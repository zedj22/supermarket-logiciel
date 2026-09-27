# Phase 11 Implementation - Purchases & Suppliers

> Decision record: `docs/PHASE_11_PURCHASES_ANALYSIS.md` (20 sections, 22 gates,
> all RESOLVED or explicitly DEFERRED). This document records what shipped.
> **Status: APPROVED / CLOSED — Human QA PASS (re-verification passed),
> commit `phase-11: complete purchases and suppliers`.**

## 1. Objective & Scope

Complete the purchase/supplier domain end to end:

- **Suppliers**: CRUD + soft archive + append-only payables ledger + payments.
- **Purchases**: lifecycle `draft → received → cancelled` with atomic receive
  (stock + PMP + movements + payable + audit in one transaction) and symmetric
  cancellation reversal.
- **PMP** moves only on receive (`weighted_average_cost`), never on cancel.
- **No new permission scopes** (GATE 19): `supplier_view`, `supplier_manage`,
  `purchase_view`, `purchase_create`, `purchase_delete` only.
- Flutter: `/suppliers` and `/purchases` destinations + full workflows.

Out of scope (deferred, §21 of the decision record): per-invoice payment
allocation, payment-method taxonomy, variant-level PMP, PMP rewind on cancel,
credit notes, report screens (Phase 14).

## 2. Decision gates - what shipped

| Gate | Resolution |
|---|---|
| GATE 4 document units | `quantity` = packages when `purchase_unit_id` set (whole packages only), else base units; `unit_cost` per document unit |
| GATE 5 totals | `subtotal = Σ line_total`, `total = subtotal - discount`, `paid ≤ total` enforced |
| GATE 9 product cost | receive sets `product.cost :=` latest base unit cost; `avg_cost` = PMP |
| GATE 10 payables | new `supplier_ledger_entries` (append-only); `suppliers.balance` cached projection |
| GATE 12 cancel | reversal NEVER changes `avg_cost`/`cost` |
| GATE 13 cancel payable | `purchase_cancel` amount = `min(total - paid, current balance)` |
| GATE 14 tax | DEFERRED (no tax lines) |
| GATE 15 snapshots | existing `purchase_lines` snapshot columns used as-is |
| GATE 16 archive | archived suppliers do NOT block create/receive; only payments reject them |
| GATE 19 RBAC | no new scopes (asserted: `len(PermissionScope) == 27`) |
| Lifecycle | `draft → received → cancelled`; drafts hard-deletable (audited); received only cancellable |
| Idempotency | create: `client_request_id` + race replay; receive: `FOR UPDATE` state guard → 409 |

## 3. Backend

### 3.1 New files

- `app/models/supplier_ledger.py` - `SupplierLedgerEntry` (append-only).
- `app/schemas/purchase.py` - request/response schemas (Decimal money).
- `app/repositories/purchase.py` - `PurchaseRepository`,
  `SupplierLedgerEntryRepository` (history, `client_request_id` replay,
  `balance_after_map`, `ledger_sum_for_supplier`).
- `app/services/purchases.py` - `PurchaseService` (create/update/receive/
  cancel/delete + `to_response`).
- `app/services/suppliers.py` - `SupplierService` (CRUD/archive/audit).
- `app/services/supplier_ledger.py` - `SupplierLedgerService` (payments,
  mirrors `debt.py` semantics incl. idempotent replay).
- `app/api/v1/suppliers.py`, `app/api/v1/purchases.py` - routers.
- `migrations/versions/2026_09_27_1400_d3e4f5a6b7c8_0015_phase11_purchases_suppliers.py`
  - adds `suppliers` contact columns, `purchases.status/client_request_id/
  received_at/cancelled_at`, `supplier_ledger_entries` table.

### 3.2 Modified files

- `app/models/party.py` - `Supplier` += `email`/`contact_person`/`notes`/
  `ledger_entries`.
- `app/models/purchase.py` - `status`/`client_request_id`/`received_at`/
  `cancelled_at`; status index.
- `app/models/enums.py` - `PurchaseStatus`, `AuditAction.RECEIVE`.
- `app/schemas/party.py` - supplier + ledger + payment schemas.
- `app/repositories/party.py` - `SupplierRepository`.
- `app/services/inventory.py` - `receive_purchase`/`reverse_purchase`
  (transaction-free; run under the caller's transaction; lock order
  purchase → products → variants → supplier).
- `app/api/v1/router.py` - both routers registered.

### 3.3 Endpoints

| Method | Path | Scope |
|---|---|---|
| GET | `/suppliers?page&page_size&q&include_archived` | `supplier_view` |
| POST | `/suppliers` | `supplier_manage` |
| GET/PUT | `/suppliers/{id}` | `supplier_view` / `supplier_manage` |
| DELETE | `/suppliers/{id}` (archive, 409 on balance≠0) | `supplier_manage` |
| GET | `/suppliers/{id}/ledger` | `supplier_view` |
| POST | `/suppliers/{id}/payments` | `supplier_manage` |
| GET | `/purchases?page&page_size&q&status&supplier_id` | `purchase_view` |
| POST | `/purchases` (`receive=true` atomic / `false` draft) | `purchase_create` |
| GET | `/purchases/{id}` | `purchase_view` |
| PUT | `/purchases/{id}` (draft only) | `purchase_create` |
| POST | `/purchases/{id}/receive` | `purchase_create` |
| POST | `/purchases/{id}/cancel` | `purchase_delete` |
| DELETE | `/purchases/{id}` (draft hard delete, 204) | `purchase_delete` |

### 3.4 Error catalog (codes introduced by Phase 11)

`PURCHASE_ALREADY_RECEIVED` (409), `PURCHASE_ALREADY_CANCELLED` (409),
`INVALID_PURCHASE_STATE` (409), `PURCHASE_LINE_INVALID` (422),
`OUTSTANDING_SUPPLIER_BALANCE` (409), `SUPPLIER_ARCHIVED` (422, payments),
`SUPPLIER_PAYMENT_EXCEEDS_BALANCE` (422),
`SUPPLIER_PAYMENT_AMOUNT_INVALID` (422), plus reused `NOT_FOUND`,
`VALIDATION_ERROR`, `CONFLICT`.

## 4. Flutter

### 4.1 New files

- `lib/features/suppliers/`: `supplier_models.dart`, `suppliers_error.dart`,
  `suppliers_providers.dart`, `supplier_form_dialog.dart`,
  `supplier_payment_dialog.dart`, `suppliers_screen.dart`.
- `lib/features/purchases/`: `purchase_models.dart`, `purchases_error.dart`,
  `purchases_providers.dart`, `purchase_pickers.dart`,
  `purchase_line_dialog.dart`, `purchase_form_dialog.dart`,
  `purchase_detail_dialog.dart`, `purchases_screen.dart`.
- Tests: `test/unit/suppliers_localization_test.dart`,
  `test/unit/purchases_localization_test.dart`.

### 4.2 Screens

- **`/suppliers`** (Phase 9 clients pattern): list + debounced server search +
  archived toggle; detail pane with balance card, contact fields, ledger
  (paginated, `balance_after` running balance) and payment/edit/archive actions
  gated by `supplier_manage`.
- **`/purchases`**: status/supplier/search filters, paginated list
  (`PurchasesLayoutMode` wide ≥1200 / medium ≥800 / narrow), row → detail
  dialog with status badge, snapshot lines, totals, and lifecycle actions
  (edit/receive gated `purchase_create`; cancel/delete gated
  `purchase_delete`). Editor dialog: supplier picker, line editor
  (product picker → optional variant + purchase-unit dropdowns with
  multiplier, qty, cost, live line total), live subtotal/discount/total/
  paid/remaining summary, **Save draft** / **Save & receive**.

### 4.3 Router + nav

Four coordinated edits in `app_router.dart`: routes `/suppliers`,
`/purchases`; rail destinations gated by `supplier_view` / `purchase_view`
inserted after debts; selected-index + `onDestinationSelected` bookkeeping.

### 4.4 Localization

+63 keys × 3 locales (`lib/core/strings.dart`): 22 supplier keys, 41 purchase
keys (`remaining` reused from the existing maps). Structured error codes map
code → localized message (raw backend text stays the secondary detail line).

### 4.5 Client-side rules mirrored

- Payment dialog: `> 0`, `≤ balance`, per-open `client_request_id`.
- Line editor: package lines must be whole numbers
  (`purchase_line_invalid`), money via `moneyToMilli` (integer math only),
  `paid ≤ total`, `discount ≤ subtotal`.
- **No PMP math in Flutter** — totals are document arithmetic for display;
  valuation always comes from the server.

## 5. Tests

### New (42 backend + 25 Flutter = 67)

- `tests/unit/test_suppliers.py` - 19 (CRUD, balance never client-writable,
  archive guards, ledger ordering, audit).
- `tests/unit/test_purchases.py` - 22 (draft lifecycle, atomic receive
  effects, package lines, variants, PMP rules, cancel reversal + ledger
  reconciliation, idempotency, permissions, error codes).
- `tests/integration/test_purchase_receive_concurrency.py` - 1 (PostgreSQL
  `FOR UPDATE` race: one 200 + one 409, stock/payable moved exactly once).
- `test/unit/suppliers_localization_test.dart` - 12.
- `test/unit/purchases_localization_test.dart` - 13.

### Suites that constrain this change (all green)

- Backend full suite: **723 passed** (681 baseline + 42).
- Migrations suite: **37 passed** (model/autogenerate parity preserved).
- Flutter: **902 passed** (877 baseline + 25); `flutter analyze`: 0 issues.

### E2E smoke (real HTTP, fresh PostgreSQL) - 51/51

Script: `C:\Users\MSI\AppData\Local\Temp\opencode\phase11_smoke\smoke_phase11.py`
(fresh `supermarket_pro_smoke` DB → `alembic upgrade head` → seed → `uvicorn`
→ full lifecycle over HTTP → teardown; dev DB never touched). Verifies:
server boot, first-admin setup, JWT auth, 401 without/with forged token,
supplier CRUD + archive guards (balance ≠ 0 → 409, archived payments → 422),
atomic package receive (240 base, PMP 3.750, cost 3.750, balance 900),
payment idempotency + overpay/negative guards, double receive/cancel → 409,
cancel reversal (stock 0, PMP untouched, capped cancel entry 500, balance 0),
draft edit/receive/delete, PMP reseed on empty stock (3.333), GATE 16
archived supplier purchase allowed, list filters, and full chronological
ledger reconciliation against `suppliers.balance`.

## 6. Verification log

```
python -m pytest -q                      → 724 passed (fix round, 4m27s)
  incl. test_suppliers + test_purchases +
  test_purchase_receive_concurrency       → 43 passed (targeted run)
python -m ruff <touched files>            → not available in fix-round env
flutter analyze                           → No issues found!
flutter test                              → 907 All tests passed!
flutter build windows --debug             → √ Built supermarket_pos.exe (11.7s)
alembic upgrade head                      → 0015 applied (rev d3e4f5a6b7c8)
E2E smoke (fresh PG + uvicorn + HTTP)     → 51/51 checks passed
dev DB (supermarket_pro)                  → upgraded c9d0e1f2a3b4 → d3e4f5a6b7c8,
                                           new columns + supplier_ledger_entries verified
```

## 7. Known limitations / deliberate deferrals

- Cancel never rewinds PMP (GATE 12) - documented cost basis stays.
- Ledger cancellation shortfall is recorded in the entry note (GATE 13).
- Per-invoice payment allocation / payment methods / credit notes: deferred.
- Purchase receive from the editor (edit mode) posts PUT then receive; a
  receive failure surfaces as a toast after the draft was saved.
- Report screens for purchases/suppliers: Phase 14.

## 8. Human QA checklist (PASS)

- [x] Suppliers: create/edit/archive + balance guard, ledger + payment flow
- [x] Purchases: draft create/edit/delete, Save & receive atomicity
- [x] Receive effects: stock, PMP, movements, supplier payable, audit
- [x] Cancel: reversal + capped payable + PMP untouched
- [x] Package lines: whole-package validation, packaging effects
- [x] Permissions: views hidden without scopes; server rejects anyway
- [x] Localization: ar/fr/en spot check on both screens
- [x] Concurrency: double-receive returns 409, stock moves once

## 9. File inventory

See `git status` for the exact set (all new backend + Flutter files listed in
§3.1/§4.1, plus edits in §3.2/§4.3/§4.4). Migration head:
`d3e4f5a6b7c8` (0015).

---

## 10. Human QA Fix Round

Manual QA found 3 issues; the fixes below were **re-verified by hand and
PASSED** (see §10.6).

### 10.1 Bug 1 — Supplier Detail balance showed 0

**Root cause (traced end to end, not a display/local-math bug):**

1. `GET /suppliers/{id}` returns `balance` correctly (E2E smoke: 900 →
   500 → 0 on the real endpoint; `SupplierResponse.balance` is the
   server-owned ledger projection).
2. `SupplierModel.fromJson` parses it (`'${json['balance'] ?? 0}'`) and
   `formatMoney` renders it — the fresh-payload widget test passed even
   BEFORE the fix.
3. The real defect: `supplierDetailProvider` / `supplierLedgerProvider`
   are **non-autoDispose families that load exactly once per supplier
   id**. The screen's `initState` only refreshed the master LIST. On any
   revisit (leave → purchase receive → return → reselect), the detail
   pane reused the cached first snapshot — taken before the payable
   existed — hence **balance 0** while the list showed the fresh value
   (list/detail disagreement). The same staleness left the ledger pinned
   to its first (empty) response — **Bug 3**.

**Fix (`suppliers_providers.dart`, `suppliers_screen.dart`):**

- `SupplierDetailNotifier.load({bool silent = false})` — `silent: true`
  refreshes in the background without clearing the snapshot to loading.
- `_SupplierDetailPaneState.initState` + `didUpdateWidget` (id change)
  call `_refreshFromServer()`: silent detail reload + ledger refresh,
  skipped while a first-ever load is in flight (no duplicate GET on the
  initial open). No local balance calculation was added anywhere.

**Regression tests** (`test/widget/suppliers_detail_balance_test.dart`, 4):

1. payload `balance = "1000.000"` → detail displays 1000, never 0, and
   list/detail agree (fails without the display path — passed pre-fix,
   pinning the QA acceptance).
2. stale-cache: first open 0 (pre-purchase) → leave → return → detail
   must show 1000 — **failed before the fix**, passes after.
3. ledger refresh on reopen: empty → `payment -400 (balance after 600)`,
   `purchase +1000 (balance after 1000, PUR-2026-0001)` — **failed
   before**, passes after.
4. history remains at balance 0 incl. `purchase_cancel -600`, pay button
   disabled at 0 (no negative balance).

**Backend contract test** (`test_purchases.py`,
`test_supplier_detail_balance_tracks_purchase_flow`): receive → detail
balance 500 → payment 200 → 300 → cancel → 0, list projection agrees.

### 10.2 Bug 2 — NavigationRail vertical overflow

**Root cause:** Flutter's `NavigationRail` wraps its destination `Column`
in a scroll view **only when `scrollable: true`** (verified in
`C:\flutter\...\material\navigation_rail.dart`, `widget.scrollable`
gate). We did not set it, and the rail now carries 11 destinations — on
short windows the internal RenderFlex overflowed ("87 pixels on the
bottom" reported by QA; reproduced in-test at 248 pixels with the fix
temporarily reverted).

**Fix (`app_router.dart`):** `scrollable: true` — the framework's own
adaptive behavior:

1. no overflow at any height (destinations scroll, nothing hidden),
2. all destinations stay accessible (rail scrolls; test scrolls + taps),
3. no destination removed, permission gating untouched,
4. tall-window layout unchanged (content still sizes intrinsically and
   is aligned exactly as before when it fits).

**Regression test** (`test/widget/nav_rail_overflow_test.dart`): all 11
destinations at normal (1000) / medium (520) / very short (400/460)
heights with `takeException() == null` after every resize, minimize →
restore (resize back), scroll-to-reach + navigate to Purchases from the
short window, and AR + EN labels. **Fails without the fix.**

**Second overflow caught by this suite:** the purchases status filter
was a fixed-width (180px) `DropdownButtonFormField` whose internal Row
overflowed **21px on the right in English** ("Status" + value + suffix
icon). Fixed by removing the fixed width (intrinsic, locale-proof — the
header is a `Wrap`, so locale-driven widths are safe).

### 10.3 Bug 3 — Supplier history experience

**Root cause:** same staleness as Bug 1 — the ledger provider kept its
first (empty) response forever, so the History section showed
"No ledger entries" after purchases/payments existed. No separate
history table was invented and no financial math was added in Flutter.

**Section (existing `_SupplierLedgerSection`, now refreshed on every
open)** uses `GET /suppliers/{id}/ledger` (append-only
`supplier_ledger_entries`) and shows, newest first:

- date/time, localized entry type
  (`supplier_entry_type_purchase|payment|purchase_cancel` in ar/fr/en),
- signed amount (`+1000` purchase / `-400` payment / `-600` cancel),
- `balance_after` straight from the backend read model,
- invoice number / user / note when present,
- section title ("Payables history" / "Historique des dettes
  fournisseur" / Arabic), refresh, and API pagination (20/page).

Verified by tests 3–4 above: purchase +1000 → balance after 1000,
payment -400 → 600, cancel entry at the end, history persists at
balance 0.

### 10.4 Fix-round files changed

| File | Change |
|---|---|
| `lib/features/suppliers/suppliers_providers.dart` | `load({silent})` on detail notifier |
| `lib/features/suppliers/suppliers_screen.dart` | pane `initState`/`didUpdateWidget` → `_refreshFromServer()` |
| `lib/router/app_router.dart` | `NavigationRail(scrollable: true)` |
| `lib/features/purchases/purchases_screen.dart` | status filter: intrinsic width (EN overflow) |
| `test/widget/suppliers_detail_balance_test.dart` | NEW — 4 regression tests |
| `test/widget/nav_rail_overflow_test.dart` | NEW — overflow/reachability/AR+EN |
| `backend/tests/unit/test_purchases.py` | NEW — detail-balance API contract test |
| `docs/PHASE_11_IMPLEMENTATION.md` | this section |

### 10.5 Final verification (fix round)

```
python -m pytest -q                                   → 724 passed
  targeted: test_suppliers + test_purchases +
  test_purchase_receive_concurrency                   → 43 passed
flutter test                                          → 907 passed
flutter analyze                                       → No issues found!
flutter build windows --debug                         → √ built (11.7s)
E2E HTTP smoke (fresh PG → alembic → uvicorn → flow)  → 51/51
```

Not broken (spot-checked by suites): supplier CRUD, purchase draft /
receive / payment / cancel, supplier ledger, supplier + purchase
permissions, AR/FR/EN + RTL (widget tests run in the default Arabic/RTL
locale; nav suite also exercises EN), Phase 10 behavior, all existing
navigation destinations.

**Manual QA status (fix round): PASS — all 3 re-verified manually:**

1. Supplier detail balance refresh: **PASS** (balance updates after
   purchase receive and payment; detail and list agree; never 0 when a
   payable exists).
2. Supplier payables history: **PASS** (purchase/payment/cancel entries
   with signed amounts and `balance_after`, newest first; history
   remains after balance reaches 0).
3. NavigationRail short-window / minimize / restore overflow: **PASS**
   (no overflow; suppliers + purchases reachable; AR/FR/EN intact).

### 10.6 Final verification (pre-commit)

```
python -m pytest -q                      → 724 passed
flutter test                             → 907 passed
flutter analyze                          → No issues found!
flutter build windows --debug            → √ built supermarket_pos.exe
alembic current                          → d3e4f5a6b7c8 (head)
alembic heads                            → d3e4f5a6b7c8 (head) [single]
```

**Phase 11 = APPROVED / CLOSED.**
