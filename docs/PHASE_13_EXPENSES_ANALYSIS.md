# PHASE 13 — EXPENSES: ANALYSIS / DECISION RECORD

Status: **CLOSED / APPROVED** — this decision record is **Step A** of the Phase 13 workflow and is
now fully executed: **HUMAN QA: PASS** · **TECHNICAL VERIFICATION: PASS** · **GIT: COMMITTED**
(`phase-13: complete expenses`, one commit, not pushed).
Final numbers: backend **874** tests, Flutter **1049** tests, `flutter analyze` clean,
`ruff check app` **64** baseline (0 new findings), Windows debug build OK, Alembic
**single head `2f6b9c4d8a31`** (0019) with `alembic check` no drift.
Phase 12 baseline: commit `phase-12: complete returns and voids` (`ed72cae`), Alembic head `f5a6b7c8d9e0` (0017),
backend 790 / Flutter 1010 tests green, `ruff check app` 64 baseline, Human QA PASS 14/14
(historical Phase 12 baseline — untouched by Phase 13).
Historical intermediate checkpoint (Step B/C, superseded): migration `1a2b3c4d5e6f` (0018) applied,
backend **845** tests, Flutter **1043** tests, `ruff check app` 64 (unchanged),
`flutter analyze` clean, `flutter build windows --debug` OK.
Fix Round 2 (2026-09-29): **B1 re-resolved — `title` is OPTIONAL** (blank/`null` → `NULL`,
supplied title trimmed ≤ 200), migration **0019** `2f6b9c4d8a31` makes `expenses.title` nullable,
and the reported **customer debt aggregate balance** defect was fixed (root cause: stale
non-autoDispose Flutter providers; backend ledger/balance proven correct, read-only audit
0 mismatches) → backend **874**, Flutter **1049**, one head `2f6b9c4d8a31`. Details in
`docs/PHASE_13_IMPLEMENTATION.md` §8.
Seed re-run (GATE 28 / D15) **executed 2026-09-29** after 0018: `python -m app.core.seed` →
`permissions=3, roles=0, role_permissions=9`; admin 30 / manager 25 / cashier 11 scopes, each holding
the three expense scopes. The Human QA navigation finding caused by the missing post-migration seed
and its data-only fix are recorded in `docs/PHASE_13_IMPLEMENTATION.md` §7 (Fix Round 1 **PASS**).
See `docs/PHASE_13_IMPLEMENTATION.md` for the file-by-file report, the Human QA checklist
(**PASS 14/14**) and the final closeout table (§9).
GATE 8 and GATE 9 are **RESOLVED** (final role matrix in §11/§20); no blocking questions remain.
Every rule in this record is marked **RESOLVED** or **DEFERRED**; **0 UNVERIFIED**.

**Step A boundary (historical):** this document originally described changes only, before any
code, migration, Flutter screen or commit existed for Phase 13. It is retained unchanged in
substance as the decision record; implementation status now lives in
`docs/PHASE_13_IMPLEMENTATION.md`.

---

## 0. Evidence base

| Source | Path | Role |
|---|---|---|
| Phase 0 roadmap | `docs/PHASE_0_ROADMAP.md` Phase 13 | scope authority ("Expense CRUD, Category management, Drawer vs external payment, Expense reporting"; dependency Phase 3) |
| Phase 0 feature matrix | `docs/PHASE_0_FEATURE_MATRIX.md:15` | "Expenses \| DB/UI \| expenses \| no immutable audit \| category/approval/audit \| P1 / 13" |
| Phase 0 API blueprint | `docs/PHASE_0_API_BLUEPRINT.md:478-488` | endpoint intent (`GET /expenses`, `POST /expenses`, `DELETE /expenses/{id}`) |
| Phase 0 DB analysis | `docs/PHASE_0_DATABASE_ANALYSIS.md:22,47` | target schema notes |
| Phase 0 business rules | `docs/PHASE_0_BUSINESS_RULES.md` | **no expense rules present** (confirmed by full read) |
| Phase 14 boundary | `docs/PHASE_0_ROADMAP.md` Phase 14 | Reports/Dashboard: date-range selector, exports, KPIs — **not Phase 13** |
| Legacy DB layer | `python_app/database/db_manager.py` | DDL, CRUD, financial report (evidence) |
| Legacy GUI | `python_app/gui/main_window.py` | list, add dialog, delete, reports, exports (evidence) |
| Legacy reports | `python_app/modules/reports.py:104-118` | expense bundle handed to exports |
| Legacy routes | `python_app/server/server.py` | **no expense endpoint** (confirmed by grep) |
| Current model | `new_app/backend/app/models/expense.py` | table already exists (0002) |
| Current enums | `new_app/backend/app/models/enums.py:139` (`ExpenseCategory`), `:18` (`PermissionScope`), `:161` (`AuditAction`) | reusable enums |
| Reusable patterns | `app/services/purchases.py`, `app/services/void.py`, `app/services/debt.py`, `app/api/dependencies.py`, `app/schemas/common.py` | service/audit/pagination/idempotency template |
| Flutter patterns | `lib/features/purchases/*`, `lib/features/returns/return_void_dialog.dart`, `lib/core/strings.dart`, `lib/router/app_router.dart` | screen/dialog/permission template |
| Report template | `docs/PHASE_11_PURCHASES_ANALYSIS.md` | section/gate structure of this document |
| Live DB (read-only) | `C:\Users\MSI\AppData\Local\Temp\opencode\inspect_expenses.py` | column/index/row-count/role-scope verification |

---

## 1. Scope

**In scope (Phase 13):**
1. Expense **list** (paginated, filtered, server-side) — screen + providers.
2. Expense **create** (title, category, amount, drawer/external, note) — dialog + service.
3. Expense **cancel** (reason mandatory) — dialog + service; corrections by cancel + re-create.
4. Expense **summary** endpoint (total / drawer / external / count) — header metrics only.
5. Schema migration 0018 (status, cancellation attribution, payment flag, idempotency key, date index).
6. Three new permission scopes + seed update; localization keys ar/fr/en.
7. Backend unit/integration tests + Flutter unit/widget tests.

**Out of scope (see §20):** reports page, charts, exports/printing, DB-backed category CRUD,
approval workflow, attachments, recurring expenses, drawer/cash reconciliation, offline queueing.

**Deviation from Phase 0 wording (documented per §2 of the workflow):** Phase 0 says "Expense
**CRUD**" and the blueprint exposes `DELETE /expenses/{id}`. This record replaces hard delete with
an audited **cancel** lifecycle (see GATE 1/2, §8, §16). Roadmap item "Category management"
becomes "fixed enum categories" (GATE 3).

---

## 2. Legacy evidence (not authority)

### 2.1 Data model

| Item | Legacy value | Source |
|---|---|---|
| Table | `expenses` | `db_manager.py:653-662` |
| Columns | `id`, `title VARCHAR(150)`, `category VARCHAR(50)`, `amount DOUBLE`, `paid_from_drawer TINYINT DEFAULT 1`, `device_name`, `expense_date DATETIME DEFAULT CURRENT_TIMESTAMP`, `note` | `db_manager.py:653-662` |
| Indexes | `idx_expenses_date`, `idx_expenses_device` | `db_manager.py:2195-2196` |
| Money type | **`DOUBLE` (float)** | `db_manager.py:659` |
| Attribution | **device only — no user/employee column** | DDL |
| Status | **none** (rows only ever exist) | DDL |
| Idempotency key | none | DDL |

### 2.2 Workflows (traced)

| # | Workflow | Trace |
|---|---|---|
| W1 | **Navigate** → "💸 المصاريف والفواتير" | nav tuple `main_window.py:2158`, page entry `:1801`; gate `_guard_db_nav` `:2391-2398` checks **DB readiness only** |
| W2 | **List** `show_expenses()` `:13420-13505` → `get_expenses(None, None, device)` `db_manager.py:1553` | no date filter (all rows); device filter: server sees all devices, client sees own device; `ORDER BY expense_date DESC, id DESC`; summary metrics `total_all`, `total_drawer`, `total_external`, `count` computed in Python `:13448-13450` |
| W3 | **Add** `_add_expense_dialog()` `:13507-13572` → `add_expense()` `db_manager.py:1517` | title required (client), 6 category options, amount `>0` (client only), drawer checkbox **default ON**, note; `device_name` from `_get_device_name()`; `expense_date` = server `CURRENT_TIMESTAMP` (no backdating) |
| W4 | **Delete** confirm `:13574-13581` → `delete_expense()` `db_manager.py:1592` | hard `DELETE`, no reason, **no audit**, returns `True` even when 0 rows matched |
| W5 | **Reports** `get_financial_report()` `db_manager.py:1175-1188` | `expenses_total = SUM(amount)`, `expenses_drawer = SUM(amount) WHERE paid_from_drawer=1`, `net_profit = net_sales − cogs − expenses_total` |
| W6 | **Drawer reconciliation strip** `main_window.py:13763-13788` | displays `manguif_from_drawer` alongside paid cash, credit sales, debts collected, cash returns — **display only, no computed expected-cash formula** |
| W7 | **Export** CSV `:13948-13952`, XLSX sheet 3 `:14062-14066`, column headers `:14091-14093`, PDF `:14266` | driven by `modules/reports.py:104-118` |
| W8 | **Audit / permissions / approval** | **absent** — `log_action()` is never called for expenses (grep across `python_app/`); no PIN/role check beyond DB readiness; no server route |

### 2.3 Legacy defects (unsafe / violating current rules)

| ID | Defect | Impact on Phase 13 |
|---|---|---|
| L1 | `amount DOUBLE` float arithmetic | violates money rule → `Numeric(18,3)` (GATE 4) |
| L2 | `>0` validated **only in the UI**; `float(amount or 0)` accepts 0/negative from other callers | server-side validation required (GATE 4) |
| L3 | Hard delete of a financial row, no reason, no audit | replaced by cancel (GATE 1/2) |
| L4 | `delete_expense()` returns `True` when 0 rows deleted | no delete path at all (GATE 2) |
| L5 | All exceptions swallowed (`add`/`get`/`delete` return empty/success) | services raise typed HTTP errors (§6) |
| L6 | `category` stores **Arabic text regardless of UI locale** (`_to_ar()` `main_window.py:1682-1707`, applied `:13557`) | store canonical enum codes (GATE 3) |
| L7 | No user attribution | `user_id` from token (GATE 6) |
| L8 | No idempotency | `client_request_id` required (GATE 10) |
| L9 | No list date filter; report period filtering only in Reports | list gets date-range filter (GATE 27); full report UI deferred (§16) |

### 2.4 Discrepancy register (legacy ↔ current ↔ proposed)

| # | Topic | Legacy | Current (Phase 12) | Proposed (Phase 13) | Status |
|---|---|---|---|---|---|
| D1 | `title` length | 150 | model 200 (`models/expense.py`) | **200** (keep current model) | RESOLVED |
| D2 | `category` | localized Arabic free text, no index | `String(30)` + `ix_expenses_category`, `ExpenseCategory` enum | **enum codes** in existing column | RESOLVED |
| D3 | `amount` | `DOUBLE` | `numeric_money()` NUMERIC(18,3), `Decimal` | unchanged | RESOLVED |
| D4 | `paid_from_drawer` | `TINYINT DEFAULT 1` | **absent from model** | `Boolean NOT NULL DEFAULT true` | RESOLVED |
| D5 | `device_name` (TEXT) | present, manual device string | `device_id` UUID-ish string via `X-Device-ID` header | keep current header convention | RESOLVED |
| D6 | `expense_date` | DATETIME + `idx_expenses_date` | `timestamptz server_default now()`, **no index** | keep server-assigned + **add index** | RESOLVED |
| D7 | `user_id` | absent | `FK users.id SET NULL` (already in model, **no index**) | populate from token + **add index** | RESOLVED |
| D8 | status / cancellation | absent | absent | `status`, `cancelled_at`, `cancelled_by`, `cancel_reason` | RESOLVED |
| D9 | idempotency | absent | absent | `client_request_id` + partial unique index | RESOLVED |
| D10 | delete | hard `DELETE` | blueprint `DELETE /expenses/{id}` | **no DELETE endpoint**; `POST /{id}/cancel` | RESOLVED |
| D11 | permissions | none | table exists, **0 rows** | 3 new scopes | RESOLVED (cashier gate resolved by GATE 8) |
| D12 | audit | none | `AuditAction.CREATE/VOID` reusable | `CREATE` on insert, `VOID` on cancel | RESOLVED |
| D13 | summary | computed in Python over full result | none | `GET /expenses/summary` SQL aggregate | RESOLVED |
| D14 | report math | `net_profit − expenses` | none in Phase 13 | **deferred to Phase 14** | DEFERRED |
| D15 | seed execution | n/a | `app/core/seed.py` runs only via `python -m app.core.seed` | document manual re-seed step in §21 | RESOLVED |

---

## 3. Current architecture (what already exists and is reused)

- **Table exists**: `new_app/backend/app/models/expense.py` → `expenses(id, title String(200),
  category String(30) index, amount Numeric(18,3), note Text, user_id FK SET NULL, device_id,
  expense_date timestamptz server_default now())`. **No rows in dev DB** (verified read-only).
- **Enum exists**: `ExpenseCategory` (`models/enums.py:139`) = `rent, utilities, salary,
  maintenance, supplies, transport, other` — already covered by
  `tests/unit/test_enums.py::TestExpenseCategory` and `tests/unit/test_models.py:314`.
- **Expected tables**: `tests/unit/test_models.py:81 EXPECTED_TABLES` already contains
  `expenses` (23 tables) → **no EXPECTED_TABLES change required** (verified).
- **Permission seeds**: `app/core/seed.py::ROLE_PERMISSIONS` (admin receives every scope
  automatically; manager/cashier lists are explicit) → 3 lines added, 3 tests updated.
- **Patterns reused verbatim**: `BaseService.transaction()` + `_audit()` (`services/purchases.py`,
  `services/void.py`), `require_permission` + `PaginationParams` (`api/dependencies.py`,
  `schemas/common.py`), `/summary` endpoint shape (`api/v1/debts.py`), `client_request_id`
  conflict handling (`services/returns.py`), `PaginatedResponse[T]`.
- **Flutter**: `purchases_screen.dart` (filter row + DataTable + pagination), `purchases_providers.dart`
  (`PurchasesQuery`/`StateNotifier`), `purchase_form_dialog.dart` (dialog + toast + error mapping),
  `return_void_dialog.dart` (reason-required confirm), `posDeviceIdProvider`
  (`features/pos/pos_providers.dart:39`), `permission_helpers.dart` + `app_router.dart` scope gating,
  `stock_screen.dart` filter widgets (`TextField` + `DropdownButtonFormField` + `FilterChip`).
- **Known test surface that hard-codes the permission count (27 → 30)**:
  `tests/unit/test_auth.py:661`, `tests/unit/test_auth.py:681`, `tests/unit/test_enums.py:45`.

---

## 4. Proposed domain model

```
Expense (aggregate root, append-mostly)
  id                UUID PK
  title             String(200) NULL     OPTIONAL (Fix Round 2): supplied -> trimmed 1..200, blank/null -> NULL
  category          ExpenseCategory      required, canonical code (String(30), indexed)
  amount            Decimal NUMERIC(18,3) required, > 0, <= MONEY_MAX
  paid_from_drawer  Boolean NOT NULL DEFAULT true
  note              Text NULL            optional, <= 2000 chars
  status            ExpenseStatus        posted | cancelled      (NEW)
  client_request_id String(100) NULL     idempotency key, unique when NOT NULL (NEW)
  user_id           UUID NULL FK users SET NULL   (attribution, existing)
  device_id         String NULL          (X-Device-ID, existing)
  expense_date      timestamptz          server now(), immutable, indexed (NEW index)
  created_at        timestamptz          (existing)
  cancelled_at      timestamptz NULL     (NEW)
  cancelled_by      UUID NULL FK users SET NULL   (NEW)
  cancel_reason     String(200) NULL     (NEW)
```

- `ExpenseStatus` is a **new enum class** (`posted`, `cancelled`), mirroring `PurchaseStatus`
  (`enums.py:199`). No existing enum values are modified (GATE 6).
- `ExpenseCategory` values are **not modified**; only used (GATE 3).
- **No** `expense_number`/human reference — UUID only (GATE 17). **No** supplier/customer link
  (GATE 18). **No** tax/discount/currency columns (GATE 4). **No** attachments (GATE 19).
- `paid_from_drawer` is a **classification flag**, not a ledger posting (GATE 5/6).

---

## 5. Database changes

| Change | Statement | Justification |
|---|---|---|
| `status` | `ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'posted'` | enables audited correction without delete (GATE 1) |
| `cancelled_at` / `cancelled_by` / `cancel_reason` | `ADD COLUMN ... NULL` (+ FK `ON DELETE SET NULL` for `cancelled_by`) | cancellation attribution (GATE 6) |
| `paid_from_drawer` | `ADD COLUMN paid_from_drawer BOOLEAN NOT NULL DEFAULT true` | legacy parity; legacy default was `1` → `true` is the data-preserving mapping for any future import (GATE 5) |
| `client_request_id` | `ADD COLUMN client_request_id VARCHAR(100) NULL` + partial `UNIQUE INDEX (client_request_id) WHERE client_request_id IS NOT NULL` | replay safety for pre-existing/nullable rows (GATE 10) |
| date index | `CREATE INDEX ix_expenses_expense_date ON expenses (expense_date)` | range filtering + list ordering (GATE 27) |
| user index | `CREATE INDEX ix_expenses_user_id ON expenses (user_id)` | attribution lookups; matches other tables' FK indexing |
| amount default | **no change** (`numeric_money()` is `NOT NULL`, no default) | avoids introducing a `0` default that would violate `>0` |
| CHECK constraints | **none added** | no CHECK constraint exists anywhere in models/migrations today (verified); validation is Pydantic-side — introducing one would be a new project-wide pattern (GATE 23) |
| `category` column | **unchanged** (`String(30)` + existing index) | enum codes fit |
| data backfill | **none required** | dev DB has **0 expense rows**; legacy DB is a separate SQLite/MySQL instance that is **not** migrated by Alembic (verified: no legacy import path exists) |

---

## 6. API design

Base: `/api/v1/expenses`. All JSON, all permission-gated.

### 6.1 `GET /api/v1/expenses` — permission `expense_view` — RESOLVED
Query: `page` (default 1), `page_size` (default 40, max 100), `q` (ILIKE on title/note),
`category` (enum code), `paid_from_drawer` (bool), `date_from`/`date_to` (inclusive `date`),
`status` (`posted` **default** | `cancelled` | `all`).
Ordering: fixed `expense_date DESC, id DESC` (no client-sortable field).
Response: `PaginatedResponse[ExpenseResponse]`.
No `device_id` query param — device filtering is **not** replicated from legacy (D5): the new
backend is multi-user, not multi-device-master; list is filtered by permission scope only.
**RESOLVED** (documented deviation from legacy W2).

### 6.2 `GET /api/v1/expenses/summary` — permission `expense_view` — RESOLVED
Query: same filter set as 6.1 (`status` default `posted`).
Response: `ExpenseSummaryResponse { count, total_amount, drawer_amount, external_amount }`
(SQL aggregate `SUM`/`COUNT`, `Decimal`) — mirrors legacy Python metrics (W2/W5).
Mounts **before** `/{expense_id}` style routes (no detail route exists, so no ambiguity).

### 6.3 `POST /api/v1/expenses` — permission `expense_create` — RESOLVED
Headers: `X-Device-ID` (optional, as Phase 12 returns/void).
Body: `client_request_id` **required** (1..100), `title` (**optional** since Fix Round 2; 1..200
when given, blank/`null` stored as `NULL`), `category` (enum),
`amount` (Decimal `>0`, `<= MONEY_MAX = Decimal("999999999999.999")`),
`paid_from_drawer` (optional, default `true`), `note` (optional, <= 2000).
Response: **201** `ExpenseResponse { ..., idempotent_replay: bool }`.
Replay: same key + same signature → 201 with `idempotent_replay: true` (Phase 12 returns
convention). Same key + different payload → **409 `IDEMPOTENCY_CONFLICT`**.
Server assigns `id`, `expense_date = now()`, `user_id`, `device_id`, `status = posted`.

### 6.4 `POST /api/v1/expenses/{expense_id}/cancel` — permission `expense_cancel` — RESOLVED
Body: `reason` **required** (1..200, non-blank) — mirrors Phase 12 void reason mandate.
Response: 200 `ExpenseResponse` (status `cancelled`).
Errors: 404 `EXPENSE_NOT_FOUND`, 409 `EXPENSE_ALREADY_CANCELLED`.
Writes `cancelled_at/cancelled_by/cancel_reason`; **never deletes the row**.

### 6.5 Explicitly not built — RESOLVED
| Endpoint | Reason | Gate |
|---|---|---|
| `GET /expenses/{id}` | list already returns full row; no UI needs a detail page | GATE 13 |
| `PUT/PATCH /expenses/{id}` | posted rows are immutable; corrections = cancel + re-create | GATE 13 |
| `DELETE /expenses/{id}` | financial history must survive (replaces blueprint DELETE, D10) | GATE 13 |
| `GET/POST/PATCH /expenses/categories` | fixed enum, localized in UI | GATE 3 |
| `GET /expenses/export`, print | Phase 14 owns exports | GATE 24 |

Error body shape, pagination envelope, and `X-Request-ID` logging follow Phase 12 exactly
(`ExpenseNotFound` → 404, `ExpenseAlreadyCancelled` → 409, `IdempotencyConflict` → 409).

---

## 7. Business rules

| ID | Rule | Status |
|---|---|---|
| B1 | `title` **optional** (Fix Round 2): omitted / `null` / blank → stored `NULL`; supplied title trimmed, 1..200 chars | RESOLVED (revised 2026-09-29, migration 0019) |
| B2 | `category` required, must be an `ExpenseCategory` code; unknown → 422 | RESOLVED |
| B3 | `amount` required, `Decimal`, `> 0`, `<= MONEY_MAX` | RESOLVED |
| B4 | `paid_from_drawer` defaults `true` when omitted (legacy default `1`) | RESOLVED |
| B5 | `note` optional, <= 2000 chars | RESOLVED |
| B6 | `expense_date` is assigned by the server; **no client backdating** (legacy parity W3) | RESOLVED |
| B7 | `user_id` = authenticated user creating the row; never client-supplied | RESOLVED |
| B8 | A `posted` expense is immutable: no edit, no delete | RESOLVED |
| B9 | A `cancelled` expense may not be cancelled twice (409) and cannot be re-opened | RESOLVED |
| B10 | Cancelling requires a non-blank reason (1..200) | RESOLVED |
| B11 | `cancelled` rows are excluded from `summary` and from `status=posted` lists by default; retained for audit | RESOLVED |
| B12 | `q` matches `title` **or** `note` (case-insensitive) | RESOLVED |
| B13 | `date_from`/`date_to` are inclusive calendar dates in the **server** timezone; `date_from > date_to` → 422 | RESOLVED |
| B14 | Categories are a fixed enum; no DB-backed add/archive (roadmap "Category management" narrowed) | RESOLVED (roadmap deviation, §1) |

---

## 8. Lifecycle

```
            POST /expenses (201)
                    │
                    ▼
              ┌──────────┐   POST /{id}/cancel (reason)   ┌────────────┐
              │  posted  │ ──────────────────────────────▶ │ cancelled  │
              └──────────┘                                └────────────┘
                    │                                              │
                    └── immutable (no PUT, no DELETE) ────── terminal (no reverse)
```

- State transitions: **exactly one** (`posted → cancelled`), executed inside
  `BaseService.transaction()` with an optimistic guard on `status`.
- No draft state, no approval state, no reopening, no soft-delete flag alongside status.
- Statuses visible in UI: Active / Cancelled (with date + reason in an inline expansion or badge).
- **RESOLVED** (GATE 1/2). Deviation from blueprint `DELETE` and roadmap "CRUD" is recorded in §1.

---

## 9. Money rules

| Aspect | Decision | Status |
|---|---|---|
| Backend type | `Decimal` + `numeric_money()` → `Numeric(18,3)` (existing column, unchanged) | RESOLVED |
| Validation | `gt=0`, `le=MONEY_MAX` in `app/schemas/expense.py` (pattern from `schemas/purchase.py`) | RESOLVED |
| Zero/negative | rejected server-side (fixes legacy L2) | RESOLVED |
| Rounding | none beyond column scale (3 dp); no half-up helpers needed (single-field, no computed totals in Phase 13 beyond `SUM`) | RESOLVED |
| Tax / discount / currency fields | **not added** — expenses are single gross amounts | RESOLVED |
| `SUM` aggregation | SQL `SUM(amount)` over `Decimal` column → returned as `Decimal` | RESOLVED |
| Flutter display | 2 decimal places via `AppConstants.moneyDecimalPlaces`, unit key `currency` (`'DA'`, existing in all 3 locales) | RESOLVED |

---

## 10. Cash / payment impact

- Legacy semantics preserved: `paid_from_drawer = true` → paid from cash drawer (cash);
  `false` → paid outside the drawer (bank/external/carded). Legacy label pair:
  "من الصندوق (نقدي)" / "خارج الصندوق" (`main_window.py:708`, `:741`).
- **No cash ledger exists in the new backend** (grep for drawer/cash-register models → zero hits).
  Therefore `paid_from_drawer` is **informational only**: it does not mutate cash balances,
  does not create a transaction, and is not reconciled against anything in Phase 13.
  **RESOLVED** (GATE 5).
- The legacy **drawer reconciliation strip** (`main_window.py:13763-13788`) and
  `net_profit = net_sales − cogs − expenses_total` (`db_manager.py:1175-1188`) are
  **reporting concerns → Phase 14**. Phase 13 only guarantees the source column is correct
  and queryable. **DEFERRED** (GATE 6).
- Consequence documented for Step B: if a future phase introduces a cash ledger, expenses
  recorded with `paid_from_drawer=true` must be replayed/posted against it — a
  **retroactive import risk accepted** (0 legacy rows exist; new rows carry full attribution).

---

## 11. Permissions

| Scope | Rationale | Grants |
|---|---|---|
| `expense_view` | financial data must not be world-readable; gates nav entry + list + summary (legacy had **no** gate, D11) | `GET /expenses`, `GET /expenses/summary` |
| `expense_create` | recording money-out must be attributable and limited (mirror `purchase_create`) | `POST /expenses` |
| `expense_cancel` | reversing a posted financial record is strictly higher privilege (mirror `purchase_delete` / `pos_void`) | `POST /expenses/{id}/cancel` |

- All three added to `PermissionScope` (`enums.py`), `ROLE_PERMISSIONS` in `app/core/seed.py`
  (admin auto-receives all scopes), and the `PermissionScope`-count assertions in
  `tests/unit/test_auth.py:661`, `:681`, `tests/unit/test_enums.py:45` (27 → 30).
- **Total scopes: 27 → 30.**
- Router/nav gating: `/expenses` route + nav-rail entry gated by `expense_view`
  (`app_router.dart` scope constants + `permission_helpers.dart`); cancel button gated by
  `expense_cancel`; add button gated by `expense_create`.
- Seed does **not** run at startup (D15) → Step B must document
  `python -m app.core.seed` after migration.

| Question | Status |
|---|---|
| Does **cashier** get `expense_view` + `expense_create` + `expense_cancel`? | **RESOLVED** (GATE 8) — all three scopes granted by product-owner decision. |
| Does **manager** get `expense_cancel`? | **RESOLVED** (GATE 9) — `expense_view` + `expense_create` + `expense_cancel`. |

**Final role matrix (GATE 7 + 8 + 9, all roles identical):**

| Role | `expense_view` | `expense_create` | `expense_cancel` |
|---|---|---|---|
| admin | ✅ | ✅ | ✅ |
| manager | ✅ | ✅ | ✅ |
| cashier | ✅ | ✅ | ✅ |

(admin still receives every scope automatically via `ROLE_PERMISSIONS` admin rule.)

---

## 12. Audit

- `AuditAction` values **used, none added**: create → `CREATE`, cancel → `VOID`
  (precedent: purchases draft delete → `DELETE`, purchase cancel → `VOID`).
- `entity_type = "expense"` (string; the audit model stores free-form entity type).
- Payloads: create → `{id, title, category, amount, paid_from_drawer, expense_date}`;
  cancel → `{id, reason, status}` (+ preserved original amount/category).
- Actor (`user_id` from token) and timestamp come from the shared `_audit()` helper
  (`services/purchases.py` pattern).
- **RESOLVED** (GATE 6: no enum additions). Fixes legacy L3 (silent, unaudited hard delete).

---

## 13. Idempotency / concurrency

| Aspect | Decision | Status |
|---|---|---|
| Key | `client_request_id` **required** on create (Phase 12 sales/returns precedent; purchases treated it as optional — the stricter sales/returns rule is chosen because expenses are money-out events) | RESOLVED |
| Storage | nullable column + **partial unique index** (NULL-safe for any pre-existing rows) | RESOLVED |
| Replay | same key + same signature → 201 + `idempotent_replay: true` | RESOLVED |
| Conflict | same key + different signature → 409 `IDEMPOTENCY_CONFLICT` (signature = canonical hash of title/category/amount/paid_from_drawer) | RESOLVED |
| Locking | **none required** — insert-only aggregate, no stock/counter to decrement; cancel guarded by `UPDATE ... WHERE status='posted'` rowcount check inside `transaction()` (0 rows → 409) | RESOLVED |
| Flutter | one `client_request_id` generated **per dialog open**, sent with the body (matches `purchase_form_dialog`/`return_create_dialog`) | RESOLVED |
| Cancel idempotency | not required (second cancel is a clean 409, not a data-corruption risk) | RESOLVED |

---

## 14. Flutter workflow

**New feature folder `lib/features/expenses/`**

| File | Responsibility |
|---|---|
| `expenses_screen.dart` | nav-rail destination `/expenses`; header with 4 summary metrics; filter row; paginated `DataTable`; row action (cancel, gated) |
| `expenses_providers.dart` | `ExpenseFilters` (q, category, paidFromDrawer, dateFrom, dateTo, status) + `StateNotifier<ExpenseState>` (mirrors `purchases_providers.dart`) |
| `expense_models.dart` | `ExpenseSummary`, `Expense` (mirrors `return_models.dart`) |
| `expense_form_dialog.dart` | create dialog: title (**optional** since Fix Round 2), category dropdown, amount, drawer toggle, note; validates B1–B5 client-side (title length checked only when supplied); 422/409/toast error mapping |
| `expense_cancel_dialog.dart` | reason-required confirm (mirrors `return_void_dialog.dart`) |
| `expenses_error.dart` | 404/409/422 → localized strings (mirrors `return_error_message.dart`) |

**Modified:** `lib/router/app_router.dart` (route + nav-rail entry + scope constant
`PermissionScope.expenseView` + index mapping), `lib/core/strings.dart` (§15).

**UX flow**
1. Enter `/expenses` (visible only with `expense_view`; otherwise 403 screen / hidden entry).
2. Screen loads `GET /expenses?status=posted&page=1&size=25` + `GET /expenses/summary` in
   parallel; shows metrics: Total expenses / Paid from drawer / Paid externally / Count
   (legacy parity W2, `main_window.py:13456-13462`).
3. Filters: search field (title/note), category dropdown (all + 7 codes), payment dropdown
   (all / drawer / external), **date range** (two `showDatePicker` fields + clear), status
   toggle (Active / Cancelled). Defaults: no filters, `status=posted`.
4. **+ New expense** (requires `expense_create`) → dialog → `POST` with per-open
   `client_request_id` → toast `expense_saved` → invalidate list + summary providers.
5. **Cancel** (requires `expense_cancel`) → reason dialog → `POST /{id}/cancel` → row moves
   to cancelled → toast `expense_cancelled`.
6. Pagination: prev/next (mirrors purchases; `AppConstants.defaultPageSize`).

**Not built in Flutter Phase 13:** charts, print/export buttons, category management screens,
per-device filtering, dashboard widgets. **DEFERRED** to Phase 14 (GATE 16/24).

| Decision | Status |
|---|---|
| Date-range filter in the expense **list** (API `date_from`/`date_to` + two pickers) | RESOLVED (GATE 27) — Phase 14's date-range selector governs reports/charts/exports, a different surface; legacy list had **no** date filter at all (D9) |
| Sorting UI (click-to-sort columns) | **DEFERRED** — server fixes ordering (GATE 12) |
| Inline "cancel reason" display on cancelled rows | RESOLVED — show date + reason tooltip/badge |
| Offline create queueing | **DEFERRED** (app-wide decision; sales/returns/voids/debts all online-only today) — GATE 25 |

---

## 15. Localization

- All new UI strings live in `lib/core/strings.dart` under the `ar` (L45-), `fr` (L677-), and
  `en` (L1292-) blocks. **No hardcoded strings** (Phase 0 convention).
- Reused existing generic keys (no duplicates created): `search`, `save`, `cancel`, `confirm`,
  `total`, `category`, `amount`, `date`, `from`, `to`, `reason`, `reason_required`, `note`,
  `clear`, `all`, `refresh`, `close`, `loading`, `retry`, `error`, `currency` (`'DA'`),
  and the existing key **`expenses`** (`strings.dart:105` ar / `:713` fr / `:1328` en) for the
  nav label.
- New keys (40 keys × 3 locales = 120 entries), all added once per locale block:

  Group | Keys
  ---|---
  Screen | `expenses_subtitle`, `expense_count`, `expense_total`, `expense_total_drawer`, `expense_total_external`, `expense_empty`
  Create | `expense_add`, `expense_title_label`, `expense_title_hint`, `expense_title_required`, `expense_category_label`, `expense_amount_label`, `expense_amount_hint`, `expense_amount_invalid`, `expense_paid_from_drawer`, `expense_paid_external`, `expense_note_label`, `expense_submit`, `expense_saved`, `expense_save_failed`, `expense_replay`
  Filters | `expense_search_hint`, `expense_filter_payment`, `expense_filter_all_categories`, `expense_date_range`
  Status | `expense_status_posted`, `expense_status_cancelled`
  Cancel | `expense_cancel_action`, `expense_cancel_title`, `expense_cancel_confirm`, `expense_cancelled_success`, `expense_already_cancelled`
  Errors | `error_expense_not_found`
  Categories | `category_rent`, `category_utilities`, `category_salary`, `category_maintenance`, `category_supplies`, `category_transport`, `category_other`
- Enum → label mapping: `ExpenseCategory.code` → `strings['category_<code>']` via a local
  `expenseCategoryLabel(Category, String Function(String, Locale))` helper (mirrors
  `permission_helpers.dart`); codes stored in DB stay canonical English (fixes legacy L6).

**RESOLVED** (GATE 21).

---

## 16. Reporting boundary

| Concern | Phase 13 | Phase 14 |
|---|---|---|
| Store queryable source data (`category`, `paid_from_drawer`, `expense_date`, `status`) | ✅ | — |
| `GET /expenses/summary` aggregates (count/total/drawer/external) | ✅ | — |
| Reports page (date-range selector, period comparison, `net_profit − expenses`) | ❌ | ✅ |
| Cash drawer reconciliation strip | ❌ | ✅ |
| CSV / XLSX / PDF export of expenses | ❌ | ✅ |
| Dashboard widget / KPI tiles | ❌ | ✅ |
| Cross-feature profit math (sales − COGS − expenses) | ❌ | ✅ |

- Phase 13 must **not** add anything to `reports_screen.dart` (currently a placeholder) or to
  `dashboard_screen.dart`. **RESOLVED** (GATE 16/24).
- What Step B must guarantee for Phase 14: `expense_date` range-indexed, `status` filterable,
  `SUM(amount)` correctness, and rows never deleted — these are all §5/§6 requirements.

---

## 17. Migration strategy

- **Next head after `f5a6b7c8d9e0` (0017) → single new revision `0018`**
  (file name pattern: `YYYY_MM_DD_HHMM_<hash>_0018_phase13_expenses.py`).
- **Addendum — approved Fix Round 2:** one further reversible revision `0019`
  `2f6b9c4d8a31` (`..._0019_expense_title_optional.py`, `down_revision=1a2b3c4d5e6f`) makes
  `expenses.title` nullable. Final head = `2f6b9c4d8a31`; still exactly one head, no drift.
- `upgrade()`: add 6 columns (§5), create 3 indexes (`expense_date`, `user_id`, partial unique
  `client_request_id`), `op.create_foreign_key` for `cancelled_by` → `users.id`.
- `downgrade()`: drop indexes → drop FK → drop columns (Phase 12 precedent for reversible
  additive migrations). Safe with **0 rows**; on populated DBs `status`/`paid_from_drawer`
  drops lose cancel/payment data written by the new version only — accepted, documented.
- **No data migration / no backfill** (dev DB: 0 rows; legacy DB is not migrated — D-table §5).
- No table renames, no `NOT NULL` added to pre-existing columns except via `server_default`
  on `status`/`paid_from_drawer` (additive-safe pattern used in 0002/0003).
- Verification commands (Step B): `alembic upgrade head`, `alembic current`, `alembic heads`
  (must be exactly one head), `alembic check` (no drift), `pytest tests/unit/test_migrations.py -q`.

**RESOLVED** (GATE 22).

---

## 18. Test strategy

**Backend (new/updated)**
| Test | Covers |
|---|---|
| `tests/unit/test_expenses.py` (new) | list pagination + every filter (q/category/paid_from_drawer/date range/status), summary aggregates (0-row + mixed + cancelled-excluded), create happy path + `expense_date`/`user_id`/`status=posted` server assignment, validation 422s (unknown category, `amount=0`, negative amount, >MONEY_MAX, note >2000, missing `client_request_id`, title >200 when supplied) + Fix Round 2 `TestExpenseTitleOptional` (omitted/`null`/blank title -> `NULL`, trimming, list+summary, `q` with a NULL title, idempotency signature, cancel, audit `untitled`), idempotent replay (same key+payload → 201 + `idempotent_replay=true`, row count unchanged) + 409 conflict (same key, different payload), cancel happy path + reason stored + audit rows (`CREATE`/`VOID`, `entity_type='expense'`), cancel 404, cancel 409 double-cancel, 403s for each missing scope, `status=all` listing |
| `tests/unit/test_migrations.py` | new Phase 13 class: 0018 up/down, single head, columns/indexes exist |
| `tests/unit/test_auth.py:661,681` | permission count 27 → 30 + the 3 new scopes present |
| `tests/unit/test_enums.py:45` | scope enum count 27 → 30 (ExpenseCategory tests untouched — no enum values added) |
| `tests/unit/test_models.py:314` | `test_create_expense` extended for `status`/`paid_from_drawer`/`client_request_id` (`EXPECTED_TABLES` already correct at `:81`) |
| seed test | `ROLE_PERMISSIONS` contains all 3 scopes for admin; manager/cashier per GATE 8 answer |

**Flutter (new)**
| Test | Covers |
|---|---|
| `test/unit/expenses_localization_test.dart` (new) | every `expense_*`/`category_*`/`error_expense_not_found` key exists in **all three** locales and is non-empty; no duplicate keys |
| `test/widget/expenses_screen_test.dart` (new) | renders summary metrics + rows; empty state; nav entry hidden without `expense_view`; cancel button hidden without `expense_cancel`; filters update query |
| `test/widget/expense_form_dialog_test.dart` (new) | client validation (B1–B5; title optional — only a bad amount blocks the POST, blank title omitted from the payload), drawer defaults to ON, `client_request_id` sent, 409 conflict → `error_idempotency_conflict`, replay toast |

**Commands (all reported; final results):**
`python -m pytest -q` → **874 passed**, targeted
`python -m pytest tests/unit/test_expenses.py tests/unit/test_debt_aggregate_balance.py tests/integration/test_migrations.py -q` → **131 passed**,
`python -m ruff check app` → **64** baseline, 0 new findings, `alembic upgrade head` / `alembic current` /
`alembic heads` (single `0019` head `2f6b9c4d8a31`) / `alembic check` → no drift,
`flutter analyze` → no issues, `flutter test` → **1049 passed**, `flutter build windows --debug` → OK.

**RESOLVED** (GATE 26).

---

## 19. Explicit Gates (decision summary)

| # | Gate | Status | Resolution |
|---|---|---|---|
| 1 | Lifecycle | **RESOLVED** | create → `posted`; corrections via `POST /{id}/cancel` |
| 2 | No edit / no hard delete | **RESOLVED** | cancels + re-create; no PUT/DELETE endpoints (blueprint deviation, D10) |
| 3 | Categories | **RESOLVED** | fixed `ExpenseCategory` enum, canonical codes in existing column, labels localized (roadmap "Category management" narrowed, §1) |
| 4 | Money | **RESOLVED** | Decimal NUMERIC(18,3), `0 < amount <= MONEY_MAX`, no tax/discount fields, no extra rounding |
| 5 | Payment flag | **RESOLVED** | `paid_from_drawer BOOLEAN NOT NULL DEFAULT true`, informational only |
| 6 | Cash/drawer ledger integration | **DEFERRED** | no ledger exists; reconciliation + `net_profit` math → Phase 14 |
| 7 | Permissions (admin/manager view+create+cancel; create/cancel separation) | **RESOLVED** | 3 scopes: `expense_view`, `expense_create`, `expense_cancel` |
| 8 | **Cashier access to expenses** | **RESOLVED** | cashier receives `expense_view` + `expense_create` + `expense_cancel` (product-owner decision) |
| 9 | Manager `expense_cancel` | **RESOLVED** | manager receives `expense_view` + `expense_create` + `expense_cancel` |
| 10 | Idempotency | **RESOLVED** | required `client_request_id` + partial unique index + 409 on signature mismatch |
| 11 | Concurrency | **RESOLVED** | insert-only; cancel via rowcount-guarded `UPDATE` in transaction; no `FOR UPDATE` |
| 12 | API surface / ordering | **RESOLVED** | 4 endpoints (§6); fixed `expense_date DESC, id DESC` |
| 13 | No detail/PUT/DELETE endpoints | **RESOLVED** | see §6.5 |
| 14 | `expense_date` server-assigned | **RESOLVED** | no client backdating (legacy parity) |
| 15 | Status + cancellation attribution | **RESOLVED** | `status`, `cancelled_at/by`, `cancel_reason` |
| 16 | Reporting content in Phase 13 | **DEFERRED** | source data + `/summary` only (§16) |
| 17 | Expense number/reference | **RESOLVED** | UUID only, no human-readable number |
| 18 | Supplier/customer link | **RESOLVED** | not an expense attribute; never added |
| 19 | Attachments / recurring / approval | **DEFERRED** | no evidence they are needed; Phase 0 matrix lists "approval" as future |
| 20 | Device attribution | **RESOLVED** | `X-Device-ID` header (Phase 12 returns/void convention), not the purchases body `device_id` |
| 21 | Localization | **RESOLVED** | 40 new keys × 3 locales, generic keys reused (§15) |
| 22 | Migration | **RESOLVED** | single reversible additive `0018`, 0 rows → no backfill (plus the approved Fix Round 2 revision `0019` `2f6b9c4d8a31`, nullable `title`) |
| 23 | CHECK constraints | **RESOLVED** | none added (no precedent in the codebase; Pydantic validates) |
| 24 | Export/printing | **DEFERRED** | Phase 14 |
| 25 | Offline queueing | **DEFERRED** | app-wide online-only convention |
| 26 | Test strategy | **RESOLVED** | §18; 3 hard-coded permission-count assertions must be updated |
| 27 | Date filtering (list) | **RESOLVED** | API `date_from`/`date_to` + two date pickers in list (Phase 14 selector = reports surface) |
| 28 | Seed re-run | **RESOLVED** | manual `python -m app.core.seed` after migration (D15) — **executed 2026-09-29 after 0018** (`permissions=3`, `role_permissions=9`); no startup auto-seed |

**Totals: 23 RESOLVED · 5 DEFERRED · 0 UNVERIFIED.**

---

## 20. Open questions / deferred items

**Blocking questions: NONE — GATE 8 and GATE 9 are RESOLVED.**

**Final role matrix (approved by product owner, all roles receive all three scopes):**

| Role | `expense_view` | `expense_create` | `expense_cancel` |
|---|---|---|---|
| admin | ✅ | ✅ | ✅ |
| manager | ✅ | ✅ | ✅ |
| cashier | ✅ | ✅ | ✅ |

**Non-blocking confirmations — all confirmed during Human QA (PASS 14/14):**
1. Keep legacy's **hard delete** instead of cancel? **No** — audited cancel is what shipped (audit
   trail required by the feature matrix: "no immutable audit" is listed as a *problem to fix*).
2. 3 scopes vs. collapsing create+cancel into `expense_manage`: **3 scopes**.
3. `status` default filter = `posted` in list responses (cancelled rows hidden unless asked):
   **as chosen**.

**Deferred (explicitly not Phase 13):** GATE 6 drawer ledger, GATE 16 reports content,
GATE 19 attachments/recurring/approval, GATE 24 exports/printing, GATE 25 offline queueing,
click-to-sort columns, dashboard widget, cross-device list filter (D5 deviation).

---

## 21. Final implementation plan (Step B — completed and verified)

Ordered; each step ends with its own verification.

1. **Migration 0018** — columns + indexes (§5). Verify: `alembic upgrade head`, `alembic current`,
   `alembic heads` (single head), `alembic check`, `pytest tests/unit/test_migrations.py`.
2. **Enums/seed** — `ExpenseStatus`, 3 × `PermissionScope`, `ROLE_PERMISSIONS`, update
   `test_auth.py:661/681` + `test_enums.py:45` + seed test (per GATE 8 answer).
   Verify: `pytest tests/unit/test_enums.py tests/unit/test_auth.py`.
3. **Model** — `status`, `paid_from_drawer`, `client_request_id`, `cancelled_at/by`,
   `cancel_reason`, indexes on `expense_date`/`user_id`.
   Verify: `pytest tests/unit/test_models.py`.
4. **Schemas** — `app/schemas/expense.py`: `ExpenseCreateRequest`, `ExpenseCancelRequest`,
   `ExpenseResponse`, `ExpenseSummaryResponse` (+ `PaginatedResponse` reuse).
5. **Repository** — `app/repositories/expense.py`: filtered/count query, summary aggregate,
   insert, status-guarded cancel update.
6. **Service** — `app/services/expenses.py`: `create()` (idempotency + audit `CREATE`),
   `cancel()` (reason + audit `VOID`), `list()`, `summary()` inside `BaseService.transaction()`.
7. **Router** — `app/api/v1/expenses.py` + include in `api/v1/router.py` (order: `/summary`
   before any param route).
8. **Backend tests** — `tests/unit/test_expenses.py` (§18 matrix).
   Verify: `python -m pytest -q`, `python -m ruff check app` (must stay **64**).
9. **Localization** — 40 keys × 3 locales in `lib/core/strings.dart`.
   Verify: `flutter analyze`.
10. **Models/providers** — `expense_models.dart`, `expenses_providers.dart`, `expenses_error.dart`.
11. **Screens/dialogs** — `expenses_screen.dart`, `expense_form_dialog.dart`,
    `expense_cancel_dialog.dart`; route + nav entry in `app_router.dart`.
12. **Flutter tests** — 3 files from §18.
     Verify: `flutter analyze`, `flutter test` (≥ 1010 + new — verified **1049**), `flutter build windows --debug`.
13. **Docs + Human QA** — `docs/PHASE_13_IMPLEMENTATION.md`, update the header/status of this
    file, run the QA script (list/create/replay-conflict/cancel/permission-denied/filter/summary/
    three-locale checks), then commit **only if explicitly requested**.
    **Done:** documentation updated to CLOSED / APPROVED, Human QA **PASS 14/14**, and the single
    commit `phase-13: complete expenses` was created on explicit request (not pushed).

**Explicitly forbidden in Step B:** touching `reports_screen.dart`, `dashboard_screen.dart`,
exports, category CRUD, `AuditAction`/`PermissionScope` values beyond the three new scopes,
`ExpenseCategory` values, a second migration revision, `device_id` body-parameter convention,
client-side backdating.
*(Exception later approved by the product owner: Fix Round 2 introduced migration **0019**
`2f6b9c4d8a31` for the optional-title rule — see `docs/PHASE_13_IMPLEMENTATION.md` §8.1. Nothing
else from that list was touched.)*
