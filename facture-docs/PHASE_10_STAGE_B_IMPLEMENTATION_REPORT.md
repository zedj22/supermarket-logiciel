# PHASE 10 — Stage B: Implementation Report

**Date:** 2026-10-09
**Baseline commit:** `81f7c35` — `feat: enforce facturation permissions`
**Scope:** three deliverables — deployment runbook, picker error
localization fix, permanent Phase 9 Stage B report. Nothing else was
changed.

---

## 1. Baseline Git commit and initial working-tree state

Before any edit, on 2026-10-09:

- HEAD: `81f7c35c91799d9305d4f80517d16aafbbfeab52` (`feat: enforce facturation permissions`), branch `main`, in sync with `origin/main`.
- Zero tracked modifications vs HEAD.
- Untracked (pre-existing, preserved untouched):
  `new_app/bar.pdf`, `new_app/bar2.pdf`,
  `new_app/reports_financial_2026-09-25_2026-10-01_2026-10-01-092831.csv`,
  `new_app/reports_sales_2026-09-22_2026-10-01_2026-10-01-115842.csv`,
  `new_app/sale_INV-20261004-142659-926-0082_2026-10-04-192350.pdf`,
  `new_app/test/widget/failures/`, `new_app/test/widget/goldens/`,
  and the Phase 10 Stage A audit report
  `facture-docs/PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md` (created in the
  previous stage).

---

## 2. Files changed and rationale

### Modified (tracked)

| File | Change | Rationale |
|---|---|---|
| `new_app/lib/features/facturation/facturation_pickers.dart` | Both picker error paths now route through the established localized mappers instead of rendering `backendErrorMessage(e)` as the primary text. (+48 / −15 lines.) | Stage A finding **P2-2**: the invoice-client and product pickers bypassed the feature's error-mapper contract, leaking raw English backend messages as the headline error in the AR UI. |

### Created (new)

| File | Rationale |
|---|---|
| `facture-docs/PHASE_9_DEPLOYMENT_RUNBOOK.md` | **Deliverable 1** — safe-deployment procedure for the manual permission seed (Stage A P2-1 operational gate). |
| `facture-docs/PHASE_9_STAGE_B_BACKEND_PERMISSIONS_REPORT.md` | **Deliverable 3** — permanent record of the backend RBAC work (Stage A P2-4 documentation gap). |
| `new_app/test/widget/facturation_pickers_error_test.dart` | Focused widget tests for the fixed picker error paths (mandated by Deliverable 2 requirement 5). |
| `facture-docs/PHASE_10_STAGE_B_IMPLEMENTATION_REPORT.md` | This report. |

No other application source, test, schema, configuration, or dependency
file was touched. No existing report was modified.

---

## 3. Exact behavior changes

### Picker error mapping (the only runtime behavior change)

**Before** (both pickers, the two paths flagged in Stage A at lines 96–98
and 261–263):

```dart
_error = isConnectionError(e)
    ? AppStrings.t('network_error_retry', _loc)
    : (backendErrorMessage(e) ?? AppStrings.t('api_error_retry', _loc));
```

The raw backend `error.message` (English, e.g.
`"Permission denied: facturation_view"`) became the **primary** user-facing
line whenever a structured envelope was returned.

**After:**

- **Invoice-client picker** (`GET /api/v1/invoice-clients`) →
  `invoiceClientsApiError(e, _loc)` from
  `lib/features/invoice_clients/invoice_clients_error.dart` (the mapper that
  already owns that endpoint's codes: `NOT_FOUND` →
  `invoice_client_not_found`, plus `VALIDATION_ERROR`, `FORBIDDEN`/
  `AUTHORIZATION_ERROR`, `UNAUTHORIZED`/`AUTHENTICATION_ERROR`, and
  401/403/404/422 status fallbacks).
- **Product picker** (`GET /api/v1/products/search`) →
  `facturationApiError(e, _loc)` from
  `lib/features/facturation/facturation_error.dart` (the facturation-feature
  mapper; no dedicated products mapper exists, and this picker is a
  facturation component — handles network, 401/403/404/422 fallbacks and
  facturation envelope codes).
- Both now store `PosApiError.message` (always localized) as the primary
  `_error` line and `PosApiError.detail` (raw backend text) as a new
  secondary `_errorDetail` line — **the same primary/detail convention as
  `invoice_form_dialog.dart:679-691`**. Keys:
  `invoice-client-picker-error` / `-error-detail`,
  `facturation-product-picker-error` / `-error-detail`.
- `_errorDetail` is reset to `null` at the start of every `_load` alongside
  `_error`, so a retry after a failure clears both lines.
- Network failures (`response == null`) still show only the localized
  `network_error_retry` message with **no** detail line (unchanged).
- Loading state, debounce, stale-response guarding, empty state, list
  rendering, and selection (`Navigator.pop` with the model) are untouched.
- The now-unused `../../network/api_client.dart` import was removed
  (`apiClientProvider` comes from `auth_provider.dart`; the pickers no
  longer call `isConnectionError`/`backendErrorMessage` directly).

No API contract, provider, controller, or error-mapper file was changed.
No duplicate mapping system was created — the two existing mappers are
reused as-is.

### Runbook and Stage B report (documentation only)

- `PHASE_9_DEPLOYMENT_RUNBOOK.md` documents: back up first; verify
  `DATABASE_URL`; apply migrations via the established Alembic procedure;
  run `python -m app.core.seed` from `new_app/backend`; the seed is
  additive/idempotent (re-verified against `seed.py:109-165`); verify the
  admin/manager/cashier matrix in SQL; verify the 11 endpoints' 200/401/403
  behavior; verify Flutter nav visibility; rollback notes. It explicitly
  adds **no** startup seeding, warnings, or behavior changes.
- `PHASE_9_STAGE_B_BACKEND_PERMISSIONS_REPORT.md` reconstructs the scopes,
  role policy, 11-endpoint permission matrix with file:line, error
  envelopes, seed implications, fresh test results, the security-boundary
  statement, and known limitations — all labeled with evidence sources.

---

## 4. Tests / analysis executed and exact results

All commands run on 2026-10-09. Working directories noted.

| # | Command | Cwd | Result |
|---|---|---|---|
| 1 | `flutter test test/widget/facturation_pickers_error_test.dart -r expanded` | `new_app` | **8 passed** (all new tests; first run failed 7/8 with a synchronous-`thenThrow`/`initState` framework error — fixed by switching the stub to an async throw, see §5) |
| 2 | `flutter analyze` | `new_app` | **No issues found** (3.7s) |
| 3 | `flutter test test/widget/facturation_screen_test.dart test/widget/invoice_clients_screen_test.dart test/widget/facturation_nav_visibility_test.dart test/unit/localization_parity_test.dart test/unit/localization_coverage_test.dart test/unit/locale_test.dart` | `new_app` | **32 passed** (7.4s) — existing facturation/localization regression |
| 4 | `flutter test` (full suite) | `new_app` | **1609 passed** (2m56s) — was 1601 at Stage A; +8 new picker tests, zero regressions |
| 5 | `pytest tests/unit/test_facturation_documents_api.py tests/unit/test_invoice_clients_api.py tests/unit/test_enums.py tests/unit/test_auth.py tests/unit/test_phase7_facturation_pdf.py -q` | `new_app/backend` | **207 passed**, 1 warning (80.94s) — backend permission tests unaffected by this stage (no backend code changed) |
| 6 | `ruff check app/api/v1/factures.py app/api/v1/invoice_clients.py app/models/enums.py app/core/seed.py` | `new_app/backend` | 2 findings, both **pre-existing baseline** (`N806` `seed.py:170`, `I001` `enums.py:6`) — unrelated to this stage; repo baselines unchanged (220 ruff / 454 mypy per Stage A) |
| 7 | `git diff --check` | repo root | exit 0 (only an LF→CRLF notice on the modified file) |

New test inventory (`facturation_pickers_error_test.dart`, 8 tests):

| Test | Locale | Asserts |
|---|---|---|
| InvoiceClientPicker 403 FORBIDDEN | ar | primary = `permission_denied` (Arabic), ≠ raw message; detail = raw message |
| InvoiceClientPicker 403 FORBIDDEN | en | primary = `permission_denied` (English) |
| InvoiceClientPicker network failure | ar | primary = `network_error_retry`; no detail line |
| InvoiceClientPicker successful load + selection | ar | list renders; tap pops without exception (regression) |
| FacturationProductPicker 401 UNAUTHORIZED | ar | primary = `session_expired_login` (Arabic), ≠ raw; detail = raw |
| FacturationProductPicker 401 UNAUTHORIZED | en | primary = `session_expired_login` (English) |
| FacturationProductPicker 403 FORBIDDEN | fr (LTR) | primary = `permission_denied` (French) |
| FacturationProductPicker network failure | ar | primary = `network_error_retry`; no detail line |

Arabic (RTL) and two LTR locales (en, fr) are covered as mandated.

---

## 5. Failures, skipped tests, and limitations

- **First test run failed (7 of 8):** the initial stub used mocktail
  `thenThrow`, which throws **synchronously** when `dio.get` is called.
  Because the pickers call `_load('')` from `initState`, the catch block ran
  inside `initState` and `_loc` (`Localizations.localeOf(context)`) triggered
  the framework's "dependOnInheritedWidget … before initState completed"
  assertion. Real Dio failures complete the returned Future asynchronously,
  so the stub was corrected to `.thenAnswer((_) async => throw error)` —
  faithful to production and to how the existing test harness simulates
  responses. All 8 tests then passed. No production code was changed to
  accommodate the test; the production path (async failure) was always safe.
- No tests were skipped in the Flutter or focused backend runs.
- Integration tests and `mypy` were not re-run this stage (no backend code
  changed; Stage A fresh results on the same HEAD remain the reference:
  106 integration passed, mypy 454 baseline).
- Limitation: the pickers still open only from the invoice form dialog;
  this stage tested them directly as pumped widgets (they are
  self-contained), which is sufficient for the error-path contract but does
  not re-exercise the full form → picker navigation (covered indirectly by
  `invoice_form_dialog` usage in `facturation_screen_test.dart`).

---

## 6. Database confirmation

**No database was migrated or seeded.** No Alembic command, no
`python -m app.core.seed`, no SQL against any database, and no server was
started. Backend tests use in-memory SQLite / the dedicated
`supermarket_pro_test` PostgreSQL database only (unchanged conftest
behavior). The runbook **documents** the seed procedure; it does not
execute it.

---

## 7. Git hygiene confirmation

**No files were staged, committed, pushed, stashed, reset, cleaned, or
checked out.** `git clean` was not used. Every pre-existing untracked
artifact listed in §1 is preserved untouched. The only new untracked files
are the three deliverable documents and the one new test file listed in §2.

---

## 8. Final Git state

`git status --short --branch`:

```
## main...origin/main
 M new_app/lib/features/facturation/facturation_pickers.dart
?? facture-docs/PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md
?? facture-docs/PHASE_9_DEPLOYMENT_RUNBOOK.md
?? facture-docs/PHASE_9_STAGE_B_BACKEND_PERMISSIONS_REPORT.md
?? new_app/bar.pdf
?? new_app/bar2.pdf
?? new_app/reports_financial_2026-09-25_2026-10-01_2026-10-01-092831.csv
?? new_app/reports_sales_2026-09-22_2026-10-01_2026-10-01-115842.csv
?? new_app/sale_INV-20261004-142659-926-0082_2026-10-04-192350.pdf
?? new_app/test/widget/facturation_pickers_error_test.dart
?? new_app/test/widget/failures/
?? new_app/test/widget/goldens/
```

- 1 tracked file modified (the picker fix; 48 insertions, 15 deletions).
- 4 new untracked files (3 reports + 1 test); all other untracked entries
  are pre-existing artifacts.
- HEAD unchanged at `81f7c35`; branch in sync with `origin/main`.

`git diff --check`:

```
warning: in the working copy of 'new_app/lib/features/facturation/facturation_pickers.dart', LF will be replaced by CRLF the next time Git touches it
```

Exit code **0** — no whitespace errors (the LF→CRLF notice is the repo's
standard line-ending normalization notice, not a defect).

---

## 9. Deliverable summary

| Deliverable | Artifact | Status |
|---|---|---|
| 1 — Safe deployment runbook | `facture-docs/PHASE_9_DEPLOYMENT_RUNBOOK.md` | Done — documents backup, DB verification, migrations, additive/idempotent seed, role-matrix verification, endpoint + nav checks; no behavior changes |
| 2 — Fix untranslated picker errors | `new_app/lib/features/facturation/facturation_pickers.dart` + `test/widget/facturation_pickers_error_test.dart` | Done — both paths localized via existing mappers; raw text demoted to secondary detail; 8 new tests (ar + en + fr); full suite 1609 passed; analyze clean |
| 3 — Permanent Phase 9 Stage B report | `facture-docs/PHASE_9_STAGE_B_BACKEND_PERMISSIONS_REPORT.md` | Done — scopes, role policy, 11-endpoint matrix, envelopes, seed implications, fresh + labeled test evidence, security boundary, limitations |

**Stopping here per the mandate — Stage C must not begin until the
reviewer approves this stage.**
