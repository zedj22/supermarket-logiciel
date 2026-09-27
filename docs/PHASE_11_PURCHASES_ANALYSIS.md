# PHASE 11 — PURCHASES & SUPPLIERS: ANALYSIS / DECISION RECORD

Status: DECISION RECORD (written before implementation)
Phase 10 baseline: commit `phase-10: complete packs` (`d15c65e`), Alembic head `c9d0e1f2a3b4` (0014), backend 681 / Flutter 877 tests green.
This document is STEP A of the Phase 11 workflow. Every uncertain business rule is marked
**RESOLVED**, **UNRESOLVED**, or **DEFERRED**. No implementation begins until this record is
internally consistent.

---

## 0. Evidence base

| Source | Path | Role |
|---|---|---|
| Phase 0 roadmap | `docs/PHASE_0_ROADMAP.md` §Phase 11 (L473–512) | scope authority |
| Phase 0 business rules | `docs/PHASE_0_BUSINESS_RULES.md` L12–13, L25–28, L30–42 | rule authority |
| Phase 0 API blueprint | `docs/PHASE_0_API_BLUEPRINT.md` L421–474 | endpoint intent |
| Phase 0 DB analysis | `docs/PHASE_0_DATABASE_ANALYSIS.md` L20–21, L45–51 | target schema |
| Feature matrix | `docs/PHASE_0_FEATURE_MATRIX.md` L13 | "destructive deletion → reversible documents" |
| Legacy source | `python_app/database/db_manager.py` L1744–2163, `python_app/gui/main_window.py` L15944–17321 | behavioral evidence |
| Current models | `new_app/backend/app/models/purchase.py`, `party.py`, `inventory.py`, `enums.py` | existing schema |
| Phase 6 packaging | `docs/PHASE_6_IMPLEMENTATION.md` §33 | purchase units / stock packages |
| Phase 7 PMP | `docs/PHASE_7_IMPLEMENTATION.md` §8/§15/§16, `app/domain/valuation.py` | costing authority |
| Phase 9 ledger pattern | `docs/PHASE_9_IMPLEMENTATION.md` §3, §7, §8, `app/services/debt.py` | supplier payables template |
| Phase 10 cost semantics | `docs/PHASE_10_IMPLEMENTATION.md` L24–30, migration 0014 | `avg_cost` authoritative, revalidation debt |

---

## 1. Legacy purchase behavior (evidence, not authority)

Legacy code is **inline**: `python_app/database/db_manager.py:1744-2163` (data layer) and
`python_app/gui/main_window.py:15944-17321` (UI). There is no `modules/purchases.py`, no server
endpoint, and no test (`README.md:27-29`, `PYTHON_FILE_LIST.txt`).

**Schema (legacy):**
- `suppliers(id, name, phone, address, email, contact_person, balance DOUBLE, notes)` — `db_manager.py:664-676`.
- `purchases(id, supplier_id, invoice_number UNIQUE, total_amount, paid_amount, discount, purchase_date, device_name, note)` — `db_manager.py:678-690`. **No status column, no state machine.**
- `purchase_items(id, purchase_id, product_id, variant_id, quantity, purchase_price, total)` — `db_manager.py:692-703`. No unit/package/snapshot columns.
- No supplier payment or ledger table — payments only decrement the scalar `suppliers.balance` (`db_manager.py:2053-2090`).

**Behavior (`create_purchase_invoice`, `db_manager.py:1804-1962`):** one transaction; validates
supplier/items/qty>0/price≥0; `net = gross − discount`, `remaining = net − paid`
(clamped silently); per line: `products.quantity += qty` (+ variant qty too), **`products.cost := purchase_price`
(last-price overwrite)**, positive `inventory_movements` row (free-text reason), then
`suppliers.balance += remaining`. Purchase is created as an immediately-posted document — no
draft, no separate receiving step.

**Deletion (`delete_purchase`, `db_manager.py:2092-2163`):** hard DELETE; reverses stock
(clamped `GREATEST(0,…)`), inserts negative movement, subtracts remaining from balance
(clamped), **does not restore cost**, no reversal record. Admin PIN + confirm in UI.

**Supplier payment (`record_supplier_payment`):** rejects `amount<=0` and `amount > balance`
(legacy Arabic error "المبلغ أكبر من رصيد المورد"); `note` parameter silently discarded; no
history kept. Payment dialog is supplier-level, not invoice-level (`main_window.py:16954-17036`).

**Payment modes in the purchase form:** `نقدًا` (paid = net) / `على الحساب` (paid = 0) /
`دفعة جزئية` (0 < paid < net) — expressed purely through `paid_amount`, no method enum
(`main_window.py:16202-16279`).

**Legacy defects (must NOT be ported):**
1. Cost = last-purchase-price overwrite, no weighted average (`db_manager.py:1933-1934`).
2. Deletion leaves `products.cost` pointing at the deleted invoice's price.
3. `purchases.paid_amount` never updated after settlement while `suppliers.balance` drops →
   per-invoice "remaining" and supplier balance diverge forever (`UPDATE purchases` = 0 hits).
4. Payment `note` discarded; no payment history.
5. Silent `GREATEST(0,…)` clamps hide over-reversal → stock/ledger mismatch.
6. Supplier `DELETE` violates FK when purchases exist; bare `except` swallows the error.
7. `total_amount` stores **gross** while UI shows it as total — gross/net ambiguity.
8. No concurrency control on the read-then-write cost update.
9. No PMP anywhere (confirmed `docs/PHASE_6_IMPLEMENTATION.md:834`, `PHASE_7_IMPLEMENTATION.md:45`).
10. No package/purchase-unit handling on documents (unit string dropped at save).
11. Device-scoped purchase list but global supplier balance → inconsistent summary card.

**Legacy verdict:** purchase = supplier invoice = stock receipt in one step; supplier balance is
a pooled scalar with no ledger; cost is last-price. Phase 11 keeps the *workflow shape*
(supplier → invoice → lines → receive → payable → payment → reversal) and replaces the
*accounting* (ledger, PMP, append-only documents) per Phase 0 rules.

---

## 2. Existing current architecture (reusable)

| Capability | Status | Location |
|---|---|---|
| `suppliers` table (`name, phone, address, balance, archived_at`) | exists | migration 0002, `app/models/party.py` |
| `purchases` table (invoice_number, supplier FK RESTRICT, subtotal/discount/total/paid, note, device_id, purchase_date, `version`) | exists | migration 0002, `app/models/purchase.py` |
| `purchase_lines` (product/variant FKs RESTRICT, name/sku/barcode/unit snapshots, unit_cost, quantity, line_total, `purchase_unit_id/name`, `unit_multiplier`, `base_qty_equivalent`) | exists | migration 0002 + 0006 |
| `StockMovementType.PURCHASE` / `.PURCHASE_DELETE` | exists, **unwritten** | `app/models/enums.py:110-111` |
| `PermissionScope` supplier/purchase scopes (27 total, seed: admin+manager) | exists | `app/models/enums.py:45-51`, `app/core/seed.py` |
| PMP: `weighted_average_cost`, `base_unit_cost_from_package`, `quantize_money` | exists (authoritative) | `app/domain/valuation.py` |
| Packaging domain: `receive_packages`, `sell_packages`, `PackagingState` | exists | `app/domain/packaging.py` |
| `inventory_movements` (`unit_cost`, `avg_cost_after`, `document_quantity/unit`, `purchase_unit_id`, `packages_change`, `source_document_type/id`) | exists, `source_document_*` unused | `app/models/inventory.py` |
| Idempotency pattern (`client_request_id` fast path + race replay) | exists | `app/services/sale.py`, `app/services/debt.py` |
| Ledger + cached balance pattern (`FOR UPDATE`, overpayment guard, `balance_after` read model) | exists | `app/services/debt.py`, `repositories/debt.py` |
| Audit (`AuditLog`, in-transaction `_audit`) | exists | `app/services/customers.py:158-181` |
| Pagination `{items,total,page,page_size,pages}`, error envelope, request IDs | exists | `app/schemas/common.py`, `app/core/exceptions.py` |
| `PurchaseService` / `SupplierService` / routers / schemas | **missing** | Phase 11 work |
| `supplier_ledger_entries` table | **missing** | Phase 11 work |

---

## 3. Reusable tables/models vs. missing capabilities

**Reused unchanged:** `suppliers` (core), `purchases`, `purchase_lines`, `products`,
`product_variants`, `product_purchase_units`, `product_stock_packages`, `inventory_movements`,
`audit_logs`, `users/roles/permissions`.

**Missing → added (migration 0015, additive):**
1. `suppliers.email`, `suppliers.contact_person`, `suppliers.notes` — legacy contact fields (§1).
2. `purchases.status`, `purchases.client_request_id` (unique), `purchases.received_at`,
   `purchases.cancelled_at` — lifecycle + idempotency (GATES 2, 18).
3. `supplier_ledger_entries` — authoritative payables ledger (GATE 10).

**Missing → code only:** schemas, repositories, services, routers, Flutter features, strings, tests.

---

## 4. Proposed domain model

```
Supplier (MasterModel)
  name(200, required, indexed, NOT unique), phone(30), address(text),
  email(100, new), contact_person(100, new), notes(text, new),
  balance NUMERIC(18,3)  -- cached projection of supplier_ledger_entries
  archived_at (soft archive)

Purchase (DocumentModel: id, created_at, updated_at, version)
  invoice_number "PUR-YYYYMMDD-HHMMSS-mmm-xxxx" unique
  supplier_id RESTRICT, user_id SET NULL
  status: draft | received | cancelled            -- new
  subtotal, discount, total, paid  NUMERIC(18,3)
  note, device_id, purchase_date
  client_request_id unique nullable               -- new
  received_at, cancelled_at nullable              -- new

PurchaseLine (unchanged schema)
  purchase_id, product_id RESTRICT, variant_id RESTRICT NULL
  snapshots: product_name, product_sku, product_barcode, product_unit
  unit_cost (per purchase unit, document fact), quantity (document units),
  line_total = quantity × unit_cost
  purchase_unit_id/name, unit_multiplier, base_qty_equivalent = qty × multiplier

SupplierLedgerEntry (new table, mirrors debt_ledger_entries)
  supplier_id RESTRICT, entry_type: purchase | payment | purchase_cancel
  amount NUMERIC(18,3) always positive, sign derived from entry_type
  reference_purchase_id SET NULL, note, client_request_id unique nullable,
  user_id SET NULL, entry_date
  -- suppliers.balance = Σ purchase − Σ payment − Σ purchase_cancel (capped, §10)

InventoryMovement (unchanged schema, newly written by Phase 11)
  movement_type: purchase | purchase_delete
  source_document_type="purchase", source_document_id=purchase.id
```

All money/quantity columns are `NUMERIC(18,3)`; all server math is `Decimal`; JSON money is a
string (existing convention). UUID PKs everywhere (existing convention).

---

## 5. Purchase lifecycle — GATE 2 **RESOLVED**

Minimal state machine justified by evidence:

```
                POST /purchases (receive=false)
                          │
                          ▼
                      ┌────────┐   PUT /purchases/{id}    ┌────────┐
      POST /purchases │ DRAFT  │◄────────────────────────► │ DRAFT  │  (editable)
      (receive=true)  └────┬───┘   DELETE → hard delete    └────────┘   (audited,
            │              │        + audit, Phase 0 rule 4)
            │              │ POST /purchases/{id}/receive
            └──────►┌───────────┐
                    │ RECEIVED  │ ── POST /purchases/{id}/cancel ──► ┌───────────┐
                    └───────────┘   (reversal: stock + payable,      │ CANCELLED │
                                    PMP untouched, movements kept)   └───────────┘
                                                                     (terminal)
```

- **RESOLVED:** exactly three states `draft | received | cancelled`. Evidence: Phase 0 rule 4
  distinguishes "unposted drafts" (⇒ a draft state exists) from posted documents; roadmap
  requires "stock increase on purchase" and "purchase deletion with stock reversal"; feature
  matrix demands "reversible documents". No legacy state names exist to honor.
- **RESOLVED:** drafts are hard-deletable (Phase 0 rule 4: "physical delete is reserved for
  unposted drafts and requires audit"). Received documents are never deleted, only cancelled.
- **RESOLVED:** cancelled is terminal; no re-receipt, no edit, no delete.
- Every transition writes an audit row inside the same transaction (§13).

## 6. Purchase versus receipt — GATE 3 **RESOLVED**

**No separate receipt document.** Receiving is a state transition on the purchase document
itself (the Phase 0 DB blueprint lists `purchases/purchase_lines` only — no receipt table —
and legacy had none). Rationale: "Do not introduce separate concepts without evidence."

- `POST /purchases` with `receive=true` (**default**) = create + receive in ONE transaction →
  blueprint parity ("Atomic: creates purchase, updates stock, adjusts supplier balance",
  `PHASE_0_API_BLUEPRINT.md:441-474`).
- `POST /purchases` with `receive=false` = save an editable draft.
- `POST /purchases/{id}/receive` = receive an existing draft (same atomic routine).
- Historical reconstruction: `received_at` + immutable lines + movement rows carrying
  `source_document_id` answer "which purchase caused this stock change".

## 7. Purchase line semantics — GATE 4 **RESOLVED**

- Line = `product_id` (+ optional `variant_id`) + document `quantity` > 0 + `unit_cost` ≥ 0.
- `line_total = quantity × unit_cost` (Decimal, quantized 0.001 at persistence).
- Document: `subtotal = Σ line_total`, `total = subtotal − discount`, `0 ≤ discount ≤ subtotal`,
  `0 ≤ paid ≤ total` (over-`paid` rejected with `VALIDATION_ERROR` — **not** silently clamped as
  in legacy §1.10.7).
- **Line-level discount: none** (no schema column exists; blueprint and legacy both use
  document-level discount only) — **RESOLVED**: document discount only.
- **Tax per line: none** — see GATE 14.
- Historical snapshots: existing `purchase_lines` snapshot columns; a later product rename/price
  change never rewrites a stored line (FKs are RESTRICT, lines are never updated post-receive).

## 8. Purchase units / packaging — GATE 5 **RESOLVED**

Follows Phase 6 schema exactly (`purchase_lines.purchase_unit_id/unit_multiplier/base_qty_equivalent`).

| Input on the line | Meaning |
|---|---|
| `purchase_unit_id = null` | loose/base purchase: `quantity` = base units, `unit_cost` = cost per base unit, `base_qty_equivalent = quantity` |
| `purchase_unit_id = X` (multiplier m) | `quantity` = **whole packages** (fractional rejected → `PURCHASE_LINE_INVALID`, consistent with `receive_packages` and Phase 7 `_adjust_packages`), `unit_cost` = cost **per package**, `base_qty_equivalent = quantity × m` |

- Example (spec §11): 5 Boxes × 24, 900/Box → `base_qty_equivalent = 120`,
  `base_unit_cost = 900 / 24 = 37.500`. Conversion: `base_unit_cost_from_package()` (Decimal-only).
- **Mixed units in one document: allowed** — each line resolves independently (evidence: stock
  packages are per product+unit; Phase 7 adjustments already treat lines independently).
- Package lines with `multiplier = 1` are permitted (behaves like base).
- **RESOLVED:** packages may be mixed freely; no document-level unit constraint.
- Receiving a package line grows `product_stock_packages.full_packages` via `receive_packages()`
  (same as Phase 7 increase path) so the packaging invariant `loose = total − Σ(full×mult) ≥ 0`
  is preserved.

## 9. Variants — GATE 6 **RESOLVED**

Variants **are supported** (evidence: `purchase_lines.variant_id` exists since 0002; blueprint
items carry `variant_id`; legacy supported variant purchase items).

- A variant line updates **`variant.quantity` only** — parent `products.quantity` is untouched.
  This is the exact symmetry of Phase 8 sales: "variant sale decrements variant.quantity ONLY,
  parent products.quantity is NOT touched" (`app/services/sale.py:1046-1075`).
- **PMP ownership:** product-level `products.avg_cost` is **not** recomputed from variant
  receipts — preserving the Phase 7 non-negotiable "Variant-level PMP deferred — variants share
  product avg_cost" (`PHASE_7_IMPLEMENTATION.md:374-383`, `inventory.py:828-830` variant
  adjustments likewise only snapshot the product PMP). Movement rows carry `variant_id`,
  `unit_cost`, and `avg_cost_after` = the unchanged product PMP snapshot.
- `variant.cost` (nominal column, exists) is set to the receipt's base unit cost — the variant
  analogue of the last-purchase reference (legacy had no variant cost column and wrongly
  overwrote the parent's; current schema gives variants their own).
- Variant lines may use a purchase unit for conversion (multiplier applies); **no** product
  packaging state change for variant lines (stock packages are product-level; variant stock is
  not packaged).
- **DEFERRED:** variant-level weighted average PMP (Phase 7 deferral stands; would require a
  variant valuation model and POS costing changes — not Phase 11).

## 10. PMP / avg_cost lifecycle — GATE 7 **RESOLVED** (core)

**Single authority:** `app/domain/valuation.py::weighted_average_cost` (pure Decimal), invoked
only from backend services (`InventoryService` today; `PurchaseService` receives via the
shared helpers below). Flutter never computes PMP.

```
new_pmp = ((old_qty × old_pmp) + (incoming_qty × incoming_unit_cost))
          / (old_qty + incoming_qty)
```

- `old_qty ≤ 0` → `new_pmp = incoming_unit_cost` (seed; covers "opening qty = 0 → PMP = 150").
- `incoming_unit_cost < 0` or `incoming_qty ≤ 0` → error (`ValuationError` → 422). Negative
  quantity on a line is rejected at schema level (`gt=0`).
- **Zero-cost receipt is allowed** (`unit_cost = 0`): free/bonus goods blend into the average
  naturally; into empty stock it seeds PMP = 0 (documented; the later Phase 10 "still nominal"
  rule then still allows a nominal `cost` edit to reseed). **RESOLVED** — matches Phase 7,
  which accepts `unit_cost ≥ 0`.
- Package conversion happens **before** the formula: `incoming_unit_cost = unit_cost ÷ multiplier`,
  `incoming_qty = quantity × multiplier`. The document quantity is never rewritten.
- Fractional base quantities supported (weight goods), quantized to 0.001 only at persistence.
- Repeated receipts compound correctly (each receipt reads the committed previous state).
- Legacy products (`avg_cost = 0`, backfilled by migration 0014): first receipt into `qty > 0`
  with `avg_cost = 0` computes `(q×0 + recv×cost)/(q+recv)` — mathematically valid but a product
  whose stock predates PMP would be under-weighted. **RESOLVED:** receipt uses the formula as
  written; migration 0014 already seeded `avg_cost = cost` for such products, so the normal path
  applies. A dedicated regression test covers a "legacy product" row (`avg_cost=0, cost>0`).
- **Never computed in Flutter**; response payloads carry server-computed `avg_cost`,
  `avg_cost_after` on movements.

## 11. What is "purchase cost"? — GATE 8 **RESOLVED**

- **Cost basis for PMP = base-unit line cost** = `unit_cost` (loose line) or
  `unit_cost ÷ multiplier` (package line). This is the price actually paid per base unit.
- **Document-level discount is NOT allocated into PMP.** Rationale: (a) the blueprint and legacy
  both model discount as a settlement-level adjustment on the total; (b) Phase 7 already defines
  the receipt cost as the document line cost; (c) allocating a lump discount across lines would
  invent a new allocation rule (proportional? equal?) that no source authorizes. The discount
  affects `total` and therefore the payable, not the stock valuation. **RESOLVED.**
- **Tax: purchases are recorded tax-exclusive with no tax field** — see GATE 14.
- `unit_cost` may be 0; negative rejected (`VALIDATION_ERROR` at schema, defense-in-depth at
  service via `ValuationError`).

## 12. `products.cost` vs `products.avg_cost` — GATE 9 **RESOLVED**

Preserves Phase 7/10 semantics; receipts now become the "receipt" the Phase 10 fix anticipated.

| Event | `products.avg_cost` (PMP, authoritative) | `products.cost` (nominal) |
|---|---|---|
| Product create | seeded `= cost` (existing) | user input |
| Catalog `cost` edit while `avg_cost == cost` (no receipt priced the stock) | reseeded `= cost` (existing Phase 7/10 rule) | updated |
| Catalog `cost` edit after a receipt owns PMP (`avg_cost != cost`) | **unchanged** (existing rule) | updated |
| Purchase receive (product line) | **weighted-average recompute** | **set to the latest receipt's base unit cost** (last-purchase reference) |
| Purchase receive (variant line) | unchanged (variant PMP deferred) | `variant.cost := base unit cost` |
| Sale / decrease / cancel | unchanged (never) | unchanged (never) |

- `cost` is shown in the UI as the "purchase price / nominal cost" reference; `avg_cost` is the
  PMP shown as valuation cost (existing stock screen behavior unchanged).
- **RESOLVED:** receipts establish PMP ownership automatically — as soon as a receipt makes
  `avg_cost != cost`, later catalog `cost` edits can no longer overwrite the PMP (the exact
  Phase 10 fix invariant, `PHASE_10_IMPLEMENTATION.md` bugfix round). Setting `cost` on receive
  keeps "last purchase price" useful for purchase-form defaults (legacy `last_pp` behavior)
  without touching the PMP.
- Pack profitability (`estimated_cost` from `avg_cost`) needs **no code change** — GATE 22.

## 13. Supplier payable lifecycle — GATE 10 **RESOLVED**

New append-only `supplier_ledger_entries`; `suppliers.balance` is a **cached projection**
(same principle as Phase 9: "a balance is a cached projection, rebuilt/reconciled from entries").

| Event | Ledger entry | Balance |
|---|---|---|
| Purchase received, `unpaid = total − paid > 0` | `entry_type="purchase"`, amount = unpaid | `+= unpaid` |
| Purchase received fully paid (`paid = total`) | none | unchanged |
| Supplier payment (`amount`) | `entry_type="payment"`, amount | `−= amount` |
| Purchase cancelled | `entry_type="purchase_cancel"`, amount = `min(total − paid, balance)` | `−= amount` |

- **RESOLVED — cash / credit / partial:** expressed by `paid` at receipt
  (`=total` / `=0` / between), exactly the legacy three modes (§1), no method enum.
- **RESOLVED — overpayment rejected:** payment `> balance` → 422
  `SUPPLIER_PAYMENT_EXCEEDS_BALANCE`; payment `≤ 0` → 422 `SUPPLIER_PAYMENT_AMOUNT_INVALID`.
  No negative balance, no supplier advance/credit semantics (Phase 9 precedent: "no advance
  semantics anywhere in the system").
- **RESOLVED — pooled balance:** supplier payments are supplier-level (legacy dialog is
  supplier-level, blueprint has no per-invoice settlement). Purchase `paid` records only the
  amount settled at receipt; later payments are not allocated to specific invoices.
  **DEFERRED:** per-invoice payment allocation (needs an allocation table; no source requires it).
- **RESOLVED — cancellation cap:** reversal amount is capped at the current balance so a
  cancellation can never push the balance negative (if other purchases' debt was already paid,
  only `balance` is reversed; the shortfall is written into the ledger `note` — explicit, not a
  silent `GREATEST(0,…)` clamp). Recovering money already paid to the supplier for cancelled
  goods (credit note) is **DEFERRED** to Phase 12/13 (no invented supplier-credit semantics).
- **Atomicity:** ledger entry + balance + purchase status + stock + movements + audit commit in
  ONE transaction (§16). Reconciliation assertion: `balance == Σ entries` inside payment and
  cancel transactions (mirrors `ledger_sum_for_customer`).
- **RESOLVED — payment methods (GATE 11):** supplier payments record `amount + note + client_request_id`
  only. Legacy payment dialog had no method field; sales' `PaymentMethod` enum is a POS
  concept and is **not** applied to purchases (spec: "Do NOT assume sales payment rules
  automatically apply"). Purchase "payment mode" is derived from `paid` (§13 table).
  **DEFERRED:** payment method taxonomy (cash/transfer/check) pending product-owner input.

## 14. Purchase cancellation / deletion — GATE 12 **RESOLVED**

| From state | Operation | Effect |
|---|---|---|
| draft | `DELETE /purchases/{id}` | hard delete lines + header, audit row (`delete`). Phase 0 rule 4 permits physical delete for unposted drafts. |
| received | `POST /purchases/{id}/cancel` | reversal: stock −base qty (movement `purchase_delete`), packaging reduced (packages of that unit consumed first; conflict if other-unit packages would exceed the new total), payable reversed (capped, §13), `status=cancelled`, audit (`void`). |
| cancelled | anything | 409 `INVALID_PURCHASE_STATE` / `PURCHASE_ALREADY_CANCELLED` |

- **Never hard-delete a received/cancelled purchase** (append-only documents, Phase 0 rule 4;
  feature matrix: "destructive deletion → reversible documents").
- **Stock guard:** cancellation that would drive stock below 0 is rejected with 409 `CONFLICT`
  (same code the implemented POS uses for insufficient stock) unless
  `products.allow_negative_stock` — **not** silently clamped like legacy.
- **PMP on cancellation: UNCHANGED.** RESOLVED with rationale: Phase 7 non-negotiable
  "decreases/sales never change avg_cost"; a cancellation is a stock decrease, and recomputing
  history would be incorrect whenever later receipts/sales have already moved the average
  (legacy likewise never restored cost). Limitation documented: after cancelling a cheap
  receipt, PMP may be higher than the current replacement cost — acceptable and consistent.
  **DEFERRED:** full PMP rewind/rebuild semantics (would need movement-chain replay rules).
- Movements are never deleted; `source_document_id` keeps the full chain auditable.

## 15. Purchase editing — GATE 13 **RESOLVED**

- **Draft:** fully editable via `PUT /purchases/{id}` (supplier, lines, discount, paid, note) —
  snapshots recomputed, totals recomputed, version incremented (optimistic lock already on
  `DocumentModel`).
- **Received:** **immutable** — any PUT → 409 `INVALID_PURCHASE_STATE`. "A received purchase
  should not silently mutate historical stock and cost calculations." Corrections happen via
  cancellation (+ a new purchase).
- **Cancelled:** immutable.
- Drafts have no stock/PMP/payable effects, so editing them cannot corrupt history.

## 16. Atomic transaction (receive)

```
BEGIN  (PurchaseService.transaction() — one Session, one commit)
  fast-path idempotency check (client_request_id)
  SELECT purchase FOR UPDATE            -- state guard, serializes concurrent receives
  validate status == draft else 409
  validate supplier exists / not a problem (archived suppliers keep history)
  validate every line (product/variant/unit exist, not archived, qty>0, cost>=0)
  lock affected rows: products (FOR UPDATE, ascending id) [+ variants FOR UPDATE]
  for each line:
      compute base_qty, base_unit_cost (Decimal)
      product path:  read qty/avg → weighted_average_cost → set quantity, avg_cost, cost
                     + packaging receive_packages (package lines)
      variant path:  variant.quantity += base_qty; variant.cost := base_unit_cost
      insert InventoryMovement (purchase, source_document_id, document_*, unit_cost,
                     avg_cost_after, quantity_before/after, user, device)
  totals: subtotal/total already stored at create; re-assert invariants
  supplier payable: unpaid = total − paid; if > 0 → SupplierLedgerEntry(purchase)
                    + supplier.balance += unpaid (FOR UPDATE on supplier row)
  purchase.status = received; received_at = now
  AuditLog(action=receive, entity_type=purchase, details=stock/PMP/payable summary)
COMMIT           -- any exception → ROLLBACK EVERYTHING (zero residue)
```

Cancellation runs the symmetric single transaction (stock reversal + `purchase_delete`
movements + ledger `purchase_cancel` + status + audit).

## 17. Concurrency — GATE 17 **RESOLVED**

- Purchase row locked `FOR UPDATE` at receive/cancel → concurrent receives serialize; the
  second sees `status=received` → 409 `PURCHASE_ALREADY_RECEIVED` (never double-receive).
- Affected `products` rows locked `FOR UPDATE` in ascending `product_id` order (deadlock-safe)
  before the PMP read-modify-write; variant rows likewise. Supplier row locked `FOR UPDATE`
  for balance updates (mirrors `CustomerRepository.get_for_update`).
- Guarded `UPDATE` + `rowcount` is used for stock decreases on cancellation (mirrors
  `SaleService._decrement_stock`).
- **PostgreSQL integration tests are mandatory** for concurrent receive (SQLite cannot prove
  `FOR UPDATE` semantics) — new `tests/integration/test_purchase_receive_concurrency.py`
  following `test_debt_payment_concurrency.py`.

## 18. Idempotency — GATE 18 **RESOLVED**

- **Create:** optional `client_request_id` (≤100, unique index on `purchases`) — Phase 8/9
  pattern: fast path → replay (`idempotent_replay=true`), race → IntegrityError → re-read winner.
  Same key on a different logical request → 409, never cross-replay (purchase keys live in their
  own column, so cross-entity collision is structurally impossible; supplier payment keys live
  on `supplier_ledger_entries` like `debt_ledger_entries`).
- **Receive:** no separate receive key — the state guard under `FOR UPDATE` is the idempotency
  mechanism: a duplicate receive request returns 409 `PURCHASE_ALREADY_RECEIVED` (documented
  behavior, never a second stock increase). Flutter treats 409-after-timeout as "already
  received" by re-fetching.
- **Supplier payment:** optional `client_request_id` on `supplier_ledger_entries` (exact Phase 9
  semantics, including "failed attempts do not consume the key").
- Rejected business operations roll back and do not consume keys (Phase 9 rule).

## 19. Permissions — GATE 19 **RESOLVED — no new scopes**

`assert len(PermissionScope) == 27` (`tests/unit/test_enums.py:45`) and every preceding phase's
"no new scopes invented" precedent stand. Mapping (all already seeded to admin+manager,
cashier gets none — `app/core/seed.py`):

| Operation | Scope |
|---|---|
| supplier list/detail/ledger | `supplier_view` |
| supplier create/update/archive | `supplier_manage` |
| supplier payment | `supplier_manage` (mirrors customer payment → `customer_manage`) |
| purchase list/detail | `purchase_view` |
| purchase create / edit draft / receive | `purchase_create` |
| purchase cancel / draft delete | `purchase_delete` (the reversible replacement for delete) |

UI gating (`hasPermissionProvider`) is convenience only; the server enforces every route.

## 20. Localization — GATE 20 **RESOLVED**

- All new UI strings added to `lib/core/strings.dart` `_arabic`, `_french`, `_english` maps
  (existing architecture; parity enforced by tests, same as Phases 6–10).
- Arabic RTL via the existing `GlobalMaterialLocalizations` delegates; layouts use
  `MediaQuery` breakpoints (never direction-dependent offsets); numeric cells
  `textDirection: TextDirection.ltr` per stock-screen convention.
- Backend returns stable error `code`s; Flutter maps code → localized message, raw backend text
  only as secondary `detail` (Phase 9 pattern).
- New localization tests: `test/unit/suppliers_localization_test.dart`,
  `test/unit/purchases_localization_test.dart` (AR/FR/EN key parity + script checks).

## 21. API contracts (derived, not copied)

Conventions applied: `/api/v1`, `{items,total,page,page_size,pages}` (default 20–40, max 100 —
implemented convention beats blueprint's `limit`, GATE 12 precedent of Phase 10), envelope
`{error:{code,message_key,message,details,request_id}}`, static routes before `/{id}`,
`StrictBaseModel`, per-router service factory, Decimal money as strings.

**Suppliers** (tags `suppliers`)

| Method | Path | Scope | Notes |
|---|---|---|---|
| GET | `/suppliers?page&page_size&q&include_archived` | `supplier_view` | `q` matches name/phone |
| POST | `/suppliers` | `supplier_manage` | 201; `balance` never client-writable |
| GET | `/suppliers/{id}` | `supplier_view` | |
| PUT | `/suppliers/{id}` | `supplier_manage` | partial (exclude_unset) |
| DELETE | `/suppliers/{id}` | `supplier_manage` | soft archive; 409 `OUTSTANDING_SUPPLIER_BALANCE` if `balance != 0` |
| GET | `/suppliers/{id}/ledger?page&page_size` | `supplier_view` | newest first, computed `balance_after` |
| POST | `/suppliers/{id}/payments` | `supplier_manage` | `{amount,note?,client_request_id?}` → payment result |

*Deviation from blueprint:* blueprint has no supplier-payment endpoint at all while the roadmap
requires a "Supplier payment dialog" and "balance tracking" → `POST /suppliers/{id}/payments`
mirrors the blueprint's `POST /customers/{id}/pay`. *Deviation:* no `/suppliers/search` — the
list endpoint's `q` covers the purchase-form picker (avoid duplicate endpoints, spec §9).

**Purchases** (tags `purchases`)

| Method | Path | Scope | Notes |
|---|---|---|---|
| GET | `/purchases?page&page_size&q&status&supplier_id` | `purchase_view` | `q` = invoice/supplier/note |
| POST | `/purchases` | `purchase_create` | 201; body below; `receive` default `true` |
| GET | `/purchases/{id}` | `purchase_view` | header + lines |
| PUT | `/purchases/{id}` | `purchase_create` | draft only |
| POST | `/purchases/{id}/receive` | `purchase_create` | draft → received (atomic) |
| POST | `/purchases/{id}/cancel` | `purchase_delete` | received → cancelled (reversal) |
| DELETE | `/purchases/{id}` | `purchase_delete` | draft only, hard delete + audit, 204 |

```jsonc
// POST /api/v1/purchases
{
  "supplier_id": "uuid",
  "lines": [{
     "product_id": "uuid", "variant_id": null,
     "purchase_unit_id": "uuid|null",
     "quantity": "5",            // document units: packages if unit else base
     "unit_cost": "900"          // per purchase unit
  }],
  "discount": "0", "paid": "4500",
  "note": "...", "device_id": "PC1",
  "client_request_id": "purchase-...",   // optional
  "receive": true                          // false → draft
}
```

*Supersession of blueprint:* blueprint's `items[].purchase_price` becomes `unit_cost` (existing
column naming, Phase 6 packaging semantics); `discount`/`paid_amount` → `discount`/`paid`
(existing columns); response uses the implemented envelope. Blueprint `DELETE /purchases/{id}`
"is atomic (restores stock, adjusts supplier balance)" is superseded by
`POST /{id}/cancel` for received documents per Phase 0 rule 4 + feature matrix (DELETE remains
for drafts only) — documented supersession, not silent change.

**Error codes (only where required):**

`NOT_FOUND`, `VALIDATION_ERROR`, `FORBIDDEN`, `CONFLICT` (existing) +
`PURCHASE_ALREADY_RECEIVED` (409), `PURCHASE_ALREADY_CANCELLED` (409),
`INVALID_PURCHASE_STATE` (409), `PURCHASE_LINE_INVALID` (422),
`OUTSTANDING_SUPPLIER_BALANCE` (409), `SUPPLIER_ARCHIVED` (422),
`SUPPLIER_PAYMENT_AMOUNT_INVALID` (422), `SUPPLIER_PAYMENT_EXCEEDS_BALANCE` (422).
Not created (redundant): `SUPPLIER_NOT_FOUND`, `PURCHASE_NOT_FOUND`, `PURCHASE_RECEIVE_CONFLICT`
(row lock + state guard cover it), `PURCHASE_CREATE_CONFLICT`.

## 22. UI workflows (Flutter)

**Suppliers** (`lib/features/suppliers/`): list + search (debounce 300 ms, server `q`),
add/edit dialog, archive action, detail panel with balance + paginated ledger, payment dialog
(idempotency key generated once per dialog open, Phase 9 pattern).

**Purchases** (`lib/features/purchases/`): list (filters: status, supplier, search), purchase
editor dialog — supplier picker (searchable), product picker (barcode/name, server search),
per line: purchase-unit dropdown (with multiplier shown), quantity, unit cost, computed
`line_total`; live subtotal/discount/total/paid/remaining summary; actions:
**Save draft** / **Save & receive**; detail dialog (historical lines, status badge, receive/cancel
buttons per permission); supplier payment reachable from supplier detail.

- Layout: `PurchasesLayoutMode {wide ≥1200, medium ≥800, narrow}` (stock/products convention).
- Keyboard-first entry: Enter adds/updates the focused line; quantity/cost fields accept
  decimal keyboards; no local PMP math — totals are computed from document quantities
  (display only) while **all valuation comes from the server**.
- Nav: two new rail entries (`/suppliers`, `/purchases`) gated by `supplier_view` /
  `purchase_view`, inserted after debts (4 coordinated edits in `ScaffoldWithNav`).
- Idempotency: purchase save generates one `client_request_id` per attempt, reused on retry
  (POS `pendingClientRequestId` pattern).

## 23. Audit requirements — RESOLVED

| Action | AuditLog | details |
|---|---|---|
| supplier create/update/archive | `create` / `update` / `delete` | fields or "archived (soft delete)" |
| purchase create (draft or direct receive) | `create` | invoice, supplier, total, receive flag |
| purchase receive | `receive` **(new `AuditAction.RECEIVE` member)** | invoice, lines, base qty, PMP before→after per product, payable added |
| purchase cancel | `void` | invoice, reversed qty, payable reversed |
| draft delete | `delete` | invoice |
| supplier payment | `payment` | amount, balance before→after |

Audit rows ride the mutation's transaction (existing `_audit` pattern — rollback removes both).
`AuditAction` gains exactly one member (`RECEIVE = "receive"`); no existing value is changed,
no test asserts the member count of `AuditAction`. Inventory movements remain the authoritative
stock journal (GATE 16).

## 24. Reporting readiness — GATE 21 **RESOLVED (data only)**

Sufficient for Phase 14: purchases by period (`purchase_date` + `status` indexes), by supplier
(`supplier_id` index exists), supplier balance (ledger), product purchase history
(`purchase_lines.product_id` + movements `source_document_id`), quantity received
(`base_qty_equivalent`), purchase cost (line `unit_cost` snapshots), PMP changes
(`inventory_movements.avg_cost_after` chain), inventory valuation (`qty × avg_cost`, existing).
New indexes in 0015: `purchases(status)`, `purchases(purchase_date)`,
`purchases(client_request_id unique)`, `supplier_ledger_entries(supplier_id, entry_date)`,
`supplier_ledger_entries(client_request_id unique)`. **No report screens built** (Phase 14).

## 25. Migration strategy — RESOLVED

Single additive migration **`0015_phase11_purchases_suppliers`, `down_revision = c9d0e1f2a3b4`**:
1. `suppliers` + `email VARCHAR(100) NULL`, `contact_person VARCHAR(100) NULL`, `notes TEXT NULL`.
2. `purchases` + `status VARCHAR(20) NOT NULL DEFAULT 'received'` (backfill: any pre-existing
   row is treated as received — legacy semantics were immediate posting; the table is empty in
   practice because no service ever wrote it), `client_request_id VARCHAR(100) NULL` unique,
   `received_at TIMESTAMPTZ NULL`, `cancelled_at TIMESTAMPTZ NULL`; index on `status`,
   `purchase_date`.
3. `supplier_ledger_entries` table + indexes + FKs (RESTRICT supplier, SET NULL purchase/user).
4. Proper `downgrade()` (drop in reverse order).

Verification after upgrade: `alembic current` / `alembic heads` → exactly one head `0015…`;
`tests/integration/test_migrations.py::HEAD_REV` updated (precedent BUG-006/007).
No existing columns altered or dropped; historical rows untouched.

## 26. Decision-gate summary

| Gate | Decision | Status |
|---|---|---|
| 1 Supplier identity | name/phone/address + legacy email/contact_person/notes; balance cached; soft archive blocked by outstanding balance; `q` search; names not unique (customer/legacy parity) | RESOLVED |
| 2 Document lifecycle | `draft → received → cancelled`; draft deletable (audited), received cancellable | RESOLVED |
| 3 Purchase vs receipt | no separate receipt table; receive = state transition; `POST /purchases(receive=true)` atomic | RESOLVED |
| 4 Line semantics | qty>0, cost≥0, document discount only, no tax field, line_total=qty×cost, snapshots exist | RESOLVED |
| 5 Units/packages | document units; whole packages; base=qty×mult; base_cost=cost÷mult; mixed units allowed | RESOLVED |
| 6 Variants | supported; variant qty only; variant.cost nominal; product PMP untouched (Phase 7 deferral) | RESOLVED |
| 7 PMP | `weighted_average_cost`, Decimal, server-side, seed-on-zero, zero-cost allowed, tests per spec §7 | RESOLVED |
| 8 Cost basis | base-unit line cost; discount not allocated; no tax | RESOLVED |
| 9 cost vs avg_cost | receipt updates avg (weighted) + cost (last receipt); catalog edits keep Phase 10 rule | RESOLVED |
| 10 Supplier payable | new ledger authoritative; balance cached; pooled; overpay rejected; cancel capped | RESOLVED (allocation DEFERRED) |
| 11 Payment methods | derived from `paid`; supplier payment = amount+note; no POS enum reuse | RESOLVED (taxonomy DEFERRED) |
| 12 Cancellation | cancel-only for received; stock reversal guarded; PMP untouched; movements kept | RESOLVED (PMP rewind DEFERRED) |
| 13 Editing | drafts editable; received/cancelled immutable | RESOLVED |
| 14 Tax/fiscal | no tax engine; tax-exclusive; no new fiscal logic | DEFERRED (Phase 0 rule 7: product-owner approval) |
| 15 Snapshots | existing line snapshots; no supplier-name snapshot (customer/sale parity) | RESOLVED |
| 16 Movements | `purchase`/`purchase_delete` + source_document_* + document_* + unit_cost + avg_cost_after | RESOLVED |
| 17 Concurrency | FOR UPDATE purchase/products/variants/supplier, ordered locks; PG tests | RESOLVED |
| 18 Idempotency | create + payments: `client_request_id`; receive: state guard → 409 | RESOLVED |
| 19 Permissions | reuse 5 existing scopes, mapping above; no new scopes (27-lock test) | RESOLVED |
| 20 Localization | AR/FR/EN ×3 maps, RTL, no hardcoded strings, tests | RESOLVED |
| 21 Reporting readiness | data + indexes only; no report UI | RESOLVED |
| 22 Pack revalidation | manual QA: purchase → PMP → pack estimated cost/profit/margin; no pack redesign | RESOLVED (QA item) |

**UNRESOLVED:** none blocking implementation.
**DEFERRED (documented, not silently decided):** per-invoice payment allocation; supplier
payment-method taxonomy; tax/TVA on purchases; variant-level weighted PMP; PMP rewind on
cancellation; supplier credit notes for cancelled paid purchases (Phase 12/13 territory).

## 27. Out of scope (phase boundary)

Returns/exchanges (Phase 12), expenses (Phase 13), reports/dashboard (Phase 14), PDF printing
(Phase 15), LAN/multi-PC (Phase 16), backup/settings/final QA (Phase 17). Pack profitability
redesign — out (GATE 22: revalidate only). POS/Packs/Products — no semantic changes.

## 28. Risks / open QA points

1. `purchase_lines` FKs are RESTRICT → cancelling does not free references (intended).
2. Backfill default `'received'` for any pre-existing purchase rows — verify none exist on the
   dev DB before upgrade (defensive only).
3. Legacy-device purchase visibility is dropped (server-side global list) — documented
   supersession of legacy bug §11.12.
4. Flutter purchase editor must never compute PMP — only document arithmetic for display.
5. `AuditAction.RECEIVE` is new — audit consumers (none today) will see a new action value.
