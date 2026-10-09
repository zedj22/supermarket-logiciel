# PHASE 9 — Facturation Deployment / Operations Runbook

**Audience:** whoever deploys or upgrades a Supermarket Pro backend that
includes the Facturation feature (Phases 1–9).
**Scope:** operational steps only. This runbook does not change application
behavior; no automatic seeding or startup warnings were added (Phase 10
Stage B explicitly keeps startup behavior unchanged).

---

## 1. Why this runbook exists

The Facturation endpoints (`/api/v1/factures/*`, `/api/v1/invoice-clients/*`)
are protected by two permission scopes introduced in Phase 9:

- `facturation_view`
- `facturation_manage`

These scopes are **not** created by Alembic migrations. They are inserted by
the seed script (`python -m app.core.seed`), which is **not** executed at
application startup (decision record D15;
`new_app/backend/app/core/seed.py:21-23`).

**Consequence:** a database that was last seeded before Phase 9 exists has
no `facturation_view` / `facturation_manage` rows. Until the seed is re-run,
`user.has_permission(...)` is False for **every role — including admin** —
and all 11 Facturation endpoints return **403 FORBIDDEN** (fail-closed;
availability impact, not a security hole).

---

## 2. Pre-deployment checklist

1. **Back up the target database** using your established backup procedure
   (the app's own backup feature, `pg_dump`, or equivalent) **before** running
   any migration or seed command.
2. **Verify the application is pointed at the intended database.** Check
   `DATABASE_URL` in the backend `.env` (or the process environment). Confirm
   the host/db name match the environment you intend to change (dev, staging,
   production). Re-read the value after any deploy-script step that might
   rewrite `.env`.
3. Confirm you are deploying a build whose backend includes the Phase 9
   migrations **and** the Phase 9 permission code (HEAD at or after
   `81f7c35` — `feat: enforce facturation permissions`).

**Never run migrations or seed commands against a production or user
database as part of a coding/QA task.** Those steps belong to the deployment
procedure only.

---

## 3. Deployment procedure

Execute in this order, from the backend working directory
(`new_app/backend`, with the backend virtual environment active):

### 3.1 Apply migrations

Use the project's established migration procedure (Alembic). After applying,
confirm a single head:

```bash
alembic current   # expect the new head revision
alembic heads     # expect exactly one head
```

Relevant Facturation migrations (for reference):
- `0026_phase2_facturation` — documents/lines/counters tables
- `0027_phase2_facturation_year_numbering` — `year` column + unique triple
- `0028_phase6_facturation_settings` — company/fiscal settings keys

### 3.2 Re-seed roles and permissions

From `new_app/backend` with the correct `DATABASE_URL`:

```bash
python -m app.core.seed
```

Expected output ends with `Seed complete: {...}` and a non-zero
`role_permissions` count the first time it runs on a pre-Phase-9 database
(the two new permission rows plus the admin/manager assignments). Exit code
is 0 on success, 1 on failure (`seed.py:168-191`).

**Verified additive/idempotent behavior**
(`new_app/backend/app/core/seed.py:109-165`, re-verified in Phase 10 Stage B
against the current implementation):

1. For every `PermissionScope` enum member: insert a `Permission` row only
   if `scope` is not already present. Never updates or deletes existing rows.
2. For every `(role_name, scopes)` in `ROLE_PERMISSIONS`: find or create the
   `Role`; read the role's existing permission scopes; insert a
   `RolePermission` only for scopes not already assigned. Never deletes.
3. Single `db.commit()` at the end.

Re-running the seed on an already-up-to-date database is a no-op (all rows
exist; created-counters stay 0). The seed **never removes** permissions or
role assignments, so it is safe on databases that already carry custom
roles — custom roles are simply untouched.

### 3.3 Verify the seeded permission matrix

After the seed, confirm the actual database state (SQL or psql):

| Role | Must have | Must NOT have |
|---|---|---|
| `admin` | `facturation_view`, `facturation_manage` (admin gets **all** scopes — `seed.py:42`: `list(PermissionScope)`) | — |
| `manager` | `facturation_view`, `facturation_manage` (`seed.py:82-83`) | — |
| `cashier` | — | `facturation_view`, `facturation_manage` (`seed.py:88-105` grants neither) |

Example check (adjust to your SQL client):

```sql
SELECT r.name, p.scope
FROM role_permissions rp
JOIN roles r ON r.id = rp.role_id
JOIN permissions p ON p.id = rp.permission_id
WHERE p.scope IN ('facturation_view', 'facturation_manage')
ORDER BY r.name, p.scope;
```

Expected rows: `admin` × 2 scopes, `manager` × 2 scopes, **no** `cashier`
rows.

### 3.4 Verify endpoints after deployment

With a running backend and a valid login token per role:

| Check | Expectation |
|---|---|
| Login as **admin** → `GET /api/v1/factures` | 200 |
| Login as **manager** → `GET /api/v1/factures` | 200 |
| Login as **cashier** → `GET /api/v1/factures` | **403** with `error.code = "FORBIDDEN"` and `error.details.required_permission = "facturation_view"` |
| No token → `GET /api/v1/factures` | **401** with `error.code = "UNAUTHORIZED"` |
| Login as **admin** → `POST /api/v1/factures` (create) | 201 (manage scope) |
| Login as **cashier** → `POST /api/v1/invoice-clients` | **403** |
| Login as **admin** → `GET /api/v1/invoice-clients` | 200 |

### 3.5 Verify Flutter navigation

On a device/PC running the Flutter app against the deployed backend:

1. Login as **admin** → the navigation rail shows **Facturation** and
   **Invoice clients**.
2. Login as **manager** → same two entries visible.
3. Login as **cashier** → neither entry is visible; POS and Clients remain.
4. Regression note: nav visibility is **UI-only**. Backend 403 is the
   security boundary — a user who navigates directly to `/facturation` by
   URL still gets a 403 from the API (the screen shows a localized
   permission error, not data).

---

## 4. Rollback / failure notes

- The seed is additive-only; there is nothing to "un-seed" via the script.
  Removing the scopes would require manual DB edits and is **not**
  recommended — the fail-closed 403 behavior is the safe state.
- If migrations succeed but the seed is forgotten, the application runs and
  every non-Facturation module works normally; only the 11 Facturation
  endpoints 403 for everyone. Running the seed afterwards fixes it without
  a restart (permissions are read from the DB per request).
- If the seed fails mid-way (process crash), re-run it — the transaction in
  `seed_roles_and_permissions` either committed fully or not at all.

---

## 5. What this runbook deliberately does NOT do

- No automatic seeding at application startup.
- No startup warnings or other application behavior changes.
- No changes to existing roles/permissions outside the additive facturation
  scopes.

These constraints were mandated by Phase 10 Stage B scope. A future stage
may add a startup diagnostic (e.g., a log line when `facturation_view` is
absent from the `manager` role) if the reviewer requests it.
