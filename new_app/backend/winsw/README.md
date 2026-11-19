# WinSW service integration — Supermarket Pro backend (R2)

**Status: prepared, NOT installed.** R2 ships the configuration and the
least-privilege ACL script only. Registering the service is an installer
phase action (or a deliberate operator action); nothing in this
repository runs `winsw install`, `sc create` or `grant_data_dir_acl.ps1`
automatically.

| File | Purpose |
|---|---|
| `SupermarketProBackend.xml` | WinSW v2/v3 service definition (absolute paths, automatic start, restart policy, graceful stop, stdout/stderr redirection, service account) |
| `grant_data_dir_acl.ps1` | One-shot least-privilege ACLs: Modify on the ProgramData data root only, read+execute on the install tree |
| `README.md` | This runbook |

---

## 1. What the service runs

```
C:\Program Files\Supermarket Pro\backend\
    .venv\Scripts\python.exe      <- <executable> (replace with the frozen
                                      runtime when packaging lands)
    run_production.py             <- production launcher (R2)
    app\...                       read-only code

C:\ProgramData\SupermarketPro\    <- DATA_DIR (all writes)
    config\.env                   installer-generated settings
    config\secrets.env            per-install APP/JWT secrets (R2)
    logs\backend.log              structured application log (R2, rotating)
    logs\SupermarketProBackend.*  WinSW stdout/stderr capture (rolling)
    license\ data\ backups\       as defined by docs/R1_DATA_PATHS.md
```

`run_production.py`:

* requires `DATA_DIR` (set below) and the production `.env`;
* `chdir`s to the backend root, forces `APP_ENV=production`;
* provisions/loads `config\secrets.env` **before** settings are built;
* serves `app.main:app` with `reload=False`, `workers=1`, host/port from
  the configured `.env`;
* exits `0` on a clean stop, non-zero on failure (WinSW restart policy
  only fires for non-zero exits).

Development is unaffected: keep using
`python -m uvicorn app.main:app --reload` from `new_app\backend`.

## 2. Prerequisites

1. Backend installed under `C:\Program Files\Supermarket Pro\backend`
   (paths in the XML are absolute and must match).
2. `C:\ProgramData\SupermarketPro\config\.env` present, with a valid
   `DATABASE_URL`. Secrets are generated on first start into
   `config\secrets.env` — no manual step.
3. WinSW v2 or v3 (`winsw.exe` / `WinSW.exe`), downloaded from
   <https://github.com/winsw/winsw/releases> — **not** bundled in R2.

## 3. Register the service (operator / installer action)

```powershell
# 1) Least-privilege ACLs — once, before first start.
powershell -ExecutionPolicy Bypass -File .\grant_data_dir_acl.ps1

# 2) Rename the wrapper so it matches the <id> in the XML.
Copy-Item .\winsw-x64.exe .\SupermarketProBackend.exe

# 3) Register (does NOT start the service).
.\SupermarketProBackend.exe install .\SupermarketProBackend.xml

# 4) Start and verify.
.\SupermarketProBackend.exe start
.\SupermarketProBackend.exe status
Invoke-RestMethod http://127.0.0.1:8000/api/v1/health/live
```

Uninstall (never deletes data):

```powershell
.\SupermarketProBackend.exe stop
.\SupermarketProBackend.exe uninstall
```

## 4. Service account

The XML runs as **`NT AUTHORITY\NetworkService`** — a built-in,
documented, low-privilege Windows account with no password stored in any
file. It is deliberately **not** `LocalSystem`.

`grant_data_dir_acl.ps1` gives it:

| Location | Permission | Why |
|---|---|---|
| `C:\ProgramData\SupermarketPro` (+ children) | **Modify**, inherited | write `.env`-adjacent state, license, server id, backups, logs; inherited ACEs are first stripped so ordinary users cannot read `config\secrets.env` |
| `C:\Program Files\Supermarket Pro` (+ children) | **ReadAndExecute** only | import the code; **never** write — the install tree stays read-only |
| everything else | unchanged | no broad grants |

An operator who prefers a dedicated account can change one line of the
XML (`<serviceaccount><username>.\SMPBackendSvc</username>…`) and pass
the same name to `-Account` in the ACL script. The password for such an
account belongs in the installer's secret store, never in this XML.

## 5. Logging

| Stream | Destination | Rotation |
|---|---|---|
| Application (structlog, JSON) | `C:\ProgramData\SupermarketPro\logs\backend.log` | size-based, `LOG_MAX_BYTES` (5 MiB) × `LOG_BACKUP_COUNT` (10) retained — `app/core/logging.py` |
| Raw process stdout/stderr | `C:\ProgramData\SupermarketPro\logs\SupermarketProBackend.out.log` / `.err.log` | WinSW `roll-by-size`, 20 MiB, 10 files kept |

Both live under `DATA_DIR\logs`; nothing is written into Program Files.

## 6. Restart / failure policy

* `startmode=Automatic` + `delayedAutoStart` → starts after boot, once
  the machine has settled.
* `onfailure`: restart after 10 s, then 30 s, then indefinitely;
  `resetfailure=1 hour` clears the counter after a stable hour.
* Stop: WinSW sends Ctrl+C, waits `stoptimeout=30 sec` for a graceful
  exit (application lifespan shutdown), then terminates. A clean stop
  exits `0`, so it never triggers the restart policy.

## 7. Known limitations (R2)

* The service is **not** installed, and this directory contains no
  WinSW binary.
* PostgreSQL is not installed, so the `<depend>` element is commented
  out; enable it once the target version's service name is known.
* The `<executable>` points at the development venv layout; the
  packaging phase replaces it with the frozen/embedded runtime.
* Migrations and the RBAC seed remain manual pre-start steps — R2 never
  runs Alembic automatically.
* Verified by unit tests against the XML schema
  (`tests/unit/test_service_winsw.py`); an end-to-end `winsw install` on
  a real Windows service host is still a manual QA step.
