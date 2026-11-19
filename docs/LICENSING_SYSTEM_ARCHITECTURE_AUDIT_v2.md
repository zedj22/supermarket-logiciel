# Supermarket Pro — Licensing System
## PHASE 1: Architecture Audit & Approved Implementation Specification (v2 — 2026-11-03)

**Status:** audit + design only. No application code, configuration, database, migration, or
deployment artifact was created, modified, deleted, or executed to produce this document.
The original audit report was created in Phase 1; this v2 file is its decision-updated specification copy.

**Scope of evidence:** the live Desktop project — Flutter Windows client
(`new_app/`), FastAPI backend (`new_app/backend/`), legacy reference app
(`python_app/`), and project documentation (`docs/`, root manifests).
`new_app_upload/`, `new_app_upload.zip`, and `tatus` were not opened, modified, or added to.

**Evidence convention:** every factual claim carries `file_path:line`. Where a claim was
verified by direct file read during Phase 1 it is marked **[verified]**; claims sourced from
the three parallel read-only code audits are marked **[audit]**.

---

## 1. Current architecture findings

### 1.1 Application (Flutter) startup sequence

Entry point `new_app/lib/main.dart:31` (`Future<void> main() async`), order:

1. `WidgetsFlutterBinding.ensureInitialized()` — `lib/main.dart:32`
2. `SharedPreferences.getInstance()` (single instance injected as Riverpod override) — `lib/main.dart:33`
3. `SecureCredentialStorage()` constructed — `lib/main.dart:39` (class `SecureCredentialStorage`,
   `lib/features/auth/credential_storage.dart:3`)
4. `ApiClient(baseUrl: await initialBaseUrl())` — `lib/main.dart:40`; default base URL
   `http://localhost:8000` (`lib/core/constants.dart:17`, `AppConstants.defaultServerBaseUrl`),
   replaced at boot by `initialBaseUrl()` (`lib/features/devices/device_identity.dart:160-165`)
5. `readServerLink()`; if `link.isPaired` → `apiClient.setDeviceIdentity(...)` — `lib/main.dart:41-47`
6. `runApp(ProviderScope(...))` with overrides incl. `installBootstrappedProvider = true` — `lib/main.dart:49-62`
7. First frame reads `lanConnectionProvider`, which starts the LAN state machine via
   `Future.microtask(() => notifier.bootstrap())` — `lib/main.dart:78`,
   `lib/features/devices/connection_provider.dart:836-860` (microtask at `:850-857`)
8. `LanConnectionNotifier.bootstrap()` — `connection_provider.dart:292-324`

Routing is a single `GoRouter` built in `routerProvider`, `lib/router/app_router.dart:51`, with
redirect logic at `app_router.dart:76-127`:

- splash gate while `AuthStatus.checking` or `!splashGateProvider` → `/splash` (`:88-90`)
- first run (`installBootstrappedProvider && !networkConfigured`) → `/setup-network` (`:95-102`)
- `setupRequired` → `/setup` (`:105-107`)
- not authenticated → `/login` (`:111-116`)
- authenticated → `/` (`:121-124`)

**Critical finding:** the Flutter client **never spawns the FastAPI backend**. A repo-wide
search for `Process.`/`uvicorn`/`ProcessStart` in `lib/`, `windows/`, and scripts found only
`Process.run('powershell.exe', ...)` for printing (`lib/features/pos/print_service.dart:95-107`).
The backend is assumed to be already running (`command.txt:1`, `uvicorn app.main:app --host 127.0.0.1 --port 8000`).
Native entry `windows/runner/main.cpp:9-54` only creates the window and hooks raw-scanner input. **[audit]**

There are **no `WidgetsBindingObserver` / lifecycle observers** anywhere in `lib/` (0 matches),
so "first application launch" currently has no in-app hook. **[audit]**

### 1.2 Backend startup and shutdown sequence

- `new_app/backend/app/main.py:16-31` — `lifespan(app)` async contextmanager:
  `setup_logging(settings.LOG_LEVEL)` (`:25`), `start_discovery()` (`:26`), `yield`,
  `finally: stop_discovery()` (`:29-31`). **[verified via audit + grep]**
- `create_app()` at `app/main.py:34`; module singleton `app = create_app()` at `:73`
- Middleware order (`app/main.py:54-65`): `CORSMiddleware` → `RequestIDMiddleware`
  (`app/core/middleware.py:25`, header `X-Request-ID` at `:22`) → exception handlers
  (`app/core/exceptions.py:212`)
- Routers mounted under `/api/v1` — `app/main.py:68`
- Health: `GET /health` (`app/api/v1/health.py:47`), `/health/live` (`:70`), `/health/ready` (`:80`)
- **No DB work, no migrations, no seeding at startup** — grep for `alembic` inside `app/`
  hits only `app/core/db_dump.py:6` (import), a comment in `app/models/catalog.py:160`, and
  backup manifest reading (`app/services/backup.py:701-707`). **[audit]**
- Uvicorn is started manually (`command.txt:1,4,7`, `docs/PHASE_1_SETUP.md:24`,
  `docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:80`); **no launcher script, no Windows
  service exists in the repo today** (deployment audit states a service is a *recommendation*,
  `docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:155`). **[audit]**

### 1.3 Database initialization and connection management

- Engine: `create_db_engine()` — `app/db/engine.py:38`, SQLite/PostgreSQL pool branch `:50`,
  lazy singleton `_EngineFactory` at `:71` with `get_engine:95`, `get_session_factory:100`
- Canonical session dependency: `get_db` — `app/db/session.py:15` (re-exported by
  `app/db/dependencies.py:5`)
- ORM base: `Base(DeclarativeBase)` with mixins `UUIDMixin/TimestampMixin/VersionMixin/ArchiveMixin`
  — `app/db/base.py:17-60`
- `DATABASE_URL` is **required** by config (`app/core/config.py:41`); `.env.example:27`
  shows `postgresql://postgres:...@localhost:5432/supermarket_pro`
- `SERVER_ID` persisted in a plain file `data/server_id` (`config.py:101`,
  `app/core/server_identity.py:58` `get_server_id()`) — **the existing precedent for
  file-based, non-database machine state [verified]**

### 1.4 Configuration and settings management

- `app/core/config.py:25` `class Settings(BaseSettings)` (pydantic-settings, reads `.env`,
  `extra="ignore"`), singleton `settings = Settings()` at `:142` **[verified]**
- Security-relevant fields: `APP_ENV:36`, `APP_SECRET_KEY:37`, `VERSION:38`,
  `DATABASE_URL:41`, `JWT_SECRET_KEY:44`, `JWT_ALGORITHM:45`, `SESSION_LIFETIME_MINUTES:49`,
  rate limits `:62-64`, `CORS_ORIGINS:67`, `HOST/PORT:73-74`
- Phase 16 fields: `LAN_MODE: bool = False` (`:93`), `DISCOVERY_ENABLED: False` (`:94`),
  `DISCOVERY_PORT = 8000` (`:95`); `.env.example:53,57` ship both at `0`
- Backup fields: `BACKUP_DIR:110`, `BACKUP_TIMEOUT_SECONDS:111`, `PG_DUMP_PATH:112`, `PSQL_PATH:113` **[verified]**
- Production guard `_reject_placeholder_secrets` — `config.py:118-139` **[verified]**
- Store/business settings live **in the database** (`AppSetting` singleton row,
  `app/models/settings.py:51`, endpoints `GET/PUT /api/v1/settings` in `app/api/v1/settings.py:63,77`)
- Client-local settings: SharedPreferences keys (`app_locale`, `app_theme_mode`,
  `pos_device_id`, `paired_server_url`, `paired_server_id`, `app_run_mode` —
  `lib/features/devices/device_identity.dart:24,27,31,34`) plus secure storage for JWT/device
  token (`credential_storage.dart:4-16`). **[audit]**

### 1.5 Authentication and authorization

Backend (authoritative):

- Argon2id PIN hashing `hash_pin`/`verify_pin` — `app/core/security.py:51,60`
- JWT HS256 `create_access_token` / `decode_access_token` — `app/core/security.py:77,103`;
  sessions store a SHA-256 token fingerprint (`hash_token` `:121`; `AuthSession` model
  `app/models/user.py:167`, comment `:170`)
- `AuthService` — `app/services/auth.py:46` (`setup_first_admin:51`, `login:151`, `verify_token:345`,
  `reauth:437`)
- Routes — `app/api/v1/auth.py`: `/setup:53`, `/setup/check:76`, `/login-users:84`, `/login:109`,
  `/verify-token:158`, `/logout-token:199`, `/reauth:214`, `/me:236`
- Dependencies — `app/api/dependencies.py`: `get_current_user:70`, `CurrentUser:129`,
  `require_permission:132`, `require_any_permission:157`
- RBAC models — `app/models/user.py` (`User:82`, `Role:121`, `Permission:148`),
  scopes in `app/models/enums.py:17 PermissionScope`
- Rate limiting — `app/core/rate_limit.py` (`api_rate_guard:119`, `auth_limiter:86`)

Client (display-only, per its own comments):

- `AuthNotifier` — `lib/features/auth/auth_provider.dart:51` (`_initialize:75`, `login:179`,
  `_applyMePermissions:272`); `AuthStatus` enum `:9-17`
- Permission helpers — `lib/features/auth/permission_helpers.dart:5-21`; nav scopes
  `lib/features/shell/nav_items.dart:6-25` (incl. `backupRestore = 'backup_restore'` `:25`)
- `ApiClient` interceptor — `lib/network/api_client.dart:251-272`; device-guard error codes
  `:42-46`
- Comments state explicitly that **backend RBAC is the security boundary**
  (`lib/router/app_router.dart:255-257`, `lib/features/devices/devices_screen.dart:8`) **[audit]**

### 1.6 LAN discovery, IP configuration, pairing, device management

Protocol (backend):

- `app/discovery/packet.py:35-42`: `MAGIC = b"SUPERMARKET_PRO_DISCOVER_V1"`,
  `PROTOCOL_VERSION = 1`, `APP_ID = "supermarket_pro"`, size caps 256/512, nonce 8–64
- `app/discovery/responder.py`: `DiscoveryResponder:65` bound to a **single UDP port =
  `DISCOVERY_PORT` (8000)**, `_RateLimiter:41` (10/s), `start:92/stop:126`, called from
  `app/main.py:26,31` via module functions `start_discovery:194` / `stop_discovery:204`
- Payload carries `server_id`, store name, port — **no secrets** (`.env.example:56`)

Protocol (client):

- `lib/features/devices/discovery_service.dart`: magic `:29`, protocol `:31`,
  `buildDiscoverPacket:53`, `buildOfferPacket:63`, `parseOfferPacket:122`,
  `UdpDiscoveryService:222` (SO_BROADCAST enabled `:263`), `ServerProbe.probeServer:414`
  (calls `GET /api/v1/health` `:429` then `GET /api/v1/system/info` `:435`, protocol mismatch
  → `NotASupermarketServerException` `:449-454`)

Pairing / device management:

- Client state machine `LanConnectionNotifier` — `lib/features/devices/connection_provider.dart:254`,
  phases `LanPhase` `:37-67`, backoff ladder `:70-92`
- Pairing: `POST /api/v1/devices/pair` (`connection_provider.dart:528-536`) → poll
  `GET /api/v1/devices/pairings/{id}` (`:595-596`); approval writes `ServerLink` (`:616-620`)
- Heartbeat: `GET /api/v1/health` every 10 s (`:677-680`, interval `lib/core/constants.dart:22`,
  failure threshold 2 at `:23`) plus identity check `GET /api/v1/system/info` (`:687-701`) →
  `forgetServer(reason:'server_changed')` if `server_id` differs (`:699`)
- Admin screen `lib/features/devices/devices_screen.dart` scope `device_manage` (`:28`),
  approve/deny/revoke `POST /api/v1/devices/{id}/{action}` (`:133-138`)
- Backend: `app/api/v1/devices.py` (`POST /pair:93`, `GET /pairings/{id}:137`, `GET:168`,
  `GET /pairing-code:185`, `approve:212`, `deny:230`, `revoke:250`);
  `app/services/devices.py:44-48` (`PAIRING_CODE_TTL_SECONDS=600`, rate limits);
  model `Device` — `app/models/device.py:31` (token stored as SHA-256 `token_hash:43`)

### 1.7 Phase 16 Device Guard implementation

`new_app/backend/app/api/device_guard.py` — **[verified by direct read]**

- Router-level dependency, attached at `app/api/v1/router.py:52`:
  `api_router = APIRouter(dependencies=[Depends(api_rate_guard), Depends(device_guard)])`
  → it runs **before every endpoint's own dependencies on every route, present and future**
  (docstring `router.py:6-9`)
- `ALLOW_PATHS` (`:70-75`): `/api/v1/health`, `/api/v1/system/info`, `/api/v1/auth`,
  `/api/v1/devices` — the bootstrap surface (`is_allowlisted:112`)
- **Loopback exemption** `LOOPBACK_HOSTS = {"127.0.0.1", "::1", "::ffff:127.0.0.1"}` (`:89`),
  `is_loopback_client():92-109`, rationale comment `:77-88` ("Q6 — the server PC may also be a
  till"): the Main PC's own till talks to itself without device headers and must not be locked out
- Behavior in `device_guard():167`: **no-op unless `LAN_MODE` is enabled** (`:171-176`) →
  allowlist (`:179-181`) → loopback exception (`:188-190`) → missing headers →
  `DeviceRequiredError` 401 (`:195-199`) → unknown device → `DeviceNotPairedError` 403
  (`:202-203`) → revoked → `DeviceRevokedError` 403 (`:205-209`) → not approved (`:211-217`)
  → constant-time compare `secrets.compare_digest(stored, hash_token(token))` (`:219-221`)
  → throttled `_touch_last_seen` (`:223`, throttle `:68`)
- Errors imported from `app/services/devices.py` (`device_guard.py:59-63`); client maps the
  codes `device_required|device_not_paired|device_revoked` (`lib/network/api_client.dart:42-46`)
  into the connection layer (`:253-260`)

**Implication for licensing:** this is the proven, battle-tested pattern (router-level
dependency + allowlist + fail-closed) that the license guard should mirror — but the license
guard must **not** inherit `LAN_MODE` gating (license applies in single-PC mode too) and must
**not** inherit the loopback exemption (the Main PC's own till must also be license-gated).

### 1.8 Main PC and LAN Client detection

- Chosen once in the first-run wizard: `SetupWizardScreen._chooseRole(mode)`
  — `lib/features/devices/setup_wizard_screen.dart:60-75`; writes `app_run_mode` prefs key
  (`device_identity.dart:34`, values `'server'` / `'client'` `:36-37`)
- Server mode → `context.go('/')` immediately, never pairs with itself (`setup_wizard_screen.dart:65-68`)
- Read at boot by `isNetworkConfigured()` — `device_identity.dart:130-138`:
  **client requires a completed pairing; server mode returns `true` immediately (`:137`)**
- `bootstrap()` unpaired branch uses it — `connection_provider.dart:294-303`
- The **backend does not know this flag**: `app_run_mode` is client-side only. On the backend,
  "is this the Main PC" is expressed indirectly as (a) the loopback peer exception in the device
  guard and (b) `LAN_MODE` being enabled for a server deployment. **[verified]**
- Server identity for clients: `server_id` from `GET /api/v1/system/info`
  (`app/api/v1/system.py:58,86`, `get_server_id()` from `app/core/server_identity.py:58`) —
  public metadata, echoed by `SystemInfoResponse` (`system.py:37-58` **[verified]**)

### 1.9 Backup/export and restore/import implementation

Backend (authoritative) — see §3 for detail; endpoints in `app/api/v1/backups.py`:
`GET:57`, `POST:71`, `GET /{id}/inspect:88`, `GET /{id}/download:105`,
`POST /upload:127`, `POST /{id}/restore:156` — all guarded by
`require_permission(PermissionScope.BACKUP_RESTORE)` (`:80,97,114,137,166`) **[verified]**,
restore additionally requires `{"confirm": true}` → 422 `RESTORE_CONFIRMATION_REQUIRED` (`:172-176`).

Client:

- `BackupNotifier` — `lib/features/settings/backup_provider.dart:88` (`load:97` → `GET /api/v1/backups`,
  `create:120` → `POST`, `restore:146` → `POST /{id}/restore` with `{"confirm": true}` `:153-156`)
- `BackupRestoreScreen` — `lib/features/backup_restore/backup_restore_screen.dart:31`
  (inspect `:86-141` → `GET /{id}/inspect`, download `:289-332`, upload `:334-384`,
  create `:385-404`, restore confirm dialog `:143-265`)
- Data transfer (CSV/XLSX): `lib/features/data_transfer/data_transfer_screen.dart:31`
  → `POST /api/v1/products/export:89`, `POST /api/v1/products/import:194` (multipart, `dry_run`)
- Report export: `lib/features/reports/report_export.dart` — CSV built client-side (`:284-328`),
  XLSX/PDF via `POST /api/v1/exports` (`:365-366`); backend `app/api/v1/exports.py:37`,
  `app/services/export.py:93`, formats `("xlsx","pdf")` (`:71`), 50 MB cap (`:52`),
  formula-injection guard `app/exporting/xlsx.py:32` **[audit]**

### 1.10 Database schema and Alembic migration structure

- `alembic.ini:5` `script_location = migrations`; `migrations/env.py:17-34` imports
  `settings` and `from app.models import *`
- **37 revisions, strictly linear**, `0001_initial` → … → `e5b7d2c9a41f` (`0037_zakat_basis_wholesale.py`)
- **Migrations are manual** — never invoked from `app/` (grep result, §1.2); documented at
  `docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:80`
- **43 tables / 19 model files** under `new_app/backend/app/models/`
  (e.g. `Product` `catalog.py:69`, `Sale` `sale.py:31`, `Device` `device.py:31`,
  `AppSetting` `settings.py:51`, `AuthSession` `user.py:167`, `AuditLog` `audit.py`)
- `audit_logs.module` is a plain **`VARCHAR(30)`** (`migrations/versions/...0031_audit_trail_context.py:53`,
  model comment `app/models/audit.py:65`) → adding a `license` module value needs **no DDL** **[verified]**

### 1.11 Existing update mechanism

**None exists anywhere** (backend, client, installer, scripts):

- Backend: two independent greps (`update_check|check_for_update|latest_version|download_update|self_update|upgrade_check|update_url`)
  → 0 matches; only backup *download* (`app/api/v1/backups.py:105`) and
  `GET /system/info` version reporting (`app/api/v1/system.py:95`) **[audit]**
- Client: no updater package in `pubspec.yaml:9-27` / `pubspec.lock`; only
  `AppConstants.appVersion = '1.0.0'` (`lib/core/constants.dart:3`) displayed on About
  (`lib/features/about/about_screen.dart:408-410`) and sent as `client_version` during pairing
  (`connection_provider.dart:533`)
- Deployment audit confirms: *"no remote update channel exists today … Fleet management /
  remote update = new development"* (`docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:252`),
  and an in-place Inno Setup upgrade flow is only a *recommended* design (`:227-234`)

**Consequence:** "free updates for life" is a **distribution policy** (installer packages
delivered manually/by the owner), not a code component. Licensing must not build an updater.

### 1.12 Existing licensing code (legacy only)

- `python_app/security/license.py:8 class LicenseManager`
  (`get_device_id:17` = `md5(platform.node()+system+processor)`, `generate_serial:21` =
  `SM-<uuid>-<uuid>`, `activate_license:24`, `check_license:47`, `get_license_info:60`) —
  **no signatures, no keys, no crypto imports**; stores rows in a MySQL `license` table
  (`python_app/database/db_manager.py:591-598`) **[audit]**
- Enforcement is **commented out**: `python_app/main.py:16-19`
  ("check temporarily disabled for testing")
- A dead Flask route `POST /api/check_license` exists (`python_app/server/server.py:18-26`,
  never launched)
- Project's own security audit demands a redesign: *"license guard is commented … Re-design
  licensing server/offline entitlement separately"* and *"MD5 platform info → weak/spoofable.
  Use generated device keypair/UUID stored in OS-protected storage"*
  (`docs/PHASE_0_SECURITY_AUDIT.md:8,11`) **[verified]**
- **No licensing, trial, activation, fingerprinting, or Ed25519 code exists in `new_app/`
  (client or backend)** — zero matches for `license|trial|activation|ed25519` in
  `new_app/lib`, `new_app/windows`, `new_app/backend/app` (only font OFL texts and unrelated
  "signature"/"fingerprint" wording) **[audit]**
- `docs/PHASE_0_ROADMAP.md` (17 phases) contains **no licensing phase** (`:23-24`) **[audit]**

---

## 2. Existing LAN architecture and safe integration points

### 2.1 How the LAN works today (must be preserved)

```
Main PC (app_run_mode='server')                    LAN Client (app_run_mode='client')
┌─────────────────────────────────────┐            ┌──────────────────────────────────┐
│ Flutter client ──HTTP──► backend    │            │ Flutter client                   │
│ (loopback, no device headers)       │            │   │ UDP discover (port 8000)     │
│ backend: uvicorn :8000              │◄───────────┼───┘ GET /health + /system/info   │
│   + UDP DiscoveryResponder          │  pair flow │   POST /devices/pair (6-digit)   │
│   + device_guard (LAN_MODE=1)       │◄───────────┼──► poll pairings/{id}            │
│   + PostgreSQL (private to backend) │  heartbeat │   GET /health  (10 s)            │
└─────────────────────────────────────┘            │   GET /system/info (identity)    │
                                                   │   X-Device-ID / X-Device-Token   │
                                                   └──────────────────────────────────┘
```

- Discovery: UDP on the HTTP port (`DISCOVERY_PORT=8000`, `config.py:95`),
  magic `SUPERMARKET_PRO_DISCOVER_V1` (`app/discovery/packet.py:35`),
  client counterpart `lib/features/devices/discovery_service.dart:29-31`
- Pairing: 6-digit code + human approval, rate-limited (`app/services/devices.py:44-48`)
- Identity: `server_id` (`app/core/server_identity.py:58`) verified on every heartbeat
  (`connection_provider.dart:687-701`)
- Transport guard: `device_guard` (§1.7) with loopback exemption for the Main PC's own till
- Reconnection: backoff ladder `connection_provider.dart:70-92`, `reacquireServer:420`,
  `_recoverAddress:367-414` (rewrites `paired_server_url` on IP change `:397-400`),
  one-shot boot modal `reconnect_dialog.dart:17` wired at `app_router.dart:383-403`

### 2.2 Safe integration points (minimal-diff, no redesign)

The license authority must be the **backend process on the Main PC** — it is the only component
every client (local till and LAN tills) already has to pass through. Three integration points,
in order of safety:

| # | Integration point | Why it is safe |
|---|---|---|
| **P1 (primary)** | `app/api/v1/router.py:52` — add `Depends(license_guard)` to the existing router-level dependency list | Runs on **every** route automatically, exactly like `device_guard`; zero changes to the 179 individual endpoints; fail-closed by construction; needs no LAN/Device Guard change |
| **P2 (status reporting)** | `app/api/v1/system.py:37-58` `SystemInfoResponse` — add an **additive** `license` field, filled in `get_system_info():66-87` | Clients already call `/system/info` in `ServerProbe.probeServer()` (`discovery_service.dart:435`) and in every heartbeat (`connection_provider.dart:688`); additive response fields are ignored by unknown-key-tolerant parsing, and the discovery protocol field (`protocol`, `system.py:57`) is untouched → **no protocol version bump, no pairing change** |
| **P3 (client display/gating only)** | `lib/features/devices/connection_provider.dart:674-724` `_heartbeatTick()` + `lib/router/app_router.dart:76-127` redirect | Existing heartbeat already performs `/health` + `/system/info`; the redirect chain already gates routes (splash/first-run/auth). A license gate is one more redirect rule and one more parsed field — no new state machine, no change to pairing/discovery/backoff |

**Explicitly NOT touched:** `app/api/device_guard.py`, `app/discovery/*`,
`app/services/devices.py`, pairing endpoints, `LanPhase` state machine semantics,
`app/models/device.py`, and the loopback exemption.

**Enforcement rule (requirement E.7/E.8):** LAN clients **display** the status the Main PC
reports and are **never** an authority. The backend guard (P1) is the enforcement; the Flutter
gate (P3) is UX. A client that lies about license status can only affect its own screen — it
cannot obtain business data, because P1 refuses the response.

**Loopback note:** unlike `device_guard`, `license_guard` must apply to loopback peers as well,
otherwise the Main PC's own till would bypass licensing (the Q6 exemption in
`device_guard.py:77-88` must remain exclusive to device pairing).

---

## 3. Existing backup/export and restore/import architecture

### 3.1 Backup format today (backend, authoritative)

`app/services/backup.py:85 class BackupService` **[verified]**

- `create():129` → `pg_dump` `.sql` + JSON sidecar manifest in `BACKUP_DIR`
  (default `<backend>/backups`, `config.py:110`); manifest written at `:145-156` with keys:
  `id`, `created_at`, **`sha256`** (of the `.sql`), **`schema_revision`** (from `alembic_version`,
  `_schema_revision():700`), `pg_dump_version` (`_tool_version():712`), `app_version`
  (`settings.VERSION`), `size` — **no machine/hardware field exists today** **[verified]**
- `list():187` — adopts stray `.sql` files by writing a manifest for them (`:192-212`)
- `inspect():343` — returns `sha_ok` + schema-compatibility verdicts
- `download():405`, `upload():438` — single-file ZIP containing dump + manifest
  (`_ARCHIVE_MANIFEST_MEMBER = "manifest.json"` `:82`, `_extract_archive():527`)
- `restore():219` — verifies the recorded SHA-256 first, takes a **safety backup of the current
  DB** (`:259` comment), then replays with `psql --single-transaction` → **full overwrite of the
  live database**; `_post_restore_check():602` verifies readiness afterwards
- Tools located by `find_pg_tool()` — `app/core/db_dump.py:49`; password via `PGPASSWORD`
  env only (`:113`)
- Transport/authorization: `require_permission(BACKUP_RESTORE)` + `{"confirm": true}`
  on restore (`app/api/v1/backups.py:166,172-177`) **[verified]**

Client mirrors these endpoints (§1.9); SHA-256 is verified **server-side**; the client only
displays `sha256_ok` (`backup_restore_screen.dart:151`). The Flutter app has **no direct
crypto dependency** (`pubspec.yaml:9-27`; `crypto` is transitive only) **[audit]**.

### 3.2 What this means for licensing requirements

| Requirement | Current state |
|---|---|
| Backup not tied to creating PC | ✅ already — manifest has no hardware/machine field |
| Export allowed in Trial and Lifetime | ✅ `POST /backups` + `/download` already exist; must stay allowed while trial is active |
| Restore forbidden in Trial | ❌ **not enforced today** — only `backup_restore` permission + confirm |
| Restore allowed on ANY licensed Main PC | ⚠️ currently restore requires no license at all — must be gated on *lifetime*, not on hardware |
| Integrity/authenticity validation | ⚠️ integrity (SHA-256) yes; **authenticity (signature) no**; schema compatibility yes (`schema_revision`) |
| Backup must not carry license | ✅ achievable only if license state lives **outside PostgreSQL** — see §4.2 and §10 |
| Never silently overwrite | ✅ confirm flag + safety backup already exist (`backup.py:229,259`) — must be *kept* |
| Schema-version compatibility | ✅ `schema_revision` compare already implemented (`inspect:343`) |

### 3.3 Export/import surfaces (not backups, but adjacent)

- Product CSV/XLSX import with dry-run + conflict policy — `app/api/v1/product_transfer.py:69,93`
- Report XLSX/PDF export — `app/api/v1/exports.py:37`, `app/services/export.py:102`
- These are business-data egress paths: they must be **blocked when the license/trial is
  expired** (they are "normal business operations"), and **allowed** during an active trial.

---

## 4. Proposed licensing architecture

### 4.1 Component map

```
                    ┌──────────────────────────────────────────────┐
                    │  LICENSE GENERATOR  (owner-only, OFFLINE)    │
                    │  • separate private repository — NOT here    │
                    │  • Ed25519 PRIVATE signing key(s)            │
                    │  • input: hardware activation code from cust │
                    │  • output: signed activation code            │
                    └───────────────────┬──────────────────────────┘
                                        │ (customer copies code by hand/e-mail)
                                        ▼
┌────────────────────────── MAIN PC ──────────────────────────────────────────┐
│  Flutter client                        FastAPI backend (licensing authority)│
│  ┌───────────────────────────┐         ┌──────────────────────────────────┐ │
│  │ License UI                │  HTTP   │ license_guard (router-level,     │ │
│  │  • activation entry       │────────►│   P1, loopback NOT exempt)       │ │
│  │  • trial countdown/banner │◄────────│ TrialManager    (trial state)    │ │
│  │  • lock screen            │  status │ LicenseManager  (Ed25519 verify) │ │
│  │  router gate (P3)         │         │ HardwareFingerprintService       │ │
│  └───────────────────────────┘         │ StateStore (DPAPI+HMAC files)    │ │
│                                        │ LicenseStatus → /system/info (P2)│ │
│  heartbeat already calls               └──────────────────────────────────┘ │
│  /health + /system/info  ──────────────►  (no new client→server call)       │
└─────────────────────────────────────────────────────────────────────────────┘
                     ▲
                     │ HTTP + X-Device-ID/Token (existing device_guard)
┌────────────────────┴─────────────┐
│ LAN client (paired only)         │  • no license state of its own
│                                  │  • reads Main PC license status (P2/P3)
│                                  │  • business calls fail at P1 if Main PC
│                                  │    is unlicensed/unreachable
└──────────────────────────────────┘
```

### 4.2 Core decision: license and trial state live **outside PostgreSQL**

Stored as files (like the existing `SERVER_ID_FILE` precedent, `config.py:101`):

```
<LICENSE_STATE_DIR>/            # config setting; dev default: <backend>/data/license
  ├─ trial.state                # first_launch_at, last_seen_at, max_seen_at, install_id
  ├─ license.state              # activation payload + signature + verified_at (DPAPI-protected envelope)
  └─ install.keypair            # optional per-install Ed25519 keypair (backup signing), DPAPI-protected
```

Reasons (each maps to a hard requirement):

1. **`pg_dump` backups cannot contain the license** → requirement D ("Backup must not contain
   or transfer the original computer's license") is satisfied *structurally*, not by filtering.
2. **A restore can never erase or install a license** → restoring a Trial backup onto a
   Lifetime PC2 cannot downgrade PC2, and restoring a licensed PC's backup cannot grant a
   license to a trial machine. (If licensing were in `app_settings`/a table, restore would
   silently rewrite it.)
3. **Uninstall/reinstall = new trial** → the uninstaller deletes only `<LICENSE_STATE_DIR>`,
   while `postgres\data` and `backups` stay untouched per the hard rule
   (`docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:103`).
4. **No schema change is required for the core licensing feature** (§10).

### 4.3 Components (proposed modules)

| Component | Location | Responsibility |
|---|---|---|
| `StateStore` | **new** `new_app/backend/app/licensing/state_store.py` | Read/write the state files atomically (write-temp+rename), DPAPI envelope via `CryptProtectData` (machine scope) when available, HMAC integrity, tolerate absence |
| `TrialManager` | **new** `app/licensing/trial.py` | `start_trial()` on first launch, `status()` → `active/expired`, `expires_at`, clock-rollback resistance (`max_seen_at`) |
| `HardwareFingerprintService` | **new** `app/licensing/fingerprint.py` | Compose SHA-256 over stable machine identifiers (Windows `MachineGuid`, system volume serial, hostname) → grouped display code. Used **only** for lifetime binding — **never for backup restore** |
| `LicenseManager` | **new** `app/licensing/license.py` | Parse activation code → verify Ed25519 signature against embedded **public** keys → validate kind/expiry/binding → persist; `status()` |
| Verification keys | **new** `app/licensing/verification_keys.json` | `{key_id → 32-byte public key}` list (supports rotation; **public material only**) |
| `license_guard` | **new** `app/licensing/guard.py` | FastAPI dependency mounted at `app/api/v1/router.py:52`; allowlist; typed errors `trial_expired` / `license_required` / `license_bound_elsewhere` / `license_invalid` |
| `LicenseStatus` reporter | extend `app/api/v1/system.py:37-87` | Additive `license: {mode, valid, expires_at?}` field (P2) |
| Activation endpoint | **new** `app/api/v1/license.py` + router include | `GET /api/v1/license/status`, `POST /api/v1/license/activation-request` (returns hardware code), `POST /api/v1/license/activate` (verifies signed code) |
| Flutter `LicenseNotifier` | **new** `lib/features/license/license_providers.dart` | Parses the status reported by P2; feeds router gate + banner |
| Flutter gate/screens | **new** `lib/features/license/{license_screen,trial_banner,license_lock_screen}.dart` | Activation entry, countdown, lock UI |
| License Generator | **outside this repository** (private repo/CLI) | Ed25519 signing tool; ships private key; never imported by app or backend |

Crypto: `cryptography` is already available transitively via
`python-jose[cryptography]` (`new_app/backend/pyproject.toml:14`) — it provides
`cryptography.hazmat.primitives.asymmetric.ed25519`. Implementation should promote it to an
**explicit direct dependency**. Flutter performs **no signature verification** (§4.4).

### 4.4 Offline validation, authority, and what cannot be guaranteed

- **Offline:** activation and verification are pure local computation (no network at all).
  The backend verifies the signature with embedded public keys.
- **Single authority:** only the backend holds state and answers status; clients only render.
  This is what makes requirement E.7/E.8 structurally true rather than a convention.
- **Enforcement matrix (`license_guard`, always on — independent of `LAN_MODE`):**

| Route class | Trial active | Trial expired | Lifetime activated | Invalid/no license |
|---|---|---|---|---|
| `/health`, `/health/live`, `/health/ready` | ✅ | ✅ | ✅ | ✅ |
| `/system/info` (incl. license status) | ✅ | ✅ | ✅ | ✅ |
| `/auth/*` (login, setup, logout, me) | ✅ | ✅ | ✅ | ✅ |
| `/devices/*` (pairing/admin) | ✅ | ✅ | ✅ | ✅ |
| Narrow `/license/status`, `/license/activation-request`, `/license/activate` endpoints | ✅ | ✅ | ✅ | ✅ (activation request/activation only; status reports invalid state) |
| All business routes (products, sales, purchases, returns, customers, debts, loyalty, facturation, expenses, inventory, packs, promotions, suppliers, reports, exports, print, dashboard, pos, settings, zakat, audit, storage, users) | ✅ | ❌ `403 trial_expired` | ✅ | ❌ `403 license_required` |
| `POST /backups` (create) | ✅ | ❌ `403 trial_expired` | ✅ | ❌ |
| `GET /backups` + `GET /{id}/download` (list/download existing backups) | ✅ | ✅ (read-only data rescue) | ✅ | ❌ |
| `POST /backups/upload` (stage uploaded archive) | ❌ `403 trial_upload_forbidden` | ❌ | ✅ | ❌ |
| `POST /backups/{id}/restore` | ❌ `403 trial_restore_forbidden` | ❌ | ✅ | ❌ |

  The three narrowly scoped `/license/*` routes above are allowlisted so activation works before
  login and after Trial expiry. They must not expose business data or general settings; activation
  is protected by signed-code verification, strict payload limits, and rate limiting.

  Error codes follow the existing convention recognised by the client
  (`device_required|device_not_paired|device_revoked` pattern, `lib/network/api_client.dart:42-46`)
  so the lock screen can be triggered from the interceptor without touching endpoints.

- **Client gate (UX only):** router redirect rule in `app_router.dart:76-127` +
  `mutationsAllowed`-adjacent display gating (§11). Tampering with the client only degrades
  the local display; data remains protected at P1.

- **What offline licensing CAN guarantee:** a genuine, owner-signed, non-expiring license
  issued for one hardware identity; trial expiry based on recorded local time; backups whose
  bytes are integrity-checked and format-validated; LAN clients that cannot obtain business
  data from an unlicensed Main PC (server-side refusal).

- **What it CANNOT guarantee against a local administrator:** an admin can edit state files
  (mitigated by DPAPI machine-scope envelope + HMAC — raises the bar above casual editing but
  an admin on the *same* machine can re-seal), roll back the clock (mitigated by
  `max_seen_at` monotonic guard, defeated by re-imaging), patch the backend binary, or run a
  patched build. This is an accepted, documented limitation of any offline scheme; the design
  deliberately does **not** claim admin-resistant enforcement, and **does not** use TPM as a
  hard requirement (optional seal only).

### 4.5 Safe uninstall/reinstall behavior

1. **Upgrade (same install present):** preserve `<LICENSE_STATE_DIR>` (license and trial
   continuity) and `ProgramData\SupermarketPro\{postgres\data,backups}` — matches
   `docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:227-234`.
2. **Uninstall:** program files removed; DB + backups preserved by default (`:103`);
   **`<LICENSE_STATE_DIR>` is deleted** → this is what makes "uninstall + reinstall starts a
   new 10-day trial" true *per installation*, with **no hardware blacklist** (requirement A).
3. **Reinstall:** trial manager finds no `trial.state` → starts a fresh trial on first
   backend start (first launch).
4. **Empty business database:** the installer must distinguish *fresh install* from *upgrade*
   (Inno Setup knows this) and, for a fresh install, point `DATABASE_URL` at a **new empty
   database** rather than adopting an existing data directory — otherwise old trial data would
   reappear. See **Conflict C1** in §14 — this is an installer-design decision, not code.
5. Since a trial **cannot upload or restore backups**, old data cannot re-enter a fresh trial
   automatically. The customer may still download an already-created backup after expiry.
   Data can be imported into a different computer only after that destination has a valid
   Lifetime License and the backup is explicitly uploaded and restored there.

---

## 5. Trial lifecycle

| # | Step | Behavior |
|---|---|---|
| T1 | Fresh installation (no `<LICENSE_STATE_DIR>`) | Installer/app first start; backend creates `trial.state` with `install_id` (random UUID), `first_launch_at = now(UTC)`, `last_seen_at = max_seen_at = now` |
| T2 | Trial runs | `license_guard` reports `mode=trial`, `valid=true`, `expires_at = first_launch_at + 10 days`; all business routes and backup export work normally, **backup restore refused** |
| T3 | Normal operation offline | All evaluation is local; no internet, no clock server |
| T4 | Clock-rollback resistance | On every status read: `now = max(now, max_seen_at)`; if `now < last_seen_at` (clock moved back) treat as tamper signal → clamp to `max_seen_at`; `max_seen_at = max(max_seen_at, now)` persisted atomically |
| T5 | Expiration | `now > expires_at` → `mode=trial_expired`; business routes return `403 trial_expired`; Flutter router redirects to lock screen; **data stays intact** (nothing is deleted) |
| T6 | After expiration | Health/system/auth/devices and activation routes remain reachable. Business operations and backup creation are blocked. Existing backup listing and download remain available as read-only data rescue. Backup upload and restore remain blocked. |
| T7 | Export during trial | `POST /backups` + `GET /backups/{id}/download` are allowed while trial is active. `POST /backups/upload` is blocked during Trial. |
| T8 | Uninstall + reinstall | Uninstaller deletes `<LICENSE_STATE_DIR>` only → new installation → new 10-calendar-day trial. No hardware-based blocking; same PC may run sequential trials after reinstall. |
| T9 | Trial vs LAN | A Main PC with an active Trial **may serve paired/authorized LAN clients**. Those clients inherit the Main PC's active Trial entitlement and do not need individual licenses. When Trial expires, server-side enforcement blocks business operations for both Main PC and LAN clients. |
| T10 | Fresh DB on reinstall | Installer creates/selects a new empty database for a fresh installation while preserving the previous database and backups on disk. No silent deletion or automatic adoption of old trial data. |

**Time rule (D2):** Trial expires exactly **10 calendar days (240 elapsed hours)** after the first backend start that creates the trial state. It continues counting while the application is closed; it is not 240 hours of cumulative usage.

---

## 6. Lifetime activation lifecycle

1. **Request:** customer reaches the activation screen (client `License UI`, after login —
   Decision D4) → `POST /api/v1/license/activation-request` → backend returns the
   **Hardware/PC Activation Code**: grouped Base32 of
   `{v, install_id, hw_hash, requested_at}` + optional HMAC (anti-casual-typo, not a secret).
2. **Hand-off (offline):** customer sends the code to the software owner (phone/e-mail).
3. **Signing (owner):** License Generator (private tool, private repo) verifies the request,
   binds it, and produces
   `SMP1.<base32(payload)>.<base32(signature)>` where payload =
   `{v:1, key_id, license_id, kind:"lifetime", customer_ref, issued_at, hw_hash|null, features}`
   canonicalized (deterministic JSON, sorted keys, UTF-8) and signed with **Ed25519**.
4. **Entry:** customer pastes the code → `POST /api/v1/license/activate`.
5. **Verification (offline, local):** `LicenseManager` decodes → selects `key_id` from
   `verification_keys.json` → Ed25519 verify → checks `kind=lifetime`, `v` supported,
   `hw_hash` equals current `HardwareFingerprintService.hash()` → writes `license.state`
   inside a DPAPI envelope + HMAC → returns status.
6. **Effect:** `license_guard` switches to `mode=lifetime, valid=true`; no expiry is ever
   computed; lock screen clears on next heartbeat/status read (no restart required).
7. **Free updates for life:** not enforced by code (nothing expires); upgrades preserve
   `<LICENSE_STATE_DIR>` (§4.5) and public-key rotation is supported via `key_id` — an
   updated build may carry additional public keys, and old activations remain valid.
8. **Failure modes:** unknown `key_id` → `license_invalid_key` (prompt for update);
   signature mismatch → `license_invalid`; wrong machine → `license_bound_elsewhere`
   (requirement C: contact owner for transfer — **not** a data lock; business routes stay
   blocked on that machine until a new code is issued).

**Key custody rules:** private keys exist only in the Generator (separate private repo);
`verification_keys.json`, `license.state`, and `trial.state` contain no private material;
`.gitignore` must reject `*.key`/`*.pem`/`*.p12` in this repository (verification that none
exist today: only third-party `LICENSE*` text files were found).

---

## 7. License transfer lifecycle

1. Customer installs Supermarket Pro on new **PC2** → PC2 produces its own activation request
   code (its `hw_hash` differs).
2. Customer sends the code **plus the original license reference** (license_id or owner's
   customer record) to the owner.
3. Owner verifies manually, then issues a **new signed activation** bound to PC2's `hw_hash`
   (same `license_id` for the owner's records; Generator can embed `supersedes` metadata).
4. Customer activates PC2 → PC2 becomes the licensed Main PC.
5. **PC1 behavior after transfer:** PC1 keeps its old `license.state`, but it still validates
   against **its own** hardware hash — it remains licensed until the owner chooses otherwise.
   There is **no promised revocation** of an offline PC1 (requirement C explicitly forbids
   promising it). Practical options offered to the owner, documented as *best-effort*:
   - re-issue PC1's code as revoked only when PC1 is next online against an owner-run check
     (does not exist today — out of scope),
   - contractual/policy level control (invoice, support),
   - **design position:** one license = one Main PC is enforced *at issue time* (the Generator
     must refuse to sign a second live binding for the same license_id without an explicit
     `--supersede` confirmation), not by remote kill.
6. **Data movement:** business data moves via **backup export → restore on PC2** (§8), which is
   deliberately hardware-independent; the license does **not** travel inside the backup.

---

## 8. Backup and restore lifecycle

| Stage | Rule | Enforcement point |
|---|---|---|
| Create (Trial) | ✅ allowed | `license_guard` allows `POST /backups` while `trial valid` |
| Create (Lifetime) | ✅ allowed | same |
| Download existing backup | ✅ allowed | `license_guard`; remains read-only and available after Trial expiry |
| Upload backup archive | ❌ blocked in Trial and expired Trial; ✅ Lifetime only | `license_guard` |
| **Restore (Trial)** | ❌ **forbidden** | double gate: `license_guard` on `POST /backups/{id}/restore` returns `403 trial_restore_forbidden`, **and** `BackupService.restore()` re-checks `LicenseManager` (defense in depth), **and** the Flutter restore button is disabled |
| **Restore (Lifetime)** | ✅ on **any** licensed Main PC — **no hardware comparison** | license status only; `fingerprint` is **never** consulted by `BackupService` |
| Integrity | SHA-256 of payload verified pre-restore (existing `backup.py:14,259`) | existing |
| Authenticity | manifest gains `format_version`, `payload_sha256`, `signature` + `key_id` (see below) | new |
| Schema compatibility | `schema_revision` vs current `alembic_version` (existing `inspect:343`) | existing |
| Never silent overwrite | `{"confirm": true}` + pre-restore **safety backup** + warning dialog (existing `backups.py:172-176`, `backup.py:229,259`) — **kept unchanged**, extended with explicit "this replaces ALL data on this PC" text | existing + UI text |
| License isolation | manifest contains **no license** and restore writes **no license** (state files live outside the DB) | structural (§4.2) |

**Manifest evolution (backward compatible):**

- Today's manifest keys (`backup.py:145-156`) stay; add:
  `format_version: 2`, `payload_sha256` (alias of/next to `sha256`), `created_by: {app_version, install_id}`,
  `signature`, `key_id`.
- **v2 backups** signed with the per-install `install.keypair` (public key embedded in the
  manifest) → validates *self-consistency* (tamper-evidence) and format provenance.
- **v1 backups** (existing, unsigned) must still restore: `format_version` absent → treat as 1,
  integrity via `sha256` only, plus structural checks (looks like `pg_dump` output —
  `_looks_like_sql():561` — and parses as manifest).
- **Honest limitation (documented in §9):** with trial-to-licensed cross-PC restore and no key
  registry available offline, *strong* origin authenticity (proving a backup came from a genuine
  Supermarket Pro copy) cannot be delivered by a key held in the customer app. What is delivered
  is: byte integrity (SHA-256), tamper-evidence (install-key signature), and format/schema
  validation. This satisfies "integrity and authenticity must be validated" to the maximum extent
  possible offline without embedding private keys.

**Cross-PC scenario (requirement D example), verified against the design:** PC1 trial →
`POST /backups` + download (allowed) → trial expires → PC2 installed, activated with owner's
code (lifetime) → `POST /backups/upload` + `POST /{id}/restore` → SHA-256 + schema check +
safety backup → data restored. No step reads PC1's or PC2's hardware fingerprint.

**Restore side effects to surface in the warning dialog (existing behavior, must be stated to
the user):** restore overwrites *all* tables, including `users`, `roles`, `auth_sessions`
(all sessions invalidated), `devices` (PC2's paired LAN clients are replaced by PC1's registry
→ LAN clients may need re-pairing), and `app_settings`. `server_id` lives in
`data/server_id` (file) and survives; license state survives (outside DB). This is existing
behavior of `psql` full-replay restore (`backup.py:219+`), not a new risk.

---

## 9. Security risks and limitations

| # | Risk | Severity | Mitigation / honest limitation |
|---|---|---|---|
| R1 | Local admin edits `trial.state`/`license.state` | Medium | DPAPI machine-scope envelope + HMAC; atomic writes. **Cannot be fully prevented offline** — accepted limitation; no claim otherwise |
| R2 | Clock rollback to extend trial | Medium | `max_seen_at` monotonic guard persisted on every evaluation; detected rollback clamps forward. Defeated only by full re-image |
| R3 | Trial file deleted to restart trial | Low (by policy) | **Allowed by design** — requirement A explicitly wants one trial per *installation*, not per PC. Deleting the file is equivalent to reinstalling |
| R4 | Private signing key leakage | Critical | Key never ships: Generator is a separate private repo; CI/repo scans for `*.key`/`*.pem`; `verification_keys.json` holds public keys only |
| R5 | Activation code replay on a second PC | Medium | `hw_hash` bound in the signed payload; second PC verifies against its own hash → `license_bound_elsewhere` |
| R6 | Client fakes "licensed" status | High if client were authority | Client is **never** an authority (§4.4); data refusal happens server-side at P1 |
| R7 | LAN client bypasses by talking to DB | High (legacy flaw) | Not possible: clients have no DB access by design (Phase 16, `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md:20-31`); backend is the only DB holder |
| R8 | Backup used to move a license to another PC | High | License outside DB → structurally absent from dumps (§4.2) |
| R9 | Backup restore overwrites live data unexpectedly | High | Existing confirm + safety backup + inspect; add explicit warnings (§8) |
| R10 | Backup forgery (crafted `.sql`) | Medium | Integrity hash + install-key signature (v2) + schema check; **residual:** an attacker can create their own install keypair → documented as tamper-evidence, not publisher authenticity |
| R11 | Public key rotation / old builds | Low | `key_id` multi-key verification; new builds can ship added keys; old builds keep verifying older keys |
| R12 | Backend absent / not started (no service today) | Medium | Existing behavior: client shows connection errors. Licensing must not be confused with connectivity (Decision D5) |
| R13 | TPM absence/failure | Low | TPM **not** mandatory; optional seal only; DPAPI always available on Windows |
| R14 | Reverse proxy on loopback would defeat device-guard loopback rule | Low | Pre-existing caveat documented in `device_guard.py:100-104`; unchanged by this work; license guard has no loopback exemption anyway |
| R15 | `LAN_MODE=0` default means device guard is off in single-PC mode | Info | License guard deliberately independent of `LAN_MODE` so trial/license works in desktop mode too |

**Offline vs admin summary:** everything is verifiable offline (signatures, trial time,
backup hashes). Nothing is enforceable against an administrator of the *same* machine —
DPAPI/HMAC/monotonic counters raise the cost from "edit a text file" to "re-imaging or binary
patching", which is the accepted boundary for an offline-activated desktop product.

---

## 10. Database and migration requirements

**Finding: no database schema change is required for the core licensing system.**

| Question | Answer | Evidence |
|---|---|---|
| New tables/columns for license info? | **No.** Recommended store is file-based (`<LICENSE_STATE_DIR>`), mirroring `SERVER_ID_FILE` precedent | `config.py:101`, `server_identity.py:58`; requirement D/D-8 (license must be absent from backups) |
| Trial state separate from business data? | **Yes — structurally separate** (different storage medium, not merely a different table) | §4.2 |
| Backup metadata versioned format? | **Yes — additive manifest fields** (`format_version`, signature). No change to the `.sql` payload | `backup.py:145-156` |
| Existing schema changes necessary? | **None for core features** | 37-revision chain intact; migrations manual (`docs/PHASE_0_INSTALLATION_DEPLOYMENT_AUDIT.md:80`) |
| Optional future migration? | Only if we choose a DB audit slice for license events: `audit_logs.module` is `VARCHAR(30)` → **a new `license` value needs no DDL**; but a dedicated `license_events` table *would* need a new Alembic revision | `migrations/...0031:53`, `models/audit.py:65` |
| Anti-recommendation | **Do not** store license/trial in `AppSetting` (`app/models/settings.py:51`) or any table | would be captured by every `pg_dump` and restored across PCs (violates D) |

No migration is created or executed in this phase (rule 4).

---

## 11. Exact files that would need modification in future phases

### 11.1 New files (backend)

| File | Purpose | Phase |
|---|---|---|
| `new_app/backend/app/licensing/__init__.py` | package | L0 |
| `new_app/backend/app/licensing/state_store.py` | atomic file state, DPAPI envelope, HMAC | L0 |
| `new_app/backend/app/licensing/fingerprint.py` | `HardwareFingerprintService` | L1 |
| `new_app/backend/app/licensing/trial.py` | `TrialManager` | L1 |
| `new_app/backend/app/licensing/license.py` | `LicenseManager` (Ed25519 verify) | L2 |
| `new_app/backend/app/licensing/guard.py` | `license_guard` dependency | L1 |
| `new_app/backend/app/licensing/verification_keys.json` | public keys (`key_id` → key) | L2 |
| `new_app/backend/app/api/v1/license.py` | status / activation-request / activate routes | L2 |
| tests: `new_app/backend/tests/unit/test_license_guard.py`, `test_trial_manager.py`, `test_activation_verify.py`, `test_fingerprint.py`, `test_backup_manifest_v2.py`, `tests/integration/test_restore_license_gate.py` | coverage | L1–L3 |

### 11.2 Modified files (backend)

| File | Change | Risk |
|---|---|---|
| `new_app/backend/app/api/v1/router.py:52` | add `Depends(license_guard)` to the dependency list | **highest-leverage, single line** — must be ordered after `device_guard` (license errors should not mask pairing errors) and must not alter device-guard behaviour |
| `new_app/backend/app/api/v1/router.py:54-94` | include the new `/license` router | low |
| `new_app/backend/app/api/v1/system.py:37-58, 66-87` | additive `license` field in `SystemInfoResponse` + fill in `get_system_info` | low (additive; `protocol` untouched → no discovery/protocol change) |
| `new_app/backend/app/core/config.py:93-113` (settings block) | add `LICENSE_ENFORCEMENT`, `LICENSE_STATE_DIR`, `TRIAL_DAYS`; no `LICENSE_REQUIRE_FOR_LAN` switch because Trial LAN serving is approved | low; must be additive with safe defaults so existing dev/test flows (`LAN_MODE=0`) keep passing |
| `new_app/backend/app/main.py:16-31` | lifespan: initialize `StateStore`/`TrialManager` (start trial on first run) | low; must never block startup on state-file errors (mirror the discovery start pattern at `:20-24`) |
| `new_app/backend/app/services/backup.py:145-156` (create/manifest), `:219` (restore), `:343` (inspect) | manifest v2 fields + signature; license precondition in `restore`; signature validation in `inspect` | medium — **backward compatibility with v1 manifests is a hard requirement** |
| `new_app/backend/app/api/v1/backups.py:156` | surface typed license errors (403 codes) | low |
| `new_app/backend/app/core/constants.py` / error code registry (`app/core/exceptions.py:212+`) | new error codes: `trial_expired`, `license_required`, `trial_restore_forbidden`, `license_invalid`, `license_bound_elsewhere` | low — follow existing `AppError` handler pattern |
| `new_app/backend/pyproject.toml:6-25` | promote `cryptography` to a direct dependency | none |
| `new_app/backend/.env.example` | document new settings | none |
| `new_app/backend/app/models/enums.py:271` (`AuditModule`) | optional `LICENSE = "license"` value (Python-only; `module` is `VARCHAR(30)`) | none |

### 11.3 New files (Flutter)

| File | Purpose |
|---|---|
| `new_app/lib/features/license/license_providers.dart` | `LicenseNotifier`, status from `/system/info`, `licenseGateProvider` |
| `new_app/lib/features/license/license_screen.dart` | activation-code entry + hardware code display |
| `new_app/lib/features/license/license_lock_screen.dart` | expired/unlicensed lock UI |
| `new_app/lib/features/license/trial_banner.dart` | countdown banner |
| tests: `new_app/test/unit/license_models_test.dart`, `new_app/test/widget/license_lock_screen_test.dart`, `new_app/test/widget/license_gate_router_test.dart` | coverage |

### 11.4 Modified files (Flutter)

| File | Change | Risk |
|---|---|---|
| `new_app/lib/router/app_router.dart:76-127` | one more redirect rule (license gate) placed **after** splash/first-run and **before** business routes; keep `/login`, `/setup-network`, `/setup` reachable when locked | medium — redirect order is subtle; existing tests `test/widget/first_run_router_test.dart`, `startup_splash_test.dart` must keep passing |
| `new_app/lib/features/devices/connection_provider.dart:674-724` | parse `license` from the **existing** `/system/info` heartbeat response into `LanConnectionState` (`:125`) as a **new field** (`licenseValid`, `licenseMode`) — do **not** change `mutationsAllowed` semantics (`:184`) | medium — heartbeat failure counting (`:726-747`, threshold `constants.dart:23`) must not treat license-expired as a connection failure |
| `new_app/lib/features/backup_restore/backup_restore_screen.dart:143-265, 334-384` | Trial: allow create/download, disable upload and restore. Expired Trial: allow listing/downloading existing backups only. Lifetime: allow upload/restore. | low |
| `new_app/lib/features/settings/settings_screen.dart:135-158, 868` | add a "License" section to the settings list (existing pattern `_BackupSection`) | low |
| `new_app/lib/core/strings.dart` | new EN/FR/AR strings (localization parity tests exist: `test/unit/localization_parity_test.dart`) | medium by volume, low by risk |
| `new_app/lib/network/api_client.dart:42-46` | add license error codes to `deviceGuardErrorCodes`-style handling so the interceptor can surface `trial_expired`/`license_required` | low |
| `new_app/pubspec.yaml:9-27` | only if a crypto/uuid helper is needed client-side (**expected: none**) | none |

### 11.5 Explicitly untouched

`app/api/device_guard.py`, `app/discovery/*`, `app/services/devices.py`,
`app/models/device.py`, pairing endpoints, `lib/features/discovery_service.dart` packet format,
`LanPhase` state machine/backoff, all business domain code, all migrations,
`python_app/**` (legacy reference only), and `new_app_upload/**` (paused project).

---

## 12. Ordered implementation plan (phases)

Each phase ends green: `pytest` (backend), `flutter analyze` + `flutter test` (client),
`ruff`/`mypy` (backend lint), with enforcement **off** by default until Phase L4.

- **Phase L0 — Foundations (no behavior change)**
  `StateStore` + config settings + error-code registry + verification-keys loader + empty
  `license_guard` behind `LICENSE_ENFORCEMENT=off`. Unit tests for state I/O, DPAPI fallback,
  atomicity. *Exit:* all existing tests pass unchanged.

- **Phase L1 — Trial Manager + locking**
  `TrialManager`, fingerprint service, trial start on first backend start, 10-calendar-day
  expiry, guard enforcement for trial state (`LICENSE_ENFORCEMENT=trial`), restore and backup
  upload forbidden during Trial (API + service + UI), active-Trial LAN serving, expired-Trial
  read-only backup listing/download, pre-login activation route access, lock screen + router
  gate + banner, `/system/info` license field, heartbeat parsing.
  *Exit:* new trial matrix tests; 2-PC pairing/heartbeat/reconnect regression passes.

- **Phase L2 — Lifetime activation (offline Ed25519)**
  `LicenseManager`, `verification_keys.json`, `/api/v1/license/*` routes, activation UI,
  invalid/wrong-machine paths, key-id rotation test, **License Generator built in a separate
  private repo** (out of this repository). *Exit:* full activation matrix + transfer-by-
  reissue test with two fingerprints.

- **Phase L3 — Backup manifest v2 + restore authorization**
  Manifest `format_version`/signature, v1 compatibility, upload and restore gated on Lifetime
  (API + service + UI), cross-PC restore test (trial-created backup exported from PC1 → licensed
  PC2), expired-Trial download-only test, warning-dialog content. *Exit:* legacy backups still restore; trial restore refused at
  all three layers.

- **Phase L4 — LAN propagation + audit**
  License status surfaced through the existing heartbeat (P2/P3), client lock display in
  client mode, tests proving active-Trial Main PC serves paired clients and expired/invalid Main
  PC blocks their business operations, license events into
  `audit_logs` (`module='license'`, no DDL), documentation. *Exit:* full LAN regression
  (pair, heartbeat, revoke, reconnect, server_id change).

- **Phase L5 — Installer integration + hardening + QA**
  Installer decision C1 (new empty DB identity on fresh install; preserve old DB/backups; delete
  `<LICENSE_STATE_DIR>` on uninstall), production default `LICENSE_ENFORCEMENT=on`, key-rotation runbook,
  clock-rollback and tamper QA, full regression + manual QA checklist
  (mirroring `docs/POST_PHASE_17_MANUAL_QA.md` style).

**Dependencies:** L1 needs L0; L2 needs L0; L3 needs L2 (signature) but can start trial-gating
in parallel with L2; L4 needs L1+L2; L5 needs everything. L2's Generator is a parallel
workstream in a separate repository.

---

## 13. Testing strategy and regression risks

### 13.1 New tests

- **Unit (backend):**
  - `trial`: fresh start, active window, expiry boundary (exactly 240h/10d), clock rollback,
    `max_seen_at` persistence, reinstall reset (delete state dir)
  - `fingerprint`: stability across runs, sensitivity to component change, no PII in display code
  - `activation verify`: known-good vector, bit-flip in payload/signature → reject, unknown
    `key_id`, wrong `hw_hash`, unsupported `v`, key rotation (two keys live)
  - `guard matrix`: one test per §4.4 cell (parameterized over route classes × 4 states),
    loopback peer **is** gated, `LAN_MODE=0` and `=1` both enforced
  - `backup`: v1 manifest restores, v2 signature valid/tampered, restore refused in trial,
    restore allowed in lifetime with **foreign** fingerprint (no comparison)
- **Integration (existing PG test harness, `tests/integration/`):** full create→inspect→
  download→upload→restore round-trip across states; schema-revision mismatch refusal;
  safety-backup creation; cross-PC simulation by swapping `LICENSE_STATE_DIR`
- **Widget (Flutter):** lock screen rendering per status, router redirect ordering
  (splash → first-run → login → license gate → shell), banner countdown, restore button
  disabled in trial, activation entry happy/invalid paths
- **Security/abuse:** oversized/garbage activation codes (fuzz decode path), state-file
  truncation/corruption (fail-closed, not fail-open), rate limiting on `/license/activate`
  (reuse `enforce_rate_limit`, `app/core/rate_limit.py:95`), ensure error responses leak no
  key material

### 13.2 Regression risks (highest first)

| Risk | Why | Mitigation |
|---|---|---|
| **Router dependency ordering** (`router.py:52`) | A faulty guard would block *every* route including auth/health | Allowlist mirrors `device_guard.ALLOW_PATHS`; `LICENSE_ENFORCEMENT=off` default in dev/test; dedicated health-check test asserting `/health` + `/auth/login` reachable in every state |
| **Redirect chain changes** (`app_router.dart:76-127`) | Could strand first-run or login flows | Place gate after first-run/auth; run `first_run_router_test`, `startup_splash_test`, `boot_reconnect_test` unchanged |
| **Heartbeat semantics** (`connection_provider.dart:674-724`) | Counting a license field as heartbeat failure would falsely disconnect tills | Parse license **informationally**; never increment `consecutiveFailures`; verify with `connection_state_test`, `boot_reconnect_test` |
| **`SystemInfoResponse` is a `StrictBaseModel`** (`system.py:37`) | Strictness could reject additive fields or clients could choke | Add field **with a default**; Dart `fromJson` ignores unknown keys; protocol field untouched → no `PROTOCOL_VERSION` bump |
| **Backup v1/v2 compatibility** | Existing customer backups must keep restoring | Absent `format_version` ⇒ v1 path; dedicated legacy-manifest fixture test |
| **Device Guard interaction** | Two router dependencies could mask each other's error codes | Ordered `device_guard` → `license_guard`; license guard allowlists `/devices` and `/auth` so pairing errors stay attributable |
| **Localization parity** | New strings without FR/AR fail `localization_parity_test` | Add all keys in one pass across `strings.dart` |
| **Performance** | State read per request | In-process cached status + mtime-based invalidation (pattern: `rate_limit.py` process-local limiter) |
| **LAN pairing/revocation** | Must not regress Phase 16 | Explicit 2-PC regression suite; no edits to discovery/pairing/device files (§11.5) |
| **`mutationsAllowed` (`connection_provider.dart:184`)** | Widening/narrowing it changes POS write gating everywhere | Add a **separate** `licenseAllowsBusiness` field/provider; leave `mutationsAllowed` semantics untouched |

### 13.3 Environments

- Single-PC (LAN_MODE=0) desktop flow; LAN server (LAN_MODE=1, DISCOVERY_ENABLED=1) with two
  real PCs (existing Phase 16 methodology, `docs/PHASE_16_IMPLEMENTATION.md`); trial clock
  simulation via injectable clock (never by actually waiting 10 days).

---

## Decision status after owner sign-off (2026-11-03)

The owner has resolved C1 and approved D1–D6. These are binding requirements for subsequent
implementation phases; they are no longer open questions:

| Decision | Approved behavior |
|---|---|
| C1 | Preserve old database/backups; fresh install uses a new empty database identity/name. |
| D1 | Active Trial Main PC may serve authorized LAN clients; clients inherit its Trial entitlement. |
| D2 | 10 continuous calendar days (240 elapsed hours) from first backend start. |
| D3 | After expiry, list/download existing backups only; no new backup creation. |
| D4 | Activation UI and narrowly scoped activation endpoints work before login. |
| D5 | Trial starts at first backend start, not Flutter startup. |
| D6 | Backup upload is blocked during Trial; Trial export/download remains allowed. |

## Appendix A — Resolved architectural decisions

**C1 — Fresh empty database while preserving old customer data — RESOLVED**
- On uninstall/reinstall, preserve the old PostgreSQL data and backup files; never silently
  delete them.
- A fresh installation must create/select a **new, empty database** (new database identity/name)
  and must not automatically attach to or adopt the previous installation's database.
- Old data can be brought into the new installation only after a valid Lifetime License is
  activated and the customer explicitly uploads/restores a backup. This preserves the data while
  ensuring a reinstall starts with an empty Trial.

**D1 — Trial Main PC may serve LAN clients — APPROVED: YES**
- An active Trial on the Main PC is sufficient to serve authorized, paired LAN clients during
  the 10-day trial. LAN clients inherit the Main PC's Trial entitlement; they do not receive or
  need individual licenses.
- After the Main PC's Trial expires, the backend blocks business operations for both the Main PC
  and all LAN clients. The Main PC remains the sole licensing authority.

**D2 — Trial duration — APPROVED: 10 CALENDAR DAYS**
- Trial runs continuously for 10 calendar days (240 elapsed hours) from the first backend start
  that creates `trial.state`, whether the application is open or closed. It is not cumulative
  runtime.

**D3 — Expired Trial backup rescue — APPROVED: DOWNLOAD ONLY**
- After Trial expiry, allow listing and downloading backups that already exist. These are
  read-only data-rescue operations.
- Block creating new backups after expiry; normal business operations remain locked.

**D4 — Activation UI before login — APPROVED: YES**
- The activation screen and activation-code entry must be reachable before user login, including
  on a locked/expired installation.
- The narrowly scoped activation-request/status/activate endpoints must be allowlisted so the
  customer can activate without an authenticated admin session. Keep strict input validation,
  rate limiting, signed-code verification, and hardware binding. Do not expose business data or
  general settings through this exception.

**D5 — Trial start trigger — APPROVED: FIRST BACKEND START**
- Trial starts when the backend first starts and initializes the trial state. The backend remains
  the authority; Flutter startup time does not start or pause the clock. This is consistent with
  the current architecture where Flutter does not spawn the backend.

**D6 — Backup upload during Trial — APPROVED: BLOCK UPLOAD**
- During Trial, allow backup creation and download/export, but reject `POST /backups/upload`.
- After Trial expiry, allow download of existing backups only; block create, upload, and restore.
- Lifetime-licensed Main PCs may upload and restore valid backups, including backups originally
  exported from a different Trial PC. Backup remains hardware-independent.

---

## Appendix B — Phase 1 audit provenance and compliance confirmation

This v2 document updates the original read-only audit with the owner's approved decisions. It is
an architecture specification only; it does not represent implementation or a change to the
Supermarket Pro repository.

- The original Phase 1 audit was read-only against the project. This v2 is a separate updated
  specification copy; no existing project source/configuration file was modified, deleted,
  renamed, or moved.
- No Git reset/clean/checkout/stash/rebase or any destructive Git command was executed; no
  commit or push was made.
- `new_app_upload/`, `new_app_upload.zip`, and `tatus` were not opened or modified.
- No database was accessed, modified, or migrated; no migration file was created or executed.
- No licensing functionality was implemented; no LAN/Phase 16 code was redesigned or replaced.
- Owner decisions C1 and D1–D6 are now incorporated as approved requirements; no unresolved
  owner decisions remain in this appendix.
- All findings above are evidence-based with `file_path:line` references to the actual code.
