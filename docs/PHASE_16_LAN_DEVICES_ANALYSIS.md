# PHASE 16 — LAN / MULTI-PC / DEVICES — ANALYSIS & SPECIFICATION (STEP A)

**Status:** ANALYSIS ONLY — no features implemented, no application code modified, no
dependencies added, no migrations created, no commits/pushes.

**Baseline:** Phase 15 closed at commit `b084d3d` ("phase-15: complete printing and
exports"). This document depends on Phases 0, 3, 8, 14 and 15 and preserves every
frozen contract of those phases.

**Objective of this document:** audit the repository at `b084d3d` and produce the
complete Phase 16 architecture/specification — server/client model, discovery
protocol, pairing, device registry, connection state machine, failure semantics,
API/RBAC/audit contracts, security threat model, gates and owner questions — so that
implementation (Step B) proceeds against explicit, evidence-based decisions.

---

## 1. Executive summary

Phase 16 delivers reliable LAN / multi-PC operation for Supermarket Pro:

- **Server mode** — the store PC runs FastAPI + PostgreSQL, binds the LAN, answers
  UDP discovery, manages an approved-device registry, and enforces device-level
  authorization on API traffic.
- **Client mode** — a till PC runs only Flutter, discovers or is told the server
  address, requests pairing with a pairing code, waits for human approval, then
  operates through the same authenticated API. **It never touches PostgreSQL**
  [PHASE-0].
- **Connection monitoring** — HTTP health heartbeat, exponential-backoff
  auto-reconnect, and a persistent status indicator; a LAN outage never corrupts a
  completed transaction (Phase 8 `client_request_id` idempotent replay).

**The single most important architectural fact:** the legacy implementation is an
anti-pattern reference only — legacy clients connected *directly to MySQL with root
credentials* and "discovery" was a /24 scan for open port 3306
[LEGACY `db_manager.py:470-483`, `network_discovery.py:51-52`]. Phase 16 implements
none of that. The modern topology mandated by Phase 0 is preserved exactly:
*Flutter → authenticated HTTP over LAN → FastAPI → local PostgreSQL*
[PHASE-0 `PHASE_0_ARCHITECTURE.md:33`].

**Current state at baseline** [MODERN]: device *attribution* exists (free-text
`X-Device-ID` header on 6 endpoints, `device_id` columns on 7 tables, report device
breakdown [PHASE-14]) but device *registry, discovery, pairing and connection
monitoring do not exist at all* — no `devices` table, no `/devices` route, no
WebSocket, no connectivity polling, hardcoded `http://localhost:8000`
[MODERN `api_client.dart:117`]. Two artifacts are already reserved for Phase 16:
permission scope `device_manage` (`enums.py:67`) and `DeviceStatus`
(`enums.py:171-174`), both currently unused.

**Headline decisions proposed by this analysis** (details + gates below):

| # | Decision | Rationale |
|---|---|---|
| D1 | One `devices` PostgreSQL table; pending requests are rows with `status='pending'`; no separate pairing/sessions tables | Phase 0 blueprint lists `devices` [PHASE-0 DB]; legacy proved one-table pairing suffices [LEGACY]; avoids overengineering |
| D2 | UDP discovery on **the same port number as HTTP (default 8000/udp)**, configurable; packet contains no secrets | one port number to remember/firewall; documented, not arbitrary |
| D3 | "TCP discovery" = HTTP probe (`/health` + `/system/info`) of *candidate addresses only* — **never a subnet sweep** | Phase 0 explicitly rejects /24 scans [PHASE-0 PERF:10] |
| D4 | Pairing requires a 6-digit **pairing code** shown on the server screen + human approve/reject (admin, `device_manage`) | Phase 0 security recommendation "pairing with one-time code" [PHASE-0 SEC:15]; blocks blind auto-approval |
| D5 | Server issues a random **device token** once at approval; SHA-256 hash stored (same pattern as `AuthSession.token_hash`); client stores it in `flutter_secure_storage` | reuses proven auth primitive; no second unrelated auth system |
| D6 | Device enforcement is a router-level guard **active only in `LAN_MODE`** | zero behavior change for single-PC mode and the entire existing test suite |
| D7 | No offline writes: when disconnected, all mutations are disabled with localized messaging; safe retries reuse Phase 8 idempotency | Phase 0 requires the policy be *designed* [PHASE-0 ARCH:63]; inventing offline sales would invent business semantics |
| D8 | HTTP `/health` heartbeat (10 s) + exponential backoff with jitter (1→30 s); no WebSocket | no WebSocket exists anywhere [MODERN]; roadmap says "connection monitoring", not realtime |
| D9 | **No new dependencies** (backend: stdlib `socket`/`json`; Flutter: `dart:io` `RawDatagramSocket`) | minimal churn; UDP is a stdlib primitive on both sides |
| D10 | Exactly **one migration**: `devices` table; no backfill; Phase 14 `device_id` contract untouched | compatibility (§26) |

---

## 2. Scope

### 2.1 In scope (roadmap, verbatim) [PHASE-0 `PHASE_0_ROADMAP.md:665-703`]

- Features: server/client mode · device discovery (UDP + TCP) · pairing approval ·
  connection monitoring · auto-reconnect · status indicator
- Backend: device service · discovery responder · pairing management · connection
  health check
- Flutter: device setup wizard · pairing approval dialog · connection status
  indicator · reconnect dialog
- Tests: discovery tests · pairing tests · connection monitoring tests
- Acceptance: server mode works · client mode works · device discovery works ·
  pairing approval works · connection monitoring works

### 2.2 Explicitly out of scope (§31)

Backup, general settings UI, final installer, fiscal fields, report-formula changes,
Phase 15 printing redesign, ESC/POS, purchase printing, Z-report, dashboard PDF,
direct PostgreSQL access from Flutter, offline sale queue, WAN/Internet operation,
broad UI redesign. Phase 15 **physical printer QA remains deferred** (hardware not
available — not a software failure).

---

## 3. Baseline

| Item | Value |
|---|---|
| Commit | `b084d3d phase-15: complete printing and exports` |
| Prior | `879c8e5 phase-14`, `7e15343 phase-13` |
| Working tree | clean except 2 stale Phase 14 CSV exports (`new_app/reports_*.csv`, untracked, unrelated) |
| Backend suite | 1061 passed / ruff `app` = 64 baseline [verified at Phase 15 close] |
| Flutter suite | 1163 passed / `flutter analyze` clean / Windows debug build OK |
| Migrations | 20 alembic revisions (`0001` … `0020_phase14_report_indexes`) |
| Test files | backend 45 (39 unit + 6 integration, 6 require PostgreSQL), Flutter 62 (33 unit + 29 widget) |

---

## 4. Evidence sources

| Class | Meaning |
|---|---|
| **[MODERN]** | verified in current code (`new_app/` Flutter + `new_app/backend/` FastAPI) |
| **[PHASE-0]** | approved Phase 0 docs (`docs/PHASE_0_*`) |
| **[PHASE-8]/[PHASE-11]/[PHASE-14]/[PHASE-15]** | frozen prior-phase contracts |
| **[LEGACY]** | `python_app/` behavioral evidence only — never copied blindly |
| **[UNVERIFIED]** | requires runtime/hardware/owner evidence — never silently resolved |

Primary sources inspected: `new_app/backend/app/{main.py,core,api,models,services,db}` +
`migrations/` + `tests/`; `new_app/lib/{network,features,router,core,l10n}` +
`test/`; `docs/PHASE_0_{ROADMAP,API_BLUEPRINT,ARCHITECTURE,SECURITY_AUDIT,DATABASE_ANALYSIS,BUSINESS_RULES,MASTER_SPECIFICATION,PERFORMANCE_AUDIT,POS_WORKFLOW}.md`;
`docs/PHASE_{2,3,8,9,11,12,13,14,15}_*`; `python_app/{utils/network_discovery.py,database/db_manager.py,gui/main_window.py,server/server.py,config,security}`.

---

## 5. Current modern architecture audit [MODERN]

### 5.1 Process/topology today

- FastAPI app factory `app/main.py:22-61`; lifespan does **only** logging setup
  (`main.py:15-19`) — no discovery, no DB ping, no seed at startup.
- Launch: `python -m uvicorn app.main:app --host 127.0.0.1 --port 8000`
  (`command.txt:1`); `settings.HOST`/`settings.PORT` (`config.py:43-44`) are **dead
  config — 0 references in `app/`**. Only `PHASE_1_SETUP.md:24` shows `0.0.0.0`.
- CORS: `allow_origins=["http://localhost:3000","http://localhost:8080"]`
  (`config.py:37`, `main.py:43-49`). Non-issue for Flutter Desktop (Dio is not a
  browser client) but relevant if a browser client ever appears.
- Middleware: `RequestIDMiddleware` preserves/generates `X-Request-ID`, binds it to
  structlog, echoes it on the response (`middleware.py:22-42`).
- No WebSocket anywhere (`grep websocket app/` → 0). No rate limiting anywhere
  (`grep rate.?limit` → 0). No devices/pairing/discovery code anywhere.

### 5.2 Configuration surface (`app/core/config.py:19-47`)

`APP_ENV`, `APP_SECRET_KEY`, `VERSION="0.1.0"`, `DATABASE_URL` (required, no
default), `JWT_SECRET_KEY`, `JWT_ALGORITHM=HS256`, `JWT_ACCESS_TOKEN_EXPIRE_MINUTES=480`,
`SESSION_LIFETIME_MINUTES=480`, `LOCKOUT_THRESHOLD=5`, `LOCKOUT_DURATION_MINUTES=15`,
`CORS_ORIGINS`, `LOG_LEVEL`, `HOST=127.0.0.1`, `PORT=8000`, `STORE_NAME`.
`.env.example` mirrors `HOST=127.0.0.1`, `PORT=8000`, PostgreSQL URL on `localhost:5432`.
**No device-related settings exist.**

### 5.3 AuthN / session lifecycle

- JWT payload is minimal: `{"sub": user_id, "sid": session_id, "exp", "iat"}`
  (`security.py:93-98`) — **no role, no device claim**; permissions are resolved
  from DB per request.
- Login `POST /api/v1/auth/login {user_id, pin, device_name}` (`api/v1/auth.py:103`);
  `device_name` is free text stored on the `AuthSession` row (`user.py:185`).
- Token revocation exists: `AuthSession.token_hash` (SHA-256, unique, indexed),
  `logout()` sets `revoked_at` (`services/auth.py:292-307`); `get_current_user`
  re-verifies session + hash on every request and updates `last_seen_at`
  (`dependencies.py:76-93`).
- **No refresh tokens** (0 matches). Argon2id PIN hashing (`security.py:40-69`).
  Account lockout 5/15min; **no request rate limiting**.

### 5.4 RBAC

- 30 scopes in `PermissionScope` (`enums.py:18-68`), incl. **`DEVICE_MANAGE` (line 67,
  never used by any route)**. Seeding: `admin = list(PermissionScope)` (all 30),
  manager 23 (explicit list, **does not include `device_manage`**), cashier 11
  (`seed.py:36-89`) → **`device_manage` is admin-only**.
- `require_permission(scope)` / `require_any_permission(*scopes)` factories
  (`dependencies.py:106-144`); `has_permission` walks users→roles→permissions
  (`models/user.py:113-118`).
- `DeviceStatus` enum exists — `pending/approved/rejected` (`enums.py:171-174`),
  exported (`models/__init__.py:15,85`), **referenced nowhere**.

### 5.5 Health / system

- `GET /api/v1/health` → `{status, version, environment, database, timestamp}`
  with `SELECT 1` DB probe (`health.py:47-67`); `/health/live`; `/health/ready`
  (`:70-101`). Public (no auth).
- `GET /api/v1/system/info` → `{name, version, environment, database_status,
  timestamp}` (`system.py:35-42,77-90`) — exposes no OS/IP/host data. **No
  `server_id`, no protocol field.**

### 5.6 device_id handling (attribution, not registry)

- Origin: **`X-Device-ID` request header**, read per-endpoint (no middleware),
  on: `POST /sales`, `/sales/{id}/void`, `/returns`, `/expenses`, `/exports`,
  `/print` (`pos.py:86,159`, `returns.py:54`, `expenses.py:57`, `exports.py:48`,
  `print.py:57`). Also body fields (`schemas/sale.py:82` etc., header wins —
  `services/sale.py:767`) and report query params (`reports.py:56…218`).
- Columns `device_id String(100) nullable` on 7 tables: `audit_logs`, `expenses`,
  `sales`, `returns`, `purchases`, `inventory_movements`, `pos_holds` (indexed).
- Reports group by `device_id`, `NULL → "unknown device"` (R15 device breakdown,
  `services/report.py:272-302`) [PHASE-14]. Phase 15 audit rows carry `X-Device-ID`
  → `device_id` (`services/print.py:64-67`, `services/export.py`) [PHASE-15].
- **No foreign key, no validation, no registry** — free text everywhere.

### 5.7 Error envelope / conventions

Typed envelope `{error:{code, message_key, message, details, request_id}}`
(`exceptions.py:266-277`); codes: `VALIDATION_ERROR 422`, `AUTHENTICATION_ERROR/
UNAUTHORIZED 401`, `AUTHORIZATION_ERROR/FORBIDDEN 403`, `NOT_FOUND 404`, `CONFLICT
409`, `BUSINESS_RULE_ERROR 422`, `DATABASE_ERROR 500`, `SERVICE_UNAVAILABLE 503`,
plus Phase 15 export/print codes. Every response carries `X-Request-ID`.

### 5.8 Database / transactions / migrations

- PostgreSQL production (`pyproject: psycopg2-binary`; `.env.example:19`); SQLite is
  test-only (`tests/conftest.py:22`). Engine: `pool_size=5, max_overflow=10,
  pool_pre_ping=True, pool_recycle=3600` (`db/engine.py:36-43`); **no explicit
  isolation level** (PG default READ COMMITTED).
- Request session `get_db` (`db/session.py:15-26`); one transaction per service
  command (`services/base.py:46-74`).
- 20 alembic revisions; PG-only partial indexes exist (`0018:102`).

### 5.9 Idempotency + locking (foundation for multi-PC) [PHASE-8/9/11]

- `client_request_id` required on sales (`schemas/sale.py:76`), unique index
  (`models/sale.py:50-54`); fast-path replay before tx (`services/sale.py:761-779`),
  IntegrityError → rollback → re-fetch winner → `idempotent_replay=true`
  (`:932-953`); stock decremented once. Same pattern: returns, expenses (payload
  signature → 409 `IDEMPOTENCY_CONFLICT`), purchases, debt/supplier payments.
- Row locks: `SELECT … FOR UPDATE` on customer/supplier/purchase rows
  (`services/sale.py:259`, `debt.py:139`, `purchases.py:429…`), guarded stock
  UPDATE rowcount (`sale.py:840`), ordered lock acquisition (Phase 11 G17).
- Proven by 6 PostgreSQL integration tests (`tests/integration/*concurrency*`).

### 5.10 Flutter audit highlights

- **Base URL hardcoded**: `baseUrl ?? 'http://localhost:8000'`
  (`lib/network/api_client.dart:117`); production constructs `ApiClient()` with no
  override (`auth_provider.dart:320-322`). Constructor param exists but is
  production-unused → **no way to point the app at a LAN server today**.
- Timeouts: `connectTimeout/receiveTimeout = 30s` (`constants.dart:11`); no
  sendTimeout; no retry interceptor. Two interceptors only: auth-expiry (401) +
  silenced log (`api_client.dart:127-133,159-178`).
- Token: `flutter_secure_storage` keys `auth_access_token`… (`credential_storage.dart:5-11`);
  startup restore via `POST /auth/verify-token` (no refresh) (`auth_provider.dart:75-149`).
- 401 → `clearToken` + `AuthStatus.sessionExpired` → router redirect
  (`app_router.dart:40-64`).
- **device_id**: generated once as `pos-<epochMillis>-<random>` in SharedPreferences
  key `pos_device_id` (`pos_providers.dart:27-41`), a *POS-feature-local* FutureProvider
  — not an app-level identity. `X-Device-ID` attached manually at 5 call sites, never
  as a global header.
- **No connectivity code whatsoever**: no `connectivity_plus`, no `Timer.periodic`
  (0 matches), no health polling (0 matches for `/health` in Dart), no WebSocket, no
  lifecycle observer. Recovery today = user presses retry buttons (10 features) or
  restarts the app.
- Startup: `main.dart:26-38` loads SharedPreferences (2 overrides), splash while
  `AuthStatus.checking` (`main.dart:47-74`), first-run decided by backend
  `GET /auth/setup/check`.
- App shell = `ScaffoldWithNav` in `app_router.dart` — AppBar actions at
  `:419-459` (user name, roles, logout) is the natural status-chip home; nav rail
  destinations `:223-306` with permission gates `:176-205`.
- Settings screen exists but is language+theme only ("Phase 6", `settings_screen.dart:8-9`);
  no generic settings provider; SharedPreferences keys today: `app_locale`,
  `app_theme_mode`, `pos_device_id`, `pos_catalog_view_mode`.
- Localization: flat maps in `strings.dart` (~760 keys × ar/fr/en), parity enforced
  by `test/unit/constants_test.dart:51-57`; per-phase localization test convention
  (13 files).
- Tests: `MockDio` + `apiClientProvider.overrideWithValue(ApiClient(dio: mockDio))`
  in ~29 widget tests; real-socket pattern in `test/unit/api_client_test.dart:214-291`
  (loopback `HttpServer`); `SharedPreferences.setMockInitialValues` pattern.
- Windows runner is the stock template; registered plugins:
  `flutter_secure_storage_windows`, `printing`, FFI `jni` — **no networking plugin**.

### 5.11 API surface today (for reuse)

21 routers registered (`api/v1/router.py`): health, system, auth, users, products,
packs, categories, customers, suppliers, debts, inventory, sales, purchases,
returns, reports, exports, print, dashboard, pos, (+void/sales group). **No devices
router.**

---

## 6. Legacy LAN audit [LEGACY]

### 6.1 How it worked (behavioral evidence)

- First-run mandatory two-card wizard: "This is the Main Device" (host forced to
  `localhost`, zero typing) vs "Additional Device" (`main_window.py:4091-4101`);
  unlinked client is forced back into the wizard (`:3240-3241`).
- Discovery: UDP broadcast port **50000**, fixed 23-byte request
  `SUPERMARKET_PRO_DISCOVER`, JSON reply `{app, host, port, store_name}`
  (`network_discovery.py:37-39,304-311,403`), 5 s budget / 3 attempts
  (`discover_server` defaults `:577`), **plus a parallel /24 TCP sweep of port 3306**
  with 100 workers (`:511,614`).
- Manual fallback after auto-search fails: IP field pre-filled with local /24 prefix,
  port 3306, user `root`, masked password (`main_window.py:4179-4247`).
- Store confirmation dialog before joining (`:3520-3546`) — fetches real store name.
- Pairing: client registers `pending` row itself and waits (60 s deadline,
  1 s polls) (`:3663,3702,3748`); server polls every 3 s and pops approve/reject
  modal (`:3907,3950-3989`); states `pending|approved|denied`
  (`db_manager.py:616,862`); **X-close = denied** (`:3988`).
- Status chip: 3 states, `● متصل` green / `⟳ إعادة الاتصال` amber / `● غير متصل`
  red (`main_window.py:4623-4637`), UI poll 2 s, monitor `SELECT 1` every 18 s
  (`:4457,4615`), transition toasts (`:4606-4609`).
- Self-heal: cached host first, else fresh discovery, 6 s deadline, 1 s sleeps,
  store-name identity check (`:4502-4538`) — fixed intervals, **no backoff**.
- Offline UX: quiet offline card + navigation guard (`:2361-2399`), modal only at
  boot (`:4479-4485`).
- Identity: server device_name = `"PC1"`, client = OS hostname (`:3068-3085`);
  pairing identity key = **IPv4 address** (`:3599`); config stored in
  `config/db_config.json` (host/port/user/password/network_mode/store_linked).

### 6.2 A. Behavior worth preserving

1. Role choice is the first user decision (server/client cards, plain language).
2. Automatic discovery first; manual entry only as fallback (prefilled prefix).
3. Store-confirmation step before committing to a server.
4. Human approve/reject on the server; client waits with visible countdown.
5. 3-state status chip + transition toasts (green/amber/red semantics).
6. Silent self-heal after IP change; modal only at boot, chip in steady state.
7. Quiet offline screen instead of crashes; guarded navigation.
8. Admin-PIN gate for changing network mode.
9. Ordered startup: mode → responder → pairing poller → monitor → dashboard.
10. Audit rows for network events (no secrets).

### 6.3 B. Obsolete architecture that MUST NOT be copied

1. **Clients connect directly to MySQL with server-level credentials**
   (`db_manager.py:470-483`) — the core anti-pattern; forbidden by Phase 0
   [PHASE-0 SEC:10] and by this spec's non-negotiables.
2. Discovery "port" **is** the DB port 3306 — a /24 scan for open MySQL
   (`network_discovery.py:51-52,612-614`).
3. Pairing approval cosmetic: client already holds root creds and runs
   `CREATE DATABASE` *before* approval (`main_window.py:4303`); nothing on the
   server checks authorization before serving data (`is_device_authorized` has a
   single call site, on the client `:3683`).
4. Dead Flask `server/server.py` (`0.0.0.0:5000 debug=True`) — never called.
5. Dead `connected_devices` table (`db_manager.py:601-608`) — never read/written.
6. Shared mutable global config dict (`db_manager.py:85-102`).
7. `local` mode declared but never settable in UI.

### 6.4 C. Security weaknesses (legacy)

Hardcoded MySQL root password in source (`main_window.py:3303` etc.) · plaintext
password in config file · unauthenticated UDP channel with fixed guessable request ·
discovery reply exposes DB host/port + store name in cleartext · no TLS anywhere ·
identity = spoofable source IP (DHCP change = re-pair) · client can create databases ·
password printed to stdout during debug · MD5-based license device id · subnet-wide
port scan by every client.

### 6.5 D. Missing modern equivalents

Encryption/HTTPS · real server-side authorization · device credential + revocation
enforcement · rate limiting · secret redaction in logs · backoff/jitter · stable
device identity (not IP/hostname) · offline write policy · version negotiation ·
server identity that survives IP change.

---

## 7. Target architecture

```
SINGLE-PC (unchanged today):
  Flutter (local) ──HTTP 127.0.0.1:8000──▶ FastAPI ──▶ PostgreSQL (localhost)

LAN / MULTI-PC (Phase 16):
  Client Flutter ──HTTP <server-ip>:8000──▶ Server FastAPI ──▶ PostgreSQL (localhost,
  # no PG credentials on client        # LAN_MODE=1, UDP discovery responder
   ever; no direct DB access)            + devices registry + device guard)
  Server PC also runs its own Flutter against 127.0.0.1 (it is also a till).
```

Invariants (non-negotiable, from Phase 0 and this spec):

1. Flutter never speaks SQL; clients receive **no PostgreSQL credentials**
   [PHASE-0 `PHASE_0_ARCHITECTURE.md:33`, `PHASE_0_MASTER_SPECIFICATION.md:43`].
2. All authorization stays server-side; UI gating is convenience only
   [PHASE-0 `ARCHITECTURE.md:60`].
3. One service transaction covers financial/stock state + audit rows
   [PHASE-0 `ARCHITECTURE.md:59`].
4. `device_id` attribution contract remains exactly as Phase 14/15 froze it (§20).

---

## 8. Server/client model

### 8.1 Mode determination

Mode is a **client-side application setting** plus a **backend configuration flag** —
two orthogonal facts:

| Layer | Mechanism | Values | Evidence/rationale |
|---|---|---|---|
| Flutter | SharedPreferences key `app_run_mode` set by the setup wizard | `server` \| `client` (absent = first-run) | legacy precedent: mandatory wizard decides before anything else [LEGACY `main_window.py:3237`] |
| Backend | new settings `LAN_MODE: bool = False`, `DISCOVERY_ENABLED: bool = False` (+ use existing `HOST`/`PORT`) | single-PC default off | the backend must know whether to (a) answer discovery, (b) enforce the device guard; explicit flag beats implicit host-sniffing |

- **Server PC (wizard "This is the store/server PC")**: sets `app_run_mode=server`,
  app behaves exactly as today against `localhost:8000`, adds a Devices management
  screen; the backend must be started with `HOST=0.0.0.0 LAN_MODE=1
  DISCOVERY_ENABLED=1` [UNVERIFIED: exactly *how* backend auto-start is packaged is
  Phase 17 installer scope (§25)].
- **Client PC (wizard "Connect to an existing server")**: `app_run_mode=client`;
  **no local backend, no PostgreSQL, no Python**; base URL comes from pairing.
- One binary supports both modes (Flutter has no mode-specific builds).
- Mode change = Settings action gated by `device_manage` (admin) — legacy precedent
  requires admin PIN (`main_window.py:4416`); modern equivalent: `require_permission`.

Deliberately **not** chosen: command-line args (users must not know technical
CLI), env file edits on the client (nothing to edit — no backend), launcher roles
(deferred to Phase 17 packaging).

### 8.2 Server-side facts

| Aspect | Decision |
|---|---|
| Bind address | `HOST=0.0.0.0` for LAN deployment (loopback retained for single-PC); wired into documented launch command (config `HOST` finally becomes live) |
| Service port | TCP **8000** (existing default, `config.py:44`) — unchanged |
| Server identity | `server_id` = UUIDv4 generated on first LAN-mode start, persisted in a backend-local file (`data/server_id`, override via env `SERVER_ID`) — **not** an IP, **not** a settings-table row (Phase 17 owns settings; no settings table exists [MODERN: 0 `settings` migrations]) |
| Health | existing `GET /api/v1/health` (+ `/live`, `/ready`) — reused as-is |
| Discovery | UDP responder (§11) started/stopped in `main.py` lifespan when `DISCOVERY_ENABLED` |
| Approved registry | `devices` table (§10) |
| Device guard | router-level dependency, active only when `LAN_MODE` (§12.5) |

### 8.3 Client-side facts

| Aspect | Decision |
|---|---|
| Server URL | stored after pairing: SharedPreferences `paired_server_url`, `paired_server_id`, `paired_server_name` |
| Device identity | existing `pos_device_id` **promoted to app-level identity** (§9) |
| Pairing state | `pairing_state` prefs + in-memory provider (§13) |
| Credential | device token in `flutter_secure_storage` (next to the JWT) |
| Last successful server | `paired_server_url` retained across restarts (for reconnect + re-discovery preference) |
| Reconnect | backoff + cached-address-first, then UDP re-discovery (§14) |

---

## 9. Device identity

### 9.1 What exists

`pos-<epochMillis>-<random(0..2^31-1)>`, generated once in
`pos_providers.dart:27-41`, persisted under `pos_device_id`, sent as `X-Device-ID`
(+ body field) on POS/return/export/print calls; stored free-text on 7 tables;
grouped by reports [PHASE-14 D5].

### 9.2 Audit of sufficiency

| Property | Verdict |
|---|---|
| Format/uniqueness | epoch millis + 31-bit random ≈ collision-resistant for a store's few devices; **adequate as a stable key** [RESOLVED] |
| Scope | currently *POS-feature-local* — Phase 16 must promote it to an app-level `deviceIdProvider` used by all traffic (single source of truth) [RESOLVED by design] |
| Survives reinstall | SharedPreferences survives update, **not uninstall/reset** — accepted: re-pair after reinstall (documented UX) |
| Regenerated after reset | yes → becomes a *new* identity requiring pairing (correct security behavior) |
| Display name | separate field: default = Windows machine name, user-editable in wizard (never the key) [owner Q9] |
| MAC address | **not used** (legacy never used it either; Phase 0 rejects weak platform-derived ids [PHASE-0 SEC:11]) |
| Server-side record | `devices.device_id` unique (§10) |

### 9.3 Three-layer separation (mandatory)

| Layer | Example | Where it lives | Secret? |
|---|---|---|---|
| **device identity** | `pos-1727880000000-123456` | SharedPreferences `pos_device_id`; `devices.device_id` | no (appears in reports/audit) |
| **authentication credential** | user JWT (`sub/sid`) — *existing*; plus **device token** (random 32 B) — *new* | JWT: secure storage + memory; device token: secure storage; server: SHA-256 hash only | **yes** |
| **display name** | `POS-كاشير 1` | prefs + `devices.display_name` | no |

A stolen `device_id` grants nothing (it is in every report row already); API access
requires a valid JWT **and** (in LAN mode) a valid device token.

---

## 10. Device registry

**Decision: one new PostgreSQL table `devices` is required.** Why: Phase 0's own
blueprint lists `devices` among core tables [PHASE-0 `DATABASE_ANALYSIS.md:47`];
Phase 14 explicitly deferred "device registry / pairing / GET /devices" to Phase 16
[PHASE-14 `:89,716 DEF-6`]; a pending/approved/revoked server-side record is
impossible to enforce without durable storage; and approval-state + last-seen must
survive restarts.

**Why no other tables:**

| Candidate table | Verdict |
|---|---|
| `pairing_requests` | **Unnecessary** — a pairing request *is* a `devices` row with `status='pending'` (legacy proved one-table pairing works [LEGACY `authorized_devices`, `db_manager.py:612-619`]); the pairing poll uses the row's unguessable `pairing_id` |
| `device_sessions` | **Unnecessary** — `auth_sessions` already tracks user sessions incl. `device_name`; device liveness is derived (`last_seen_at` updated by the guard/heartbeat), not sessionized |
| refresh/revocation token tables | **Unnecessary** — no refresh tokens exist [MODERN]; revocation = `devices.revoked_at` |
| `settings` (server config) | **Phase 17** — does not exist yet; `server_id` uses a local file instead (§8.2) |

### 10.1 Proposed schema (specification only — migration is Step B)

```
devices
  id            UUID PK                 (UUIDMixin, client-side uuid4 — existing pattern)
  device_id     VARCHAR(100) NOT NULL UNIQUE   -- pos-… identity (§9)
  pairing_id    UUID NOT NULL UNIQUE          -- created with the request; client polls it
  display_name  VARCHAR(150) NOT NULL         -- user-visible, editable, not a key
  status        VARCHAR(20) NOT NULL          -- pending | approved | rejected | revoked
  client_version VARCHAR(50)                  -- reported at pair time (compat §19)
  token_hash    VARCHAR(64)                   -- SHA-256 of device token; NULL until approved
  requested_ip  VARCHAR(45)                   -- request source (last 3 bytes max: IPv4/IPv6)
  approved_at   TIMESTAMPTZ
  approved_by   UUID FK users ON DELETE SET NULL
  rejected_at   TIMESTAMPTZ
  revoked_at    TIMESTAMPTZ
  last_seen_at  TIMESTAMPTZ
  last_ip       VARCHAR(45)
  created_at / updated_at                     (TimestampMixin — existing)
INDEXES: uq(device_id), ix(status), ix(pairing_id)
```

Notes: `status` is a plain VARCHAR (existing enum values `DeviceStatus` map to it;
Step B adds `REVOKED = "revoked"` to the Python enum — code-only, DB unaffected).
No FK from domain tables (sales.device_id stays free text — §20). `approved_by`
provides the audit link without touching `audit_logs`.

---

## 11. Discovery — UDP + TCP

Roadmap mandates "Device discovery (UDP + TCP)" [PHASE-0 ROADMAP:675] while Phase 0
performance evidence forbids subnet sweeps: *"cached known server then signed
UDP/mDNS-style discovery; bounded backoff"* [PHASE-0 PERF:10]. Reconciled design:

### 11.1 UDP (broadcast find)

| Aspect | Specification |
|---|---|
| Port | **same number as HTTP (default 8000/udp)**, setting `DISCOVERY_PORT`. Rationale: one number for firewall + UX; no new magic port invented; legacy alternative (50000) documented but not reused because 50000 sits in the dynamic range 49152–65535 and continuity with a legacy that is being replaced has no value. [Decision; owner may override → Q13] |
| Transport | IPv4 broadcast `255.255.255.255` + per-interface `x.x.x.255` (legacy proved this works on Windows [LEGACY `network_discovery.py:279-289`]); loopback excluded |
| Request packet | ≤ 256 B: `{"v":1,"app":"supermarket_pro","t":"discover","nonce":"<16B hex>"}` prefixed by ASCII magic `SUPERMARKET_PRO_DISCOVER_V1` for cheap filter (legacy-style `:38,403` + versioning) |
| Response packet | ≤ 512 B, JSON: `{"v":1,"app":"supermarket_pro","t":"offer","nonce":"<echo>","server_id":"<uuid>","name":"<STORE_NAME>","http_port":8000,"tls":false}` |
| **Never in packets** | PostgreSQL anything · JWT/APP secrets · pairing codes · device tokens · IP subnets beyond the sender's own reply · user data |
| Timeout/retry | client: 3 attempts × 750 ms (budget ~2.25 s; legacy full sweep found server in ~0.5 s [LEGACY `main_window.py:3289`], UDP-only should be ≤1 s typical) — target: **first offer < 1 s** [UNVERIFIED until runtime] |
| Responder | server binds UDP in `main.py` lifespan when `DISCOVERY_ENABLED`; single background thread (legacy `DiscoveryResponder` pattern); **token-bucket reply limit (max 10 offers/second/IP)** to blunt discovery-spam DoS |
| Firewall | UDP inbound on `DISCOVERY_PORT` must be allowed (§15) |

Justification for including `name` (store name): preserves the legacy
store-confirmation UX (A4) — the client shows "Found server: <name>" before pairing.
It discloses only the store name already visible to anyone walking in; acceptable on
a trusted store LAN [residual risk logged §21].

### 11.2 TCP (probe/validate)

"TCP discovery" = **HTTP GET probing of candidate addresses only** — never a sweep:

1. candidates = UDP offer results + remembered `paired_server_url` + manually
   entered host (§14).
2. `GET /api/v1/health` (timeout 2 s) → server is up, `database: connected|degraded`.
3. `GET /api/v1/system/info` (timeout 2 s) → **additive Step B fields**:
   `server_id`, `protocol` (int, =1). Client validates: `server_id` matches the UDP
   offer (spoof detection), `protocol` matches (§19), version present.
4. Unrelated software answering the port: JSON parse fails or fields mismatch →
   candidate rejected with a localized "not a Supermarket Pro server" error; never
   a crash, never a pairing attempt.

No new health endpoint is created — the blueprint's health/system endpoints are
reused [PHASE-0 `API_BLUEPRINT:662-674`].

---

## 12. Pairing / authentication (SECURITY-CRITICAL)

### 12.1 Principles

- Reuse the existing JWT/session system untouched; pairing adds a **device-level
  credential**, not a second user-auth system (§5.3).
- No trust by IP, by discovery response, or by possession of the device_id.
- Admin human approval is mandatory (roadmap: "Pairing approval").
- Only `device_manage` (admin-only today) may approve/reject/revoke (§17).

### 12.2 Flow (normative)

```
Client                                   Server (LAN_MODE)
──────                                   ─────────────────
1. UDP discover ───────────────────────▶ offers {server_id, name, http_port, nonce}
2. TCP probe /health + /system/info ──▶ validate server_id + protocol match
3. user confirms store name (legacy A4 UX)
4. client reads 6-digit PAIRING CODE from the server PC's Devices screen (§12.4)
5. POST /devices/pair
   {device_id, display_name, client_version, code}
   ────────────────────────────────────▶ rate-limit check (§21 T10)
                                         validate code (constant-time compare)
                                         upsert devices row → status=pending,
                                           fresh pairing_id (re-pair resets state)
                                         audit: device_pair (no code in details!)
   ◀──────────── {pairing_id, status:"pending"}
6. client polls GET /devices/pairings/{pairing_id}  (every 2 s, 5 min timeout)
                                         [admin on server PC:]
7.                    GET /devices?status=pending (device_manage) → list
                     POST /devices/{device_id}/approve | /deny | /revoke
                                         approve: generate device_token (32 B urlsafe),
                                          store SHA-256 hash, status=approved,
                                          approved_by/at; audit device_approve
   ◀──────────── first poll response after approval:
                 {status:"approved", device_token:"<ONE TIME>",
                  server_id, name}      ← token returned exactly once
8. store token in flutter_secure_storage; state=paired/connected
   every API call now: Authorization: Bearer <JWT>  (unchanged)
                       X-Device-ID: <device_id>     (now global, §23)
                       X-Device-Token: <token>      (new; LAN mode only)
```

Reject path: `POST /deny` → `status=rejected`; next client poll returns
`{status:"rejected"}` → wizard shows localized rejection (never a token).
Re-pair path: any approved device calling `/pair` again with valid code → row reset
to `pending` with new `pairing_id` (credential regenerated at next approval).
Revoke path: `POST /revoke` → `revoked_at`, `token_hash=NULL` → all API calls from
that device fail with `DEVICE_REVOKED` (§12.5) → client UI enters `rejected`
sub-state offering re-pair.

### 12.3 What each call requires

| Call | Auth | Rate limit |
|---|---|---|
| `POST /devices/pair` | none (pre-credential), but must present valid **pairing code** | in-memory: 5/min/IP + 10/min global |
| pairing poll | possession of unguessable `pairing_id` (UUIDv4) | 30/min |
| list/approve/deny/revoke/code-display | JWT + `device_manage` | none extra |
| ordinary API | JWT + (LAN mode) valid device token | existing lockout only |

### 12.4 Pairing code

6 digits, generated server-side, **rotates every 5 minutes**, fetched by the server
PC's Devices screen via an authenticated endpoint (`GET /devices/pairing-code`,
`device_manage`), displayed large; entered manually by the person at the client PC.
This is the Phase 0 recommendation "Pairing with one-time code" [PHASE-0 SEC:15]
translated into low-friction UX. Constant-time comparison; code never logged/audited.
[Owner Q1 — recommended default: required.]

### 12.5 Device guard (enforcement point)

- Implemented as a **router-level dependency on `api_router`** (one change point —
  no per-endpoint edits), activated only when `settings.LAN_MODE` is true; otherwise
  it is a no-op (existing single-PC behavior and the entire 1061-test suite are
  untouched) [MODERN].
- Applies to every `/api/v1/*` route **except an explicit allowlist**:
  `health*`, `system/info`, `auth/login`, `auth/login-users`, `auth/setup*`,
  `auth/verify-token`, `auth/logout-token`, `devices/pair`, `devices/pairings/*`.
- Checks: `X-Device-ID` present → row exists → `status=approved` → `token_hash`
  matches SHA-256(`X-Device-Token`) → update `last_seen_at/last_ip` (throttled:
  at most one UPDATE/minute/device to avoid write amplification).
- Failures (typed envelope, no new mechanism): missing device headers → `401
  UNAUTHORIZED {reason:"device_required"}`; unknown/pending device → `403 FORBIDDEN
  {reason:"device_not_paired"}`; revoked → `403 FORBIDDEN {reason:"device_revoked"}`.
  (Codes reused from the existing envelope; details carry the reason — §16.)
- Flutter maps `device_revoked` to a dedicated terminal UI state (§13).

### 12.6 Explicitly rejected designs

Auto-trust of LAN clients (legacy C8) · identity = IP (legacy C9) · trust = valid
discovery response · long-lived secrets in plaintext files · client-side DB
credentials (legacy B1) · replacing JWT with a custom scheme · mTLS/certificates in
Phase 16 (no CA story on a store LAN; deferred, §21/Q8).

---

## 13. Connection state machine

### 13.1 Client states (normative)

```
                    ┌──────────────┐
     first run ───▶ │ unconfigured │
                    └──────┬───────┘
              wizard: client mode
                           ▼
                    ┌──────────────┐   offer/timeout     ┌──────────────┐
                    │  discovering │────────────────────▶│ manual entry │
                    └──────┬───────┘◀────────────────────└──────┬───────┘
                 offer validated (TCP)                          │ connect
                           ▼                                    │
                    ┌──────────────┐                            │
                    │ server_found │◀───────────────────────────┘
                    └──────┬───────┘
                 pair requested (code ok)
                           ▼
                    ┌────────────────┐  server denies/     ┌──────────┐
                    │pairing_requested│──code invalid─────▶│ rejected │◀──┐
                    └──────┬─────────┘                     └────┬─────┘   │
                           ▼ (pairing_id issued)                │ approve │
                    ┌────────────────┐                          │ re-pair │
                    │awaiting_approval│─────────────────────────┘         │
                    └──────┬─────────┘  poll: rejected ──────────────────┤
                           │ poll: approved + token                      │
                           ▼                                             │
                    ┌──────────────┐   connect attempt                   │
                    │   connecting │──────────── fail ──────────────────► │
                    └──────┬───────┘                                     │
                           │ first authenticated response                 │
                           ▼                                             │
              ┌─────────────────────┐  1 failure   ┌──────────────┐      │
              │      connected      │────────────▶│ reconnecting │──────┘
              │  (heartbeat ok)     │◀────────────│  (backoff)   │ revoked/
              └─────────┬───────────┘  recovered   └──────┬───────┘  server
                        │ heartbeat fails ×2             │ give-up   gone
                        │                    ┌───────────▼──────┐    │
                        └───────────────────▶│   disconnected   │◀───┘
                                             │ (retry forever,  │
                                             │  slower cadence) │
                                             └──────────────────┘
```

| State | Meaning | Entering | Exiting |
|---|---|---|---|
| `unconfigured` | no `app_run_mode` | first run / mode reset | wizard choice → `discovering` (client) or configured (server) |
| `discovering` | UDP probes in flight | enter client wizard | offer → `server_found`; budget exceeded → manual entry |
| `server_found` | validated candidate (TCP probe ok) | validation success | confirm → `pairing_requested` |
| `pairing_requested` | POST /pair sent | 200 | `pairing_id` → `awaiting_approval`; code invalid/rate-limited → `rejected` |
| `awaiting_approval` | polling | poll start | approved → `connecting`; rejected → `rejected`; 5 min no answer → `rejected` (timeout) |
| `connecting` | auth + first guarded call | token stored | success → `connected`; failure → `reconnecting`/`rejected` (revoked) |
| `connected` | heartbeat succeeding | first success | 2 consecutive heartbeat failures → `reconnecting` |
| `reconnecting` | backoff loop (§14) | disconnect | success → `connected`; admin revoke detected → `rejected` |
| `disconnected` | prolonged failure (backoff cap reached N times) | `reconnecting` exhausted (after ~2 min) | any success → `connected`; user "retry now" → `connecting` |
| `rejected` | denied/revoked/tampered | server response | user re-pair (from `pairing_requested`) or mode reset |

Degradation nuance: server-side health may be `degraded` (DB down, `health.py:61`)
while HTTP responds — client surfaces **connected-but-degraded** (amber, "server
database unavailable") and mutation errors propagate normally; it is *not* a
disconnected state.

### 13.2 Server states (observational, Devices screen)

`starting` (lifespan init) → `available` (health 200 + db connected) ⇄ `degraded`
(health 200 + db disconnected) → `unavailable` (health unreachable, observed only by
clients — the server cannot observe itself). No server-side machine is persisted.

---

## 14. Auto-reconnect

| Parameter | Value | Rationale |
|---|---|---|
| Heartbeat | `GET /api/v1/health`, **every 10 s**, only in `connected`/`reconnecting` | endpoint exists and is cheap (1 SQL probe) [MODERN]; 10 s vs legacy 18 s: snappier UI, still trivial load |
| Failure threshold | 2 consecutive failures → `reconnecting` | avoids flapping on one dropped packet |
| Backoff | 1 s, 2 s, 4 s, 8 s, 16 s, **30 s cap**, ±20 % jitter | legacy had *no* backoff (fixed 1 s/18 s) [LEGACY]; jitter prevents synchronized client storms |
| Address strategy | try remembered `paired_server_url` first (legacy cached-host-first `main_window.py:4506`) → then UDP rediscovery → manual entry after cap | survives DHCP change (legacy self-heal A7 preserved, but against an *HTTP service*, with `server_id` re-verification) |
| Identity check | `server_id` from `/system/info` must equal `paired_server_id`; mismatch → stop, show "server changed — re-pair required" | IP is not identity (§14/§7) |
| Steady-state UI | chip only, **no modal** (legacy `:4567-4570`); modal only during boot/wizard | preserves legacy UX |
| First reconnect attempt | immediate (no initial delay) | fast recovery |
| Flutter mechanism | first `Timer.periodic` in the app, owned by a `connectionProvider` (§23) | none exists today (§5.10) |

---

## 15. Failure / offline semantics

Phase 0 mandates the policy be designed here [PHASE-0 `ARCHITECTURE.md:63`]:
*"A disconnected LAN client is not silently allowed to create conflicting sales;
its permitted queue/offline policy must be explicitly designed in Phase 16."*

**Design chosen: NO offline writes in Phase 16** (no queue, no local DB on client).
This does not invent business semantics; it makes explicit what the code already
does (mutations require the server; there is no local storage for sales).

| Situation | Classification | Client behavior |
|---|---|---|
| A. UI disconnected (heartbeat failing) | `reconnecting`/`disconnected` | mutation actions **disabled** with localized reason; reads show last data + "may be outdated" chip; user retry available |
| B. server down (connection refused) | as A, immediate | same; reconnect loop runs |
| C. PostgreSQL down (health `degraded`) | connected-but-degraded | keep session; mutations will fail with typed backend errors — surface normally; chip amber |
| D. request timeout (30 s Dio limit) | ambiguous outcome | see E for mutations |
| E. response lost after server committed | **safe**: retry with **same** `client_request_id` → replay returns original sale (`services/sale.py:761-779`) | checkout keeps the key until success [PHASE-8 `:400,462`] — **never regenerate on timeout** |
| F. stale cached data | last-loaded screens | no auto-refresh exists; user-initiated refresh/retry only (existing pattern) |

### 15.1 Per-operation safety matrix (no new semantics — reading existing ones)

| Operation | Offline | Safe automatic retry? | Mechanism |
|---|---|---|---|
| sale (checkout) | disabled | **yes, with same key** | `client_request_id` unique + replay [PHASE-8] |
| return | disabled | yes, same key | returns idempotency [PHASE-12] |
| expense / debt payment / supplier payment / purchase create | disabled | yes, same key | [PHASE-13/9/11] |
| void | disabled | **refetch, don't blind-retry** | terminal-state guard → second attempt 409 [PHASE-12] |
| inventory adjust | disabled | refetch-then-retry | state may have changed |
| product/category master edits | disabled | last-write-wins + `VersionMixin` version field exists | conflicts → 409 handled by existing error path |
| reads (POS catalog, reports, dashboard) | show stale + chip | user-initiated refresh | existing retry pattern |
| print/export | disabled when disconnected (server renders) | n/a | Phase 15 architecture unchanged |

Completed transactions are never corrupted: the server commits atomically or not at
all; a lost *response* leaves the original sale retrievable by replay
(stock decremented exactly once — Phase 8 test_w).

---

## 16. API contracts (Phase 16 surface)

Blueprint evidence [PHASE-0 `API_BLUEPRINT:594-608`]: `GET /devices`,
`POST /devices/pair`, `POST /devices/{id}/approve` (admin), `POST /devices/{id}/deny`
(admin) — **bodies/responses were never specified**, and two needed operations
(revoke, client poll) are missing. Modernized contract (all responses use the
existing envelope for errors; JSON bodies strict — `StrictBaseModel`, no extras):

| # | Method + path | Request body | Response | Auth | Permission | Key errors | Audit |
|---|---|---|---|---|---|---|---|
| 1 | `POST /api/v1/devices/pair` | `{device_id, display_name, client_version, code}` | `201 {pairing_id, status:"pending"}` | none (+code, rate limit) | — | `VALIDATION_ERROR` (422), `PAIRING_CODE_INVALID` (403, new typed code), `CONFLICT` (429-ish throttle → use `VALIDATION_ERROR` w/ retry_after) | `device_pair` |
| 2 | `GET /api/v1/devices/pairings/{pairing_id}` | — | `200 {status, device_token? (once), server_id, name}` | pairing_id possession | — | `NOT_FOUND` (404) | — (no token in audit) |
| 3 | `GET /api/v1/devices` | query `status?` | `200 {items:[{device_id, display_name, status, client_version, requested_ip, last_seen_at, approved_at, ...}]}` | JWT | `device_manage` | `FORBIDDEN` | — |
| 4 | `POST /api/v1/devices/{device_id}/approve` | — | `200 {device_id, status:"approved"}` | JWT | `device_manage` | `NOT_FOUND`, `CONFLICT` (not pending → 409) | `device_approve` |
| 5 | `POST /api/v1/devices/{device_id}/deny` | — | `200 {status:"rejected"}` | JWT | `device_manage` | `NOT_FOUND`, `CONFLICT` | `device_reject` |
| 6 | `POST /api/v1/devices/{device_id}/revoke` | — | `200 {status:"revoked"}` | JWT | `device_manage` | `NOT_FOUND`, `CONFLICT` (already revoked) | `device_revoke` |
| 7 | `GET /api/v1/devices/pairing-code` | — | `200 {code, expires_at}` | JWT | `device_manage` | `FORBIDDEN` | — (never log code) |
| 8 | `GET /api/v1/health` (+live/ready) | — | **reused as-is** [MODERN `health.py:47-101`] | none | — | — | — |
| 9 | `GET /api/v1/system/info` | — | existing + **additive** `server_id`, `protocol` | none | — | — | — |

- Path param `device_id` (the `pos-…` string) is used rather than the blueprint's
  ambiguous `{id}` — matches how clients and reports already identify devices
  [PHASE-14 D5].
- **New typed error codes (envelope mechanism unchanged):** `PAIRING_CODE_INVALID`
  (403), `DEVICE_REVOKED` (403, raised by guard via details; guard may instead use
  `FORBIDDEN`+`details.reason` — final choice recorded in Step B, both conform to
  the envelope) — flagged as a micro-decision, gate G-API.
- No WebSocket endpoints. No changes to any Phase 14/15 endpoint.

---

## 17. Permissions / RBAC

| Operation | Scope | Effective holders |
|---|---|---|
| list pending devices, pairing-code display | `device_manage` | **admin only** (seed: `admin = list(PermissionScope)`; manager's explicit list omits it) [MODERN `seed.py:36-89`] |
| approve / deny / revoke | `device_manage` | admin only |
| request pairing | *unauthenticated by necessity* (no credential yet) — protected by pairing code + rate limit | any LAN host with the code |
| pair poll | possession of `pairing_id` | requester |
| everything else | unchanged | unchanged |

**No new permission scopes.** Phase 0's business-rules matrix grants "devices" to
admin [PHASE-0 `BUSINESS_RULES:41`], matching the existing seed. Whether *manager*
should also view devices is owner question Q2 (default: no — approve/revoke is
admin-only authority). This resolves the Phase 3 roadmap gap ("Device management
API" listed for Phase 3 but never built) without new RBAC machinery.

---

## 18. Audit logging

New additive `AuditAction` values (DB column is `String(30)` — **code-only, no
migration**): `device_pair`, `device_approve`, `device_reject`, `device_revoke`.

| Event | action | actor (user_id) | entity | details (JSON) |
|---|---|---|---|---|
| pairing requested | `device_pair` | NULL (pre-auth) | type=`device`, id=devices.id | `device_id`, `display_name`, `client_version`, `result` |
| approved | `device_approve` | approving admin | device | `device_id`, `display_name` |
| rejected | `device_reject` | admin | device | `device_id` |
| revoked | `device_revoke` | admin | device | `device_id` |
| mode change (server/client) | reuse `update` on entity `device`? → **new** `device_mode`? | operator | — | deferred: mode change audit only if trivial; gate G-AUDIT |

- **Never logged:** pairing code, device token (only its hash exists), JWT material,
  PINs — mirrors Phase 15 rule [PHASE-15 `:1423`].
- **No heartbeat/last_seen audit rows** (noise; `devices.last_seen_at` is the
  lightweight equivalent).
- `ip_address`/`device_id` columns on `audit_logs` are populated where meaningful
  (pair: source IP; approve: admin's device if any).

---

## 19. Version / compatibility

| Layer | Mechanism |
|---|---|
| HTTP API | already versioned by prefix `/api/v1` — unchanged |
| Discovery protocol | integer `v:1` in request+response; responder ignores/rejects unknown majors (client shows "update required") |
| Pair/replay protocol | `protocol` field returned by `/system/info` (Step B additive); client compares to its supported `kProtocolVersion=1` → **mismatch blocks pairing** with localized message (never silent unsafe operation) |
| App versions | backend `VERSION="0.1.0"` vs Flutter `1.0.0+1` — **discrepancy D-05**; pairing records `client_version` for support visibility; server UI shows it next to pending devices |
| Minimum supported client | **UNVERIFIED** — no release channel exists yet; policy deferred (Q12). Enforcement point already designed (`protocol` compare) |
| Upgrade warning | client detects `protocol` higher than its own → "server updated — please update this till" |

---

## 20. Concurrency / data integrity

**Audit conclusion: the existing transactional core is already multi-PC-safe.**
Multi-PC means *more concurrent clients against one backend* — exactly what the
existing design and tests assume:

- One transaction per command, READ COMMITTED, `FOR UPDATE` row locks
  (customer/debt ceiling `services/sale.py:259`, supplier `party.py:77-88`,
  purchase receive `purchases.py:429`), ordered lock acquisition (Phase 11 G17),
  guarded stock UPDATE rowcount (`sale.py:840`), unique `client_request_id` with
  race-replay (`sale.py:932-953`), `VersionMixin` optimistic versions on masters.
- Proven by 6 PostgreSQL integration tests (`test_*_concurrency.py`) simulating
  simultaneous writers [PHASE-9/11].
- Invoice numbers: millisecond + unique constraint — collision risk under
  concurrency assessed and accepted in Phase 8 [PHASE-8 `:999`].
- **No business-service rewrite is proposed.** Phase 16 adds only: tests that
  simulate *two device identities* issuing simultaneous sales through the guarded
  path (device guard must not serialize or deadlock requests — guard does one
  throttled UPDATE outside the business transaction).
- Identified risk to watch (gate G-CONC): `get_current_user` commits
  `last_seen_at` on **every request** (`dependencies.py:92-93`) — under N LAN
  clients this adds write churn; Phase 16 throttles device `last_seen` updates the
  same way (decided §12.5). [No evidence of a *correctness* problem.]

---

## 21. Security threat model (LAN)

Threat → control → residual:

| # | Threat | Control (designed) | Residual / gate |
|---|---|---|---|
| T1 | Rogue device impersonation | device token (random 32 B, hash stored) + human approval + pairing code; `device_id` alone grants nothing | token sniffable on plain HTTP → **Q8/HTTPS** |
| T2 | Fake discovery response | TCP probe validates `server_id`+`protocol`; pairing code entered by human on the *client* ties client to the server they see; store-name confirmation (legacy A4) | malicious server can still MITM a client that pairs with it → user must read the server screen (Q8) |
| T3 | Unauthorized pairing | pairing code (constant-time) + admin approval | code shoulder-surfing — acceptable in-store |
| T4 | Pairing request replay | fresh `pairing_id` per request; token issued once to that `pairing_id` only | plain-HTTP sniff of poll response → Q8 |
| T5 | Credential theft | token/JWT in `flutter_secure_storage` (DPAPI on Windows); server keeps hashes only | memory dump on client = out of Phase 16 threat model |
| T6 | Revoked device reconnect | guard checks `revoked_at`/`token_hash=NULL` every request → `device_revoked` | none |
| T7 | Unauthorized API access | existing JWT + RBAC + new device guard in LAN mode | single-PC mode unchanged by design |
| T8 | LAN sniffing | **no crypto invented**; secrets never in discovery packets or audit logs | plain HTTP accepted on trusted store LAN → **Q8** (Phase 0 says "authenticated HTTPS where feasible" [PHASE-0 MASTER:43]) |
| T9 | Token leakage via logs | structlog request logs contain method/path/status only; token in header never logged (verify in Step B — gate G-SEC) | — |
| T10 | Brute-force pairing / spam | rate limit 5/min/IP on `/pair`; no secret to brute-force beyond 6-digit code (10⁶, rotates 5 min, constant-time) | in-memory limit resets on restart → acceptable |
| T11 | Discovery info leakage | packet has name/port/`server_id` only; no store data, no user data | name visible to LAN — accepted (§11.1) |
| T12 | Malformed/spoofed packets | size cap 512 B, strict JSON+magic+`app` check, unknown fields ignored, responder thread isolated with try/except (legacy exception policy [PHASE-0 EXCEPTION:17]) | — |
| T13 | Discovery-spam DoS | token bucket 10 offers/s/IP | — |
| T14 | PIN brute force (unchanged) | existing lockout 5/15 min [MODERN] | rate limiting absent app-wide (roadmap Phase 3 gap → D-08) |

**Honest statement:** JWT existence does **not** make LAN traffic confidential.
Phase 16 ships plain HTTP by default with secrets only in POST bodies/headers and
never in discovery; HTTPS/mTLS is designed-for but deferred (Q8, Phase 17).

---

## 22. Performance

Phase 0 SLOs preserved verbatim [PHASE-0 PERF:15]: POS lookup p95 <100 ms · first
product page <200 ms · sale command <500 ms · dashboard/report <2 s · export <5 s.

| Phase 16 target | Value | Basis |
|---|---|---|
| Discovery (find server) | p95 < 1 s, budget 2.25 s | legacy found in ~0.5 s via sweep; UDP 3×750 ms |
| TCP probe (health+info) | < 300 ms on LAN | two small GETs, 2 s timeout each |
| Pairing request round-trip | < 500 ms | trivial insert |
| Approval→client transition | < 3 s (2 s poll cadence) | poll design |
| Heartbeat cost | ≤ 0.1 req/s/device, 1 SQL probe | 10 s cadence |
| Reconnect (server restart) | < 10 s typical (1-2-4 s backoff) | §14 |
| Sale over LAN vs local | +1–5 ms network (negligible vs DB) | LAN RTT; DB dominates |
| Simultaneous clients | target ≥ 10 tills | pool_size 5 + max_overflow 10 = 15 concurrent sessions [MODERN `engine.py:36-43`] — revisit only if measured |
| Discovery responder load | ≤ 10 replies/s/IP | T13 |

Latency classes kept separate: application network (above) · database (server-local,
unchanged) · printer (Phase 15, client-side Windows dialog, hardware QA deferred).

---

## 23. Flutter UX architecture

### 23.1 New components

| Component | Responsibility |
|---|---|
| `lib/features/devices/discovery_service.dart` | UDP socket abstraction (`DiscoveryService` interface + `UdpDiscoveryService` impl + test fake) — packet codec as pure functions (unit-testable without sockets) |
| `lib/features/devices/setup_wizard_screen.dart` | first-run/network wizard: role cards (server/client) → search (animated, legacy copy pattern) → found/confirm → pairing-code entry → awaiting-approval (countdown) → done/rejected; mandatory (unclosable) on first run; accessible later from Settings via `device_manage` |
| `lib/features/devices/devices_screen.dart` | server-side management: pairing-code card (auto-refresh on rotation), pending list (name/IP/version + Approve/Reject), registered list (Revoke w/ confirm), permission-gated nav item |
| `lib/features/devices/connection_provider.dart` | the state machine of §13: heartbeat `Timer.periodic(10s)`, backoff+jitter, rediscovery, exposes `ConnectionState` to UI; owns `X-Device-ID`/`X-Device-Token` wiring |
| `lib/features/devices/reconnect_dialog.dart` | boot-time modal only (legacy policy) with cancel→manual entry |
| `ConnectionStatusChip` | placed in `ScaffoldWithNav` AppBar actions (`app_router.dart:419-459`, beside logout) — green/amber/red + tooltip; RTL-aware (trailing position) |
| Pairing approval dialog | *lives inside `devices_screen`* (roadmap's "pairing approval dialog" = the approve/reject row dialog) |

### 23.2 Modified components

- `api_client.dart`: base URL becomes **dynamic** — `apiClientProvider` constructs
  `ApiClient(baseUrl: stored_paired_url ?? 'http://localhost:8000')`; add a
  `setBaseUrl()` for post-pair switching; attach `X-Device-ID` + `X-Device-Token`
  as global headers when paired (today `X-Device-ID` is per-call at 5 sites — those
  sites remain, now harmless duplication, or are simplified in Step B).
- `auth_provider.dart`: `apiClientProvider` override reads prefs; 401-handler gains
  `device_revoked`/`device_not_paired` branch → dedicated auth-independent UI state.
- `pos_providers.dart`: `ensurePosDeviceId` moves/promoted to app-level
  `deviceIdProvider` (same storage key `pos_device_id` — **format and key
  unchanged** [PHASE-14]).
- `app_router.dart`: routes `/setup-network` (wizard), `/devices`; nav destination
  gated `device_manage`; status chip in shell AppBar; redirect logic: client mode
  + not paired → `/setup-network` before login.
- `main.dart`: unchanged ordering (prefs already loaded pre-`runApp`).

### 23.3 Explicitly not built

Offline cart queue · local SQLite on client · background isolate networking beyond
the UDP/heartbeat timers · settings UI beyond wizard entry (Phase 17) ·
`connectivity_plus` (health polling is sufficient and dependency-free).

---

## 24. Localization

New keys (~46) × ar/fr/en, prefix `lan_`/`device_`, appended to the three maps in
`strings.dart` + a new `test/unit/lan_localization_test.dart` (existing convention,
13 precedents). Key groups:

| Group | Keys (representative) |
|---|---|
| Wizard/roles | `lan_wizard_title`, `lan_server_role`, `lan_client_role`, `lan_role_server_desc`, `lan_role_client_desc`, `lan_first_run_hint` |
| Discovery | `lan_searching_server`, `lan_search_timeout`, `lan_server_found`, `lan_server_not_supermarket`, `lan_manual_entry`, `lan_ip_label`, `lan_port_label`, `lan_connect`, `lan_retry`, `lan_cancel` |
| Confirm | `lan_confirm_store`, `lan_confirm_store_body`, `lan_yes_connect` |
| Pairing | `lan_pairing_code`, `lan_enter_pairing_code`, `lan_pairing_code_invalid`, `lan_waiting_approval`, `lan_waiting_seconds`, `lan_pairing_approved`, `lan_pairing_rejected`, `lan_pairing_timeout`, `lan_pairing_rejected_body`, `lan_repair_required` |
| Devices screen | `lan_devices_title`, `lan_pending_devices`, `lan_no_pending`, `lan_approve`, `lan_reject`, `lan_revoke`, `lan_revoke_confirm`, `lan_device_last_seen`, `lan_device_ip`, `lan_device_version`, `lan_status_pending/approved/rejected/revoked` |
| Status chip | `lan_connected`, `lan_reconnecting`, `lan_disconnected`, `lan_degraded_db`, `lan_connected_tooltip` |
| Reconnect/errors | `lan_reconnect_title`, `lan_reconnect_body`, `lan_reconnect_now`, `lan_server_unreachable`, `lan_device_revoked_title/body`, `lan_version_mismatch`, `lan_server_changed` |
| Disabled actions | `lan_offline_mutations_disabled` |

Reused existing keys: `retry`, `refresh`, `network_error`, `network_error_retry`,
`api_error_retry` [MODERN `strings.dart:117,156,226`]. RTL: chip and dialogs follow
existing directionality (Arabic default `locale_provider.dart:41`); no new layout
constraints beyond ensuring the chip sits at the AppBar's trailing edge.

---

## 25. Deployment / install implications

**Phase 16 does not build the installer** (Phase 17/packaging). What Phase 16 must
leave packaging-ready:

| Concern | Phase 16 responsibility | Deferred to Phase 17/packaging |
|---|---|---|
| Server: FastAPI start | documented command `uvicorn app.main:app --host 0.0.0.0 --port 8000` + `LAN_MODE=1 DISCOVERY_ENABLED=1`; lifespan owns responder start/stop | Windows service / auto-start / recovery |
| Server: PostgreSQL | unchanged local instance; **bind stays localhost** (never LAN-exposed) | install/config of PG itself |
| Client | zero backend install; wizard + pairing only | bundling/exclusion decisions in the installer |
| Firewall | **document** that first LAN-mode start will trigger a Windows Firewall prompt for the app on TCP 8000 + UDP 8000; make ports configurable so packaging can preset them | **actually modifying firewall rules (netsh) = installer action** — gate G-FW is DEFERRED-to-packaging (do not manipulate firewall in Phase 16) |
| Startup order | server app shows "waiting for backend" state if `localhost:8000` unreachable at boot (same health check) | launching the backend process |
| Secrets | `.env` remains server-only; clients get none | secrets provisioning |

---

## 26. Migration analysis (no migration created in Step A)

| Question | Answer |
|---|---|
| Device registry table required? | **Yes** — `devices` (§10), justified by Phase 0 blueprint + Phase 14 DEF-6 + enforcement needs |
| Existing table reusable? | No (no settings/devices table exists) |
| device_id already in domain rows? | Yes — 7 tables, free text, **untouched** |
| New indexes? | `uq(device_id)`, `ix(status)`, `ix(pairing_id)` — all inside the new table; **no index on any existing table** |
| Backfill required? | **None.** Historical `sales.device_id` values (`pos-…`, possibly NULL) stay as-is; unpaired devices simply have no registry row — reports unchanged [PHASE-14 formulas frozen] |
| Report compatibility | preserved: grouping/filtering by `device_id` continues to work identically; display-name enrichment = future/optional (Q11) |
| Forward/backward intent (Step B) | forward: create table; backward: drop table — additive-only, no data migration, safe to downgrade |
| Exact migration | `0021_phase16_devices.py` (next revision after `0020_phase14_report_indexes`) |

---

## 27. Test strategy

Network tests **must not require real hardware**; loopback/sockets/fakes only.
Real LAN QA = later acceptance stage (like Phase 15 hardware QA).

### 27.1 Backend (new files)

| File | Covers |
|---|---|
| `tests/unit/test_devices.py` | registry CRUD · pair (valid/invalid/expired code, malformed body, duplicate device_id re-pair) · poll pending/approved/rejected/once-only token · approve (`CONFLICT` when not pending) · deny · revoke · permissions matrix (admin ok / manager 403 / cashier 403 / anonymous 401) · token hash never returned by list · audit rows for pair/approve/reject/revoke with no secrets · pairing-code rotation + constant-time path |
| `tests/unit/test_discovery.py` | packet codec round-trip · magic/version/app validation · response contains **no secrets** (assert field allowlist) · size caps · responder on loopback UDP (bind `127.0.0.1`, ephemeral port via `DISCOVERY_PORT` override) → request→offer · token-bucket throttling · ignore garbage bytes |
| `tests/unit/test_device_guard.py` | LAN_MODE on: missing headers 401 · unknown device 403 · pending device 403 · revoked 403 `device_revoked` · valid token 200 · allowlist paths (health/login/pair) work unguarded · **LAN_MODE off: everything behaves exactly as today (regression sentinel)** |
| `tests/unit/test_system_protocol.py` | `/system/info` carries `server_id`+`protocol` |
| integration | two simultaneous "devices" (two tokens) issuing sales via existing idempotency (reuse Phase 8 machinery) → both succeed, stock correct · guard `last_seen_at` throttling under N requests |

### 27.2 Flutter (new files)

| File | Covers |
|---|---|
| `test/unit/discovery_packet_test.dart` | codec encode/decode, malformed input |
| `test/unit/connection_state_test.dart` | state machine transitions + backoff schedule (injectable clock/timer) — no real waiting |
| `test/widget/devices_wizard_test.dart` | role cards → searching → found (fake `DiscoveryService`) → code entry → awaiting → approved/rejected/timeout; RTL Arabic smoke; manual-entry fallback |
| `test/widget/devices_screen_test.dart` | pending list, approve/reject/revoke confirm, permission gating, pairing-code display |
| `test/widget/connection_status_test.dart` | chip in shell: connected/reconnecting/disconnected colors+toasts; reconnect dialog on boot; revoked terminal state |
| `test/unit/lan_localization_test.dart` | all new keys × ar/fr/en (existing convention) |
| `test/unit/api_client_test.dart` (extend) | dynamic base URL + device headers on requests (existing loopback `HttpServer` pattern) |

### 27.3 Integration (loopback, no hardware)

Server-on-loopback: start backend with `LAN_MODE=1` → discovery against loopback →
pair → approve → guarded call succeeds → revoke → next call 403 → re-pair → success.
Simulated failures: stop backend mid-heartbeat → `reconnecting` → restart →
`connected`; response-loss simulation via idempotent replay (already covered
backend-side, asserted from the client-side retry contract).

Regression: full backend 1061 + Flutter 1163 must remain green with **zero
modifications to existing test files** except additive `system/info` assertions.

---

## 28. Gates

Statuses: **RESOLVED** (decided from evidence) · **DEFERRED** (consciously later
phase) · **UNVERIFIED** (needs runtime/hardware/owner). **No PASS** — implementation
has not happened.

| ID | Gate | Status | Note |
|---|---|---|---|
| G-01 | Current architecture audit | RESOLVED | §5, full citations |
| G-02 | Legacy LAN audit | RESOLVED | §6 |
| G-03 | Server/client model | RESOLVED | §8 (wizard + `LAN_MODE`); backend *auto-start* packaging → G-26 |
| G-04 | Device identity | RESOLVED | §9 — keep `pos-…`, promote to app-level, 3-layer separation |
| G-05 | Device registry (table exists?) | RESOLVED | §10 — one `devices` table, no extras |
| G-06 | Discovery protocol (packet contract) | RESOLVED | §11.1 |
| G-07 | UDP behavior (port choice) | RESOLVED (default) | same number as HTTP (8000/udp), configurable; override = Q13 |
| G-08 | TCP/HTTP probing (no sweep) | RESOLVED | §11.2 [PHASE-0 PERF:10] |
| G-09 | Pairing flow | RESOLVED | §12.2 (11-step normative) |
| G-10 | Pairing code required? | UNVERIFIED | designed §12.4; **owner Q1** decides |
| G-11 | Authentication reuse (JWT + device token) | RESOLVED | §12.1/12.5 |
| G-12 | Authorization (RBAC mapping) | RESOLVED | §17 — no new scopes; Q2 only widens |
| G-13 | Revocation enforcement | RESOLVED | §12.2/12.5 |
| G-14 | Connection state machine | RESOLVED | §13 |
| G-15 | Auto-reconnect (backoff params) | RESOLVED | §14 (values chosen; runtime tuning = Step B evidence) |
| G-16 | Offline/failure semantics | RESOLVED | §15 — no offline writes; per-op matrix |
| G-17 | Concurrency safety | RESOLVED (design) | §20 — no service rewrite; RUNTIME proof via existing 6 PG tests + new dual-device test → remains UNVERIFIED until Step B runs |
| G-18 | Idempotency under LAN retry | RESOLVED | §15.1 — Phase 8 mechanism reused, key never regenerated |
| G-19 | API contract | RESOLVED | §16 — 9 endpoints, blueprint reconciled; micro-decision on guard error style recorded at implementation |
| G-20 | RBAC scopes sufficient | RESOLVED | §17 |
| G-21 | Audit model | RESOLVED | §18 — 4 additive actions, no heartbeats, no secrets |
| G-22 | Version/compatibility | RESOLVED (mechanism) / UNVERIFIED (min-version policy) | §19; **Q12** |
| G-23 | LAN security model (plain HTTP) | UNVERIFIED | §21 — **Q8** (HTTPS defer/accept); residual risk documented |
| G-24 | Windows firewall | DEFERRED | §25 — Phase 16 documents, installer applies (Phase 17) |
| G-25 | Configuration (`LAN_MODE`, ports) | RESOLVED | §5.2/§8.2 — additive settings; `HOST`/`PORT` become live |
| G-26 | Server auto-start/packaging | DEFERRED | Phase 17/installer |
| G-27 | Localization (keys plan) | RESOLVED | §24 — runtime correctness at Step B |
| G-28 | Performance targets | RESOLVED | §22 — measurement at Step B |
| G-29 | Test strategy | RESOLVED | §27 — results at Step B |
| G-30 | Migration strategy | RESOLVED | §26 — one additive migration, no backfill |
| G-31 | Installer/deployment boundary | RESOLVED | §25 |
| G-32 | Manual LAN QA (real 2-PC) | DEFERRED | later acceptance stage (like Phase 15 hardware) |
| G-33 | Phase 14 report compatibility | RESOLVED | §20/§26 — device_id contract untouched |
| G-34 | Phase 15 print/export compatibility | RESOLVED | §22 note + §31 — X-Device-ID metadata unchanged, no printer registry |
| G-35 | No-new-dependencies claim | RESOLVED | §3.2/D9 — stdlib sockets both sides; UNVERIFIED only for Windows firewall prompt behavior at runtime |
| G-36 | Rate limiting on pairing | RESOLVED (design) | §12.3 in-memory; app-wide rate limiting remains a roadmap gap (D-08) |

**Counts: RESOLVED 29 · DEFERRED 3 (G-24, G-26, G-32) · UNVERIFIED 4 (G-10,
G-22 min-version policy, G-23, G-17-runtime)** — 36 gates total, none PASS.
Full tally repeated in the Final Step A report (item 24).

---

## 29. Owner questions

| # | Question | Why it matters | Recommended default | Gate | Phase impact |
|---|---|---|---|---|---|
| Q1 | Is a 6-digit **pairing code** required, or is name+IP approval (legacy-style) enough? | determines spoof-resistance of approval | **Code required** (Phase 0 recommendation [SEC:15]) | G-10 | if no: simpler wizard, weaker T3 |
| Q2 | May **manager** view/approve devices, or admin only? | RBAC scope | **admin only** (matches seed + Phase 0 matrix) | G-12 | widening = trivial |
| Q3 | One server per store — can multiple servers coexist on one LAN? | discovery ambiguity | **one active server**; multiple offers shown, user picks + confirms name | G-06 | multi-server UX later |
| Q4 | Is **manual server address** entry allowed as fallback? | offline discovery/firewall issues | **Yes** — prefilled pattern like legacy | G-08 | wizard step |
| Q5 | Will WAN/Internet access ever be intended? | security posture (HTTPS, exposure) | **No — LAN only**, port not forwarded | G-23 | if yes: HTTPS becomes mandatory |
| Q6 | May server PC also act as a till? | topology | **Yes** — server mode includes full POS against localhost | G-03 | none |
| Q7 | Maximum simultaneous clients? | pool sizing, testing | **no hard cap**; design for ≥10; revisit if measured | G-28 | none |
| Q8 | Accept **plain HTTP on trusted LAN** for Phase 16, deferring HTTPS to Phase 17? | residual sniff/replay risk (T1/T4/T8) | **defer HTTPS**, document residual risk; Phase 0 says "where feasible" | G-23 | if required now: cert story needed |
| Q9 | Device **display name**: default = Windows machine name, user-editable? | report/UX clarity | machine name default, editable at pairing (immutable `device_id`) | G-04 | none |
| Q10 | When disconnected, may the client browse **stale cached data**? | offline UX | current screens remain visible (no cache layer), mutations disabled | G-16 | offline catalog = big scope |
| Q11 | Show **display names** in reports alongside raw `device_id`? | Phase 14 UI/formulas | **defer** — formulas frozen; display-name join is cosmetic, later phase | G-33 | small Phase 14 touch if approved |
| Q12 | Minimum supported client version policy? | update enforcement | enforce **protocol** match now; app-version floor once releases exist | G-22 | — |
| Q13 | UDP discovery port: same-number-as-HTTP (recommended) vs legacy 50000 vs custom? | firewall UX | **same number as HTTP (8000/udp)**, configurable | G-07 | trivial |

---

## 30. Discrepancy register

| ID | Sources in conflict | Observation | Proposed decision | Status |
|---|---|---|---|---|
| D-01 | Roadmap Phase 3 owns "Device management API"/"Device service" [ROADMAP:139-157] vs Phase 16 owns devices [ROADMAP:665] | Phase 3 device API was never built; Phase 14 deferred `GET /devices` to 16 [PHASE-14 DEF-6] | implement devices fully in Phase 16 (as specified here); do not reopen Phase 3 | RESOLVED |
| D-02 | Blueprint device endpoints [API_BLUEPRINT:594-608] vs modern needs | blueprint has no bodies, no revoke, no poll, uses `{id}` | §16 modernizes: strict bodies, `{device_id}`, adds poll+revoke+code endpoints | RESOLVED |
| D-03 | Blueprint health shape `{status,database,version,uptime}` [:662-674] vs actual `{status,version,environment,database,timestamp}` [MODERN `health.py:24-31`] | example vs implemented | actual wins; blueprint treated as illustrative (documented) | RESOLVED |
| D-04 | `DeviceStatus` = pending/approved/rejected [MODERN `enums.py:171-174`] vs need for **revoked** | revocation is an acceptance criterion | add `REVOKED="revoked"` enum value (code-only; column is VARCHAR) | RESOLVED |
| D-05 | backend `VERSION="0.1.0"` [MODERN] vs Flutter `1.0.0+1` [pubspec] | version identity ambiguous | introduce explicit `protocol` field; align app versions later (packaging) | UNVERIFIED → Q12 |
| D-06 | `settings.HOST/PORT` exist but are dead (0 usages) [MODERN `config.py:43-44`] | config that does nothing | Phase 16 wires them into launch docs + responder; no removal needed | RESOLVED |
| D-07 | Legacy identity = IP/hostname [LEGACY] vs modern `pos-…` device_id [PHASE-14] | different identity models | modern wins; IP is metadata only (`last_ip`) | RESOLVED |
| D-08 | Roadmap Phase 3 lists "Rate limiting" [ROADMAP:139-147] vs 0 rate limiting in code [MODERN] | gap persists after 15 phases | Phase 16 adds *pairing-only* throttle (§12.3); app-wide rate limiting stays open (Phase 17 security pass) | RESOLVED → Phase 17 §17.7 (`app/core/rate_limit.py`: per-IP API backstop + auth/setup/reauth limits, 429 `RATE_LIMITED` envelope) |
| D-09 | Phase 0 lists `print_jobs`/`export_jobs` [DB:47]; Phase 15 deferred them citing "multi-PC Phase 16" [PHASE-15:1191] | multi-PC now arrives — tables still absent | **stay deferred**: synchronous rendering still meets SLOs; no new evidence → do not add tables | RESOLVED |
| D-10 | Blueprint login body has `device_name` [BLUEPRINT:14-16] vs Phase 14 rename to `device_id` [PHASE-14 C4/D5] | two different fields | both exist legitimately: `AuthSession.device_name` (session label) vs `device_id` (reporting key) — documented, no change | RESOLVED |
| D-11 | CORS allows only localhost origins [MODERN `config.py:37`] vs LAN clients | desktop Dio unaffected; browser clients would fail | leave unchanged (no browser client exists); note for any future web UI | RESOLVED |
| D-12 | Roadmap Phase 16 depends on "Phase 3" [ROADMAP:23] vs actual dependency web (auth=P4, device_id=P8/14) | dependency line is stale | treat Phase 16 as depending on Phases 3,4,8,14 (all present) | RESOLVED |
| D-13 | `POST /auth/logout` is a no-op stub vs real `/auth/logout-token` [MODERN `auth.py:156-175`] | client uses the real one | no change in Phase 16; note for Phase 17 cleanup | RESOLVED → Phase 17 §17.7 (`/auth/logout` now revokes the presented token) |

---

## 31. Out of scope (protected boundaries)

- No backup implementation · no general settings system · no final installer or
  firewall manipulation (all Phase 17/packaging).
- No fiscal fields, no report formula changes, no Phase 14 report edits.
- No Phase 15 printing redesign, no ESC/POS, no purchase printing, no Z-report, no
  dashboard PDF; **Phase 15 physical printer QA remains deferred** until hardware.
- **No direct PostgreSQL access from Flutter, ever**; no client DB credentials.
- No offline sale queue / local database on client (§15) unless a future owner
  decision explicitly requests it.
- No WebSocket/SSE, no mTLS/certificate infrastructure, no WAN/Internet features.
- No unrelated refactoring, no broad UI redesign, no dependency additions (D9).
- No changes to existing `device_id` values, headers, columns or report formulas.

---

## 32. Acceptance criteria (traceable)

| Roadmap criterion [PHASE-0:698-703] | Evidence of satisfaction (Step B) |
|---|---|
| Server mode works | server wizard → `app_run_mode=server`; backend with `LAN_MODE=1` boots, responder answers, Devices screen manages registry (tests 27.1) |
| Client mode works | client wizard → discovery → pair → approve → guarded API call succeeds; POS sale completes end-to-end over loopback (test 27.3) |
| Device discovery works | UDP offer received <1 s (loopback test), TCP probe validates `server_id`/`protocol`, garbage port rejected |
| Pairing approval works | pending list → approve issues one-time token; deny → localized rejection; revoke → `device_revoked` 403; audit rows present |
| Connection monitoring works | heartbeat state transitions, chip states, backoff schedule (unit), auto-recovery after backend restart (loopback), sale replay safety on response loss |

Plus non-regression: backend ≥1061 + Flutter ≥1163 green, `ruff app` = 64,
`flutter analyze` clean, Windows build OK.

---

## 33. Step B implementation plan (sequence)

Order chosen to keep every step independently green:

1. **Config** — add `LAN_MODE`, `DISCOVERY_ENABLED`, `DISCOVERY_PORT` (+ make
   `HOST`/`PORT` live in docs/launch); `.env.example` additions. *Tests: config.*
2. **Identity model** — `DeviceStatus.REVOKED`, audit actions `device_*`;
   promote device id to app-level Flutter provider (no format change).
3. **Migration + model** — `0021_phase16_devices.py`, `app/models/device.py`
   (+ export), schemas (`app/schemas/device.py`), repository.
4. **Discovery responder (backend)** — `app/discovery/` packet codec + thread
   responder wired into `main.py` lifespan; loopback tests (§27.1).
5. **Devices service + API** — pair/poll/list/approve/deny/revoke/pairing-code,
   rate limit, audit rows, permissions; `router.py` registration; `test_devices.py`.
6. **Device guard** — router-level dependency + allowlist + `LAN_MODE` switch;
   `test_device_guard.py` incl. regression sentinel (guard off = today's behavior).
7. **`/system/info` additive fields** (`server_id`, `protocol`) + server_id file.
8. **Flutter: dynamic base URL + headers** — `apiClientProvider` from prefs,
   `setBaseUrl`, global `X-Device-ID`/`X-Device-Token`; unit tests (loopback).
9. **Flutter: connection provider** — state machine, heartbeat, backoff+jitter,
   rediscovery; `connection_state_test` (fake clock).
10. **Flutter: discovery service seam** — codec + UDP impl + fake.
11. **Flutter: setup wizard** — role cards, search, confirm, code entry, awaiting
    approval, rejected/timeout; router wiring (`/setup-network`), mandatory-first-run.
12. **Flutter: devices screen + pairing approval dialog + status chip + reconnect
    dialog** — permission-gated nav, AppBar chip.
13. **Localization** — ~46 keys × ar/fr/en + `lan_localization_test.dart`.
14. **Integration/loopback suite** — full §27.3 scenario incl. dual-device sales,
    revoke mid-session, backend restart recovery, idempotent replay from client path.
15. **Regression** — full backend + Flutter suites; `flutter analyze`; ruff; Windows
    build. **Docs:** `docs/PHASE_16_IMPLEMENTATION.md`.

### 33.1 Files that Step B would change

**Backend new:** `app/models/device.py` · `app/schemas/device.py` ·
`app/repositories/device.py` · `app/services/devices.py` · `app/api/v1/devices.py` ·
`app/discovery/{__init__,responder,packet}.py` ·
`migrations/versions/0021_phase16_devices.py` ·
`tests/unit/{test_devices,test_discovery,test_device_guard}.py` (+integration).

**Backend modified:** `app/core/config.py` (3 settings) ·
`app/models/enums.py` (REVOKED + 4 audit actions) · `app/models/__init__.py` ·
`app/api/v1/router.py` (devices router + guard) · `app/api/dependencies.py`
(guard dependency) · `app/main.py` (lifespan responder) · `app/api/v1/system.py`
(2 additive fields) · `.env.example` · `docs/`.

**Flutter new:** `lib/features/devices/{setup_wizard_screen,devices_screen,
connection_provider,discovery_service,reconnect_dialog}.dart` ·
`lib/features/devices/widgets/status_chip.dart` ·
`test/widget/{devices_wizard,devices_screen,connection_status}_test.dart` ·
`test/unit/{discovery_packet,connection_state,lan_localization}_test.dart`.

**Flutter modified:** `lib/network/api_client.dart` ·
`lib/features/auth/auth_provider.dart` · `lib/features/pos/pos_providers.dart`
(promote id) · `lib/router/app_router.dart` (routes + chip) ·
`lib/core/strings.dart` (keys only) · `test/unit/api_client_test.dart` (additive).

**Explicitly unchanged:** every Phase 8/9/11/12/13/14/15 service, report formula,
print/export contract, `pubspec.yaml`, `pyproject.toml` dependencies (no additions).

### 33.2 Potentially required migrations / dependencies

- Migration: **exactly one** (`0021_phase16_devices.py`, additive table).
- Backend dependencies: **none** (stdlib `socket`, `json`, `secrets`, `hashlib`).
- Flutter packages: **none** (`dart:io` `RawDatagramSocket`; `dart:async` Timer;
  existing `flutter_secure_storage` for the token).

### 33.3 Unresolved blockers

None that block Step B. Runtime-open items (not blockers for starting):
G-10/Q1 pairing code, G-23/Q8 HTTPS posture, G-24 firewall (packaging),
G-32 manual two-PC LAN QA (acceptance stage), G-17-runtime concurrency evidence
(existing PG integration suite is the harness).

---

# Final Step A report

**1. Baseline commit** — `b084d3d phase-15: complete printing and exports`.

**2. Current repository state** — clean working tree except two stale untracked
Phase 14 CSV exports; 20 migrations; backend 1061 tests / Flutter 1163 green at
baseline; no Phase 16 code anywhere.

**3. Current LAN/device-related implementation** — attribution only: `X-Device-ID`
header on 6 endpoints, `device_id` free-text on 7 tables, report device breakdown,
JWT+session auth with revocation, `X-Request-ID` middleware, health/system/info
endpoints, unused `device_manage` scope + `DeviceStatus` enum. No registry, no
discovery, no pairing, no monitoring, hardcoded `localhost:8000`.

**4. Legacy LAN behavior** — UDP 50000 broadcast + /24 TCP sweep of MySQL 3306;
client-writes-own-approval pairing (cosmetic); IP identity; root-credential clients;
3-state chip; 18 s monitor; 6 s self-heal; two-card wizard; store confirmation.
Preserve UX beats (§6.1), reject architecture (§6.2).

**5. Recommended target architecture** — Flutter → FastAPI (LAN) → local PG; single
`devices` table; JWT unchanged + per-device token; router guard in `LAN_MODE`;
UDP+HTTP-probe discovery; no WebSocket; no offline writes.

**6. Server mode design** — wizard `server`; backend `HOST=0.0.0.0 LAN_MODE=1
DISCOVERY_ENABLED=1`; responder in lifespan; Devices screen with pairing code +
approval list; local file `server_id`.

**7. Client mode design** — wizard `client`; no backend/PG locally; discover or
manual URL (Q4) → validate `/health`+`/system/info` → pairing code → poll → store
token → dynamic base URL → guarded traffic.

**8. Discovery design** — UDP same-number-as-HTTP (8000/udp, configurable),
256/512-byte JSON packets with magic+nonce, no secrets, 3×750 ms, token-bucket
responder; TCP = HTTP probe of candidates only.

**9. Pairing/auth design** — 11-step flow (§12.2): code → pending row → admin
approve → one-time device token (hash stored) → JWT + device headers; deny/revoke/
re-pair paths; rejected designs listed.

**10. Connection/reconnect design** — 10 s health heartbeat; 2-failure threshold;
backoff 1→30 s ±20 % jitter; remembered-URL-first then rediscovery; `server_id`
re-verification; chip-only steady state; degraded DB = amber not disconnected.

**11. Device registry design** — one `devices` table (15 columns, §10.1);
pairing_requests/device_sessions/settings tables explicitly rejected as unnecessary.

**12. API surface** — 7 new/extended device endpoints + 2 reused (§16), strict
bodies, existing error envelope, additive `system/info` fields.

**13. Permission matrix** — `device_manage` (admin-only) for list/code/approve/
deny/revoke; pairing public-but-coded; no new scopes (§17).

**14. Audit model** — 4 additive actions (`device_pair/approve/reject/revoke`),
actor/device/IP/details, never secrets, no heartbeat rows (§18).

**15. Security findings** — 14-threat table (§21); plain-HTTP residual risk is an
explicit owner decision (Q8); legacy weaknesses (root password in source, DB-port
scan, cosmetic approval) all eliminated by design.

**16. Concurrency findings** — existing FOR UPDATE/guarded-UPDATE/idempotency core
is multi-PC-safe; no service rewrites; dual-device tests added; `last_seen`
write-churn throttled.

**17. Failure/offline semantics** — no offline writes; mutations disabled when
disconnected; safe retry = same `client_request_id` (sale/return/expense/payments/
purchase), void=refetch; response-loss never duplicates a sale.

**18. Version compatibility** — `/api/v1` prefix + `v:1` discovery + `protocol`
field gates pairing; version floor policy = Q12/UNVERIFIED.

**19. Performance targets** — discovery <1 s, probe <300 ms, approval→connect <3 s,
reconnect <10 s, ≥10 clients; Phase 0 SLOs preserved; heartbeat ≤0.1 req/s/device.

**20. Migration requirement** — exactly one additive migration (`devices`), no
backfill, no changes to existing tables/indexes/formulas.

**21. Flutter UX plan** — wizard / devices screen / connection provider / status
chip in shell AppBar / reconnect dialog; dynamic base URL; device id promoted to
app level; ~46 localized keys.

**22. Localization requirements** — 6 key groups, ar/fr/en, parity test, RTL-aware
chip, reuse of existing `retry/network_error*` keys (§24).

**23. Test plan** — 3 new backend unit files + integration, 5 new Flutter test
files + 2 extended; loopback-only network tests; zero edits to existing tests
beyond additive assertions (§27).

**24. Gates** — **RESOLVED 29 · DEFERRED 3 (G-24 firewall/packaging, G-26 server
auto-start, G-32 manual LAN QA) · UNVERIFIED 4 (G-10 pairing code, G-22 min-version
policy, G-23 plain-HTTP posture, G-17 runtime concurrency evidence)** — 36 gates
total, none marked PASS.

**25. Owner questions** — 13 (Q1 pairing code · Q2 approval role · Q3 multi-server
· Q4 manual URL · Q5 WAN · Q6 server-as-till · Q7 client cap · Q8 HTTPS · Q9 device
naming · Q10 stale browsing · Q11 display names in reports · Q12 version floor ·
Q13 UDP port).

**26. Discrepancies** — 13 registered (D-01…D-13): 10 RESOLVED, 2 DEFERRED
(app-wide rate limiting, logout stub), 1 UNVERIFIED (version alignment).

**27. Out-of-scope** — §31: Phase 17 items (backup/settings/installer/firewall
rules), offline queue, WebSocket, HTTPS infra, report/print changes, new
dependencies, direct PG from Flutter.

**28. Exact Step B sequence** — §33, steps 1→15 (config → identity → migration →
discovery → devices API → guard → system fields → client URL/headers → connection
provider → discovery seam → wizard → screens/chip → localization → integration →
regression+docs).

---

## Verification (Step A rules honored)

- Read-only commands only: `git log/status`, file reads, greps, doc extraction.
- **No** source edits, no dependency changes, no migrations, no formatters, no
  commits/pushes. The only artifact created is this document:
  `docs/PHASE_16_LAN_DEVICES_ANALYSIS.md`.

**Files inspected:** backend `main.py`, `core/{config,exceptions,security,middleware,seed,constants}`,
`api/{dependencies.py,v1/{router,auth,health,system,pos,reports,print,exports}}`,
`models/{enums,user,audit,sale}`, `db/{session,engine,base}`, `services/{auth,sale,base}`,
`migrations/versions/*` (20), `pyproject.toml`, `.env.example`, `tests/conftest.py`;
Flutter `lib/{main.dart,network/{api_client,byte_download}.dart,router/app_router.dart,
core/{constants,strings}.dart,l10n/locale_provider.dart,features/auth/{auth_provider,
credential_storage}.dart,features/pos/pos_providers.dart,features/settings/settings_screen.dart}`,
`pubspec.yaml`, `windows/`, `test/` harness samples; legacy
`python_app/{utils/network_discovery.py,database/db_manager.py,gui/main_window.py,
server/server.py,config/db_config.json,security/license.py}`;
docs `PHASE_0_{ROADMAP,API_BLUEPRINT,ARCHITECTURE,SECURITY_AUDIT,DATABASE_ANALYSIS,BUSINESS_RULES,MASTER_SPECIFICATION,PERFORMANCE_AUDIT,POS_WORKFLOW,EXCEPTION_AUDIT,FEATURE_MATRIX}`,
`PHASE_{1,2,3,8,9,11,12,13,14,15}_*`.
