# Phase 16 — LAN / Multi-PC / Devices — Implementation Record (Step B)

**Status:** STEP B IMPLEMENTED — backend (§33 steps 1–7) + Flutter (§33 steps
8–14) complete and green on every automated gate. **No commits, no pushes**
(per execution rules).
**Baseline:** Phase 15 closed at `b084d3d`; Step A analysis in
`docs/PHASE_16_LAN_DEVICES_ANALYSIS.md` (owner answers Q1–Q13 apply).

---

## 0. Verification snapshot (exact results, executed 2026-10-03)

| Gate | Command (cwd) | Result |
|---|---|---|
| Backend tests | `python -m pytest -q` (`new_app/backend`, venv) | **1103 passed, 4 warnings** (warnings pre-existing), **512.38 s** |
| Backend lint (baseline scope) | `python -m ruff check app` | **64 errors — identical to the Phase 15 baseline**, 0 in any Phase 16 file |
| Migration integration | `python -m pytest tests/integration/test_migrations.py -q` | **61 passed**, 110.70 s (incl. `test_autogenerate_detects_no_changes`) |
| Flutter analyzer | `flutter analyze --no-pub` (`new_app`) | **No issues found!** |
| Flutter tests | `flutter test` (`new_app`) | **1259 passed**, exit 0, ~127 s |
| Windows debug build | `flutter build windows --debug` (`new_app`) | **Built OK** — `build\windows\x64\runner\Debug\supermarket_pos.exe`, exit 0, 14.9 s |
| VCS state | `git log -1` / `git status` | HEAD still `b084d3d phase-15` — **no Phase 16 commit, no push** |

Test-count arithmetic:

- Backend **1103 = 1061 (Phase 15) + 42** (`tests/unit/test_phase16_devices.py`).
- Flutter **1259 = 1163 (Phase 15) + 96**:
  `lan_localization_test` 11 + `discovery_packet_test` 23 +
  `connection_state_test` 21 + `connection_status_test` 13 +
  `devices_screen_test` 7 + `devices_wizard_test` 9 +
  `first_run_router_test` 4 + `api_client_test` (additive) 8.
- `ruff --statistics` unchanged: 27 F401, 13 I001, 8 UP035, 6 UP037, 3 N806,
  3 F821, 1 UP006, 1 F811, 1 E712, 1 F841 = **64**.

Re-run after the §5.3 contract reconciliation (same day) — every count
identical: backend **1103 passed** (516.25 s), `ruff check app` **64** with
the same statistics, migrations **61 passed** (113.42 s), Flutter analyze
clean, Flutter **1259 passed** (~129 s), `flutter build windows --debug` OK
(50.1 s), HEAD still `b084d3d`.

---

## 1. Files

### Backend — new

| File | Purpose |
|---|---|
| `app/models/device.py` | `Device` row: `device_id` (unique), `pairing_id` (unique, `uuid4` default), `display_name`, `status` (`pending/approved/revoked/rejected`, indexed, `server_default='pending'`), `token_hash`/`token_expires_at`, `client_version`, `last_ip`, `requested_ip`, `last_seen_at`, `approved_by` (FK → `users.id`, `ON DELETE SET NULL`) |
| `app/schemas/device.py` | `DevicePairRequest` (**field `pairing_code`**), `DevicePairResponse`, `DevicePairingStatusResponse` (**field `server_name`**), `DeviceListResponse`, `DeviceResponse`, `PairingCodeResponse`, `PROTOCOL_VERSION = 1` |
| `app/repositories/device.py` | CRUD + `get_by_pairing_id` / `get_pending` / rotate-code helpers |
| `app/services/devices.py` | pairing-code issuance (TTL + rotation), in-memory rate limit, pairing-id → one-shot device-token vault, approve/deny/revoke, audit rows, device error classes |
| `app/api/v1/devices.py` | the seven admin/pairing endpoints (§3) |
| `app/api/device_guard.py` | router-level `device_guard` dependency + `is_allowlisted()` |
| `app/core/server_identity.py` | stable `server_id` (UUIDv4) persisted under `backend/data/` |
| `app/discovery/{__init__,packet,responder}.py` | UDP wire codec (pure) + lifespan responder thread |
| `migrations/versions/0021_phase16_devices.py` | **the only new migration** (additive `devices` table + 2 indexes) |
| `tests/unit/test_phase16_devices.py` | 42 tests: schemas, service, endpoints, guard, allowlist, rate limit, audit |

### Backend — modified

| File | Change |
|---|---|
| `app/core/config.py` | `LAN_MODE: bool = False`, `DISCOVERY_ENABLED: bool = False`, `DISCOVERY_PORT: int = 8000` (defaults **off** — Phase 15 behaviour is byte-identical until opted in) |
| `app/models/enums.py` | `DeviceStatus.REVOKED`, `PermissionScope.DEVICE_MANAGE` (`device_manage`), `AuditAction` += `DEVICE_PAIR/APPROVE/REJECT/REVOKE` (4 additive) |
| `app/models/__init__.py` | export `Device` |
| `app/api/v1/router.py` | register the devices router **and** mount the guard as an `APIRouter(dependencies=[Depends(device_guard)])` over `/api/v1` |
| `app/api/v1/system.py` | **additive** fields `protocol` (int) and `server_id` (str) on `/api/v1/system/info` |
| `app/main.py` | lifespan starts the discovery responder when `DISCOVERY_ENABLED` |
| `.env.example` | the three settings documented, defaulting off |
| `tests/integration/test_migrations.py` | the 8 `HEAD_REV` constants → `b7f3c2d91a04` (only existing test edited, per instructions) |

### Flutter — new

| File | Purpose |
|---|---|
| `lib/features/devices/device_identity.dart` | `pos_device_id` storage (key/format unchanged, Phase 14), `app_run_mode`, `ServerLink` (`paired_server_url`/`paired_server_id` + device token), `networkConfiguredProvider`, `initialBaseUrl()`, `installBootstrappedProvider` |
| `lib/features/devices/discovery_service.dart` | packet codec (`MAGIC\|json\|NUL`, 256/512-byte budgets), `UdpDiscoveryService` (`RawDatagramSocket`), `FakeDiscoveryService`, `probeServer()` (`/system/info` + `/health` fingerprint, 2 s timeout) |
| `lib/features/devices/connection_provider.dart` | `LanPhase` (10 states), backoff/jitter/heartbeat pure helpers, `LanConnectionState`, `LanConnectionNotifier` (bootstrap → discovery → probe → pair → poll → heartbeat → backoff → `handleDeviceError`/`forgetServer`), `reconnectPromptShownProvider` |
| `lib/features/devices/setup_wizard_screen.dart` | role → searching → confirm → code → waiting (300 s countdown) → failed; `PopScope(canPop: !mandatory)` |
| `lib/features/devices/devices_screen.dart` | server-side registry: pairing-code card, pending list (approve/deny), registered list (revoke), permission-gated on `device_manage` |
| `lib/features/devices/reconnect_dialog.dart` | boot-time modal: Retry / Manual entry |
| `lib/features/devices/widgets/status_chip.dart` | `ConnectionStatusChip` + static `presentation(phase, degraded)` |

### Flutter — modified

| File | Change |
|---|---|
| `lib/network/api_client.dart` | `setBaseUrl()` / `baseUrl`, `setDeviceIdentity()` / `hasDeviceIdentity` (global `X-Device-ID` + `X-Device-Token`), `setOnDeviceError`, `deviceGuardErrorCodes` {`device_required`, `device_not_paired`, `device_revoked`}, `isDeviceGuardErrorCode`, `shouldHandleSessionExpiry` now returns **false** for those codes (JWT preserved), `_AuthInterceptor.onError` branch |
| `lib/core/constants.dart` | `defaultServerBaseUrl`, discovery/heartbeat/backoff tuning (`discoveryAttemptTimeout 750 ms`, `discoveryAttempts 3`, `heartbeatInterval 10 s`, `heartbeatFailureThreshold 2`, `backoffCap 30 s`) |
| `lib/features/auth/credential_storage.dart` | `saveDeviceToken` / `readDeviceToken` / `clearDeviceToken` — **deliberately outside `clearAll()`** so pairing survives logout |
| `lib/features/pos/pos_providers.dart` | `ensurePosDeviceId`/`posDeviceIdProvider` promoted to `deviceIdProvider` in `device_identity.dart`; `posDeviceIdProvider = deviceIdProvider` (same key `pos_device_id`, same `pos-<millis>-<rand>` format) |
| `lib/main.dart` | builds `ApiClient(baseUrl: await initialBaseUrl())`, re-attaches device identity, adds `installBootstrappedProvider` override |
| `lib/router/app_router.dart` | `/setup-network` + `/devices` routes, first-run redirect, nav destination gated `device_manage`, `ConnectionStatusChip` in the AppBar, boot-time reconnect modal |
| `lib/core/strings.dart` | **61 Phase 16 keys × ar/fr/en** (183 entries) |
| `test/unit/api_client_test.dart` | +8 additive tests (device-code exclusion, `setBaseUrl`, `setDeviceIdentity`) |

---

## 2. Decision → implementation map (Q1–Q13)

| Decision | Implementation |
|---|---|
| Q1 6-digit pairing code required | `POST /devices/pair` takes `pairing_code`; wrong code → 401 `PAIRING_CODE_INVALID`; IP+name alone never pairs |
| Q2 admin only | `device_manage` (admin seed); manager gets `permission_denied`; **no permissions were added** (`test_auth.py` pins `permissions == 30`) |
| Q3 one active server, multiple offers shown | discovery lists every offer; wizard renders each and the user confirms the store name |
| Q4 manual address entry | `manual-host` + `manual-connect` in the searching step; `probeServer()` rejects a non-supermarket HTTP host |
| Q5 LAN only, no WAN | plain HTTP everywhere; no TLS/HTTPS code path added |
| Q6 server PC may also be a till | choosing *server* role `context.go('/')` — full POS against `localhost` |
| Q7 no hard cap | no connection pool or cap introduced; state is one `StateNotifier` per install |
| Q8 plain HTTP deferred | as Q5 — documented residual sniff/replay risk, Phase 17 |
| Q9 machine name default, editable at pairing | `Platform.localHostname` used when no offer name, `display_name` sent with the pairing request |
| Q10 no offline writes | `LanConnectionState.mutationsAllowed` is true **only** in `connected`; the UI disables mutations otherwise; the connection layer queues nothing |
| Q11 display names in reports deferred | no report formula or report column touched |
| Q12 protocol match enforced now | `supportedProtocolVersion = 1`; `probeServer()` refuses an offer whose `protocol` differs |
| Q13 discovery port = HTTP port | `DISCOVERY_PORT: int = 8000` (same number as `PORT`), configurable |

---

## 3. API surface (frozen for Step B)

| Endpoint | Body / params | Success | Scope |
|---|---|---|---|
| `POST /api/v1/devices/pair` | `{pairing_code, display_name, device_id, client_version?}` | `DevicePairResponse` = `201 {pairing_id, status:"pending"}` — **no token field at all** (the credential does not exist until an admin approves) | pairing code (no JWT) |
| `GET /api/v1/devices/pairings/{id}` | — | `DevicePairingStatusResponse {status, server_name, device_token?, server_id, http_port, protocol, tls, token_unavailable}` — `device_token` is non-null **only on the first poll after approval**; every later poll returns `null` + `token_unavailable: true` | pairing id (no JWT) |
| `GET /api/v1/devices` | — | `DeviceListResponse {items, total, page, page_size, pages}` | `device_manage` |
| `GET /api/v1/devices/pairing-code` | — | `PairingCodeResponse {code, generated_at, expires_at, expires_in_seconds, protocol, server_id, http_port}` | `device_manage` |
| `POST /api/v1/devices/{device_id}/approve` | — | `DeviceResponse` (**no token**) | `device_manage` |
| `POST /api/v1/devices/{device_id}/deny` | `{}` | `DeviceResponse` | `device_manage` |
| `POST /api/v1/devices/{device_id}/revoke` | `{}` | `DeviceResponse` | `device_manage` |
| `GET /api/v1/system/info` | — | **+** `protocol`, `server_id` (additive; `name/version/environment/database_status/timestamp` unchanged) | allowlisted |

Guard error codes/status (Step A §12): `device_required` **401** (no
identity offered at all), `device_not_paired` **403**, `device_revoked`
**403** (identity offered and refused); `PAIRING_CODE_INVALID` **401**,
`PAIRING_RATE_LIMITED` **429**, `DEVICE_ALREADY_PAIRED` **409**. The
envelope is unchanged by the status: `{error:{code, message_key,
message, details, request_id}}`, and Flutter branches on `error.code`.
Guard allowlist (prefix-based): `/api/v1/health`, `/api/v1/system/info`,
`/api/v1/auth`, `/api/v1/devices`.
**`LAN_MODE=0` (default) → the guard is inert, i.e. exactly today's
behaviour** (regression sentinel in `test_device_guard.py`).

Discovery datagrams carry **no secrets** — only `server_id`, store name and
port (`DISCOVERY_ENABLED=0` by default).

---

## 4. Flutter flow (contracts the tests pin)

1. **First run:** `main()` → `initialBaseUrl()` + persisted device identity →
   router redirect forces `/setup-network` until a run mode exists → wizard
   (`PopScope(canPop: false)` while mandatory) → *server* goes straight to
   `/`, *client* searches (UDP sweep → probe → confirm) → 6-digit code →
   `POST /devices/pair` (body is `{pairing_id, status}` only, never a token) →
   `GET /devices/pairings/{id}` every 2 s up to 5 min → the token arrives
   **once, on the first poll after approval** (later polls return
   `token_unavailable: true`) → stored in `flutter_secure_storage`, link
   persisted, heartbeat starts.
2. **Steady state:** `GET /api/v1/health` every 10 s; **2 consecutive failures
   → `reconnecting`**; backoff **1,2,4,8,16 then 30 s cap, ±20 % jitter, first
   attempt immediate**; a changed `server_id` stops the loop and asks for a
   re-pair. The AppBar chip is the only steady-state indicator (green / amber
   for a degraded server DB / red), and the modal appears **once, at boot
   only** — a mid-session flap never interrupts a cashier.
3. **Server admin:** `/devices` (nav gated `device_manage`) → generate/rotate
   the pairing code, approve (confirmed) / deny / revoke (confirmed). The
   screen never renders a device token.

---

## 5. Implementation decisions, defects found, deviations

### 5.1 First-run router gate — why `installBootstrappedProvider` exists

§23.2 requires "client mode + not paired → `/setup-network` before login" and
§33 step 11 requires a *mandatory* first run, i.e. `app_run_mode` absent must
also be forced into the wizard. Implementing that literally broke the
pre-existing `test/widget/reports_screen_test.dart` (11 tests), which boots
`SupermarketPosApp` with an empty `SharedPreferences` and expects to reach the
**login** screen — and existing tests may not be modified.

Resolution: the redirect is now gated on `installBootstrappedProvider`
(`false` by default, overridden to `true` in `main()`). Every real launch
enforces the mandatory first run exactly as specified; hosts that embed
`SupermarketPosApp` without going through `main()` (widget-test harnesses,
previews) are inert. New coverage: `test/widget/first_run_router_test.dart`
(4) pins both sides — a bootstrapped install with no run mode is locked to
`/setup-network` (and `/pos` bounces back), an install with a run mode goes to
`/login`, and a non-bootstrapped host is never forced in.

### 5.2 `reconnect_dialog.dart` was dead code — now wired (boot-only)

The file existed but nothing called it. `ScaffoldWithNav` now `ref.listen`s to
`lanConnectionProvider` and opens `ReconnectDialog` **only** on a
`connecting → reconnecting|disconnected` transition (a phase entered solely by
`bootstrap()`, a completed pairing, or an explicit *retry now*), guarded by
`reconnectPromptShownProvider` so it happens at most once per run. A
mid-session `connected → reconnecting` flap therefore shows the chip and
nothing else — the §14 legacy policy, pinned by 3 new tests.

### 5.3 Contract reconciliation (pair token delivery, guard status codes)

Two findings from a review of Step B against
`PHASE_16_LAN_DEVICES_ANALYSIS.md`, fixed in place:

**Token delivery.** Canonical flow: `POST /devices/pair` → `201
{pairing_id, status:"pending"}` (no token field at all) → admin approval
generates the credential → `GET /devices/pairings/{id}` hands it over
**exactly once**, on the first poll after approval → every later poll
returns `device_token: null` plus `token_unavailable: true`.

- The service already generated the token at approval and never returned it
  from `POST /pair`, but `DevicePairResponse` was wider than the contract
  (`device_id`, `display_name`, `poll_after_ms`, `protocol`) and §3 wrongly
  listed `device_token` in the pair row. It is now exactly
  `{pairing_id, status}`, built from those two fields only.
- Pinned by `test_pair_then_poll_is_pending` (`set(body) == {"pairing_id",
  "status"}`, no `device_token` key) and
  `test_approve_delivers_token_exactly_once` (first poll delivers, second
  poll `null` + `token_unavailable: true`, registry row never holds
  plaintext).

**Guard status codes.** `device_not_paired` and `device_revoked` were raised
as 401; Step A §12 requires 403. Now `device_required` → **401** (no identity
offered), `device_not_paired` → **403**, `device_revoked` → **403**
(identity offered and refused), and the unused `DeviceTokenInvalidError`
(carrier of the same `device_not_paired` code) follows. The envelope
(`{error:{code, message_key, message, details, request_id}}`) is emitted from
`code`/`message_key` by `app_error_handler`, so it is byte-identical, and
`_AuthInterceptor.onError` branches on `error.code` *before* it considers the
status — no Flutter behaviour moved. Only the four guard status assertions in
`tests/unit/test_phase16_devices.py` and the two status expectations in
`test/unit/api_client_test.dart` changed; the header-missing case stays 401
and the JWT-missing case stays an ordinary `UNAUTHORIZED` 401.

### 5.4 Real 2-PC discovery bug — offer missing the `app` field

Found in genuine two-PC testing: broadcast left PC2, `DiscoveryResponder`
answered on PC1, the offer parsed as well-formed, TCP 8000 /
`/api/v1/health` / `/api/v1/system/info` all answered — and the Flutter
wizard still reported "server not found".

Cause: `discovery_service.dart::_decode` requires
`decoded['app'] == discoveryAppId` (`"supermarket_pro"`) on **every**
datagram, while the backend `build_offer()` sent no `app` at all, so the
client silently dropped a perfectly good offer. The backend's own
`parse_discover()` never required `app`, which is why the request side
worked and the mismatch stayed invisible until a second PC was used.

Fix — backend contract only, Flutter validation untouched:
`app/discovery/packet.py` now emits `"app": "supermarket_pro"` in every
offer (new `APP_ID`, documented as the counterpart of Flutter's
`discoveryAppId`). Covered by `test_offer_matches_the_flutter_client_contract`
(exact key set, `app`, `v`, `t`, nonce echo,
`server_id`/`name`/`http_port`/`protocol`/`tls`, no secrets, ≤ 512 B) plus
`app` assertions on the roundtrip and the loopback-responder tests.

### 5.5 Loopback exception — the server PC's own POS (Q6)

Found in real 2-PC QA: with `LAN_MODE=1` the store server's own POS got
`401 device_required` on every ordinary route (`/dashboard`, `/products`,
`/categories`, `/packs`, `/expenses`, `/returns`, `/pos/…`) even though
login and `/auth/me` returned 200 — the guard was locking the server PC
out of its own till, contradicting Q6 ("server PC may also be a till"),
whose local POS boots against `http://localhost:8000` and therefore has
no paired device.

Fix (one rule, `app/api/device_guard.py`): a request whose **TCP peer
address is this machine** — `127.0.0.1`, `::1` or `::ffff:127.0.0.1` —
skips the *device* layer only. JWT + RBAC still run on every route, the
guard stays on for LAN_MODE, and a `192.168.x.x` client can never present
a loopback peer address, so remote tills keep `X-Device-ID` +
`X-Device-Token` with unchanged 401/403 codes. `LAN_MODE=0` behaviour is
untouched.

5 new tests (peer address is set with Starlette's `TestClient(client=...)`
— its default peer is `"testclient"`, i.e. never loopback): loopback + JWT
without device headers → 200 on 7 routes; remote peer without headers →
401 `device_required`; remote peer with an unpaired device → 403
`device_not_paired`; loopback without JWT → 401 `UNAUTHORIZED`; `LAN_MODE=0`
→ 200 for both peers.

Launch inspection (nothing changed): the app never binds a socket itself —
no `uvicorn.run`, no usage of `settings.HOST`. The bind address is
entirely the launch command, and the documented LAN command stays
`uvicorn app.main:app --host 0.0.0.0 --port 8000`. No config was moved to
127.0.0.1.

### 5.6 Real 2-PC restart bug — the client never repaired `paired_server_url`

**Symptom (PC2, after PC1 moved 192.168.1.7 → 192.168.1.20).** Restarting the
paired Flutter client showed the generic connection-failure screen with a Retry
button. Retry produced **no request at all** in FastAPI's log, and UDP
rediscovery never ran. Manual UDP discovery from PC2 and
`GET /api/v1/health` on the new address both worked, and PC2 had paired
successfully *before* the IP change.

**Root cause — two independent Flutter defects.**

1. *The reconnect machine was never started.* `lanConnectionProvider` — the only
   thing that runs `bootstrap()` — was referenced from exactly three places:
   `ScaffoldWithNav` (`router/app_router.dart:270`), `ConnectionStatusChip`
   (`widgets/status_chip.dart:42`) and the first-run wizard
   (`setup_wizard_screen.dart`). The first two mount only **after** a
   successful login, and the wizard is only reachable while
   `isNetworkConfigured()` is false — which it is not for a paired install. A
   client whose remembered address had gone stale therefore could not
   authenticate, never mounted the shell, and `bootstrap()` never ran: no
   heartbeat, no probe, no sweep.

2. *Rediscovery existed only for the first-run wizard.* `startDiscovery()` had a
   single caller (`setup_wizard_screen.dart:77`). `bootstrap()` re-applied the
   persisted link and ticked `_api.baseUrl`, and `retryNow()` did the same —
   neither ever swept UDP. So even when the machine did run, "reconnect" meant
   re-issuing `GET /api/v1/health` against `192.168.1.7` forever.

**Why nothing appeared in FastAPI's log.** Every request the client made
(`/auth/verify-token`, `/auth/setup/check`, `/auth/login-users`) was addressed
to `http://192.168.1.7:8000`. That host no longer exists, so the TCP connect
fails before a single packet reaches 192.168.1.20 — PC1 never sees them. The
login screen's Retry only re-issued the same GET against the same
`ApiClient.baseUrl`.

**Why manual URL worked before the change.** `initialBaseUrl()` returns the
persisted `paired_server_url`, which was correct while PC1 was
`192.168.1.7`; auth, login and heartbeat all went to a live host.

**Fix — 3 files, Flutter only (no backend, no pairing/security change).**

| file | change |
|---|---|
| `lib/main.dart` | `ref.read(lanConnectionProvider)` on the first frame of `SupermarketPosApp`: the machine now starts before authentication (`read`, not `watch`, so the app is not rebuilt on every connection tick). |
| `lib/features/devices/connection_provider.dart` | new `_recoverAddress()` — **cached address first** (a 2 s `/health` + `/system/info` probe, filtered by `paired_server_id`), **then UDP sweep → probe → adopt**. On success it rewrites `paired_server_url` (never the device token), repoints the shared `ApiClient`, and keeps the same `server_id`, so no re-pair is ever asked for. Hooked into `bootstrap()`, `retryNow()` and the new public `reacquireServer()`. Heartbeat connection failures now record `errorMessage: 'unreachable'` (the reconnect dialog's existing branch finally fires). `probeServer` became an injectable constructor seam — the production default is unchanged. |
| `lib/features/auth/login_screen.dart` | the login screen's **Retry** awaits `reacquireServer()` before re-requesting `/auth/login-users`; previously it only re-issued the GET, which is the reported "no request at all" symptom. |

Identity is still `server_id`, never the address: offers with a different
`server_id` are filtered **before** they are even probed, the remembered
address answering as another server still ends in
`forgetServer('server_changed')`, and the device token is never rewritten.

**Tests added (8):** `test/unit/lan_address_recovery_test.dart` (6 — healthy
address does not sweep, dead address is replaced and persisted, foreign
`server_id` is never adopted, `retryNow` rediscovers, `reacquireServer` is a
no-op when unpaired, `reacquireServer` repairs the login Retry's link) and
`test/widget/boot_reconnect_test.dart` (2 — the provider exists on the first
frame while only `LoginScreen` is mounted; the login Retry sweeps, repoints
`ApiClient` and reloads).

**Residual behaviour.** If the sweep finds nothing, the client keeps the
remembered address and stays on the existing heartbeat/backoff loop, so the
boot reconnect dialog ("Try again now" / manual entry) remains the fallback
for a server that is simply down.

### 5.7 Real 2-PC broadcast bug — `SO_BROADCAST` was never enabled

**Symptom (PC2, after the §5.6 fix rebuilt).** Rediscovery was reached
correctly —

```
[LAN] cached address http://192.168.1.7:8000 is unusable → UDP rediscovery

Unhandled Exception: SocketException: Send failed
(OS Error: An attempt was made to access a socket in a way forbidden by its
 access permissions, errno = 10013)
address = 0.0.0.0, port = 0
    UdpDiscoveryService._start.sendOnce
    discovery_service.dart:265 socket.send(...)
    discovery_service.dart:272 sendOnce()

[LAN] rediscovery found no offer for server_id 9a0cac7d-…
```

The same PC2 reaches PC1 over HTTP, and a **manual PowerShell UDP broadcast
from PC2 gets PC1's `SUPERMARKET_PRO_DISCOVER_V1{…}` offer** — so PC1's
responder, the packet, the port, the firewall and the pair were all fine.

**Root cause 1 — IPv4 broadcast was never switched on.** The source carried
this comment:

> `dart:io` exposes no SO_BROADCAST toggle on RawDatagramSocket

**That assumption is false.** The Dart SDK declares
`RawDatagramSocket.broadcastEnabled` (`dart:io` `socket.dart:1268-1275`):

> Whether IPv4 broadcast is enabled. IPv4 broadcast needs to be enabled by
> the sender for sending IPv4 broadcast packages. **By default IPv4 broadcast
> is disabled.**

and implements it as a real `SO_BROADCAST` socket option
(`socket_patch.dart:3080-3082`). With the option off, Windows rejects every
send to `255.255.255.255` / `x.x.x.255` with `WSAEACCES` = **errno 10013**
— the reported error — while unicast (the PowerShell *receive* side, PC2 →
PC1 HTTP) keeps working. Nothing ever left PC2, so PC1's responder logged
nothing.

**Root cause 2 — the failure is a socket *stream* event, not a throw.** The
`try/catch` around `socket.send()` could never see it:

- `RawDatagramSocket.send` (`socket.dart:1325-1327`): "If a local failure to
  send the datagram occurs then **an error event will be added to the
  Stream**."
- The VM wraps the native call: `_NativeSocket.send` catches, then
  `scheduleMicrotask(() => reportError(e, st, "Send failed"))`
  (`socket_patch.dart:1512-1516`); `reportError` invokes the socket's error
  handler → `_controller.addError(e, st)` and **closes the socket**
  (`socket_patch.dart:1926-1940`, `2980-2983`).
- `_RawDatagramSocket.listen` forwards `onError` straight to that controller
  (`socket_patch.dart:3015-3027`). Our call had **no `onError`**, so the
  error fell through to the zone → *Unhandled Exception*.

That also explains the "synchronous-looking" stack: it is
`StackTrace.current` captured inside `send()`'s own `catch` and handed to
the microtask, so the frames are the send site even though delivery is
asynchronous.

**Fix — 2 files, Flutter only.**

| file | change |
|---|---|
| `lib/features/devices/discovery_service.dart` | `socket.broadcastEnabled = true;` immediately after `RawDatagramSocket.bind(...)`, with the false comment replaced by the SDK citation; `socket.listen(...)` now has an `onError` that logs `[LAN] discovery socket error: …` and forwards the error to the stream controller (surfaced to the caller, not swallowed) plus an `onDone` that closes the controller; the per-target send `catch` now logs instead of suppressing. A bind/enable failure propagates out of `_start` into `discover()`'s existing `catchError` → the subscriber. |
| `lib/features/devices/connection_provider.dart` | the two remaining silent discovery catches now log: `startDiscovery`'s `onError` prints `[LAN] discovery failed: …`, `_recoverAddress`'s sweep `catch` prints `[LAN] UDP rediscovery failed: …`. |

Untouched: packet format and the wire contract, discovery port `8000`,
target generation, pairing, `server_id` validation, the device token, the
backend, the firewall and no migration/dependency.

A `DatagramBinder` constructor seam (`bindSocket`) lets a test observe socket
setup without an OS socket; the production default is the original
`RawDatagramSocket.bind(InternetAddress.anyIPv4, 0, reuseAddress: true)`.

**Tests added (3):** `test/unit/discovery_socket_test.dart` —
(1) broadcast is enabled **before** the first datagram and the first send
lands on `255.255.255.255:8000` / `127.0.0.1:8000`; (2) a socket error event
is delivered to the subscriber while the zone's uncaught handler stays
empty; (3) a bind failure surfaces on the stream. Both mutations were
checked by hand: removing `broadcastEnabled = true` fails (1), removing the
listener's `onError` fails (2) with exactly the QA stack. The packet tests in
`test/unit/discovery_packet_test.dart` are untouched.

**Windows / manual 2-PC QA note (real broadcast).**

Preconditions: PC1 `uvicorn … --host 0.0.0.0 --port 8000` with
`DISCOVERY_ENABLED=1`; PC2 paired and holding a **dead** `paired_server_url`
(`http://192.168.1.7:8000`) to force the sweep; both on the same subnet.

1. *Baseline* — the PowerShell broadcast from PC2 still answers with
   `SUPERMARKET_PRO_DISCOVER_V1{…}` (this isolates app regressions from
   network regressions).
2. *Restart PC2* → console must show `[LAN] cached address … → UDP
   rediscovery` **without** any `SocketException`, then
   `[LAN] rediscovered the paired server at http://192.168.1.20:8000`.
3. *PC1 side* — no responder log exists for discovery, so confirm the offer
   arrived by PC2's adoption (`paired_server_url` now `.20`, no
   `/devices/pair`, `X-Device-Token` unchanged, login works). Optional:
   `pktmon`/Wireshark UDP capture on PC2 shows the outbound broadcast and
   PC1's reply on port 8000.
4. *Failure path* — with PC1 stopped, PC2 must log
   `[LAN] discovery socket error: …` **or** `[LAN] UDP rediscovery failed: …`
   and fall back to the remembered address/backoff loop, never an
   unhandled exception and never a wizard re-pair.
5. *Regression guard* — a third PC on the same LAN answering port 8000 must
   be ignored (foreign `server_id` filtered before probing).

**Residual behaviour.** One refusing interface is still tolerated (logged,
not fatal), because a multi-homed NIC may reject a broadcast target; a
socket-level error is reported once, the VM closes that socket, and the
sweep degrades to "no offers" → the existing reconnect fallback.

### 5.8 Deviations / notes

- **Migration verified, not assumed:** `alembic revision --autogenerate`
  reports *no changes* against the model (`test_autogenerate_detects_no_changes`
  passes); the only new revision is `0021_phase16_devices.py`, single head.
- **Contract corrections found while writing the Flutter layer** (the backend
  is authoritative): the pair body field is `pairing_code` (not `code`), and
  `GET /devices/pairings/{id}` returns `server_name` (not `name`).
- `app/discovery/__init__.py` was initially missing (implicit namespace
  package) — added to match §33.1.
- `debugSetState()` is a `@visibleForTesting` seam on `LanConnectionNotifier`;
  without it every state-machine widget test would need real sockets.
- `pos_device_id` key and `pos-<millis>-<rand>` format are untouched (Phase 14
  contract); `pos_providers.dart` now re-exports `deviceIdProvider` under the
  old name so no call site changed.
- `PermissionScope` was **not** widened (`permissions == 30` is pinned by
  `test_auth.py`); `device_manage` already exists in the seed.

### 5.9 Tooling notes (reusable)

- **Never prepend the venv to `PATH` when running backend tests.**
  `_run_alembic` in `tests/integration/test_migrations.py` shells out to
  `python -m alembic` using **PATH**; the Windows Store Python on PATH has
  `tzdata`, the venv does not → `alembic revision --autogenerate` fails with
  `Can't locate timezone: UTC` (because `alembic.ini` sets `timezone = UTC`).
  Invoke the venv interpreter directly (`& "…\.venv\Scripts\python.exe" -m
  pytest …`) and leave `PATH` alone. Note the venv interpreter *also* runs the
  whole suite green — only the alembic CLI subprocess is affected.
- Widget tests whose screen hosts an infinite animation (`CircularProgressIndicator`
  in the wizard/POS) must use bounded `tester.pump(Duration(...))` loops —
  `pumpAndSettle` never returns.
- `Directionality` in a widget test comes from `MaterialApp.locale`, not from
  `localeProvider`; RTL assertions need `locale` + `supportedLocales` +
  `localizationsDelegates` on the harness.
- `FutureProvider` in Riverpod 2.6 has `overrideWith`, **not**
  `overrideWithValue`.
- **The suite is written for the default config.** Real 2-PC QA needs
  `.env` → `LAN_MODE=1` / `DISCOVERY_ENABLED=1`, which makes the
  default-config sentinels fail (`test_guard_is_a_noop_when_lan_mode_is_off`,
  `test_discovery_is_off_by_default`) — override them per run instead of
  editing tests: `$env:LAN_MODE='0'; $env:DISCOVERY_ENABLED='0'; pytest -q`
  (OS env beats `.env` in pydantic-settings).

---

## 6. Verification (technical) — FINAL

```
backend:  pytest -q                       → 1103 passed, 4 warnings (pre-existing), 512.38 s
          ruff check app                  → 64 errors (= Phase 15 baseline; 0 in Phase 16 files)
          pytest tests/integration/test_migrations.py -q → 61 passed, 110.70 s
flutter:  analyze --no-pub                → No issues found!
          test                            → 1259 passed (exit 0), ~127 s
          build windows --debug           → OK (supermarket_pos.exe, exit 0, 14.9 s)
git:      HEAD                            → b084d3d (phase-15) — no commit, no push
```

Re-verified after the §5.3 contract reconciliation (pair body + guard 403):
same six results — **1103 / 64 / 61 / clean / 1259 / build OK**, HEAD
unchanged.

Re-verified after the §5.4 discovery `app` fix: discovery subset **8
passed**, full backend **1104 passed** (1103 + 1 new contract test),
526.13 s, `ruff check app` **64** with `app/discovery/packet.py` clean.
Run with `LAN_MODE=0 DISCOVERY_ENABLED=0` in the process environment —
`.env` now enables both for the owner's real 2-PC QA. Phase 16 was
committed by the owner as `8332a20`; this fix is uncommitted.

Re-verified after the §5.5 loopback (Q6) fix: Phase 16 file **48 passed**,
full backend **1109 passed** (1104 + 5 new Q6 tests), 517.87 s,
`ruff check app` **64** with `app/api/device_guard.py` clean. Bug fix #1
was committed by the owner as `67d20a6`; bug fix #2 (this one) is
uncommitted. The run used the `LAN_MODE=0 DISCOVERY_ENABLED=0` override
because `.env` still enables both for real 2-PC QA.

Re-verified after the §5.6 paired-client restart fix (Flutter only):
`flutter analyze --no-pub` → **No issues found**, `flutter test` →
**1267 passed** (1259 + 8 new, 2 min 23 s), `flutter build windows --debug`
→ **OK (supermarket_pos.exe, 23.4 s)**. No backend file, no migration, no
dependency and no pairing/security rule was touched.

Re-verified after the §5.7 broadcast / socket-error fix (Flutter only):
`flutter analyze --no-pub` → **No issues found**, `flutter test` →
**1270 passed** (1267 + 3 new, 2 min 26 s), `flutter build windows --debug`
→ **OK (supermarket_pos.exe, 17.4 s)**. Both mutations were checked by hand
— deleting `socket.broadcastEnabled = true` fails test (1); dropping the
listener's `onError` fails test (2) with the exact QA stack. No backend
file, no migration, no dependency, no pairing/security rule, no firewall
setting and no discovery wire-contract change. HEAD → `3b2dd15`; this fix
is uncommitted.

---

## 7. Not touched (forbidden / out of scope for Step B)

- No commits, no pushes, no `pubspec.yaml` / `pyproject.toml` dependency
  additions (§33.1 "explicitly unchanged"), no config changes.
- No existing test modified except the 8 `HEAD_REV` constants in
  `tests/integration/test_migrations.py` and the Phase 16 contract updates of
  §5.3 (`tests/unit/test_phase16_devices.py`: pair body shape + guard 403;
  `new_app/test/unit/api_client_test.dart`: canonical guard statuses). No
  Phase 14/15 test, contract or formula was touched.
- Report formulas, print/export contracts, Phase 8–15 services and screens:
  untouched beyond the files listed in §1.
- No offline cart queue, no local SQLite, no `connectivity_plus`, no TLS
  (§23.3 "explicitly not built").
- `LanConnectionState` never queues a mutation — offline writes stay forbidden
  (Q10 / §15).

---

## 8. Human QA decision (2026-10-03)

| QA item | Result |
|---|---|
| Automated QA — backend **1103 passed**, `ruff check app` = 64 baseline, migration integration **61 passed**, Flutter analyze clean, Flutter tests **1259 passed** | **PASS** |
| Windows build — `flutter build windows --debug` → `supermarket_pos.exe`, exit 0 | **PASS** |
| Single-PC flow (wizard role choice, device screen, chip, permission gate, error/cancel paths) — simulated and pinned by the suites | **PASS** |
| **Real 2-PC LAN QA** (server + client on one LAN: UDP discovery, pairing code, admin approval, heartbeat loss/recovery, revoke mid-session, backend restart) | **DEFERRED / PENDING — requires a second machine on the same LAN** |
| Production deployment QA (`LAN_MODE=1`, `DISCOVERY_ENABLED=1` against a real store network, firewall/port behaviour) | **DEFERRED / PENDING — no live LAN available in this environment** |

The two LAN items are deferred **solely because this environment has no
second machine on a shared LAN — this is NOT a software failure**. They do not
block software phase closure: every automated gate of Phase 16 is green (§0,
§6), the approved scope (§2, §3) is unchanged, and no mock, stub or scope
change was introduced to compensate. The §27.3 loopback/integration scenarios
that *can* run single-process (packet codec, guard, pairing lifecycle, rate
limit, audit) are covered by `tests/unit/test_phase16_devices.py`;
the two-PC scenarios will be executed when a second machine is available.

## 9. Closeout — Phase 16 Step B

Step B is complete and green on every automated gate (backend tests/lint,
migration integration, Flutter analyzer/tests, Windows debug build). Human QA
software items PASS; real 2-PC LAN QA deferred per §8 without blocking
closure. Ready for: commit of the Phase 16 change set → push, in the order the
execution rules prescribe.
