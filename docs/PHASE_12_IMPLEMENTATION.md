# Phase 12 — Returns / Voids Implementation Record

> **Status: CLOSED / APPROVED**
>
> - **IMPLEMENTED** — Step B (backend) and Step C (Flutter); migrations `0016`
>   (`e4f5a6b7c8d9`) and `0017` (`f5a6b7c8d9e0`) are applied to the dev DB.
> - **FIX ROUND 1 VERIFIED** — product-owner UX changes (multi-product
>   "Return Products" workflow, invoice quantity defaulting to the remaining
>   returnable quantity, return reason optional) — see §7. The result-dialog
>   routing fix of §7.8 was **manually verified** in the Windows build: the
>   dialog closes and `/returns` routing is unaffected.
> - **TECHNICAL VERIFICATION: PASS** — backend 790 green, targeted Phase 12
>   green, `ruff check app` no-new-errors, `flutter analyze` clean, Flutter
>   1010 green, Windows debug build ok, single Alembic head `f5a6b7c8d9e0`,
>   `alembic check` clean.
> - **HUMAN QA: PASS** — the 14-point plan in
>   `PHASE_12_RETURNS_VOIDS_ANALYSIS.md` §25 plus the fix-round-1 smoke
>   script (§7.6) were executed by the product owner: **all 14 QA areas
>   passed**. No remaining blocking issues.
> - **GIT: COMMITTED** — one commit, message
>   `phase-12: complete returns and voids`.
>
> Authority: `docs/PHASE_12_RETURNS_VOIDS_ANALYSIS.md` (26 sections, 22 gates).
> This file records *what was built* and *how it was verified*; it does not
> re-decide anything.

---

## 0. Schema mismatch blocker / resolution (2026-09-28)

**Observed:** `POST /api/v1/sales` →
`psycopg2.errors.UndefinedColumn: column sales.voided_at does not exist`,
raised from `SaleService.create_sale()` → `sales.find_by_client_request_id()`
(`SELECT ... sales.voided_at, sales.voided_by, sales.void_reason ...`).

**Root cause.** Migration `0016_phase12_returns_voids` had never been applied
to the *application* database. The Phase 12 ORM models already declared the
new columns, so the idempotency SELECT projected columns that did not exist.
The Phase 12 migration verification (upgrade → downgrade → re-upgrade and
`TestPhase12ReturnsVoidsMigration`) had run against the **test** database
`supermarket_pro_test`, which was already at head; the **dev** database
`supermarket_pro` was left at 0015. Nothing was stamped, drifted or lost —
Alembic history, `alembic_version` and the physical schema agreed with each
other, they were simply one revision behind.

**Not the cause (checked):** application and Alembic use the *same*
`settings.DATABASE_URL` (`migrations/env.py` sets `sqlalchemy.url` from
`app.core.config.settings`; `.env` → `postgresql://postgres@localhost:5432/supermarket_pro`);
no second `DATABASE_URL` in the process environment; no `env.py`/config file
divergence; no bad `alembic stamp`.

**State before the fix**

| Item | Value |
|---|---|
| Database | `supermarket_pro` (host `localhost`, port `5432`, user `postgres`, PG 18.6) |
| `alembic_version` | `d3e4f5a6b7c8` (0015) |
| Alembic head | `e4f5a6b7c8d9` (0016) |
| `sales.voided_at/voided_by/void_reason` | **absent** (18 columns on `sales`) |
| `returns.client_request_id/subtotal/discount` | **absent** (13 columns on `returns`) |
| `return_lines` | 14 columns (missing all 7 Phase 12 columns) |
| Test DB `supermarket_pro_test` | already `e4f5a6b7c8d9` — healthy |

**Action taken.** The normal chain only — `alembic upgrade head`
(`d3e4f5a6b7c8 → e4f5a6b7c8d9, 0016_phase12_returns_voids`). No manual DDL,
no `alembic stamp`, no schema/data reset, no business-logic change. The
running uvicorn (`--reload`) was left up; the fix is database-side.

**State after the fix**

- `alembic current` → `e4f5a6b7c8d9 (head)`.
- `sales` = 21 columns incl. `voided_at`, `voided_by`, `void_reason`.
- `returns` = 16 columns incl. `client_request_id`, `subtotal`, `discount`;
  `return_lines` = 21 columns; `ix_returns_client_request_id` present and
  unique; `ix_returns_return_date`, `ix_return_lines_pack_id` present.
- `alembic downgrade d3e4f5a6b7c8` + re-upgrade and the autogenerate
  no-drift check remain green on the test database.

**Verification**

| Command | Result |
|---|---|
| `POST /api/v1/sales` smoke (in-process route → service → real dev DB) | **14/14 PASS** — 201 created, void fields present and `null`, replay of the same `client_request_id` → `idempotent_replay=true` + same id + exactly 1 row, `GET /api/v1/sales/{id}` 200, raw `SELECT` with the three void columns OK |
| Phase 11/12 regression on the same app | `GET /purchases`, `/suppliers`, `/products`, `/returns` all 200 |
| Live server | `uvicorn` on `127.0.0.1:8000` serving (`/api/v1/auth/login-users` → 200), same DB, no restart required |
| `pytest -q` | **778 passed** |
| targeted Phase 12 (`test_returns`, `test_void`, `test_return_concurrency`, `test_migrations`) | **91 passed** |
| `ruff check app` | 64 (baseline 66 — no new errors) |
| `flutter analyze` | No issues found |

Auth for the HTTP smoke was dependency-overridden (no PIN available to the
CLI); routing, schemas, `SaleService`, repositories and the PostgreSQL schema
are the real production path. Re-running the manual Flutter smoke with a real
login is part of Human QA.

**Human QA status: PASS** (§25, 14 points — executed by the product owner,
all 14 areas green).

---

## 1. Files

### Backend — new

| File | Purpose |
|---|---|
| `migrations/versions/2026_09_28_1000_e4f5a6b7c8d9_0016_phase12_returns_voids.py` | adds `sales.voided_at/voided_by/void_reason`; `returns.client_request_id/subtotal/discount`; `return_lines.pack_id/variant_name/selling_unit_name/selling_unit_multiplier/quantity_base/unit_cost/line_discount`; `return_lines.product_id` nullable; unique `ix_returns_client_request_id`; `ix_returns_return_date`; `ix_return_lines_pack_id` |
| `migrations/versions/2026_09_28_1200_f5a6b7c8d9e0_0017_return_reason_optional.py` | **fix round 1** — `returns.reason` → nullable, `server_default` dropped (NULL = no reason); `downgrade` refuses to re-impose `NOT NULL` while any row is NULL. Void reason untouched |
| `app/services/returns.py` | `ReturnService.post/list/get` + shared Phase 12 primitives |
| `app/services/void.py` | `VoidService.void` |
| `app/repositories/returns.py` | `ReturnRepository` (`find_by_client_request_id`, list filters) |
| `app/schemas/returns.py` | request/response models + `ReturnCreateResponse`; `reason` optional (fix round 1), `VoidRequest.reason` mandatory |
| `app/api/v1/returns.py` | `POST/GET /api/v1/returns`, `GET /api/v1/returns/{id}` |
| `tests/unit/test_returns.py` | 34 tests (GATE 3/4/5/8/10/11/12/13/14/16 + fix round 1 reason/multi-line cases) |
| `tests/unit/test_void.py` | 14 tests (GATE 1/7/8/9/10/12/16, incl. void reason mandatory) |
| `tests/integration/test_return_concurrency.py` | 3 tests (GATE 16/17, Postgres) |

### Backend — modified

`app/models/sale.py` (+3 void columns, `voided_by_user` relationship),
`app/models/return_doc.py` (+7 columns, nullable `product_id`),
`app/repositories/sale.py` (`get_for_update`),
`app/repositories/debt.py` (capped-reversal algebra, §17),
`app/schemas/sale.py` (void payload),
`app/services/sale.py` (`_to_sale_response` void fields, `create_sale(request, *, user, device_id) -> SaleCreateResponse`),
`app/api/v1/pos.py` (void route), `app/api/v1/router.py` (+returns router),
`tests/integration/test_migrations.py` (+`TestPhase12ReturnsVoidsMigration`, 11 tests; `HEAD_REV` → `e4f5a6b7c8d9`, **fix round 1** → `f5a6b7c8d9e0`).

### Flutter — new (`lib/features/returns/`)

`return_models.dart`, `return_error_message.dart`, `return_providers.dart`,
`return_void_dialog.dart`, `return_create_dialog.dart` (linked/invoice
return), `return_products_dialog.dart` (**fix round 1** — independent
multi-product return), `return_detail_dialog.dart`, `returns_screen.dart`
(list + **Return Products** entry point).

### Flutter — modified

`lib/core/strings.dart` (+68 keys × ar/fr/en = 204 entries, of which 14 are
the fix-round-1 "Return Products" / remaining-qty / optional-reason block),
`lib/router/app_router.dart`
(route `/returns`, RBAC `pos_return`, nav entry + index),
`lib/features/pos/pos_models.dart` (`SaleDetailLine.packId`,
`SaleDetail.voidedAt/voidedBy/voidReason/isVoided`),
`lib/features/pos/sale_detail_dialog.dart` (`_void()`, `_returnItems()`,
`canVoid`/`canReturn`, keys `sale-void` / `sale-return`, VOID banner),
`test/unit/pos_localization_test.dart` (Phase 12 POS key group).

### Flutter tests — new

`test/unit/returns_localization_test.dart` (68 keys × 3 locales + reason
labels + ar/fr ≠ en, incl. the 14-key fix-round-1 block),
`test/unit/return_error_message_test.dart` (error-code → localized headline
matrix, network/non-Dio/403/404/409-unknown/500),
`test/widget/returns_screen_test.dart` (list, detail dialog, **Return
Products** entry point, reason filter → API, RBAC denial),
`test/widget/return_create_dialog_test.dart` (8 — linked return: quantity
defaults to remaining, partial prior returns, fully-returned line disabled at
0, optional reason, ar/fr/en + RTL),
`test/widget/return_products_dialog_test.dart` (10 — independent multi-product
return: search adds, repeat merges, multiple products, steppers, submit with
no reason → one POST with N lines, variant barcode, unknown barcode →
localized not-found, ar/fr/en + RTL).

---

## 2. Gate → implementation map

| Gate | Where it lives | Primary test |
|---|---|---|
| 1 void terminal | `services/void.py` (`status='void'`, no unvoid path) | `test_void.py::test_cannot_void_twice…` |
| 2 no draft/cancel return | `schemas/returns.py` (no status field written) | `test_returns.py` |
| 3 linked vs independent | `services/returns.py::_post` | `test_returns.py` linked/independent |
| 4 cumulative cap | `_line_signature` + `sum(return_lines.qty)` under sale lock | `test_returns.py::test_return_exceeds_remaining…` |
| 5 refund from persisted economics | `sale_line` read at return time, not catalog price | `test_returns.py` discount conservation |
| 6 PMP unchanged | `apply_restore` never touches `avg_cost` | `test_returns.py` |
| 7 movement types | `RETURN` / `SALE_VOID` via `entry_type` param | `test_void.py`, `test_returns.py` |
| 8 capped debt reversal | `repositories/debt.py` algebra + shortfall note | `test_void.py`/`test_returns.py` |
| 9 void fields, no zeroing | `void.py` sets columns, totals untouched | `test_void.py::test_void_keeps_money_columns…` |
| 10 mutual exclusion | both services check the other | `test_void.py`, `test_returns.py` |
| 11 pack whole-only | `RETURN_PACK_NOT_WHOLE`, components from that sale's lines | `test_returns.py` |
| 12 variant-only restore | `apply_restore` variant branch | `test_void.py`/`test_returns.py` |
| 13 selling-unit snapshots | `selling_unit_multiplier` → `quantity_base` | `test_returns.py` |
| 14 pro-rata refund + invoice discount | `ReturnService._line_refund` | `test_returns.py` discount tests |
| 15 permissions | `pos_return` (cashier+manager), `pos_void` (manager), no enum change | existing permission tests + widget RBAC |
| 16 idempotency | `client_request_id` unique index + under-lock re-check | `test_return_concurrency.py` |
| 17 locking | §19 order: sale → customer → products/variants | `test_return_concurrency.py` |
| 18 no enum expansion | fixed movement types, free-text reasons | `test_models.py` (23 tables, 27 scopes) |
| 19 reporting data-only | no report UI touched | — |
| 20 deferred | UI shows `cash_pending` only; no drawer/payment split/tax | — |
| 21 localization | 68 keys × 3 locales, RTL | `returns_localization_test.dart` |
| 22 Flutter workflow | `/returns` + sale-detail actions | `returns_screen_test.dart` |

---

## 3. Implementation decisions (deviations and rationale)

1. **Shared primitives in `services/returns.py`** — `lock_restore_targets`,
   `apply_restore`, `sale_credit_and_reversed`, `credit_reversed_for_key`,
   `reverse_customer_debt`, `void_restores` are imported by `services/void.py`
   so restore and reversal logic exists once (no drift between void and return).
2. **`reverse_customer_debt(..., entry_type=...)`** — parameterized
   (`sale_void` vs `sale_refund`) instead of a second implementation.
3. **Void passes `refund_total=refund_due`** — one valuation path for both
   documents (GATE 5).
4. **`_line_signature` = `(sale_line_id, quantity)`** — cap counting keys on
   the source line only; `(product_id, ...)` would conflate two lines of the
   same product.
5. **Under-lock second idempotency check** (`ReturnService._replay_if_committed`)
   — the fast-path check runs before the sale lock; a concurrent duplicate can
   commit in between, and without the second check the retry would fail with
   `RETURN_EXCEEDS_SOLD` carrying its own committed quantity. The Postgres test
   proves a single document is created.
6. **No client-side refund estimate** — the refund / credit-reversed /
   cash-pending split is rendered from the authoritative 201 response. The
   server owns all money (GATE 5); a client-side preview would be a second
   valuation implementation.
7. **Error mapping is envelope-driven** — `resp.json()["error"]["code"]`; an
   unknown 409 code must never surface as "stock conflict", an unknown 404
   maps to `return_not_found`, unknown 403 to `permission_denied`, 5xx to
   `api_error_retry` with backend detail.
8. **Entry points** — the Returns rail (`/returns`, gated by `pos_return`),
   the sale detail dialog (`sale-return` / `sale-void`) and — since **fix
   round 1** — a clearly visible **"Return Products"** action on the Returns
   screen that opens the independent multi-product return dialog. There is
   still no POS-*header* button: the Returns screen is the canonical entry
   point, but the product-owner requirement ("the Returns feature must
   provide an obvious product-return entry point without an invoice") is met
   by `returns-return-products`.
9. **Independent return product picker (fix round 1)** — one dialog, N lines:
   scan/search through the existing `GET /api/v1/products/barcode-lookup` and
   `GET /api/v1/products?search=&page_size=` endpoints (no second product
   repository, no Flutter-side SQL); repeated scans of the same
   product/variant **merge and increment** instead of duplicating the line;
   one `POST /api/v1/returns` per submission produces **one return document
   with N `return_lines`** (`sale_id`/`customer_id` NULL). Backend stays
   authoritative: unknown product → 404, `quantity > 0`, no sale-line ceiling
   on an independent return, variant line restores variant stock only.
10. **Return reason optional (fix round 1)** — `ReturnCreateRequest.reason`
    accepts `null`, `""` and an omitted field; all three normalize to `NULL`
    (no fake default reason, no invented vocabulary entry). A *supplied*
    reason must still be one of `defective / wrong_item / customer_change /
    expired / other` (422 otherwise). `VoidRequest.reason` is unchanged and
    stays mandatory (§8 GATE 15).
11. **Invoice return quantity defaults to the remaining returnable quantity
    (fix round 1)** — the linked dialog loads `GET /returns?sale_id=…`,
    derives `already_returned` per source line and seeds each editable field
    with `sold − already_returned` (0 and disabled when fully returned). The
    default is convenience only: the server still enforces
    `RETURN_EXCEEDS_SOLD` / cumulative source-line caps inside the
    transaction.

---

## 4. Verification (technical)

| Check | Result |
|---|---|
| `pytest -q` | **790 passed** (after the idempotency fix of §7.7; 786 before it, 778 before fix round 1) |
| new unit tests | +49 (`test_returns` 35, `test_void` 14) |
| new integration tests | +17 (migration 14 — incl. 3 new 0017 tests —, concurrency 3) |
| targeted Phase 12 (`test_returns`, `test_void`, `test_return_concurrency`, `test_migrations`) | **103 passed** (before fix round 1: 96) |
| targeted Phase 12 as run for closeout (`test_returns`, `test_void`, `test_return_concurrency`) | **52 passed** |
| `alembic current` / `alembic heads` | **one head**: `f5a6b7c8d9e0` (0017) = DB current revision |
| `alembic check` | `No new upgrade operations detected.` (no migration drift) |
| `alembic upgrade head` / `downgrade d3e4f5a6b7c8` / re-upgrade | pass (test DB; dev DB at `f5a6b7c8d9e0` after fix round 1 — see §7.5) |
| `alembic revision --autogenerate` | no model drift |
| `ruff check app` | **64** (baseline 66 — no new errors; every remaining finding exists at `HEAD`) |
| `ruff` on new/changed Phase 12 backend files | **0 new** |
| `flutter analyze` | **No issues found** |
| `flutter test` | **1010 passed** (1008 before the result-dialog fix of §7.8; 986 before fix round 1, baseline 907) |
| `PermissionScope` count | 27 (unchanged) |
| `EXPECTED_TABLES` | 23 (unchanged) |

Postgres used for migration and concurrency tests:
`supermarket_pro_test` (teardown removes `audit_logs`, `sales`, `returns`,
`return_lines`, `debt_ledger_entries`, devices).

---

## 5. Human QA — PASS (§25, 14 points + fix-round-1 smoke script)

Run on Windows with seeded `admin` / `manager` / `cashier`:

1. void happy path (2 product + 1 variant + 1 pack line) ·
2. cashier sees no void, direct API → 403 ·
3. void guards: double void 409 `SALE_ALREADY_VOID`, void-with-return 409,
   empty reason 422 ·
4. linked return pro-rata / full-return-equals-total, PMP unchanged ·
5. ceilings `RETURN_EXCEEDS_SOLD` / `RETURN_LINE_INVALID` ·
6. pack return: components only, whole-pack rule, two pack lines of same pack ·
7. variant-only restore ·
8. debt reversal + shortfall note + `balance == ledger_sum_for_customer` ·
9. mutual exclusion both directions ·
10. idempotent double-submit + concurrent last-unit (Postgres) ·
11. independent return (with **and** without a reason), no ledger entry,
    404 unknown product ·
12. localization ar (RTL) / fr / en, movement journal + debt history
    translations ·
13. regression: backend 790 green, Flutter 1010 green, analyze clean,
    migration up/down, Windows build, Phase 11 flows untouched ·
14. product-owner sign-off: cashier `pos_return` grant, manager void without
    PIN step-up, deferred cash-refund scope.

**Fix-round-1 smoke script (A–O):**

- **A–H — Return Products (independent, multi-product):** open Returns →
  *Return Products* → scan/search product A → scan A again (quantity merges
  to 2) → search product B → submit **without** a reason → exactly **one**
  return document with **two** `return_lines` (`sale_id` NULL) → stock
  restored (variant line → variant only).
- **I–O — invoice return quantities:** open a multi-line sale → *Return* →
  every line defaults to its **remaining returnable** quantity (a previously
  partially returned line defaults to the remainder, a fully returned line
  starts at 0 and disabled) → reduce one quantity → submit with no reason →
  correct partial return + refund, caps still enforced server-side.

**Status 2026-09-29 — HUMAN QA: PASS.** The API-level portion of this
script was executed against a live backend (`127.0.0.1:8000`) with a real
`Admin`/PIN login — all checks green, see §7.6. The product owner then ran
the full 14-point plan above plus the UI click-through (steps A, B, I, J —
opening the dialogs, scanning into them, the rendered defaults and disabled
rows) on Windows: **all 14 QA areas passed**, including the result-dialog
close and `/returns` routing (§7.8).

**Human QA is complete — no remaining blocking issues.**

---

## 6. Not touched (forbidden / out of scope)

- No permission enum or scope changes (`POS_RETURN` / `POS_VOID` only).
- No Phase 7–11 sale, stock, purchase or supplier semantics modified beyond
  the void columns, void response fields and `device_id` plumbing required by
  GATE 9/16.
- No `except: pass`, no swallowed broad exceptions, no float money, no Flutter
  direct SQL, no current-catalog-price refund, no current-`pack_items` pack
  restore, no product+variant double restore, no zeroing of sale totals /
  paid / discount / change, no `paid_amount`-based void reversal, no missing
  row locks / transaction / audit / `source_document_id` / idempotency /
  localized errors.
- Deferred (§18 / §20): cash and card refund execution, cash drawer,
  payment-split reversal, tax, return cancellation documents, un-void, PIN
  step-up, report UI (Phase 14).

---

## 7. Fix round 1 — product-owner UX changes (2026-09-29)

Business rules were **not** redesigned: the backend remains authoritative for
caps, refunds, stock restoration, idempotency and locking. Only UX, reason
requiredness and the `returns.reason` column changed.

### 7.1 Return Products — multi-product scan/search workflow (CHANGE A)

- `returns_screen.dart` gained a visible **`Return Products`** action
  (key `returns-return-products`) → `return_products_dialog.dart`.
- One dialog, N lines, **one** `POST /api/v1/returns` per submission → one
  independent return document (`sale_id`/`customer_id` NULL, no debt entry,
  `movement_type=RETURN`, `audit action=RETURN`) containing N
  `return_lines`. Never one document per product.
- Products are added by **barcode scan** (`GET
  /api/v1/products/barcode-lookup`, with an exact-match
  `GET /api/v1/products?search=` fallback) or by **text search** + selecting
  a result — both endpoints already existed; no new product repository, no
  Flutter-side SQL.
- Re-scanning/re-selecting the same product **merges** into the existing line
  and increments its quantity (notice key `return_scan_merged`); lines can be
  removed and quantities edited; submit is blocked with no lines
  (`return_no_products`) or with any quantity ≤ 0 (`invalid_qty`).
- Unknown barcode/product → localized `return_product_not_found` (never a
  silent ignore).
- Variant barcodes resolve to `product_id + variant_id`; restoration keeps
  the Phase 8/12 **variant-only** rule (variant quantity moves, parent
  product untouched, never both).
- Backend unchanged for this flow: unknown product → 404, `quantity > 0`,
  no current-sale-line ceiling on an independent return, one document per
  `client_request_id`.

### 7.2 Invoice return quantity defaults to the remaining returnable (CHANGE B)

`return_create_dialog.dart` loads `GET /api/v1/returns?sale_id=…` first, then
per line shows **Sold / Already returned / Returnable** and seeds the editable
quantity with `max(sold − already_returned, 0)`:

| Line | Sold | Already returned | Default qty |
|---|---:|---:|---:|
| A (no prior returns) | 5 | 0 | **5** |
| A (partially returned) | 5 | 2 | **3** |
| B (fully returned) | 2 | 2 | **0**, control disabled + `return_fully_returned` |

Nothing is auto-submitted: the operator still presses Submit, can reduce any
quantity, and the server re-validates every cap inside the transaction
(`RETURN_EXCEEDS_SOLD`, cumulative source-line caps, pack whole-only rules).

### 7.3 Return reason optional, void reason mandatory (CHANGE C)

| | Before | After (fix round 1) |
|---|---|---|
| Linked return `reason` | required | **optional** — omitted / `null` / `""` → `NULL` |
| Independent return `reason` | required | **optional** — same normalization |
| Supplied return `reason` | vocabulary-checked | vocabulary-checked (unchanged: 422 on unknown) |
| Void `reason` | mandatory, non-blank | **mandatory, non-blank (unchanged, 422)** |
| UI | required marker | `Reason (optional)` label, blank allowed, no red marker |

No fake default reason is ever written; `returns.reason` may be `NULL`.

### 7.4 Fix-round-1 file list

Backend: `app/schemas/returns.py` (optional-reason validator),
`app/models/return_doc.py` (`reason` nullable + comment),
`app/services/returns.py` (idempotency quantity normalization — §7.7),
`migrations/versions/…_0017_return_reason_optional.py`,
`tests/unit/test_returns.py` (+reason/multi-line/idempotency cases),
`tests/integration/test_migrations.py` (+`TestPhase17ReturnReasonOptionalMigration`).

Flutter: `lib/features/returns/return_products_dialog.dart` (new),
`returns_screen.dart` (entry point), `return_create_dialog.dart` (remaining
defaults + sold/returned/returnable rows), `return_models.dart`
(`ReturnProductCandidate`, `ReturnBarcodeHit`), `return_providers.dart`
(`ReturnsApi.searchProducts/barcodeLookup`), `lib/core/strings.dart`
(+14 fix-round-1 keys × 3 locales).

Tests: `test/widget/return_products_dialog_test.dart` (10),
`test/widget/return_create_dialog_test.dart` (8), extended
`returns_screen_test.dart`, `returns_localization_test.dart`.

### 7.5 Schema applied to the dev database

`alembic upgrade head` on `supermarket_pro`: `e4f5a6b7c8d9 → f5a6b7c8d9e0`
(0017). `returns.reason` is now nullable with no server default; no rows were
rewritten (0 NULL rows existed at upgrade time). Void columns untouched.

### 7.6 Verification of fix round 1

| Check | Result |
|---|---|
| `pytest -q` | **790 passed** |
| targeted Phase 12 tests | **103 passed** |
| `ruff check app` | **64** (no new errors vs. baseline) |
| `flutter analyze` | No issues found |
| `flutter test` | **1010 passed** |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe` (Dart `kernel_blob.bin` rebuilt from current sources) |
| live smoke A–O (API level, real login) | **ALL CHECKS PASSED** — 2026-09-29, details below |
| Human QA UI click-through (steps A, B, I, J) + §25 (14 areas) | **PASS** (2026-09-29, product owner) |

Live smoke against a running backend (`127.0.0.1:8000`, real `Admin` / PIN
login, script `smoke_phase12_fix1.py`):

- independent no-reason submit → **201**, one document, 2 lines,
  `sale_id`/`customer_id`/`reason` all `NULL`, refund `25`, stock A `10→12`,
  stock B `5→6`, `RETURN` movements `+2`/`+1` recorded once;
- exact replay of that payload → **201** with `idempotent_replay=true` and
  **no second stock restore**;
- unknown product → **404**; supplied invalid reason → **422**; supplied
  valid reason → **201** and persisted (stock still restored);
- linked invoice: defaults `5`/`2` (no prior returns) → partial return of
  `2` (reason `NULL`) → remaining defaults `3`/`2` → submit remaining →
  line remaining `0`/`0` → cumulative refunds `60 == invoice total 60.000`;
  linked replay → **201** `idempotent_replay=true`;
- cap: returning a fully returned line → **409 `RETURN_EXCEEDS_SOLD`**;
- void: missing reason **422**, blank reason **422**, with reason **200**
  and `status=void`; `GET /returns` lists every document once.

### 7.7 Idempotency replay fix (defect found by the live smoke)

The smoke's exact-payload replay returned **409 `IDEMPOTENCY_CONFLICT`**
instead of replaying the original document. `_line_signature` compared
`str(to_decimal(quantity))`: the request sends `Decimal('2')` → `'2'` while
the persisted `NUMERIC(18,3)` comes back as `Decimal('2.000')` → `'2.000'`,
so the signatures differed and an exact retry looked like a different
payload. The existing unit test masked this by sending `"1.000"`.

Fix: `ReturnService._qty_key` (`app/services/returns.py`) normalizes the
quantity with `format(Decimal.normalize(), "f")` before it enters the
signature, so `1`, `1.000` and `1.0` compare equal, while a genuinely
different quantity still conflicts. Locking, caps, refund valuation and
the `client_request_id` idempotency contract (same key + same payload →
replay, different payload → 409) are unchanged.

Regression test: `test_replay_matches_short_and_persisted_quantity_forms`
(`tests/unit/test_returns.py`) — a linked and an independent replay typed
as `1`/`2` both return 201 `idempotent_replay=true` with stock restored
exactly once, and `3` under the same key still returns 409.

### 7.8 UI bug fix — the return result dialog popped the wrong navigator (2026-09-29)

**Observed (Windows runtime):** closing the success dialog threw
`You have popped the last page off of the stack, there are no pages left to
show` (`go_router/src/delegate.dart:162`) followed by `'!_debugLocked' is not
true`, top frame
`returns_screen.dart:95` → `_showResultDialog.<closure>.<closure>`.

**Root cause:** with a `ShellRoute`, go_router builds a **nested Navigator**
for the shell's child pages (`builder.dart:285`), so the `/returns` page lives
on the *inner* navigator, while `showDialog` (default `useRootNavigator: true`)
pushes the result dialog on the *root* navigator. `Navigator.pop(context)` in
the OK handler used the **Returns screen's** context — the inner navigator —
whose topmost route is the `/returns` **page**. `NavigatorState.pop` saw a
page-based route, invoked GoRouter's `onPopPage`, which removed the last match
and emptied the route stack; the dialog itself was never closed.

**Fix** (`lib/features/returns/returns_screen.dart`, no backend / no routing
change): the dialog builder now captures `dialogContext` and closes through
`_closeResultDialog(dialogContext)`, which pops only when
`ModalRoute.of(dialogContext)` is `isCurrent` (and not `isFirst`) — one pop,
on the dialog's own navigator, and a repeated/second invocation while the
dialog is closing is a no-op. After OK the Returns screen stays open; no
`GoRouter` navigation happens. The other returns dialogs (`return_products`,
`return_create`, `return_detail`, `return_void`) already pop from their own
build context and are unaffected.

**Regression tests** (`test/widget/returns_screen_test.dart`, +2):
- *"OK closes only the result dialog and keeps /returns"* — full Return
  Products flow → success dialog → OK → no exception, dialog gone, Returns
  screen still visible, `router.state.uri.path == '/returns'`,
  `currentConfiguration.isNotEmpty`.
- *"a repeated tap on OK while the dialog closes never pops the Returns
  route"* — fires the captured close handler a second time while the dialog
  is closing (a pointer cannot land on a closing route). With the guard
  removed this test reproduces the reported assertion.

**Verification:** `flutter analyze` clean · `flutter test` **1010 passed**
(1008 before this fix) · `flutter build windows --debug` built.

---

## 8. Final closeout (2026-09-29)

**STATUS: CLOSED / APPROVED · HUMAN QA: PASS · TECHNICAL VERIFICATION: PASS ·
GIT: COMMITTED**

| Gate | Result |
|---|---|
| `pytest -q` (backend) | **790 passed** |
| `pytest -q tests/unit/test_returns.py tests/unit/test_void.py tests/integration/test_return_concurrency.py` | **52 passed** |
| targeted Phase 12 incl. `test_migrations` | **103 passed** |
| `ruff check app` | **64** (pre-existing baseline, no new errors; Phase 12 files **0**) |
| `flutter analyze --no-pub` | **No issues found!** |
| `flutter test --no-pub` | **1010 passed** |
| `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\supermarket_pos.exe` |
| `alembic current` | `f5a6b7c8d9e0 (head)` |
| `alembic heads` | **exactly one** head: `f5a6b7c8d9e0` (0017) |
| `alembic check` | `No new upgrade operations detected.` (no drift) |
| Phase 11 (purchases / suppliers) | green inside the 790 suite; **no Phase 11 file touched** by this change set |
| Human QA (§25, 14 areas + fix round 1) | **PASS** — executed and signed off by the product owner |
| Result-dialog routing fix (§7.8) | **manually verified** in the Windows build |
| Blocking issues | **none remaining** |

**Scope discipline:** no new features, no business-rule change, no Phase 11
change, no GoRouter reconfiguration; only the records in this file and
`PHASE_12_RETURNS_VOIDS_ANALYSIS.md` were updated at closeout.

**Commit:** one commit, message `phase-12: complete returns and voids`
(message recorded here without its hash — a file cannot contain the hash of
the commit that carries it).
