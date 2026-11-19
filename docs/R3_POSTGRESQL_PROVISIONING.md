# R3 — PostgreSQL Provisioning & Database Lifecycle

**Scope:** R3 only. Makes the database itself provisionable: locate the
PostgreSQL installation without touching it, decide whether it can host
this application, create the database **only when absent**, migrate it to
the single Alembic head, and seed the RBAC catalog — all idempotently and
without ever dropping or rewriting anything.

R3 does **not** run an installer on the developer's machine, does not
install or reconfigure PostgreSQL, never migrates the developer's active
database, contains no destructive SQL, changes no licensing/Backup Manifest
contracts, and adds no Flutter code. `new_app_upload/`,
`new_app_upload.zip` and `tatus` are untouched.

Builds on R1 (`docs/R1_DATA_PATHS.md`, path architecture) and R2
(`docs/R2_PRODUCTION_RUNTIME.md`, launcher/secrets/logging).

---

## 1. What a provisioning pass looks like

```python
from app.core.postgres_provisioning import provision_database

report = provision_database(
    app_url="postgresql://app_user:…@localhost:5432/supermarket_pro",
    admin_url="postgresql://postgres:…@localhost:5432/postgres",
)
assert report.ok
```

The pass is strictly linear and each step is recorded as `applied`,
`skipped`, `planned` or `failed`:

| Step | Does | Never |
|---|---|---|
| `instance` | discover + select a server (§2) | start/stop/reconfigure anything |
| `connect` | open a maintenance connection, classify errors | echo a password |
| `database` | `CREATE DATABASE` **if absent** | drop, rename, re-own, truncate |
| `migrations` | `alembic upgrade <head>` via subprocess | run against an unknown target |
| `rbac` | seed roles/permissions/grants, then audit | write to `users` |

`report.as_dict()` is JSON-safe and scrubbed: every occurrence of a known
secret is replaced with `***`.

### Failure is always fail-closed

| Error | Raised when |
|---|---|
| `InstanceUnavailableError` | discovery found no usable server |
| `IncompatibleVersionError` | major < 13, or major > 18 without `allow_unverified=True` |
| `CredentialsError` | authentication refused, or no `admin_url`/`PG_ADMIN_URL` for a local host |
| `MigrationError` | `alembic upgrade` exited non-zero (the database is left exactly as it was) |
| `ProvisioningError` | everything else, carrying the partial `report` |

## 2. Discovery — read-only (§2)

`app/core/postgres_discovery.py` merges four independent sources in
priority order. **Nothing is written, started or installed**; the only
probes allowed are `sc.exe query`, `sc.exe qc` and `psql.exe --version`.

| # | Source | What it yields |
|---|---|---|
| 1 | settings overrides `PG_INSTALL_DIR` / `PG_BIN_DIR` / `PG_DATA_DIR` / `PG_SERVICE_NAME` / `PG_PORT` | everything, explicitly |
| 2 | registry `HKLM\SOFTWARE\PostgreSQL\Installations\*` (+ WOW6432) | base dir, version, data dir, service id/account, superuser, branding |
| 3 | filesystem `<root>\*\bin\psql.exe` under `C:\Program Files\PostgreSQL` and `…\PostgreSQL (x86)` | install/bin dir, tools |
| 4 | Windows services (`sc.exe query state= all` + `sc.exe qc <name>`) | service name, RUNNING/STOPPED, binary path, data dir, account, port |

Sources are merged per-instance identity (install dir, data dir, service
name); a fact found in a higher-priority source wins, and every instance
records which sources contributed (`instance.sources`).

The port comes from `PG_PORT` → `postgresql.conf` `port =` → `DEFAULT_PORT`
(5432). `listen_addresses` is read for information only.

### Version policy (evidence-based)

| Constant | Value | Why |
|---|---|---|
| `MIN_SUPPORTED_MAJOR` | `13` | migrations `0002`/`0015` need `gen_random_uuid()`; `0023` needs trusted `pg_trgm` |
| `VERIFIED_MAX_MAJOR` | `18` | the newest major exercised by this project's suite |

`check_compatibility()` returns `Compatibility(accepted, verified, reason)`.
A major **above** 18 is *accepted but unverified* and requires an explicit
`allow_unverified=True`; a major **below** 13 is rejected outright. Nothing
in between is guessed at.

## 3. Plan before execute (§3)

`plan_provisioning()` performs discovery and decides **without opening a
single connection**:

* `reuse` — a compatible, running server was found;
* `install-dedicated` — nothing found and a verified installer was staged;
* `fail` — nothing usable, reported with reasons.

On this machine:

```console
> python -m app.core.postgres_provisioning --plan --json
{
  "action": "reuse",
  "instance": {
    "label": "PostgreSQL 18.6-4 (C:\\Program Files\\PostgreSQL\\18)",
    "major": 18, "version": "18.6-4", "service": "postgresql-x64-18",
    "state": "RUNNING", "port": 5432,
    "sources": ["registry", "filesystem", "service"]
  },
  "steps": [
    {"name": "discover", "status": "applied", "detail": "PostgreSQL 18.6-4 …"},
    {"name": "select",   "status": "applied", "detail": "PostgreSQL 18.6-4 …"},
    {"name": "port",     "status": "skipped", "detail": "using the detected port 5432"}
  ]
}
```

## 4. Credentials (§5)

* The **application role** comes from `app_url` (`DATABASE_URL`).
* The **maintenance/superuser role** comes from, in order: the explicit
  `admin_url` argument → the `PG_ADMIN_URL` environment variable. It is
  **never** taken silently from `settings.DATABASE_URL` — a local host with
  no admin credentials fails closed with `CredentialsError`.
* Only local hosts (`''`, `localhost`, `127.0.0.1`, `::1`) are ever
  provisioned by this pass; a remote `app_url` is the operator's business
  and is refused.

Per-install password file (alongside R2's `secrets.env`, which is never
modified):

```
<DATA_DIR>/config/database.env     # created once, then load-only
    DATABASE_PASSWORD=<CSPRNG or installer-supplied>
```

`secrets.ensure_database_password()` generates a 43-character URL-safe
value on first call (or accepts an installer-supplied one, validated as
≥8 URL-safe characters with no quotes/newlines) and afterwards returns the
existing value — it never rotates. `secrets.load_database_password()`
reads it back and returns `None` when absent. `secrets.env` and `.env`
are untouched by both.

## 5. RBAC initialisation & audit (§5)

`app/core/rbac_bootstrap.py` exposes two operations over the same catalog:

* `audit_rbac(db)` — **read-only**; reports `missing_roles`,
  `missing_permissions`, `missing_role_permissions` (role → set of
  scopes), `users_modified` (always `0`).
* `initialize_rbac(db)` — seeds via the existing `seed_roles_and_permissions`
  (3 roles × 35 permissions from `ROLE_PERMISSIONS`), then audits, so the
  returned report describes the *post* state. Idempotent: a second call
  reports `seeded == {"permissions": 0, "roles": 0, "role_permissions": 0}`.

`WRITABLE_TABLES = {"roles", "permissions", "role_permissions"}` —
`users` is **not** writable by this module, by construction and by test
(`test_module_source_never_targets_the_users_table` scans the module's
non-docstring string literals for `INSERT/UPDATE/DELETE … users` and
`pin_hash=`). Administrator credentials can therefore never be created,
reset or rotated by provisioning.

## 6. Migrations

`run_migrations(url, revision=head)` shells out to
`python -m alembic upgrade <rev>` with `DATABASE_URL` in the child
environment and `cwd=<backend root>`. A subprocess is mandatory here:
`migrations/env.py` overwrites `sqlalchemy.url` from
`settings.DATABASE_URL` at import time, so an in-process Alembic API call
would silently migrate the *configured* database instead of the requested
one.

`head_revision()` asserts there is exactly one head; a non-zero exit
raises `MigrationError` carrying the captured output, and the database is
left exactly as it was (verified by `test_migration_failure_leaves_the_database_intact`).

## 7. Dedicated-install adapter — double-locked

`install_dedicated()` is the only code path that could ever execute an
installer, and all four conditions must hold simultaneously:

1. `execute=True` (the caller explicitly asked for execution),
2. `R3_ALLOW_POSTGRESQL_INSTALL=1` in the environment (never settable
   from `.env` — it is read from the process environment only),
3. `verify_installer()` SHA-256 matches the expected digest,
4. an explicit `runner` callable is supplied (nothing is invented).

The unattended flag set (`--mode unattended --unattendedmodeui none
--disable-components stackbuilder --enable_acledit 1`, plus
`--superaccount` / `--prefix`) was **corrected in R5** against EDB's
official parameter list (`docs/R5_INSTALLER_DESIGN.md` §1.2); the
tokens are still never executed on the development machine.
`redacted_argv()` / `redacted_command()` make any logged command safe.
`plan_dedicated_install()` and `--plan` never execute anything.

R3 itself never installs PostgreSQL; the adapter exists so the installer
round can call it deliberately.

## 8. CLI

```console
python -m app.core.postgres_provisioning [--plan] [--dry-run]
        [--no-migrations] [--no-rbac] [--allow-unverified] [--json]
```

| Flag | Effect |
|---|---|
| `--plan` | discovery only — no connection, no write |
| `--dry-run` | connects and inspects, creates/migrates/seeds nothing |
| `--no-migrations` / `--no-rbac` | skip those steps |
| `--allow-unverified` | accept a major newer than 18 |
| `--json` | machine-readable report (scrubbed) |

Exit code `0` when the report is `ok`, non-zero otherwise. Human output
prints the same steps as the JSON.

## 9. Files added/changed by R3

| File | Role |
|---|---|
| `new_app/backend/app/core/postgres_discovery.py` | read-only discovery, version policy, merge, selection (§2) |
| `new_app/backend/app/core/postgres_provisioning.py` | plan/provision/migrations/adapter/CLI (§1, §3, §6–§8) |
| `new_app/backend/app/core/rbac_bootstrap.py` | `audit_rbac` / `initialize_rbac` (§5) |
| `new_app/backend/app/core/secrets.py` | `database.env` + `ensure_database_password` / `load_database_password` (§4) |
| `new_app/backend/app/core/config.py` | `PG_INSTALL_DIR`, `PG_BIN_DIR`, `PG_DATA_DIR`, `PG_SERVICE_NAME`, `PG_PORT` |
| `new_app/backend/.env.example` | documents the `PG_*` overrides (all empty by default) |
| `new_app/backend/tests/unit/test_postgres_discovery.py` | 40 tests |
| `new_app/backend/tests/unit/test_postgres_provisioning.py` | 56 tests (+1 skipped on Windows) |
| `new_app/backend/tests/unit/test_rbac_bootstrap.py` | 19 tests |
| `new_app/backend/tests/integration/test_postgres_lifecycle.py` | 16 tests, real server |
| `docs/R3_POSTGRESQL_PROVISIONING.md` | this document |

**131 tests green, 1 skipped** (a POSIX `0600` file-mode assertion).
Ruff is clean on every file above.

## 10. Safety guarantees, as tested

| Guarantee | Test |
|---|---|
| discovery never writes/starts/installs | `test_postgres_discovery.py::TestReadOnlyGuarantees` (token-level allowlist of probe argv) |
| no `DROP`/`TRUNCATE`/`ALTER` anywhere in R3 | `ALLOWED_SQL` regex + statement assertions in `test_postgres_provisioning.py` |
| the developer's database is never migrated | `test_postgres_lifecycle.py::TestFreshInstallation::test_the_development_database_is_untouched` |
| backups stay byte-identical | `TestBackupsAreNeverTouched` (sha256 of the whole directory, before/after plan and provision) |
| RBAC never touches `users`/`pin_hash` | `TestAdministratorCredentialsAreUntouched` (row tuple compared, 3× repeated init) |
| migration failure leaves the DB intact | `test_migration_failure_leaves_the_database_intact` |
| wrong credentials create nothing | `test_wrong_credentials_are_rejected_without_creating_anything` |
| no admin URL → fail closed | `test_missing_database_without_admin_credentials_fails_closed` |
| provisioning is idempotent | `TestIdempotentReprovisioning` (second pass: `database_created is False`, table count and revision unchanged, single catalog) |
| no secret reaches a report or log | `PASSWORD not in str(...)` / `scrub()` assertions throughout |

### Deliberately out of scope / known limits

* **No `DROP DATABASE`.** The scratch databases created by the
  integration tests (`supermarket_pro_r3_test`, `supermarket_pro_r3_absent`)
  outlive the run by design; re-running the suite exercises the *reuse*
  path instead of re-creating them.
* **`database.env` is consumed by the launcher as of R5.** R3 provides
  `ensure_database_password()` / `load_database_password()` and their
  tests; `run_production.py` now calls `load_database_password(data_dir)`
  and publishes the assembled `DATABASE_URL` before `Settings()` is
  imported (`tests/unit/test_database_env_handoff.py`).
* **The unattended installer flags are unverified** — R3 never executes
  an installer, so that command line has not been proven against a real
  installer.
* **Discovery is Windows-only** (registry + `sc.exe`); on other platforms
  only the settings overrides and filesystem probes can contribute.

## 11. Evidence from this machine

Read-only inspection, nothing modified:

```
HKLM\SOFTWARE\PostgreSQL\Installations\postgresql-x64-18
    Base       = C:\Program Files\PostgreSQL\18
    Version    = 18.6-4
    Data       = C:\Program Files\PostgreSQL\18\data
    Service ID = postgresql-x64-18
    Account    = NT AUTHORITY\NetworkService
    Super User = postgres
postgresql.conf: port = 5432, listen_addresses = '*'
Service: RUNNING   Tools: psql/pg_dump/pg_ctl present
```

`python -m app.core.postgres_provisioning --plan --json` → `action:
reuse`, instance `PostgreSQL 18.6-4`, sources `registry + filesystem +
service`. `--dry-run --json` → every step `applied`/`skipped`/`planned`,
`database_created: false`, current revision `e5b7d2c9a41f`, and no
connection was used to write anything.
