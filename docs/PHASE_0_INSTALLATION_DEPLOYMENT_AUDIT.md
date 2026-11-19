# Phase 0 — Installation and Deployment Audit

**Scope:** End-user installation, background services, remote connectivity, Android distribution, QR pairing, updates, and commercial deployment — for the **current** Supermarket Pro implementation.

**Status:** architecture audit only. No source code, database, migration, configuration, installer, service, or deployment change is made or implied by this document. Every external pricing, licensing, redistribution, or vendor-policy claim is marked **UNVERIFIED** unless it is quoted from current official vendor documentation and even then must be re-checked at procurement time.

**Evidence basis:** all file paths and line numbers below were verified against this repository at the time of writing. Where a claim needs runtime, hardware, legal, or vendor confirmation it is tagged **UNVERIFIED**.

**Citation convention:** full paths are given at first use; short forms such as `config.py`, `seed.py`, `health.py`, `main.py`, `rate_limit.py`, `logging.py`, `db_dump.py`, `server_identity.py`, `responder.py`, `alembic.ini`, or bare `devices.py` refer to files under `new_app/backend/` (e.g. `app/core/config.py`, `app/services/devices.py`). `api/v1/devices.py` and `api/device_guard.py` always name the HTTP router/guard explicitly. Doc citations (`docs/...`) are always full repository paths.

---

## 0. Which application this audit covers

Two applications live in this repository. This audit concerns **only the current implementation**.

| | Legacy reference application | Current Supermarket Pro |
|---|---|---|
| Location | `reference/` docs + `python_app/` | `new_app/` |
| UI | CustomTkinter desktop | Flutter Windows desktop (`new_app/windows/`) |
| Backend | none for the main runtime; a small legacy Flask sidecar (`python_app/server/server.py`) | FastAPI service (`new_app/backend/app/main.py`) |
| Database | MySQL/MariaDB via PyMySQL | PostgreSQL via SQLAlchemy + Alembic (`new_app/backend/`) |
| Pairing | UDP broadcast on port 50000, direct shared DB | Phase 16 device pairing with one-time tokens (`new_app/backend/app/services/devices.py`) |
| Evidence | described in `docs/PHASE_0_MASTER_SPECIFICATION.md:5` | `docs/PHASE_15_PRINTING_EXPORTS_ANALYSIS.md:44` (`new_app/backend/` = "Modern FastAPI backend") |

Rules this audit follows:

1. No recommendation inherits an assumption from `python_app` (no MySQL, no Flask, no Tkinter, no shared-database clients).
2. `new_app_upload/` and `new_app_upload.zip` are untracked export snapshots and are **out of scope** (`docs/PHASE_15_PRINTING_EXPORTS_ANALYSIS.md:50` classifies stale root artifacts similarly; `new_app/` is the tracked, canonical tree).
3. Stale root artifacts (`MANIFEST.md`, `README.md`, dependency maps) are not used as evidence.

---

## 1. Finding — packaging is a roadmap gap, not a completed phase

Packaging was deferred by Phase 16 and then explicitly excluded by Phase 17, leaving no scheduled owner:

| Statement | Location |
|---|---|
| G-26 "Server auto-start/packaging" = **DEFERRED → Phase 17/installer** | `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1100` |
| Firewall automation (gate G-FW) = **installer action, deferred** | `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1006` |
| "**Scope honoured:** no installer, no `.exe`/packaging, no cloud/WAN" | `docs/PHASE_17_IMPLEMENTATION.md:6` |
| "Installer, packaging, `.exe`, firewall automation \| explicitly outside Phase 17 scope" | `docs/PHASE_17_IMPLEMENTATION.md:317` |
| "Installer / packaging / EXE build … out of scope" | `docs/POST_PHASE_17_MANUAL_QA.md:10` |
| "Installer/service auto-start packaging — explicitly out of scope for this round" | `docs/POST_PHASE_17_MANUAL_QA.md:682` |

Repository evidence confirms the gap:

| Artifact | State |
|---|---|
| Installer scripts (`.iss`, `.nsi`, `.wxs`), build scripts (`.bat`, `.ps1`), CI (`.github/workflows`) | **none exist** in the repository |
| Windows service / Task Scheduler entry / autostart | **none** |
| Android platform folder (`new_app/android/`) | **does not exist** (verified: `Test-Path` = false) |
| QR generation/scanning packages in use | **none** — no `qr_flutter`/`mobile_scanner` imports anywhere under `new_app/lib/` |
| Release output today | a folder copy: `new_app/build/windows/x64/runner/Release/` (`supermarket_pos.exe` + `flutter_windows.dll` + plugin DLLs + `data/`) per `new_app/windows/CMakeLists.txt:75-106` |

The current documented way to run the product is a developer command sequence (`docs/POST_PHASE_17_MANUAL_QA.md:20-36`): activate env vars, launch `uvicorn` by hand, run the Flutter exe. That is not an end-user experience.

---

## 2. Windows installer feasibility

### 2.1 Tool evaluation

| Tool | Verdict | Reason |
|---|---|---|
| **Inno Setup** | **RECOMMENDED** | Free, mature, produces a single `SupermarketPro-Setup.exe`, Pascal scripting supports prerequisite installation, Windows service registration, firewall rules, first-run wizard hooks, and careful uninstall logic. Flutter's own distribution guide lists Inno Setup as an appropriate wrapper for the Windows build output (official `docs.flutter.dev` distribution guidance — **UNVERIFIED** for exact current recommendations). |
| WiX Toolset | Rejected (for now) | MSI-based, enterprise-oriented, steeper learning curve; our install flow (nested PostgreSQL install, service setup, data-preserving uninstall) is simpler to express in Inno Setup. Revisit only if enterprise MSI deployment becomes a requirement. |
| MSIX | Rejected | Package-identity sandboxing is a poor fit for a product that must install a database server, register Windows services, and write to arbitrary data directories; requires code signing and either Microsoft Store submission or `.appinstaller` update infrastructure (Microsoft packaging docs — **UNVERIFIED** for our specific constraints). |
| NSIS / zip folder | Rejected | NSIS is capable but Inno Setup's scripting is more approachable; a bare zip has no service, prerequisite, or uninstall story. |

### 2.2 What the installer must package

| Component | Source of truth today | Packaging action |
|---|---|---|
| Flutter Windows app | `new_app/build/windows/x64/runner/Release/` — `supermarket_pos.exe`, `flutter_windows.dll` (~21 MB), `data/app.so` AOT, `pdfium.dll`, plugin DLLs (`flutter_secure_storage_windows_plugin.dll`, `printing_plugin.dll`, `dartjni.dll`), per `new_app/windows/CMakeLists.txt:75-106` | Ship the whole Release folder as-is; also ship the VC++ runtime if absent (Flutter Windows docs — **UNVERIFIED** requirement on target machines) |
| FastAPI backend | `new_app/backend/app/` + `pyproject.toml` dependencies (fastapi, uvicorn, sqlalchemy, alembic, psycopg2-binary, cryptography-backed `python-jose`, argon2, reportlab, arabic-reshaper, python-bidi, openpyxl — `new_app/backend/pyproject.toml:6-25`) | Package a frozen Python runtime (PyInstaller onedir **or** embedded CPython + pre-installed wheels). Native extensions (`psycopg2-binary`, `pydantic_core`, `cryptography`, `argon2-cffi-bindings`, `greenlet`) make a from-source build on the customer machine unacceptable; pre-built wheels for CPython 3.10 x64 must be bundled. **Choice of freeze method = new development, UNVERIFIED until a prototype builds.** |
| Python dependencies | No `requirements.txt` for the backend; `pyproject.toml` only | Freeze into the bundle; pin exact versions at build time |
| PostgreSQL | Not shipped at all today; backend assumes an existing server (`new_app/backend/.env.example:27`) | See §3 — installer runs the official PostgreSQL Windows installer silently |
| Database schema | 37 Alembic revisions in `new_app/backend/migrations/versions/`, run manually (`alembic upgrade head`) | Installer (or first service start) runs migrations after creating the database |
| RBAC seed | `new_app/backend/app/core/seed.py:21` — "NOT executed at application startup" | Run once during install (idempotent `run_seed()`, `seed.py:168`) |
| Backend configuration | `.env` resolved **relative to process CWD** (`new_app/backend/app/core/config.py:29`), `DATABASE_URL` mandatory (`config.py:41`) | Installer generates `.env` with a per-install random `APP_SECRET_KEY`/`JWT_SECRET_KEY`, a generated DB password, and absolute paths; service sets working directory explicitly |
| Server identity | `SERVER_ID_FILE=data/server_id` is a **relative** path (`new_app/backend/app/core/server_identity.py:70`) | Pin to an absolute path in the generated `.env` to avoid CWD drift |
| Firewall | First LAN-mode start triggers a Windows Firewall prompt for TCP 8000 + UDP 8000 (`docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1006`) | Installer adds scoped inbound rules (installer action, gate G-FW) |
| Automatic startup | none | Installer registers services (§4) and optional user logon shortcut for the desktop app |
| Logging | stdout only — `structlog` Console/JSON renderer to stderr/stdout (`new_app/backend/app/core/logging.py:32,40`); **no file handler** | Service wrapper redirects stdout to rotating files, or backend gains a file sink (**new development**) |
| Local backups | `new_app/backend/app/services/backup.py:106,113-114` — default `backend/backups/` directory; API-triggered only (`new_app/backend/app/api/v1/backups.py:71,156`) | Relocate to `ProgramData\SupermarketPro\backups`; add scheduled backup task (**new development**) |

### 2.3 PostgreSQL deployment decision

| Option | Assessment |
|---|---|
| **A. Fully embedded PostgreSQL binaries inside our bundle** | Rejected as primary. We would own service registration, `initdb`, security updates, and major-version upgrades ourselves; the backup code already probes `C:\Program Files\PostgreSQL\<ver>\bin` for `pg_dump`/`psql` (`new_app/backend/app/core/db_dump.py:16-19,44-45`), so an unusual install layout would break backups unless `PG_DUMP_PATH`/`PSQL_PATH` are always set. |
| **B. Official PostgreSQL Windows installer run silently by our setup — RECOMMENDED** | Our Inno Setup script invokes the official EDB/PostgreSQL Windows installer in unattended mode, into a dedicated directory and data directory, registers its own Windows service, then runs `createdb` + Alembic. Silent-install switches are documented by PostgreSQL/EDB (`--mode unattended`, `--unattendedmodeui none`, `--superpassword`, `--serverport`; official PostgreSQL wiki/EDB documentation — **exact flags UNVERIFIED for the current major version and must be validated before packaging**). Redistribution of the installer binary: PostgreSQL license is permissive, but **redistributing the EDB installer package inside a commercial product = UNVERIFIED, legal review required**. |
| C. Docker / external DBA-managed instance | Rejected: requires Docker or manual DBA work — violates the "no technical knowledge" requirement. |

**Recommended option B rules (safety):**

- Install to `C:\Program Files\SupermarketPro\PostgreSQL\<ver>` with data in `C:\ProgramData\SupermarketPro\postgres\data` (never inside Program Files).
- Bind **localhost only** — consistent with the Phase 16 decision that PostgreSQL "bind stays localhost (never LAN-exposed)" (`docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1004`).
- Detect an existing PostgreSQL on port 5432 and either use a dedicated port or refuse with a clear message — **conflict handling = new development**.
- **Upgrade:** never overwrite the data directory; a PostgreSQL major-version upgrade = dump/restore using the existing `pg_dump` path (`new_app/backend/app/core/db_dump.py`).
- **Uninstall (hard rule):** uninstalling Supermarket Pro **must never silently delete the customer's database or backups**. The uninstaller leaves `ProgramData\SupermarketPro\postgres\data` and `ProgramData\SupermarketPro\backups` in place, shows an explicit checkbox (default **unchecked**) "Also remove store data", and refuses to remove the PostgreSQL data directory while a `pg_dump` of the current database has not been offered. This rule is a **product requirement**, not an existing behavior — today no uninstaller exists at all.

---

## 3. Remote connection setup experience

### 3.1 What exists today

- The architecture is deliberately **LAN-only, no WAN, no TLS**: `new_app/backend/.env.example:73` — "Never forward the service port to the Internet (owner Q5)"; `new_app/backend/app/core/config.py:91-93` — "LAN-only: this phase never exposes the service to WAN/Internet".
- Desktop default base URL is `http://localhost:8000` (`new_app/lib/core/constants.dart:17`); LAN clients use `http://<ip>:8000` built by discovery (`ServerOffer.baseUrl`).
- No VPN, gateway, tunnel, WebSocket, or push code exists anywhere in `new_app/` (grep for `tailscale|wireguard|vpn|ngrok|cloudflared` returns only legacy interface-filter strings in `python_app/`).
- **There is no remote-access feature today.** Everything in this section beyond LAN pairing is a *proposal*.

### 3.2 Option comparison

| Option | Setup complexity for the customer | Pros | Cons |
|---|---|---|---|
| **Tailscale** (installed on store PC + owner phone) | Low *if pre-configured*: silent MSI install is supported (`msiexec /i tailscale-*.msi /quiet`, properties like `TS_UNATTENDEDMODE`, `TS_ONBOARDING_FLOW=hide` — official `tailscale.com/docs/install/windows/msi`), and `tailscale up --auth-key=…` avoids interactive login (official auth-key docs) | Mature NAT traversal, WireGuard-based, no router configuration, Android app exists | Requires a **tailnet account**; device approval/key expiry policy; commercial use of the free Personal plan is **explicitly excluded** ("only suitable for non-commercial use" — official `tailscale.com/pricing` FAQ); each store ideally its own tailnet **or** one vendor tailnet with tags/ACLs; distribution of the client inside our installer + trademark = **UNVERIFIED**; coordination-server dependency and reachability from Algeria = **UNVERIFIED**; the owner must also install the Tailscale app on the phone (breaks the "one app" ideal) unless we ship a second APK or deep-link guidance |
| **WireGuard (self-operated)** | High | Free, open source, fast | No key distribution, no NAT traversal, no coordination — we would have to build a controller and likely a relay anyway; manual config on phones is unacceptable for the target customer |
| **Dedicated gateway / relay (PROPOSED — does not exist)** | Low (if bundled) | One vendor-operated component; store PC makes an **outbound** connection only (no port forwarding, works behind CGNAT/any router); phone connects to the gateway with the paired device token; no customer accounts, no VPN knowledge; we control licensing and cost | **Requires new development** (agent on the store PC, gateway service, relay infrastructure, TLS, per-store routing, offline behavior). Recurring server cost (**UNVERSED — vendor verification required**). Single point of failure for *remote* access only — local POS keeps working when the gateway or internet is down |
| Third-party tunnels (ngrok, cloudflared, frp-as-a-service) | Low | Fast to prototype | Commercial redistribution/resale terms **UNVERIFIED**; dependency on another vendor's SaaS; not appropriate to embed in a sold product without legal review |

### 3.3 Recommendation

1. **Today (achievable):** ship LAN-only remote *within the store network* — already implemented (Phase 16 pairing + device guard).
2. **Target architecture (new development):** a **dedicated vendor-operated gateway** as the *only* path that satisfies "owner scans one QR and accesses the store from anywhere" without customer VPN accounts, per-store router configuration, or third-party VPN licensing. This is a **proposed future component, not an existing feature.**
3. **Tailscale is a viable bootstrap candidate**, conditional on: (a) legal confirmation that bundling/redistributing the client is permitted (**UNVERIFIED**), (b) a paid plan or vendor-owned tailnet because commercial use of the free plan is excluded (**official pricing page; plan selection UNVERIFIED**), (c) confirmation that the coordination/DERP infrastructure is reachable acceptably from Algeria (**UNVERIFIED**), and (d) an acceptable phone-side install step for the owner.

---

## 4. Automatic background services

### 4.1 Current state

The backend is a manually launched uvicorn process. There is no service wrapper, no autostart, no crash recovery. Additional constraints that any service design must respect:

| Constraint | Evidence |
|---|---|
| **Single worker only** — rate limits and pairing state are process-local | `new_app/backend/app/core/rate_limit.py:13` ("State is process-local… a single uvicorn worker"); `new_app/backend/app/services/devices.py:121` ("Process-local state (single worker; no new tables in Phase 16)") |
| Bind address comes from the **CLI flag**, not `HOST` in `.env` | `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md` documents `uvicorn … --host 0.0.0.0 --port 8000`; `settings.HOST` (`config.py:73`) is not used for binding |
| `.env` and `data/server_id` are CWD-relative | `config.py:29`, `server_identity.py:70` |
| Logs go only to stdout/stderr | `logging.py:32,40` — no file handler |
| Migrations and RBAC seed are manual pre-start steps | `alembic.ini:5` (`script_location = migrations`), `seed.py:21` |
| Health endpoints exist and are suitable for probes | `GET /api/v1/health` (`health.py:48`), `/health/live` (`:71`), `/health/ready` with `SELECT 1` (`:80-96`); prefix `/api/v1` from `main.py:68` |
| Backend lifespan already starts/stops the UDP discovery thread | `main.py:17,26` (`start_discovery()`), daemon thread `responder.py:115` |
| Doc drift: `docs/PHASE_1_SETUP.md:68` says `/health`; real path is `/api/v1/health` | fix in documentation during packaging work |

### 4.2 Recommended service architecture

| Service | Wraps | Notes |
|---|---|---|
| `SupermarketPro-PostgreSQL` | official PostgreSQL service (option B, §2.3) | installed by the setup program |
| `SupermarketPro-Backend` | frozen/packaged uvicorn, **single worker**, working directory pinned | depends on the PostgreSQL service (`sc config depend=`); before serving: wait for DB readiness, run pre-migration backup, run `alembic upgrade head`, then bind `127.0.0.1:8000` (desktop) or `0.0.0.0:8000` (LAN server mode) |
| `SupermarketPro-Gateway` | **PROPOSED — does not exist**; only if the dedicated gateway (§3) is built | outbound-only agent |
| Notification worker | **does not exist** (no Celery/APScheduler/push anywhere in `new_app/backend/`) | recommend implementing scheduled jobs (backups, retention) **inside** the backend process (single process, process-local state) rather than as a separate service, until there is a proven need |

**Wrapper choice:** a small service wrapper such as **WinSW or NSSM** (both free, widely used) wrapping the packaged Python executable. Both support: automatic restart on crash, startup type Automatic, stdout/stderr redirection to files, and dependency ordering. Windows SCM recovery (restart 1st/2nd/3rd failure) is configured on top. **Choice between WinSW/NSSM and exact flags = UNVERIFIED until prototype.**

**Requirements checklist:**

| Requirement | How it is met |
|---|---|
| Start after boot | Service `StartupType=Automatic` (delayed start preferred so PG is up) |
| Restart after crash | Wrapper auto-restart + SCM failure actions (restart every N seconds) |
| Service account | Dedicated low-privilege virtual service account (or `NetworkService`) with write ACL only on `ProgramData\SupermarketPro` — **exact ACL design = new development**; never LocalSystem for the app process |
| Startup ordering | Backend service `depend=` PostgreSQL; plus an application-level readiness wait loop calling `/api/v1/health/ready` before accepting traffic |
| Health checks | Wrapper `reset`/`restart` on repeated health failures; desktop already polls `/api/v1/health` every 10 s (`new_app/lib/features/devices/connection_provider.dart:8`) |
| Graceful shutdown | uvicorn handles SIGTERM/CTRL_BREAK via lifespan shutdown (`main.py:17`) — **behavior under WinSW/NSSM on Windows = UNVERIFIED, must be tested** (discovery thread stop: `main.py` lifespan) |
| Update without data loss | Stop service → replace program files → pre-migration backup → migrate → start (§7) |
| Local POS works without internet | All components are on the store PC; nothing in the startup path may require WAN connectivity (**current code has no WAN dependency — verified by design statements in `config.py:91-93`**) |

---

## 5. QR pairing and customer onboarding

### 5.1 What already exists (Phase 16 — current implementation)

| Element | Implementation | Evidence |
|---|---|---|
| Pairing code | 6-digit random code, `secrets.randbelow(1_000_000)`, TTL **600 s** | `devices.py:44,136-137` |
| Single-use token | minted on approval, delivered once via polling vault, TTL **600 s**, then discarded | `devices.py:45,167-199` (`_TokenVault.take()` removes on first read) |
| At-rest storage | **only SHA-256 hash** of the device token persisted | `devices.py:11,349` (`device.token_hash = hash_token(token)`); model `token_hash` `models/device.py:67` |
| Owner approval | admin approve/deny endpoints; `approved_by` FK recorded | `api/v1/devices.py:212,230`; `models/device.py:74` |
| Revocation | sets status REVOKED **and clears `token_hash`** so the credential can never match again | `devices.py:396-413` |
| Rate limiting | per-IP and global pairing attempt limits | `api/v1/devices.py:117`; limiter objects `services/devices.py:203-204` |
| Enforcement | `device_guard` on every `/api/v1` route when `LAN_MODE=1`; loopback exempted for the local POS | `api/v1/router.py:52`; `api/device_guard.py:89,188` |
| Client flow | Flutter posts `/api/v1/devices/pair` with `client_version`, polls `/api/v1/devices/pairings/{id}` | `connection_provider.dart:529,533,596` |
| Unpaired redirect | router forces `/setup-network` when unpaired | `lib/router/app_router.dart:142` |
| Desktop credential storage | JWT + device token in `flutter_secure_storage`; device token survives logout | `credential_storage.dart:4,14,66` |

### 5.2 Gaps against the stated requirements

| Requirement | Status |
|---|---|
| Short-lived codes | ✅ 600 s TTL exists |
| Random, single-use tokens | ✅ exists (in-memory vault + hash-only persistence) |
| Owner authorization | ✅ approve/deny exists; **but pairing-code generation should be gated behind an owner session on the desktop** — verify current gating **UNVERIFIED** |
| Device bound to a specific store and user | ⚠️ store binding = `server_id` handshake exists; **device→user binding for employees is not implemented** (Device model has no user FK — `models/device.py:31-85`) |
| Owner can revoke | ✅ implemented (`devices.py:396`) |
| No DB credentials / API secrets in the QR | ✅ design already avoids this; QR must carry only a pairing code + `server_id` + address |
| Employee devices get only their permissions | ⚠️ permissions come from the **login user** (`auth_provider` scopes), not the device; needs explicit design so a paired employee device is bound to a user account |
| Pairing survives backend restart | ❌ pairing code + token vault are **process-local** (`devices.py:121`) — a restart mid-pairing drops the code (acceptable: user regenerates) but this must be documented |
| QR rendering/scanning | ❌ no packages in use; **new development** (`qr_flutter` on desktop, a camera scanner on Android) |

### 5.3 Proposed pairing lifecycle (design for implementation later)

1. Owner logs into the desktop POS with PIN (existing auth).
2. Desktop requests `GET /api/v1/devices/pairing-code` (existing endpoint `api/v1/devices.py:185`) — server rotates a fresh 6-digit code (existing behavior, `api/v1/devices.py:196` "Rotate the code on every call").
3. Desktop renders a **QR containing only**: `smp://pair?code=123456&server=<server_id>&addr=<host:port>&v=1` — no secrets, no tokens, no database information.
4. Owner opens the Android app → scans (or types the code) → app calls `POST /api/v1/devices/pair` with code, device name, `client_version` (existing contract, `connection_provider.dart:529-533`).
5. Desktop shows a pending-device prompt; owner approves (existing approve endpoint). Optionally the desktop asks *which user* this device is for (new: employee binding).
6. Server mints a single-use device token; the app retrieves it once via the polling endpoint; the server persists **only the SHA-256 hash** (existing).
7. App stores the token in platform secure storage (existing pattern, `credential_storage.dart:14`); all API calls then present `X-Device-ID` + `X-Device-Token` (device guard) **and** a user JWT for permissioned actions.
8. Owner can list/revoke devices at any time (existing list/revoke endpoints `api/v1/devices.py:168,250`); revocation clears the hash so the phone is locked out on next guard check.
9. Re-pairing a replaced phone = revoke + repeat from step 2.

**QR must never contain:** database URLs, passwords, JWT secrets, gateway credentials, or long-lived tokens — none of which exist in the current pairing payload anyway.

---

## 6. Updates and maintenance

| Layer | Proposed update mechanism | Backup / rollback |
|---|---|---|
| Desktop Flutter app | New `SupermarketPro-Setup.exe` with the same Inno Setup `AppId` runs as an upgrade: stop app → replace files → preserve `ProgramData` → finish. Desktop also displays its version (pubspec `1.0.0+1`, `new_app/pubspec.yaml:4`) | No user data lives in Program Files; settings are in the DB / `ProgramData` |
| FastAPI backend | Same installer replaces the frozen backend; service restarted | See migrations row |
| PostgreSQL schema | Installer/service-start sequence: **(1)** automatic `pg_dump` to `backups/pre_migrate_<version>_<ts>.sql` using the existing dump path (`db_dump.py:167+`, `backup.py`), **(2)** `alembic upgrade head`, **(3)** verify `/api/v1/health/ready`. If step 2 fails: stop, keep the backup, roll back the *program* to the previous version, and offer restore through the existing restore endpoint (`api/v1/backups.py:156`) | **Rollback caveat:** many Alembic revisions are not safely reversible; the supported rollback is **restore-from-backup**, not `alembic downgrade` — **UNVERIFIED per-revision** |
| Android app | Versioned APK; in-app update check against the gateway or a download endpoint (**new development**); Play Store optional later | n/a |
| Gateway (proposed) | Rolling service update; never touches the local DB | n/a |
| Version compatibility | Pairing already records `client_version` (`connection_provider.dart:533`, model `client_version` `models/device.py:62`) and there is a `lan_version_mismatch` UX string; backend `VERSION="0.1.0"` (`config.py:38`) vs Flutter `1.0.0+1` is discrepancy **D-05** (`docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1146`) — packaging work must introduce one aligned version/protocol number (**new development**) | Fail fast with a clear "please update" message rather than half-working |

**No customer data may be lost by an update:** the only mutable state is the PostgreSQL data directory and `ProgramData\SupermarketPro\backups`; neither is ever overwritten by an upgrade, and uninstall preserves both by default (§2.3).

---

## 7. Commercial deployment considerations (Algeria, many independent stores)

### 7.1 Operational complexity estimates

| Operation | Complexity with the proposed design | Notes |
|---|---|---|
| Install a new store | **Low** — run `SupermarketPro-Setup.exe`, first-run wizard, create owner account | Requires one USB/transfer of one file; no internet required for install |
| Pair owner phone | **Low** — install APK, scan QR, owner approves | APK delivery method §8.6 |
| Pair employee phones | **Low–Medium** — same flow; employee must log in with their own user/PIN | Needs the device→user binding design (§5.2) |
| Replace a damaged PC | **Medium** — install on the new PC, restore latest backup (`POST /api/v1/backups/{id}/restore`, `api/v1/backups.py:156`), re-pair devices | Requires the owner to have a backup file (USB/cloud) — **scheduled backups are new development** |
| Restore from backup | **Medium** — wizard-driven restore is proposed; raw restore exists as an API | Must add a guided flow (**new development**) |
| Change internet router | **Low for LAN** (nothing to reconfigure on our side beyond DHCP); **gateway mode** unaffected (outbound-only) | If static IPs were used in LAN mode, re-pair/reconfigure addresses |
| Replace a phone | **Low** — revoke old device, pair new one | Existing revoke endpoint |
| Revoke employee access | **Low** — revoke device + disable user | Both exist (device revoke `devices.py:396`; user management exists) |
| Update many installations | **Medium** — no remote update channel exists today; initially hand-carry the new setup exe or host a download | Fleet management / remote update = **new development** |

### 7.2 Recurring infrastructure / licensing costs (all **UNVERIFIED — vendor verification required**)

| Item | Why it may cost money |
|---|---|
| Windows code-signing certificate | SmartScreen reputation for `SupermarketPro-Setup.exe`; OV/EV cert pricing per year |
| Gateway servers (if §3 dedicated gateway is built) | VPS/relay hosting, bandwidth, per-region latency |
| Tailscale plan (if Tailscale is chosen instead) | Free Personal plan excludes commercial use; paid plans bill per user (official pricing page; **amounts change — verify**) |
| Google Play developer account (if Play distribution chosen) | One-time registration fee (official Google terms — **UNVERIFIED for Algeria availability**) |
| PostgreSQL installer redistribution | Legal review of EDB/PostgreSQL distribution terms (**UNVERIFIED**) |
| Tailscale client redistribution / trademark | License + trademark terms (**UNVERIFIED**) |
| Support labor | Phone/remote help for installs, restores, pairing |
| Backup storage | If backups leave the store (cloud/USB rotation) |
| Monitoring/diagnostics | If we monitor customer installations remotely |

Open-source components with no license fee (subject to license-text review at packaging time): **Inno Setup (freeware for non-commercial… Inno Setup licensing must be checked for commercial use — UNVERIFIED)**, PostgreSQL (permissive), WinSW/NSSM (MIT-style — **UNVERIFIED**), Flutter, FastAPI, Python.

---

## 8. Required deliverables — recommendations

| # | Deliverable | Recommendation |
|---|---|---|
| 1 | Windows installer technology | **Inno Setup** producing `SupermarketPro-Setup.exe`; single file; includes Flutter Release bundle, frozen backend, PostgreSQL installer payload, generated `.env`, service registration, firewall rules, first-run wizard |
| 2 | PostgreSQL deployment approach | **Option B** — official PostgreSQL Windows installer run silently by our setup, dedicated data dir under `ProgramData`, localhost-only service, migrations + seed at install; uninstall/upgrade **never** deletes data or backups by default |
| 3 | Windows service architecture | **WinSW (or NSSM)** wrapper: `SupermarketPro-Backend` (single uvicorn worker, depends on PostgreSQL, auto-restart, health-checked, stdout→file logs); optional future `SupermarketPro-Gateway`; scheduled backups as a backend-internal job initially |
| 4 | Recommended remote connectivity solution | **Phase 1: LAN-only (exists today). Phase 2: dedicated vendor-operated outbound gateway (PROPOSED — new development).** Tailscale = conditional bootstrap only (see #5) |
| 5 | Tailscale distribution/licensing findings | Silent install: **supported** (official MSI docs). Accounts: customers need none **only if we operate the tailnet**. Device authorization: configurable (official docs). Per-store networks: recommended (or one tagged tailnet). **Commercial use of the free plan: excluded (official pricing FAQ).** Redistribution in our installer: **UNVERIFIED**. Costs: **UNVERIFIED — verify at procurement**. Algeria reachability: **UNVERIFIED** |
| 6 | Android packaging & distribution strategy | **New development** — `flutter create --platforms=android`; release keystore generated offline and stored in vendor secret management (never in the repo); `applicationId` + version aligned with pubspec; permissions: INTERNET, CAMERA (QR scan), notifications if used; **direct APK delivery first** (website/USB), Google Play optional later (**UNVERIFIED** for Algeria account/billing); no push backend exists → app must poll |
| 7 | Secure QR pairing design | Reuse Phase 16 primitives (600 s code, single-use hashed token, approve/revoke, rate limits); QR carries only code + server_id + address; add QR UI packages, owner-gated code display, device→user binding for employees, persistence documented as process-local |
| 8 | Update & backup strategy | In-place Inno Setup upgrades; automatic `pg_dump` before every migration; rollback = previous bundle + restore dump; aligned version/protocol field (closes D-05); scheduled backups (**new development**) |
| 9 | Expected customer installation steps | See §9 customer journey |
| 10 | Ongoing support & operating costs | §7.2 table; **every price UNVERIFIED** |
| 11 | Main technical and commercial risks | §10 risk table |

---

## 9. Final proposed customer journey

**What the customer does (5 manual steps):**

1. Double-click **`SupermarketPro-Setup.exe`** → wizard (language, install folder, "Install PostgreSQL automatically" pre-checked) → **Finish**.
2. First run: a **first-run wizard** inside the desktop app creates the **store owner account** (PIN) — using the existing first-admin setup endpoint (`POST /api/v1/auth/setup`, already in the client: `new_app/lib/features/auth/auth_provider.dart:161`).
3. Desktop shows a **QR pairing screen** (after owner login).
4. Owner installs **`SupermarketPro-Mobile.apk`** on the phone (sideloaded), opens it, **scans the QR**, taps Approve on the desktop.
5. Owner views store data from the phone (LAN today; via the proposed gateway when built).

**What happens automatically (no user action):**

- PostgreSQL service installed, registered, and started; database created; Alembic migrations applied; RBAC seeded.
- `.env` written with generated secrets and absolute paths.
- Backend Windows service installed, set to Automatic, dependent on PostgreSQL, health-checked, restarted on crash, logs written to files.
- Firewall rules for TCP/UDP 8000 created (LAN mode).
- Desktop shortcut created; optional autostart.
- On every upgrade: services stopped, files replaced, **automatic pre-migration backup**, migrations run, services restarted.
- On uninstall: program files removed; **database and backups preserved** unless the owner explicitly ticks a purge checkbox.

**The customer never touches:** Python, Flutter, PostgreSQL, FastAPI, database tools, VPN tools, the command line, or any router setting.

---

## 10. Main technical and commercial risks

| Severity | Risk | Evidence / status | Required remediation |
|---|---|---|---|
| High | No packaging exists at all; roadmap gap between Phase 16 deferral and Phase 17 exclusion | §1 citations | Schedule an explicit packaging phase before any sales |
| High | Backend requires single worker; naive multi-worker service would silently break rate limits and pairing | `rate_limit.py:13`, `devices.py:121` | Pin `--workers 1` in the service definition; document invariant |
| High | Secrets/DB password live in `.env`; placeholder secrets only warn outside production | `config.py` validators; `.env.example:27` | Installer generates strong per-install secrets; `APP_ENV=production` in shipped config (**new development**) |
| High | No TLS; LAN HTTP by design; remote access over any WAN without TLS is unacceptable | `config.py:91-93`, `.env.example:73` | Gateway mode must terminate TLS; LAN mode documented as trusted-LAN-only |
| High | Android application does not exist (no `android/` folder) | verified `Test-Path` = false | Entire §8.6 track is new development |
| High | Tailscale commercial licensing excludes the free plan for commercial use | official `tailscale.com/pricing` FAQ (**re-verify**) | Legal/procurement decision before any Tailscale commitment |
| Medium | PostgreSQL installer redistribution and Inno Setup commercial-use terms not reviewed | **UNVERIFIED** | Legal review before shipping binaries |
| Medium | Migrations are manual and mostly irreversible; failed upgrade = restore-only rollback | 37 revisions in `migrations/versions/`; `alembic.ini:5` | Mandatory pre-migration backup + tested restore drill |
| Medium | Logs are stdout-only; a service without redirection loses all diagnostics | `logging.py:32,40` | File sink or wrapper redirection |
| Medium | CWD-relative `.env` / `data/server_id` break if the service starts in the wrong directory | `config.py:29`, `server_identity.py:70` | Absolute paths in generated config |
| Medium | Version identity ambiguous (backend `0.1.0` vs Flutter `1.0.0+1`) | D-05, `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:1146` | Align versions + protocol field before packaging |
| Medium | No scheduled backups; restore is an API only — a non-technical owner may never back up | `backup.py` (manual only) | Scheduled backup job + guided restore wizard (new development) |
| Medium | Doc drift: health URL wrong in setup doc | `docs/PHASE_1_SETUP.md:68` vs `health.py:80` | Fix doc during packaging work |
| Medium | No CI, no code signing, no release automation | no `.github/workflows` | Build pipeline required for reproducible releases |
| Low | Dead native payload (`dartjni.dll`) shipped in Release | `generated_plugins.cmake` FFI list | Exclude during packaging |
| Low | Duplicate untracked trees (`new_app_upload/`, zip) may confuse packaging inputs | `git status` untracked | Packaging scripts must reference `new_app/` only |

---

## 11. Achievable with existing architecture vs requires new development

| Capability | Status |
|---|---|
| LAN multi-PC pairing, device guard, approve/revoke, hashed one-time tokens | **Exists (Phase 16)** |
| Local-first POS with no internet dependency | **Exists (by design)** |
| Health endpoints, backup/restore API, Alembic migrations, RBAC seed | **Exists (manual invocation)** |
| Flutter Windows release build | **Exists (folder output)** |
| `SupermarketPro-Setup.exe` installer | **New development** |
| PostgreSQL silent install + DB provisioning in installer | **New development** (mechanism documented, unimplemented) |
| Windows services, autostart, crash recovery, file logging | **New development** |
| Frozen/packaged Python backend runtime | **New development** |
| First-run wizard (owner account is partly existing; wizard shell is new) | **Partial — new development** |
| QR code display + scanning UI | **New development** (no packages in use) |
| Device→user binding for employee devices | **New development** |
| Scheduled backups, guided restore, update orchestration | **New development** |
| Android app (`android/` target, signing, permissions, APK) | **New development — does not exist** |
| Remote access beyond the LAN (gateway, or Tailscale integration) | **Proposed future component — new development; not an existing feature** |
| Push notifications | **Does not exist** (no backend push, no FCM) — polling only |
| Version/protocol compatibility handshake (beyond recorded `client_version`) | **New development** (D-05) |

---

*End of audit. This document prescribes nothing beyond recommendations; implementation requires separate approval and a dedicated packaging/phase plan.*
