# Phase 13 — Expenses Implementation Record

**STATUS: CLOSED / APPROVED** · **HUMAN QA: PASS** · **TECHNICAL VERIFICATION: PASS** · **GIT: COMMITTED**
Date: 2026-09-29 · Decision record: `docs/PHASE_13_EXPENSES_ANALYSIS.md` (Step A approved;
23 RESOLVED · 5 DEFERRED · 0 UNVERIFIED)
Commit: `phase-13: complete expenses` — exactly one commit, not pushed.
Phase 12 baseline (untouched): commit `phase-12: complete returns and voids` (`ed72cae`),
Alembic head `f5a6b7c8d9e0` (0017), backend 790 / Flutter 1010 tests, `ruff check app` 64,
Human QA PASS 14/14. *(historical Phase 12 baseline, superseded by §0 for Phase 13)*

Scope delivered: **Expense lifecycle end-to-end** — migration 0018, RBAC (3 scopes),
model/schemas/repository/service/API, 60 API tests, and the Flutter list + summary + create +
cancel workflow with ar/fr/en localization. Category CRUD, approval, attachments, recurring,
offline queue, cash ledger, tax/discount/currency fields and every report/dashboard surface
remain **out of scope** (§6).

Fix Round 1: Expenses navigation entry restored by re-seeding the dev DB (§7) — **PASS**.
Fix Round 2: expense **title optional** end-to-end (migration 0019) and the
**customer debt aggregate balance** refresh fix (Flutter providers; backend proven correct) — §8 —
**PASS** (approved by the product owner).

**GATE 8 and GATE 9: RESOLVED.** Final role matrix (product-owner approved, all three roles
hold all three expense scopes):

| Role | `expense_view` | `expense_create` | `expense_cancel` |
|---|---|---|---|
| Admin | ✅ | ✅ | ✅ |
| Manager | ✅ | ✅ | ✅ |
| Cashier | ✅ | ✅ | ✅ |

---

## 0. Verification snapshot

| Command | Result |
|---|---|
| `python -m pytest -q` (backend) | **874 passed** (historical checkpoints: Fix Round 1 845, Phase 12 close 790) |
| `pytest tests/unit/test_expenses.py` | **60 passed** (44 API-level + 16 title-optional) |
| `pytest tests/integration/test_migrations.py` | **61 passed** (6 `TestPhase13ExpensesMigration` + 4 title-optional) |
| `pytest tests/unit/test_debt_aggregate_balance.py` | **10 passed** (new, Fix Round 2 debt regressions) |
| `python -m ruff check app` | **64** — unchanged baseline, 0 new findings |
| `alembic current` / `alembic heads` | **one head**: `2f6b9c4d8a31` (0019) = DB current revision |
| `alembic upgrade head` → `downgrade -1` → `upgrade head` | round-trip OK (0019 applied, reverted, re-applied) |
| `alembic check` | `No new upgrade operations detected.` |
| `flutter analyze` | **No issues found** |
| `flutter test` | **1049 passed** (Phase 12 baseline 1010) |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe` |
| Localization entries added | **40 keys × 3 locales = 120** (`lib/core/strings.dart`) |
| `PermissionScope` count | **30** (was 27; +`expense_view`/`expense_create`/`expense_cancel`) |
| Migration applied to dev DB | yes — `alembic current` reports `2f6b9c4d8a31` on PostgreSQL |
| Seed re-run (GATE 28 / D15) | **executed 2026-09-29** — `python -m app.core.seed` → `permissions=3, role_permissions=9, roles=0`; admin 30 / manager 25 / cashier 11 scopes, each holding the three expense scopes (see §7) |
| Read-only debt audit (dev DB) | 16 customers, 3 with >1 ledger rows, **0 mismatches** `customers.balance` vs `ledger_sum_for_customer` |
| Targeted suites | `test_expenses.py` + `test_debt_aggregate_balance.py` + `test_migrations.py` → **131 passed** |
| Human QA (product owner) | **PASS 14/14** (2026-09-29); Fix Round 1 **PASS**, Fix Round 2 **PASS** |

---

## 1. Files

### Backend — new

| File | Purpose |
|---|---|
| `migrations/versions/2026_09_29_1000_1a2b3c4d5e6f_0018_phase13_expenses.py` | adds `expenses.status` (VARCHAR 20, `posted`), `paid_from_drawer` (BOOLEAN, `true`), `cancelled_at` / `cancelled_by` (FK → `users.id` `ON DELETE SET NULL`) / `cancel_reason`, `client_request_id` (VARCHAR 100) + partial unique `ux_expenses_client_request_id` (`WHERE client_request_id IS NOT NULL`), `ix_expenses_expense_date`, `ix_expenses_user_id`; downgrade drops only these |
| `migrations/versions/2026_09_29_1400_2f6b9c4d8a31_0019_expense_title_optional.py` | **Fix Round 2** — `expenses.title` `NOT NULL` → nullable (the column was created `NOT NULL` in 0002; 0018 is applied and untouched); downgrade restores `NOT NULL` (fails while NULL rows exist, documented) |
| `app/schemas/expense.py` | `ExpenseCreateRequest`, `ExpenseCancelRequest`, `ExpenseResponse` (carries `idempotent_replay`), `ExpenseSummaryResponse`; `MONEY_MAX = Decimal("999999999999.999")`; **Fix Round 2**: `title: str | None = None` (max 200) + `_blank_title_is_none` validator, response `title: str | None` |
| `app/repositories/expense.py` | `search()` (`expense_date DESC, id DESC`, offset/limit + count), `summary()` (count/total/drawer/external via `case()`), `find_by_client_request_id()`, `cancel()` (rowcount-guarded Core `UPDATE` where `status == 'posted'`) |
| `app/services/expenses.py` | `list` / `summary` (filter validation), `create` (fast-path idempotency + transaction insert + `CREATE` audit + `IDEMPOTENCY_CONFLICT` on mismatch), `cancel` (404 / 409 / terminal attribution + `VOID` audit), `_audit`, module-level `to_response()` |
| `app/api/v1/expenses.py` | 4 routes: `POST ""`, `GET ""`, `GET "/summary"`, `POST "/{expense_id}/cancel"`; `require_permission(EXPENSE_CREATE/VIEW/CANCEL)`; optional `X-Device-ID` header |
| `tests/unit/test_expenses.py` | **60** tests: 44 API-level (GATE 1/4/5/7/8/9/10/11/12/13/14/15/21/27) + **Fix Round 2** `TestExpenseTitleOptional` (16) |
| `tests/unit/test_debt_aggregate_balance.py` | **Fix Round 2 (new)** — 10 regression tests for the aggregate customer balance (520+534=1054 → pay → 0 sequence, ledger-sum equality, detail API, atomicity) |

### Backend — modified

| File | Change |
|---|---|
| `app/models/enums.py` | `PermissionScope.EXPENSE_VIEW / EXPENSE_CREATE / EXPENSE_CANCEL`; `ExpenseStatus` (`posted`/`cancelled`) |
| `app/core/seed.py` | `ROLE_PERMISSIONS` — all three scopes granted to `admin`, `manager`, `cashier` |
| `app/models/expense.py` | lifecycle/payment/cancellation/idempotency columns, indexes, `ux_expenses_client_request_id`, single `user` relationship; **Fix Round 2**: `title` now `Mapped[str | None]` (`nullable=True`) |
| `app/services/expenses.py` | module-level `_normalize_title()` (None/blank → NULL, else trimmed), applied on insert, in both idempotency signatures, and in the audit row (`expense.title or "untitled"`) |
| `app/api/v1/router.py` | mounts the expenses router |
| `tests/unit/test_auth.py` | scope count 27 → 30; `test_every_role_holds_the_expense_scopes` |
| `tests/unit/test_enums.py` | 27 → 30, `TestExpenseStatus`, `test_expense_scopes_exist` |
| `tests/unit/test_models.py` | `test_create_expense` extended (status, `paid_from_drawer`, `client_request_id`, cancel fields) |
| `tests/integration/test_migrations.py` | `HEAD_REV = "2f6b9c4d8a31"` (7 sites) + `TestPhase13ExpensesMigration` (6 tests) + **Fix Round 2** `TestPhase13TitleOptionalMigration` (4 tests) |

### Flutter — new (`lib/features/expenses/`)

| File | Purpose |
|---|---|
| `expense_models.dart` (159) | `kExpenseCategories`, `expenseCategoryKey()`, `expenseStatusKey()`, `ExpenseItem`, `ExpenseListPage`, `ExpenseSummary` |
| `expenses_providers.dart` (309) | `ExpensesQuery` / `ExpensesState` / `ExpensesNotifier` (list + summary load, filters, pagination), `ExpensesApi.create/cancel` returning `(model, PosApiError?)` |
| `expenses_error.dart` (98) | `expensesApiError` / `expensesApiMessage` — envelope `code` → localized headline, raw backend text only as `detail` |
| `expenses_screen.dart` (552) | permission-gated header + add button, summary card, filter bar (search/category/payment/status/date range/clear), list, pagination, toasts |
| `expense_form_dialog.dart` (293) | create editor (title/category/amount/drawer switch/note) + per-open `client_request_id` |
| `expense_cancel_dialog.dart` (176) | terminal cancel with mandatory reason, localized failure line, dialog-local `Navigator.pop` |

### Flutter — modified

| File | Change |
|---|---|
| `lib/core/strings.dart` | +40 keys × ar/fr/en = 120 entries |
| `lib/router/app_router.dart` | `/expenses` route, `expenseViewScope = 'expense_view'`, gated nav destination (after Returns) + selected-index + `onDestinationSelected` sites |

### Flutter tests — new

| File | Tests |
|---|---|
| `test/unit/expenses_localization_test.dart` | 11 (40 keys × 3 locales, category + status labels, ar/fr/en differ) |
| `test/widget/expenses_screen_test.dart` | 15 (list + summary money, category/status/payment/search/date filters, create, cancel, RBAC ×2, **nav regression ×4**) |
| `test/widget/expense_form_dialog_test.dart` | 8 (validation, payload contract, fresh idempotency key, 409 localized, cancel reason/payload/409) |

---

## 2. Decision → implementation map

| # | Decision | Where it lives | Primary test |
|---|---|---|---|
| 1 | create → `posted`, corrections via `POST /{id}/cancel` | `services/expenses.py` | `test_expenses.py::TestExpenseCancel` |
| 2 | no edit / no hard delete (no PUT/DELETE route) | `api/v1/expenses.py` (4 routes only) | route surface + `test_cancel_never_touches_the_amount` |
| 3 | fixed `ExpenseCategory` enum, canonical codes, localized labels | `expenseCategoryKey()` + `strings.dart` `category_*` | `expenses_localization_test.dart` |
| 4 | `NUMERIC(18,3)`, `0 < amount <= MONEY_MAX`, no tax/discount | `schemas/expense.py` | `test_validation_rejects_bad_input` |
| 5 | `paid_from_drawer` informational only, default `true` | model + migration default; no ledger touched | `test_paid_from_drawer_defaults_to_true` |
| 7 | 3 scopes `expense_view`/`expense_create`/`expense_cancel` | `enums.py` + `require_permission(...)` per route | `TestExpensePermissions` |
| 8/9 | cashier **and** manager hold all three scopes (product-owner decision) | `seed.py` `ROLE_PERMISSIONS` | `test_every_role_holds_the_expense_scopes`, `test_every_seeded_role_holds_the_three_scopes` |
| 10 | required `client_request_id` + partial unique index + 409 on mismatch | migration index + `service.create` + `_money_key` signature | `TestExpenseIdempotency` (4) |
| 11 | insert-only create; cancel via rowcount-guarded `UPDATE` | `repositories/expense.py::cancel` | `test_cancel_is_terminal` |
| 12 | 4 endpoints, `expense_date DESC, id DESC` | `api/v1/expenses.py`, `repositories/expense.py` | `test_newest_first_and_monotonic_dates` |
| 13 | no detail/PUT/DELETE endpoints | `api/v1/expenses.py` | route list |
| 14 | `expense_date` server-assigned (no backdating from UI) | schema drops client `expense_date`; service sets it | `test_server_assigns_identity_fields` + payload-contract widget test |
| 15 | `status`, `cancelled_at/by`, `cancel_reason` | migration 0018 + model | `TestPhase13ExpensesMigration`, `test_cancel_records_attribution_and_keeps_the_row` |
| 16 | source data + `/summary` only | no report/dashboard file touched | §6 |
| 17 | UUID only, no human-readable number | `ExpenseItem.id` | list/summary tests |
| 18 | no supplier/customer link | not in schema/model | payload contract test |
| 20 | `X-Device-ID` header accepted | `api/v1/expenses.py::create_expense` | (client deviation — §3 D2) |
| 21 | 40 keys × 3 locales + generic reuse | `lib/core/strings.dart` | `expenses_localization_test.dart` |
| 22 | single reversible additive `0018`, no backfill | migration file | `TestPhase13ExpensesMigration` (6) |
| 23 | no CHECK constraints | migration has none | migration tests |
| 26 | permission-count assertions updated | `test_auth.py`, `test_enums.py` (27 → 30) | full suite green |
| 27 | `date_from`/`date_to` API + two date pickers | route `Query(date)`, service inclusive-day validation, `expenses-date-from/to` | `test_date_range_is_inclusive_of_the_whole_day`, `test_reversed_date_range_is_422`, date-picker widget test |
| 28 | seed re-run after migration | `python -m app.core.seed` (manual, D15) | role-scope tests read the seeded tables |

DEFERRED (unchanged, verified absent): 6 cash ledger, 16 report UI, 19 attachments/recurring/approval, 24 exports, 25 offline queue.

---

## 3. Implementation decisions and deviations

**D1 — `ExpenseListQuery` schema dropped.** The analysis sketched a reusable query model; the
`GET` routes declare their parameters inline (`FastAPI` `Query(...)`) and the date-ordering rule
(`date_from <= date_to`) is validated in `ExpenseService._validate_filters` so both `list` and
`summary` reject a reversed range with the same `VALIDATION_ERROR` 422. One behavior, one code
path, identical envelope for both endpoints.

**D2 — the Flutter client does not send `X-Device-ID`.** The endpoint accepts it (GATE 20, same
convention as returns/void), but the app has no device-identity concept yet and no other screen
sends one; sending a synthetic value would be fake attribution. The field is stored as `NULL`
until a device-identity story exists (deferred with GATE 6's ledger work).

**D3 — category label helper is code-based.** §15 sketched
`expenseCategoryLabel(Category, t)`; the implementation ships `expenseCategoryKey(code)` →
`'category_<code>'`, which the enum codes and the DB values already match (canonical English
codes, localized only at render time — legacy defect L6 fixed either way).

**D4 — client-side amount validation is a convenience, never authority.** The dialog checks only
"parses as money and > 0" via the shared `moneyToMilli()` integer parser (no floats, no rounding);
`MONEY_MAX`, the 3-decimal rule and the category enum are enforced server-side (422 envelope).
A rejected amount never reaches the API.

**D5 — idempotency signature normalizes money.** `120.5`, `120.500` and `120.50` are the same
expense; the signature is computed over `title|category|normalized_amount|paid_from_drawer`, so a
re-submit with a different money spelling still replays instead of 409'ing (verified by
`test_money_format_difference_still_replays` and its client twin).

**D6 — filter-bar label wiring.** The status dropdown is labelled `status`, and
`expense_date_range` is the caption over the two date buttons (a copy/paste slip found while
writing the widget tests).

**D7 — UI page size 25.** The list always sends `page_size=25`
(`AppConstants.defaultPageSize`); the API default of 40 (§6) applies only when the parameter is
omitted (curl/other clients).

---

## 4. Verification (technical) — FINAL

| Check | Result |
|---|---|
| `pytest -q` | **874 passed** |
| targeted `pytest tests/unit/test_expenses.py tests/unit/test_debt_aggregate_balance.py tests/integration/test_migrations.py -q` | **131 passed** (60 expense + 10 debt-aggregate + 61 migration) |
| new backend tests | `test_expenses.py` **60** (44 API-level + 16 title-optional), `test_debt_aggregate_balance.py` **10**, Phase 13 migration class tests **10** (6 + 4), plus scope/enum/model extensions |
| `ruff check app` | **64** — identical to the Phase 12 baseline (verified file-by-file against `ed72cae`: same 64 findings, only a line-number shift in `seed.py`); **0 new findings** |
| `alembic current` / `heads` | **one head** `2f6b9c4d8a31` (0019) = DB current revision |
| `alembic check` | `No new upgrade operations detected.` (no drift) |
| migration up → down → up | round-trip OK (0018 + 0019); also covered by `TestPhase13ExpensesMigration` / `TestPhase13TitleOptionalMigration` |
| `PermissionScope` count | 30, every seeded role holds the three expense scopes |
| `flutter analyze` | **No issues found** |
| `flutter test` | **1049 passed** (Phase 12 baseline 1010 + 39 new; 0 regressions) |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe` |
| Localization | 40 × 3 = 120 entries, none resolve to the raw key |
| SQLite behaviors proven in tests | tz-aware + naive + date bounds, `.ilike()`, `case()` aggregates as `Decimal`, `UPDATE` rowcount guard (1 then 0) |
| Read-only debt audit (dev DB) | 0 mismatches `customers.balance` vs ledger sum |

*Historical intermediate checkpoint (Fix Round 1, superseded by the table above): backend
**845** passed, Flutter **1043** passed, single Alembic head `1a2b3c4d5e6f` (0018).*

---

## 5. Human QA — **PASS** (14/14, 2026-09-29, product owner)

All 14 points below were executed manually on Windows with seeded `admin` / `manager` /
`cashier` and passed. Fix Round 1 (§7) and Fix Round 2 (§8) were approved separately.

Checklist as executed:

1. Rail shows **Expenses** for all three roles; `viewer`/guest gets *Permission denied* and no rail entry.
2. List opens on **posted** rows only, newest first, summary = count/total/from-drawer/outside-drawer.
3. Filters: search (title/note), category, payment (drawer/external), status posted/cancelled/all, date range both bounds inclusive, clear button.
4. Add expense: title/category/amount > 0/drawer switch/note → 201, toast, row appears, summary grows.
5. Validation: title optional (blank = no title, trimmed ≤ 200 when given), `0`, negative, non-numeric, >3 decimals → localized inline message, no request.
6. Idempotency: double-click *Save* (and retry after a network error) → exactly one row, second response `idempotent_replay=true`, same id.
7. Same key + different amount/title → 409 `IDEMPOTENCY_CONFLICT` shown localized, dialog stays open.
8. Cancel: requires a reason; posted → cancelled; amount untouched; row leaves the default list but shows under *all/cancelled* with reason + who + when.
9. Cancel guards: unknown id → 404, second cancel → 409 `EXPENSE_ALREADY_CANCELLED`, blank reason → 422.
10. Cancelled rows leave the summary; the same filters on `/summary` match the list.
11. Drawer vs external: both flag values round-trip and split the summary correctly.
12. Localization ar (RTL) / fr / en: header, summary, filters, both dialogs, status and category labels, toasts.
13. Regression: backend 874 green, Flutter 1049 green, analyze clean, migration up/down (0018+0019), Windows build, Phase 12 returns/voids untouched.
14. Product-owner sign-off: cashier may view/create/cancel (GATE 8/9), no category CRUD / approval / attachments / reports in this phase.

---

## 6. Not touched (forbidden / out of scope)

- No Phase 12 feature file changed. The only pre-existing test files touched are
  `tests/integration/test_migrations.py` (`HEAD_REV` moved to the new head + the appended
  `TestPhase13ExpensesMigration`), `test_auth.py` / `test_enums.py` (27 → 30 scopes) and
  `test_models.py` (expense column assertions) — returns, voids, stock and debt semantics are
  untouched.
- No `reports_screen.dart`, no `dashboard_screen.dart`, no export/printing code (GATE 16/24).
- No category CRUD UI/API, no approval workflow, no attachments, no recurrence (GATE 19).
- No cash-drawer ledger writes, no `net_profit` math, no reconciliation strip (GATE 6).
- No tax / discount / currency / exchange-rate fields, no float money, no client rounding.
- No offline queueing, no `except: pass`, no swallowed exceptions, no DELETE endpoint.
- `PermissionScope` grew only by the three expense scopes (27 → 30); no other scope or role
  semantics changed.

---

## 7. Fix Round 1 closeout — Expenses navigation entry (dev DB not re-seeded after 0018) - 2026-09-29 — **PASS**

**Cause in one line:** the dev database had not been re-seeded after migration **0018**, so the
`expense_*` permissions did not exist and the (correct) permission gate hid the nav entry.
Fix: `python -m app.core.seed`. No automatic startup seeding was introduced (D15).

**Finding (Human QA):** the Navigation Rail showed Dashboard, POS, Returns, Products, Packs,
Inventory, Clients, Debts, Suppliers, Purchases, Users, Settings - **no Expenses** entry - while
`/expenses` still routed correctly.

**Root cause: data, not code.** The navigation code in `lib/router/app_router.dart` was correct on
every point: `/expenses` route + `builder: ExpensesScreen()`, `expenseViewScope = 'expense_view'`,
`canViewExpenses = hasPermissionProvider(expenseViewScope)`, the destination `if (canViewExpenses)`
placed after Returns, the selected-index block and the `onDestinationSelected` block. The
destination is gated on `expense_view`, and scopes arrive from the login / `/auth/me` payload -
i.e. from PostgreSQL. Migration 0018 had been applied, but the documented post-migration seed
re-run (GATE 28 / D15) had never been executed, so the live DB held **zero `expense_*` rows in
`permissions`** (probe before fix: admin 27 / manager 22 / cashier 8 scopes, `expense = []` for all
three). `hasPermissionProvider('expense_view')` therefore returned `false` and the shell correctly
hid the gated destination. Backend and Flutter tests stayed green because their fixtures seed their
own data.

**Fix performed (data only):**

```
python -m app.core.seed
Seed complete: {'permissions': 3, 'roles': 0, 'role_permissions': 9}
```

Post-fix probe: `admin = 30`, `manager = 25`, `cashier = 11` scopes, each containing
`expense_view`, `expense_create`, `expense_cancel`. Session scopes are refreshed at login, so the
stale session needed a re-login / app restart.

**No code changed for this fix:** navigation logic, backend expense permissions, migration 0018,
Phase 12, and startup behaviour (still no auto-seed, per D15) are all untouched.

**Regression coverage added** - `test/widget/expenses_screen_test.dart`, group
`Expenses rail entry (Human QA regression)` (4 tests; the login stub now takes `roleName`):

| Test | Asserts |
|---|---|
| `admin sees the Expenses destination after Returns` | ar label present, index = Returns index + 1, tap -> `/expenses` renders (`expenses-title` + `expenses-list`) |
| `manager sees the Expenses destination after Returns` | same |
| `cashier sees the Expenses destination after Returns` | same |
| `a role without expense_view has no Expenses destination` | no Expenses label while Returns is still present |

Scope sets mirror the seeded matrices (admin broad / manager broad / cashier `pos_sale` +
`pos_return` + the three expense scopes).

**Fix Round 1 intermediate verification** (historical checkpoint at the end of Fix Round 1,
superseded by §0/§4): `flutter analyze` clean - `flutter test` **1043 passed** -
`flutter build windows --debug` OK - backend `pytest -q` **845 passed** - `ruff check app` **64**
(no new findings) - single Alembic head `1a2b3c4d5e6f` (0018) - `alembic check` no drift.

**Fix Round 1 result: PASS.** The rail entry and its permission gating are proven automatically by
the four regression tests above, and the product owner confirmed the entry in the manual
checklist (§5, **Human QA PASS 14/14**).

---

## 8. Fix Round 2 — 2026-09-29 (title optional + customer debt aggregate balance) — **PASS**

Two product-owner findings after the Phase 13 closeout. Both were investigated at source before
any code changed.

### 8.1 Expense title optional (schema change → migration 0019)

**Finding:** an expense could not be saved without a title.

**Root cause:** B1 was specified as "title required, trimmed, 1..200 chars" and was enforced in
three places — `ExpenseCreateRequest.title` (`str`, required, `min_length=1`), the Flutter
`expense_form_dialog` validation, and the list/detail rendering (which assumed a title always
existed). The column itself had been created `NOT NULL` by migration **0002**, so the change is
a genuine schema change; migration 0018 is already applied and was **not** modified.

**Change (B1 re-resolved):**

- `title` is optional end-to-end. When supplied it is trimmed and capped at 200 chars; `null`,
  `""` and whitespace-only are normalized to `NULL` (validator `_blank_title_is_none`,
  service `_normalize_title()`), so idempotency signatures and audit rows stay deterministic
  (`audit.title_text = expense.title or "untitled"`).
- Migration **0019** `2f6b9c4d8a31`
  (`2026_09_29_1400_2f6b9c4d8a31_0019_expense_title_optional.py`,
  `down_revision=1a2b3c4d5e6f`): `op.alter_column("expenses", "title", ... nullable=True)`;
  downgrade restores `NOT NULL` and therefore fails while NULL rows exist (documented in the
  revision docstring).
- Flutter: no title validation, the `title` key is omitted from the POST payload when blank,
  `ExpenseItem.title` is `String?`, and rows/dialogs render through
  `expenseTitleLabel(item, loc)` which falls back to the localized category label. The
  `expense_title_required` localization key is intentionally **kept** (unused by the UI, still
  asserted by `expenses_localization_test.dart`, so the 40 keys x 3 locales = 120 count is
  unchanged).

**Tests:** `test_expenses.py::TestExpenseTitleOptional` (16),
`test_migrations.py::TestPhase13TitleOptionalMigration` (4: single head, nullable at head, NULL
round-trip, upgrade/downgrade/upgrade), `expense_form_dialog_test.dart` validation group
rewritten (title omitted from the payload, only a bad amount blocks the POST).

### 8.2 Customer debt aggregate balance

**Finding:** "the customer detail balance does not go up when a new debt is added" and "a
payment seems to clear one debt and then move to the next one".

**Investigation before coding (read-only):** a script compared `customers.balance` with
`DebtLedgerEntryRepository.ledger_sum_for_customer()` on the dev PostgreSQL DB: **16 customers,
3 with more than one ledger row, 0 mismatches** (sample customer `islem`: balance `14.000` ==
ledger sum, 19 entries incl. sale 520 + payment 520 + sale 14). The write paths were then traced
and confirmed correct and atomic: sale (`customer.balance += debt` + `DebtLedgerEntry` in the
same transaction, ceiling check re-reads the row with `FOR UPDATE`), payment (overpayment
rejected with `PAYMENT_EXCEEDS_BALANCE`, no partial write), returns (reconciles `balance` with
the ledger and raises on mismatch), money stored as `NUMERIC(18,3)`.

**Root cause — Flutter only, stale cached providers.** `customerDetailProvider` and
`debtHistoryProvider` are non-autoDispose family providers that load exactly once per customer
id. `_CustomerDetailPaneState` had no `initState`/`didUpdateWidget` reload, and neither the
Debts-screen payment nor the POS credit sale refreshed them, so the detail card, the debtors row
and the payment dialog kept the snapshot taken at first open. The "one debt then the next" feel
came from the same stale snapshot being compared against freshly updated history rows.

**Fix (Phase 11 supplier pattern, no ledger semantics touched):**

| File | Change |
|---|---|
| `lib/features/clients/clients_providers.dart` | `CustomerDetailNotifier.load({bool silent = false})` — background re-read without a loading flash |
| `lib/features/clients/clients_screen.dart` | `_CustomerDetailPaneState.initState` + `didUpdateWidget` + `_refreshFromServer()` (silent detail + history refresh, skipped while a first-ever load is in flight) |
| `lib/features/debts/debts_screen.dart` | after a payment: refresh `customersProvider` (guarded) + silent `customerDetailProvider(id)` reload + `debtHistoryProvider(id).refresh()` — only for providers that are already alive (`ref.exists`) |
| `lib/features/pos/pos_screen.dart` | after a credit checkout (`debt > 0`): refresh `customersProvider` / `debtorsProvider` / `debtSummaryProvider`, each guarded with `ref.exists` so a never-opened screen triggers no fetch |

**This was not a backend ledger corruption bug.** The backend ledger and `customers.balance` were
verified correct and atomic before and after the fix; a read-only audit of the dev DB found
**0 mismatches**. The defect was purely stale Flutter provider state, fixed at the
refresh/provider-lifecycle level, with regression tests added on both the Flutter and backend
sides.

**Tests (5 Flutter + 10 backend):**

- `test/widget/clients_screen_test.dart` — group `Fix Round 2 — customer balance is the ledger
  aggregate`: (1) list row and detail card show the same aggregate, (2) silent reload replaces
  the stale balance without a spinner flash, (3) a payment recorded on the Debts screen re-reads
  the open detail card (and shows the fresh number on return), (4) two debts are summed and a
  payment never switches to the other debt or drops a history row.
- `test/widget/debts_screen_test.dart` — payment re-reads the debtor row (new aggregate) and
  never creates an unopened customer-detail provider.
- `tests/unit/test_debt_aggregate_balance.py` (new, 10 tests) — the reported numbers end to end
  (520 + 534 = 1054 → pay 500 → 554 → +200 → 754 → pay 754 → 0), `customers.balance` ==
  ledger sum at every step, detail API agrees, overpayment still rejected with no ledger row,
  history keeps all 5 entries with exact running balances, and debt creation/payment remain
  atomic (ceiling breach and overpayment leave balance, ledger and sales untouched).

### 8.3 Fix Round 2 verification

| Command | Result |
|---|---|
| `python -m pytest -q` | **874 passed** |
| `python -m ruff check app` | **64** (unchanged baseline) |
| `alembic upgrade head` / `downgrade -1` / `upgrade head` | round-trip OK, **one head `2f6b9c4d8a31`**, `alembic check` no drift |
| `flutter analyze` | No issues found |
| `flutter test` | **1049 passed** |
| `flutter build windows --debug` | OK |
| Read-only balance audit | 0 mismatches on the dev DB (16 customers) |

**Fix Round 2 result: PASS** (approved with the Human QA sign-off).

---

## 9. Final closeout — Phase 13

| Item | Result |
|---|---|
| STATUS | **CLOSED / APPROVED** |
| HUMAN QA | **PASS** (14/14, including ar/fr/en, RTL, drawer vs external, idempotency, customer aggregate debt balance) |
| TECHNICAL VERIFICATION | **PASS** — backend **874** passed, Flutter **1049** passed, `flutter analyze` clean, Windows debug build OK, `ruff check app` **64** (baseline, 0 new), single Alembic head `2f6b9c4d8a31` (0019), `alembic check` no drift |
| Fix Round 1 (seed) | **PASS** |
| Fix Round 2 (title optional + debt aggregate) | **PASS** |
| GATE 8 / GATE 9 | **RESOLVED** (admin = manager = cashier: `expense_view` + `expense_create` + `expense_cancel`) |
| Phase 11 / Phase 12 | unchanged, green |
| GIT | **COMMITTED** — one commit, `phase-13: complete expenses` (not pushed) |
