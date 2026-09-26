# Phase 9 Implementation — Customers, Debts & Debt Payments

Status: **APPROVED / CLOSED** — Human QA **PASSED** (all Phase 9 scenarios,
including the **PHASE 9 BUG FIX round**: authoritative debt-ceiling
enforcement at POS checkout (`DEBT_CEILING_EXCEEDED`, HTTP 422), and the
**PHASE 9 FINAL UX FIX round**: complete customer debt history (running
`balance_after` per entry, date+time, signed amounts, Pay All shown as a
normal full-payment entry)). Final automated verification: backend 595
passed / Flutter 822 passed / analyze clean / Windows build PASS /
alembic head `c8d4e5f6a1b2`. Committed as `phase-9: complete customers
debts payments` (see §21).

---

## 1. Objective & Scope

Deliver Phase 9 of the Supermarket Pro rewrite (Flutter desktop + FastAPI +
PostgreSQL):

- Customer CRUD: create, read, paginated list/search, partial update, soft
  archive.
- Per-customer debt history (append-only ledger, paginated, newest first).
- Debt payment command (atomic, idempotent, never over-pays).
- Accounts-receivable summary (total debt, debtors count) + debtors list.
- RBAC, audit logging, structured errors, AR/FR/EN localization, tests,
  migration, and this report.

Out of scope (unchanged from the roadmap): packs, returns, voids, purchases,
suppliers, reports/dashboard, PDF, LAN, offline queue, gateways, tax changes,
split-payment redesign. POS checkout debt-ceiling enforcement was originally
deferred but has since been IMPLEMENTED in the bug-fix round (see §2.1).

## 2. Decision Gates

### 2.1 Debt ceiling enforcement at checkout — RESOLVED (IMPLEMENTED in bug-fix round)

Original state (first implementation round):

- No document in the repository specified a checkout enforcement rule
  (`docs/PHASE_8_POS_ANALYSIS.md:520` — "Legacy never enforces — Phase 9
  decision"), so the ceiling shipped **display-only**.
- Display semantics were already app-wide: clients screen shows the
  over-limit badge only when `balance > debt_ceiling > 0`
  (`clients_screen.dart`), and report §2.1 hints on the same condition —
  i.e. **`debt_ceiling == 0` means NO ceiling (unlimited)**.

Resolution (bug-fix round, explicit instruction): the server now enforces
the ceiling authoritatively during `POST /api/v1/sales` checkout:

- **Rule:** `projected = current_balance + new_debt`; reject when
  `projected > debt_ceiling` (only when `debt_ceiling > 0`;
  `projected == ceiling` is allowed). `new_debt = total - paid` — cash/card
  full payment produces `new_debt = 0` and is never blocked.
- **Where:** `SaleService._enforce_debt_ceiling` is the **first statement
  inside the sale transaction** (before stock decrements): a
  `refresh(customer, with_for_update=True)` re-reads the customer row under
  a row lock, re-evaluates the rule on the authoritative balance, and
  raises **before any mutation** — a rejected checkout leaves zero residue
  (no sale/lines/movements/payments, stock untouched, balance and ledger
  untouched). The transaction rolls back; the debt write later reuses the
  refreshed authoritative balance (also closes a stale-balance race).
- **Contract:** `BusinessRuleError(code="DEBT_CEILING_EXCEEDED")` → HTTP
  422 with `details = {customer_id, current_balance, new_debt,
  projected_balance, debt_ceiling}` (all strings, e.g. `"600.000"`).
- **Localization:** Flutter maps the envelope code FIRST
  (`posApiError` → `DEBT_CEILING_EXCEEDED`), showing the localized headline
  `debt_ceiling_exceeded` plus a localized amounts block
  `debt_ceiling_detail` (placeholders `{current} {new_debt} {ceiling}
  {projected}` substituted from `details`) folded into the single
  `cart.lastError` string (payment-dialog `payment-error` line + toast).
  Raw backend text stays secondary (`PosApiError.detail`).
- The failed attempt does NOT consume the idempotency key — the same
  `client_request_id` can be retried after lowering the ceiling/raising the
  payment.
- Tests: edge cases 1-11 in `tests/unit/test_pos_debt_ceiling.py` (10),
  case 12 (concurrent race) in
  `tests/integration/test_sale_ceiling_concurrency.py` on real PostgreSQL
  (§19), Flutter mapping in `test/unit/pos_debt_ceiling_error_test.dart`
  (15) + checkout rejection widget tests ×3 locales (3).
- **Manual QA: PASSED** — over-ceiling rejection with the localized
  headline + amounts (AR/FR/EN), zero residue, retry after rejection, and
  unlimited (`debt_ceiling == 0`) selling all verified by hand
  (§20 checklist item 11).

### 2.2 Overpayment — REJECTED (implemented as 422 error)

- No Phase 0/blueprint rule exists for overpayment.
- Verified legacy guard: `python_app/gui/main_window.py:12843-12848` —
  "لا تسديد أكثر من الدين الحالي" (cannot pay more than the current debt).
- Phase 0 rule: commands "must not silently create a negative balance".

Implemented: `BusinessRuleError(code="PAYMENT_EXCEEDS_BALANCE")` → HTTP 422,
balance untouched, no negative-balance/advance/credit semantics anywhere in
the system. Flagged for human confirmation (§2.1 has since been resolved in
the bug-fix round).

## 3. Architecture

```
Flutter (clients/debts screens, dialogs, providers)
   │  JSON money as strings
   ▼
FastAPI routers  app/api/v1/customers.py · app/api/v1/debts.py
   ▼
Services (transaction + audit + business rules)
   app/services/customers.py · app/services/debt.py
   ▼
Repositories (SQL, pagination, row lock)
   app/repositories/party.py · app/repositories/debt.py
   ▼
Models: Customer (party) · DebtLedgerEntry (append-only) · AuditLog
```

- Balance is a **cached projection** of the ledger (`customer.balance`), moved
  only by credit sale (Phase 8) and debt payment — never by CRUD.
- Reads use the cached projection; the payment command re-derives truth from
  the ledger inside the same transaction (`ledger_sum_for_customer`
  reconciliation assertion).

## 4. API Endpoints

| Method | Path | Permission | Notes |
|---|---|---|---|
| GET | `/api/v1/customers/search` | customer_view | Phase 8 POS picker contract **unchanged** (`q,page,page_size,include_archived`) |
| GET | `/api/v1/customers` | customer_view | list: `page,page_size,q,include_archived,has_debt` |
| POST | `/api/v1/customers` | customer_manage | 201, balance always starts 0 |
| GET | `/api/v1/customers/{id}` | customer_view | detail |
| PUT | `/api/v1/customers/{id}` | customer_manage | partial (`exclude_unset`), balance never writable |
| DELETE | `/api/v1/customers/{id}` | customer_manage | soft archive, 409 `OUTSTANDING_DEBT` if balance > 0 |
| GET | `/api/v1/customers/{id}/debts` | customer_view | paginated ledger, `entry_date DESC, id DESC` |
| POST | `/api/v1/customers/{id}/pay` | customer_manage | payment command (atomic, idempotent) |
| GET | `/api/v1/debts/summary` | customer_view | `{total_debt, customers_with_debt}` |

Deviation from `PHASE_0_API_BLUEPRINT.md`: the blueprint's list endpoint used
`page,limit,search`; current code (Phase 8 precedent) uses
`page,page_size,q,include_archived` — current code wins, `has_debt=true` was
added for the debts screen. The blueprint-era `/search` contract is preserved
exactly.

## 5. Request/Response Contracts

- `CustomerCreateRequest` / `CustomerUpdateRequest`: `name` (trimmed,
  non-blank, ≤ 200), `phone` (≤ 30, nullable), `address` (nullable),
  `debt_ceiling` (`Decimal ≥ 0`, string in JSON like `"5000.000"`). No
  `balance` field exists on either schema.
- `CustomerResponse`: `id,name,phone,address,balance,debt_ceiling,is_archived,
  created_at,updated_at` — money as JSON **strings** (Pydantic v2 Decimal
  serialization).
- `DebtPaymentRequest`: `amount` (`Decimal > 0`, required), `note`
  (≤ 2000, optional), `client_request_id` (≤ 100, optional — omitted by the
  blueprint payload, so plain `{amount, note}` stays valid).
- `DebtPaymentResponse`: `id,customer_id,entry_type,amount,balance,note,
  client_request_id,entry_date,idempotent_replay`.
- `DebtEntryResponse`: ledger row + denormalized `invoice_number` and
  `user_name`, plus `balance_after` (string, nullable) — the running debt
  balance AFTER that entry, computed per request from the full ledger
  (§5.1).
- List envelopes: `{items,total,page,page_size,pages}` (Phase 8 shape).

### 5.1 Debt history `balance_after` (final UX fix)

- `GET /customers/{id}/debts` items now carry `balance_after`: the running
  debt balance **after** that entry — `sale` adds its amount, `payment`
  subtracts it, any other type (`adjustment`) contributes 0, exactly
  mirroring `ledger_sum_for_customer`.
- Computed as a chronological prefix sum over the customer's FULL ledger
  (`entry_date ASC, id ASC`) inside the same request and merged into the
  page — so page 2 entries still show balances that include older entries.
  It is a **read model only**: no column, no migration, append-only ledger
  untouched. Each step is quantized with `quantize_money`, so the newest
  entry's `balance_after` equals `customers.balance`.
- Ordering semantics unchanged: history stays `entry_date DESC, id DESC`
  (newest first) with offset pagination.
- **Manual QA: PASSED** — full lifecycle (credit sale → partial debt →
  payments → Pay All → balance 0 with entries retained), running
  `balance_after`, newest-first pagination, and AR/FR/EN labels verified
  by hand (§20 checklist item 6).

## 6. Money & Decimal Policy

- Backend: `Decimal` only, quantized to `0.001` via `quantize_money` /
  `to_decimal` — same helpers as Phases 2-8.
- JSON wire: money is a **string** (`"1500.000"`).
- Flutter: money stays a string end-to-end; arithmetic uses
  `moneyToMilli`/`milliToMoney` (integer thousandths — **no floats anywhere**),
  display uses `formatMoney` (trailing-zero trim).
- Client input rejects > 3 decimals and negatives instead of rounding
  (`moneyToMilli` returns null); the backend remains authoritative.

## 7. Transaction & Concurrency Boundary

- `DebtService.pay` runs in one DB transaction:
  1. `SELECT … FOR UPDATE` on the customer row (`get_for_update`) — serializes
     concurrent payments (SQLite tests ignore FOR UPDATE; no true concurrency
     test possible on SQLite).
  2. Re-read balance, reject `amount > balance` (`PAYMENT_EXCEEDS_BALANCE`)
     and `amount <= 0` (`PAYMENT_AMOUNT_INVALID`, also schema-level 422).
  3. Insert `DebtLedgerEntry(type=payment)`, update `customer.balance`.
  4. Reconcile: assert projection equals `SUM(ledger)` (same transaction).
  5. Audit row (`action=payment`, `entity_type=customer`) rides the same
     transaction — failure propagates, nothing is swallowed.
- Archive blocks on `balance > 0` with `ConflictError(OUTSTANDING_DEBT, 409)`.
- Archived customers always carry balance 0 (archived debtors cannot exist).
- **Debt-ceiling gate (bug-fix round):** `SaleService.create_sale` — the
  FIRST statement inside the sale transaction (before stock decrements) is
  `_enforce_debt_ceiling` when `new_debt > 0`: `refresh(...,
  with_for_update=True)` locks the customer row, re-reads the authoritative
  balance, and raises `DEBT_CEILING_EXCEEDED` (422) if
  `current_balance + new_debt > debt_ceiling > 0`. The exception rolls the
  transaction back → zero mutation (verified by tests asserting every table
  and stock unchanged). The later balance write reuses the refreshed row.
  Concurrent credit sales serialize on that row lock — proven on real
  PostgreSQL (§19, second test); SQLite cannot verify `FOR UPDATE`.

## 8. Idempotency

- Optional `client_request_id` (unique, nullable) on the payment command.
- Fast path: existing row with same id → return it with
  `idempotent_replay=true` and the **current** balance, no double deduction.
- Race path: unique-constraint violation on insert → re-read → replay.
- Same id on a **different** customer → 409 conflict (never cross-replay).
- Flutter dialog generates one id per dialog open → double-click / network
  retry cannot double-pay; legacy double-payment behavior is eliminated.
- CRUD mutations are naturally idempotent (PUT/POST re-runs are safe); the
  dialog disables buttons in flight.

## 9. Validation Summary

| Rule | Layer | Error |
|---|---|---|
| name non-blank, ≤ 200 (trimmed) | schema + service | 422 VALIDATION_ERROR |
| phone ≤ 30 | schema | 422 |
| debt_ceiling ≥ 0, ≤ 3 dp on client | schema + dialog | 422 |
| credit/partial sale must not cross debt_ceiling (`current + new_debt > ceiling`, ceiling > 0) | service (in-lock, first statement of sale tx) | 422 DEBT_CEILING_EXCEEDED |
| amount > 0 | schema | 422 PAYMENT_AMOUNT_INVALID (client mirror `invalid_amount`) |
| amount ≤ balance | service | 422 PAYMENT_EXCEEDS_BALANCE (client-side mirror blocks submit) |
| archive only when balance == 0 | service | 409 OUTSTANDING_DEBT |
| unknown customer (valid UUID) | service | 404 NOT_FOUND (structured, never 500) |
| invalid UUID | path validation | structured 422 |
| note ≤ 2000, client_request_id ≤ 100 | schema | 422 |

## 10. RBAC

- **No new permission scopes invented.** Reads (`/search`, list, detail, debt
  history, `/debts/summary`) require `customer_view`; mutations + `POST /pay`
  require `customer_manage`.
- Seed (Phase 2) already grants both to admin/manager/cashier — "Customers
  (view + limited manage for debt)".
- Flutter: rail destinations (Clients, Debts) gated by `customer_view`;
  screens render a localized permission-denied state without it; add/edit/
  archive/pay actions hidden without `customer_manage`.
- Tests: guest (no roles) → 403 `FORBIDDEN` with
  `details.required_permission`; cashier can read history and record payments.

## 11. Audit

- Reuses `AuditLog` + existing `AuditAction` enum (`create`, `update`,
  `delete`, `payment`) — no enum expansion needed.
- `entity_type="customer"`, `entity_id=<uuid>`, `actor_id=user_id`.
- Payment audit written inside the payment transaction (§7); failures
  propagate. Tests assert audit rows for create, update, archive, payment.

## 12. Error Catalog

Structured envelope `{error:{code,message,details}}`. Codes introduced/used:

- `DEBT_CEILING_EXCEEDED` (422, bug-fix round — checkout crossed the credit
  ceiling; `details` carries `customer_id, current_balance, new_debt,
  projected_balance, debt_ceiling`)
- `PAYMENT_EXCEEDS_BALANCE` (422)
- `PAYMENT_AMOUNT_INVALID` (422, service-level belt-and-braces)
- `CUSTOMER_ARCHIVED` (422, payment/archive on archived customer)
- `OUTSTANDING_DEBT` (409)
- `NOT_FOUND` (404), `FORBIDDEN` (403), `VALIDATION_ERROR` (422)

Flutter mapping (`clients_error.dart`): envelope `code` first (so a customer
409 never becomes the POS "stock conflict" message), HTTP status fallback,
connection → `network_error_retry`. Primary message is **always localized**;
raw backend text travels only as the secondary `detail` line
(`PosApiError.message/detail`, Phase 8 contract).

Flutter POS mapping (`pos_error_message.dart`, bug-fix round): envelope code
is now checked FIRST for `DEBT_CEILING_EXCEEDED` (via the shared
`backendErrorCode` helper in `api_client.dart`), so that 422 never collapses
into the generic `validation_error` headline; all other statuses keep the
existing status-first mapping.

## 13. Database Migration

- `migrations/versions/2026_09_26_1000_c8d4e5f6a1b2_0011_phase9_debt_payment_idempotency.py`
  - rev `c8d4e5f6a1b2`, down_revision `b7c3d4e5f6a1` (Phase 8 head)
  - adds `client_request_id VARCHAR(100)` to `debt_ledger_entries`
    (nullable, unique index)
- `alembic current` → `c8d4e5f6a1b2 (head)`; **single head** verified
  (`ScriptDirectory.get_heads() == ['c8d4e5f6a1b2']`, 11 revisions).
- `tests/integration/test_migrations.py`: HEAD_REV updated (3 occurrences);
  upgrade / downgrade / re-upgrade pass; autogenerate reports no model drift.
- All prior tables/columns unchanged — additive only.

## 14. Backend Implementation Notes

- `app/schemas/party.py` — Phase 9 request/response schemas (money as
  `Decimal`, serialized as strings).
- `app/repositories/party.py` — `CustomerRepository`: `_base_stmt`
  (archived/q/`has_debt` filters), deterministic `name ASC, id ASC`
  ordering, `get_for_update`, `total_outstanding`.
- `app/repositories/debt.py` — `DebtLedgerEntryRepository`: history
  pagination, `find_by_client_request_id`, `ledger_sum_for_customer`,
  `balance_after_map` (chronological prefix sum → entry-id → running
  balance, §5.1).
- `app/services/customers.py` — CRUD + archive rule + audit helper.
- `app/services/debt.py` — payment command (§7) + history + summary +
  `balance_after_map` (delegates to the repository; returned separately
  from `history()` so that contract is unchanged).
- `app/api/v1/customers.py`, `app/api/v1/debts.py` mounted in
  `app/api/v1/router.py`.
- `has_debt` filter added to list endpoint + repository (debtors screen).
- **Bug-fix round:** `app/services/sale.py` — `_enforce_debt_ceiling`
  (in-transaction `FOR UPDATE` re-read + rule, §2.1), called as the first
  statement of `create_sale`'s transaction whenever `new_debt > 0`.

## 15. Flutter Implementation

New files (`lib/features/clients/`):

- `customer_models.dart` — `CustomerModel`, `DebtEntryModel`,
  `DebtPaymentResult`, `DebtSummaryModel` + decimal helpers.
- `clients_error.dart` — `clientsApiError` / `clientsApiMessage` (§12).
- `clients_providers.dart` — `customersProvider` (debounced search 300 ms,
  stale-response guard, pagination, CRUD mutations returning `PosApiError?`),
  `debtorsProvider` (**separate instance** pre-set `has_debt=true` so screen
  queries never cross-contaminate), `customerDetailProvider` (family),
  `debtHistoryProvider` (family, paginated), `debtPaymentProvider`,
  `debtSummaryProvider`.
- `customer_form_dialog.dart` — create/edit (name/phone/address/ceiling),
  milli-based validation, success toast.
- `debt_payment_dialog.dart` — amount/note, "pay all", live exact
  remaining-after preview, client-side overpayment mirror (submit disabled),
  per-dialog `client_request_id`, localized inline error + raw detail.

Rewritten:

- `clients_screen.dart` — master/detail: debounced search, show-archived
  filter, paginated list with balance + over-limit badge, detail pane
  (balance card, ceiling, actions gated by `customer_manage`), paginated
  debt history (type icon/color, invoice, user, note), archive confirmation
  dialog, toasts.
- `debts_screen.dart` — AR summary cards (`total_debt`,
  `customers_with_debt`), debtors list (`has_debt=true`), per-row payment
  action, refresh, pagination, permission gating.
- `router/app_router.dart` — Clients + Debts rail destinations gated by
  `customer_view`, inserted between Stock and Users with index bookkeeping
  updated in all three places (destinations, selection, onDestinationSelected).
- `core/strings.dart` — 36 new keys × ar/fr/en (§16).

POS picker (`customer_picker_dialog`, `/search`) untouched.

Bug-fix round (checkout ceiling rejection, §2.1):

- `network/api_client.dart` — new `backendErrorCode(DioException)` helper
  (envelope `error.code`, null when absent) next to `backendErrorMessage`.
- `features/pos/pos_error_message.dart` — code-first branch:
  `DEBT_CEILING_EXCEEDED` → `headline \n amounts` composed from the
  `debt_ceiling_detail` template + envelope `details` (folded into the
  single `cart.lastError` string because both the payment dialog's
  `payment-error` line and the toast read that one field); other statuses
  unchanged.
- Checkout state preservation needed no change (already correct): on any
  failure the cart, `pendingClientRequestId`, and the open payment dialog
  are kept; the cart clears only on 2xx.

Final UX fix round (complete customer debt history):

- `customer_models.dart` — `DebtEntryModel.balanceAfter` parsed from
  `balance_after` (null when absent; older payloads unaffected).
- `clients_screen.dart` `_DebtHistorySection` row rendering:
  - **Title** = localized type label + ` · ` + **signed** amount:
    `sale` → `+`, `payment` → `-`, `adjustment` unsigned.
  - **Pay All label rule**: `entryType == 'payment' && balanceAfter == 0`
    → `entry_type_full_payment`; otherwise the ordinary entry-type label.
    Pay All stays a normal `payment` ledger entry — the distinction is
    display-only, driven by the zero running balance.
  - **Meta line** (newest-first order preserved): date **+ time**
    (`YYYY-MM-DD HH:MM:SS`, `_timestampOf`), `balance_after: <value>`,
    invoice number, user, note — joined with ` · `.
  - Null `balance_after` degrades gracefully (no balance segment, no
    full-payment relabel) — pagination/refresh keys unchanged.
- No changes to `debt_payment_dialog` / pay command (Pay All keeps posting
  a single normal payment).

## 16. Localization

36 keys in `_arabic` / `_french` / `_english` (32 from the first round + 2
from the bug-fix round — `debt_ceiling_exceeded`, `debt_ceiling_detail` +
2 from the final UX fix round — `entry_type_full_payment`, `balance_after`;
`entry_type_sale` was relabeled to the spec text):
`balance, debt_ceiling, over_limit_hint, archive, add_client, edit_client,
client_created, client_updated, client_archived, archive_client_confirm,
customer_outstanding_debt, customer_not_found, customer_is_archived,
record_payment, record_debt_payment, payment_success, debt_payment_exceeds,
pay_all, remaining_after, amount, note_hint, debt_history, entry_type_sale,
entry_type_payment, entry_type_full_payment, entry_type_adjustment,
balance_after, debt_summary, total_debt, customers_with_debt,
show_archived, select_client_hint, no_debt_records, field_required,
debt_ceiling_exceeded, debt_ceiling_detail`.

Reused existing keys: `clients, debts, search, total, name, phone, address,
save, cancel, edit, no_data, loading, retry, refresh, archived, note,
invoice_number, permission_denied, network_error_retry, api_error_retry,
validation_error, session_expired_login, invalid_amount`, etc.
`clients_localization_test.dart` enforces existence, non-fallback, and
cross-locale difference for all of them.

## 17. Tests

### Backend (595 total, 66 new in Phase 9: 49 first round + 11 bug-fix round + 6 final UX fix round)

- `tests/unit/test_customers_crud.py` (25) — CRUD, validation, audit,
  archive 409, archived visibility, `has_debt` filter, RBAC (auth / guest /
  cashier).
- `tests/unit/test_debts.py` (23) — payment flows, overpayment rejected,
  zero/negative rejected, idempotent replay, cross-customer id conflict,
  history ordering/pagination/append-only, summary totals, projection
  reconciliation, RBAC.
- `tests/unit/test_pos_debt_ceiling.py` (10, bug-fix round) — ceiling edge
  cases 1-11: within-ceiling credit sale writes balance + ledger;
  projected > ceiling → 422 with **exact** `details`; boundary
  (`projected == ceiling`) allowed; partial payment counts only the debt
  portion; cash/card full payment never blocked even when already over;
  `debt_ceiling == 0` = unlimited; existing balance counts; sequential
  sales cannot cross; rejection leaves **zero residue** (sales, lines,
  payments, movements, ledger, balance, stock all unchanged) and the very
  next sale succeeds; envelope shape (`code/message_key/message/details/
  request_id`); rejected attempt does not consume the idempotency key.
- `tests/integration/test_debt_payment_concurrency.py` (1) — **PostgreSQL
  concurrency gate** (see §19): two concurrent payments on real
  `supermarket_pro_test`, row-lock serialization, invariants + structured
  error on real PG.
- `tests/integration/test_sale_ceiling_concurrency.py` (1, bug-fix round) —
  **PostgreSQL ceiling gate** (see §19): two concurrent credit sales racing
  the ceiling; loser's `details.current_balance == "600.000"` proves the
  in-lock re-read; zero residue from the loser.
- `tests/unit/test_debt_history_lifecycle.py` (6, final UX fix round) —
  full debt lifecycle through the API: credit sale entry visible with
  invoice/user/`balance_after`; partial sale records only the debt
  portion; normal partial payment drops the running balance; Pay All is a
  normal `payment` entry with `balance_after == 0`; all entries remain
  visible after the balance reaches 0; newest-first ordering; exact
  running-balance sequence (1200 → 700 → 0) reconciled against
  `ledger_sum_for_customer` and `customers.balance`; `balance_after`
  correct for entries beyond the current page; history reads never
  mutate the ledger. (Ordering-sensitive tests separate ledger writes by
  >1s — SQLite's `func.now()` is second-precise while PostgreSQL's is
  microsecond-precise, so only the SQLite harness can tie `entry_date`.)
- `tests/integration/test_migrations.py` — HEAD_REV ×3, upgrade/downgrade/
  re-upgrade, single head, autogenerate clean.
- All unit tests are self-contained per file (own SQLite `StaticPool`
  fixtures); the two concurrency gates are the only PG-dependent tests.

### Flutter (822 total, 109 new: 85 first round + 18 bug-fix round + 6 final UX fix round)

- `test/unit/clients_localization_test.dart` (21) — keys × ar/fr/en, no raw
  fallbacks, Arabic script check, entry-type coverage (incl.
  `full_payment`), exact spec labels for the 4 entry types +
  `balance_after` ×3 locales.
- `test/unit/clients_models_test.dart` (19) — JSON parsing, money helpers
  (reject `1.2345`, negatives, round-trip), `hasDebt`, `balance_after`
  parse + null-when-absent.
- `test/unit/clients_error_test.dart` (32) — envelope codes → localized
  headlines ×3 locales, status fallbacks, no "stock conflict" leak, detail
  preserved.
- `test/widget/clients_screen_test.dart` (15) — list load + query params,
  permission denied + hidden rail entry, view-only gating, detail + history
  load, create payload (`balance` absent, `debt_ceiling '0'`), client-side
  overpayment mirror (no POST sent), payment POST with idempotency key +
  success toast, backend overpayment error in dialog, archive 409 toast,
  debounced search, archived toggle; final UX fix round: lifecycle rows
  (signed amounts + localized types + Pay All label), meta (date+time,
  balance after, invoice, user, note), rows visible at zero balance,
  pagination indicator + next page load.
- `test/widget/debts_screen_test.dart` (4) — summary + debtors
  (`has_debt=true`), payment from tile + summary/list refresh, permission
  denied, view-only (no pay button).
- `test/unit/pos_debt_ceiling_error_test.dart` (15, bug-fix round) —
  `DEBT_CEILING_EXCEEDED` mapped by envelope code (never the generic 422
  headline), headline + four amounts folded into the single message ×3
  locales, missing-details `?` degradation, `posApiMessage` single-string
  surface, ar/fr ≠ en, plain 422 still `validation_error` (regression),
  ceiling code on a non-422 status still wins, `backendErrorCode` unit
  coverage, key/template existence.
- `test/widget/pos_screen_test.dart` new group (3, bug-fix round — one per
  locale) — checkout rejection shows the localized headline + amounts in
  the payment dialog's `payment-error` line, dialog stays open and
  interactive, cart + `pendingClientRequestId` preserved, `lastResult`
  null, no success UI.

Mocktail ordering rule discovered and documented in both widget test headers:
specific-path stubs must be registered **after** `any()` catch-alls (last
registered = checked first).

## 18. Verification Results (FINAL — actual command output)

### Backend (from `new_app/backend`, sequential)

```
python -m pytest tests/integration/test_debt_payment_concurrency.py -v
→ test_concurrent_debt_payments_serialize_on_postgresql PASSED [100%]
  1 passed in 1.61s            # targeted PG concurrency gate

python -m pytest tests/unit/test_pos_debt_ceiling.py -q
→ 10 passed in 3.76s          # ceiling edge cases (SQLite)

python -m pytest tests/integration/test_sale_ceiling_concurrency.py -q
→ 1 passed in 1.52s           # targeted PG ceiling gate

python -m pytest tests/unit/test_debt_history_lifecycle.py -q
→ 6 passed in 8.96s           # debt history lifecycle (final UX fix)

python -m pytest tests -q
→ 595 passed, 3 warnings in 221.78s (0:03:41)
  (warnings are pre-existing: SAWarning in tests/unit/test_service.py)
python -m alembic current → c8d4e5f6a1b2 (head)
python -m alembic heads    → c8d4e5f6a1b2 (head)   # single head
```

### Flutter (from `new_app`)

```
flutter test        → 822 tests passed (baseline 713 + 109 new)
flutter analyze     → No issues found! (ran in 2.0s)
flutter build windows --debug → √ Built ...Debug\supermarket_pos.exe (11.4s)
```

## 19. PostgreSQL Concurrency Gate (Final Technical Gate)

Two PostgreSQL integration tests exist; the rest of the suite intentionally
stays on SQLite in-memory. Both use the project's existing PG test
infrastructure (`tests/conftest.py` `PG_TEST_URL` → dedicated
`supermarket_pro_test` database; production `supermarket_pro` is never
touched; `alembic upgrade head` runs in the fixture).

### Test names

1. `tests/integration/test_debt_payment_concurrency.py::test_concurrent_debt_payments_serialize_on_postgresql`
   — concurrent debt **payments** (first-round gate).
2. `tests/integration/test_sale_ceiling_concurrency.py::test_concurrent_credit_sales_cannot_cross_debt_ceiling_on_postgresql`
   — concurrent credit **sales** racing the debt ceiling (bug-fix round).

### Why SQLite cannot verify FOR UPDATE

`DebtService._record` serializes concurrent payments with
`SELECT ... FOR UPDATE` on the customer row
(`CustomerRepository.get_for_update`, `app/repositories/party.py:74`).
The guarantee depends on PostgreSQL READ COMMITTED semantics: the loser
of the row-lock race **blocks**, then re-reads the row version committed
by the winner and sees the reduced balance before applying the
overpayment check.

SQLite cannot reproduce this:

- No row-level locks and no `FOR UPDATE`. A second writer gets
  SQLITE_BUSY / database-level write serialization instead of blocking
  on one row and re-evaluating after the winner commits.
- There is no "wait for the row lock, then re-read the latest committed
  row version" step, so the exact interleaving that must be proven
  (winner commits balance 300.000 → loser re-reads 300.000 → rejects
  with `PAYMENT_EXCEEDS_BALANCE`) is unverifiable on SQLite. SQLite unit
  tests verify logic and invariants, never the lock behavior itself.

The ceiling gate has the identical problem: `SaleService.
_enforce_debt_ceiling` relies on `refresh(customer, with_for_update=True)`
under READ COMMITTED so the loser of the lock race re-reads the winner's
committed balance. SQLite silently ignores `FOR UPDATE`, so both writers
would simply read balance 0 and both would pass — the exact bug the gate
must prevent is unprovable there.

### Scenario 1 — concurrent payments & result

1. Seed one customer with balance **1000.000** plus a matching `sale`
   ledger entry (baseline: balance == projection == 1000.000).
2. Two concurrent `POST /api/v1/customers/{id}/pay` attempts of
   **700.000** each (each individually valid; combined 1400.000 >
   1000.000), driven through the real ASGI app (`httpx.ASGITransport` +
   `asyncio.gather`, real auth login, real `get_db` → PG sessions).
   A test-only barrier on the idempotency fast-path
   (`find_by_client_request_id`) forces both threads to reach the
   customer row lock together. No production code was changed.

**Result: PASSED on real PostgreSQL (targeted run, 1.61s).**

Evidence asserted by the test:

- Exactly one `200` + one `422`; loser envelope code
  **`PAYMENT_EXCEEDS_BALANCE`** (existing structured business error,
  contract/error codes unchanged), `details.balance == "300.000"` —
  proof the loser re-read the winner's committed balance **under the
  row lock**.
- Final `customers.balance == 300.000` (never negative, no duplicate
  deduction).
- Exactly **one** payment ledger entry, matching the winner's response
  id, `entry_date` populated, `created_at == updated_at` (never
  UPDATEd — append-only).
- `customer.balance == SUM(ledger projection) == 300.000`
  (`DebtLedgerEntryRepository.ledger_sum_for_customer`).
- Exactly **one** audit row (`action=payment`) with the correct actor
  and details `balance 1000.000 -> 300.000`; the rejected attempt left
  no ledger or audit residue.

### Scenario 2 — concurrent credit sales racing the ceiling (bug-fix round)

1. Seed one customer with balance **0.000** and `debt_ceiling` **1000.000**,
   plus one product with **1000** units of stock (product create seeds its
   own ADJUSTMENT movement, asserted as exactly 1 of the 2 movements).
2. Two concurrent `SaleService.create_sale` credit sales of
   **6 × 100 = 600.000** debt each (each individually valid:
   0 + 600 ≤ 1000; combined 1200 > 1000) run in two native threads, each
   with its own PG session, synchronized by a test-only barrier on the
   sale idempotency fast-path (`SaleRepository.find_by_client_request_id`)
   so both race into the customer row lock. No production code changed.
3. Exactly one commits; the other raises `BusinessRuleError` →
   envelope **`DEBT_CEILING_EXCEEDED`** whose
   `details.current_balance == "600.000"` (not `"0.000"`) — proof the
   loser re-read the winner's committed balance **under the row lock**;
   `projected_balance == "1200.000"`, `debt_ceiling == "1000.000"`,
   `new_debt == "600.000"`.

**Result: PASSED on real PostgreSQL (targeted run, 1.52s).**

Final-state invariants asserted: `balance == 600.000`,
`debt_ceiling == 1000.000`, exactly one sale (winner's
`client_request_id`, `paid == 0`, `user_id IS NULL`) + one sale line + one
sale payment + one SALE inventory movement (loser's decrement rolled back)
+ one `sale` ledger entry referencing the winner's sale, and product stock
`== 1000 - 6 = 994` (loser left **zero residue**).

### Actual final test counts

| Check | Result |
|---|---|
| Targeted PG payment-concurrency test | **1 passed (1.61s)** |
| Targeted PG ceiling-concurrency test | **1 passed (1.52s)** |
| Targeted ceiling unit tests (SQLite) | **10 passed (3.76s)** |
| Targeted debt-history lifecycle tests (SQLite) | **6 passed (8.96s)** |
| Backend `pytest tests -q` | **595 passed**, 3 pre-existing warnings |
| Flutter `flutter test` | **822 passed** |
| Flutter `flutter analyze` | **No issues found!** |
| `flutter build windows --debug` | **Built** `supermarket_pos.exe` (11.4s) |
| `alembic current` | `c8d4e5f6a1b2 (head)` |
| `alembic heads` | `c8d4e5f6a1b2 (head)` — single head |

## 20. Known Limitations / Deviations / Open Items

1. ~~Debt-ceiling enforcement at checkout is intentionally absent~~ —
   **RESOLVED in the bug-fix round**: server-side enforcement implemented
   and documented (§2.1, §7, §19 scenario 2), including localization and
   regression tests. `debt_ceiling == 0` = unlimited semantics preserved.
2. **Overpayment rejection is legacy-derived, not spec-derived** (§2.2) —
   awaiting human confirmation.
3. Blueprint list params (`limit, search`) not adopted; Phase 8 param style
   kept (documented §4).
4. ~~`FOR UPDATE` concurrency has no true parallel test~~ — **RESOLVED by
   the Final Technical Gate**: real-PostgreSQL test added and passing
   (§19); SQLite unit tests still don't (and can't) exercise the lock.
5. Client payment idempotency key is per-dialog-open (not persisted) — a
   reopened dialog is a new logical attempt, matching server semantics.
6. The POS customer picker was deliberately not extended with a "add
   customer" shortcut (out of scope).
7. `CUSTOMER_ARCHIVED` 422 on pay overlaps with the archive 409 path — both
   mapped, never overlapping in normal flows.
8. Client rejects > 3-decimal input where the backend would round — stricter
   client, authoritative server (documented §6).
9. Rails: Sales / Reports / Dashboard destinations unchanged (still absent or
   out of scope for Phase 9).
10. ~~Working tree is **uncommitted** — commit only after human QA
    approval~~ — **RESOLVED**: human QA passed, single commit created
    (§21).

### Manual test checklist (HUMAN — QA PASSED, all items PASS)

Human QA is complete; all Phase 9 scenarios passed (customer CRUD, debt
creation, partial debt, payments, Pay All, complete debt history +
running `balance_after`, history pagination, debt-ceiling enforcement +
zero-residue rejection + retry, AR/FR/EN localization, RBAC,
idempotency, PostgreSQL concurrency). The final debt-history UX fix
(§5.1/§15) and the debt-ceiling enforcement round (§2.1) both passed
manual verification.

1. PASS — Clients list: search debounce, pagination, show-archived toggle
   (AR/FR/EN).
2. PASS — Create client: empty name rejected, ceiling rejected when
   negative/garbled, success toast + list refresh.
3. PASS — Detail: balance/ceiling/over-limit hint; edit round-trip;
   archive blocked while in debt (localized toast) and allowed at zero.
4. PASS — Payment: overpayment blocked client-side (no request), backend
   422 shows localized dialog error, success toast + refreshed
   balance/history.
5. PASS — Idempotency: double-click pay button records exactly one
   payment.
6. PASS — Debt history: type icons, localized labels (incl. Pay All shown
   as `entry_type_full_payment` when the running balance hits 0), signed
   amounts (`+` sale / `-` payment), date **+ time**, running
   `balance_after`, invoice/user/note meta, pagination; entries stay
   visible after the balance reaches 0. *(Final debt-history UX fix —
   manual verification PASSED.)*
7. PASS — Debts screen: summary KPIs, debtors-only list, tile payment
   flow.
8. PASS — RBAC: user without `customer_view` sees no rail entries +
   denied state; view-only user sees no mutation buttons; cashier can
   record payments.
9. PASS — Ledger spot-check: projection equals ledger sum after manual
   payments.
10. PASS — Migration: fresh `alembic upgrade head` on empty DB + dev DB
    already at head; app boots and connects.
11. PASS — **Debt ceiling (bug-fix round):** credit/partial sale that
    would push `balance + new_debt` over the ceiling is rejected — payment
    dialog stays open showing the localized headline + amounts (AR/FR/EN),
    cart and selected customer preserved, retry after lowering the ceiling
    / raising the payment succeeds, and stock/balance/ledger are
    untouched in between; a ceiling of 0 keeps selling unlimited.
    *(Debt-ceiling enforcement — manual verification PASSED.)*

## 21. Status & Stop Line

**Phase 9 is APPROVED and CLOSED. Human QA PASSED** — every manual
checklist item (§20, 1-11) is PASS, including the debt-ceiling
enforcement round (§2.1, checklist item 11) and the final debt-history
UX round (§5.1/§15, checklist item 6).

Final verification (actual command output, §18/§19):

- Backend `pytest tests -q` → **595 passed** (3 pre-existing warnings)
- `flutter test` → **822 passed**
- `flutter analyze` → **No issues found!**
- `flutter build windows --debug` → **PASS** (built `supermarket_pos.exe`)
- `alembic current` / `alembic heads` → **`c8d4e5f6a1b2 (head)`** (single head)

Exactly one commit created for the whole phase:
`phase-9: complete customers debts payments` — working tree clean after
commit. **Phase 10 is NOT started.**

Still open (documented, deliberately not invented away): §2.2 overpayment
policy remains legacy-derived and flagged for explicit product
confirmation; the remaining §20 known limitations (blueprint params,
per-dialog idempotency key, picker shortcut, etc.) are unchanged
deviations.
