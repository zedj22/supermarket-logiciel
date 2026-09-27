# Phase 10 "Packs / Bundles" — Reverse-Engineering Analysis & Decision Record

Status: **all decision gates RESOLVED before any implementation code was written.**
This document is the single source of truth for the Phase 10 build. The
implementation document is `docs/PHASE_10_IMPLEMENTATION.md`.

---

## 1. Scope

**Phase 10 roadmap block** (`PHASE_0_ROADMAP.md:436-469`):

| Area | Required |
|---|---|
| Features | Pack CRUD, component management, pack pricing, stock validation, pack sales in POS |
| Backend | Pack service, component validation, pack pricing logic |
| Flutter | Pack management screen, pack picker in POS, pack display in cart |
| Tests | Pack CRUD tests, stock validation tests, pack sale tests |
| Acceptance | packs create/edit/delete; stock validation works; pack sales deduct component stock |

Governing business rule — `PHASE_0_BUSINESS_RULES.md:11`:
> "| Pack | A pack sale must have all component stock; components are deducted | retain |"

and `PHASE_0_BUSINESS_RULES.md:27` (rule 6):
> "A pack is saleable only if active and all aggregate component quantities are
> available. Variants in packs require an explicit target policy; legacy source
> is not sufficient proof."

**Out of scope (unchanged):** returns/voids of packs (Phase 12), reports
(Phase 14), purchases (Phase 11), PDF/printing (Phase 15), LAN/offline.

---

## 2. What already exists (verified in code, not assumed)

### 2.1 Database — no pack tables need to be created

`migrations/versions/2026_09_22_1128_73355bdf31d4_0002_phase2_domain_models.py`
already creates:

| Table | Columns (relevant) |
|---|---|
| `packs` | `id`, `name VARCHAR(200) NOT NULL`, `barcode VARCHAR(50) UNIQUE`, `price NUMERIC(18,3) NOT NULL DEFAULT 0`, `is_active BOOLEAN NOT NULL DEFAULT true`, `image_path VARCHAR(500)`, `archived_at`, `created_at`, `updated_at` |
| `pack_items` | `id`, `pack_id → packs CASCADE`, `product_id → products RESTRICT NOT NULL`, `variant_id → product_variants RESTRICT NULL`, `quantity NUMERIC(18,3) NOT NULL DEFAULT 1`, `UNIQUE (pack_id, product_id, variant_id)` (`uq_pack_item_component`) |
| `sale_lines.pack_id` | `→ packs RESTRICT`, nullable, **no index today** |

### 2.2 Models already exist

`new_app/backend/app/models/catalog.py:298` `Pack(MasterModel)` and
`:320` `PackItem(Base, UUIDMixin, TimestampMixin)` are complete, with
`pack_items` relationship `cascade="all, delete-orphan"`, `lazy="selectin"`.

`MasterModel` (`app/db/base.py:87`) already provides `archived_at` +
`is_archived` — soft-archive is free.

### 2.3 Enum already exists

`StockMovementType.PACK_COMPONENT` exists (`PHASE_2_IMPLEMENTATION.md:185`:
"| `StockMovementType` | sale, sale_void, purchase, purchase_delete, return,
adjustment, pack_component |"). `PHASE_8_POS_ANALYSIS.md:450` explicitly left
its usage as an open decision: *"new enum has `PACK_COMPONENT` — **decision for
Phase 10**"* → **resolved below (GATE 5)**.

`SaleLine.pack_id` already exists on the model (`app/models/sale.py:106`).

### 2.4 What is actually missing

1. `sale_lines.product_id` is `NOT NULL` (`app/models/sale.py:96-100`), but a
   pack summary line has no product → **one migration is required**.
2. No Pack schemas / repository / service / router.
3. `SaleLineRequest` has no `pack_id`; `SaleService` has no pack branch.
4. Flutter has no Pack models, no packs screen, no POS pack picker, no pack
   cart-line rendering, no Pack localization keys.

---

## 3. Legacy behavior (verified from source — behavioral reference only)

Source: `python_app/modules/sales.py` (pack branch inside the invoice insert
loop), `python_app/modules/packs.py`, `python_app/gui/main_window.py`.

Legacy `sale_items` insert for a pack cart item, verbatim structure:

```python
if item.get("is_pack"):
    pack_id   = int(item["pack_id"])
    pack_price= float(item["price"])
    pack_qty  = float(item["quantity"])
    components = item.get("components") or []
    # 1) pack summary row — product_id is NULL
    INSERT INTO sale_items (sale_id, product_id, quantity, price, total, pack_id)
    VALUES (?, NULL, pack_qty, pack_price, pack_price*pack_qty, pack_id)
    # 2) component rows — real product, exploded qty, pack_id set
    need_qty = unit_qty * pack_qty
    if cavailable < need_qty: raise ValueError(...)          # pre-check
    INSERT INTO sale_items (sale_id, product_id, quantity, price, total, pack_id)
    VALUES (?, cid, need_qty, cprice, cprice*need_qty, pack_id)
    UPDATE products SET quantity = quantity - ? WHERE id = ? AND quantity >= ?  # guarded
    if cursor.rowcount != 1: raise ValueError(...)
    INSERT INTO inventory_movements (product_id, quantity_change, reason)
    VALUES (?, -need_qty, f"... - {invoice_number}")
    continue   # pack path never falls through to the product path
```

Legacy facts worth keeping:
- pack summary row has **NULL `product_id`** and carries the **charged** amount;
- component rows are **not charged** (the invoice total comes from the cart,
  not from summing `sale_items`);
- component target is the **base product** (`products` table) — no variant;
- per-component pre-check **plus** guarded decrement with rowcount;
- one `inventory_movements` row per component;
- pack branch `continue`s — it is a separate line type, not a product line.

Legacy cart line shape (`PHASE_8_POS_ANALYSIS.md:266-258`):
```python
{"is_pack": True, "pack_id": int, "id": -int(pack_id), "name": str,
 "price": float, "quantity": float, "unit": "باقة", "total": price*qty,
 "components": [{"product_id": int, "name": str, "unit_qty": float, "unit_price": float}, ...]}
```

Legacy locales entries for packs live in
`python_app/locales/translations_new_additions.json`, which **no code loads**
(`PHASE_0_LOCALIZATION_AUDIT.md:3`) — not a usable source for new keys.

---

## 4. Decision gates — RESOLVED

Every gate below was answered before implementation. Each records the
alternatives, the decision, and the evidence.

### GATE 1 — What does a component point at? → **base product only**

- **Decided:** `pack_items.product_id` is the only component target.
  `variant_id` stays in the DDL (Phase 2 legacy compatibility) but the Pack API
  **rejects** any request carrying `variant_id`, and `SaleService` never
  resolves a pack component through a variant.
- **Alternatives considered:** (a) allow variants as components; (b) allow
  variants but resolve stock from the parent product; (c) base product only.
- **Why (c):** `PHASE_0_BUSINESS_RULES.md:27` — *"Variants in packs require an
  explicit target policy; legacy source is not sufficient proof."*;
  `PHASE_2_IMPLEMENTATION.md:279` and `PHASE_3_IMPLEMENTATION.md:354` list
  "Pack + variant combination rules" as an **UNVERIFIED / UNRESOLVED** deferred
  decision requiring product-owner approval. Phase 10 must not silently resolve
  a decision that docs mark as requiring approval. Legacy also only ever
  targeted `products`.
- **Consequence:** the deferred decision stays open and unchanged. Re-opening
  it later is additive (drop the API rejection), not a rewrite.
- **Fractional quantities are allowed:** `pack_items.quantity NUMERIC(18,3)`
  and weighted packs (e.g. `0.500 kg` of cheese per pack) are legitimate;
  component demand is computed in base units with `Decimal`.

### GATE 2 — What does `component.quantity` mean? → **base units consumed per 1 pack**

- **Decided:** `component.quantity` = base units of that product consumed by
  **one** pack. Selling `N` packs consumes `N × component.quantity`.
  Legacy: `need_qty = unit_qty * pack_qty`.
- **Decided:** pure `Decimal` arithmetic end-to-end; quantize only at
  persistence (`NUMERIC(18,3)`), matching Phase 7 non-negotiable #3
  (`PHASE_7_IMPLEMENTATION.md:376`). No floats in the pack path.

### GATE 3 — Pack price semantics → **fixed, editable, >= 0, no auto-discount**

- **Decided:** `packs.price` is a fixed, server-authoritative price, editable
  through `PUT /packs/{id}`. `price >= 0` (0 is allowed — promotional /
  zero-rated packs; negative rejected by `Field(ge=0)`).
- **Decided:** **no automatic discount formula.** `PHASE_8_POS_ANALYSIS.md:401`
  — *"no auto discount formula — UNVERIFIED whether any UI computes pack
  savings"*. Therefore no savings field, no auto-computed discount.
- **Decided:** `sum_of_parts` is a **computed, read-only, informational**
  field on list/detail responses: `Σ (component.quantity × products.price)`
  computed live at read time. It is never persisted, never fed into totals,
  never used for stock or COGS. It exists because the blueprint shows it
  (`PHASE_0_API_BLUEPRINT.md:216-226`).
- **Decided:** server-authoritative price wins, exactly like product lines;
  a client `unit_price` mismatch produces a `PriceOverride` (see GATE 10).

### GATE 4 — Which stock is checked and decremented? → **`products.quantity` (Phase 7 source of truth), with the `allow_negative_stock` escape hatch**

- **Decided:** component stock is `products.quantity` — Phase 7's authoritative
  stock (`PHASE_7_IMPLEMENTATION.md:378`, `PHASE_8_POS_ANALYSIS.md:434`). No
  second stock field, no stock reserved for packs.
- **Decided:** the component's `products.allow_negative_stock` flag is honored,
  exactly as `_resolve_line` / `_decrement_stock` do today
  (`app/services/sale.py:362,742,768`). This keeps pack stock semantics
  identical to plain-line stock semantics — a product that may go negative
  through a plain sale must not become unsellable through a pack sale.
- **Decided:** "aggregate" in `PHASE_0_BUSINESS_RULES.md:27` means
  `Σ over all pack lines in this request (component.quantity × pack qty)` for
  that component. A running per-request demand map is accumulated across pack
  lines and compared with live stock at resolve time. Plain product lines keep
  their existing per-line pre-check + guarded-decrement behavior (untouched —
  changing it would alter Phase 8 semantics and is not Phase 10 scope).

### GATE 5 — Which movement type? → **`PACK_COMPONENT`**

- **Decided:** component deductions write `inventory_movements` rows with
  `movement_type = StockMovementType.PACK_COMPONENT`, `reason =
  "Pack sale {invoice_number}"`, `source_document_type = "sale"`,
  `source_document_id = sale_id`, `unit_cost` = component `avg_cost` snapshot,
  `avg_cost_after` = component `avg_cost` unchanged.
- **Why:** resolves the explicit open decision at
  `PHASE_8_POS_ANALYSIS.md:450`. The enum value was seeded in Phase 2 exactly
  for this, and it makes pack-driven stock drops distinguishable from pl.3ain
  sales in Phase 14 reports without parsing reason text (legacy had to use
  free-text reason `PHASE_8_POS_ANALYSIS.md:547`).
- **The pack summary line writes NO movement** — it owns no stock.

### GATE 6 — How is a pack sale persisted? → **one uncharged pack summary line + N uncharged-flagged component lines**

This is the central design decision.

**Decided line set for one cart line of `N` packs:**

| # | `product_id` | `pack_id` | `quantity` | `unit_price` | `unit_cost` | `line_discount` | `line_total` | role |
|---|---|---|---|---|---|---|---|---|
| summary | **NULL** | pack | `N` (packs) | `packs.price` | `0` | charged discount | charged total | **charged** |
| component ×k | product | pack | `N × component.quantity` (base) | component catalog price snapshot | component `avg_cost` snapshot | `0` | **`0`** | **not charged** |

- **Derivation of "charged":** `pack_id IS NOT NULL AND product_id IS NULL` →
  pack summary (charged); `pack_id IS NOT NULL AND product_id IS NOT NULL` →
  component (not charged); `pack_id IS NULL` → ordinary product line (charged).
  This is exactly the shape `PHASE_8_POS_ANALYSIS.md:544` documented as the
  intended design: *"pack summary `product_id NULL + pack_id`"*.
- **Why not charge component rows and skip the summary row:** legacy charged
  the pack price on the summary row and stored component amounts separately
  (§3); if component `line_total` were non-zero, `SUM(sale_lines.line_total)`
  would double-count revenue forever.
- **Why keep the component `unit_price` snapshot:** `PHASE_8_POS_ANALYSIS.md:400`
  — *"Component `sale_items` rows store component unit price & extended amounts
  for cost/stock tracking; pack summary row carries charged amount."* Keeping it
  is free and preserves the historical record.
- **Aggregate integrity that this shape guarantees:**
  - `SUM(sale_lines.line_total)` = header `subtotal − line_discounts` (component
    rows contribute 0, summary row carries the charge). ✅
  - `SUM(sale_lines.unit_cost × quantity)` = true COGS (summary row contributes
    0 because `unit_cost = 0`, component rows contribute real COGS). ✅
  - Therefore **no report ever needs to filter lines** to get revenue or COGS
    right — the uncharged flag is only needed for *pre-commit totals*.
- **`unit_price × quantity ≠ line_total` on component rows is intentional** and
  documented here (§4 GATE 6) and in `PHASE_10_IMPLEMENTATION.md`. `line_total`
  is the money column; `unit_price` on a component row is a catalog snapshot.
- **Pre-commit totals:** `_ResolvedLine` gains a `charged: bool`.
  `_compute_totals` and `validate_cart` sum `line_gross` / `line_discount`
  **only over charged lines**. Component lines carry `line_gross = 0` so any
  naive sum is also correct.
- **`unit_summary_from_lines` skips component lines**, so a pack sale shows
  `"1 pack"` and not `"1 pack · 6 piece"`.

**Rejected alternatives:**
1. *Only component lines, no summary row* — loses the charged line, breaks
   `SUM(line_total)` = revenue (would report component prices, not pack price),
   and contradicts legacy + `PHASE_8_POS_ANALYSIS.md:544`.
2. *A synthetic `products` row per pack* — pollutes the catalog, needs stock,
   breaks barcode uniqueness. Rejected outright.
3. *Component rows with `unit_price = 0`* — arithmetically clean but throws
   away a documented historical snapshot for no gain (totals are already
   correct because `line_total = 0`).

### GATE 7 — Can editing a pack rewrite historical sales? → **no**

- `sale_lines.pack_id` is `ON DELETE RESTRICT`, and Pack deletion is a
  **soft archive** (GATE 8), so a pack referenced by any sale can never vanish.
- Component replacement rewrites `pack_items` only. Historical sale lines carry
  their own name/price/cost/quantity snapshots (Phase 2 snapshot pattern,
  `PHASE_2_IMPLEMENTATION.md:132-135`) and do **not** read `pack_items` at
  read time. Editing components therefore cannot change a past invoice.
- `DELETE /packs/{id}` archives; it never hard-deletes a referenced pack.

### GATE 8 — What makes a pack saleable, and what does DELETE mean? →
**`is_active AND archived_at IS NULL`; DELETE = soft archive**

- **Saleable iff** `pack.is_active == True AND pack.archived_at IS NULL`
  (satisfies *"active"* in `PHASE_0_BUSINESS_RULES.md:27`).
- Selling a non-saleable pack → `BusinessRuleError(code="PACK_INACTIVE")`
  → HTTP 422, raised during line resolution, **before** any mutation.
- `DELETE /packs/{id}` sets `archived_at = now()` and `is_active = false`
  (soft archive, matching products/customers; the blueprint's *"Delete/
  deactivate pack"* at `PHASE_0_API_BLUEPRINT.md:250`). Re-activating is done
  via `PUT` (`is_active` and clearing `archived_at`).
- Archived packs are excluded from the default list and from the POS picker,
  and are rejected at checkout. `status=all` includes them for admin views.

### GATE 9 — Cost / PMP treatment → **sales never move PMP; pack cost is not first-class**

- Phase 7 non-negotiables (`PHASE_7_IMPLEMENTATION.md:374-383`): `avg_cost` is
  the authoritative PMP; **decreases/sales never change PMP**. A pack sale is a
  set of component decreases → each component's `avg_cost` is read for the
  movement snapshot and left untouched.
- There is **no `packs.cost` / pack COGS column**. COGS of a pack sale is
  `Σ component.unit_cost × component.quantity` from the persisted component
  lines. The summary line's `unit_cost = 0` makes this fall out of a plain sum.
- The `packs.price − Σ COGS` margin is a Phase 14 reporting question and is
  deliberately **not** computed anywhere in Phase 10.

### GATE 10 — Discounts on packs → **reuse Phase 8 rules on the pack summary line**

- Line discount is accepted on the pack summary line and validated exactly
  like a product line discount (`0 <= line_discount <= line_gross`).
- Invoice-level discount applies to the whole cart as today.
- `require_pos_discount` (POS_DISCOUNT permission) triggers when the pack
  summary line has a discount — no Pack-specific discount permission.
- Component lines always carry `line_discount = 0`, so a discount can never be
  double-applied.
- Client `unit_price` mismatch on a pack line produces a `PriceOverride`
  carrying `pack_id` (and `product_id = null`), keeping the
  "server corrected the price" notice working for packs.

### GATE 11 — Permissions → **no new scopes; reuse product scopes for pack CRUD**

| Endpoint | Scope | Rationale |
|---|---|---|
| `GET /packs`, `GET /packs/{id}`, `GET /packs/{id}/availability` | `PRODUCT_VIEW` | Packs are catalog data; POS (cashier) must read them |
| `POST /packs` | `PRODUCT_CREATE` | Pack definition is master-data authoring |
| `PUT /packs/{id}` | `PRODUCT_UPDATE` | same |
| `DELETE /packs/{id}` | `PRODUCT_ARCHIVE` | same |
| `POST /api/v1/sales` with pack lines | `POS_SALE` (existing) | unchanged |

Every preceding phase reused Phase 4 scopes (`PHASE_6_IMPLEMENTATION.md:164`,
`PHASE_7_IMPLEMENTATION.md:381`, `PHASE_8_POS_IMPLEMENTATION.md:205`,
`PHASE_9_IMPLEMENTATION.md:244`). `PermissionScope` already contains all four
`product_*` scopes. **No `pack_*` scope is invented.**

### GATE 12 — Response envelope → **implemented pagination convention wins over the blueprint**

`PHASE_0_API_BLUEPRINT.md:216-226` shows `GET /packs` returning a bare array.
The implemented convention everywhere (`{items,total,page,page_size,pages}`,
default 40 / max 100) wins by the established precedent
(`PHASE_5_IMPLEMENTATION.md:153` — *"Seed policy is authoritative … deliberate
supersession of the blueprint line"*).

### GATE 13 — Holds / restore → **packs are holdable**

`HoldCartItem.product_id` is required today, so saving a hold containing a pack
would 422. `HoldCartItem` gains an optional `pack_id` and an optional
`product_id`, and `restore_hold` dispatches through the same pack resolver as
checkout. Hold restore performs **no stock reservation** (Phase 8 rule
unchanged).

### GATE 14 — Concurrency → **same guarded-decrement + row-lock discipline as Phase 8/9**

- Component stock is decremented with `UPDATE … WHERE quantity >= ?` +
  `rowcount == 1` inside the single sale transaction (identical to
  `_decrement_stock`). The loser of the race gets `ConflictError` (409) and the
  whole sale rolls back → **zero residue**.
- The debt-ceiling gate (`_enforce_debt_ceiling`, FOR UPDATE re-read) remains
  the **first statement** inside the transaction, before any component
  decrement (`PHASE_9_IMPLEMENTATION.md:204-213`).
- A real PostgreSQL concurrency test is added, because SQLite physically cannot
  prove `SELECT … FOR UPDATE` / row-lock serialization (same rationale as
  `tests/integration/test_sale_ceiling_concurrency.py:1-42`).

---

## 5. Architecture

### 5.1 Pack management (backend)

```
POST/GET/PUT/DELETE /api/v1/packs
        │  require_permission(product_*)
        ▼
   PackService  ── validation, audit rows, soft archive
        │  BaseService.transaction()
        ▼
   PackRepository ── persistence only (Phase 7 non-negotiable #9)
        ▼
   packs / pack_items  (already migrated)
```

### 5.2 Pack sale (backend) — one transaction, unchanged boundary

```
POST /api/v1/sales  (items[] may now carry pack_id)
        │
        ├─ read-only, before tx:  resolve every line
        │     product line  → _resolve_line            (unchanged)
        │     pack line     → _resolve_pack_line  → [summary, comp1..compN]
        │                        ▲ aggregates component demand across pack lines
        ├─ _compute_totals over CHARGED lines only
        ├─ pos_discount / pos_credit permission gates (unchanged)
        ▼
   ONE transaction
        ├─ 1. _enforce_debt_ceiling   (FIRST — Phase 9 rule)
        ├─ 2. guarded decrement for every component line (rowcount)
        ├─ 3. INSERT sales
        ├─ 4. INSERT sale_lines (summary: product_id NULL; components: pack_id set)
        ├─ 5. INSERT inventory_movements type=PACK_COMPONENT per component
        ├─ 6. INSERT sale_payments
        └─ 7. customer.balance + DebtLedgerEntry (if debt > 0)
        any exception → full rollback → structured error
```

### 5.3 Flutter

```
lib/features/packs/
  packs_providers.dart     list/detail/availability + create/update/archive
  packs_screen.dart        paginated table, search, status filter, actions
  pack_form_dialog.dart    create / edit (name, barcode, price, components)
  pack_detail_dialog.dart  components + availability
lib/features/pos/
  pack_picker_dialog.dart  choose an active pack, qty, add to cart
  pos_models.dart          CartLine.packId / isPack / key / toSaleJson
  pos_providers.dart       cart add/merge/stock-guard pack awareness
  pos_screen.dart          pack cart tile + components sub-list + picker button
lib/core/strings.dart      pack keys × ar/fr/en
lib/router/app_router.dart /packs route (product_view)
```

---

## 6. API contracts (specification)

### 6.1 Pack component request

```jsonc
{ "product_id": "uuid", "quantity": "2.000" }
// variant_id is NOT accepted (GATE 1) → 422
```

### 6.2 `POST /api/v1/packs` → 201

```jsonc
{
  "name": "Family Pack",
  "barcode": "PK0001",
  "price": "500.000",
  "is_active": true,
  "components": [
    {"product_id": "…", "quantity": "2.000"},
    {"product_id": "…", "quantity": "3.000"}
  ]
}
```

### 6.3 `GET /api/v1/packs?page=&page_size=&search=&status=` → 200

```jsonc
{
  "items": [{
    "id": "uuid", "name": "Family Pack", "barcode": "PK0001",
    "price": "500.000", "is_active": true, "is_archived": false,
    "components_count": 2, "sum_of_parts": "600.000",
    "created_at": "…", "updated_at": "…"
  }],
  "total": 1, "page": 1, "page_size": 40, "pages": 1
}
```

### 6.4 `GET /api/v1/packs/{id}` → 200 — same object plus `components[]`
(each with `product_id`, `product_name`, `product_unit`, `quantity`, `product_price`).

### 6.5 `PUT /api/v1/packs/{id}` → 200 — partial update. `components`, when
present, **replaces the whole component set** (validated before the write).

### 6.6 `DELETE /api/v1/packs/{id}` → 200 — soft archive (GATE 8).

### 6.7 `GET /api/v1/packs/{id}/availability?quantity=1` → 200 (read-only)

```jsonc
{
  "pack_id": "uuid", "pack_name": "Family Pack", "price": "500.000",
  "is_active": true, "is_archived": false,
  "quantity": "2.000",             // packs being checked (default 1)
  "saleable": true,                // active + archived check + all components ok
  "max_pack_quantity": "4.000",    // floor(min over components of stock / need)
  "sum_of_parts": "600.000",       // informational
  "components": [{
    "product_id": "uuid", "product_name": "Rice 1kg", "product_unit": "piece",
    "required_per_pack": "2.000",
    "required_quantity": "4.000",  // required_per_pack × quantity
    "available_quantity": "10.000",
    "ok": true
  }],
  "errors": []                     // e.g. "Rice 1kg: need 4, have 2"
}
```
This endpoint **never mutates anything** (no stock reservation).

### 6.8 `POST /api/v1/sales` item shape change

```jsonc
// product line (unchanged)
{"product_id": "uuid", "quantity": "1", "unit_price": "100", "line_discount": "0"}
// pack line (new)
{"pack_id": "uuid", "quantity": "2", "unit_price": "500", "line_discount": "0"}
```
Exactly one of `product_id` / `pack_id` is required; both or neither → 422
(`VALIDATION_ERROR`). This preserves the existing *"422 when both missing"*
contract.

---

## 7. Error catalog (only codes actually introduced)

| Code | HTTP | When |
|---|---|---|
| `PACK_INACTIVE` | 422 | selling a pack that is `is_active=false` or archived |
| `PACK_STOCK_INSUFFICIENT` | 422 | a component's stock (aggregated over pack lines) cannot cover demand; `details` lists every shortage |
| `PACK_COMPONENT_DUPLICATE` | 422 | create/update lists the same `(product_id)` twice |
| `VALIDATION_ERROR` | 422 | component `quantity <= 0`, `price < 0`, empty component list, both/neither of `product_id`/`pack_id`, `variant_id` supplied |
| `NOT_FOUND` | 404 | unknown pack id (existing `NotFoundError` convention) |
| `CONFLICT` | 409 | concurrent component decrement lost the row race (existing) |
| `FORBIDDEN` / `VALIDATION_ERROR` | 403/422 | existing permission + validation paths |

Deliberately **not** introduced: `PACK_NOT_FOUND` (repo convention is a generic
`NOT_FOUND` with `details.pack_id`), `PACK_COMPONENT_INVALID` (archived/missing
component products reuse the existing `NOT_FOUND` / `BUSINESS_RULE_ERROR`
messages), `PACK_COMPONENT_QUANTITY_INVALID` (schema-level `gt=0` already gives
`VALIDATION_ERROR`).

---

## 8. Localization

- All new user-visible strings live in `new_app/lib/core/strings.dart` in **all
  three** maps (`ar`, `fr`, `en`). Key parity is enforced by
  `test/unit/constants_test.dart`.
- Arabic is RTL: every new pack widget uses logical properties
  (`EdgeInsetsDirectional`, `AlignmentDirectional`, `textDirection`) — no
  hard-coded left/right, no manual `Directionality` overrides.
- Backend returns codes only (`PACK_INACTIVE`, …); Flutter maps codes to
  localized keys. Raw backend `message` travels only as the secondary `detail`
  line (Phase 9 contract, `PHASE_9_IMPLEMENTATION.md:276-280`).

---

## 9. Migration

Single new revision, `down_revision = c8d4e5f6a1b2` (Phase 9 head), keeping
exactly one Alembic head:

1. `ALTER TABLE sale_lines ALTER COLUMN product_id DROP NOT NULL`
   (pack summary rows are `product_id IS NULL`).
2. `CREATE INDEX ix_sale_lines_pack_id ON sale_lines (pack_id)` — the model
   gains `index=True` on `pack_id`, which `alembic autogenerate` would
   otherwise flag (`tests/integration/test_migrations.py:86`
   `test_autogenerate_detects_no_changes`).

Both are **additive / constraint-relaxing and fully reversible**; downgrade
restores `NOT NULL` and drops the index. No rows are rewritten. The only
precondition for `downgrade` is that no pack summary rows exist yet — the
downgrade test runs against a freshly migrated test database, and
`test_downgrade_and_reupgrade` (`test_migrations.py:65`) runs before any pack
sales can be written.

`packs` / `pack_items` need **no** new migration — they already exist.

---

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `sale_lines.product_id` becomes nullable → an ordinary product line could be written without a product | `SaleLineRequest` validator requires exactly one of `product_id`/`pack_id`; `SaleService` asserts the invariant before insert |
| Component rows double-count revenue | component `line_total = 0` + `charged` flag in `_compute_totals` + unit summary skips them |
| Pack + plain line of the same product over-draws stock | plain lines keep Phase 8 semantics; pack lines aggregate among themselves; final guarded decrement catches everything else → 409 + rollback |
| Editing components corrupts history | history never reads `pack_items`; snapshots only; `pack_id` RESTRICT + soft archive |
| SQLite green / PostgreSQL red | dedicated PG concurrency test for the pack component race |
| `CartLine.productId` becoming nullable breaks Phase 8 tests | field stays named and becomes `String?`; every existing constructor call site keeps compiling; new pack tests cover the null path |
| Old holds (product-only snapshots) | `HoldCartItem.product_id` stays valid; `pack_id` is optional |

---

## 11. Files inspected

**Backend:** `app/models/catalog.py`, `app/models/sale.py`,
`app/models/enums.py`, `app/models/audit.py`, `app/db/base.py`,
`app/schemas/sale.py`, `app/schemas/common.py`, `app/schemas/catalog.py`,
`app/services/sale.py`, `app/services/base.py`, `app/services/customers.py`,
`app/services/catalog.py`, `app/repositories/base.py`,
`app/api/v1/products.py`, `app/api/v1/customers.py`, `app/api/v1/pos.py`,
`app/api/v1/router.py`, `app/core/exceptions.py`,
`migrations/versions/*0002*`, `*0009*`, `*0010*`, `*0011*`,
`tests/conftest.py`, `tests/unit/test_pos_sale.py`,
`tests/integration/test_migrations.py`,
`tests/integration/test_sale_ceiling_concurrency.py`.

**Flutter:** `lib/features/pos/pos_models.dart`, `pos_providers.dart`,
`pos_screen.dart`, `pos_quantity.dart`, `price_override_dialog.dart`,
`lib/core/strings.dart`, `lib/router/app_router.dart`,
`lib/features/products/*`, `test/unit/constants_test.dart`,
`test/unit/pos_cart_test.dart`, `test/widget/pos_screen_test.dart`.

**Legacy:** `python_app/modules/sales.py` (pack branch),
`python_app/modules/packs.py`, `python_app/gui/main_window.py`
(`_ensure_packs_schema`), `python_app/locales/translations_new_additions.json`.

**Docs:** `PHASE_0_ROADMAP.md`, `PHASE_0_BUSINESS_RULES.md`,
`PHASE_0_API_BLUEPRINT.md`, `PHASE_0_POS_WORKFLOW.md`,
`PHASE_0_DATABASE_ANALYSIS.md`, `PHASE_0_FEATURE_MATRIX.md`,
`PHASE_0_LOCALIZATION_AUDIT.md`, `PHASE_0_ARCHITECTURE.md`,
`PHASE_2_IMPLEMENTATION.md`, `PHASE_3_IMPLEMENTATION.md`,
`PHASE_5_IMPLEMENTATION.md`, `PHASE_6_IMPLEMENTATION.md`,
`PHASE_7_IMPLEMENTATION.md`, `PHASE_8_POS_ANALYSIS.md`,
`PHASE_8_POS_IMPLEMENTATION.md`, `PHASE_9_IMPLEMENTATION.md`.

---

## 12. Fix round decision record (PACK UX / DOMAIN)

Three issues were raised after the core Phase 10 round. This section is the
decision record for them; `PHASE_10_IMPLEMENTATION.md` §3.5 / §4.5 describe
what was built.

### Issue 1 — component selling units

**Decision:** a component MAY pin one of the product's existing Phase 6
selling units; `quantity` on the wire is then expressed **in that unit** and
the backend converts once with the already-tested Phase 6 rule
`base = quantity × multiplier` (`app/domain/unit_conversions.py`).

**GATE 2 stays intact by construction.** `pack_items.quantity` keeps its
meaning (*base units consumed per 1 pack*) and no legacy row is rewritten —
stock, availability, sale deduction and `sum_of_parts` math are untouched.
The unit identity lives in three new **nullable** columns:

| Column | Type | Meaning |
|---|---|---|
| `selling_unit_id` | FK → `product_selling_units.id`, `ON DELETE SET NULL`, indexed | which unit the manager picked (`NULL` = base unit = legacy row) |
| `selling_unit_name` | `VARCHAR` snapshot | label at definition time |
| `selling_unit_multiplier` | `NUMERIC` snapshot | multiplier at definition time |

Snapshots are required: a later catalog edit (Box 24 → 12) must not change
the meaning of packs that already exist. Availability and the sale always
use the stored base quantity, so the pinned unit can never affect stock
math — it is an input/labeling concern only.

**Validation reuses existing envelopes** (no new error codes): unknown unit
→ `NOT_FOUND` 404; unit of another product → `VALIDATION_ERROR` 422;
archived unit → `BUSINESS_RULE_ERROR` 422; resolved base `<= 0` →
`VALIDATION_ERROR` 422.

### Issue 2 — informational profitability preview

**Decision:** `GET /packs/{id}` returns `estimated_cost`,
`estimated_profit` and `estimated_margin_percent`, computed live from the
components' `avg_cost` (Phase 7 PMP):

```
cost   = Σ(base_quantity × avg_cost)
profit = price − cost
margin = profit / price × 100   (null when price == 0 — never ÷ 0)
```

Everything is quantized (`0.01` for money/percent, `0.001` for quantities)
and returned as decimal **strings**. Nothing is persisted and nothing in
pricing, totals, stock or reports reads it — it is a *display-only* hint,
so GATE 3 (fixed price) and GATE 9 (pack cost is not first-class) are not
weakened. Phase 14 remains the place where pack costing becomes real.

### Issue 3 — edit hydration

**Decision:** the list row carries no `components[]`; the edit action now
fetches `GET /packs/{id}` first (`PacksNotifier.fetchDetail`) and hydrates
the dialog from the detail payload — product **name**, pinned unit and the
quantity **in that unit** (`unit_quantity`), so no component row is ever
silently dropped and no quantity is rescaled on open.

### Backward compatibility

- Packs created before this fix round hydrate with `selling_unit_id = NULL`
  → base unit, quantity unchanged (still base units), payload still sends
  `selling_unit_id: null` → the backend keeps its original behavior.
- The API only gained optional fields; every existing client and test that
  ignores them keeps working.
- Migration `2026_09_27_1200_b7c8d9e0f1a2_0013_phase10_pack_component_selling_unit.py`
  (`b7c8d9e0f1a2` ← `d1e2f3a4b5c6`) is purely additive and reversible;
  `alembic heads` stays single-headed.

### Tests added in this round

- Backend: `tests/unit/test_packs.py` 53 → **71** (base-unit component, unit
  conversion + stock deduction, availability parametrized in base and unit
  terms, legacy load, hydration by name, update round-trip, archived /
  foreign / unknown unit rejection, historical stability after a multiplier
  change, estimate values incl. zero-price margin, estimate follows the live
  `avg_cost`).
- Flutter: new `test/widget/pack_form_dialog_test.dart` (14), extended
  `pack_models_test`, `packs_localization_test` (4 new keys × 3 locales),
  `packs_screen_test` (detail-fetch hydration).

---

## 13. Bugfix decision record — 100% margin preview

**Reported:** the pack profitability preview shows a 100% margin even when
the component products have real costs.

**Root cause (data, not the formula).** `PackService.to_detail_response`
correctly computes `SUM(base_quantity * products.avg_cost)`, but
`products.avg_cost` (the Phase 7 PMP) was `0` for products whose real cost
sat in `products.cost`:

- migration `0008` added `avg_cost NOT NULL DEFAULT 0` with **no
  backfill**, so every product row created before 2026-09-23 kept PMP 0
  (7 of 21 rows on the dev DB: `lait` 150, `jnina` 200, `fromage` 190,
  `Smoke PU Product` 6, `#35 Smoke Product` 8);
- `ProductService.update` copied `cost` through `setattr` without ever
  reseeding the PMP, so a cost entered after creation was lost too.

`cost = 0` → `profit = price` → margin **100.00%**.

**Decision:** keep `products.avg_cost` as the ONLY cost input of the
estimate and repair the PMP itself:

1. `0014` (`c9d0e1f2a3b4`) — data migration: `avg_cost = cost` where
   `avg_cost = 0 AND cost > 0` and no positive `adjustment` /
   `package_receive` movement with an explicit `unit_cost` owns the
   average. Idempotent; `downgrade` is a no-op (data, not schema).
2. `ProductService.update` — while the PMP still mirrors the nominal cost
   (`avg_cost == cost`, i.e. no receipt priced the stock) a `cost` edit
   reseeds it; once receipts own it, a cost edit never rewrites it.

**Rejected:**

- reading `product.cost` as a fallback in the estimate — two cost sources
  would disagree with stock valuation and break the "PMP is authoritative"
  contract;
- hiding / special-casing the 100% in Flutter — the display was correct,
  the input was wrong.

**Tests:** 15 new (14 backend + 1 Flutter), listed in
`PHASE_10_IMPLEMENTATION.md` §5/§10. `alembic heads` → `c9d0e1f2a3b4`
(single head), applied to the dev DB: `products WHERE cost > 0 AND
avg_cost = 0` went **7 → 0**.
