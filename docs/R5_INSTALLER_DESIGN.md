# R5 — Supermarket Pro Windows Desktop Installer: Design & Verification Record

Status: **DESIGN FREEZE — no installer source written yet.**
Scope boundary: this document is the pre-implementation deliverable required by the R5 brief:
vendor verification (flags / licensing / checksums / version+source), the complete installer
design, and the list of unresolved integration contracts.

---

## 0. Hard safety boundaries (rehearsal)

| # | Rule | Enforced by |
|---|---|---|
| 1 | All rehearsal activity confined to `D:\R5Isolation\` | build scripts take `ISOLATION_ROOT` as a required parameter |
| 2 | `REHEARSAL` is a **compile-time** Inno define; a production build cannot activate it | `#error` guards in `setup.iss` (§6) |
| 3 | The actual compiled `Setup.exe` must be executed in rehearsal | §6 rehearsal matrix |
| 4 | Dedicated test port + isolated test database; **never** the development database | §6 (HTTP 18000, PostgreSQL 15432, all data under `D:\R5Isolation`) |
| 5 | Test install / backend start / Flutter launch / upgrade / reinstall / uninstall / data preservation | §6 |
| 6 | Clearly separate REAL EXECUTED from SIMULATED / NOT TESTED | evidence report (end of R5) |
| 7 | Never claim service registration, firewall, PostgreSQL installation, or clean-machine install passed unless actually tested | evidence report (end of R5) |
| 8 | No UAC elevation on this machine | verified by static manifest inspection before every vendor installer execution (§1) |
| 9 | No modification of the dev PostgreSQL instance; no production private key; no deletion of any DB/backup; `new_app_upload`, `new_app_upload.zip`, `tatus`, `.env` untouched | pre/post verification runs |
| 10 | No Git commit / push / reset / clean / checkout / stash | HEAD stays `7d634bf` |

---

## 1. Vendor verification results

### 1.1 Inno Setup — **VERIFIED**

| Item | Value |
|---|---|
| Version | **Inno Setup 7.1.1 x64** (released 2026-10-28) |
| Source | `https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe` (linked from `jrsoftware.org/download.php/is/`) |
| Size | 14,336,568 bytes |
| Published SHA-256 | `8a5a6711c3766a6e5fb74f280ba0e3551e719ce94538d901fdbd1f8f9920b3f0` (GitHub release asset `digest`, cross-checked against `…exe.issig` which stores it in plain text) |
| Local SHA-256 | identical → **MATCH** |
| Authenticode | `Status=Valid`, signer `CN=Pyrsys B.V., O=Pyrsys B.V., NL` → **MATCH** with `jrsoftware.org/isdl-verify.php` |
| Embedded manifest | `asInvoker=True`, `requireAdministrator=False` → launch cannot trigger UAC |
| License | Inno Setup `license.txt` (verbatim fetched): *"Permission is granted to anyone to use this software for any purpose, including **commercial applications**, and to alter and redistribute it"* subject to 4 conditions (retain copyright notices in source; **retain copyright notice and website addresses in binary redistributions**, e.g. in the About boxes; no misrepresentation of origin; modified versions must be marked). Purchasing is requested by the author, **not legally required**. |
| Acquisition method (no UAC) | `innosetup-7.1.1-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PORTABLE=1 /DIR=D:\R5Isolation\tools\innosetup-7` — non-elevating because `setup.iss` sets `PrivilegesRequiredOverridesAllowed=dialog` (official source, `jrsoftware/issrc@is-7_1_1/setup.iss`) |
| Toolchain proof | ISCC smoke compile `Successful compile (0.844 sec)` → `r5-smoke.exe` → executed `/VERYSILENT` exit **0**, payload written, `[Run]` action executed, uninstall entry created. ISCC self-reports *"Non-commercial use only"* (the community-edition banner) — consistent with the license above; commercial use is permitted, a license purchase is a request. |

**Obligation carried into the product:** the shipped Setup.exe and product documentation must
retain the Inno copyright notice + `https://jrsoftware.org/` address (condition 2) and must not
claim we wrote Inno Setup (condition 3). Recorded in the product's third-party notices file (§9-8).

### 1.2 PostgreSQL — **VERIFIED (flags, licensing, checksum); NOT executed**

| Item | Value |
|---|---|
| Version | **PostgreSQL 18.6-5** (Windows x64), R3-verified major range is 13–18 (`postgres_discovery.py:57-64`) |
| Installer source | `https://get.enterprisedb.com/postgresql/postgresql-18.6-5-windows-x64.exe` (the installer linked from postgresql.org/download/windows, "certified by EDB") |
| Size | 414,966,472 bytes |
| Published SHA-256 | `227e2bc08091b4c2b8338c7d61b11d057f895711480b006f90bfcfcd2410a58a` — fetched from the publisher's own sidecar `…windows-x64.exe.sha256` **before** the installer was downloaded |
| Local SHA-256 | identical → **MATCH** |
| Redistribution / license | EDB's own `server/resources/installation-notes.html` for PostgreSQL 18 (`EnterpriseDB/edb-installers@REL-18`) states verbatim: *"**The PostgreSQL Server, pgAdmin and the installer itself are released under the PostgreSQL License.**"* The PostgreSQL License (postgresql.org/about/licence) grants *"Permission to use, copy, modify, and distribute this software and its documentation for any purpose, without fee, and without a written agreement"*, conditioned on retaining the copyright notice + the three licence paragraphs in all copies. OpenSSL attribution is also declared by the package. → **Redistribution of the installer inside our commercial product is permitted provided the licence/acknowledgement texts ship with the product.** |
| Binaries ZIP (rehearsal path) | `postgresql-18.6-5-windows-x64-binaries.zip`, published SHA-256 `e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2` (publisher sidecar `…binaries.zip.sha256`). postgresql.org explicitly describes this artefact as *"intended for users who wish to **include Postgres as part of another application installer**"*. |
| Execution status | **Not executed on this machine** (would require UAC; forbidden). |

**Official unattended flags (verified against EDB docs, `enterprisedb.com/docs/supported-open-source/postgresql/installing/command_line_parameters/`):**
`--mode qt|win32|unattended`, `--unattendedmodeui none|minimal|minimalWithDialogs`,
`--disable-components`/`--enable-components` (`server`, `pgAdmin`, `stackbuilder`, `commandlinetools`),
`--prefix`, `--datadir`, `--serverport`, `--superaccount`, `--superpassword`,
`--serviceaccount`, `--servicepassword`, `--servicename`, `--install_runtimes`,
`--enable_acledit`, `--locale`, `--optionfile`, `--create_shortcuts`, `--extract-only`, `--help`, `--version`.

**Corrections required to R3 (`app/core/postgres_provisioning.py:590-635`, currently labelled UNVERIFIED):**

| Current R3 token | Official EDB parameter | Consequence of the current value |
|---|---|---|
| `--unattendmode unattended` | `--unattendedmodeui none` | not an EDB parameter at all |
| `--disablestackbuilder` | `--disable-components stackbuilder` | not an EDB parameter at all |
| `--superuser <u>` | `--superaccount <u>` | superuser name silently ignored → default `postgres` happens to coincide |
| `--installprefix <d>` | `--prefix <d>` | install directory silently ignored → would land in `C:\Program Files\PostgreSQL\18` instead of ours |
| *(absent)* | `--enable_acledit 1` | recommended for our non-default data path under a stripped-inheritance `ProgramData` tree |
| *(absent)* | `--install_runtimes 1` (default) | keep the default: VC++ runtimes must be provisionable offline |

Kept as-is (all official): `--mode unattended`, `--superpassword`, `--serverport`,
`--datadir`, `--servicename`.

### 1.3 WinSW — **v2.12.0 chosen, artefact verified (contract 9) — DONE (R5)**

| Item | Value |
|---|---|
| Licence | **MIT** (GitHub licence API for `winsw/winsw`, SPDX `MIT`) → redistribution permitted with notice retention |
| Description | "A wrapper executable that can run any executable as a Windows service, in a permissive license." |
| Version decision | **v2.12.0** (latest *stable*, 2023-01-28). v3 exists only as `3.0.0-alpha.*` prereleases → an alpha is not shippable to customers. Asset **`WinSW-x64.exe`** = self-contained .NET build (no .NET runtime dependency on the target); the small `WinSW.NET461.exe` variant was not needed |
| Artefact | `D:\R5Isolation\vendor\WinSW-x64-v2.12.0.exe`, 18,243,033 bytes (== GitHub release asset size), SHA-256 `05b82d46ad331cc16bdc00de5c6332c1ef818df8cefcd49c726553209b3a0da` |
| Authenticode | **NotSigned** (WinSW upstream ships unsigned builds) — recorded; final Setup.exe signing is contract 11 |
| Probes (REAL, unelevated, `D:\R5Isolation\winsw-probe\`) | `version` → `WinSW 2.12.0.0` exit 0 · `status` with the **committed `winsw/SupermarketProBackend.xml`** → `NonExistent` exit 0 (**config parses unmodified**) · `install` → exit 0 "installed successfully" · `uninstall` → exit 0, post-check error 1060 = removed. Anomaly to record: the shell token is **medium integrity** (`net session` denied) yet SCM accepted create/delete — mechanism unexplained; `sc.exe delete` from the same token was denied (access 5) while WinSW's own path succeeded |
| Not tested | starting the service, `NT AUTHORITY\NetworkService` runtime behaviour, ACL grant script — needs real service execution; rehearsal reports NOT TESTED (boundary 7) |
| Note | WinSW v2.12.0 has **no `run` console command** (`Unknown command: run`) → wrapper→child launch can only be proven via the installed service, not from a console probe |

### 1.4 Python runtime — **DECIDED + GATED (contract 1) — DONE (R5)**

| Fact | Value |
|---|---|
| Dev environment | `.venv` base = **Microsoft Store** Python `3.10.11` (`pyvenv.cfg` → `…WindowsApps\PythonSoftwareFoundation.Python.3.10_qbz5n2kfra8p0`) → **not shippable / not relocatable** |
| Python 3.10 status | 3.10 reached **EOL 2026-10-01**; the only 3.10 Windows installer is 3.10.11 |
| Chosen payload | **CPython 3.13.17** official runtime **zip** `python-3.13.17-amd64.zip` (from python.org `index-windows.json`, the only artifact type python.org publishes SHA-256 for), SHA-256 `b26ca4b4ee51e157836049934d2b8eabd55939be296f3130254251b6df96ec2f` **verified locally**, extracted to `D:\R5Isolation\tools\py313\` and shipped as **payload files** (no vendor installer runs on the target) |
| Licence | PSF License — `LICENSE.txt` ships inside the extracted runtime |
| Gate (full backend suite on 3.13.17) | `17 failed, 3708 passed, 1646 skipped, 1477.89s` — **baseline-equivalent**: the 17 failures are the pre-existing stale `HEAD_REV` pins, skips identical to baseline, +10 passed = the tests added by R5 |
| Runtime handoff | `run_production.py --check` = **exit 0** on the offline venv; with a `database.env` present `database_url_source` = `"database_env"` (live proof) |

### 1.5 Other vendor items still to verify

Flutter/VC++ runtime (Phase-0: *"also ship the VC++ runtime if absent — UNVERIFIED"*),
Microsoft `VC_redist.x64.exe` redistribution terms, and code-signing of the final Setup.exe.
→ contracts 7, 13.

---

## 2. Architecture (production)

```
C:\Program Files\Supermarket Pro\            <- install tree, read-only at runtime (R1)
├── app\                                     <- Flutter Release folder, as-is
│   └── supermarket_pos.exe
├── backend\                                 <- BACKEND_ROOT
│   ├── python\                              <- bundled CPython (contract 1: layout TBD)
│   ├── .venv\Scripts\python.exe             <- service executable (pinned by test_service_winsw)
│   ├── run_production.py, alembic.ini, pyproject.toml, migrations\
│   ├── app\  (customer_package.json boundary)
│   ├── winsw\SupermarketProBackend.xml      <- template, paths patched at install time
│   └── installers\  (staging is NOT here — see below)
├── vendor\                                   <- 3rd-party notices, PG installer payload, VC redist
└── SupermarketPro-Backend.exe               <- renamed WinSW wrapper

C:\ProgramData\SupermarketPro\               <- DATA_DIR, all writes (R1)
├── config\ .env (installer)  secrets.env (R2)  database.env (R3)
├── license\  data\  backups\  logs\
├── installers\postgresql-18.6-5-windows-x64.exe   <- R3 staging dir (must be OUTSIDE Program Files;
│                                                       test_staged_installer_location_is_outside_the_install_tree)
└── pgdata\18\  (or ProgramData\SupermarketPro\postgres\data — contract 5)
```

| Concern | Value |
|---|---|
| Services | `SupermarketProBackend` (WinSW, `NT AUTHORITY\NetworkService`, delayed auto-start, no password in XML) + `postgresql-supermarketpro-<major>` (EDB installer) |
| HTTP | `HOST`/`PORT` from `<DATA_DIR>\config\.env`; default `127.0.0.1:8000` (desktop) / `0.0.0.0:8000` (LAN) |
| UDP discovery | `DISCOVERY_PORT` = same number as HTTP (8000) |
| Firewall (gate G-FW / G-24) | **installer action**: scoped inbound **TCP 8000 + UDP 8000**, created only in LAN mode, production build only |
| Launcher exit codes | `0/1/2/3/4` (`run_production.py:55-59`) — the installer's health gate uses `--check` → `0` |
| ACL | `winsw/grant_data_dir_acl.ps1` executed by the installer **once**, before service registration (refuses a data root inside Program Files) |
| Backend ↔ Flutter | Flutter never spawns the backend; it calls `http://localhost:8000` (`lib/core/constants.dart:17`). No static file serving exists anywhere in the backend. |

---

## 3. Install modes

| Mode | Trigger | Behaviour |
|---|---|---|
| **M1 Fresh install** | no prior install key, no reusable PG | discover → none → stage+verify PG installer → dedicated install (gated) → `provision_database()` (DB, role, `alembic upgrade head`, RBAC) → write `.env` → ACLs → register WinSW → optional firewall → shortcuts |
| **M2 Reuse** | compatible running PG 13–18 found | no PG install; `provision_database()` reuses it; port conflict → fail with an actionable message (Phase-0: conflict handling = new development) |
| **M3 Upgrade** | install key present, newer version | stop services → replace files → **preserve `DATA_DIR` entirely** → pre-migration backup `backups/pre_migrate_<ver>_<ts>.sql` → `alembic upgrade head` → health `/api/v1/health/ready` → restart. License state, DB and backups are never overwritten |
| **M4 Reinstall** | uninstall then install | uninstaller removed program files **and `<LICENSE_STATE_DIR>`** (→ new trial, licensing audit T8) but preserved `postgres\data` + `backups`; the new install **must create a NEW empty database identity** and must not adopt the old one (binding decision **C1**) |
| **M5 Uninstall** | user action | remove program files + service; **DB and backups preserved by default**; an explicit *"Also remove store data"* checkbox is **unchecked by default**; refuse to delete the PG data directory unless a `pg_dump` has been offered (Phase-0 §2.3 hard rule) |

---

## 4. Install sequence (production)

1. Verify payload integrity (bundled artefact SHA-256 pins).
2. Create `DATA_DIR` tree + run `grant_data_dir_acl.ps1` (SYSTEM/F, Administrators/F, service account/M; install tree RX for the service account).
3. Install bundled CPython (all-users, no PATH pollution) → create `.venv` → install **offline wheelhouse** (`pip install --no-index --find-links`).
4. Copy backend payload honouring `customer_package.json` include/exclude/forbidden rules (no `tools/`, `tests/`, `.env`, key material).
5. Copy Flutter Release folder as-is.
6. Stage the PG installer into `<DATA_DIR>\installers\` and pin its SHA-256.
7. Generate the DB password (≥8 URL-safe chars, R3 validation).
8. Write `<DATA_DIR>\config\.env` from `production.env.example` with real values, `APP_ENV=production`, `LICENSE_ENFORCEMENT=on` (contract 4).
9. Run the R3 provisioning pass: `provision_database(app_url=…, admin_url=…, app_password=…)` → creates role/DB, runs migrations, seeds RBAC, writes `database.env`.
10. Register + start `SupermarketProBackend`, then `--check` → exit 0, then `/api/v1/health/live`.
11. Firewall rules (LAN mode only).
12. Shortcuts + uninstall entries.

---

## 5. Provisioning API actually invoked (R3 contract)

```python
provision_database(
    app_url="postgresql://<role>:<pw>@127.0.0.1:<port>/<dbname>",
    admin_url=...,            # maintenance creds; ONLY from PG_ADMIN_URL, never settings.DATABASE_URL
    app_password=<pw>,        # -> ensure_role() + database.env
    apply_migrations=True, initialize_rbac=True,
    instances=...,            # explicit instance list ONLY in rehearsal (contract 14)
)
```
Execution gates for a dedicated install (`postgres_provisioning.py:702-734`), all four required:
`execute=True` **and** `R3_ALLOW_POSTGRESQL_INSTALL=1` in the **process environment**
(never from `.env`) **and** `verify_installer()` SHA-256 match **and** an explicit `runner`.
`install_dedicated()` / `plan_dedicated_install()` / `--plan` never execute anything by themselves.

---

## 6. RehearsalMode (compile-time)

**Mechanism.** `setup.iss` receives exactly one of `REHEARSAL` / `PRODUCTION` as an ISPP
`#define` from the build script:

```pascal
#if Defined(REHEARSAL) && Defined(PRODUCTION)
  #error REHEARSAL and PRODUCTION are mutually exclusive
#endif
#if !Defined(REHEARSAL) && !Defined(PRODUCTION)
  #error a build mode must be selected explicitly
#endif
```

Consequences: a normal production build **cannot** contain rehearsal behaviour (the rehearsal
path is compiled out, not toggled at run time), and a build with no explicit mode refuses to
compile. Output names differ (`SupermarketPro-Setup-REHEARSAL.exe` vs `SupermarketPro-Setup.exe`).

**Difference matrix:**

| Aspect | `PRODUCTION` | `REHEARSAL` |
|---|---|---|
| Install root | `C:\Program Files\Supermarket Pro` | `D:\R5Isolation\app` |
| `DATA_DIR` | `C:\ProgramData\SupermarketPro` | `D:\R5Isolation\data` |
| Privileges | admin (`PrivilegesRequired=admin`) | `lowest` → **no UAC** |
| Windows service registration | yes | **no** |
| Firewall rules | yes (LAN mode) | **no** |
| PG dedicated install | yes (official installer, gated) | **no** — isolated portable PG instead (§6.1) |
| ACL script | yes | yes (isolated tree only) |
| HTTP port | 8000 | **18000** |
| PostgreSQL port | 5432 (or detected) | **15432** |
| Python install | all-users | per-user into `D:\R5Isolation\app\python` (no UAC) |
| Licence enforcement | `on` | `on` (same code path) |

### 6.1 Isolated rehearsal database (never the development instance)

The development PostgreSQL instance must not be touched, and installing a Windows service /
running the EDB installer would require UAC. Therefore rehearsal provisions a **temporary,
non-service PostgreSQL process**:

1. Fetch + verify `postgresql-18.6-5-windows-x64-binaries.zip` against its published SHA-256 (§1.2).
2. Extract under `D:\R5Isolation\pg\` (pure file extraction — no UAC, no registry, no service, no PATH change).
3. `initdb` into `D:\R5Isolation\pgdata` with a generated password, start `postgres.exe -p 15432`
   as a child process of the rehearsal harness.
4. Feed R3 an explicit `PostgresInstance(major=18, service_state="RUNNING", port=15432, …)`
   (`postgres_discovery.py:124-125` defines `is_running` as `service_state.upper() == "RUNNING"`),
   so the real reuse/plan/migrate/RBAC code paths execute against the isolated server.
5. Teardown stops the process and leaves everything inside `D:\R5Isolation`.

**Honest limitation:** this exercises R3's plan/reuse/connectivity/`CREATE DATABASE`/migration/RBAC
code for real, but it does **not** exercise the EDB unattended installer execution (§1.2) —
that stays **NOT TESTED** in rehearsal because it requires elevation.

---

## 7. Unresolved integration contracts

| # | Contract | Owner / source | Risk | Planned resolution |
|---|---|---|---|---|
| 1 | **Backend runtime packaging method** — "frozen Python runtime … choice of freeze method = new development, UNVERIFIED until a prototype builds" | Phase-0 `:74-76` | High — the service cannot start without it; dev venv is Store-based and non-relocatable | **DONE (R5)** — bundled official CPython 3.13.17 runtime zip (SHA-256 verified) + `.venv` created by that runtime + offline wheelhouse (48 wheels); full backend suite gate passed (3708/1646/17 = baseline-equivalent) and `run_production.py --check` = 0 on the offline venv |
| 2 | **R3 unattended flags are non-official** (§1.2) | R3 `:590-635` | High — dedicated PG install would silently mis-target | **DONE (R5)** — corrected to `--unattendedmodeui none`, `--disable-components stackbuilder`, `--superaccount`, `--prefix`, `--enable_acledit 1`; pinned by `test_command_uses_only_official_edb_parameters` |
| 3 | **`database.env` is not wired into the launcher** — `run_production.py` must call `load_database_password(data_dir)` and publish `DATABASE_URL`; `PG_ADMIN_URL` only to the provisioning pass; `config.py` must never mention `database.env` | R4 §5 handoff, pinned by `test_secret_file_separation.py` | High — provisioning writes a password the app never reads | **DONE (R5)** — `_publish_database_url()` in `run_production.py`; new `tests/unit/test_database_env_handoff.py` (9 tests) + secret-separation/launcher suites green |
| 4 | **`LICENSE_ENFORCEMENT` must be `on` for the final commercial release** while the R4 template defaults to `trial` | R4 | Medium — shipping `trial` would freeze the licence layer at L1 | Set `on` in the generated `.env`; verify Lifetime **and** Trial flows before release |
| 5 | **PostgreSQL data/install directory conflict** — Phase-0/R1 prescribe `Program Files\SupermarketPro\PostgreSQL\<ver>` + `ProgramData\SupermarketPro\postgres\data`; R3's defaults are `<DATA_DIR>\pgdata\<major>` / `pgsql\<major>` | Phase-0 `:97-103`, R1 `:148` vs `postgres_provisioning.py:561-571` | Medium | Pass explicit `data_dir` / `install_dir` on the spec (Phase-0 wins); verify EDB `--prefix` + `--enable_acledit` against our stripped-inheritance tree **on an elevated machine** (not testable here) |
| 6 | **Firewall (gate G-FW)** — installer action, TCP+UDP 8000, LAN mode only | Phase-0 `:84,305`, Phase-16 `:1006` | Medium | Implement as `netsh advfirewall` in the production path only; rehearsal reports NOT TESTED |
| 7 | **VC++ runtime** — "ship the VC++ runtime if absent" is UNVERIFIED; Flutter Release needs `vcruntime140*.dll`, CPython/PG need their own | Phase-0 `:76` | Medium | Bundle `VC_redist.x64.exe` (Microsoft redistributable terms to be verified) or rely on `--install_runtimes 1` + Python's bundled runtime; verify absence detection |
| 8 | **Third-party notices obligation** — Inno (retain copyright + jrsoftware.org address), PostgreSQL/OpenSSL (retain notice), WinSW (MIT), Python (PSF), VC redist | §1 | Medium (licence compliance) | Ship `vendor\THIRD_PARTY_NOTICES.*` and surface it in the wizard + installed tree |
| 9 | **WinSW major version** (v2 .NET Framework vs v3 self-contained) and XML compatibility | R2 `:123`, winsw README | Medium | **DONE (R5)** — **v2.12.0 `WinSW-x64.exe`** (latest stable; v3 is alpha-only; self-contained .NET = no target runtime dependency), SHA-256 `05b82d46…a0da` pinned; committed XML parses unmodified (`status` probe) and installs/uninstalls for real (§1.3) |
| 10 | **Fresh-install database identity (C1)** — the installer must pick a NEW empty DB name and never adopt an existing data directory, while upgrades must find the right DB again | licensing audit `:874-898`, Phase-0 C1 | High (product/licensing correctness) | Decide the naming scheme (e.g. fixed name + `install_id` recorded in `data/server_id`) and encode fresh-vs-upgrade detection via Inno's install key |
| 11 | **Code signing of the final Setup.exe** (SmartScreen) | new | Medium | Out of R5 scope unless requested; record as open |
| 12 | **Interpreter version** — 3.10.11 is the only 3.10 installer and is EOL; 3.13.9/3.14.1 are supported but untested against the app | §1.4 | Medium | **DONE (R5)** — shipped as **3.13.17** (python.org manifest's latest `3.13-64`, SHA-256 pinned); full suite gate 3708 passed / 1646 skipped / 17 known failures = baseline-equivalent |
| 13 | **Offline wheelhouse** — no lockfile exists; deps in `pyproject.toml` are floor-pinned only | `pyproject.toml` | Medium | **DONE (R5)** — `requirements.lock.txt` (48 pins) generated **from the dev environment** (dev `pip freeze` used as constraints, per this contract); wheelhouse = 48 wheels / 23.7 MB; `pip install --no-index --find-links wheelhouse -r requirements.lock.txt` = exit 0; regeneration command recorded in the lock header and build script |
| 14 | **Rehearsal discovery shim** — R3 discovery only consults registry / `C:\Program Files\PostgreSQL*` / services, so a portable rehearsal server is invisible; rehearsal passes an explicit `instances=[…]` | `postgres_discovery.py:67-76` | Low (rehearsal-only) | Keep the shim in the rehearsal harness, never in the production installer path; report it as a rehearsal-only deviation |
| 15 | **Upgrade/pre-migration backup + health-gate sequence** (stop → backup → migrate → ready → start) | Phase-0 `:229,325` | Medium | Encode in the `[Run]`/`[Code]` upgrade path; test in rehearsal M3 |

---

## 8. Evidence log (Step 1)

| Action | Result |
|---|---|
| `Invoke-WebRequest` Inno 7.1.1 x64 + `.issig` | size 14,336,568; SHA-256 == GitHub release digest; Authenticode `Valid` / `Pyrsys B.V.`; manifest `asInvoker` |
| Inno silent per-user portable install | exit 0; `ISCC.exe` present (2,136,992 bytes), Authenticode `Valid` / `Pyrsys B.V.`; 26 files; `license.txt` present |
| ISCC smoke compile | `Successful compile (0.844 sec)`, `ISCC_EXIT=0` |
| Executed `r5-smoke.exe /VERYSILENT` | `SETUP_RUN_EXIT=0`; payload written; `[Run]` marker written (`ran=Mon 11/09/2026 11:40:17`); uninstall entry created |
| Fetched EDB `.sha256` sidecars **before** any installer download | installer `227e2bc0…10a58a`, binaries `e2246ba9…ad84e2` |
| Downloaded `postgresql-18.6-5-windows-x64.exe` | 414,966,472 bytes; local SHA-256 == published → **MATCH**; **never executed** |
| Fetched EDB `command_line_parameters` doc, REL-18 `installation-notes.html`, PostgreSQL licence, Inno `license.txt`/`setup.iss`/`isdl-verify.php` | §1.1/§1.2 conclusions |
| WinSW GitHub API | SPDX `MIT` |
| python.org HEAD probes | 3.10.11 ✅ (29,037,240 bytes), 3.10.12–22 ❌, 3.11.9/3.12.8/3.13.9/3.14.1 ✅ |
| Flutter release build (earlier) | `√ Built build\windows\x64\runner\Release\supermarket_pos.exe`, exit 0 |
| Downloaded + verified `python-3.13.17-amd64.zip` (31,162,518 B) | local SHA-256 == python.org manifest `b26ca4b4…6ec2f` → **MATCH**; extracted to `D:\R5Isolation\tools\py313\` (python.exe, python313.dll, Lib\venv, pip, LICENSE.txt) |
| `python -m venv` from the extracted runtime | works; venv `home` points at `D:\R5Isolation\tools\py313` |
| Lock generated from dev env (`pip install -r requirements.runtime.txt -c <dev freeze>` in a fresh venv) | exit 0; pinned versions match dev (fastapi 0.141.1, SQLAlchemy 2.0.54, starlette 1.6.0, …) → `requirements.lock.txt` 48 pins |
| First fresh-resolve attempt (no dev constraints) **rejected** | gate run 11 failed (fastapi 0.162 / SQLAlchemy 2.1 → `postgresql://` switched to psycopg3 → `_pg_available()` False → 157 PG tests skipped, `pymupdf` missing) → re-locked against dev constraints; also added `sqlalchemy<2.1` cap + `pymupdf`/`setuptools` dev extras to `pyproject.toml` |
| Wheelhouse `pip download -r requirements.lock.txt` | exit 0; 48 wheels, 23.7 MB |
| Offline install `pip install --no-index --find-links wheelhouse -r requirements.lock.txt` | **exit 0** on `venv-offline` (3.13.17) |
| Full backend suite on gate venv (3.13.17 + dev-pinned lock) | **`17 failed, 3708 passed, 1646 skipped, 1477.89s`** — identical 17 stale-`HEAD_REV` failures and identical skip count as the dev baseline (3698/1646/17); +10 = R5's new tests |
| `run_production.py --check` on `venv-offline` (no `database.env`) | **exit 0**; report `database_url_source: "dotenv"` |
| `run_production.py --check` with `database.env` present | **exit 0**; report `database_url_source: "database_env"` (R4 §5 handoff live) |
| Dev-venv sanity after `pyproject.toml` edits | boundary/license/handoff/separation/launcher suites = **152 passed** |
| Downloaded `WinSW-x64.exe` v2.12.0 | 18,243,033 bytes; SHA-256 `05b82d46…a0da`; Authenticode `NotSigned`; `version` → `WinSW 2.12.0.0` |
| WinSW probes with the committed R2 XML | `status` → `NonExistent` (config parses) · `install` → **exit 0, service created** · `uninstall` → **exit 0**, `sc query` → 1060 (gone); token was medium integrity — anomaly recorded in §1.3 |
| Downloaded `postgresql-18.6-5-windows-x64-binaries.zip` | 384,620,317 bytes; local SHA-256 `e2246ba9…ad84e2` == EDB publisher sidecar → **MATCH** |

---

## 9. Definition of done for R5 (rehearsal)

1. `setup.iss` + payload staging scripts + build script exist and compile under both modes.
2. The rehearsal `Setup.exe` is **executed** for: fresh install → backend start (`--check`=0 + health) →
   Flutter launch → upgrade → reinstall → uninstall, with data/backup preservation proven by hashes.
3. Every claim in the final report is tagged **REAL EXECUTED** / **SIMULATED** / **NOT TESTED**,
   with commands, exit codes and log excerpts.
4. Items that cannot be tested here (service registration, firewall, EDB installer execution,
   clean-machine install, ACL behaviour on Program Files) are reported as **NOT TESTED** with the
   reason (no UAC / no clean VM available), never as passed.
5. Verdict: `PASS` / `PASS WITH LIMITATIONS` / `FAIL`.

---

## 10. Rehearsal execution report (R5 step 2)

**Green run:** 2026-11-11 06:45:12 -> 06:47:58 (2m46s), isolation root `D:\R5Isolation`
**Harness:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\rehearsal_harness.ps1 -IsolationRoot D:\R5Isolation`
**Result:** `RESULT: ALL STEPS PASSED` (8/8 steps)

### 10.1 Artifacts under test

| Artifact | Size | SHA-256 | Executed? |
|---|---|---|---|
| `D:\R5Isolation\build\SupermarketPro-Setup-REHEARSAL.exe` | 447,842,345 B (427.1 MB) | `ede7235e8c33578ed6d283c07a2e8a5fc41227f414621e5260bd281c597a23d4` | **Yes** - all M1/M4/M5b runs (M0 re-verified the hash at run start) |
| `D:\R5Isolation\build\SupermarketPro-Setup.exe` (production mode) | 859,128,347 B (819.3 MB) | `6aaf9e2ce0d6c50808eb194e60d736dd9d81234acde1f5ede78a83b1b261e5c8` | **No** - compiled only (would require UAC; see NOT TESTED) |

### 10.2 Staging/build commands (all exit 0, `build_evidence.log`)

```
stage_payload.ps1 -IsolationRoot D:\R5Isolation -Mode Rehearsal    -> STAGING_OK, 2831 files, 502.3 MB
stage_payload.ps1 -IsolationRoot D:\R5Isolation -Mode PRODUCTION   -> STAGING_OK, 2832 files, 898.0 MB
build_installer.ps1 -IsolationRoot D:\R5Isolation -Mode Rehearsal  -> exit=0, 27.4 s, sha256 ede7235e... (2026-11-10 12:13:51)
build_installer.ps1 -IsolationRoot D:\R5Isolation -Mode Production -> exit=0, 47.7 s, sha256 6aaf9e2c... (2026-11-11 06:54:42)
```

### 10.3 Green-run step results (commands, exit codes, excerpts)

| Step | Tag | Result | Key evidence |
|---|---|---|---|
| M0-prep | REAL EXECUTED | PASS (06:45:12-31) | protected-artifact mtimes recorded; dev PG `STATE: 4 RUNNING`; own previous cluster `pg_ctl -m fast stop` **exit=0**; archive (never delete) `rehearsal-data.prev-20261111_064512`; PG zip pin `e2246ba9...` OK; `initdb` **exit=0**; postmaster direct-start; `pg_isready` within 30s; scram TCP auth OK; ports 18000/15432 free (LISTENING-only); no service registered |
| M1-install | REAL EXECUTED | PASS (06:45:31-06:46:17) | `Setup-REHEARSAL.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...` **exit=0** (46 s, Inno log `Installation process succeeded` + `Log closed.`); `install.txt seq=1 database=supermarket_pro`; `.env` `LICENSE_ENFORCEMENT=on`, `DATABASE_URL=...@127.0.0.1:15432/supermarket_pro` (no password), `PORT=18000`, `APP_ENV=production`; `database.env` carries `DATABASE_PASSWORD`; `provision_report.json` `"ok": true`; `install_steps.log`: `venv exit=0`, offline `pip exit=0` (20 s), `provision exit=0`, `run_production.py --check exit=0`, `=== install OK ===`; payload (venv/launcher/driver/flutter/notices) staged; isolated cluster: DB exists, **44 tables**; **no backup** on fresh install; **NO** service / WinSW XML / firewall rule |
| M2-backend-health | REAL EXECUTED | PASS (06:46:17-22) | launcher `run_production.py` (DATA_DIR pinned) pid 15368; `/api/v1/health/ready` **200** `{"status":"ready","database":"connected"}`; `/live` **200** (first boot 5 s) |
| M3-flutter-launch | REAL EXECUTED (launch only) | PASS (06:46:22-33) | `supermarket_pos.exe` alive after 8 s; window title `"supermarket_pos"`; clean terminate; **app-to-backend pairing NOT TESTED** (first-run wizard defaults to `http://localhost:8000`, pairing to 18000 not automated) |
| M4-upgrade | REAL EXECUTED (backup+identity) / SIMULATED (service stop) | PASS (06:46:33-06:47:00) | pre-upgrade `tables=44 seq=1 env_sha=6c0716b8...`; backend stopped by process kill **[SIMULATED service stop]**; `Setup` **exit=0** (22 s); `identity: upgrade, database=supermarket_pro`; **seq kept=1**; **`.env` byte-identical** (sha unchanged); backup `pre_migrate_20261111_064654.sql` **127,967 B** created; **no** `supermarket_pro_2`; tables **44 -> 44**; post-upgrade health **200/200** |
| M5-uninstall | REAL EXECUTED | PASS (06:47:00-06) | backend stop **[SIMULATED]**; `Unins000.exe /VERYSILENT` -> install tree **removed** (ground-truth poll: `wait-target-gone=True`); `install_seq.txt`=1 preserved; `.env` preserved; backup preserved (127,967 B); `license\` removed (fresh trial on reinstall); DB `supermarket_pro` preserved; **no** service after uninstall |
| M5b-reinstall-new-db | REAL EXECUTED | PASS (06:47:06-52) | `Setup` **exit=0** (46 s); `install.txt seq=2 database=supermarket_pro_2` **(contract 10)**; `install_seq.txt`=2; **old DB preserved + new DB created**; `.env` retargeted to `supermarket_pro_2`; backups preserved; health **200/200**; licence recreated (`hmac.key`, `trial.state`) |
| M6-cleanup-and-verify | REAL EXECUTED | PASS (06:47:56-58) | backend stopped **[SIMULATED]**; all 4 protected artifacts still present with **mtimes identical to M0** (`new_app_upload` 2026-10-26, `.zip` 2026-10-26, `tatus` 2026-11-01, dev `.env` 2026-10-03); dev PG **RUNNING** at end; port 18000 released (poll, LISTENING-only); environment left in place for inspection |

### 10.4 Tagged claim inventory

**REAL EXECUTED** (all with commands + exit codes above and in `rehearsal_evidence.log`):
silent fresh install, payload staging incl. offline pip install, DB provisioning (create role/database/migrations/RBAC = 44 tables), `run_production.py --check`, backend start + live HTTP health on 18000, Flutter packaged-app launch, upgrade with pre-migrate `pg_dump` backup + identity preservation + `.env` byte-identity, uninstall with data/backup/DB preservation, reinstall with new DB name (seq=2) + old DB preservation, licence-state delete/recreate, protected-artifact and dev-PG integrity checks.

**SIMULATED** (labelled in the log at every occurrence):
service stop = `taskkill` process kill (3 occurrences: M4 pre-upgrade, M5, M6/M5b) - WinSW `stop` is production-only and compiled out of the rehearsal build.

**NOT TESTED** (never claimed as passed):
1. **Windows service registration/start/stop (WinSW)** - production-only code compiled out; no UAC for service creation.
2. **Firewall rule creation (netsh)** - production-only, LAN_MODE-gated; not present in rehearsal build (verified absent).
3. **EDB PostgreSQL installer execution** (`R3_ALLOW_POSTGRESQL_INSTALL=1` path) - production-only; requires UAC elevation; never executed (vendor zip pin verified instead).
4. **Clean-machine install** - no clean VM available on this host; developer toolchain present.
5. **ACL hardening on Program Files / ProgramData** - production-only, needs elevation.
6. **App-to-backend pairing** - Flutter first-run wizard not automatable; launch-only (M3).

### 10.5 Defects found and fixed during rehearsal

Product fixes (both modes rebuilt after):
1. `setup.iss` `BuildEnvContent` wrote `PG_PORT=` (empty) -> `Settings.PG_PORT: int` crashed the provisioning driver at import. Fixed: `PG_PORT={#PgPort}` (15432 rehearsal / 5432 production), matching `DATABASE_URL`.
2. `installer_provision.py` imported `app.core.*` (which builds `Settings()` at import) before per-install secrets existed -> placeholder validator rejected `APP_ENV=production`. Fixed: `ensure_production_secrets(data_dir)` bootstrap before any `app.core` import, same order as `run_production.py` (generates `<DATA_DIR>/config/secrets.env` once, publishes via `os.environ`).

Harness fixes (script only, no rebuild): Inno Setup/uninstaller early-return + stale `$LASTEXITCODE` -> completion judged from Inno log `Log closed.` / install-tree ground truth; own-PG stop moved before the port check; `(?m)^...$` -> `\r?$` for CRLF files; `Get-TableCount` now queries `-d supermarket_pro`; message concats parenthesized; M6 port check = LISTENING-only + 15 s release poll.

### 10.6 Safety confirmation (from the green log itself)

- Protected artifacts: 4/4 present, mtimes byte-identical at start and end (see M0/M6 rows).
- Dev PostgreSQL `postgresql-x64-18`: `STATE: 4 RUNNING` at start and end; rehearsal used only `D:\R5Isolation\pg` (port 15432); dev instance untouched.
- No UAC/elevation used; no Git operations; no production private keys; no database/backup deleted (all superseded state archived as `*.prev-<timestamp>`).
- Only `D:\R5Isolation` written (plus read-only repo reads).

### 10.7 Evidence file index

| File | Content |
|---|---|
| `D:\R5Isolation\build\harness_console.log` | Full green-run console (176 lines, `RESULT: ALL STEPS PASSED`) |
| `D:\R5Isolation\build\rehearsal_evidence.log` | Structured per-step evidence (164 lines, tags per step) |
| `D:\R5Isolation\build\build_evidence.log` | Every stage/build command, exit code, duration, hash |
| `D:\R5Isolation\build\M1-setup_inno.log`, `M4-...`, `M5b-...` | Inno's own logs (identity, venv/pip/provision/check exit codes, `Log closed.`) |
| `D:\R5Isolation\data\logs\install_steps.log` | Installer step log (`install OK`, all child exit codes) |
| `D:\R5Isolation\data\logs\provision_report.json` | Provisioning report (`"ok": true`, revision `e5b7d2c9a41f`) |
| `D:\R5Isolation\data\backups\pre_migrate_20261111_064654.sql` | Upgrade backup (127,967 B) |
| `D:\R5Isolation\build\build_REHEARSAL.log`, `build_PRODUCTION.log` | Full ISCC compiler output |

### 10.8 Verdict

# **PASS WITH LIMITATIONS**

All rehearsal-scope requirements passed 8/8 on the actual compiled `Setup.exe`
(fresh install -> health -> Flutter launch -> upgrade+backup -> uninstall -> reinstall+new DB ->
cleanup), with data/backup/identity preservation and dev-environment integrity proven from logs.
The limitations are the six **NOT TESTED** items in 10.4 (service, firewall, EDB installer,
clean machine, Program Files ACL, app pairing) - all production-only or elevation/VM-gated;
they require an approved elevated/clean-VM production-run phase to be claimed.

