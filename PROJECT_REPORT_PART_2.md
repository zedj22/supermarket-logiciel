# PROJECT REPORT — PART 2 (Sections 9–13)

Continuation of `PROJECT_REPORT.md` (§1–§8). Same repository, same audit date (2026-11-12). Paths are relative to the repository root.

---

## 9. Windows Packaging Readiness (CRITICAL)

### 9.1 Does the Flutter project have a `windows/` folder, and is it configured for desktop release builds?

**Yes, and it is a real, customised Windows target.**

| Item | Evidence |
|---|---|
| Windows runner present | `new_app/windows/` with `CMakeLists.txt`, `flutter/`, `runner/` (19 files) |
| Project/binary name | `project(supermarket_pos LANGUAGES CXX)`, `set(BINARY_NAME "supermarket_pos")` — `windows/CMakeLists.txt:3,7` |
| Executable produced | `build\windows\x64\runner\Release\supermarket_pos.exe` (standard Flutter layout; `installer/setup.iss` references `{app}\app\supermarket_pos.exe`) |
| Release config | Default Flutter CMake release configuration (no project-specific overrides found); `windows/runner/Runner.rc` supplies version info + CompanyName used by `%APPDATA%` paths |
| Custom native code | `windows/runner/raw_scanner_input.cpp` (489 lines) + `.h`, wired from `flutter_window.cpp` — **Raw Input barcode capture**, i.e. the runner is not stock |
| Plugins | `windows/flutter/generated_plugins.cmake`: `flutter_secure_storage_windows`, `printing` (native), FFI list contains `jni` |
| Manifest | `windows/runner/runner.exe.manifest` (standard DPI/ComCtl32 manifest) |

**Plugin Windows support:** all four runtime plugins are Windows-capable. `flutter_secure_storage_windows` uses DPAPI/Credential Manager; `printing` uses the native Windows print subsystem; `ffi` is pure FFI; `file_picker`, `shared_preferences`, `dio`, `go_router`, `riverpod`, `pdf` are Dart-only. **`jni` appears in the FFI plugin list** — it is not required by anything in `lib/`, so it is most likely a transitive dependency of another package; it is harmless on Windows but should be confirmed with `flutter pub deps` before release. **UNKNOWN - needs confirmation**: exact transitive origin of `jni`.

**Release build command (standard, not currently scripted in the repo):**

```
cd new_app
flutter build windows --release
```

No build script for the Flutter bundle exists in the repository (`installer/stage_payload.ps1` *stages* an existing build; it does not run `flutter build`). That is a gap for reproducible packaging (see §9.12, item P2).

### 9.2 Can the backend be bundled as a standalone executable? What is recommended?

**It does not need to be rewritten, and it does not need PyInstaller — the repository already contains a working, rehearsed bundling design.** The chosen approach is: **embedded official CPython + per-install virtual environment + offline wheelhouse + WinSW service.**

Evidence:

| Artifact | Role |
|---|---|
| `installer/stage_payload.ps1` (18 KB) | Builds the staged payload: `python\` (official CPython runtime with `Doc/include/libs/test` stripped), `wheelhouse\` (all wheels from `requirements.lock.txt`), the first-party backend tree (`app\`, `migrations\`, `winsw\`, `run_production.py`, `alembic.ini`, `requirements.lock.txt`), `vendor\` (PostgreSQL EDB installer + binaries zip + VC++ redist, all SHA-256 pinned), `vendor\THIRD_PARTY_NOTICES.md`, the built Flutter app |
| `installer/installer_provision.py` (13 KB) | Install-time orchestrator: secrets → optional dedicated PostgreSQL install (4 gates) → DB password → optional pre-migration `pg_dump` → `provision_database()` (create DB, `alembic upgrade head`, RBAC) → JSON report |
| `installer/setup.iss` (17 KB) | Inno Setup script: file copy, venv creation, offline pip install, provisioning, `run_production.py --check` health gate, VC++ redist, ACL grant, WinSW install+start, identity commit |
| `new_app/backend/run_production.py` | Production launcher: requires `DATA_DIR`, provisions/loads secrets, assembles `DATABASE_URL`, publishes `supermarket_endpoint.json`, single worker, clean Ctrl+C/SIGBREAK exit codes |
| `new_app/backend/winsw/SupermarketProBackend.xml` | Windows service definition (absolute paths, `Automatic` + delayed start, Ctrl+C stop, failure restarts, log redirection, dedicated account) |
| `installer/build_installer.ps1` | Compiles `SupermarketPro-Setup-REHEARSAL.exe` / `SupermarketPro-Setup.exe` with SHA-256 + evidence log |
| `installer/rehearsal_harness.ps1` (35 KB) | End-to-end rehearsal of install/upgrade/uninstall in an isolated root |
| `docs/R5_INSTALLER_DESIGN.md` (39 KB) | Design + verification record; ends "**PASS WITH LIMITATIONS**" |

**Why this is the right option for *this* stack (justification):**

1. **No rewrite risk.** FastAPI/uvicorn/SQLAlchemy/reportlab/cryptography/psycopg2 are all supported, tested and already pinned; the launcher and installer were built around them.
2. **Alembic needs its source tree.** Migrations are Python modules plus `alembic.ini` with `script_location = migrations` and `prepend_sys_path = .`. Freezing with PyInstaller requires bundling migration scripts as data, keeping a working `alembic` CLI inside the frozen app, and re-testing `alembic upgrade` in a one-file bundle — significant, avoidable risk.
3. **Subprocess dependencies.** `pg_dump`, `psql`, `powershell.exe`, `icacls` and `netsh` are invoked as external processes. A venv-based install keeps a normal `python.exe` and normal site-packages, which makes these calls, tracebacks and on-site debugging far simpler than a one-file executable.
4. **Native wheels are already resolved.** `psycopg2-binary`, `cryptography`, `argon2-cffi`, `reportlab` (with `pillow`) are binary wheels; the offline wheelhouse installs the exact known-good set (`requirements.lock.txt` was generated from the dev environment). PyInstaller would have to re-solve hidden imports for all of these.
5. **The alternative that *would* be acceptable** if a single-file backend is ever mandated: **PyInstaller** with `--onedir` (never `--onefile`), `--collect-all reportlab`, `--collect-all alembic`, migrations copied as data, and the same WinSW/`run_production.py` contract. Do this only if the 100–200 MB `python\` + `wheelhouse\` footprint is unacceptable. **`jpackage`/`dotnet publish` are not applicable** (no JVM/.NET backend).
6. **A third option — embed the backend inside the Flutter app** (start `python.exe` as a child of the client, no service) — is **not recommended**: it breaks multi-PC (each till would need its own database), loses the WinSW restart/supervision guarantees, and conflicts with the existing `run_production.py`/service design.

### 9.3 How should the backend start/stop automatically? Port conflicts?

**Already designed and implemented: a Windows service via WinSW.**

From `new_app/backend/winsw/SupermarketProBackend.xml`:

- `<executable>` = `<install>\backend\.venv\Scripts\python.exe`, `<arguments>` = `"…\backend\run_production.py"`, absolute `<workingdirectory>`.
- `<env DATA_DIR=C:\ProgramData\SupermarketPro>`, `APP_ENV=production`, `PYTHONDONTWRITEBYTECODE=1`.
- `<startmode>Automatic</startmode>` + `<delayedAutoStart>true</delayedAutoStart>` (lets PostgreSQL start first).
- Graceful stop: WinSW sends Ctrl+C, waits `30 sec`; `run_production.py::install_signal_handlers()` converts SIGINT/SIGBREAK into `KeyboardInterrupt` → exit code **0**, so a normal stop is not treated as a crash.
- Failure policy: restart after 10 s, then 30 s, then always; `resetfailure 1 hour`.
- Logs: `C:\ProgramData\SupermarketPro\logs` (rolled by size, 20 MB × 10) plus the app's own `backend.log` (`app/core/logging.py`, 5 MB × 10).
- Service account block present and documented (dedicated low-privilege account, never LocalSystem); `winsw/grant_data_dir_acl.ps1` grants `Modify` on the data root by locale-proof SID.

**Port conflict handling — current state:**

- Uvicorn bind failure raises `SystemExit`; `run_production.py` returns `EXIT_SERVE_FAILED (1)` → WinSW sees a failure and restarts per policy. The install-time health gate (`run_production.py --check`) only validates configuration, **not** port availability, and there is no retry-with-another-port logic.
- Discovery uses the same port number for UDP (`DISCOVERY_PORT`), so only one number must be free and open.
- **Recommended addition:** before `uvicorn.run`, probe `PORT` (and `DISCOVERY_PORT` if enabled) with a socket bind; on `EADDRINUSE`, log a specific, actionable event (`port_in_use`, with the PID owner if resolvable via `netstat`) and exit with a distinct code so WinSW's failure log and the installer's log point at the real cause instead of a generic traceback. Also consider adding a pre-install check in `setup.iss` that fails with a clear message if 8000/5432 are occupied.

### 9.4 Where should the database and user data live on the client machine?

**Already implemented and documented (`docs/R1_DATA_PATHS.md`, `app/core/config.py`, `installer/setup.iss`).**

| Data | Location (production) |
|---|---|
| Application (read-only) | `C:\Program Files\Supermarket Pro\` → `app\` (Flutter), `backend\` (code, `.venv`, `python\`, `wheelhouse\`, `migrations\`, `winsw\`), `vendor\` |
| Writable root `DATA_DIR` | `C:\ProgramData\SupermarketPro\` |
| Config | `…\config\.env` (installer-written), `secrets.env`, `database.env`, `pg_admin.env` (generated once), `supermarket_endpoint.json` |
| Licence/trial state | `…\license\` (`trial.state`, `license.state`, `hmac.key`, `install.keypair*`) |
| Server identity | `…\data\server_id` |
| Backups | `…\backups\*.sql`, `*.json`, `*.zip` |
| Logs | `…\logs\backend.log`, WinSW stdout/stderr |
| PostgreSQL data | `…\postgres\data` (installer `#define PgDataDir`) |
| Client-only prefs | `%APPDATA%\com.supermarket\supermarket_pos` (SharedPreferences) |
| Client secrets (JWT, device token) | Windows Credential Manager via `flutter_secure_storage` |

**Verified behaviour:** `DATA_DIR` is resolved to an absolute path; `ensure_data_dirs()` creates `config/ license/ data/ backups/ logs/` at startup and **aborts** with `DataDirectoryError` if it cannot; `legacy_data_locations()` warns (never moves) about pre-R1 data inside the install tree; every write path (`LICENSE_STATE_DIR`, `SERVER_ID_FILE`, `LOG_DIR`, `BACKUP_DIR`) derives from `DATA_DIR`; uninstall deletes `…\license` (new trial on reinstall) and **preserves** the DB/backups/`install_seq.txt`.

**What still needs a check:** the ACL script strips inherited ACEs and grants the service account; `run_production.py` re-grants `BUILTIN\Users:R` on `supermarket_endpoint.json` only. If the desktop app ever needs to read another file under `config\`, it will be denied by design — keep it that way.

### 9.5 Hard-coded paths / URLs / configs that break outside the dev machine

| # | Location | Value | Assessment |
|---|---|---|---|
| H1 | `new_app/backend/winsw/SupermarketProBackend.xml` | `C:\Program Files\Supermarket Pro\…`, `C:\ProgramData\SupermarketPro` | **Correct for production**, but the XML is a fixed-path template: any change to `DefaultDirName`/`DataDir` in `setup.iss` must be mirrored here (there is no substitution step in `setup.iss`, which copies the XML verbatim: `CopyFile(…\winsw\SupermarketProBackend.xml, …\SupermarketProBackend.xml)`). |
| H2 | `installer/setup.iss` | `AppIdGuid`, `InstallDir`, `DataDir`, `HttpPort 8000`, `PgPort 5432`, `PgInstallDir`, `PgDataDir`, pinned SHAs | Fine; production vs rehearsal compile-time split is clean and mutually exclusive. |
| H3 | `installer/build_installer.ps1` | `D:\R5Isolation\tools\innosetup-7\ISCC.exe` derived from mandatory `-IsolationRoot` | Requires a prepared isolation root; document it for the build machine. |
| H4 | `installer/rehearsal_harness.ps1` | Isolated root D: paths | Rehearsal only. |
| H5 | `lib/core/constants.dart:17` | `defaultServerBaseUrl = 'http://localhost:8000'` | Correct on the server PC; client PCs must pair. |
| H6 | `lib/features/devices/connection_provider.dart` | `_discoveryFactory(8000)`, `lanDiscoveryPortProvider = 8000` | Discovery port duplicated as a literal in three places; a non-default `DISCOVERY_PORT` would break client rediscovery. |
| H7 | `new_app/backend/.env` (dev) | `HOST=0.0.0.0`, `LAN_MODE=1` | Must not be copied into a customer install. |
| H8 | `command.txt`, `docs/PHASE_1_SETUP.md` | `C:\Users\MSI\Desktop\supermarket_logiciel\new_app` | Developer docs only. |
| H9 | `app/services/hardware.py` | PowerShell fallback path `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` | Valid on Windows 10/11; override available via `POWERSHELL_PATH`. |
| H10 | `lib/features/storage/local_storage_measure.dart:72` | `exportsDir: Directory.current.path` | Depends on the shortcut's working directory. |
| H11 | `installer/setup.iss` uninstall | `DelTree(DataRoot + '\license', …)` | Intentional (new trial), but it means "uninstall → reinstall" grants a fresh trial — an owner-side licensing consideration. |

### 9.6 Required runtimes / redistributables

| Requirement | Needed for | Handled? |
|---|---|---|
| **VC++ 2015–2022 x64 redistributable** | Flutter Windows app, CPython, psycopg2/cryptography/Pillow binaries | **Yes** — `vc_redist.x64.exe` SHA-256 pinned (`CC0FF0EB…`), run `/install /quiet /norestart`, exit codes 0/3010/1638 accepted (R6 contract 7) |
| **PostgreSQL 18.6** | Database | **Yes** — EDB installer `postgresql-18.6-5-windows-x64.exe` SHA-256 pinned (`227e2bc0…`), installed only under 4 gates, data dir under ProgramData |
| **CPython 3.13.17 (official zip)** | Backend runtime | **Yes** — pinned by SHA-256 in `requirements.lock.txt` header; staged into `backend\python\` |
| **.NET Framework** | WinSW v2 wrapper (if v2) | **UNKNOWN - needs confirmation** — the WinSW binary itself is not in the repo (staging expects it in the payload); WinSW v2 needs .NET Framework 4.6.1+ (built into Win10/11), WinSW v3 is self-contained. Confirm which version is staged. |
| **WebView2** | Nothing — no webview/embedded browser is used | Not required |
| **DirectX / ANGLE** | Flutter rendering | Bundled by Flutter (`flutter_windows.dll`, ANGLE in the release folder) |
| **Java / JRE** | Nothing (`jpackage` not used) | Not required |
| **Inno Setup 7** | Build machine only | Not shipped |

### 9.7 Printing, barcode, cash drawer, file access in a packaged build

| Capability | Implementation today | Works packaged? |
|---|---|---|
| **Receipt / A4 printing** | Backend renders PDF (reportlab, Arabic-shaped, `roll80`/`a4`), client calls `Printing.layoutPdf` → **native Windows print dialog** | **Yes** — `printing` is a bundled Windows plugin; requires the printer driver + spooler installed on the till. |
| **Thermal 80 mm** | `PdfPageFormat.roll80`; output depends on the driver's paper support | **Yes with caveats** — works with a proper "80 mm receipt" driver (e.g. generic ESC/POS text driver, XPrinter/Epson Windows drivers). A raw ESC/POS-only device without a Windows driver will not work. |
| **Direct ESC/POS / cash-drawer kick / customer display** | **Not implemented** — explicitly documented as unsupported in `lib/features/documentation/doc_content.dart` ("Direct ESC/POS printer control, cash-drawer kick, and customer display hardware are not integrated") | **No** — would need new work (§11 #2). |
| **Barcode scanner** | Keyboard-wedge capture (app gateway) + native **Win32 Raw Input** (`windows/runner/raw_scanner_input.cpp`), diagnostics panel, layout experiments | **Yes** — the native code is compiled into the release runner; no runtime dependency beyond the scanner being configured as a keyboard. |
| **File access (imports/exports)** | `file_picker` (CSV/XLSX import, images, backup upload), save dialogs for PDF/CSV/XLSX; exports default to the process working directory | **Yes** — but note the CWD dependency (H10) and that a Program Files install is read-only, so a save dialog must be used (it is). |
| **Hardware inventory screen** | PowerShell/CIM presence checks on the **server** | **Yes** — PowerShell exists on every supported Windows; non-Windows degrades honestly. |
| **Serial scale / COM device** | Presence check only (port is deliberately not opened) | **No** — no scale driver exists. |

### 9.8 Licensing / activation, auto-update, backup

| Concern | Status |
|---|---|
| **Trial** | Implemented: 10 calendar days from first backend start, state in `<DATA_DIR>\license\trial.state`, HMAC + optional DPAPI sealing, never in PostgreSQL, restart-proof. |
| **Lifetime activation** | Implemented: Ed25519-signed offline activation codes, hardware fingerprint computed server-side, verified on every read, `POST /license/activate`, rate limited, status surfaced to UI. |
| **Enforcement** | Router-level guard with modes `off | trial | on`; production template ships `on`; expired → 403 `trial_expired`; unknown → 503 `license_status_unavailable` (never fail open). |
| **Backup policy during trial** | Enforced (`app/licensing/backup_policy.py`): restore/upload blocked in trial, list/download allowed. |
| **Auto-update** | **MISSING.** No updater, no update endpoint, no version-manifest check, no signed update channel. Upgrades are installer-over-install (identity preserved via `install\install.txt`, pre-migration `pg_dump`). |
| **Backup** | Implemented, manual, with signed v2 manifests, ZIP portability, safety backup before restore. **No scheduler.** |
| **Uninstall** | Removes install tree + licence state; keeps DB, backups, `install_seq.txt` (M4/M5 contracts). |

### 9.9 Recommended installer tool

**Keep Inno Setup (already implemented in `installer/setup.iss`).**

Why it is the right fit for this product:

- **Per-machine, privileged install** (`PrivilegesRequired=admin`) with a Windows **service** registration, firewall rules, ACL changes, and a **PostgreSQL server install** — all scriptable in `[Code]` with `Exec` and explicit exit-code checks (exactly what `setup.iss` does: venv → offline pip → provisioning → health gate → VC++ → service → firewall → identity).
- **Custom pre/post steps with real error handling** (`RequireOk`, `RaiseException`, `StepLog` in `<DATA_DIR>\logs\install_steps.log`, `SetupLogging=yes`).
- **Upgrade-in-place semantics** with a stable `AppId` (`{{9E41A7C2-…}}`) and preserved data root — already exercised by `rehearsal_harness.ps1`.
- **Single self-extracting `.exe`** is the expected artefact for a POS client in this market (no Store, no admin portal).
- **MSIX** is a poor fit: packaged-service and per-machine PostgreSQL installs, driver prerequisites, custom ACLs and `Exec` of vendor installers are all restricted or awkward; MSIX also complicates the "installer runs as SYSTEM/admin" model and app-container filesystem assumptions.
- **NSIS** could technically do it, but it lacks Inno's built-in wizard/logging/`[Code]` ergonomics and would mean rewriting a rehearsed, tested script for no gain.

**Artefact names already defined:** `SupermarketPro-Setup.exe` (production), `SupermarketPro-Setup-REHEARSAL.exe` (rehearsal). **Missing for release:** Authenticode code signing of the `.exe` (and of `supermarket_pos.exe`), and a published checksum/manifest.

### 9.10 What still has to be verified before calling the installer "releasable"

1. `docs/R5_INSTALLER_DESIGN.md` records **"PASS WITH LIMITATIONS"** — read §10 of that document and close each limitation before shipping.
2. Rehearsal was run in an **isolated root on D:** with `PrivilegesRequired=lowest`; a production build path (`C:\Program Files` + `C:\ProgramData` + service account + UAC) must be rehearsed on a clean Windows VM.
3. No code-signing step exists anywhere in `installer/` (grep: no `signtool`).
4. `stage_payload.ps1` must be confirmed to exclude `.env`, `backups/`, `data/`, `tests/`, `tools/`, `__pycache__`, `*.pyc` — `customer_package.json` defines those exclusions for the *customer package*, but staging uses its own copy list; **UNKNOWN - needs confirmation** until the staged manifest (`staging-manifest.json`) is inspected.
5. `flutter build windows --release` is not automated (P2 below).

### 9.11 Concrete code changes required BEFORE packaging (ordered by priority)

| # | Priority | Change | Why / where |
|---|---|---|---|
| **P1** | **Blocker** | Remove/neutralise the real `.env` from anything that ships; confirm `.env` never entered git history; add `.env` to the staging exclusion test | `new_app/backend/.env` (real DB password). `customer_package.json` already forbids `.env`; staging must enforce it too. |
| **P2** | **Blocker** | Add a reproducible build script that runs `flutter build windows --release`, verifies `supermarket_pos.exe`, and feeds `stage_payload.ps1` | No Flutter release build is automated today; the payload is staged from whatever exists in `build\`. |
| **P3** | **Blocker** | Authenticode-sign `SupermarketPro-Setup.exe` and `supermarket_pos.exe`; add `signtool` step to `build_installer.ps1` | SmartScreen/UAC trust; unsigned per-machine installers are routinely blocked in the field. |
| **P4** | **High** | Confirm the WinSW binary/version is staged, and that the `serviceaccount` block is completed with a real account or explicitly `NetworkService` | `winsw/SupermarketProBackend.xml` has the block, but the wrapper binary is not in the repo and the account choice affects ACLs. |
| **P5** | **High** | Add a port-availability pre-flight (install time) and a typed bind-failure log at runtime | Avoid a service that silently restart-loops on a busy 8000/5432 (`run_production.py`, `setup.iss`). |
| **P6** | **High** | Replace fixed absolute paths in the WinSW XML with installer-substituted values (or generate the XML during install) | H1: `setup.iss` copies the XML verbatim; any path change silently breaks the service. |
| **P7** | **High** | Decide the production `LAN_MODE`/`HOST` policy and test both: single-PC (`127.0.0.1`, no firewall) and LAN (device guard + firewall rules) | Installer currently writes `LAN_MODE=0`/`HOST=127.0.0.1`; the dev `.env` says `0.0.0.0`/`LAN_MODE=1`. The two configurations must both be exercised. |
| **P8** | **Medium** | Make the discovery port configurable end-to-end (client reads it from `supermarket_endpoint.json` / pairing response) | H6: `8000` is hard-coded in `_sweepOffers`/`startDiscovery`. |
| **P9** | **Medium** | Make the client's working directory deterministic (shortcut `WorkingDir` is set to `{app}\app`; storage measurement should use a dedicated exports folder) | H10; cosmetic but produces confusing "documents" sizes. |
| **P10** | **Medium** | Add a first-run "printer test" flow and document the 80 mm driver requirement in the installer's `InfoBeforeFile` | Printing works, but a missing driver is the most likely field failure. |
| **P11** | **Medium** | Ensure `backups/`, `data/`, `*.log`, `flutter_*.log`, `tatus`, `new_app_upload/`, `new_app_upload.zip` are excluded from the shipped payload and from the repository's release artefact | Real data/secrets hygiene; `new_app/backend/backups/` contains customer dumps. |
| **P12** | **Low** | Replace `PrintService.printText` PowerShell path with a native/plugin path, or drop it | Not used by the primary flow; PowerShell dependency is avoidable. |
| **P13** | **Low** | Add an auto-update channel (or explicitly document "manual upgrade only") | §9.8. |
| **P14** | **Low** | Add scheduled backup (Windows Task Scheduler entry created by the installer, calling `POST /backups` or `pg_dump` directly) | §11 #4. |

---

## 10. Code Quality & Issues

### 10.1 General quality assessment

**Strengths**

- No `TODO` / `FIXME` / `HACK` / `XXX` markers anywhere in `backend/app` or `lib/` (verified by exhaustive grep).
- Module-level design records: nearly every file states its invariants, decisions and non-goals (e.g. `app/models/facturation.py`, `lib/core/barcode_scanner.dart`, `connection_provider.dart`).
- Strong typing end-to-end: mypy **strict** in `pyproject.toml`, `analysis_options.yaml` with `flutter_lints`, Pydantic v2 models for every endpoint.
- Transactions and idempotency treated as first-class (unique `client_request_id`, replay semantics documented per endpoint).
- Money as `NUMERIC(18,3)` / `Decimal`; no floats in the database.
- Extensive test suites (116 backend unit + 24 integration modules; ~180 Flutter test files incl. goldens).
- Production concerns already addressed (data dirs, secrets, logging, rate limits, licensing, health/readiness).

**Weaknesses**

- **Very high comment density** relative to code: several models/services are >50 % commentary. Excellent for auditability, but it makes reviews slower and the risk of comments drifting from code is real (a few already read as historical narratives).
- **No CI configuration** in the repository (`UNKNOWN - needs confirmation`).
- **Duplicated trees** (`new_app_upload/`) and stray artefacts (`tatus`, `flutter_*.log`, `FILE_HASHES.txt`) create drift risk and noise.
- **Client has no repository layer**: `*_providers.dart` call `dio` directly, so request/response shapes are duplicated between provider code and models.
- **Backend error localisation is partial**: the client maps a fixed set of codes (`licenseErrorLocalizationKeys`, plus feature-specific error mappers) and otherwise shows the backend's English message.

### 10.2 Issue register

| # | Severity | File:line | Issue | Suggested fix |
|---|---|---|---|---|
| Q1 | **Critical** (release hygiene) | `new_app/backend/.env` | Live development configuration with a plaintext DB password and JWT/APP secret sits in the working tree | Delete from any distribution; verify git history (`git log --all -- .env`); keep only `.env.example`; rotate the password if the repo was ever shared (it has a `new_app_upload.zip` in the tree, so verify what that archive contains). |
| Q2 | **High** | `new_app/backend/backups/*.sql|*.json` | Real `.sql` dumps of a working database (1.5 MB, Oct 2026) stored in the repo tree | Move out of the tree, add `backend/backups/` to `.gitignore`, assert exclusion in the staging manifest. |
| Q3 | **High** | `new_app_upload.zip` (93 MB), `new_app_upload/` | Unknown contents; risk of shipping `.env`, `.venv`, `build/`, real data | Inspect the archive; either regenerate it from the customer package rules or delete it. |
| Q4 | **High** | `new_app/backend/winsw/SupermarketProBackend.xml` | Absolute paths duplicated from `setup.iss` and copied verbatim by the installer | Generate/substitute at install time, or assert equality in a packaging test. |
| Q5 | **Medium** | `app/api/v1/auth.py:214` | JWT accepted as a **query parameter** for logout; uvicorn `access_log=True` writes the full path (including the token) to stdout/WinSW logs | Use the existing bearer-authenticated `/auth/logout`, or accept the token in a JSON body. |
| Q6 | **Medium** | `new_app/backend/.env` (`HOST=0.0.0.0`, `LAN_MODE=1`) | Development config exposes the API on every interface, with plaintext HTTP | Keep `127.0.0.1` + `LAN_MODE=0` as the shipped development default; require explicit opt-in for LAN testing. |
| Q7 | **Medium** | `app/core/rate_limit.py` (in-process limiter), `app/licensing/guard.py` (in-process cache) | Correctness depends on **one worker**; nothing in the app enforces it (only `run_production.py` sets `workers=1`) | Add a startup assertion (reject `WEB_CONCURRENCY>1`/detect multiple PIDs) and document it in `/system/info`. |
| Q8 | **Medium** | `app/api/v1/router.py` | `device_guard` runs **before** authentication on every route; a revoked device gets 403 before login — correct, but it means a mis-paired till cannot even reach `/auth/login` | Already documented; add a client-side recovery path that clears the link on `device_not_paired` (partially exists in `handleDeviceError`). |
| Q9 | **Medium** | `installer/setup.iss` (`CurUninstallStepChanged`) | Uninstall deletes `…\license`, granting a fresh trial on reinstall | Decide product policy; consider a persistent install marker outside `license\` if trials must not reset. |
| Q10 | **Medium** | `app/services/hardware.py` (`test_scanner`) | Script uses `Get-PnpDevice | Where-Object { $_.FriendlyName -eq '<name>' }` with quote-escaping but no CIM filter — a name containing a newline could alter the script | Use `Get-PnpDevice -FriendlyName` with a parameterised CIM filter, or reject control characters in the name. |
| Q11 | **Medium** | `lib/features/auth/auth_provider.dart::_checkSetupNeeded` | Swallows every exception and returns `false`; with the backend unreachable the user sees a login screen instead of "server unreachable" | Distinguish connection errors and surface the reconnect dialog / network error. |
| Q12 | **Low-Medium** | `lib/core/constants.dart:17` + `lib/features/devices/connection_provider.dart` (`_sweepOffers`, `startDiscovery`) | Discovery port `8000` hard-coded in several places while the backend allows `DISCOVERY_PORT` to differ | Read the port from the endpoint descriptor / pairing response. |
| Q13 | **Low** | `app/db/engine.py:get_db` and `app/db/session.py:get_db` | Two identical `get_db` implementations; routers import one, `dependencies.py` the other | Delete the duplicate in `engine.py` (or re-export) and keep a single source. |
| Q14 | **Low** | `app/db/engine.py::_EngineFactory.session_factory` | New `sessionmaker` created on every access (including every request through `session.py`) | Build the factory once per engine. |
| Q15 | **Low** | `app/models/sale.py`, `catalog.py`, `party.py`, … | Money columns declared `Mapped[float]` while the DB type is `Numeric(18,3)`; services use `Decimal` | Annotate as `Decimal` (or a `Money` type alias) so mypy catches float/Decimal mixing. |
| Q16 | **Low** | `lib/features/auth/auth_provider.dart` (`login`) | `device_name` hard-coded to `'Desktop POS'` for every till | Send a real Windows machine name (or the pairing display name) so audit/session rows are distinguishable. |
| Q17 | **Low** | `lib/core/constants.dart:3` (`appVersion = '1.0.0'`) vs `pubspec.yaml` (`1.0.0+1`) | Version duplicated and manually maintained; sent to the server at pairing (`client_version`) | Read from `package_info_plus` or generate at build time. |
| Q18 | **Low** | `lib/features/storage/local_storage_measure.dart:72` | `exportsDir = Directory.current` makes the "documents" figure depend on how the app was launched | Point at a dedicated exports folder under `%USERPROFILE%\Documents\Supermarket Pro` (and set it in the save dialogs). |
| Q19 | **Low** | `lib/features/pos/print_service.dart::printText` | Shells out to PowerShell `Out-Printer` (temp file → spooler) | Remove if unused, or reimplement through the `printing` plugin/native API. |
| Q20 | **Low** | `windows/flutter/generated_plugins.cmake` (`jni` in FFI list) | Unused-looking native plugin increases binary size/attack surface | Confirm origin via `flutter pub deps`; remove the dependency if transitive-only. |
| Q21 | **Low** | `new_app/flutter_*.log`, `new_app/flutter-crash.log`, root `tatus` | Build/crash artefacts and a stray `git diff --stat` dump committed/left in the tree | Delete and ignore (`*.log`, `tatus`). |
| Q22 | **Low** | `new_app_upload/` (whole tree) | Duplicate of `new_app/` that will silently drift from the real code | Remove or replace with a generated release artefact. |
| Q23 | **Low** | `app/api/v1/dashboard.py`, `app/api/v1/reports.py` | Permission dependencies were **not re-verified** in this audit (the router is included with router-level guards only) | Verify each endpoint declares `report_financial`; add a test asserting 403 for a cashier on financial reports. |
| Q24 | **Low** | `backend/scripts/_smoke_35.py`, `_smoke_37.py`, `_smoke_increase_validation.py`, `check_migration.py`, `create_test_db.py`, `inspect_schema.py` | Ad-hoc developer scripts at the backend root with underscores | Move under `scripts/` or delete; they are excluded from the package but clutter the tree. |
| Q25 | **Low** | `docs/PHASE_1_SETUP.md` | Says "SQLite used in development/testing" and `sqlite:///./app.db`, but the live `.env` uses PostgreSQL and no `.db` file exists | Update the doc to the current reality to avoid a wrong setup path. |
| Q26 | **Low** | `app/services/hardware.py::_run_powershell` | `-ExecutionPolicy Bypass` on every call | Use `-ExecutionPolicy RemoteSigned` or `-NoProfile` only; `Bypass` is unnecessary for `-Command` and weakens policy signalling. |

### 10.3 Performance observations

| Area | Observation |
|---|---|
| Reports | Dedicated aggregates in `app/repositories/report.py` (1,767 lines) with date-window indexes (migration 0020) and benchmarks (`scripts/benchmark_reports_phase14.py`, `docs/phase14_benchmark_results.json`). No N+1 patterns found in the reviewed query paths; `lazy="noload"`/`selectin` are chosen deliberately on `Product`, `Category`, `Customer`. |
| Catalog lists | Explicitly avoid loading variants/selling units per product (`noload`), with dedicated endpoints. |
| POS cart | Client-side cart with `MAX_SALE_LINES = 10_000`; backend validates the whole cart in one transaction; large-cart tests exist (`test/unit/pos_cart_large_test.dart`, `scripts/benchmark_large_sale.py`). |
| Search | `pg_trgm` GIN indexes on `products.name`/`barcode` (0023). |
| Session heartbeat | Throttled to 60 s (`api/dependencies.py`), avoiding a write per GET. |
| Engine/session | Pool 5 + overflow 10, `pool_pre_ping`, `pool_recycle=3600` for PostgreSQL (`app/db/engine.py`). Reasonable for a shop LAN. |
| Flutter | Uses `compute` isolates for storage walks; `LogInterceptor` retained but its printer is a no-op (`logPrint: (obj) {}`). |
| Concern | `_EngineFactory.session_factory` rebuilds the sessionmaker per request (Q14) — negligible but unnecessary. |

### 10.4 Missing tests / coverage gaps (observed, not measured)

- No test was found that asserts **port-conflict** behaviour or the WinSW restart contract.
- Packaging is validated by `rehearsal_harness.ps1` (PowerShell), not by pytest.
- No frontend test targets the **installer-installed** path (`%APPDATA%` cache dir) or a packaged build.
- `backend/tests/integration/` covers concurrency (e.g. `test_variants_units_concurrency.py`) but **no live-PostgreSQL CI** is configured in the repo.
- Overall coverage percentages: **UNKNOWN - needs confirmation** (no `coverage.xml`/`htmlcov` present; `pytest-cov` is configured only as a dependency).

---

## 11. Missing Features / Recommendations (ranked)

| Rank | Gap | Why it matters for a real POS client | Where it would go |
|---|---|---|---|
| 1 | **Shift / cash-drawer session** (open float, X-report, Z-report, cash count, over/short, per-cashier shift close) | The single most expected retail control; today money-out is only `expenses` with a `paid_from_drawer` flag, and there is no shift, no drawer reconciliation and no cashier close-out | New `shifts` + `shift_counts` tables, `app/services/shift.py`, `/api/v1/shifts*`, a POS "Close shift" screen and a Z-report PDF |
| 2 | **ESC/POS direct printing + cash-drawer kick + customer display** | Many Algerian shops use driverless 80 mm printers and want the drawer to open on cash sales; the app currently needs a Windows driver and cannot open a drawer | Native ESC/POS encoder in the backend (`app/printing/escpos.py`) + a raw spooler path (Win32 `WritePrinter` via the runner, or a small helper service) |
| 3 | **Automatic update mechanism** | Field upgrades otherwise require an on-site visit; the installer supports upgrade-in-place, but nothing triggers it | Signed update manifest + `/api/v1/system/update-check` + installer download/run, or a Windows service updater |
| 4 | **Scheduled backups** | Manual backups are forgotten; data loss risk in a single-PC shop | Installer-created Task Scheduler job calling `POST /backups` (or `pg_dump`), retention policy, UI to configure it |
| 5 | **Offline resilience / queue for client PCs** | A Wi-Fi blip stops sales ("Sales are never stored offline") | Documented design choice; if the owner wants it, a local outbox with idempotent replay (`client_request_id` already exists, which makes this feasible) |
| 6 | **VAT applied to sale/invoice totals** | `products.vat_rate` (0/9/19) is stored but **never affects totals**; Algerian invoices normally require HT/TVA/TTC | Extend `SaleService`/receipt rendering or rely on the Facturation module for fiscal documents; decide and document the policy |
| 7 | **Custom roles / permission editor** | Owner may want "senior cashier" roles; today only the three seeded roles exist | `settings` UI + `/roles` CRUD (tables already support it) |
| 8 | **Supplier returns / purchase returns** | Damaged or wrong supplier deliveries cannot be sent back with stock/payable effects | `purchase_returns` document + ledger/movement reversal, mirroring `returns.py` |
| 9 | **Formal stock take / cycle count documents** | Adjustments exist, but no count sheet, variance report or approval trail | `stock_counts` header/lines + variance posting via existing adjustment service |
| 10 | **Price change history view** | Audit log records before/after, but there is no "price history per product" screen for margin analysis | Derived from `audit_logs` (`entity_type='product'`) with a dedicated view |
| 11 | **Multi-store / warehouse transfers** | Chain shops cannot move stock between sites; `product_transfer` is CSV import/export, not inter-store transfers | New transfer documents, or defer explicitly |
| 12 | **Customer statement printing / account PDF** | Debt ledger is viewable, but a printable statement is expected for credit customers | `POST /print` document type `customer_statement` |
| 13 | **Gift cards / vouchers / layaway** | Common supermarket features; completely absent | New tender types + liability ledger |
| 14 | **E-invoicing / fiscal QR / timbre automation** | `show_timbre` is a display flag; no fiscal stamp calculation beyond facturation domain totals | Extend `app/domain/facturation.py` with the owner's fiscal rules; needs regulatory confirmation |
| 15 | **Scale / weight integration** | Weighted items require manual entry; COM ports are only presence-checked | Serial scale driver (protocol per device), plus a settings mapping |
| 16 | **Legacy data migration tooling** | `python_app/` (Tkinter, MySQL per its requirements) data cannot be imported; only CSV/XLSX product import exists | One-off migration script (SQLite/MySQL → PostgreSQL) with dry-run and reconciliation |
| 17 | **Per-cashier performance reporting** | Reports are financial/product-oriented; cashier-level metrics depend on `sales.user_id` but no report exposes them | Add to `app/api/v1/reports.py` |
| 18 | **Automated DB maintenance** | Long-running shop DBs need `VACUUM`/`ANALYZE`/bloat checks | Scheduled maintenance task or documented operator procedure |

---

## 12. Final Checklist

| Area | Status | Notes |
|---|---|---|
| **Core POS checkout** | **Ready** | Atomic, idempotent, permission-gated, well tested (`sale.py` 2,040 lines; POS UI 6,500 lines) |
| **Catalog / products / variants / units / packs** | **Ready** | Complete CRUD + packaging state + bulk import/export |
| **Inventory & costing** | **Ready** (no stock-take docs) | Immutable movement journal, PMP maintained on receive |
| **Purchases & supplier payables** | **Ready** | draft→received→cancelled with full reversal |
| **Returns / voids** | **Ready** | Pro-rata refunds, stock restore, one-way void, audit |
| **Customers / debt / loyalty** | **Ready** | Ledgers + cached balances + CHECK constraints |
| **Facturation (fiscal docs)** | **Ready** | Separate numbering domain, posting to POS, A4 PDF |
| **Reports / dashboard / exports** | **Ready** | 11 report endpoints + XLSX/CSV/PDF, indexed & benchmarked |
| **Users / roles / permissions** | **Needs work** (roles fixed) | 30 scopes seeded; no custom-role UI |
| **Audit trail** | **Ready** | Append-only, filtered UI, survives deletions |
| **Licensing (trial + lifetime)** | **Ready** | Ed25519, fail-closed, file state outside DB |
| **Backup / restore** | **Ready** (manual only) | Signed manifests, ZIP portability, safety backup; no scheduler |
| **LAN / multi-PC** | **Ready** (single server) | Pairing, device guard, heartbeat, rediscovery |
| **Security — auth/crypto** | **Ready** | Argon2id, hashed tokens, revocation, lockout, rate limits |
| **Security — transport** | **Needs work** | No TLS on the LAN; plaintext JWTs/device tokens (accepted risk, document it) |
| **Security — secrets hygiene** | **Needs work** | Real `.env`, dev DB dumps and a 93 MB unknown zip in the tree |
| **Database schema/migrations** | **Ready** | 37 migrations, constraints, indexes, idempotent provisioning |
| **Windows desktop build** | **Ready** | `windows/` present, custom runner, all plugins Windows-capable |
| **Backend bundling** | **Ready (designed + rehearsed)** | Embedded CPython + venv + offline wheelhouse + WinSW |
| **Installer** | **Needs work** | Inno Setup implemented; rehearsal = "PASS WITH LIMITATIONS"; **not code-signed**; no automated Flutter build step |
| **Printing (PDF / 80 mm / A4)** | **Ready** (driver-dependent) | Windows print dialog; no ESC/POS |
| **Cash drawer / customer display** | **Missing** | Explicitly unsupported in-app |
| **Barcode scanning** | **Ready** | Wedge + native Raw Input + diagnostics |
| **Auto-update** | **Missing** | Manual upgrade only |
| **Offline operation** | **Missing** (by design) | Server must be reachable |
| **Shift / cash reconciliation** | **Missing** | No shift model |
| **Testing** | **Ready (broad), Needs work (packaging/CI)** | 116 + 24 backend modules, ~180 Flutter files; no CI config; packaging covered only by PowerShell rehearsal |
| **Documentation** | **Ready** | 53 design docs + 13 in-app chapters (AR/FR/EN) |

---

## 13. Files Read Log

### 13.1 Read in full (line by line)

**Root / configuration**
- `README.md`, `command.txt`, `.gitignore`
- `new_app/pubspec.yaml`, `new_app/README.md`, `new_app/analysis_options.yaml`
- `new_app/backend/pyproject.toml`, `requirements.lock.txt`, `alembic.ini`, `pytest.ini`, `customer_package.json`, `.env.example`, `production.env.example`

**Backend — entry points, core, DB**
- `app/main.py`, `app/core/config.py`, `app/core/constants.py`, `app/core/security.py`, `app/core/seed.py`, `app/core/rbac_bootstrap.py`
- `app/db/base.py`, `app/db/engine.py`, `app/db/session.py`, `app/db/dependencies.py`
- `app/api/dependencies.py`, `app/api/v1/router.py`
- `run_production.py`

**Backend — models (all 19 modules)**
- `app/models/enums.py`, `user.py`, `catalog.py`, `sale.py`, `inventory.py`, `pos.py`, `party.py`, `purchase.py`, `facturation.py`, `return_doc.py`, `debt.py`, `expense.py`, `loyalty.py`, `promotion.py`, `settings.py`, `supplier_ledger.py`, `audit.py`, `device.py`, `zakat.py`

**Backend — API**
- `app/api/v1/auth.py`, `app/api/v1/pos.py` (full), plus decorator/path/signature extraction for **all 32** router modules (`audit, auth, backups, categories, customers, dashboard, debts, devices, expenses, exports, factures, hardware, health, inventory, invoice_clients, license, loyalty, packs, pos, print, product_transfer, products, promotions, purchases, reports, returns, settings, storage, suppliers, system, users, zakat`)

**Backend — services / licensing / printing / discovery**
- `app/services/hardware.py`, `app/services/backup.py` (module docstring + structure), `app/licensing/license_manager.py` (module docstring + structure)
- `app/printing/templates/__init__.py` listing, `app/printing/` and `app/services/` inventories

**Migrations**
- `migrations/versions/0001_initial.py`, head of `2026_09_22_1128_73355bdf31d4_0002_phase2_domain_models.py`, full version list + head/down_revision of `0037`

**Installer**
- `installer/setup.iss` (full), `installer/build_installer.ps1` (full), `installer/installer_provision.py` (full)
- `new_app/backend/winsw/SupermarketProBackend.xml` (partial — through `<log>`, the `<serviceaccount>` block was cut by the terminal `head -80`; the file's structure and intent are documented in its own comments and `winsw/README.md`)

**Frontend**
- `lib/main.dart`, `lib/router/app_router.dart`, `lib/network/api_client.dart`, `lib/core/constants.dart`
- `lib/features/auth/auth_provider.dart`, `lib/features/auth/credential_storage.dart`
- `lib/features/pos/print_service.dart`, `lib/features/pos/print_document.dart`
- `lib/features/devices/connection_provider.dart`, `lib/features/devices/device_identity.dart` (first 80 lines)
- `lib/core/barcode_scanner.dart` (first ~700 lines of 1,575 — file header, gateway API and capture rules; the rest is the capture state machine)
- `lib/features/storage/local_storage_measure.dart`

**Windows runner**
- `windows/CMakeLists.txt` and `windows/runner/CMakeLists.txt` (key lines), `windows/flutter/generated_plugins.cmake`

**Docs**
- `docs/R1_DATA_PATHS.md` (full), `docs/PHASE_1_SETUP.md` (full)
- `docs/R5_INSTALLER_DESIGN.md` (section headings + status line only)

**Legacy**
- `python_app/main.py`, `python_app/requirements.txt`

### 13.2 Inspected structurally (signatures, decorators, table/route inventories, headers) — not read line by line

- All 31 modules of `backend/app/services/` (largest: `sale.py` 2,040, `catalog.py` 1,680, `returns.py` 1,598, `facturation.py` 1,598, `product_transfer.py` 1,548, `inventory.py` 1,432, `report.py` 987, `loyalty.py` 999, `purchases.py` 901, `zakat.py` 888, `backup.py` 846, `print.py` 703, `pack.py` 696, `promotions.py` 572) — endpoint behaviour, invariants and file sizes established from routers, models and module docstrings.
- All 20 modules of `backend/app/repositories/`, `app/schemas/` (26+ modules), `app/domain/` (9 modules), `app/printing/` (12 modules), `app/exporting/` (3), `app/licensing/` (14), `app/discovery/` (3), `app/core/` remaining (exceptions, middleware, logging, rate_limit, secrets, postgres_discovery, postgres_provisioning, db_dump, filenames, server_identity), `app/api/device_guard.py`, `app/api/v1/license.py`.
- Backend `tests/` (140 modules): counted and categorised by filename; test bodies were not read.
- Frontend `lib/`: 220 Dart files — `core/strings.dart` (5,282 lines) only via targeted excerpts; `features/documentation/doc_content.dart` (3,602) via the printing/LAN chapters; `features/pos/pos_screen.dart` (6,500), `pos_providers.dart` (1,361), `reports/report_models.dart`, `products/products_screen.dart` (2,137), `settings/settings_screen.dart` (1,513), `stock/stock_screen.dart` (1,860), `zakat/zakat_screen.dart` (1,554), `documentation/doc_registry.dart` (1,480), `report_tabs.dart` (1,597) — located and read only the sections needed (checkout payload, printing, storage, permissions, licence gates).
- Frontend `test/` (~180 files): counted by filename; bodies not read.
- `installer/stage_payload.ps1` (18 KB): grepped for payload contents, pins and staging rules; not read line by line.
- `installer/rehearsal_harness.ps1` (35 KB): not read (referenced only).
- `installer/THIRD_PARTY_NOTICES.md`: not read.
- `new_app/backend/winsw/grant_data_dir_acl.ps1`, `winsw/README.md`: not read (behaviour summarised from XML comments and `run_production.py`).
- `docs/` — 53 files, ~1.3 MB total: read `R1`, `PHASE_1_SETUP`; section headings of `R5`; **not read**: `PHASE_0_*` (20 files), `PHASE_2` … `PHASE_17` implementation/analysis docs (24 files), `LICENSING_SYSTEM_ARCHITECTURE_AUDIT(_v2).md` (68/71 KB), `FACTURATION_QA_REPORT.md`, `R2`/`R3`/`R4`, `POST_PHASE_17_MANUAL_QA.md`, `LICENSE_GENERATOR_OPERATIONS.md`, `PHASE4_DOCUMENTATION_CHAPTERS_REPORT.md`, `phase14_benchmark_results.json`.
- `facture-docs/` (7 files): not read (they are reports about the facturation sub-project; the code itself was audited).
- `reference/` (7 Phase-0 documents): not read.
- `python_app/` (legacy Tkinter app): only `main.py` and `requirements.txt` read; `gui/main_window.py`, `modules/*`, `database/db_manager.py`, `server/server.py`, `security/license.py`, `utils/network_discovery.py` were **not** read in depth (out of scope: not part of the shipping product).
- `new_app_upload/` (1,005 files): **not read** — treated as a duplicate snapshot on the evidence of identical `pubspec.yaml`/`pubspec.lock`/`README.md`/`analysis_options.yaml`; its contents were not diffed file-by-file.
- `MANIFEST.md`, `FLUTTER_DEPENDENCY_MAP.md`, `PYTHON_DEPENDENCY_MAP.md`, `PARITY_COMPARISON_GUIDE.md`, `FILE_HASHES.txt`, `FLUTTER_FILE_LIST.txt`, `PYTHON_FILE_LIST.txt`, `tatus`: not read in full (`README.md`, which they index, was read).
- `new_app/backend/scripts/*`, `backend/tools/license_generator/*`, `backend/_smoke_*.py`, `check_migration.py`, `create_test_db.py`, `inspect_schema.py`, `backend/docs/*`: inventoried and sized; bodies not read.
- Third-party code under `new_app/backend/.venv/` (4,074 `*.py`), `new_app/build/`, `new_app/.dart_tool/`, `__pycache__/`, `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/`: **deliberately not read** (dependencies/build output).

### 13.3 Files that could NOT be read, and why

| File / group | Reason |
|---|---|
| `new_app_upload.zip` (93 MB) | Binary archive; not opened. Contents **UNKNOWN - needs confirmation** |
| `new_app/backend/backups/*.sql` / `*.dump` (~5 MB) | Binary/large data dumps; not read (only listed). Presence is itself a finding (Q2) |
| `*.png` goldens and `test/widget/failures/*` | Binary images; not inspected visually |
| `*.pyd`, `*.pyc`, `*.dll`, `*.exe`, `*.ttf`, `*.pfb` | Binaries |
| `new_app/backend/data/server_id` | Runtime state, not source (its existence was listed) |
| `new_app/backend/.env` | Read **keys and non-secret values only**; secret values intentionally not reproduced, per the audit rules. The DB password exists in plaintext there (Q1) |
| `new_app/backend/logs/backend.log` (13 KB) | Runtime log; not analysed (could contain operational data) |
| `new_app/flutter-crash.log`, `flutter_0{1,2,3}.log` | Crash logs; listed only |
| `winsw/SupermarketProBackend.xml` `<serviceaccount>` block | Truncated by the terminal read window (`head -80`); the surrounding comments describe the intent |

---

## Closing note for the next reader (e.g. an AI writing a packaging plan)

1. **The packaging architecture already exists and is coherent**: Inno Setup → stage payload (embedded CPython + wheelhouse + PostgreSQL EDB + VC++ redist) → venv → offline pip → provisioning (`alembic upgrade head` + RBAC) → health gate → WinSW service → ACLs → firewall. Do not redesign it; verify and complete it (§9.10).
2. **The three real release blockers** are: secrets/data hygiene in the tree (`.env`, `backend/backups/`, the 93 MB zip), no automated `flutter build windows --release` step feeding the staging script, and no code signing.
3. **The one architectural risk** is the absence of TLS on the LAN API combined with device tokens/JWTs in cleartext — a deliberate, documented trade-off that should be re-evaluated if tills use Wi-Fi.
4. **The most valuable functional additions** are a shift/cash-drawer model and direct ESC/POS + drawer-kick printing; both are prerequisites for a typical Algerian supermarket counter.
5. **Data lives in `C:\ProgramData\SupermarketPro` (writable) and code in `C:\Program Files\Supermarket Pro` (read-only)** — every packaging decision must preserve that split; `docs/R1_DATA_PATHS.md` is the authoritative reference.
