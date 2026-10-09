# PHASE 9 — Stage B: Backend Facturation Permissions (RBAC)

**Date of original implementation:** 2026-10-08/09 (Phase 9 Stage B)
**Report reconstructed:** 2026-10-09 (Phase 10 Stage B), from the current
implementation, Git history, tests re-run in this stage, and the Phase 10
Stage A read-only audit.
**Commit that shipped this work:** `81f7c35` — `feat: enforce facturation
permissions` (current HEAD at reconstruction time).
**Status:** implemented, tested, committed. This file is the permanent
record that was missing after Stage B originally delivered its report
in-chat only (flagged as P2-4 in the Phase 10 Stage A audit).

---

## 1. Objective and approved policy

Enforce backend RBAC on the Facturation feature so that:

- **Admin** and **Manager** can view and manage Facturation documents and
  Invoice Clients.
- **Cashier** and any user without roles/scopes are denied.
- All other module authorization (POS, sales, inventory, customers,
  suppliers, printing, reports, LAN, devices, …) is **unchanged**.

Flutter navigation gating is **Stage C** (separate deliverable,
`facture-docs/PHASE_9_STAGE_C_FLUTTER_PERMISSIONS_REPORT.md`); backend 403
is the security boundary.

---

## 2. New permission scopes

`new_app/backend/app/models/enums.py:71-73`:

```python
    # Facturation (Phase 9) — documents + invoice clients; admin + manager only.
    FACTURATION_VIEW = "facturation_view"
    FACTURATION_MANAGE = "facturation_manage"
```

| Scope value | Purpose |
|---|---|
| `facturation_view` | Read: list, detail, preview, PDF render |
| `facturation_manage` | Write: create, update documents; create/update/archive invoice clients |

`PermissionScope` total members after this change: **35** (verified:
`tests/unit/test_enums.py` asserts `len(PermissionScope) == 35`).

---

## 3. Role policy

`new_app/backend/app/core/seed.py` (`ROLE_PERMISSIONS`, lines 41–106):

| Role | `facturation_view` | `facturation_manage` | Source |
|---|---|---|---|
| `admin` | ✅ | ✅ | `seed.py:42` — `"admin": list(PermissionScope)` (all scopes, computed at import) |
| `manager` | ✅ | ✅ | `seed.py:82-83` — explicit entries in the manager list |
| `cashier` | ❌ | ❌ | `seed.py:88-105` — neither scope appears in the cashier list |

No other roles are defined by the seed. Custom roles created out-of-band
are unaffected until an operator assigns the scopes manually.

---

## 4. Endpoint-by-endpoint permission matrix

All handlers use the `require_permission(scope)` factory
(`new_app/backend/app/api/dependencies.py:131-153`), which depends on
`get_current_user` (token → session → user validation,
`dependencies.py:69-125`) and raises `ForbiddenError` with
`details={"required_permission": scope.value}` when
`user.has_permission(scope)` is False.

### 4.1 Facturation documents — `app/api/v1/factures.py` (prefix `/api/v1/factures`)

| # | Method + path | Permission | Line |
|---|---|---|---|
| 1 | `POST /api/v1/factures` | `FACTURATION_MANAGE` | `factures.py:149` |
| 2 | `POST /api/v1/factures/preview` | `FACTURATION_VIEW` | `factures.py:170` |
| 3 | `GET /api/v1/factures` | `FACTURATION_VIEW` | `factures.py:200` |
| 4 | `GET /api/v1/factures/{document_id}` | `FACTURATION_VIEW` | `factures.py:239` |
| 5 | `PUT /api/v1/factures/{document_id}` | `FACTURATION_MANAGE` | `factures.py:256` |
| 6 | `POST /api/v1/factures/{document_id}/pdf` | `FACTURATION_VIEW` | `factures.py:283` |

Router-level `api_rate_guard` + `device_guard` apply as on every other
router (`app/api/v1/router.py:46`). There is deliberately **no DELETE**
route (`factures.py:19-21`) — asserted by
`test_no_delete_route_on_collection_or_detail`
(`tests/unit/test_facturation_documents_api.py:271-279`).

### 4.2 Invoice clients — `app/api/v1/invoice_clients.py` (prefix `/api/v1/invoice-clients`)

| # | Method + path | Permission | Line |
|---|---|---|---|
| 7 | `GET /api/v1/invoice-clients` | `FACTURATION_VIEW` | `invoice_clients.py:88` |
| 8 | `POST /api/v1/invoice-clients` | `FACTURATION_MANAGE` | `invoice_clients.py:119` |
| 9 | `GET /api/v1/invoice-clients/{client_id}` | `FACTURATION_VIEW` | `invoice_clients.py:146` |
| 10 | `PUT /api/v1/invoice-clients/{client_id}` | `FACTURATION_MANAGE` | `invoice_clients.py:162` |
| 11 | `DELETE /api/v1/invoice-clients/{client_id}` | `FACTURATION_MANAGE` | `invoice_clients.py:178` |

`DELETE` is a **soft archive** (`archived_at` timestamp; idempotent; allowed
while documents reference the client; documents are never hidden) —
`app/services/facturation.py:409-428`.

**Coverage:** every one of the 11 endpoints carries an explicit
`Depends(require_permission(...))` — verified by grep in Phase 10 Stage B
(all `@router.` decorators listed above are immediately followed by a
`require_permission` dependency). No endpoint is unprotected.

---

## 5. Error envelopes (401 vs 403)

`new_app/backend/app/core/exceptions.py:253-277` (structured handler for
`AppError` subclasses):

**401 UNAUTHORIZED** (missing/invalid token, revoked/expired session) —
`UnauthorizedError`, `code = "UNAUTHORIZED"`, `details = {}`:

```json
{"error": {"code": "UNAUTHORIZED", "message_key": "errors.unauthorized",
 "message": "Missing authentication token", "details": {},
 "request_id": "<uuid|null>"}}
```

**403 FORBIDDEN** (authenticated but missing the scope) —
`ForbiddenError`, `code = "FORBIDDEN"`; the factory attaches the required
scope (`dependencies.py:143-148`):

```json
{"error": {"code": "FORBIDDEN", "message_key": "errors.forbidden",
 "message": "Permission denied: facturation_view",
 "details": {"required_permission": "facturation_view"},
 "request_id": "<uuid|null>"}}
```

Tested:
- 401: `tests/unit/test_facturation_documents_api.py:194-199`
  (asserts `code == "UNAUTHORIZED"`).
- 403: same file `:218-232` (asserts `code == "FORBIDDEN"` and
  `details.required_permission == "facturation_view"`).
- Cashier/guest denied on every PDF route:
  `tests/unit/test_phase7_facturation_pdf.py`
  (`test_pdf_requires_authentication`, `test_denied_roles_cannot_print`
  parametrized over cashiers + guest, `test_manager_can_print`).

---

## 6. Seeding behavior and existing-database implications

**Command:** `python -m app.core.seed` (CLI entry `run_seed()`,
`seed.py:168-191`; exit 0 on success, 1 on failure).

**Not automatic:** the application lifespan does **not** call the seed
(`seed.py:21-23` documents decision D15; `app/main.py` startup only sets up
logging/discovery). Migrations create the `permissions`/`roles` tables
(migration `0002`) but insert no data rows.

**Upsert logic** (`seed_roles_and_permissions`, `seed.py:109-165`) —
re-verified against the current file in Phase 10 Stage B:

1. For each `PermissionScope`: insert `Permission` only if `scope` not
   found (`:117-128`); `db.flush()`.
2. For each `(role_name, scopes)` in `ROLE_PERMISSIONS`: find-or-create
   `Role` (`:133-145`); read existing `{rp.permission.scope}` (`:148-151`);
   insert `RolePermission` only for scopes not already present (`:154-162`).
3. `db.commit()` (`:164`).

Additive and idempotent — it never deletes or updates existing rows, so
re-running is safe and custom roles are untouched.

**Existing-database implication (the operational gate):** a database last
seeded before Phase 9 has no `facturation_view` / `facturation_manage`
rows. Until `python -m app.core.seed` is run against that database,
`has_permission(FACTURATION_*)` is False for **everyone including admin** →
403 on all 11 routes (fail-closed; availability, not a security hole).
Operational procedure: `facture-docs/PHASE_9_DEPLOYMENT_RUNBOOK.md`.

---

## 7. Relevant tests and exact commands/results

Commands re-run during Phase 10 Stage B reconstruction (cwd
`new_app/backend`, backend `.venv` Python), 2026-10-09:

| Command | Result |
|---|---|
| `pytest tests/unit/test_facturation_documents_api.py tests/unit/test_invoice_clients_api.py tests/unit/test_enums.py tests/unit/test_auth.py tests/unit/test_phase7_facturation_pdf.py -q` | **207 passed**, 1 warning, 80.94s |
| `ruff check app/api/v1/factures.py app/api/v1/invoice_clients.py app/models/enums.py app/core/seed.py` | 2 findings, both **pre-existing baseline** items unrelated to RBAC logic: `N806` in `seed.py:170` (`SessionLocal` local variable in `run_seed`) and `I001` import-sort in `enums.py:6`. Repo-wide baselines (Stage A fresh runs on the same HEAD): `ruff check app tests` = 220, `mypy --strict app` = 454. |

Prior fresh full-suite evidence on the same HEAD `81f7c35` (Phase 10
Stage A read-only audit, `facture-docs/PHASE_10_STAGE_A_READ_ONLY_AUDIT_REPORT.md`
§10 — labeled as sourced from that audit, not re-run in this stage):

| Command | Result |
|---|---|
| `pytest tests/unit -q` | 3598 passed |
| `pytest tests/integration -q` | 106 passed (PostgreSQL available; includes numbering concurrency) |

Key test files covering this stage's behavior:

| File | What it pins |
|---|---|
| `tests/unit/test_enums.py` | `len(PermissionScope) == 35` |
| `tests/unit/test_auth.py` | Seed idempotency; admin role holds all 35; permission-count pins (33→35 bump in `81f7c35`) |
| `tests/unit/test_facturation_documents_api.py` | 401/403 envelopes on document routes; cashier/guest denied; manage-only on create/update; no DELETE route; immutable identity ignored |
| `tests/unit/test_invoice_clients_api.py` | Same matrix for invoice-clients CRUD + archive |
| `tests/unit/test_phase7_facturation_pdf.py` | Auth on PDF route; `COMPANY_MISSING` 422; stored date/number printed; totals/words match Phase 1 math |
| `tests/unit/test_facturation_documents_service.py` | Validation-before-transaction rollback; atomic line replace; numbering sequence; update immutability |
| `tests/integration/test_phase5_facturation_numbering.py` | True concurrent allocation (PG, 6 threads); failed create consumes no number; DB constraints |

---

## 8. Security boundary: Flutter nav visibility is not authorization

Stage C (`new_app/lib/features/shell/nav_items.dart`) hides the Facturation
and Invoice Clients navigation entries from users lacking
`facturation_view`. **This is UI-only.** The authoritative enforcement is
the backend `require_permission(...)` on every route (§4). A user who
bypasses the UI (direct URL, scripted API call) still receives 401/403 with
the structured envelope (§5). No route-level redirect guard was added in the
Flutter router — by approved design.

---

## 9. Known limitations / deviations

1. **Manual seed required on existing deployments** (§6) — fail-closed 403
   for all roles until `python -m app.core.seed` is run. Documented in the
   runbook; no startup diagnostic was added (Phase 10 Stage B kept startup
   behavior unchanged by mandate).
2. **View vs manage UI affordances:** a user with `facturation_view` but not
   `facturation_manage` can open lists/detail but create/update actions will
   403. The Flutter UI does not yet hide those action buttons — acceptable
   per approved policy; a possible future refinement.
3. **Immutability is application-level:** `doc_type`/`year`/`number`/
   `document_date` are omitted from the update schema and silently ignored;
   the DB unique triple is the only DB backstop (no trigger). Low risk;
   noted in Stage A P3-6.
4. **Concurrency gate is PostgreSQL-only:** the true parallel-allocation
   integration test skips when PG is unreachable; SQLite ignores
   `FOR UPDATE` (Stage A P2-5).
5. **No optimistic locking:** concurrent PUTs to the same document are
   last-write-wins (Stage A P3-6).

None of these are P0/P1 defects (Stage A §11).

---

## 10. Git record

| Item | Value |
|---|---|
| Shipping commit | `81f7c35` — `feat: enforce facturation permissions` |
| Files changed in that commit (facturation-RBAC scope) | `app/models/enums.py`, `app/core/seed.py`, `app/api/v1/factures.py`, `app/api/v1/invoice_clients.py`, `tests/unit/test_enums.py`, `tests/unit/test_auth.py`, `tests/unit/test_facturation_documents_api.py`, `tests/unit/test_invoice_clients_api.py`, `tests/unit/test_phase7_facturation_pdf.py` |
| Existing-test edits | Permission-count pins only (33→35); no assertions weakened |
| Additive-only check | Router registrations for factures/invoice-clients were added in earlier Phase 9 commits (`5cac783`, `238b48b`) without removing any existing router (Stage A §9 verified via git diff) |

---

*End of Phase 9 Stage B permanent report. Reconstructed and re-verified
during Phase 10 Stage B; all quoted line numbers and test results were
checked against the current tree at HEAD `81f7c35`.*
