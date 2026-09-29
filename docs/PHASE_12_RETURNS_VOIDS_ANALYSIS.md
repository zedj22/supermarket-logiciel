# Phase 12 — Returns / Voids Analysis (Decision Record)

> **Step A — analysis and decisions.** This document is the source of truth
> for Step B (backend) and Step C (Flutter).
>
> **Step B + Step C — IMPLEMENTED.** Migration 0016, services, API, tests,
> Flutter screens/dialogs, `/returns` route and localization are in the
> working tree (see `PHASE_12_IMPLEMENTATION.md`).
>
> **CLOSEOUT 2026-09-29 — STATUS: CLOSED / APPROVED.** Human QA **PASS**
> (§25, all 14 areas + the fix-round-1 click-through, executed by the
> product owner), technical verification **PASS** (backend 790, targeted
> Phase 12 103, Flutter 1010, analyze clean, single Alembic head
> `f5a6b7c8d9e0`, `alembic check` clean), result-dialog routing fix manually
> verified, no blocking issues left. Committed as one commit,
> `phase-12: complete returns and voids`.
>
> **FIX ROUND 1 — IMPLEMENTED (2026-09-29).** Product-owner UX changes, all
> recorded in §26: (a) a visible **Return Products** multi-product
> scan/search workflow that posts ONE independent return document with N
> lines, (b) invoice return quantity defaults to the **remaining returnable**
> quantity, (c) return reason is now **optional** while **void reason stays
> mandatory**. Migration `0017_return_reason_optional` (head
> `f5a6b7c8d9e0`) applied to the dev database. No business rule below was
> redesigned — the backend stays authoritative.
>
> **Baseline:** Phase 10 CLOSED (`phase-10: complete packs`), Phase 11 CLOSED
> (`phase-11: complete purchases and suppliers`), Alembic head `d3e4f5a6b7c8`
> (0015) → now `f5a6b7c8d9e0` (0017), backend 724 tests → now 790 green
> (targeted Phase 12: 103), Flutter 907 tests → now 1010 green, `analyze`
> clean. Phase 11 behavior is not modified by this record.

---

## 1. Evidence base

Everything in this document comes from sources that were actually read for Step A.

| # | Source | What was taken from it |
|---|---|---|
| 1 | `docs/PHASE_0_BUSINESS_RULES.md` L5–L42 | Retained void rule (L18), rules to correct #1–#4 (L22–L25), rule #7 UNVERIFIED list (L28), permission matrix proposal (L30–L42) |
| 2 | `docs/PHASE_0_ROADMAP.md` L515–L551 | Phase 12 scope: independent returns, invoice returns, stock restoration, invoice voiding, customer balance adjustment; backend/Flutter/test lists; acceptance criteria |
| 3 | `docs/PHASE_0_API_BLUEPRINT.md` L240–L350 | `POST /api/v1/sales/{id}/void` (permissions admin, atomic), `POST /api/v1/returns`, `GET /api/v1/returns` |
| 4 | `docs/PHASE_0_FEATURE_MATRIX.md` | Returns/voids → P0 / phase 12, "source-line limits / approval" |
| 5 | `docs/PHASE_0_POS_WORKFLOW.md` L259–L303 | Documented intended void flow (PIN + confirm + restore + movement + balance + `status='void'`) and both return flows |
| 6 | `docs/PHASE_0_BUSINESS_RULES.md` + `docs/PHASE_8_POS_ANALYSIS.md` L809, L895–897 | POS entry points: void → `pos_void`, independent return → Phase 12 |
| 7 | `docs/PHASE_9_IMPLEMENTATION.md` | `balance_after` read model, Decimal-only money, transaction/idempotency policy, error catalog, Postgres gate |
| 8 | `docs/PHASE_10_PACKS_ANALYSIS.md` (gates 5/6) | PACK_COMPONENT movement typing, uncharged summary line + N component lines, `pack_id IS NOT NULL AND product_id IS NULL` = charged summary |
| 9 | `docs/PHASE_7_IMPLEMENTATION.md` L177–L190 | Authoritative PMP rules (sales/decreases never move avg_cost; increase without unit_cost leaves avg_cost unchanged) |
| 10 | `docs/PHASE_11_PURCHASES_ANALYSIS.md` | House structure for this record (gate numbering style, "data only" reporting gate, permission gate "no new scopes") |
| 11 | Legacy `python_app/database/db_manager.py` L924 (`get_returns`), L1040 (`void_invoice`) | Legacy void and return *behavior*, including defects |
| 12 | Legacy `python_app/gui/main_window.py` L2568 (`_ensure_returns_schema`), L4641 (`_get_returned_quantity`), L4655 (`show_independent_return_dialog`), L4799 (`show_return_dialog`), L8398 (POS return button), L12421–L12433 (`_confirm_void_invoice`), L14889 (`_render_returns_voids_tab`) | Legacy UI entry points, ceilings, audit calls, report columns |
| 13 | Legacy `python_app/modules/sales.py` L225–L330 | Legacy sale decrements product **and** variant (double decrement) |
| 14 | Current backend: `models/{sale,return_doc,inventory,debt,enums}.py`, `services/{sale,debt,inventory,purchases,base}.py`, `repositories/{base,sale,debt,purchase,party}.py`, `api/{v1/router,v1/pos,v1/purchases,dependencies}.py`, `core/{exceptions,seed}.py`, `domain/{valuation,unit_conversions}.py`, `db/base.py` | Reusable architecture, existing enums/columns, exact patterns to mirror |
| 15 | Migration `2026_09_24_..._0002_phase2_domain_models.py` L288–L445 | Current `returns` / `return_lines` schema |
| 16 | Current Flutter: `lib/core/strings.dart`, `lib/router/app_router.dart`, `lib/features/auth/*`, `lib/features/pos/*`, `lib/features/stock/stock_screen.dart` L29–L52, `lib/features/clients/clients_screen.dart` L610, `lib/network/api_client.dart` | Localization, permission, movement-label and debt-history entry points |
| 17 | Tests: `tests/unit/test_enums.py`, `test_models.py` L95–L96, `test_purchases.py` L217–L219, `test_debt_history_lifecycle.py`, `tests/integration/test_*_concurrency.py`, `tests/integration/test_migrations.py`, Flutter `test/unit/pos_localization_test.dart` | Enum counts asserted, ledger algebra asserted, concurrency/integration test patterns |

No source outside this repository was used as authority. Legacy is behavioral
evidence only, never authority (project rule).

---

## 2. Legacy returns / void behavior (evidence, not authority)

### 2.1 Legacy void — `db_manager.void_invoice` (L1040)

```
BEGIN; SELECT sale_items; SELECT sale header;
for each item:  products.quantity += qty            (if product_id not null)
                INSERT inventory_movements(product_id, qty, reason)   <- product branch only
                product_variants.quantity += qty    (if variant_id not null)
if customer_id and paid_amount > 0:
    customers.balance = GREATEST(0, balance - paid_amount)
UPDATE sales SET status='void', total=0, discount=0, paid_amount=0, change_amount=0
COMMIT
```

**Observed defects (must not be ported):**

| # | Legacy behavior | Why it is wrong |
|---|---|---|
| V1 | No `require_pin` / authorization anywhere on the void path — `_confirm_void_invoice` (main_window L12424) only shows a yes/no box; `require_pin` (L2805) is never called for void | Phase 0 requires backend scopes + audit for sensitive actions |
| V2 | Reduces customer balance by `paid_amount` | Phase 0 rule #3: reverse the *outstanding debt attributable to the sale*, not `paid_amount` |
| V3 | `total = 0, discount = 0, paid_amount = 0, change_amount = 0` | Destroys the financial snapshot; Phase 0 rule #4 is append-only + preserve snapshot |
| V4 | No `status != 'void'` guard — voiding twice restores stock twice | Non-idempotent, no state machine |
| V5 | Swallows every exception (`except Exception: return False`) | Violates the no-silent-swallow rule; the caller shows a generic toast |
| V6 | No audit row written by `void_invoice` itself; movement rows carry no user/device/source document | Not attributable, not reportable |
| V7 | Variant lines restore **both** product and variant (mirrors the legacy double decrement in `modules/sales.py`) | Current Phase 8 decrements variant only — a ported void would double-restore |

### 2.2 Legacy invoice return — `show_return_dialog` (main_window L4799)

- Ceiling: client-side only, per `(invoice_number, product_id)` via
  `_get_returned_quantity` (L4641); ignores variants, ignores voided sales,
  never re-validated in the DB transaction.
- Refund `amount = q * unit_price` — ignores the sale discount and the line's
  `line_total`.
- Restores **product stock only** (`si.product_id IS NOT NULL` filter, then
  `UPDATE products SET quantity = quantity + ?`); variant stock is never touched.
- No `inventory_movements` rows at all.
- Debt: `due = total - paid_amount`; `balance -= min(amount, due)` capped at 0.
- Writes `returns` + `return_items`, audits `log_action("return_registered", ...)`
  (L4868).
- **Dead code:** `show_return_dialog` has no caller anywhere in the legacy tree
  (grep of `main_window.py`: only the `def` at L4799). Only the independent
  return is reachable, from the POS header button (L8398).

### 2.3 Legacy independent return — `show_independent_return_dialog` (L4655)

- No source sale (`sale_id NULL`), reference `DIRECT-RETURN-<timestamp>`,
  note text = fixed string, **no ceiling at all** (any quantity, any product).
- Quantity **or** amount input mode; integer check only for piece-like units.
- Restores product stock only; no movement rows; audits `log_action`
  ("return_registered", "product", pid) at L4776.
- No variant, no pack, no reason vocabulary, no authorization.

### 2.4 Legacy reporting

`_render_returns_voids_tab` (L14889): returns = `(id, invoice_number, amount,
device, return_date, note)` capped at 50; voided = `(id, invoice_number, date,
device)` capped at 30. Financial report exposes `returns_total` and subtracts
it from `net_sales`.

**Conclusion from §2:** legacy proves the *user workflow* (search/select →
ceiling → confirm → stock restored → reportable) but supplies none of the
correctness, authorization, idempotency or append-only semantics this phase
requires. Phase 0 rules #1/#3/#4 are the corrections.

---

## 3. Existing current architecture (reusable as-is)

| Concern | Where it already lives | Reuse for Phase 12 |
|---|---|---|
| Single transaction per mutation | `services/base.py` — `transaction()` context manager (`ServiceBase`) | Wrap void / create-return exactly like `create_sale`, `receive`, `cancel` |
| Row lock | `repositories/base.py` — `get_for_update()` → `.with_for_update()` (used by `party.py`, `purchase.py`) | Add `get_for_update` to `SaleRepository` (additive method) |
| Status guard helper | `services/purchases.py:_require_status` (L557+ area, raises `ConflictError` with a code) | Same shape for `sale.status == void` and return preconditions |
| Cap-with-shortfall reversal | `services/purchases.py:_post_cancel` L496–L540: `reverse = min(unpaid, balance)`, shortfall written into the ledger note, then in-transaction ledger-vs-balance reconciliation that raises `ConflictError` | Direct template for customer-debt reversal (§17) |
| Compensating ledger entry type | Phase 11 added `purchase_cancel`; `repositories/purchase.py` L167 subtracts it in `balance_after_map`, L190 in `ledger_sum_for_supplier` | Template for `sale_void` / `sale_refund` in `repositories/debt.py` |
| Idempotency | `services/sale.py.create_sale` L751–L951: unique `client_request_id`, replay returns original + `idempotent_replay=True`, `IntegrityError` → rollback → re-fetch winner | Returns get the same treatment; void uses terminal-state 409 (§19) |
| Debt ledger | `models/debt.py` (`entry_type` = free `String(20)`, `reference_sale_id`, `client_request_id`, `user_id`), `repositories/debt.py` | Only read-model algebra changes (§17); no schema change |
| Inventory movements | `models/inventory.py` + `services/sale.py:_record_sale_movement` L1101–L1156 | Mirror for void/return movements |
| Permissions | `models/enums.py` L25–L26 `POS_VOID` / `POS_RETURN`; `api/dependencies.py` L106 `require_permission`, L131 `require_any_permission`; `core/seed.py` L29–L76 | Reuse, no new scopes (§20) |
| Audit | `core/seed.py` + `services/*._audit`; `AuditAction.VOID` / `AuditAction.RETURN` already exist (`models/enums.py`) | Reuse |
| Error envelope | `core/exceptions.py`: `code=` override on any `AppError` subclass, `message_key` for Flutter | New codes via `code=` |
| Localization | `core/strings.dart` (`AppStrings.t` falls back to the raw key), `features/pos/pos_error_message.dart` (code → key) | Extend in 3 locales (§23) |
| Enums asserted | `tests/unit/test_enums.py` L45 `len(PermissionScope) == 27`, L84–L90 movement types, L114–L115 audit actions | Constrains additions (§20, §21) |
| Tables asserted | `tests/unit/test_models.py` L95–L96 `returns`, `return_lines` | Already exist; additive columns only |

---

## 4. Reusable tables/models vs. missing capabilities

| Capability | Exists today | Gap for Phase 12 |
|---|---|---|
| `returns` header table (Phase 2) | Yes — `return_number` (unique), `sale_id`, `customer_id`, `user_id`, `reason`, `total`, `note`, `device_id`, `return_date` | No `client_request_id` (idempotency), no `subtotal` / `discount` (refund decomposition) |
| `return_lines` (Phase 2) | Yes — `return_id`, `product_id` (**NOT NULL**), `variant_id`, `sale_line_id`, name/sku/barcode/unit snapshots, `unit_price`, `quantity`, `line_total` | `product_id` must become nullable (pack charged-summary lines are `product_id IS NULL`); missing `pack_id`, `quantity_base`, selling-unit/variant display snapshots, `unit_cost`, `line_discount` |
| Void columns on `sales` | `status` exists with `SaleStatus.VOID` (`enums.py`) | No `voided_at` / `voided_by` / `void_reason` → not reportable, not attributable |
| Void operation | None — `SaleService` has no void method (L751–L1572), `api/v1/pos.py` has no void route | Entire operation missing |
| Return operation | `Return` / `ReturnLine` models exported (`models/__init__.py` L62, L124–L125) but referenced by **no** service, schema or router | Entire operation missing |
| Debt reversal algebra | `sale +`, `payment -`, `adjustment ±0` (`repositories/debt.py` L86–L108) | Must subtract `sale_void` / `sale_refund` |
| `SaleRepository.get_for_update` | Missing (`repositories/sale.py` has read/list/idempotency only) | Add |
| Movement types | `StockMovementType.SALE_VOID`, `.RETURN` already exist | None (§21) |
| Flutter returns/voids feature | None (`lib/features/` has no returns/voids dir) | Whole feature |
| Flutter localization | `entry_type_*`, `supplier_entry_type_*`, `movement_*` exist | Need `entry_type_sale_void`, `entry_type_sale_refund`, plus the Phase 12 string set |
| Tests | None for returns/void | New unit + integration tests (§25) |

---

## 5. Proposed domain model

Additive only. No column is dropped, renamed or re-typed; no existing row is
rewritten.

**`sales`** (+3 nullable columns)

| Column | Type | Purpose |
|---|---|---|
| `voided_at` | `TIMESTAMPTZ NULL` | When the invoice was voided (reporting) |
| `voided_by` | `UUID NULL FK users SET NULL` | Who voided it (independent of audit) |
| `void_reason` | `TEXT NULL` | Operator-supplied reason |

`status` stays the authoritative flag (`'void'`); the snapshot columns
(`subtotal`, `discount`, `total`, `paid`, `change`) are **never** zeroed —
Phase 0 rule #3/#4.

**`returns` header** (+3 columns)

| Column | Type | Purpose |
|---|---|---|
| `client_request_id` | `VARCHAR(100) UNIQUE NULL` | Idempotency (mirror `sales.client_request_id`) |
| `subtotal` | `NUMERIC(18,3) NOT NULL DEFAULT 0` | Σ line refunds before invoice-discount share |
| `discount` | `NUMERIC(18,3) NOT NULL DEFAULT 0` | Invoice-discount share (§12) |

`total` (existing) = `subtotal - discount` = refund due. `sale_id NULL` ⇒
independent return (no new `return_type` column — derived, §10).

**`return_lines`** (+7 columns, 1 nullability change)

| Column | Type | Purpose |
|---|---|---|
| `product_id` | **NULL allowed** (was NOT NULL) | Charged pack-summary return line (`pack_id` set, `product_id` NULL), mirroring `sale_lines` |
| `pack_id` | `UUID NULL FK packs RESTRICT` | Pack-ness of the return line without joining |
| `variant_name` | `VARCHAR(100) NULL` | Historical display snapshot (mirror `sale_lines.variant_name`) |
| `selling_unit_name` | `VARCHAR(50) NULL` | Historical display snapshot |
| `selling_unit_multiplier` | `NUMERIC(18,3) NULL` | Historical multiplier — never re-read from the catalog (§15) |
| `quantity_base` | `NUMERIC(18,3) NULL` | Stock restored, in base units (§15) |
| `unit_cost` | `NUMERIC(18,3) NOT NULL DEFAULT 0` | Movement `unit_cost` snapshot (informational, §13) |
| `line_discount` | `NUMERIC(18,3) NOT NULL DEFAULT 0` | Line discount already applied inside `line_total` (reporting) |

**`debt_ledger_entries`** — no schema change. Two new *values* for the existing
free-form `entry_type` column (≤ 20 chars): `sale_void`, `sale_refund`.

**`inventory_movements`** — no schema change. Existing `movement_type` values
`sale_void` / `return` are used; pack-ness is derived from the return/sale
lines (§21).

**Nothing else changes.** No new tables: returns, voids, movements, ledger
entries and audits are all rows in existing tables.

---

## 6. Migration strategy — LIST ONLY → executed at Step B

One additive migration when Step B starts:

| Item | Detail |
|---|---|
| File | `new_app/backend/migrations/versions/..._0016_phase12_returns_voids.py` |
| `down_revision` | `d3e4f5a6b7c8` (0015) |
| Revision id | `e4f5a6b7c8d9` (generated at Step B) |
| Operations | `ALTER TABLE sales ADD COLUMN voided_at / voided_by / void_reason`; `ALTER TABLE returns ADD COLUMN client_request_id / subtotal / discount`; `ALTER TABLE return_lines ADD COLUMN pack_id / variant_name / selling_unit_name / selling_unit_multiplier / quantity_base / unit_cost / line_discount`; `ALTER TABLE return_lines ALTER COLUMN product_id DROP NOT NULL`; `CREATE UNIQUE INDEX` on `returns.client_request_id`; `CREATE INDEX` on `returns.return_date`, `returns.sale_id` (if absent) |
| Down | Drop the added columns/indexes only; never touches existing data |
| Data migration | None — all new columns are nullable or defaulted |
| Guard | `tests/integration/test_migrations.py` already asserts `returns` / `return_lines` exist (`test_models.py` L95–L96); Step B adds column assertions |

**Status: EXECUTED** — `..._e4f5a6b7c8d9_0016_phase12_returns_voids.py`;
`alembic upgrade head` / `downgrade d3e4f5a6b7c8` / re-upgrade green,
`alembic revision --autogenerate` reports no model drift, column and index
assertions added in `TestPhase12ReturnsVoidsMigration`.

---

## 7. Void lifecycle — GATE 1 **RESOLVED**

**Decision:** `completed → void` is a one-way terminal transition. Void marks
`sales.status = 'void'`, records `voided_at/voided_by/void_reason`, restores
stock, writes `sale_void` movements, reverses the attributable debt and appends
one audit row — all inside one `transaction()`. The sale row and all of its
lines, payments and snapshot totals are retained unchanged.

- Void **never** deletes or rewrites rows (Phase 0 rule #4, legacy defect V3).
- Void is **not** available for a sale in any other state: `status != 'completed'`
  → `ConflictError(code="SALE_ALREADY_VOID" | "SALE_NOT_VOIDABLE")`.
- **No `unvoid`.** Corrections are made by a new sale (project rule: corrections
  are reversals; reversing a reversal is out of scope for Phase 12).
- A voided sale keeps its `invoice_number` and remains visible in history with
  a VOID badge (legacy already filters `status != 'void'` from the *new* list,
  `db_manager` L1011 — Phase 12 keeps it listable and flagged instead, because
  reporting needs it; see §24).

Rejected alternatives: *delete the sale* (violates append-only, breaks ledger
references), *status `cancelled` + keep totals* (already covered — void is that
state, no second state invented).

## 8. Void record fields / financial snapshot — GATE 9 **RESOLVED**

**Decision:** add `voided_at`, `voided_by`, `void_reason` (§5). `subtotal`,
`discount`, `total`, `paid`, `change`, `payment_method` and every `sale_lines`
row are frozen at their original values. The reason is mandatory in the API
request (non-blank after strip → 422), mirroring the Phase 7 "reason required on
decrease" convention.

Reporting derives: `refund_due = sale.total`, `credit_reversed` = Σ ledger
`sale_void` entries referencing the sale, `cash_pending = refund_due -
credit_reversed`.

## 9. Return lifecycle — GATE 2 **RESOLVED**

**Decision: posted-immediately, no draft/cancel state.** `POST /api/v1/returns`
creates a fully posted return document in one transaction (document + lines +
stock + movements + debt entry + audit). There is **no `status` column** on
`returns`, no edit and no delete.

Consequences:
- `INVALID_RETURN_STATE` is **not** needed; the error catalog gains no
  state-machine code for returns.
- "Cancellation" of a mistaken return is a *new compensating document* handled
  by the same machinery in a later phase — not a Phase 12 feature.
- Append-only is therefore structural (no update path exists), satisfying
  Phase 0 rule #4.

Rejected: `draft → posted → cancelled` (Phase 11 needed that because receipts
arrive later; a POS return is instantaneous at the counter).

## 10. Linked vs. independent return — GATE 3 **RESOLVED**

**Decision: both flows, one schema, derived mode.**

| Mode | Trigger | `sale_id` | Stock | Debt | Refund ceiling |
|---|---|---|---|---|---|
| Linked (invoice-based) | `sale_id` provided | set | restore from the sale's own lines | `min(refund, remaining credit, balance)` | source-line caps (§11) |
| Independent | `sale_id` omitted | `NULL` | restore to the named product/variant | none (no sale, no customer) | `quantity > 0` only |

- Independent returns are **permitted for `POS_RETURN` holders** (cashier
  included). The `reason` field is **optional** (fix round 1, product-owner
  decision): when supplied it must come from the existing `ReturnReason`
  vocabulary (`defective`, `wrong_item`, `customer_change`, `expired`,
  `other`); `null`/blank is stored as `NULL` and an unknown supplied value is
  still 422. **Void reasons stay mandatory** (§8, GATE 15). Phase 0 rule #22
  "reason and authorization" is satisfied without inventing an approval
  table: *authorization* = the actor's `POS_RETURN` scope persisted on
  `returns.user_id` plus the `AuditAction.RETURN` audit row.
- Independent returns carry `customer_id = NULL`, touch no ledger, and their
  refund is cash-side (§18).
- Legacy defect (independent return had no ceiling) is intentionally **not**
  ported; the ceiling question for independent returns is "does the product
  exist and is qty > 0", because no sold quantity exists to cap against.

## 11. Return quantity cap / source-line limits — GATE 4 **RESOLVED**

**Decision (Phase 0 rule #1, corrected): cumulative, per source sale line, in
the sale line's own quantity unit:**

```
FOR EACH requested return line with sale_line_id = S:
    returned_before = Σ return_lines.quantity
                      WHERE sale_line_id = S            (all existing returns)
    if returned_before + qty > sale_line.quantity  →  ConflictError(
        code="RETURN_EXCEEDS_SOLD", details={sold, already_returned, requested})
```

- The cap is evaluated **inside the posting transaction with the sale row
  locked** (§19), not in the client — legacy defect.
- The cap is per `sale_line_id`, not per product: two sale lines of the same
  product in one invoice each carry their own cap, and a voided sale is
  unreachable (§16) so `unvoided` in the Phase 0 wording is enforced by
  exclusion rather than by arithmetic.
- Pack summary lines cap returned **whole packs** (§14); component lines are
  derived, never independently requestable (a return line may only reference the
  charged summary line).
- Independent returns bypass this gate by construction (§10).

## 12. Refund amount / discount conservation — GATE 5 (valuation source) + GATE 14 (conservation) **RESOLVED**

**Decision: refund is computed from persisted line economics, never from the
current catalog price.**

Per charged source line `L`:

```
already = Σ return_lines.line_total WHERE sale_line_id = L
refund_line(L, k) = L.line_total × k / L.quantity        - already-less pro-rata
```

where `k` is the quantity returned now and `L.line_total` is already net of the
line discount. Invoice-level discount is shared proportionally to the refunded
net amount:

```
subtotal   = Σ refund_line(L, k)
share      = sale.discount × subtotal / Σ charged sale_lines.line_total
refund     = subtotal - share                     (quantized to NUMERIC(18,3) at persistence)
```

Conservation invariants (enforced by tests):
- `Σ returns.total ≤ sale.total` for the life of a sale;
- returning **the whole invoice** refunds exactly `sale.total` (share collapses
  to the full `sale.discount`);
- a full return of a fully discounted line refunds `0`, and the return document
  still exists (stock moved, audit written) with `total = 0`.

Legacy defect (`amount = q × price`, ignoring discounts) is not ported.
`rounding residue ≤ 0.001` is absorbed into the last return line of the final
return, documented in the audit note.

## 13. PMP / avg_cost on return — GATE 6 **RESOLVED**

**Decision: a return restores stock and never moves PMP.**

- The return movement row still carries `unit_cost` = the sale line's historical
  `unit_cost` snapshot (so the journal explains the source of the goods) and
  `avg_cost_after` = the *unchanged* `products.avg_cost`.
- `products.avg_cost` is not recomputed: a return is not a purchase, no new
  acquisition cost enters the business, and re-weighting with a stale sale cost
  would silently revalue inventory (Phase 7 rule "increase without unit_cost
  leaves avg_cost unchanged", `PHASE_7_IMPLEMENTATION.md` L184).
- `products.cost` (nominal) is untouched. Valuation stays `quantity × avg_cost`.
- This mirrors `services/inventory.py:reverse_purchase`, which records
  `unit_cost` / `avg_cost_after` without recomputing.

Rejected: feeding the sale's unit_cost into `weighted_average_cost` (would let a
return move PMP downward on stale costs); leaving `unit_cost` NULL (loses the
explanatory snapshot the movement journal exists for).

## 14. Stock restoration targets — GATE 7 (movement typing), GATE 11 (packs), GATE 12 (variants) **RESOLVED**

**Decision — restore exactly what the sale took, in one transaction:**

| Source line kind (from `sale_lines`) | Restored | Movement row |
|---|---|---|
| Product line (`product_id` set, `pack_id` NULL, `variant_id` NULL) | `products.quantity += quantity_base` | `movement_type='return'` (or `'sale_void'`), `product_id` set |
| Variant line (`variant_id` set) | `product_variants.quantity += quantity_base` **only** | type as above, `product_id` + `variant_id` set |
| Pack summary line (`pack_id` set, `product_id` NULL) | **no stock change** (it never decremented stock) | **no movement row** |
| Pack component line (`pack_id` set, `product_id` set) | `products.quantity += restored component qty` | type as above, `product_id` set |

- **GATE 12:** variant-only restore matches Phase 8's DECIDED sale semantics
  (`services/sale.py` L1046–L1075: "variant sale decrements variant.quantity
  ONLY"). Legacy's product+variant restore (defect V7) is not ported.
- **GATE 11 (packs):** returning `k` packs restores each component by
  `per_pack × k`, where `per_pack` is **derived from the sale's own component
  line** (`component_line.quantity ÷ Σ summary lines with the same pack_id in
  that sale`), never from the current `pack_items` (composition may have changed
  since). Whole packs only: `k` must be a positive integer and `k ≤` unreturned
  summary quantity (§11). A `return_lines` row for the charged summary keeps
  `product_id = NULL`, `pack_id` set — exactly the Phase 10 summary-line shape,
  which is why `product_id` must become nullable (§5).
- **GATE 7:** movements are typed `StockMovementType.RETURN` for returns and
  `StockMovementType.SALE_VOID` for voids, with `quantity_change > 0`,
  `quantity_before/after` captured around the update (same guarded
  `UPDATE … WHERE quantity >= 0` style as `_decrement_stock`, but inverted —
  increments never need the guard), `source_document_type`/`source_document_id`
  = the return id / sale id.
- Stock is restored **unconditionally** (an increment cannot oversell); the only
  failure modes are unknown ids (404) and concurrency on the same row, which the
  row lock (§19) resolves.

## 15. Quantity units and snapshots — GATE 13 **RESOLVED**

**Decision: returns speak the sale line's historical selling unit; stock moves
in base units.**

- `return_lines.quantity` is expressed in the unit printed on the source
  `sale_line` (`selling_unit_name` + `selling_unit_multiplier` snapshots are
  copied onto the return line, `product_unit` stays the base-unit snapshot).
- `return_lines.quantity_base = quantity × selling_unit_multiplier` (multiplier
  `NULL` ⇒ `quantity_base = quantity`), computed with `Decimal` and quantized to
  `NUMERIC(18,3)`; **stock updates use `quantity_base` only**.
- The multiplier is read from the sale line snapshot, never from the catalog
  (Phase 8 rule: historical values survive renames/multiplier changes).
- Validation: `quantity > 0`, and for whole-piece units `quantity` must be a
  positive integer (mirrors legacy's piece check and the Phase 8 quantity
  validation), while pack returns are always whole packs (§14).
- Pack component lines are not user-entered, so their `quantity_base` equals
  the derived component quantity.

Rejected: asking the operator for a unit (Phase 7 removed unit selectors from
adjust for the same reason); recomputing from `products.base_unit` (would
restate history).

## 16. Void <-> return mutual exclusion — GATE 10 **RESOLVED**

**Decision: strict, both directions.**

1. A **voided sale cannot be returned**: `sale.status == 'void'` →
   `ConflictError(code="SALE_ALREADY_VOID")` on `POST /returns` with `sale_id`.
2. A **sale with any return cannot be voided**: Σ `return_lines` referencing the
   sale > 0 → `ConflictError(code="SALE_HAS_RETURNS")` with the list of return
   numbers in `details`.

Rationale: both operations restore the same stock and reverse the same debt;
allowing both would double-restore and double-reverse. The check runs inside
the void transaction with the sale row locked, so it cannot race (§19).

Rejected: *allow void after returns, minus already-returned quantities* (correct
arithmetically but doubles the failure surface, and the operator's mental model
"is this invoice dead or partially refunded" stays unambiguous only if the two
are exclusive).

## 17. Customer balance / debt reversal — GATE 8 **RESOLVED**

**Decision — mirror Phase 11's capped reversal exactly
(`services/purchases.py` L496–L540), with a new compensating entry type.**

Let, for sale `S`:

```
credit(S)        = Σ debt_ledger_entries.amount
                   WHERE entry_type='sale' AND reference_sale_id = S
reversed(S)      = Σ debt_ledger_entries.amount
                   WHERE entry_type IN ('sale_void','sale_refund')
                     AND reference_sale_id = S
```

**Void:** `due = credit(S)`, `reverse = min(due, customers.balance)`.
**Return:** `due = refund_total`, capped further by the sale's remaining credit
`credit(S) − reversed(S)`: `reverse = min(refund_total, credit(S) − reversed(S),
customers.balance)`.

- One `debt_ledger_entries` row is appended: `entry_type = 'sale_void'` /
  `'sale_refund'`, `amount = reverse`, `reference_sale_id = S`,
  `user_id = actor`, `client_request_id = NULL` (void) / the return's key,
  `note` = human-readable reason.
- `customers.balance -= reverse` in the same transaction; then the in-transaction
  reconciliation `ledger_sum_for_customer(customer) == customers.balance`
  raises `ConflictError` on mismatch — the Phase 11 §13 pattern.
- **Shortfall is never silent:** `shortfall = due − reverse` (goods paid for in
  cash, or credit already settled by later payments) is written into the ledger
  `note` and into the audit `details`, and is reported as *pending cash refund*
  (§18). Balance can never go negative, preserving Phase 9's "no advance credit"
  rule.
- Read models updated (2 lines each, exactly like Phase 11's supplier ledger):
  `repositories/debt.py:balance_after_map` L86–L89 →
  `elif entry_type in ("payment", "sale_void", "sale_refund"): running -= value`,
  and `ledger_sum_for_customer` L108 →
  `sale − payment − sale_void − sale_refund`. This is a documented Phase 9
  read-model extension, precedented by Phase 11's `purchase_cancel`.

Rejected alternatives: *negative `sale` entries* (silently corrupts every
"credit sales total" report); *reuse `payment`* (a refund is not a payment and
would appear as one in customer history); *allow negative balance* (contradicts
Phase 9); *no ledger entry at all* (breaks the reconciliation identity).

## 18. Cash refund / drawer / payment split / tax — GATE 20 **DEFERRED**

**Decision: DEFERRED — Phase 12 records the refund due and reverses only the
debt portion.**

- Cash/card refund execution, cash-drawer effect, payment-split reversal and
  tax handling are **UNVERIFIED** by Phase 0 rule #7 (`PHASE_0_BUSINESS_RULES.md`
  L28) and require product-owner approval; Phase 0 rule #7 explicitly forbids
  implementing them first.
- Phase 12 therefore: computes `refund_total` (§12), reverses `reverse` (§17),
  stores `refund_due − reverse` as *pending cash refund* (derivable: no new
  account is invented), and exposes it on the return/void response.
- Independent returns (no customer, no debt) are 100% pending cash refund.
- Sale tax does not exist in the model (`sales` has `subtotal/discount/total`
  only) → no tax to reverse; tax remains UNVERIFIED for a later phase.
- Cash-drawer settlement will be implemented when Phase 0 rule #7 is approved,
  against the already-persisted `returns` / void rows — no schema change later.

This is the only top-level gate that is **DEFERRED**, and it does not block
Step B: every Phase 12 deliverable above is implementable without it.

## 19. Concurrency, idempotency, atomicity — GATE 16 (idempotency), GATE 17 (concurrency) **RESOLVED**

**Atomicity:** one `transaction()` per operation; any failure rolls back
document, lines, stock, movements, ledger and audit together. No partial state
is possible.

**Locking (GATE 17):**
1. `SaleRepository.get_for_update(sale_id)` (new method, additive) — sale row
   first, so §11/§16 checks and the status transition serialize.
2. Customer row via `PartyRepository.get_for_update` when a debt reversal
   applies (already exists).
3. Affected `Product` / `ProductVariant` rows locked in a deterministic
   `ORDER BY id` order before the increments (avoids deadlocks with a
   concurrent `create_sale` that locks the same rows).
4. Integration test in the established style: PostgreSQL subprocess with
   `DATABASE_URL=...` (`tests/integration/test_*_concurrency.py`), skipped when
   `supermarket_pro_test` is unavailable — two concurrent returns of the same
   source line, and a void racing a return.

**Idempotency (GATE 16):**

| Operation | Key | Repeat behavior |
|---|---|---|
| `POST /returns` | required `client_request_id` (unique on `returns`) | replay returns the original document with `idempotent_replay=true`; unique-race → rollback → re-fetch winner (exact `create_sale` L751–L951 pattern) |
| `POST /sales/{id}/void` | none needed — `sale_id` is the natural key | second call → `409 SALE_ALREADY_VOID` (Phase 11 `_require_status` mirror); the client treats 409-on-void as "already done" and refreshes |

## 20. Permissions & approval — GATE 15 **RESOLVED (no new scopes)**

**Decision: reuse the two scopes that already exist. No enum additions.**

| Operation | Scope | admin | manager | cashier |
|---|---|---:|---:|---:|
| Void an invoice | `POS_VOID` (`enums.py` L25) | yes | yes | **no** |
| Independent return | `POS_RETURN` (`enums.py` L26) | yes | yes | **yes** |
| Linked (invoice) return | `POS_RETURN` | yes | yes | **yes** |

- Enforced server-side with `Depends(require_permission(PermissionScope.POS_VOID
  | POS_RETURN))` (`api/dependencies.py` L106); enforced client-side with
  `hasPermissionProvider('pos_void' | 'pos_return')`
  (`lib/features/auth/permission_helpers.dart`).
- `core/seed.py` L36–L37 / L67 already grants exactly this (manager: both,
  cashier: `POS_RETURN` only). **No reseed required.**
- `len(PermissionScope) == 27` (`tests/unit/test_enums.py` L45) stays true →
  no test edit, no seed edit, no migration of role permissions.
- **Divergence documented for the product owner:** Phase 0's *proposal* matrix
  (L36) says cashier "no" for independent return and manager "approval" for
  void. The shipped seed (Phase 2) grants cashier `POS_RETURN` and manager an
  unguarded `POS_VOID`. Decision: **keep the shipped seed** — legacy POS exposed
  an independent-return button to any logged-in operator (main_window L8398) and
  a manager-level void is the operational minimum for a supermarket counter.
  The divergence is listed in §24 risks and checked in §25 human QA.
- **DEFERRED sub-item:** a PIN step-up / second-approver confirmation for void.
  No server-side mechanism exists to bind an approval to a mutation
  (`POST /api/v1/auth/reauth` merely re-verifies the *current* user's PIN and
  carries no proof into the mutation), so inventing one would be a new auth
  design, not a Phase 12 feature. Phase 12 compensates with: mandatory typed
  reason + confirm dialog + `voided_by` + audit row. Tracked as a deferred
  sub-item of GATE 15 (not a blocking gate).

## 21. Audit, movements and error catalog — GATE 18 **RESOLVED (no enum expansion)**

**Audit:** one row per operation — `AuditAction.VOID` for voids,
`AuditAction.RETURN` for returns (both already exist, `enums.py`), with
`entity_type` = `sale` / `return`, `entity_id`, and structured `details`
(invoice/return number, lines, quantities, `refund_total`, `credit_reversed`,
shortfall, reason). Actor comes from `user.device_id`-style context already used
by `services/*._audit`.

**Movements:** `StockMovementType.SALE_VOID` (void) and `.RETURN` (return)
already exist and are already asserted (`test_enums.py` L85, L88). One row per
restored stock line; pack summary lines produce none (§14).

**Pack-ness is derived, not typed:** a `return` movement's pack-ness comes from
joining `source_document_id → return_lines.pack_id`; a `sale_void` movement's
from `sale_lines`. **Rejected alternative `PACK_RETURN`:** it would expand
`StockMovementType`, force edits to Phase 2's `test_enums.py`, and add a third
display path — for information already present in the linked row.

**Flutter movement labels:** `stock_screen.dart` L29–L52 already maps `sale_void`
→ `movement_sale` and `return` → `movement_return`; Step B will add a distinct
`movement_sale_void` key (3 locales) so voids read as "Void", not "Sale".

**Error catalog (new `code=` values, all with `message_key` for Flutter):**

| Code | HTTP | Raised when |
|---|---:|---|
| `SALE_ALREADY_VOID` | 409 | void twice, or return against a voided sale |
| `SALE_NOT_VOIDABLE` | 409 | void on a non-completed sale |
| `SALE_HAS_RETURNS` | 409 | void on a sale with returns |
| `RETURN_EXCEEDS_SOLD` | 409 | cumulative source-line cap exceeded (§11) |
| `RETURN_EXCEEDS_REMAINING_CREDIT` | 409 | (reserved; the cap is a note, not a failure — see §17) |
| `RETURN_PACK_NOT_WHOLE` | 422 | non-integer pack quantity |
| `RETURN_LINE_INVALID` | 422 | line references a component line or nothing (independent) |
| `IDEMPOTENCY_CONFLICT` | 409 | replay key reuse with a different payload |

Existing generic classes are reused (`ConflictError` 409, `BusinessRuleError`
422, `AuthorizationError` 403) — no change to `core/exceptions.py` beyond new
`code=` values at the raise sites.

## 22. API contracts (derived, not copied) + backend files (LIST ONLY)

Contracts follow `PHASE_0_API_BLUEPRINT.md`; shapes follow Phase 8/11
conventions (`StrictBaseModel`, Decimal strings for money/qty, envelope error).

| Method | Path | Permission | Notes |
|---|---|---|---|
| `POST` | `/api/v1/sales/{sale_id}/void` | `POS_VOID` | Body `{ "reason": non-blank }`, header `X-Device-ID`; 200 `{ sale, credit_reversed, refund_due, cash_pending }` |
| `POST` | `/api/v1/returns` | `POS_RETURN` | Body `{ client_request_id (required), sale_id?, customer_id?, reason? (optional: omitted / null / blank ⇒ NULL), note?, lines: [{ sale_line_id?, product_id?, variant_id?, pack_id?, quantity }] (1..200 lines), device }`; 201 `{ return, idempotent_replay, refund_total, credit_reversed, cash_pending }` |
| `GET` | `/api/v1/returns` | `POS_RETURN` (read) | Filters: `page`, `page_size`, `sale_id`, `invoice_number`, `from`, `to`, `reason` |
| `GET` | `/api/v1/returns/{return_id}` | `POS_RETURN` (read) | Header + lines |
| `GET` | `/api/v1/sales/{sale_id}` | existing | gains void fields in the response |

**Reason rules (fix round 1):** on `POST /api/v1/returns` the `reason` is
**optional** — omitted, `null` and blank all mean "no reason" and persist as
`NULL`; a *supplied* reason must still belong to the supported vocabulary
(`defective`, `wrong_item`, `customer_change`, `expired`, `other`), otherwise
422. On `POST /api/v1/sales/{sale_id}/void` the `reason` remains
**mandatory** and non-blank (422), unchanged.

**Backend files to create (list only — written at Step B):**

```
new_app/backend/app/services/returns.py        # ReturnService (post/list/get)
new_app/backend/app/services/void.py           # VoidService (or a SaleService.void method)
new_app/backend/app/repositories/returns.py    # ReturnRepository (+ get_for_update for sales lives in sale.py)
new_app/backend/app/schemas/returns.py         # request/response models
new_app/backend/app/api/v1/returns.py          # returns_router
new_app/backend/migrations/versions/..._0016_phase12_returns_voids.py
new_app/backend/migrations/versions/..._0017_return_reason_optional.py  # fix round 1
new_app/backend/tests/unit/test_returns.py
new_app/backend/tests/unit/test_void.py
new_app/backend/tests/integration/test_return_concurrency.py
```

**Backend files to modify (list only):**

```
app/models/sale.py            (+3 columns)        app/models/return_doc.py       (+7 cols, product_id nullable)
app/repositories/sale.py      (+get_for_update)   app/repositories/debt.py       (2-line algebra, §17)
app/api/v1/router.py          (+returns_router)   app/api/v1/pos.py              (+void route) or api/v1/sales.py
```

**Status: IMPLEMENTED** (Step B) — see `PHASE_12_IMPLEMENTATION.md`.

## 23. Flutter UI workflow and localization — GATE 21 (localization), GATE 22 (workflow) **RESOLVED**

**GATE 21 (localization):** every new user-visible string is added to
`lib/core/strings.dart` in **all three** maps (`_arabic`, `_french`, `_english`)
— `AppStrings.t` falls back to the raw key, so a missing key would render
`entry_type_sale_void` literally on screen. RTL-safe layouts (Arabic is the
default locale), keys registered in `test/unit/pos_localization_test.dart`
(same `const keys = [...]` pattern).

New key groups (names fixed here so Step B/C don't rename):

```
void_invoice, void_confirm, void_reason_label, void_reason_required, void_success,
return_title, return_mode_linked, return_mode_independent, return_search_invoice,
return_lines, return_refund_total, return_credit_reversed, return_cash_pending,
return_reason_*, return_qty_exceeds_sold, return_whole_packs_only,
returns_history, no_returns, entry_type_sale_void, entry_type_sale_refund,
movement_sale_void, error_sale_already_void, error_sale_has_returns,
error_return_exceeds_sold, error_return_pack_not_whole, ...
```

Fix round 1 additions (14 keys, all three locales):

```
return_products, return_scan_product, return_selected_products,
return_sold_quantity, return_returnable, return_fully_returned,
return_qty_label, return_remove, return_add_product, return_no_products,
return_product_not_found, return_scan_merged, return_reason_optional,
return_reason_none
```

(`return_reason_optional` replaces `return_reason_required` in both return
dialogs; `void_reason_required` is untouched — void keeps its mandatory
reason.)

**GATE 22 (workflow):**

| Flow | Entry point | Steps |
|---|---|---|
| Void | Invoice detail from Sale History (`sale_detail_dialog.dart`) — button shown only with `hasPermissionProvider('pos_void')` | Confirm dialog → **mandatory** typed reason → `POST /sales/{id}/void` → localized result via `pos_error_message.dart` code map → refresh history |
| Linked return | Sale detail "Return items" (permission `pos_return`) from Sale History | Load invoice → per-line **Sold / Already returned / Returnable** → editable qty **defaulted to the remaining returnable** (0 + disabled when fully returned) → **optional** reason → submit → refund split (refund / credit reversed / cash pending) rendered from the 201 response |
| Independent return | **Returns screen → "Return Products"** (fix round 1; permission `pos_return`) | Scan/barcode or search a product → add N lines (re-scan **merges** and increments) → edit qty / remove line → **optional** reason → one submit → **one** return document with N `return_lines` |
| Returns list | Sales area (new route `/returns`) | Paginated list + detail; voided invoices flagged |

*Correction (fix round 1):* the earlier wording "POS header **Return**"
describing both return flows is superseded — there is **no POS-header
button**. The Returns screen is the canonical entry point and must expose an
obvious **Return Products** action (plus the invoice-level return from the
sale detail dialog). Entry points are gated by `pos_return` only; no new
permission scope exists.

Routing: a new `/returns` route beside the placeholder `/sales`
(`app_router.dart`, `salesSaleScope` pattern), navigation guarded by
`pos_return`.

**Flutter files to create/modify (LIST ONLY):**

```
new_app/lib/features/returns/returns_screen.dart        # list + filters + Return Products action
new_app/lib/features/returns/return_create_dialog.dart  # linked (invoice) return
new_app/lib/features/returns/return_products_dialog.dart # fix round 1: independent multi-product return
new_app/lib/features/returns/return_detail_dialog.dart
new_app/lib/features/returns/return_models.dart         # doc/line models + search & barcode candidates
new_app/lib/features/returns/return_providers.dart      # Riverpod + ReturnsApi (search / barcode / post)
new_app/lib/features/returns/return_error_message.dart  # or extend pos_error_message.dart
new_app/lib/features/returns/return_void_dialog.dart
new_app/lib/core/strings.dart                           # +68 keys × 3 locales (14 of them fix round 1)
new_app/lib/router/app_router.dart                      # /returns route
new_app/lib/features/pos/sale_detail_dialog.dart        # void + return buttons
new_app/test/unit/returns_localization_test.dart
new_app/test/unit/return_error_message_test.dart
new_app/test/widget/returns_screen_test.dart
new_app/test/widget/return_create_dialog_test.dart      # fix round 1: remaining-qty defaults
new_app/test/widget/return_products_dialog_test.dart    # fix round 1: multi-product workflow
```

**Status: IMPLEMENTED** (Step C) — see `PHASE_12_IMPLEMENTATION.md`.

## 24. Reporting readiness — GATE 19 **RESOLVED (data only)** + gate summary + risks

**GATE 19:** all report inputs become queryable in Phase 12 with **data only**;
no report UI is built now (Phase 14 owns dashboards/reports).

- Returns report: `returns` × `return_lines` (number, invoice, reason, user,
  device, `subtotal`/`discount`/`total`, dates) — covers the legacy
  `_render_returns_voids_tab` columns (L14889) plus reason/actor.
- Voids report: `sales WHERE status='void'` with `voided_at/voided_by/void_reason`
  and untouched snapshot totals — strictly more than legacy, which zeroed them.
- `returns_total` for `net_sales` (legacy `get_financial_report`) = `SUM(returns.total)`.
- Stock journal: `movement_type IN ('return','sale_void')` with pack-ness
  derivable (§21).

### Decision-gate summary (22 gates)

| Gate | Topic | Status |
|---|---|---|
| 1 | Void lifecycle (terminal, no unvoid) | **RESOLVED** |
| 2 | Return lifecycle (no draft/cancel) | **RESOLVED** |
| 3 | Linked vs independent return | **RESOLVED** |
| 4 | Cumulative per-source-line quantity cap | **RESOLVED** |
| 5 | Refund valuation from persisted line economics | **RESOLVED** |
| 6 | PMP / avg_cost on return | **RESOLVED** |
| 7 | Movement typing for restorations | **RESOLVED** |
| 8 | Debt / balance reversal (capped, shortfall noted) | **RESOLVED** |
| 9 | Void record fields / financial snapshot | **RESOLVED** |
| 10 | Void <-> return mutual exclusion | **RESOLVED** |
| 11 | Pack return (whole packs, historical components) | **RESOLVED** |
| 12 | Variant return (variant stock only) | **RESOLVED** |
| 13 | Selling-unit snapshots / base-qty math | **RESOLVED** |
| 14 | Refund + invoice-discount conservation | **RESOLVED** |
| 15 | Permissions & approval | **RESOLVED** (PIN step-up approval **DEFERRED** sub-item) |
| 16 | Idempotency | **RESOLVED** |
| 17 | Concurrency / locking | **RESOLVED** |
| 18 | Audit / movement / error enums | **RESOLVED** (no enum expansion) |
| 19 | Reporting readiness | **RESOLVED (data only)** |
| 20 | Cash refund / drawer / payment split / tax | **DEFERRED** (Phase 0 rule #7) |
| 21 | Localization (ar/fr/en parity) | **RESOLVED** |
| 22 | Flutter UI workflow | **RESOLVED** |

**Totals: 22 gates — 21 RESOLVED, 1 DEFERRED, 0 UNRESOLVED (blocking: 0).**
Deferred items: (a) GATE 20 cash-refund execution / drawer / tax, (b) GATE 15
PIN step-up approval sub-item.

### Critical risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Pooled customer balance lets a return of a *paid* sale forgive another sale's credit | Cap by `min(refund, credit(S) − reversed(S), balance)` and write the shortfall into the note (§17); flagged in human QA |
| R2 | Pack component attribution when the same pack appears on two cart lines | Derivation uses the sale-group total (§14); unit test covers duplicate pack lines and a changed pack composition across two sales |
| R3 | Phase 9 read-model change (`debt.py`) crosses phase ownership | Two-line, exactly precedented by Phase 11 `purchase_cancel`; reconciliation test included |
| R4 | Non-integer refunds from pro-rata division | Quantize at persistence `NUMERIC(18,3)`, residue rule in §12, conservation tests |
| R5 | Two racing returns consuming the same source line | Row lock + cumulative cap in-transaction + Postgres concurrency test (§19) |
| R6 | Seed/Phase-0-matrix divergence on cashier returns / manager void | Documented (§20), confirmed in human QA with the product owner |
| R7 | `return_lines.product_id` nullability change | Additive `ALTER`; existing rows unaffected; `test_models.py` table assertions unchanged |
| R8 | Legacy habits (zeroing totals, `paid_amount` reversal, double restore) leaking into Step B | Explicitly rejected in §2, §8, §14; code review checklist in §25 |

### Out of scope (phase boundary)

Cash/card refund execution and cash drawer (Phase 0 rule #7), tax, return
cancellation/reversal documents, un-void, PIN step-up approval, report UI and
dashboards (Phase 14), variant-level PMP, expense-side effects, offline
conflict resolution for returns.

## 25. Human QA plan — PASS (2026-09-29)

Run after Step C, on Windows, with the seeded `admin` / `manager` / `cashier`
accounts and the Phase 8→11 feature set intact.

1. **Void happy path (manager):** sale with 2 product lines + 1 variant line +
   1 pack line → void → stock restored exactly (variant only, pack components
   only, pack summary untouched), `sale_void` movement rows present with correct
   before/after, `status='void'`, totals **unchanged**, reason/actor recorded,
   debt reduced, history shows VOID badge.
2. **Void authorization (cashier):** cashier sees no void button; direct API call
   → 403 `FORBIDDEN`/`AUTHORIZATION_ERROR`; audit shows the denied attempt if
   applicable.
3. **Void guards:** void twice → 409 `SALE_ALREADY_VOID` and stock unchanged the
   second time; void a sale with a return → 409 `SALE_HAS_RETURNS`; empty reason
   → 422.
4. **Linked return happy path (AR/FR/EN):** partial return of a discounted
   multi-line invoice → refund = pro-rata line net + invoice-discount share;
   full return of the whole invoice → refund equals the invoice total exactly;
   stock restored in the sale's selling unit → base units; PMP unchanged.
5. **Ceiling:** attempt to return more than sold, more than the remaining
   unreturned qty, and a component line directly → 409 `RETURN_EXCEEDS_SOLD` /
   422 `RETURN_LINE_INVALID`, nothing persisted.
6. **Pack return:** return 1 pack → only its components restored, quantities
   taken from that sale's historical component lines; non-integer pack qty → 422;
   two pack lines of the same pack in one invoice → correct attribution.
7. **Variant return:** only `variant.quantity` changes; parent product quantity
   untouched (regression against legacy defect V7).
8. **Debt reversal:** credit sale partially paid → void/return reduces balance by
   the capped amount, shortfall appears in the ledger note, `customers.balance`
   equals `ledger_sum_for_customer` afterwards; cash sale → no debt change, cash
   pending shown.
9. **Mutual exclusion:** return then void (blocked), void then return (blocked).
10. **Idempotency/concurrency:** double-submit the same `client_request_id` → one
    return document; two operators return the same last unit simultaneously →
    exactly one succeeds (Postgres test).
11. **Independent return:** cashier performs one **with** a reason and one
    **without** any reason → both 201; the reason-less document stores
    `reason = NULL`; stock increases; no ledger entry; audit row present;
    product-not-found → 404. Multi-product variant: two scans of the same
    product merge into one line, a second product adds a second line, one
    submit produces **one** return document with two `return_lines`.
12. **Localization:** every new screen/dialog in ar (RTL), fr, en; no raw keys on
    screen; movement journal shows "Void"/"Retour"/"إلغاء"; debt history shows
    the new entry types translated.
13. **Regression:** backend suite green (790 at fix round 1), Flutter green
    (1010 at fix round 1), `flutter analyze` clean, `alembic upgrade head` +
    `downgrade` pass, Windows build passes, Phase 11 purchase/supplier flows
    untouched.
14. **Product-owner sign-off:** the two divergences (§20 cashier return grant,
    manager void without PIN step-up) and the deferred cash-refund scope (§18).
15. **Fix round 1 — Return Products:** Returns → *Return Products* → scan A,
    scan A again (merge → qty 2), search B, submit with **no reason** → one
    document, two lines, correct stock restore; variant barcode restores
    variant stock only.
16. **Fix round 1 — invoice quantity defaults:** open a multi-line invoice →
    each line defaults to its **remaining returnable** quantity; a previously
    partially returned line defaults to the remainder; a fully returned line
    starts at 0 and disabled; reduce one quantity and submit with no reason →
    correct partial return and refund (server caps still enforced).

*Status 2026-09-29 — **HUMAN QA: PASS.** The API-level equivalents of items
11, 15 and 16 were executed against a live backend with a real login — all
checks green (`PHASE_12_IMPLEMENTATION.md` §7.6) — and the product owner then
ran this whole plan including the click-through steps (A, B, I, J) on
Windows: **all 14 QA areas passed** (items 1–14), fix round 1 verified
(items 15–16), and the result-dialog routing fix was manually verified.
No remaining blocking issues.*

---

## 26. Fix round 1 — product-owner UX changes (2026-09-29)

Recorded here because they amend **UX and one column**, not the decision
gates: every gate in §24 stays as resolved, and the backend remains the
authoritative implementation of caps, refunds, restoration, idempotency and
locking.

| # | Change | Where it landed | What did **not** change |
|---|---|---|---|
| **A** | Dedicated **"Return Products"** workflow: scan/barcode or search products, add N lines to the selection, edit/remove lines, submit **one** independent return document containing N `return_lines` | `returns_screen.dart` (`returns-return-products`), `return_products_dialog.dart`, `ReturnsApi.searchProducts` / `barcodeLookup` | Independent semantics: `sale_id` NULL, `customer_id` NULL, no debt entry, `movement_type = RETURN`, audit `RETURN`, `quantity > 0`, unknown product → 404, no current-sale-line ceiling, variant line restores variant stock only |
| **A2** | Repeated scan/search of the same product/variant **merges** into the existing line and increments its quantity (never a duplicate line, never one document per product); unknown barcode → localized not-found feedback | `_addProduct` / `_handleScan` in `return_products_dialog.dart` | Product existence and stock restoration stay backend-authoritative; a return is not a sale, so current stock is never validated on the way in |
| **B** | Linked/invoice return quantity **defaults to the remaining returnable quantity** (`sold − already_returned`), with Sold / Already returned / Returnable shown per line; fully returned → 0 and disabled | `return_create_dialog.dart` (`_initializeQuantities`, `_remaining`) | Backend caps (`RETURN_EXCEEDS_SOLD`, cumulative source-line caps, pack whole-only, mutual exclusion, refund valuation) — the default is convenience only and is never auto-submitted |
| **C** | Return reason is **optional** for linked *and* independent returns: omitted / `null` / blank → `NULL`; no fake default reason | `app/schemas/returns.py` (`_optional_reason`), migration `0017`, both Flutter dialogs | A *supplied* reason is still vocabulary-checked (422 otherwise); **void reason stays mandatory and non-blank** (422), `void_reason_required` untouched |
| **D** | Localization for all of the above in ar / fr / en (14 new keys × 3), Arabic RTL | `lib/core/strings.dart`, `returns_localization_test.dart` | No hardcoded user-facing strings; `pos_return` / `pos_void` scopes unchanged |

**Two old statements corrected:**

1. *"Independent returns must carry a reason."* — superseded. Rule #1 in
   `PHASE_0_BUSINESS_RULES.md` is resolved as: the reason is **optional**
   (Phase 12 fix round 1 product-owner decision); *authorization* = the
   actor's `POS_RETURN` scope on `returns.user_id` + the `AuditAction.RETURN`
   audit row (§10). Void reasons remain mandatory (§8).
2. *"No POS-header button."* — refined: there is still no button on the POS
   header, **but** the Returns feature must expose an obvious product-return
   entry point. That entry point is now the visible **Return Products**
   action on the Returns screen (`returns-return-products`), with invoice
   returns still entered from the sale detail dialog.

**Schema:** migration `2026_09_28_1200_f5a6b7c8d9e0_0017_return_reason_optional`
drops `NOT NULL` and the `'other'` server default from `returns.reason`
(head `f5a6b7c8d9e0`, applied to the dev database `supermarket_pro`).
Existing rows keep their stored reason; no data is rewritten; `downgrade`
refuses to re-impose `NOT NULL` while any row is NULL (asserted by
`TestPhase17ReturnReasonOptionalMigration`).

**Tests added/extended:** backend `test_returns.py` (26 → 35: no-reason
linked + independent 201, `null`/blank/omitted accepted, valid reason
persisted, invalid reason still 422, void without reason still 422,
multi-line independent document, idempotent replay in short and persisted
quantity forms), `test_migrations.py` (+3 for 0017);
Flutter `return_products_dialog_test.dart` (10),
`return_create_dialog_test.dart` (8), `returns_screen_test.dart` (Return
Products entry + RBAC + 2 result-dialog close regression tests),
`returns_localization_test.dart` (14-key fix-round-1 block, ar/fr/en).

**Defect found and fixed during verification:** an exact `POST /returns`
replay typed with a short quantity (`2` instead of `2.000`) returned 409
`IDEMPOTENCY_CONFLICT` instead of replaying, because `_line_signature`
compared raw `str(Decimal)` text. Fixed by normalizing the quantity in
`ReturnService._qty_key`; same-key/different-payload still returns 409.
Full record: `PHASE_12_IMPLEMENTATION.md` §7.7.

**UI defect found and fixed:** closing the return **result dialog** threw
`You have popped the last page off of the stack` / `'!_debugLocked' is not
true` from `returns_screen.dart:95`. `showDialog` pushes on the root
navigator, but with a `ShellRoute` go_router nests a second Navigator for the
shell's child pages, so popping with the **screen's** context popped the
`/returns` page instead of the dialog. Fixed by closing through the dialog's
own builder context with an `isCurrent` guard (one pop, no route change, no
double-tap fall-through); +2 widget regression tests. Full record:
`PHASE_12_IMPLEMENTATION.md` §7.8.

**Verification:** `pytest -q` 790 passed · targeted Phase 12 103 passed ·
`ruff check app` 64 (no new errors) · `flutter analyze` clean ·
`flutter test` 1010 passed · `flutter build windows --debug` built ·
live smoke A–O (API level, real login) **ALL CHECKS PASSED** → recorded in
`PHASE_12_IMPLEMENTATION.md` §7.6/§7.7/§7.8.

**Status: CLOSED / APPROVED — TECHNICAL VERIFICATION PASS — HUMAN QA PASS.**

---

**STATUS: CLOSED / APPROVED — DECISION RECORD + FIX ROUND 1 VERIFIED**
**HUMAN QA: PASS (14/14 areas) · TECHNICAL VERIFICATION: PASS · GIT: COMMITTED
(`phase-12: complete returns and voids`)**
