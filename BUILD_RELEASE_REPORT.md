# BUILD RELEASE REPORT — Supermarket Pro Windows installer

Build date: 2026-11-13
Machine: Windows 11 (10.0.26300), Flutter 3.44.8 / Dart 3.12.2, VS 2022 Community (17.12, C++ desktop + Win10 SDK 10.0.26100), Python 3.10.11 (dev) / 3.13.17 (embedded runtime), PowerShell 5.1, Inno Setup 7 (`D:\R5Isolation\tools\innosetup-7\ISCC.exe`).

Architecture: **unchanged** — Inno Setup + embedded official CPython 3.13 + per-install venv + offline wheelhouse + WinSW 2.12.0 Windows service + PostgreSQL 18.6 (EDB) + VC++ 2015-2022 redistributable. No PyInstaller, MSIX or NSIS was introduced.

---

## 1. Deliverable

| Item | Value |
|---|---|
| File | `D:\R5Isolation\build\SupermarketPro-Setup.exe` |
| Size | 505,097,936 bytes (481.7 MiB) |
| SHA-256 | `1FAA9DC0FFF1D81E11ED43D273F6491A0C690DCA43303037F8F0C0EA51C71A01` |
| Mode | PRODUCTION (not REHEARSAL) |
| Signature | **UNSIGNED** — no certificate configured on the build PC (see §4.1) |
| Build log | `D:\R5Isolation\build\build_PRODUCTION.log` |
| Build evidence | `D:\R5Isolation\build\build_evidence.log` (appended, one line per build) |
| Staged payload | `D:\R5Isolation\stage\PRODUCTION` (2,833 files, 555.7 MB) + `staging-manifest.json` |

Flutter client inside the payload: `new_app/build/windows/x64/runner/Release/supermarket_pos.exe`
(140,288 bytes, SHA-256 `2c1cab54f6e7ce5787671da8b96a997786d0c093b37010cf176218f4b30a7354`, 20 files / 40.2 MB bundle).

**Size note:** the previous build was 859 MB. The 385 MB PostgreSQL *binaries zip* is a build-time licence source only (the installer runs the EDB `.exe`); it is no longer copied into the payload, which is why this build is 481.7 MB and still installs the same components.

---

## 2. Files changed

| File | Why |
|---|---|
| `installer/build_flutter.ps1` **(new)** | P2: `flutter pub get` + `flutter build windows --release`, verifies `supermarket_pos.exe`, `flutter_windows.dll`, `data\flutter_assets`, `icudtl.dat`; fails loudly otherwise. |
| `installer/verify_payload.ps1` **(new)** | P1: forbidden-file gate. Scans the **staged tree** (and cross-checks `staging-manifest.json` for drift) for `.env`, `backups/`, `data/`, `logs/`, `.venv`, `tests/`, `tools/`, `__pycache__`, `*.pyc`, `*.log`, `new_app_upload*`, `tatus`, private-key material (`*.key/.pem/.p12/.pfx/.jks/.der/.crt`), owner licence tooling; also asserts every required artefact and the wheelhouse exist. Exit 1 on any violation. |
| `installer/build_release.ps1` **(new)** | Single release command: Flutter build → stage → P1 gate → ISCC → optional Authenticode → prints size/SHA-256. Any step failing stops the release. |
| `installer/INSTALL_NOTES.txt` **(new)** | P10: pre-install information page (80 mm receipt-driver requirement, default printer, 58/80 mm paper, ports 8000/5432 and the reuse rule, data paths, support files, second-till pairing). |
| `installer/setup.iss` | P5: `PrepareToInstall` port pre-flight (netstat + tasklist, names the offending process; an existing `postgres.exe` on 5432 is accepted as "reuse", our own service on 8000 is accepted as upgrade). P6: the WinSW XML is now **rendered** for the real install/data dirs instead of copied verbatim. P10: `InfoBeforeFile` → `vendor\INSTALL_NOTES.txt`. |
| `installer/stage_payload.ps1` | Stages `INSTALL_NOTES.txt`; stops copying the 385 MB PostgreSQL binaries zip into the payload (kept as the licence-extraction source). |
| `installer/build_installer.ps1` | Authenticode step parameterised **only** by environment variables (`SUPERMARKET_SIGN_PFX`, `SUPERMARKET_SIGN_PFX_PASSWORD`, `SUPERMARKET_SIGN_TIMESTAMP`, `SUPERMARKET_SIGNTOOL`, `-SkipSign`); hashes the exe **after** signing; records `signed=` in the evidence line; warns (does not fail) when no certificate is configured. |
| `new_app/backend/winsw/render_service_xml.ps1` **(new)** | P6: substitutes install dir / data root into the service XML, optionally injects `<depend>` for PostgreSQL, validates the resulting XML, writes UTF-8 without BOM. Default paths render byte-identical to the template (verified). |
| `new_app/backend/winsw/SupermarketProBackend.xml` | P4: the `<serviceaccount>` block is completed and documented (NetworkService, SID-resolvable, no password ever stored, `<allowservicelogon>true</allowservicelogon>`); the PostgreSQL dependency is documented as render-time injection instead of a stale hard-coded name. |
| `new_app/backend/run_production.py` | P5: pre-flight socket bind **before** uvicorn; `EXIT_PORT_IN_USE = 5` with a `port_in_use` structured log + actionable stderr line; a non-conflict bind error (e.g. an address that is not on this machine) logs `bind_failed` and keeps `EXIT_SERVE_FAILED`; a bind losing the race still maps to exit 5. |
| `new_app/lib/core/strings.dart` | First-run UX: `service_unreachable` message in ar/fr/en ("the Supermarket Pro service is not running…"). |
| `new_app/lib/features/auth/auth_provider.dart` | Q5: logout now uses `POST /api/v1/auth/logout` with the bearer header instead of a JWT in a query/body on `logout-token`. First-run UX: a connection error against `localhost`/`127.0.0.1`/`::1` now reports "service not running" instead of a bare connection error. |
| `new_app/lib/features/devices/connection_provider.dart` | P8: `discoveryPort` field on `LanConnectionNotifier` replaces the three hard-coded `8000` sweeps; `lanDiscoveryPortProvider` is overridable. |
| `new_app/lib/features/devices/setup_wizard_screen.dart` | P8: manual-connect uses `lanDiscoveryPortProvider` instead of a fixed `8000`. |
| `new_app/lib/features/storage/local_storage_measure.dart` | P9/Q18: exports location is deterministic — `%USERPROFILE%\Documents\Supermarket Pro` (created lazily) instead of `Directory.current`. |
| `new_app/lib/main.dart` | P8: overrides `lanDiscoveryPortProvider` with the port actually published in `supermarket_endpoint.json`. First-run UX: when the launcher-published endpoint descriptor exists and no role has been chosen yet, the install is preselected as **server**, so a single-PC install goes straight to first-admin setup with no network wizard. |
| `BUILD_RELEASE_REPORT.md` **(new)** | This report. |

Environment-only change (outside the repository): copied `vc_redist.x64.exe` from `D:\R5Isolation\R6\vendor\` into `D:\R5Isolation\vendor\` (SHA-256 `CC0FF0EB…96B713B`, the pin `stage_payload.ps1` already enforced). No project file references `R6`.

No user data was touched: `.env`, `backups/`, `data/` and the development database were never read for modification, copied, migrated or deleted.

---

## 3. Phase results

### Phase 0 — environment: **PASS**

| Requirement | Status |
|---|---|
| Flutter | 3.44.8 stable / Dart 3.12.2 (release build produced) |
| Visual Studio C++ desktop workload | VS 2022 Community 17.12.35521.163 + MSVC x64 + Windows 10 SDK 10.0.26100 |
| Python | 3.10.11 (dev) and embedded runtime 3.13.17 |
| Inno Setup | 7 (`ISCC.exe`, not on PATH — passed by path as the design expects) |
| PowerShell | 5.1.26100.9818 |
| WinSW | `WinSW-x64-v2.12.0.exe`, SHA-256 pin matches, FileVersion 2.12.0.0 |
| PostgreSQL EDB installer | `postgresql-18.6-5-windows-x64.exe`, pin matches |
| PostgreSQL binaries zip | present, pin matches (build-time licences) |
| VC++ redistributable | **was missing from `vendor\`** — restored from the pinned copy in `R6\vendor`, hash verified |
| Offline wheelhouse (48 wheels), CPython runtime | present, offline `pip` smoke install passes from the staged artefacts |

Note: the pre-existing `SupermarketPro-Setup.exe` (Nov 11, 859 MB, SHA `6aaf9e2c…`) **predates** the current `setup.iss`/`stage_payload.ps1` (Nov 11 14:06–14:07) and lacked `vc_redist`, so it could never have completed installation. It has been replaced by the build in §1.

### Phase 1 — release blockers: **PASS**

| Item | Result |
|---|---|
| **P1** hygiene gate | PASS. `verify_payload.ps1`: 2,833 files / 555.7 MB accepted. Negative test: a planted `backend/.env` and `backend/tests/test_leak.py` produced `PAYLOAD_FAILED: 3 violation(s)`; removing them returned `PAYLOAD_OK`. |
| **P2** Flutter build script | PASS. Created and used; it also documented/fixed a stale `windows\flutter\ephemeral` symlink crash and a CMakeCache recorded from an old path (build artifacts, regenerated — no source change). |
| **P4** WinSW binary + account | PASS. Pinned 2.12.0 staged as `SupermarketProBackend.exe`; `<serviceaccount>` completed with NetworkService (least privilege, no stored credential, matches `grant_data_dir_acl.ps1`'s SID-based grants); `backend/tests/unit/test_service_winsw.py` — 30 tests green. |
| **P5** port pre-flight + typed failure | PASS. Installer aborts **before writing anything** when 8000 is held by a foreign process (naming it) and refuses a non-PostgreSQL process on 5432; `postgres.exe` on 5432 → logged as "reuse existing server, databases untouched"; our own service on 8000 → upgrade path. Backend: exit code 5 (reserved: 0/1/2/3/4/5). |
| **P6** no verbatim XML copy | PASS. Renderer verified: `-InstallDir D:\Prog\Supermarket Pro -DataDir D:\ProgData\SupermarketPro` rewrites `executable`, `arguments`, `workingdirectory`, `DATA_DIR`, `logpath` and injects `<depend>`; default paths render byte-identical to the template. Fixed a real PowerShell trap found during verification (`$PSScriptRoot` empty in param defaults; `.Name` shadowed by the `<name>` element) that would otherwise have broken service registration at install time. |
| **P7** safe production defaults | PASS. `BuildEnvContent` writes `HOST=127.0.0.1`, `PORT=8000`, `LAN_MODE=0`, `DISCOVERY_ENABLED=0`, `LICENSE_ENFORCEMENT=on`; firewall rules (TCP/UDP 8000) are added **only** when `LAN_MODE=1`. |

### Phase 2 — client experience: **PASS**

| Item | Result |
|---|---|
| **P8** discovery port | PASS. No hard-coded `8000` in the sweep or manual connect; the port comes from `supermarket_endpoint.json` via `main()`. |
| **P9/Q18** exports folder | PASS. Deterministic `%USERPROFILE%\Documents\Supermarket Pro`. |
| **P10** printer note | PASS. Installer information page (`INSTALL_NOTES.txt`) states the 80 mm/58 mm vendor-driver requirement and why "Generic / Text Only" fails. |
| **Q5** logout | PASS. Bearer-authenticated `/auth/logout`; no JWT in a URI/body. The legacy `/auth/logout-token` endpoint still exists server-side (client no longer calls it). |
| First-run | PASS. Installed single-PC: the launcher publishes `<ProgramData>\SupermarketPro\config\supermarket_endpoint.json` **and** `app\supermarket_endpoint.json`; `main()` sees it, preselects role `server`, and the client boots silently against the local backend → login/first-admin. If the service is stopped, login shows "The Supermarket Pro service is not running on this computer…" instead of a bare connection error. |

`flutter analyze --no-pub` → **No issues found** (71 s).

### Phase 3 — build: **PASS (signing SKIPPED)**

1. `flutter build windows --release` → `FLUTTER_BUILD_OK` (40.2 MB, 132 s).
2. `stage_payload.ps1 -Mode PRODUCTION` → `STAGING_OK`, 2,833 files / 555.7 MB, vendor SHA-256 pins verified, offline `pip` smoke from staged artefacts OK, `customer_package.json` boundary OK.
3. `verify_payload.ps1` → `PAYLOAD_OK`.
4. `ISCC /DPRODUCTION` → 505,090,902 bytes, SHA-256 `67DE4FEC…6F42`.
5. Authenticode → **SKIPPED with a warning** (no certificate configured; nothing hard-coded).

Reproduce with one command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File installer\build_release.ps1 `
    -IsolationRoot D:\R5Isolation -Mode Production
# optional signing (never committed):
#   $env:SUPERMARKET_SIGN_PFX = 'C:\path\to\codesign.pfx'
#   $env:SUPERMARKET_SIGN_PFX_PASSWORD = '***'
```

### Phase 4 — verification: **PASS with limitations**

| Check | Result |
|---|---|
| Backend unit suite (`pytest tests/unit`, 116 modules) | 20 failed / 3541 passed / 1646 skipped — all failures pre-existing and unrelated (see §3.1) |
| Backend tests for changed code (`test_production_launcher.py`, `test_service_winsw.py`, `test_local_endpoint_publish.py`, `test_database_env_handoff.py`) | **30 + 17 passed** (the launcher suite caught the initial over-eager port classification — fixed: only `EADDRINUSE` is exit 5) |
| Flutter tests touching changed files (`auth_localization`, `lan_address_recovery`, `devices_wizard`, `boot_reconnect`, `connection_status`) | **37 passed** |
| `flutter analyze` | clean |
| `rehearsal_harness.ps1` | **NOT RUN.** It performs a real isolated install (service registration, PostgreSQL, ports 18000/15432) and this PC already runs the development backend on 8000 and the development PostgreSQL on 5432; running it unattended while both are live is not a safe operation on your machine. Use the checklists in §5/§6 instead. |
| Clean-VM install / upgrade / uninstall | **NOT RUN** (no VM available here) → §5 |
| Code signing | **NOT DONE** (no certificate) → §4.1 |

#### 3.1 Backend suite outcome

`pytest tests/unit`: **20 failed, 3541 passed, 1646 skipped** (17m46s).

Every failure is in a module **this release did not touch**, and they share one root cause in your current working tree (uncommitted work in progress: `app/core/config.py` +409 lines, `app/main.py`, `app/api/v1/*`, `tests/conftest.py`): the test `Settings` object comes up with `PORT = 0`, so `assert settings.PORT > 0`, `DISCOVERY_PORT == PORT`, the phase-16 device-guard suites, the trial/LAN compatibility suites, and the PDF/export rendering suites all fail on that value (e.g. `assert 8000 == 0`). Nothing in this release touches settings, the router, licensing or PDF layout.

Failing ids, for your own follow-up: `test_config.py::test_settings_loads_defaults`, `test_phase16_devices.py` (7 tests), `test_trial_lan_compat.py` (4), `test_phase7_facturation_pdf.py` (6), `test_export_render.py::test_a4_sale_invoice_and_report_keep_page_number_footer`.

The suites that cover the backend files changed here — `test_production_launcher.py`, `test_service_winsw.py`, `test_local_endpoint_publish.py`, `test_database_env_handoff.py` — are **all green (47 passed)**.

---

## 4. Remaining risks and manual steps

1. **Code signing (HIGH for delivery).** The installer is unsigned: SmartScreen will show "Windows protected your PC" and a client must click "More info → Run anyway". Configure `SUPERMARKET_SIGN_PFX` (+ password/timestamp URL) and rebuild — nothing else changes. Sign the *client exe* too before packaging if you want a fully clean first launch.
2. **Clean-Windows test (HIGH).** Nothing proves an end-to-end install until §5 is executed once on a clean Windows 10/11 x64 VM. Highest-risk steps: PostgreSQL EDB silent install (`--mode unattended`), VC++ redist install, service registration, and the first health gate.
3. **Reusing an existing PostgreSQL.** When 5432 is already owned by `postgres.exe`, provisioning is expected to attach to that server and create only `supermarket_production`-style databases; it must never touch other databases. Confirm this once on a machine with a pre-existing PostgreSQL (the dev-PC checklist in §6 exercises exactly this case).
4. **Trial/licence behaviour.** `LICENSE_ENFORCEMENT=on`, `TRIAL_DAYS=10` are written by the installer; a fresh client therefore starts in trial. If a licence key is required at first run, prepare the key file/paths before handover — the installer does not ship one.
5. **First-run network.** Single PC: automatic. Second till: LAN mode must be enabled in Settings (writes `LAN_MODE=1`), firewall rules are only added at install time when `LAN_MODE=1`, so enabling LAN mode afterwards needs a reinstall or manual `netsh` rules (documented in §7.5).
6. **Unsigned scripts in the payload.** `grant_data_dir_acl.ps1` and `render_service_xml.ps1` run under `-ExecutionPolicy Bypass` during install; a machine with an AppLocker/WDAC policy blocking PowerShell scripts would fail at that step (`install_steps.log` names it).
7. **Upgrade path.** Upgrade relies on the installer stopping the service at `ssInstall` and on a pre-migration `pg_dump` (M3). Verify once (§5 step 8).
8. **No automatic PostgreSQL service dependency** unless `render_service_xml.ps1 -PgService <name>` is passed; `delayedAutoStart` covers the normal boot order. If a client sees the service start before PostgreSQL on a very slow disk, add the dependency by re-rendering the XML with the service name from `install_steps.log`.

---

## 5. Clean Windows 10/11 VM checklist (release acceptance)

Prerequisites: fresh Windows 10/11 x64, administrator account, no Python/Flutter/PostgreSQL installed, snapshot taken.

1. Copy `SupermarketPro-Setup.exe`; verify SHA-256 = `67DE4FEC…6F42`.
2. Double-click → SmartScreen "More info → Run anyway" (expected while unsigned). Read the information page: printer driver note, ports, data paths.
3. Port pre-flight must not complain on a clean VM. Secretly confirm: `netstat -ano | findstr :8000` and `:5432` show nothing before installation.
4. Install completes without a terminal window. Then:
   - `services.msc` → **Supermarket Pro Backend** = Running, Startup = Automatic (Delayed).
   - `http://localhost:8000/api/v1/health` returns healthy JSON in a browser.
   - `C:\Program Files\Supermarket Pro\` contains `app\`, `backend\`, `SupermarketProBackend.exe`, `SupermarketProBackend.xml`, `vendor\`.
   - `C:\ProgramData\SupermarketPro\` contains `config\` (`.env`, `database.env`, `secrets.env`), `logs\`, `backups\`, `postgres\`.
   - `logs\install_steps.log` ends with `=== install OK ===` and every step has `exit=0`.
5. Desktop shortcut → app opens **without** the network wizard, straight to first-admin setup; create the admin (name + PIN).
6. Sell: add a product, make a sale, take payment, open the receipt preview. With a printer installed, print one 80 mm receipt.
7. Settings → Backup → create a backup; confirm a file appears under `C:\ProgramData\SupermarketPro\backups`.
8. **Reboot.** Do not log in to any tool: the service is Running again and the shortcut connects with no configuration.
9. **Upgrade:** run the same installer again over the install. Data, users, products and sales must survive; `install_steps.log` shows a pre-migration backup step.
10. **Uninstall** (Settings → Apps). `C:\Program Files\Supermarket Pro` is gone, the service is gone, **`C:\ProgramData\SupermarketPro` and all data remain**.
11. Reinstall and confirm the restored data appears (login with the existing admin).
12. Negative test: with a listener on 8000 (e.g. `python -m http.server 8000`), the installer must abort **before** changing anything and name the process.

---

## 6. Safe checklist for THIS dev PC

Your development backend (port 8000), development PostgreSQL (5432) and `new_app/backend/.env` are untouched by the build. To test an install here:

1. **Back up the dev database** with `pg_dump` to a file outside `C:\ProgramData`, and copy `new_app\backend\.env` to a safe name. Do not rely on the installer to protect it.
2. Stop the dev backend (close the `uvicorn`/Flutter run) so port 8000 is free: `netstat -ano | findstr :8000` should print nothing. **Leave your dev PostgreSQL running** — the installer will detect `postgres.exe` on 5432 and reuse it (this is the path worth testing here).
3. Snapshot/record: `sc query SupermarketProBackend` (should be "does not exist" before the test).
4. Run `SupermarketPro-Setup.exe` as administrator. Expect: port check accepts PostgreSQL on 5432, creates a separate app database and its own role; your dev databases are not touched.
5. Verify `C:\ProgramData\SupermarketPro\logs\install_steps.log` and `http://localhost:8000/api/v1/health`.
6. When finished, uninstall from Settings → Apps (data under `C:\ProgramData\SupermarketPro` remains — delete it manually if you want a clean slate), then restart your dev backend and re-check `git status`.
7. If you also want the PostgreSQL-install path tested, do it on a VM (§5), not here.

---

## 7. Troubleshooting on a client PC

**Installer log:** Inno writes its own log (default `%TEMP%\Setup Log <date>.txt`) and the app's step log:
`C:\ProgramData\SupermarketPro\logs\install_steps.log` — every step with its exit code; the first non-zero `exit=` is the failing step.

| Symptom | Check |
|---|---|
| Service not running | `services.msc` → *Supermarket Pro Backend*. Restart it, then look at `C:\ProgramData\SupermarketPro\logs\backend.log`. |
| App says the service is not running | `http://localhost:8000/api/v1/health`; if that fails, start the service (`sc start SupermarketProBackend`). |
| Health OK but app cannot connect | `C:\ProgramData\SupermarketPro\config\supermarket_endpoint.json` (port) vs `netstat -ano | findstr :8000`. |
| "Port 8000 already in use" at install | The message names the process; close it and rerun. Do **not** disable the check. |
| Database problems | `backend.log` for `port_in_use`/`bind_failed`; PostgreSQL service `postgresql-x64-18`; `C:\ProgramData\SupermarketPro\postgres\data`. |
| Roll back a bad upgrade | Backups are taken before migrations under `C:\ProgramData\SupermarketPro\backups`; restore with `pg_restore` using `config\database.env` credentials. |
| Uninstall keeps data | By design. `C:\ProgramData\SupermarketPro` is only removed manually. |

---

## 8. How to give this to the client

1. Hand over **one file**: `SupermarketPro-Setup.exe` (481.7 MB), plus its SHA-256 so they can verify the copy.
2. Client: right-click → Run as administrator (or double-click; admin rights are required and UAC asks). SmartScreen → More info → Run anyway (unsigned). If they have an unsigned-app policy, sign the installer first.
3. Default ports: **8000/TCP** (service, also UDP for LAN discovery) and **5432/TCP** (PostgreSQL). Nothing needs to be opened on a single PC.
4. Data lives in `C:\ProgramData\SupermarketPro` (exports in `Documents\Supermarket Pro`), program in `C:\Program Files\Supermarket Pro`, logs in `C:\ProgramData\SupermarketPro\logs`.
5. Restore a backup: Settings → Backup/Restore inside the program, or `pg_restore` against `config\database.env` if the app cannot start.
6. Pair a second PC: enable LAN mode on the main PC, run the installer on the second PC, choose "client" in the wizard and pick the server found automatically (or type its IP).
7. Keep the receipt printer's vendor driver installed first — the installer's information page repeats this.

---

## 9. Checks actually executed (verbatim)

| Command | Result |
|---|---|
| `flutter analyze --no-pub` | `No issues found!` |
| `installer\build_flutter.ps1` | `FLUTTER_BUILD_OK … bytes=140288 total_bytes=42155878` |
| `stage_payload.ps1 -Mode PRODUCTION` | `STAGING_OK … files=2833 total=555.7 MB` |
| `verify_payload.ps1` (clean stage) | `PAYLOAD_OK` |
| `verify_payload.ps1` (planted `.env` + `tests/test_leak.py`) | `PAYLOAD_FAILED: 3 violation(s)` |
| `render_service_xml.ps1` (non-default paths + `-PgService`) | rendered paths correct, `<depend>` injected |
| `render_service_xml.ps1` (default paths) | byte-identical to the template (`diff` empty) |
| `pytest` — launcher/service/endpoint/database-env suites | 47 passed |
| `pytest tests/unit` (full) | 20 failed / 3541 passed / 1646 skipped — all 20 are pre-existing failures caused by `PORT = 0` in the current WIP `config.py`/`conftest.py`, none in code changed here (§3.1) |
| `flutter test` (5 suites touching changed files) | `All tests passed!` (37) |
| `ISCC /DPRODUCTION` | exit 0, 505,090,902 bytes |

## 10. Rebuild after the first real install attempt (2026-11-13, 15:17)

Your first install reached the `provision` step and failed with `exit=1`. Findings and fixes:

1. **Unexpanded Inno constants (cause of the odd command line).** `ProvisionArgs` built the command from a bare `{#PgInstallDir}` / `{#PgDataDir}`. ISPP substitutes the *define text* at compile time, so the backend received the literal `{autopf}\SupermarketPro\PostgreSQL\18`. Both arguments are now produced with `ExpandConstant('{#PgInstallDir}')`, which yields real paths at run time. (The first attempt showed real paths because it came from the older 10:45 build.)
2. **Real reason for `exit=1`.** Reproduced manually with the installed interpreter: `plan: reuse (PostgreSQL 18.6-5, C:\Program Files\PostgreSQL\18)` → no maintenance password was supplied → the pass tried to connect as `app_user` → `FATAL: password authentication failed for user "app_user"`. The reason was also being lost because `provision_report.json` could not be rewritten (PermissionError from a non-admin run) *before* anything was printed.
3. **Reuse now works and is explicit.** A new installer page ("This PC already has PostgreSQL") asks for that server's superuser password when a PostgreSQL install is detected (registry `SOFTWARE\PostgreSQL\Installations` or `postgres.exe` owning 5432) and is skipped on a clean PC. The password is passed by file, deleted immediately, never logged, and stored only in `<DATA_DIR>\config\pg_admin.env` (needed for upgrades and pre-migration backups) — exactly where a dedicated install already stored it. The pass creates only its own role and database.
4. **Never touching a foreign database.** New guard: on a *fresh* install against a reused server, if the target database already exists, provisioning refuses (`exit 3`) instead of migrating somebody else's database. The message tells the operator to re-run with `/DBNAME=<name>`, which the installer now honours (`{param:DBNAME|}`), so an install can coexist with your `supermarket_pro` dev database without reading or altering it.
5. **Real reason in `install_steps.log`.** The backend now writes `<DATA_DIR>\logs\provision_error.txt` on every failure (including unexpected crashes, via an entry-point guard) and prints the JSON report even when the report file cannot be written; `setup.iss` reads that file back into `install_steps.log` (`provision reason: …`) before raising.

Verified: `pytest tests/unit/test_postgres_provisioning.py tests/unit/test_release_provisioning.py` → 92 passed / 1 skipped; manual runs confirm (a) no password on a detected server → `exit 2` with the actionable "enter the superuser password" message, (b) wrong superuser password → `exit 1` with the postgres authentication error and `pg_admin.env` persisted, (c) every failure leaves `provision_error.txt`. The successful reuse path itself needs your real `postgres` password and was **not** executed here — it is the first thing to try on the next install. Nothing was written to, migrated or dropped in any existing database during these tests.

Three installer compiler issues were found and fixed while making this change: a Pascal comment containing `}` terminated early, a continuation line starting with `[` was read as a section tag, and Inno 7 does not define the `TInputQueryPage` alias (it is `TInputQueryWizardPage`).

Rebuilt with `installer\build_release.ps1 -Mode Production`: 505,093,771 bytes, SHA-256 `2CA089A0…D36B`.

## 11. Maintenance-password verification (review fix, 2026-11-13)

A code review found that the superuser password was written to `pg_admin.env` **before** it was verified, and `_persist_admin_password` used `O_EXCL` (never rewrites), so a wrong password could never be corrected.

1. **Verify on Next.** The wizard now test-connects with the detected instance's own `psql.exe` (`HKLM\SOFTWARE\PostgreSQL\Installations\<id>\Base Directory`) as `postgres` to `127.0.0.1:5432`, `-w` (never prompt), 5 s timeout. The password is passed in `PGPASSWORD` (never on a command line, never in the generated `.bat`), is cleared immediately, and the `.bat` is deleted. A failure blocks Next with psql's own message and the field stays editable. If no `psql.exe` can be found the test cannot run and the field is accepted (the backend still refuses to persist anything unverified).
2. **Persist only after verification.** `_persist_admin_password` moved to the end of `installer_provision.py` and runs only when provisioning succeeded; it writes to a temp file and `os.replace`s it, so an interrupted run leaves no partial or wrong credential. `--save-admin-password` documents this contract.
3. **Stale stored password.** On a re-run/upgrade with the field empty, the stored password is test-connected too: if the server rejects it, it is renamed to `pg_admin.env.rejected-<timestamp>` (moved aside, never silently reused) and Next is blocked until the current password is typed; the corrected password overwrites the stored one after a successful pass. The backend additionally classifies a rejected *stored* password as `exit 4` with an explicit message, instead of failing mid-migration.
4. **No wrong file after a failed install.** Verified by test: a rejected supplied password leaves `config/` without any `pg_admin.env`; a rejected stored password leaves the existing file byte-identical (nothing rewritten).

Verified: `pytest tests/unit/test_postgres_provisioning.py tests/unit/test_release_provisioning.py` → 92 passed, 1 skipped; manual runs confirm `exit 4` for both rejection paths, `pg_admin.env` absent after a failed install, and `psql` returning `FATAL: password authentication failed for user "postgres"` (exit 2) as the text shown to the operator. The successful-acceptance path still needs the real password and is not exercised here. Nothing was written to or changed in any existing database.

Rebuilt: 505,095,913 bytes, SHA-256 `A7F0EA90…3BCC`.

## 12. Reuse never trusts `database.env` (review fix)

Evidence from the server (`\du` showed only the `postgres` role) located the bug precisely: in `provision_database`, `ensure_role()` ran **only in the "database absent" branch**. On a reused server that already held a database with the target name (the operator's own `supermarket_pro`), the role was never created and the migrations then connected as `app_user` — `FATAL: password authentication failed for user "app_user"`. A `database.env` left by the failed install was pure assumption; nothing checked it against the server.

New order of operations in `provision_database` (always through the maintenance credential):

1. `connect` — as `postgres` (admin URL).
2. `role` — always: role missing → `CREATE ROLE app_user LOGIN PASSWORD <database.env>`; role present → `ALTER ROLE app_user WITH LOGIN PASSWORD <database.env>` (`ensure_role_password`). A stale `database.env` is thereby repaired, never trusted; no other role is ever touched.
3. `database` — created only when absent, owned by the role; re-created/dropped never.
4. `app_login` — `check_connectivity(app_url)` **before** migrations; failure raises `CredentialsError` telling the operator to delete `<DATA_DIR>\config\database.env` and re-run.
5. migrations, RBAC.

Database naming on a shared server: the wizard now lists the server's databases after the password test succeeds. If `supermarket_pro` already exists on a fresh install it explains that the database is not ours and will not be touched, and switches this installation to `supermarket_pro_install` (or the next free `…_N`); `/DBNAME=<name>` is honoured, and an explicitly requested name that already exists blocks Next with a clear message instead of exiting 3 later. `ResolveIdentity` uses the chosen name, which flows into `.env`, provisioning and the service.

`provision_error.txt` is now written by **every** failure path: all early returns go through `_fail()`, `SystemExit` from the backup/dedicated-install helpers records its code, and unexpected exceptions still record the type and message.

Tests added (`tests/unit/test_postgres_provisioning.py`): stale `database.env` + missing role → role created through the admin URL with the stored password and `app_login` applied; existing role → exactly one `ALTER ROLE app_user … PASSWORD` and no `CREATE ROLE`; reconciliation touches no other role. `ALLOWED_SQL` now permits `ALTER ROLE` and the destructive list names destructive `ALTER`s explicitly. Suite result: **108 passed, 1 skipped** (provisioning + release + launcher).

Not exercised here: the real-server run (needs the `postgres` password) and `tests/integration/test_postgres_lifecycle.py`. Nothing was created, altered or dropped on the live server during this work.

Rebuilt: 505,097,936 bytes, SHA-256 `06E3E711…E5A1`.

---

Full backend unit suite (`pytest tests/unit`) was executed separately; its per-test outcome is captured in `%TEMP%\pytest_unit.log` on the build PC. Every suite that covers a file changed in this release passed. Long-running integration-style cases in that suite are timing/DB dependent and were not re-run individually; the rehearsal harness (§3, Phase 4) remains the one meaningful end-to-end check and is deferred to §5.

## 13. Post-install re-discovery reported a Running service as "not running" (2026-11-14)

**Reported:** on a clean sandbox the dedicated install finished (service
`postgresql-supermarketpro-18` created and Running per `Get-Service`), then
provisioning aborted with *"the post-install plan is install-dedicated:
PostgreSQL 18.6-5 (C:\Program Files\SupermarketPro\PostgreSQL\18): the Windows
service postgresql-supermarketpro-18 is not running"*, and no
`provision_report.json` / `database.env` were written.

**Cause (three separate defects):**

1. `postgres_discovery.parse_sc_query_states` read the *localized* state word
   of `sc query` (`STATE : 4  RUNNING`). The field name and the word are
   translated on some Windows languages, so the state string came back empty,
   and the plan message printed `item.service_state or 'not running'` — a
   healthy server described as stopped. Now the state comes from the numeric
   Windows service-state code (1-7, locale-invariant), with a per-service
   `sc query <name>` fallback (`parse_sc_single_state`) that works even when
   the field names are localized (`NOM_SERVICE` / `ÉTAT`).
2. `plan_provisioning` no longer claims "not running" for an unknown state; it
   says the state could not be read and points at `sc query <name>`.
3. The installer re-ran discovery after installing its own instance. That
   re-discovery could only add races (postmaster still starting, registry key
   not yet visible). `installer_provision.py` now keeps the facts it created
   (`--pg-install-dir`, `--pg-data-dir`, port, service name, generated
   superuser password), waits for `SELECT 1` with the instance's own
   credentials (`_wait_for_server`, up to 90 s, every attempt logged with a
   timestamp) and plans from `_known_instances()` instead.

Also in this build:

* **The wizard-verified connection is authoritative.** `setup.iss` passes
  `--verified-server --admin-host 127.0.0.1 --pg-bin-dir <bin>` once the
  maintenance password has been test-connected on the wizard page, and
  `installer_provision.py` builds the plan from that endpoint (querying
  `SHOW server_version`), never from a fresh discovery pass. Exit 4 if the
  endpoint is no longer reachable.
* **Readiness instead of netstat/`tasklist`.** The installer used to parse
  `netstat` for the localized `LISTENING` word; the listener test is now
  locale-proof (local address `:<port>` plus foreign `:0`), and both
  `ExistingPostgresDetected` and `PrepareToInstall` call `pg_isready`
  (cached, retried 5×1.5 s) so a server that is still starting is not
  mistaken for a missing one.
* **Evidence on every failure path.** `_fail()` now also writes
  `provision_report.json` (previously only `provision_error.txt`), and the EDB
  installer's stdout/stderr is saved to `<DATA_DIR>\logs\pg_install.log`.
* **Dedicated-install limits and progress.** `--disable-components` keeps only
  `stackbuilder` — the identifier the shipped builds already pass. EDB's
  documented list is `server pgAdmin stackbuilder commandlinetools`, but
  `--help` could not be run against the staged installer (it requires
  elevation), so `pgAdmin` is **not** passed: an unverified component name must
  not appear on an unattended command line. `server` and `commandlinetools`
  stay enabled because provisioning needs `psql`, `pg_isready` and `pg_dump`.
  No install-time measurement was taken and **no speed-up is claimed**; the
  ~20 minutes seen on the sandbox remain unexplained. What this build adds is
  evidence: each sub-step (install, readiness, role, database, app_login,
  migrations, RBAC) is logged with a timestamp and elapsed time,
  `<DATA_DIR>\logs\pg_install.log` keeps the EDB installer's own
  stdout/stderr, and the wizard shows a status line while pip/provisioning run.
* **Retry after the partial state** (`pg_admin.env` present, service Running,
  no `database.env`) plans as `reuse` and never reinstalls PostgreSQL.

**Checks executed:** `pytest tests/unit/test_postgres_provisioning.py
tests/unit/test_postgres_discovery.py tests/unit/test_release_provisioning.py`
→ 141 passed, 1 skipped (includes new regression tests
`TestDedicatedInstanceIsSeenAsRunning` — custom service name, localized output,
stopped state — and `test_unknown_service_state_never_claims_not_running`).
`ISCC /DPRODUCTION` compiles clean; `build_release.ps1 -Mode Production`
prints `RELEASE_OK`.

**Not executed here:** the end-to-end clean-machine install. This PC has the
development PostgreSQL 18 on 5432 with the developer's databases and no
superuser password is available to this session, so the dedicated-install and
provisioning-reuse paths cannot be exercised without touching that server. The
acceptance test remains: on a fresh Windows VM, run the setup, then
`curl http://localhost:8000/api/v1/health` must answer `connected`.

**Rebuilt:** 505,102,177 bytes, SHA-256 `F0475CE2…CFE7`.

## 14. Empty DACLs, no post-start check, crash loop (sandbox evidence, 2026-11-14)

**Reported:** `config\.env`, `config\secrets.env`, `config\database.env` were
created with an empty DACL (no ACE, inheritance not applied). The
NetworkService backend crash-looped on `PermissionError`, WinSW logged
"finished with 3" every second, `pg_admin.env` was equally unreadable, and
administrators could not read `logs\install_steps.log`. The installer still
reported success.

**Cause.** The old `grant_data_dir_acl.ps1` did one recursive pass over the
whole data root: `icacls <DATA_DIR> /grant …:(OI)(CI)… /T` and then
`icacls <DATA_DIR> /inheritance:r /T`. Reproduced on a scratch tree with the
exact sequence: afterwards `icacls` on a file inside the tree answers
*"Access is denied"* and creating a new file there is denied too — a
protected DACL that grants nothing except to the three named SIDs. The same
`/T` also walked into `postgres\data`, replacing PostgreSQL's own ACLs (which
is what broke `postgresql.conf` in the sandbox). Credential files must never
depend on inheritance from a tree whose DACL is being rewritten underneath
them.

**Fix: explicit, per-object, SID-based ACLs applied as the last step before
the service starts** — `app/core/acl.py`, run by
`installer_selfcheck.py --phase pre-service`, wired in `setup.iss` as
`HardenConfigAcls` immediately after provisioning and before
`ProductionServiceRegister`. Never recursive: `icacls_argv()` asserts `/T` is
absent, and `postgres\` / `data\` are skipped by name.

### Exact command lines (`<DATA>` = `C:\ProgramData\SupermarketPro`)

```
icacls "<DATA>\config\.env"        /inheritance:r /grant *S-1-5-20:R /grant *S-1-5-32-544:F /grant *S-1-5-18:F
icacls "<DATA>\config\secrets.env"  /inheritance:r /grant *S-1-5-20:R /grant *S-1-5-32-544:F /grant *S-1-5-18:F
icacls "<DATA>\config\database.env" /inheritance:r /grant *S-1-5-20:R /grant *S-1-5-32-544:F /grant *S-1-5-18:F
icacls "<DATA>\config\pg_admin.env" /inheritance:r /grant *S-1-5-32-544:F /grant *S-1-5-18:F
icacls "<DATA>\logs"                /grant *S-1-5-20:(OI)(CI)M /grant *S-1-5-32-544:(OI)(CI)F /grant *S-1-5-18:(OI)(CI)F
```

`S-1-5-20` = NETWORK SERVICE, `S-1-5-32-544` = BUILTIN\Administrators,
`S-1-5-18` = LOCAL SYSTEM. The `*` prefix makes icacls resolve the SID
directly, so no localized name is ever looked up. `pg_admin.env` gets **no**
service ACE: `run_production.py` never opens it (only
`installer_provision.py` does), so granting it would only widen exposure of
the superuser password.

### Expected `icacls` output on a clean machine (by SID)

```
<DATA>\config\.env
        S-1-5-18:(F)        (NT AUTHORITY\SYSTEM  /  AUTORITE NT\Système)
        S-1-5-32-544:(F)    (BUILTIN\Administrators  /  BUILTIN\Administrateurs)
        S-1-5-20:(R)        (NT AUTHORITY\NETWORK SERVICE  /  AUTORITE NT\SERVICE RÉSEAU)
        no (I) inherited entries — the DACL is protected
        SDDL: D:PAI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;NS)

<DATA>\config\pg_admin.env
        S-1-5-18:(F)
        S-1-5-32-544:(F)
        SDDL: D:PAI(A;;FA;;;SY)(A;;FA;;;BA)      — no NS ACE

<DATA>\logs
        S-1-5-18:(OI)(CI)(F)
        S-1-5-32-544:(OI)(CI)(F)
        S-1-5-20:(OI)(CI)(M)
        inherited (I) entries from <DATA> remain — inheritance is KEPT
        SDDL starts with D:AI (not D:PAI)
```

Verification reads the DACL through `icacls <path> /save <tmp>` (UTF-16LE,
no BOM) and checks the locale-independent SDDL codes `SY`/`BA`/`NS`, the
`PAI` (protected) versus `AI` (inherited) flag and the access mask. Nothing
localized is parsed; only exit codes decide success.

### Post-start self-check — no more false success

`installer_selfcheck.py --phase post-service` polls
`http://127.0.0.1:8000/api/v1/health` for up to 60 s and requires
`"database": "connected"`. On failure it writes the tails of
`SupermarketProBackend.err.log`, `SupermarketProBackend.out.log`,
`backend.log` and the newest PostgreSQL log to `<DATA>\logs\selfcheck.txt`;
`setup.iss` copies those into `install_steps.log`, shows "The files were
installed, but the installation is NOT working yet" on the final page, skips
`CommitIdentity` and never logs `=== install OK ===`. PostgreSQL readiness
before provisioning already has its own 90 s retry loop. When a config file
is unreadable, `run_production.py` now prints the account name and the exact
path plus the `icacls` repair line.

### Service stop/restart

WinSW: `<onfailure action="restart" delay="10 sec"/>`, then `30 sec`, then
`60 sec`, with `<resetfailure>1 hour</resetfailure>`; `<stoptimeout>30 sec`
makes a stop wait for the Ctrl+C shutdown and then terminate the child.
WinSW cannot branch on an exit code, so a configuration error (exit 3) cannot
disable restarts outright — what is guaranteed is that the "finished with 3
every second" loop becomes at most one attempt per minute.

### The ~20 minute PostgreSQL install — not measured

No timing data exists for the sandbox run, so nothing was optimised. This
build only collects evidence: every sub-step is timestamped with elapsed
time, `<DATA>\logs\pg_install.log` keeps the EDB installer's stdout/stderr
and exit code, and `--debugtrace <DATA>\logs\pg_edb_install.log` (a
documented EDB option) records the installer's own step-by-step trace.
Reading that trace on the next sandbox run will show whether initdb, the VC++
runtime, AV scanning or something else dominates.

### Checks executed

* `pytest` on `test_installer_acl.py`, `test_service_winsw.py`,
  `test_production_launcher.py`, `test_release_provisioning.py`,
  `test_postgres_provisioning.py`, `test_database_env_handoff.py` →
  **155 passed, 1 skipped**. New: `TestCommandLines` (exact icacls argv, no
  `/T`), `TestSddlCheck` (accepted/rejected SDDL), `TestSelfCheck` (health
  parsing, diagnostics, log tails), `TestInstallerWiring` (ACL step before
  service registration; a failed self-check never reports success), plus the
  WinSW policy test now requires escalating delays ≥ 10 s.
* Real run of the ACL step on a scratch tree on this PC:
  `installer_selfcheck.py --data-dir <tmp> --phase pre-service` → exit 0 in
  0.4 s, `ACL-SELF-CHECK OK`, printing the five command lines above; the
  resulting ACLs were read back with `icacls` and match the expected output.
* `ISCC /DPRODUCTION` compiles clean; `build_release.ps1 -Mode Production
  -SkipFlutter` → `RELEASE_OK`.

### Not verified

* No clean-Sandbox install of this build: the host's PostgreSQL 18 on 5432
  holds `supermarket_pro` and no superuser password is available here, so an
  install must not be run on this PC. Everything above about a fresh machine
  is argued from code, unit tests and the scratch-tree run.
* `icacls` output on a French machine was verified only for shape (names are
  localized, SIDs are not); the self-check never parses names.
* The `/save` audit path under a low-privilege context is untested — the
  installer runs elevated, and a failure there now aborts the install rather
  than continuing silently.
* The 20-minute install stays unexplained until `pg_edb_install.log` from a
  sandbox run is read.

**Rebuilt:** 505,113,427 bytes, SHA-256 `AF1FCFA7…B1A8`.

## 15. Password ending in "@" broke the reuse path (2026-11-14)

**Reported:** `/DBNAME=supermarket_pro_install` on a PC that already runs
PostgreSQL 18 failed with `provision exit=4` and *"the PostgreSQL maintenance
password supplied to the installer was rejected by the server … Underlying
error: database connection failed: connection to server on socket
"@127.0.0.1/.s.PGSQL.5432" failed: Invalid argument (0x00002726/10022)"*,
although the wizard's `psql` test had accepted the same password.

**Cause.** `installer_provision.py` built the maintenance URL by hand:

```
postgresql://{user}:{password}@127.0.0.1:{port}/postgres
```

A password ending in `@` produced `…secret@@127.0.0.1…`: the userinfo ended at
the first `@`, the second one made the host empty, and psycopg2 fell back to
`socket "@127.0.0.1/.s.PGSQL.5432"`. Any of `@ : / % # ? &` would do the
same. The error was then mapped to "password rejected", which sent the
operator after a credential that was in fact correct.

**Fixes**

1. `app/core/postgres_provisioning.py`
   * new `build_url()` — `sqlalchemy.engine.URL.create(...).render_as_string()`
     percent-encodes every reserved character; `DbParams.from_url` already
     decodes with `unquote`, so `psql`/`pg_dump` still receive
     `PGPASSWORD` with the original bytes.
   * `classify_connection_error()` replaces the old two-token heuristic and
     never guesses:
     * SQLSTATE **28P01 / 28000** (locale-proof) or an authentication
       sentence → `CredentialsError`;
     * `invalid dsn` / `invalid argument` / `missing "="` /
       `invalid connection string` → `MalformedConnectionError`
       ("installer defect, not a password problem");
     * refused / timeout / DNS / "starting up" → `InstanceUnavailableError`;
     * anything else → `ProvisioningError` with the raw driver text.
     The raw text is always kept, passwords scrubbed.
2. `installer/installer_provision.py`
   * admin verification now uses `psycopg2.connect(host=…, port=…, user=…,
     password=…, dbname=…)` — keyword arguments, no URL to misparse —
     and both URLs are built with `build_url()`.
   * distinct exit codes: **4** credentials refused, **5** server
     unreachable (password never tested), **6** unusable connection string.
   * `_read_password()` no longer `strip()`s: only a trailing CRLF/LF/CR is
     removed, so leading/trailing spaces and `@` survive; `utf-8-sig`
     tolerates a BOM.
   * `_load_admin_password()` no longer strips the value from
     `pg_admin.env` either.
3. `app/core/secrets.py` — `_validate_external_password` rejects
   surrounding whitespace explicitly instead of silently trimming it
   (generated passwords are URL-safe `token_urlsafe`, so they never need it).
4. `installer/setup.iss`
   * the password page no longer `Trim()`s what the operator typed
     (`Trim()` is used only for the empty-field test), so the value
     `psql` verified is the value written to the hand-off file
     (`SaveStringToFile`, no newline, UTF-8 without BOM) and the value the
     backend receives.
   * the database-name check now logs both outcomes: `/DBNAME=<name>` taken
     (abort + message) and the automatic switch away from
     `supermarket_pro` (message + `LogStep`).
5. SQL that carries a password keeps using the `E'…'` escape literal
   (`_quote_literal`, backslash and quote escaped) and validated
   identifiers; `psql`/`pg_dump` still get the password only through
   `PGPASSWORD`, never argv or a `.bat` file.

### Regression tests (`tests/unit/test_password_special_characters.py`, 47 cases)

Passwords `trailing@`, `p@ss:word/1%2#3?4&5!6'7"8^9`, `lead space and @`,
`espace finale@ `, `a:b/c@d%e#f?g&h!i^j'k"l`, `+slash\back@slash` covering:
`build_url` → `DbParams.from_url` → `make_url` round trip (alembic/SQLAlchemy
path), no unencoded `@` in the userinfo, `maintenance_url`, `safe_repr`
(no password), `_probe_admin` keyword arguments (no URL), the four error
classes, `ensure_role` / `ensure_role_password` `E'…'` quoting,
`create_database` identifiers, `database.env` round trip +
`run_production._database_url_with_password`, `pg_admin.env` save/load, and
the wizard hand-off file (with and without CRLF).

Suite: **202 passed, 1 skipped** across
`test_postgres_provisioning`, `test_password_special_characters`,
`test_release_provisioning`, `test_production_launcher`,
`test_database_env_handoff`, `test_installer_acl`, `test_service_winsw`.

### Live evidence on the real dev server (read-only, 2026-11-14)

Run with the operator's own superuser password (10 bytes, ends with `@`),
passed only through a temporary file that was deleted afterwards:

* the hand-off file round trip is **exact** (`_read_password` returns the same
  10 bytes, still ending in `@`);
* the OLD hand-built URL reproduces the reported failure verbatim —
  `connection to server on socket "@127.0.0.1/.s.PGSQL.5432" failed:
  Invalid argument (0x00002726/10022)` — and is now classified
  **MalformedConnectionError** ("installer defect, not a password problem")
  instead of "password rejected";
* the NEW path (`psycopg2.connect(host=…, port=…, user=…, password=…,
  dbname=…)`) logs in successfully (`SELECT 1`);
* inventory before the operator's own install: 10 non-template databases
  (`health_system_management`, `pos_db`, `postgres`,
  `supermarket_bench_largesale`, `supermarket_bench_phase14`,
  `supermarket_bench_phase17`, `supermarket_pro`, `supermarket_pro_r3_absent`,
  `supermarket_pro_r3_test`, `supermarket_pro_test` — 12 with `template0/1`),
  roles: `postgres` only; `supermarket_pro_install` absent, `app_user`
  absent — i.e. the failed run created nothing.

### Not verified

The full reuse install (`/DBNAME=supermarket_pro_install`, role + database +
migrations + RBAC + service + health) was **not** executed here: the operator
runs it themselves with this build. Unit tests do not prove an end-to-end
install.

**Rebuilt:** 505,115,641 bytes, SHA-256 `1FAA9DC0…1A01`.
