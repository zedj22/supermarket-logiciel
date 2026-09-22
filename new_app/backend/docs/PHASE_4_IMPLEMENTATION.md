# Phase 4 — Authentication, Users & Permissions

**Date:** 2026-09-22
**Status:** 🔄 Phase 4 Implementation Complete + Final Shell/Logout/Audit + Users-Nav visibility fix (+ /auth/me permission refresh) + Manual Bug Fix 2 (desktop keyboard PIN + wrong-PIN user preservation) applied — **manual verification still PENDING (must be performed by a human on a FRESH build; see Final Manual Verification below)**
**Backend Tests:** 224 passed, 0 failed
**Flutter Tests:** 123 passed, 0 failed
**Flutter Analyze:** No issues found

---

## Phase 4 Bug Fix — Login User Discovery / 401 Handling (2026-09-22)

### Root cause

- `login_screen.dart` loaded the login selector from `GET /api/v1/users`, which is
  protected by JWT + `user_manage` permission. The login screen runs before any
  JWT exists, so the backend returned `401 Unauthorized` ("Missing authentication
  token") on every attempt to load users.
- The Dio `_AuthInterceptor` treated ANY 401 as "session expired": it cleared the
  token and fired the `onUnauthorized` callback even for unauthenticated requests
  and public authentication endpoints.
- The login screen mapped every `DioException` to the generic localized string
  "Connection error, please try again", which was misleading because the backend
  was reachable (it responded 401).

### Public login user discovery endpoint

Added `GET /api/v1/auth/login-users`:

- Public — no JWT and no admin permission required (login selector must work
  before any token exists).
- Response shape: `{"items": [{"id", "full_name", "is_active", "roles": [{"name"}]}], "total"}`.
- Returns **only active users**, ordered by full name.
- Exposes ONLY the minimum selector fields. Never exposes `pin_hash`,
  `failed_login_attempts`, `locked_until`, `last_login_at`, `last_logout_at`,
  `created_at`, session data, audit data, or any internal security field.
- `GET /api/v1/users` stays protected exactly as before (JWT + `user_manage`).

The login flow is now:

```
GET /api/v1/auth/setup/check
  ↓ (setup not required)
GET /api/v1/auth/login-users      ← public user discovery
  ↓ select user
POST /api/v1/auth/login
  ↓ store secure token
GET /api/v1/auth/me if required
  ↓
authenticated
```

### 401 interceptor correction

`lib/network/api_client.dart`:

- New pure function `shouldHandleSessionExpiry(err, hasToken:)` decides when a 401
  means session expiry. It fires ONLY when ALL of these hold: status is 401, a
  token is currently attached, and the failing request is NOT a public
  authentication path.
- `publicAuthPaths` covers setup, login, verify-token, login-users, and logout.
- A 401 on a public/authentication request now passes through as an ordinary API
  error and never triggers the unauthorized callback.
- Only authenticated requests on protected endpoints cause session-expiry handling.
- No auth redirect loops: the login/setup flow never touches `onUnauthorized`.

### Error messaging

- `isConnectionError()` is true only when no HTTP response was received — i.e. a
  real network failure. That path shows the localized connection error.
- `backendErrorMessage()` extracts the structured `{"error": {"message": ...}}`
  body and other message fields.
- HTTP 401 → authentication error, 403 → permission error, 422 → validation
  error, other HTTP errors → backend/API error. A 401 is never shown as a
  connection error.

### Tests

Backend — new `tests/unit/test_login_users.py` (8 tests):

- login-users works without any JWT
- login-users works even with a bogus JWT attached
- login-users returns only active users
- login-users includes role names
- login-users does not expose security-sensitive fields
- GET /api/v1/users still requires authentication (no token → 401)
- GET /api/v1/users rejects an invalid token (→ 401)
- public discovery endpoint is not tied to the admin `user_manage` permission

Flutter — `api_client_test.dart` + `login_screen_test.dart`:

- `shouldHandleSessionExpiry` matrix: non-401, unauthenticated (no token), public
  auth paths, protected path while authenticated
- `isConnectionError` / `backendErrorMessage` behavior
- Live-HTTP interceptor tests: 401 on a protected endpoint expires the session
  when authenticated; 401 on a public auth endpoint does not expire (both with and
  without a stale token)
- Login screen widget tests: loads from `/api/v1/auth/login-users` and never calls
  `GET /api/v1/users` before authentication; discovery failure shows the backend
  error instead of "connection error"

### Build result

```
Backend:
  pytest: 220 passed, 0 failed
  compileall: 0 errors
Flutter:
  flutter test: 77 passed, 0 failed
  flutter analyze: No issues found
  flutter build windows: built build\windows\x64\runner\Release\supermarket_pos.exe
```

---

## Phase 4 Manual UI Bug Fix — Flutter Localization Initialization (2026-09-22)

### Root cause

- `MaterialApp` / `MaterialApp.router` in `lib/main.dart` declared
  `supportedLocales: ar, fr, en` but never registered `localizationsDelegates`.
- Without delegates, only Flutter's English-only defaults were available, so on
  startup (locale `ar`) the app logged:
  - `This application's locale, ar, is not supported by all of its localization
    delegates`
  - `A MaterialLocalizations delegate that supports the ar locale was not found`
  - `A CupertinoLocalizations delegate that supports the ar locale was not found`
  - `No MaterialLocalizations found`
- Widgets that require `MaterialLocalizations` (buttons, dialogs, text fields,
  PIN pad, scaffold, navigation) failed to build, which cascaded into a bogus
  giant `RenderFlex overflowed by 99879 pixels` report during the error state.

### Fix (no Arabic removed, no Material localization bypassed)

`lib/main.dart`:

- Added `import 'package:flutter_localizations/flutter_localizations.dart';`
  (`flutter_localizations` was already declared in `pubspec.yaml`).
- Added shared configuration used by BOTH the checking/splash `MaterialApp`
  and the main `MaterialApp.router`:

  ```dart
  const List<Locale> appSupportedLocales = <Locale>[
    Locale('ar'),
    Locale('fr'),
    Locale('en'),
  ];

  const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  ```

  Both apps now pass `locale`, `supportedLocales: appSupportedLocales` and
  `localizationsDelegates: appLocalizationsDelegates`.
- Removed the manual `Directionality` wrapper from the `builder`. Flutter's
  `Localizations` widget now derives text direction from
  `GlobalWidgetsLocalizations`, so Arabic gets RTL and fr/en get LTR through
  the standard localization pipeline — no hardcoded direction, no positions
  hardcoded.

`lib/features/auth/login_screen.dart` (real overflow that remained after the
localization fix, reproduced by a widget test as `RenderFlex overflowed by 124
pixels on the bottom` in the PIN-pad state):

- Login body `Column` is now `mainAxisSize: MainAxisSize.min` inside a
  `SingleChildScrollView`, so the login/PIN layout scrolls instead of
  overflowing on short windows or scaled displays. Layout cause fixed — no
  other layout hacks added.

Preserved untouched:

- `lib/core/strings.dart` — all AR/FR/EN application strings and
  `AppStrings.t()` / `AppStrings.translate()` remain the app's translation
  source.
- Arabic RTL behavior (now provided by Flutter localization itself).
- Backend authentication, the public `GET /api/v1/auth/login-users` endpoint,
  and auth security. Phase 5 was not started.

### Regression tests

New `test/widget/localization_init_test.dart` (11 tests):

- Delegate configuration: Material/Widgets/Cupertino globals registered;
  supported locales are ar/fr/en; every global delegate `isSupported` for
  ar/fr/en.
- Arabic loads real translated Material strings (Arabic script asserted) and
  RTL `WidgetsLocalizations.textDirection`.
- **Arabic app startup** pumps the real `SupermarketPosApp` and asserts no
  exception (i.e. no `MaterialLocalizations` missing error), Material and
  Cupertino localizations resolve, `Directionality` is RTL, custom
  `AppStrings` text and user cards render; selecting a user builds the PIN pad
  and `TextField`.
- **French startup** and **English startup** pump the real app, assert LTR,
  localized Material strings, and custom French/English `AppStrings`.
- Custom translations remain available for ar/fr/en (`AppStrings.t`).
- Widgets that need `MaterialLocalizations` build under `ar`: MaterialApp,
  Scaffold, AppBar, buttons (incl. PIN pad keys), `AlertDialog` via
  `showDialog`, `TextField`s, `Card`, and drawer navigation
  (`DrawerButton` → `Drawer`).

### Verification (2026-09-22)

```
flutter test:          88 passed, 0 failed (77 existing + 11 new)
flutter analyze:       No issues found
flutter build windows: √ Built build\windows\x64\runner\Release\supermarket_pos.exe
flutter run -d windows: launched clean — no "MaterialLocalizations delegate ...
                        ar was not found", no "CupertinoLocalizations delegate
                        ... ar was not found", no "No MaterialLocalizations
                        found", no giant RenderFlex overflow; login screen
                        renders normally (Arabic RTL)
```

### Manual runtime-fix checklist

1. `cd new_app && flutter run -d windows`
2. Console must NOT show any of:
   - `MaterialLocalizations delegate ... ar was not found`
   - `CupertinoLocalizations delegate ... ar was not found`
   - `No MaterialLocalizations found`
   - `RenderFlex overflowed by ... pixels`
3. Login screen renders with Arabic text in RTL layout.
4. Select a user → PIN pad renders (scrolls if the window is short).
5. Switch language to French/English in settings → UI stays LTR with
   translated Material widgets (dialogs/tooltips/date pickers in the app's
   language) and `AppStrings` labels.

STOP — Phase 4 fix complete. Do NOT start Phase 5.

---

## Phase 4 Manual UI Bug Fix — Explicit Login Button (2026-09-22)

### Root cause

- The login screen had **no Login button**. `PinPad` only auto-submitted when the
  PIN reached `maxLength` (6 digits), via `_onKeyTap` → `onSubmit` at
  `text.length == maxLength`.
- A valid **4-digit PIN** (backend minimum) never triggered auto-submit, so
  `POST /api/v1/auth/login` was never sent and the user was stuck on the PIN pad.
- There was also no Enter-key path and no way to submit a 4- or 5-digit PIN.

### Fix (Flutter-only: UI, state, localization, tests — no backend/auth/JWT/RBAC changes)

`lib/core/constants.dart`:

- Added `AppConstants.minPinLength = 4` (mirrors backend `PIN_MIN_LENGTH`).

`lib/core/strings.dart`:

- New `login_submit` key in all three locale maps (ar/fr/en kept in sync):
  ar `تسجيل الدخول`, fr `Se connecter`, en `Login`.
  (`login_button` was left untouched — it is a different key.)

`lib/features/auth/pin_pad.dart`:

- New optional `onChanged` callback so the parent screen tracks the current PIN
  on every digit / backspace / clear (auto-submit at max length still works and
  now routes through the same guarded action).
- After each edit the pad re-requests focus on its display `TextField`, so
  keyboard focus does not drift onto digit keys.
- `TextField.onSubmitted` now forwards to `onSubmit` (IME "done" path).

`lib/features/auth/auth_provider.dart`:

- `login()` now sets `status: AuthStatus.authenticating` on start and
  `AuthStatus.error` on failure (these statuses existed in the enum and were
  already referenced by `PinPad.enabled` / `errorText` but were never set).
- `_extractError()` is now locale-aware (locale resolved lazily via
  `ref.read(localeProvider)` inside the provider — never `watch`, so locale
  changes do not recreate the notifier): connection → `network_error_retry`,
  backend message passthrough, 401 → `authentication_failed`,
  403 → `permission_denied`, 422 → `validation_error`, else → `api_error_retry`.

`lib/features/auth/login_screen.dart`:

- Tracks `_pin` state via `PinPad.onChanged`.
- Single guarded action `_tryLogin()` used by the **Login button**, PinPad
  auto-submit/`onSubmitted`, and the **Enter / keypad-Enter** key handler
  (`Focus` with key `login-key-handler`, autofocus). The guard returns
  immediately when already authenticating → duplicate submits are impossible.
- Explicit full-width **Login button** (key `login-submit-button`, width 280 to
  match the PIN pad): disabled when no user is selected, PIN empty/invalid
  (length < 4, > 6, or non-digit), or authentication is in progress; shows a
  spinner while authenticating; label from `login_submit`.
- Selecting a user / going back resets `_pin`. Layout stays
  `SingleChildScrollView` + `mainAxisSize.min` (overflow-safe, unchanged).

Route safety verified: `app_router.dart` redirect treats
`authenticating`/`error` the same as unauthenticated while already on `/login`
(no redirect loop, no premature redirect).

### Regression tests

New `test/widget/login_button_test.dart` (11 tests):

- Button appears only after user selection; disabled for empty and 3-digit
  PINs; enabled at exactly 4 digits; re-disabled by backspace below 4.
- Tapping the button sends exactly one `POST /api/v1/auth/login` with
  `user_id`, 4-digit `pin`, `device_name`.
- Double-tap while authenticating → exactly one POST (Completer-delayed stub).
- Enter key with a valid PIN triggers the login request.
- Successful login in the full `SupermarketPosApp` navigates to the Dashboard.
- Invalid PIN (HTTP 401 with no message) shows the localized authentication
  error, never the connection-error string.
- Button label asserted in ar / fr / en (`تسجيل الدخول`, `Se connecter`,
  `Login`) — one test per locale.
- PIN pad + button renders without overflow (incl. a short 800×500 window).

Also updated: `auth_localization_test` authKeys += `login_submit`;
`constants_test` += `minPinLength == 4`.

### Verification (2026-09-22)

```
flutter test:          100 passed, 0 failed (88 existing + 11 login-button + 1 constants)
flutter analyze:       No issues found
flutter build windows: √ Built build\windows\x64\runner\Release\supermarket_pos.exe
flutter run -d windows: launched clean — no MaterialLocalizations /
                        CupertinoLocalizations missing errors, no RenderFlex
                        overflow; login screen renders (Arabic RTL)
```

### Manual runtime-fix checklist

1. `cd new_app && flutter run -d windows`
2. Select a user → enter a **4-digit** PIN → the Login button enables.
3. Click Login (or press Enter) → `POST /api/v1/auth/login` → Dashboard opens.
4. Wrong PIN → localized authentication error (not "connection error").
5. Button is disabled during authentication and shows a spinner; double-click
   sends only one request.
6. Switch to French/English → button reads `Se connecter` / `Login`.
7. No overflow warnings when the window is short (login screen scrolls).

STOP — Phase 4 fix complete. Do NOT start Phase 5.

---

## Phase 4 Final Fix — Authenticated Shell, Logout, Audit user_id (2026-09-22)

Scope: only the three outstanding Phase 4 manual-verification items. No Phase 5
module was started. Argon2id, JWT, auth session model, RBAC, permission scopes,
the login-users endpoint, secure storage, the login flow, and DB architecture
were not changed (the only backend change is audit actor attribution below).

### 1. Minimal authenticated Flutter shell

`lib/router/app_router.dart` — `ScaffoldWithNav` is now the authenticated shell
(a `ConsumerWidget` driven by `state.matchedLocation`):

- **AppBar** with the localized app title (`app_name`).
- **Current user info** in the AppBar: user full name
  (`Key('shell-user-name')`) and localized role names
  (`Key('shell-user-roles')`), from `currentUserProvider`.
- **Logout** `TextButton.icon` (`Key('logout-button')`) — calls the existing
  `ref.read(authProvider.notifier).logout()` only; no manual `context.go`
  (the router redirect navigates to `/login` when auth state flips).
- **Body** = `NavigationRail` + `VerticalDivider` + `Expanded(child: child)`:
  - Dashboard destination always present (goes to `/`).
  - Users destination (goes to `/users`) **only when the current user has the
    `user_manage` permission** (`hasPermissionProvider('user_manage')`, same
    scope the backend requires for `GET /api/v1/users`).
  - Selected index derived from `location` (`/` → 0, `/users` → 1).

`lib/features/dashboard/dashboard_screen.dart` — own `Scaffold`/`AppBar`
removed (the shell provides them); content kept as
`Center(Text('Dashboard - Phase 2'))` (string preserved — asserted by
`login_button_test.dart`). Other Phase 2 screens keep their own Scaffold+AppBar
and are intentionally not in the rail (Phase 4 scope = Dashboard + gated
Users only).

No redirect loop: logout → `AuthState(unauthenticated)` → `routerProvider`
(watches `authProvider`) recreates the `GoRouter` → redirect forces `/login`
(`/login` is allowed when unauthenticated). The `GoRouterRefreshStream` no-op
is pre-existing and out of scope; recreation via `ref.watch(authProvider)` is
what re-evaluates redirects.

### 2. Logout wiring

`AuthNotifier.logout()` (unchanged) reads the token → `POST
/api/v1/auth/logout-token` (public path, no session-expiry handling) →
`clearAll()`/`clearToken()` → `_checkSetupNeeded()` → state
`unauthenticated`/`setupRequired` → router redirects to `/login`. The shell's
logout button is wired straight to this existing flow — verified by regression
tests below (logout-token POST called exactly once; LoginScreen visible after;
`routerProvider.go('/users')` after logout still shows LoginScreen, never
UsersScreen).

### 3. Backend audit `user_id` attribution

Root cause: `AuthService._audit()` never set `user_id` — every `audit_logs`
row had a NULL actor.

Fix in `backend/app/services/auth.py`:

- `_audit()` gained `user_id: uuid.UUID | None = None` and passes it to the
  `AuditLog` row. Docstring states the actor must be the authenticated user's
  UUID — **never** a PIN, PIN hash, JWT, or raw token.
- Actor passed at call sites where the user is in scope:
  - `setup_first_admin` → created admin's id
  - login success → logging-in user's id
  - failed login (`_handle_failed_login`) → attempted user's id
  - logout → `session.user_id`
  - reauth failure and success → user's id
- User-CRUD audits intentionally unchanged (API actor not in the service
  signature; would require API changes — out of Phase 4 final scope).
- No secret ever enters audit details/state: regression tests assert the PIN,
  raw token, and `pin_hash` never appear in login-audit rows.

### 4. Regression tests

Backend — `backend/tests/unit/test_auth.py`, new `TestLoginAuditUserId`
(3 tests): successful-login audit `user_id == admin_user.id` and no PIN in
details; failed-login audit `user_id == admin_user.id` and no attempted PIN in
details; no login-audit row (details/before/after/entity) contains the PIN,
the issued JWT, or `pin_hash`.

Flutter — new `test/widget/auth_shell_test.dart` (6 tests):

- Authenticated shell renders app title, user name, localized roles, Logout,
  NavigationRail, and the `Dashboard - Phase 2` placeholder (no exception).
- Logout button exists and calls the existing logout flow
  (`POST /api/v1/auth/logout-token` exactly once).
- Logout navigates back to the login screen (LoginScreen visible, dashboard
  gone).
- After logout, opening `/users` via the router still shows LoginScreen —
  UsersScreen never mounts, `GET /api/v1/users` never called (verifyNever).
- Admin sees the Users navigation item; tapping it loads Users
  (`GET /api/v1/users` called, UsersScreen visible).
- User without `user_manage` (cashier login payload) still gets the shell
  (name/roles/logout/dashboard) but does **not** see the Users nav and never
  calls `GET /api/v1/users`.

Stateful `ShellCredentialStorage` fake (token saved by login, read by logout,
cleared by `clearAll`) matches real credential-storage semantics; MockDio
stubs cover setup/check, login-users, login, logout-token, and `/api/v1/users`.

### 5. Verification (automated — 2026-09-22)

```
Backend:
  pytest: 223 passed, 0 failed   (220 existing + 3 new audit-user_id tests)
  compileall: 0 errors
Flutter:
  flutter test: 106 passed, 0 failed   (100 existing + 6 new shell tests)
  flutter analyze: No issues found
  flutter build windows: √ Built build\windows\x64\runner\Release\supermarket_pos.exe
```

### 6. Final manual verification checklist (MUST be done by a human)

Phase 4 is **NOT** claimed manually verified. The automated tests and builds
above are green, but the following checklist must be completed by a person
before Phase 4 is marked verified and only then may Phase 5 be considered:

1. Start backend: `cd backend && python -m uvicorn app.main:app --reload`
   (or the usual dev command).
2. Start Flutter: `cd new_app && flutter run -d windows`.
3. Log in as **Admin** (4-digit PIN) → authenticated shell opens on the
   Dashboard.
4. AppBar shows the app title and the **current Admin user's name + role**
   (e.g. `Admin` / `مدير` in Arabic locale).
5. Click **Logout** → returns to the login screen, no error snackbar, no
   redirect loop; console shows `POST /api/v1/auth/logout-token` succeeded.
6. **Re-login** as Admin → Dashboard opens again.
7. Open **Users** from the navigation rail → `GET /api/v1/users` loads and
   the user list renders.
8. (Optional but recommended) Inspect `audit_logs` after a login: the login
   row's `user_id` equals the Admin user's UUID (not NULL, not a PIN/hash).
9. Log out once more and confirm the app lands on `/login` cleanly.

Only after a human completes this checklist may the status line be changed to
"Phase 4 manually verified". Until then: **manual verification pending**.

STOP — Phase 4 final fix complete. Do NOT start Phase 5.

---

## Phase 4 Final Fix — Users Navigation Visibility (2026-09-22)

Manual verification reported: the authenticated shell showed Admin name/role,
Logout, and Dashboard — but **no Users navigation item**, so `/users` was
unreachable. Root cause and fix below. Phase 5 was not started.

### Root cause

- The shell gates the Users rail destination on
  `hasPermissionProvider('user_manage')` → `AuthUser.permissions`.
- `POST /api/v1/auth/login` returns `LoginResponse.user` = `UserResponse`,
  which has **no top-level `permissions` field** (only `GET /api/v1/auth/me`
  / `CurrentUserResponse` returns a flat `permissions: list[str]`).
- `AuthUser.fromJson` only read `json['permissions']` → always `[]` after
  login **and** after session restore (`verify-token` also returns
  `UserResponse`) → `hasPermission('user_manage')` was false for every role
  → the Users destination never rendered.
- The scopes **are** present in the login JSON, nested under
  `roles[].permissions[].scope` (`UserResponse.roles` → `RoleResponse` →
  `PermissionResponse.scope`; all relevant SQLAlchemy relationships are
  `lazy="selectin"`; the seeded `admin` role has every `PermissionScope`
  including `user_manage`).

### Fix (client only — no backend/authz change)

Two complementary client changes so the `user_manage` gate always has data:

1. **`lib/features/auth/auth_models.dart` — `AuthUser.fromJson`:**
   - still reads a top-level `permissions` list when present (e.g. `/auth/me`);
   - **also flattens nested `roles[].permissions[]`** (accepts both
     `{scope: ...}` objects and plain strings);
   - merges and de-duplicates both sources into `AuthUser.permissions`.

2. **`lib/features/auth/auth_provider.dart` — `_applyMePermissions()`:**
   after a successful `POST /api/v1/auth/login` (token already attached) and
   after `verify-token` session restore, call **`GET /api/v1/auth/me`**
   (`CurrentUserResponse` returns a flat `permissions: list[str]`) and merge
   those scopes into the stored `AuthUser`. The call is fully fail-open:
   any error keeps the scopes parsed from the login/verify payload, so
   login/restore never break if `/me` is unavailable.

Both paths feed the existing shell gate
(`hasPermissionProvider('user_manage')` → rail destination → `context.go('/users')`).
The `/users` route and backend `require_permission(user_manage)` on
`GET /api/v1/users` are unchanged — authorization is not weakened: non-admin
roles never receive `user_manage` (seed: admin = all scopes, manager =
operational, cashier = basic), so they still do not see the nav item, and
the backend still rejects them on the API.

> **Manual-verification note:** the first report of a missing Users item was
> against a build without the `fromJson` nested-scope parse (and possibly
> without the `/me` refresh). Always re-run the checklist on a **fresh
> `flutter run -d windows` / rebuilt executable** after pulling these fixes.

### Users screen verification (no duplicate screen created)

Existing `UsersScreen` (shell-provided Scaffold, own header) already
implements: authenticated `GET /api/v1/users` load, Create User dialog with
name/PIN/PIN-confirm + role dropdown (cashier/manager/admin), per-row
active/inactive `Switch` (`PUT /api/v1/users/{id}`), row menu → Delete →
confirmation dialog → `DELETE /api/v1/users/{id}`. Reached via the rail's
Users destination (`context.go('/users')`). No Products/POS/etc. work done.

### Regression tests added

Backend — `tests/unit/test_login_users.py` (+1, total 224):

- `test_login_response_user_roles_include_permission_scopes`: real
  `POST /api/v1/auth/login` as Admin → `user` has **no** top-level
  `permissions` key, and `roles[admin].permissions` includes
  `scope == "user_manage"` (locks the contract the shell depends on).
- Login audit `user_id` regression tests from the previous fix remain in
  `tests/unit/test_auth.py` (`TestLoginAuditUserId`, 3 tests): successful
  and failed login audit rows carry the user's UUID; no PIN/JWT/`pin_hash`
  ever appears in audit rows.

Flutter (+8, total 114):

- `auth_models_test.dart` (+2): nested `roles[].permissions[].scope`
  parsing (login shape); merge/dedup of top-level + nested permissions.
- `auth_shell_test.dart` (+2): admin login with **only** nested permissions
  still shows the Users nav and opens `/users` (real backend shape);
  **worst-case login payload with zero scopes + `GET /api/v1/auth/me`
  returning `user_manage` still shows Users nav** (locks the /me refresh);
  existing tests still cover: shell render, logout flow, no access after
  logout, cashier without `user_manage` does **not** see the nav.
- `test/widget/users_screen_test.dart` (+4, new file): full-app admin
  session → rail → `/users`:
  1. loads via authenticated `GET /api/v1/users` and lists users;
  2. Create User dialog opens with 3 fields + role dropdown; selecting
     `manager` updates the dropdown value;
  3. active/inactive `Switch` present for each listed user;
  4. row menu → Delete → confirmation dialog (text + Confirm button) →
     confirm issues `DELETE` and reloads the list.

### Verification (automated — 2026-09-22)

```
Backend:
  pytest: 224 passed, 0 failed   (220 original + 3 audit + 1 login-permission-scope)
  compileall: 0 errors
Flutter:
  flutter test: 114 passed, 0 failed (pre-fix baseline; final count after Manual Bug Fix 2 = 123)
  flutter analyze: No issues found
  flutter build windows: √ Built build\windows\x64\runner\Release\supermarket_pos.exe
```

### Manual verification checklist (MUST be done by a human on a FRESH build)

Phase 4 is **NOT** claimed manually verified. Stop any old app instance,
then complete these steps:

0. **Fresh build/run:** `cd new_app && flutter run -d windows` (do not use a
   stale Release exe from before the Users-nav fix).
1. Login as **Admin** (4-digit PIN) → Dashboard opens.
2. **Users navigation is visible** in the left rail (label `قائمة
   المستخدمين` / `User List`).
3. Open Users → user list loads (`GET /api/v1/users`).
4. Create User button opens the dialog; role dropdown selects
   cashier/manager/admin.
5. Active/inactive Switch visible on each user row.
6. Row menu → Delete → confirmation dialog appears (Cancel/Confirm).
7. Logout → login screen (no redirect loop).
8. Login again as Admin → Users remains accessible.
9. (Optional) Inspect `audit_logs`: login row `user_id` = Admin UUID,
   never NULL / PIN / hash / token.

Only after a human completes this checklist may the status line change to
"Phase 4 manually verified". Until then: **manual verification pending**.

STOP — Phase 4 complete. Do NOT start Phase 5.

---

## Phase 4 Manual Bug Fix 2 — Desktop Keyboard PIN Input + Wrong-PIN User Preservation (2026-09-22)

Scope: Flutter-only (`lib/features/auth/pin_pad.dart`,
`lib/features/auth/login_screen.dart`, `lib/router/app_router.dart`,
`test/widget/pin_keyboard_test.dart`). No backend/auth/JWT/RBAC change, no route
guard weakening, no session-expiry change, Phase 5 not started.

### BUG 1 — physical keyboard digits did not type into the PIN field

**Root cause:** the PIN display `TextField` inside `PinPad` was `readOnly: true`
(display-only), and the outer `Focus` wrapper (`login-key-handler`) only handled
Enter — digits, numpad digits, and Backspace were ignored.

**Fix (`pin_pad.dart`):**

- `TextField` is now editable (`readOnly: false`), `autofocus: true`,
  `key: Key('pin-input')`, `keyboardType: TextInputType.number`,
  `textInputAction: done`, `onChanged` wired, `textAlign: center` + RTL kept.
- New `AsciiPinInputFormatter` (applied before `LengthLimitingTextInputFormatter`):
  ASCII `0-9` only; maps Arabic-Indic `٠-٩` and Extended `۰-۹` to ASCII; drops
  everything else. Backend PIN must be ASCII — this keeps physical-keyboard
  input compatible on all locales.
- `PinPadState` is now **public** with `inputDigit` / `deleteLast` / `clearPin` /
  `requestPinFocus` / `hasPinFocus` — single authoritative PIN controller
  shared by the TextField, on-screen pad, and the outer Focus fallback.
- On-screen pad buttons route through the same `PinPadState` methods
  (no second PIN state).

**Fix (`login_screen.dart`):**

- `GlobalKey<PinPadState> _pinPadKey` on the `PinPad`.
- Outer `Focus` (`login-key-handler`, `autofocus: false`) key handler:
  Enter / numpad-Enter → guarded `_tryLogin()`; digits (main row + numpad) and
  Backspace / Delete → routed into `PinPadState`. The handler only receives
  keys the focused `TextField` did **not** consume (Focus propagation stops at
  handled events), so there is no double-insert on a real desktop.
- `_digitFromLogicalKey` uses non-`const` `final` maps (`LogicalKeyboardKey`
  has no primitive equality).

### BUG 2 — wrong PIN bounced the user back to user selection (selected user lost)

**Root cause:** `routerProvider` did `ref.watch(authProvider)` → every
`AuthState` change (including `AuthStatus.error` after a wrong PIN) created a
**new** `GoRouter` → `LoginScreen` remounted → local `_selectedUser` /
`_showPinPad` wiped → appeared to return to the user list. `GoRouterRefreshStream`
was a pre-existing no-op.

**Fix (`app_router.dart`):**

- One **stable** `GoRouter` instance.
- `ValueNotifier<int> authRefresh` bumped via `ref.listen(authProvider)` →
  `refreshListenable: authRefresh`; `redirect` reads live state with
  `ref.read(authProvider)`.
- `ref.onDispose` disposes the notifier + router. `GoRouterRefreshStream` removed.
- Route guards **unchanged** (unauthenticated → `/login`, setup → `/setup`,
  authenticated on login/setup → `/`). Login 401 never triggers session expiry
  (`/api/v1/auth/login` is in `publicAuthPaths`).

**Fix (`login_screen.dart` — wrong-PIN UX):**

- `ref.listen` detects `prev.status == authenticating && next.status == error &&
  errorMessage != null` → `postFrameCallback`: `clearPin()` + `requestPinFocus()`,
  **keeps** `errorMessage` in state so `PinPad.errorText` shows the localized
  `authentication_failed` (`فشل المصادقة`) — no immediate `clearError()`, no
  SnackBar for login failures. `selectedUser` is never cleared on failure.
- Back-to-user-list button still calls `clearError()` (intentional navigation).
- `_tryLogin()` guard (`authenticating` / `loginInProgress`) prevents duplicate
  POST when Enter and the Login button fire together.

### Regression tests — new `test/widget/pin_keyboard_test.dart` (9 tests)

BUG 1 (6):

1. Main-row digits `1234` type into the PIN field and enable Login.
2. Numpad digits `1234` type into the PIN field and enable Login.
3. Keyboard Backspace removes exactly one digit.
4. Keyboard Enter with a valid PIN sends exactly one `POST /api/v1/auth/login`.
5. Enter + Login button together still send only one POST (guarded).
6. On-screen PIN pad still works alongside keyboard input.

BUG 2 (3):

7. Failed login stays on Admin PIN screen: user kept, PIN cleared, localized
   error shown, no logout POST.
8. Retry after wrong PIN with correct PIN opens Dashboard.
9. Login failure does not navigate away from `/login` (LoginScreen still mounted).

Existing suites kept green (login_button 11, auth_shell, users_screen,
localization_init, etc.). On-screen digit taps use
`find.widgetWithText(ElevatedButton, digit)` (the editable field also exposes
the digit string once entered). 401 stub uses an empty body so the client falls
back to the localized `authentication_failed` string.

### Verification (automated — 2026-09-22)

```
Backend:
  pytest: 224 passed, 0 failed
  compileall: 0 errors
Flutter:
  flutter test: 123 passed, 0 failed   (114 existing + 9 new pin_keyboard tests)
  flutter analyze: No issues found
  flutter build windows: √ Built build\windows\x64\runner\Release\supermarket_pos.exe
```

### Manual verification checklist (MUST be done by a human on a FRESH build)

Phase 4 is **NOT** claimed manually verified for this fix. Stop any old app
instance, then:

0. **Fresh build/run:** `cd new_app && flutter run -d windows` (or rebuild the
   Release exe — do not use a stale binary from before this fix).
1. Select Admin → click/focus the PIN field → type `1234` on the **physical
   main-row keyboard** → digits appear (obscured), Login enables.
2. Same with the **numpad** digits; Backspace removes exactly one digit.
3. Press **Enter** with a valid PIN → one login request → Dashboard.
4. Wrong PIN (e.g. `9999`) → **stays on the same Admin PIN screen** (user card
   / selected user preserved — does NOT bounce to user selection), PIN field
   cleared, localized error `فشل المصادقة` shown, focus back on PIN field.
5. Re-enter the correct PIN → Dashboard opens (retry works).
6. On-screen pad digits still work mixed with physical keyboard.
7. No duplicate login requests when pressing Enter and clicking Login together.
8. Logout still works; login 401 still does **not** fire session-expiry.

Only after a human completes this checklist may the status line change to
"Phase 4 manually verified". Until then: **manual verification pending**.

STOP — Phase 4 Manual Bug Fix 2 complete. Do NOT start Phase 5.

---

## Summary

Phase 4 implements the complete authentication and authorization infrastructure for both backend and Flutter frontend. The system supports first-admin setup, PIN-based login, session management, user CRUD, role-based access control, and secure token storage.

## Backend (Complete)

### Security (`app/core/security.py`)
- **Argon2id PIN hashing** — time_cost=3, memory_cost=64MB, parallelism=4, hash_len=32, salt_len=16
- **JWT tokens** — HS256, claims: sub (user_id), sid (session_id), exp, iat
- **Token fingerprinting** — SHA-256 hash stored in DB, never raw JWT

### Auth Service (`app/services/auth.py`)
- `setup_first_admin()` — First-admin setup with PIN validation
- `is_setup_needed()` — Check if setup is required
- `login()` — PIN verification with lockout support
- `verify_token()` — JWT + session validation
- `logout()` — Session revocation
- `reauth()` — PIN reverification for sensitive actions
- `create_user()` / `update_user()` / `delete_user()` / `change_pin()` — Full user CRUD
- `_audit()` — Immutable audit logging for all operations
- `_handle_failed_login()` — Lockout after N failed attempts
- `_revoke_all_sessions()` — Session cleanup on deactivation

### API Endpoints (13 total)
- `POST /api/v1/auth/setup` — First-admin setup
- `GET /api/v1/auth/setup/check` — Check if setup needed
- `POST /api/v1/auth/login` — PIN-based login
- `POST /api/v1/auth/logout-token` — Session revocation
- `POST /api/v1/auth/reauth` — PIN reverification
- `GET /api/v1/auth/me` — Current user info
- `GET /api/v1/users` — List users (paginated, admin-only)
- `POST /api/v1/users` — Create user (admin-only)
- `GET /api/v1/users/roles` — List available roles
- `GET /api/v1/users/{id}` — Get user by ID
- `PUT /api/v1/users/{id}` — Update user (admin-only)
- `DELETE /api/v1/users/{id}` — Delete user (admin-only)
- `POST /api/v1/users/{id}/pin` — Change user PIN (admin-only)

### Authorization Dependencies (`app/api/dependencies.py`)
- `get_current_user` — Extracts + verifies JWT from Authorization header
- `require_permission(scope)` — Factory dependency requiring specific permission
- `require_any_permission(*scopes)` — Factory requiring any of multiple permissions

### Role/Permission Seeding (`app/core/seed.py`)
- 27 permission scopes seeded from `PermissionScope` enum
- 3 roles: admin (all permissions), manager (operational), cashier (POS basics)
- Idempotent — safe to run multiple times

### Database Migration 0004
- `auth_sessions` table (id, user_id, token_hash, device_name, expires_at, revoked_at, last_seen_at)
- User security fields (failed_login_attempts, locked_until, last_logout_at)

### Config
- `SESSION_LIFETIME_MINUTES = 480` (8 hours)
- `LOCKOUT_THRESHOLD = 5` attempts
- `LOCKOUT_DURATION_MINUTES = 15`

---

## Flutter (Complete)

### Auth State (`lib/features/auth/auth_provider.dart`)
- Riverpod `StateNotifierProvider` with `AuthNotifier` + `AuthState`
- States: checking, setupRequired, unauthenticated, authenticating, authenticated, sessionExpired, error
- Stores current user with id, fullName, roles, permissions
- `login()`, `logout()`, `reauth()`, `setupFirstAdmin()`
- 401 interceptor → auto session expiry
- Convenience providers: `currentUserProvider`, `isAuthenticatedProvider`, `isAdminProvider`

### Secure Token Storage (`lib/features/auth/credential_storage.dart`)
- Uses `flutter_secure_storage` (OS-backed: Keychain on macOS, libsecret on Linux, Credential Manager on Windows)
- Stores: token, userId, userName, roles, permissions
- `clearAll()` for logout
- `hasToken()` for startup session check

### API Client Auth (`lib/network/api_client.dart`)
- `setToken()` / `clearToken()` for Authorization header
- `_AuthInterceptor` handles 401 → triggers `onUnauthorized` callback
- No raw tokens in logs

### Route Guards (`lib/router/app_router.dart`)
- `redirect` callback checks `AuthStatus`
- Unauthenticated → `/login`
- Setup required → `/setup`
- Authenticated on login/setup → `/`
- `GoRouterRefreshStream` for auth state changes

### Setup Screen (`lib/features/auth/setup_screen.dart`)
- Step 1: Admin name input
- Step 2: PIN creation with PIN pad
- Step 3: PIN confirmation with mismatch detection
- Loading state, error handling, prevents double-submit

### Login Screen (`lib/features/auth/login_screen.dart`)
- Loads active users from the public `GET /api/v1/auth/login-users` endpoint (no JWT needed)
- User selection cards with avatar, name, roles
- PIN pad for authentication
- Error display for invalid PIN, locked/disabled accounts
- Back button to change user selection

### Reauth Screen (`lib/features/auth/reauth_screen.dart`)
- PIN input for sensitive action verification
- Success state with checkmark
- Error display for invalid PIN

### PIN Pad Widget (`lib/features/auth/pin_pad.dart`)
- 3x4 grid with digits 0-9, clear, backspace
- PIN display with obscure toggle
- Max length enforcement
- Auto-submit on max digits
- Keyboard accessible, RTL aware
- Error text display

### Permission Helpers (`lib/features/auth/permission_helpers.dart`)
- `hasPermissionProvider` — check single scope
- `hasAnyPermissionProvider` — check multiple scopes
- `AuthUserExtension.hasAnyPermission()` — extension method

### Users Management (`lib/features/users/users_screen.dart`)
- Admin-only access (checked via `isAdminProvider`)
- User list with avatar, name, roles, active toggle
- Create user dialog with name, PIN, role selection
- Delete user with confirmation
- Toggle active/inactive status

### Localization (`lib/core/strings.dart`)
- 50+ auth keys added in Arabic, French, English
- Covers: setup, login, logout, reauth, errors, user management, PIN pad
- Arabic RTL support via `Directionality` widget
- `AppStrings.t()` convenience method

### Auth Models (`lib/features/auth/auth_models.dart`)
- `AuthUser` — id, fullName, isActive, roles, permissions
- `LoginResult` — accessToken, expiresIn, user
- `SetupResult` — userId, name
- `UserListItem` — id, fullName, isActive, roleNames

### Main App (`lib/main.dart`)
- Shows loading screen while `AuthStatus.checking`
- Full app with router after auth initialization

---

## Flutter Tests (123 total after Manual Bug Fix 2; table below is the original Phase 4 baseline)

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `auth_models_test.dart` | 9 | AuthUser, LoginResult, SetupResult, UserListItem parsing |
| `auth_state_test.dart` | 7 | AuthState defaults, copyWith, flags, AuthStatus enum |
| `auth_localization_test.dart` | 7 | All auth keys exist in ar/fr/en, translations correct |
| `permission_helpers_test.dart` | 6 | hasAnyPermission, role detection, inactive user |
| `credential_storage_test.dart` | 2 | Instantiation, API method existence |
| `api_client_test.dart` | 17 | Instantiation, token set/clear, session-expiry matrix, error mapping, interceptor 401 behavior |
| `colors_test.dart` | 4 | Theme colors defined |
| `constants_test.dart` | 7 | App constants, translations |
| `locale_test.dart` | 6 | LocaleState, LocaleNotifier |
| `theme_test.dart` | 5 | ThemeState, ThemeNotifier |
| `theme_test.dart` (widget) | 3 | Theme rendering |
| `login_screen_test.dart` | 2 | Uses public login-users endpoint, never calls /api/v1/users; correct error display |

---

## Files Created/Modified

### Backend
| File | Action |
|------|--------|
| `app/core/security.py` | Rewritten: Argon2id + JWT |
| `app/core/config.py` | Added: SESSION_LIFETIME, LOCKOUT settings |
| `app/core/constants.py` | Added: Argon2id params |
| `app/core/seed.py` | **New**: Role/permission seeding |
| `app/api/dependencies.py` | Rewritten: Auth + permission deps |
| `app/api/v1/router.py` | Added: auth + users routers |
| `app/api/v1/auth.py` | **New**: Auth API endpoints |
| `app/api/v1/users.py` | **New**: User management endpoints |
| `app/schemas/auth.py` | **New**: Auth/user/role schemas |
| `app/services/auth.py` | **New**: AuthService |
| `app/models/user.py` | Added: AuthSession + security fields |
| `app/models/__init__.py` | Added: AuthSession export |
| `migrations/versions/..._0004_phase4_auth.py` | **New**: Auth migration |
| `tests/unit/test_auth.py` | **New**: 46 auth tests |

### Flutter
| File | Action |
|------|--------|
| `lib/features/auth/auth_models.dart` | **New**: Auth data models |
| `lib/features/auth/auth_provider.dart` | **New**: Auth state + Riverpod provider |
| `lib/features/auth/credential_storage.dart` | **New**: Secure token storage |
| `lib/features/auth/pin_pad.dart` | **New**: Shared PIN pad widget |
| `lib/features/auth/setup_screen.dart` | **New**: First-admin setup |
| `lib/features/auth/login_screen.dart` | **Rewritten**: User selection + PIN |
| `lib/features/auth/reauth_screen.dart` | **New**: Reauthentication |
| `lib/features/auth/permission_helpers.dart` | **New**: Permission providers |
| `lib/features/users/users_screen.dart` | **New**: User management |
| `lib/network/api_client.dart` | **Rewritten**: Auth interceptor + 401 |
| `lib/router/app_router.dart` | **Rewritten**: Route guards |
| `lib/main.dart` | **Updated**: Auth initialization |
| `lib/core/strings.dart` | **Updated**: 50+ auth strings |
| `pubspec.yaml` | Added: flutter_secure_storage |
| `test/unit/auth_models_test.dart` | **New**: 9 tests |
| `test/unit/auth_state_test.dart` | **New**: 7 tests |
| `test/unit/auth_localization_test.dart` | **New**: 7 tests |
| `test/unit/permission_helpers_test.dart` | **New**: 6 tests |
| `test/unit/credential_storage_test.dart` | **New**: 2 tests |

---

## Verification

```
Backend:
  compileall: 0 errors
  tests: 224 passed, 0 failed
  alembic: head = b2c3d4e5f6a7 (0004_phase4_auth)
  seed: 27 permissions, 3 roles, 57 role-permissions

Flutter:
  analyze: No issues found
  tests: 123 passed, 0 failed (114 existing + 9 Manual Bug Fix 2 tests)
  build windows: supermarket_pos.exe built
  pubspec: flutter_secure_storage added
```

## Manual Verification Steps

### Login flow (Phase 4 bug-fix)

1. Start backend: `cd backend && python -m uvicorn app.main:app --reload`
2. Start Flutter: `cd new_app && flutter run -d windows`
3. Login screen must load WITHOUT a "connection error" banner (it now calls the
   public `GET /api/v1/auth/login-users`).
4. Admin user is visible (along with other active users).
5. Select Admin → Enter PIN → Login succeeds → Dashboard opens.
6. Invalid PIN → authentication error (not "connection error").
7. Logout works → returns to the login screen (no 401 redirect-loop).
8. `GET /api/v1/users` remains protected:
   ```
   curl http://localhost:8000/api/v1/users
   # -> 401 {"error":{"code":"UNAUTHORIZED",...}}
   ```
9. After re-login, authenticated Admin can open the Users screen (`/users`) and
   lists users successfully.
10. **Shell check (final fix):** AppBar shows app title + current user
    name/roles; Logout returns to login without a redirect loop; Admin sees
    the Users navigation item and it opens `/users`; a non-admin (cashier)
    does not see the Users nav.
11. **Audit check (final fix):** after a login, `audit_logs.user_id` for the
    login row equals the Admin user's UUID (never NULL, never a PIN/hash/JWT).

> **Manual verification status:** automated checks are green; the checklist
> above (especially items 10–11 and the Final Manual Verification checklist in
> the Final Fix sections) must still be executed by a human before Phase 4 can
> be called manually verified. The Users-nav visibility bug reported in manual
> testing is fixed (see "Users Navigation Visibility") — re-run the checklist
> with a fresh build. Do NOT start Phase 5 before that.

### Full Phase 4 manual matrix

1. First-admin setup screen appears (GET /api/v1/auth/setup/check returns setup_needed=true)
2. Enter admin name → Create PIN → Confirm PIN → Account created
3. Login screen shows admin user
4. Select admin → Enter PIN → Login successful → Dashboard
5. Navigate to Users → Create cashier user → Logout
6. Login as cashier → Verify admin-only UI elements are restricted
7. As admin → Disable cashier → Cashier session becomes invalid
8. Test invalid PIN → Authentication error message displayed
9. Test locked account (5 failed attempts) → Account temporarily locked message
10. Restart Flutter → Session restored from secure storage
11. Test Arabic, French, English authentication UI → All strings translated correctly
12. Test RTL layout in Arabic mode
