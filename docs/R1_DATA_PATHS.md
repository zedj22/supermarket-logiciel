# R1 — Windows Production Data Paths & Runtime Architecture

**Scope:** R1 only. Separates application installation files from writable
runtime data and makes backend configuration independent of the process
current working directory (release-audit blockers **B4** and **B7**).
No installer, no PostgreSQL automation, no service wrapper, no key
provisioning — those remain later phases.

---

## 1. Old versus new path architecture

### Old (pre-R1)

| Concern | Location | Problem |
|---|---|---|
| Configuration (`.env`) | `CWD/.env` (`config.py`: `env_file=".env"`) | **CWD-relative (B4)** — the same install loads a different (or no) `.env` depending on where the process was started |
| License / trial state | `<backend>/data/license` | inside the install tree — unwritable under `C:\Program Files` (**B7**) |
| Server identity | `data/server_id` relative → resolved against **CWD** | identity file location drifts with the launch directory |
| Backups | `<backend>/backups` | install-tree writes (**B7**) |
| Logs | stdout only | no defined location |
| Database config | `DATABASE_URL` from CWD-relative `.env` | unstable resolution (content itself unchanged) |

`<backend>` = the directory holding `app/core/config.py`
(`new_app\backend` in development, e.g.
`C:\Program Files\Supermarket Pro\backend` when installed).

### New (R1)

| Concern | Production (`DATA_DIR` set) | Development (`DATA_DIR` empty, default) |
|---|---|---|
| Configuration (`.env`) | `<DATA_DIR>/config/.env` | `<backend>/.env` (same file as before) |
| License / trial state | `<DATA_DIR>/license` | `<backend>/data/license` (unchanged) |
| Server identity + app data | `<DATA_DIR>/data/server_id` | `<backend>/data/server_id` (unchanged location, now absolute) |
| Backups | `<DATA_DIR>/backups` | `<backend>/backups` (unchanged) |
| Logs (reserved) | `<DATA_DIR>/logs` | `<backend>/logs` |
| Database | unchanged: `DATABASE_URL` from the resolved `.env` | unchanged |

**Everything is resolved to an absolute path at settings-validation time;
nothing is ever resolved against the process CWD.**

## 2. Exact path definitions

### Production layout

```
C:\Program Files\Supermarket Pro\          <- read-only install tree
└── backend\                               <- BACKEND_ROOT (code, venv, tools)
    ├── app\...                            code (read-only)
    ├── alembic.ini, pyproject.toml        read-only
    └── app\licensing\verification_keys.json   packaged public keys (read-only)

C:\ProgramData\SupermarketPro\             <- DATA_DIR (all writes)
├── config\        .env (installer-generated: DATABASE_URL, secrets, DATA_DIR-independent settings)
├── license\       trial.state, license.state, hmac.key, install.keypair, install.keypair.state
├── data\          server_id (+ future application data)
├── backups\       *.sql, *.json manifests, *.zip archives
└── logs\          reserved: service stdout/stderr redirect target (backend itself still logs to stdout only)
```

### Development layout (DATA_DIR empty — identical to pre-R1)

```
new_app\backend\
├── .env                  config (absolute-resolved; was CWD-relative)
├── data\license\         licensing state
├── data\server_id        server identity (absolute-resolved; was CWD-relative)
├── backups\              backup catalogue
└── logs\                 reserved (never created eagerly)
```

### Resolution rules (in order)

1. **`.env` file** — `resolve_env_file()`:
   1. process env `DATA_DIR` set → `<DATA_DIR>/config/.env`
   2. otherwise → `<BACKEND_ROOT>/.env`
   A *relative* process `DATA_DIR` anchors to `BACKEND_ROOT`, never the CWD.
   The process environment is used deliberately: a dotenv file cannot
   locate itself. A `DATA_DIR` entry *inside* the dotenv file still
   configures the data paths (rule 2 finds the file first).
2. **`DATA_DIR`** — explicit production data root; absolutized at settings
   validation (relative values anchor to `BACKEND_ROOT`).
3. **`LICENSE_STATE_DIR`** — explicit override (absolute or relative to
   the data root) → else `<DATA_DIR>/license` → else `<BACKEND_ROOT>/data/license`.
4. **`SERVER_ID_FILE`** — explicit override → else `<DATA_DIR>/data/server_id`
   → else `<BACKEND_ROOT>/data/server_id`. Always absolute after validation.
5. **`BACKUP_DIR`** — read at call time by `BackupService.directory` and
   `storage.resolve_backup_dir` (tests monkeypatch it): explicit absolute
   wins; explicit relative resolves against the data root; empty →
   `<DATA_DIR>/backups` or `<BACKEND_ROOT>/backups`.
6. **`LOG_DIR`** — explicit override → else `<DATA_DIR>/logs` or
   `<BACKEND_ROOT>/logs`. Resolution only; nothing creates or writes it
   in R1 (the future service wrapper redirects stdout/stderr here).

### Startup behaviour (lifespan, `app/main.py`)

1. `setup_logging()`.
2. `ensure_data_dirs()` — **no-op when `DATA_DIR` is empty** (development
   keeps the historical lazy, on-write directory creation). With
   `DATA_DIR` set, creates `config/ license/ data/ backups/ logs/`;
   any `OSError` (missing parent that is really a file, no write
   permission, full disk) raises `DataDirectoryError` and **aborts
   startup** with an actionable log line — fail fast instead of 500-ing
   on every licensing/backup write later.
3. `legacy_data_locations()` — with `DATA_DIR` set, logs a
   `legacy_data_not_migrated` **warning** for any non-empty pre-R1 data
   still under `<backend>/data/license`, `<backend>/data/server_id` or
   `<backend>/backups`. **Nothing is moved, copied or deleted.**
4. Trial start, discovery, serve (unchanged).

## 3. Compatibility behaviour

* **Development / existing single-directory installs** (`DATA_DIR` unset):
  every path resolves exactly as before the only behavioural delta is
  that `.env` and `server_id` are anchored to `BACKEND_ROOT` instead of
  the CWD — which is what those installs already experienced, because
  they always ran from the backend directory. The CWD dependence was a
  latent defect, not a feature.
* **Existing installations adopting `DATA_DIR`**: the backend switches
  all *new* writes to `DATA_DIR`; existing in-tree data is detected and
  **reported** (startup warning) but never moved automatically.
* **Manual migration procedure** (operator action, nothing automatic):

  ```bat
  :: stop the backend first
  xcopy "<backend>\data\license"   "%ProgramData%\SupermarketPro\license\"   /E /I
  copy  "<backend>\data\server_id" "%ProgramData%\SupermarketPro\data\server_id"
  xcopy "<backend>\backups"        "%ProgramData%\SupermarketPro\backups\"    /E /I
  :: verify the warning is gone on next start, THEN delete the old copies
  ```

  The old copies are deleted only after a successful verification start —
  R1 itself never deletes anything.
* **Database**: untouched by R1. `DATABASE_URL` is read exactly as
  before, now from a deterministically located `.env`. R1 never creates,
  drops or re-creates a database; an existing database is always reused.
* **Uninstall/upgrade** (future installer): must leave `DATA_DIR`
  untouched — R1 makes that the only place customer data lives.

## 4. Windows permission assumptions (least privilege)

| Location | ACL assumption |
|---|---|
| `C:\Program Files\Supermarket Pro` | read for the service account / Users; write for Administrators only. R1 guarantees **no runtime write** targets this tree when `DATA_DIR` is set (code + tests assert every resolved writable path lies outside `BACKEND_ROOT`). |
| `C:\ProgramData\SupermarketPro` (and all subdirs) | created by the installer (or by `ensure_data_dirs` on first start) with **Modify** for the dedicated service account (or `NetworkService`); Administrators full. Clients never touch it. |
| Python bytecode | with a read-only install tree Python silently skips writing `__pycache__` (start the service with `PYTHONDONTWRITEBYTECODE=1` / `python -B` to make that explicit). |
| **DPAPI** | StateStore seals with **machine scope** (`CRYPTPROTECT_LOCAL_MACHINE`, `state_store.py`), so the future service account and any interactive admin on the same machine can unprotect state written by the other — no profile-dependent sealing, no change needed for R1. State lives under `ProgramData`, not a user profile. |
| PostgreSQL | unchanged: server data directory stays under `ProgramData\SupermarketPro\postgres\data` per the Phase-0 decision (later phase). |

## 5. Development versus production differences (summary)

| | Development (`DATA_DIR` empty) | Production (`DATA_DIR` set) |
|---|---|---|
| `.env` | `<backend>/.env` | `<DATA_DIR>/config/.env` (found via process env `DATA_DIR`) |
| Licensing state | `<backend>/data/license` | `<DATA_DIR>/license` |
| Server identity | `<backend>/data/server_id` | `<DATA_DIR>/data/server_id` |
| Backups | `<backend>/backups` | `<DATA_DIR>/backups` |
| Logs | `<backend>/logs` (reserved) | `<DATA_DIR>/logs` (reserved) |
| Startup directory creation | none (lazy, on write) | all five subdirectories, fail-fast on error |
| Legacy in-tree data | is the live data — no warning | warned (`legacy_data_not_migrated`), never moved |
| CWD influence | none (absolute resolution) | none (absolute resolution) |

## 6. Files changed by R1

* `new_app/backend/app/core/config.py` — `resolve_env_file()`,
  `DATA_DIR`/`LOG_DIR`, absolute path validators, `data_root()`,
  `ensure_data_dirs()`, `legacy_data_locations()`, `DataDirectoryError`.
* `new_app/backend/app/main.py` — lifespan: data-dir validation +
  legacy migration warnings before any state write.
* `new_app/backend/app/services/backup.py` — backup directory resolves
  against the data root.
* `new_app/backend/app/services/storage.py` — storage report path
  resolution matches (no CWD).
* `new_app/backend/.env.example` — `DATA_DIR`/`LOG_DIR` documentation,
  absolute-path notes.
* `new_app/backend/tests/unit/test_data_paths.py` — 23 new tests.
* This document.

Flutter is untouched: the client never touches server filesystem paths
(it receives backup filenames over the API only).

## 7. Non-goals (later phases)

Installer; PostgreSQL install/automation; service wrapper; log file sink;
scheduled backups; production key provisioning; database creation
wizard. R1 also does not alter trial duration/fingerprint/activation
contracts, Backup Manifest v2 cryptography, or any API payload.
