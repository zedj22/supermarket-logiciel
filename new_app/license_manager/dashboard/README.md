# KlickPOS License Manager — Web Dashboard

Private administrator console for the KlickPOS **lifetime license** service. It
is a Next.js (App Router) app that talks to the Python License API in
`../` and never touches Firestore, signing keys or activation-code generation
itself.

- **Framework**: Next.js 15 App Router, TypeScript, Tailwind CSS
- **Auth**: Firebase Authentication (web SDK, **Google** sign-in only)
- **Data**: the existing FastAPI service — `new_app/license_manager`
- **Tests**: Vitest + Testing Library (jsdom)

---

## 1. Quick start (real Firebase Authentication)

Sign-in is **Google only** and always uses the real Firebase project. There is
no development sign-in fallback in the dashboard.

1. Firebase Console → **Authentication** → Sign-in method → **Google** enabled.
2. Authentication → Settings → **Authorized domains**: `localhost` (plus the
   deployed host) is present.
3. Project settings → Your apps → Web app → copy the config values into
   `NEXT_PUBLIC_FIREBASE_*` (see §2).
4. Put the administrator's **Firebase UID** (or Google email) in
   `LICENSE_API_ADMIN_UIDS` / `LICENSE_API_ADMIN_EMAILS` on the License API, and
   set `LICENSE_API_FIREBASE_PROJECT_ID=klickpos-license-manager` there.
   That allowlist, not the client route guard, is what authorises access.

```bash
# terminal 1 — License API (real token verification needs Google credentials)
cd new_app/license_manager
./.venv/Scripts/python.exe -m pip install -r requirements.txt      # once
export LICENSE_API_ENV=development
export LICENSE_API_FIREBASE_PROJECT_ID=klickpos-license-manager
export LICENSE_API_ADMIN_UIDS=<administrator uid>       # and/or ADMIN_EMAILS
export LICENSE_API_DEV_SIGNING_KEY_ID=dev-local
export LICENSE_API_VERIFICATION_KEYS_FILE=/tmp/licapi-dev/keys.json
export LICENSE_API_DEV_SIGNING_SEED_B64=...             # base64 32-byte seed
export LICENSE_API_DEV_CODE_ENC_KEY_B64=...             # base64 32-byte key
./.venv/Scripts/python.exe -m uvicorn service.api:app --port 8000
```

Token verification uses `firebase_admin` with Application Default Credentials
(`gcloud auth application-default login`, or `GOOGLE_APPLICATION_CREDENTIALS`
pointing at a service-account key with Firebase Auth access). Without them,
`/v1` answers `401`/`503` — it never falls back to trusting the token.

```bash
# terminal 2 — dashboard
cd new_app/license_manager/dashboard
cp .env.example .env.local
# fill NEXT_PUBLIC_FIREBASE_API_KEY / _AUTH_DOMAIN / _PROJECT_ID / _APP_ID
# and leave NEXT_PUBLIC_API_BASE_URL at the API origin
npm install
npm run dev            # http://localhost:3000
```

The sign-in page offers **“Sign in with Google”**, which opens the Google
account chooser (`prompt=select_account`). After sign-in the dashboard reads the
Firebase ID token (`user.getIdToken()`) and sends it as
`Authorization: Bearer <token>` on every `/api/license/*` call; the API verifies
it with `check_revoked=True` and then applies its allowlist. Sign-out calls
Firebase `signOut`, so a revoked/removed session stops working immediately.

---

## 2. Environment variables

| Variable | Required | Meaning |
| --- | --- | --- |
| `NEXT_PUBLIC_API_BASE_URL` | yes | License API origin, e.g. `http://127.0.0.1:8000` — the **proxy target**, read by the Route Handler at request time (no rebuild needed) |
| `LICENSE_DASHBOARD_API_AUDIENCE` | on Cloud Run | The API's Cloud Run URL; the audience this server mints its OIDC identity token for. Server-only (never `NEXT_PUBLIC_`). Empty = no service identity, correct only for a local run |
| `NEXT_PUBLIC_FIREBASE_API_KEY` | real deployments | Firebase web API key |
| `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | real deployments | `<project>.firebaseapp.com` |
| `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | real deployments | Firebase project id |
| `NEXT_PUBLIC_FIREBASE_APP_ID` | yes | Web app id |
| `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | no | sender id from the same config panel |
| `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | no | storage bucket from the same config panel |
| `NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST` | no | e.g. `127.0.0.1:9099` (never in production) |
| `NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY` | once App Check is enforced | reCAPTCHA Enterprise site key; the client mints an App Check token and sends `X-Firebase-AppCheck` |
| `NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN` | local only | debug token registered in the Console, or `true`; never in staging/production |

All of these are **public** (they are bundled into the browser). Signing seeds,
AES keys, service-account JSON and Secret Manager values must never appear here.

---

## 3. Pages

| Route | What it does |
| --- | --- |
| `/login` | Google popup sign-in (the only administrator provider) |
| `/overview` | Customer / device / active / revoked counts, recent licenses, recent activity |
| `/issue` | Parse an `SMPr1` code → review fingerprint → issue one lifetime license → copy code |
| `/devices` | Search devices, current license, full license history |
| `/licenses` | Search/filter licenses, detail view, audited code retrieval, reissue, revoke |
| `/customers` | Search customers, devices and licenses per customer |
| `/audit` | Audit trail with action, administrator, license, hardware hash, details |

Destructive actions (reissue, revoke, revealing a code) require a reason and an
explicit confirmation, and the revocation dialog states plainly that an offline
lifetime license cannot be deactivated remotely.

---

## 4. API endpoints used

| Method | Path | Where |
| --- | --- | --- |
| GET | `/healthz` | sign-in / connectivity |
| POST | `/v1/requests/parse` | Issue license |
| POST | `/v1/licenses` | Issue license |
| GET | `/v1/devices/{hw_hash}` | Device detail |
| GET | `/v1/devices` | Devices list *(added in Phase 3)* |
| GET | `/v1/licenses` | Licenses list *(added in Phase 3)* |
| GET | `/v1/licenses/{license_id}/code` | Audited code reveal |
| POST | `/v1/licenses/{license_id}/reissue` | Reissue |
| POST | `/v1/licenses/{license_id}/revoke` | Revoke |
| GET | `/v1/customers` | Customers list *(added in Phase 3)* |
| GET | `/v1/customers/{customer_id}` | Customer detail *(added in Phase 3)* |
| GET | `/v1/audit` | Audit log *(added in Phase 3)* |
| GET | `/v1/overview` | Overview totals *(added in Phase 3)* |

The browser always calls the same-origin path `/api/license/*`, which the Route
Handler `app/api/license/[...path]/route.ts` proxies to
`NEXT_PUBLIC_API_BASE_URL`. Direct cross-origin calls are not used because the
License API deliberately has no CORS middleware; the proxy forwards the
`Authorization` header unchanged, so the token gates still apply exactly as
before.

Since Phase 6 the proxy also attaches the dashboard's own **Cloud Run service
identity** (`lib/server-identity.ts` → `x-klickpos-service-authorization`, plus
`x-serverless-authorization` for Cloud Run's IAM edge). That token is minted
server-side from the metadata server and never reaches a browser. It was a
`next.config.ts` rewrite until Phase 6; a rewrite can only forward what the
browser sent, which is not enough for a second credential.

The read-only list/aggregate endpoints were added to the API in this phase
because the dashboard has to list and search records and show totals, and the
original API could only fetch one device by its exact fingerprint. They never
return an activation code, and they are administrator-only through the same
three gates (ID token, allowlist, optional App Check).

---

## 5. Security properties

- The browser holds a Firebase **ID token** only; no service account, signing
  key or AES key is ever shipped to it.
- Activation codes are fetched one at a time from the audited endpoint, are
  shown in a dialog, and are never cached (`cache: "no-store"`), logged or
  persisted.
- Route protection here is convenience: the API verifies the token and its own
  allowlist on every request, so bypassing a client route still yields 401/403.
- The API sends `Cache-Control: no-store` on every `/v1` response.

---

## 6. Scripts

```bash
npm run dev         # dev server (http://localhost:3000)
npm run build       # production build
npm start           # serve the production build
npm run lint        # eslint
npm run typecheck   # tsc --noEmit
npm test            # vitest run
```

Tests cover: authentication UI, protected routes, the API client (tokens,
status codes, no-store, no logging of codes), request parsing, issuance,
duplicate devices, audited code retrieval, reissue and revocation confirmation,
search/empty/error states and responsive navigation.

---

## 7. Known limitations

- Device, license, customer and audit searches filter the most recent 500
  records returned by the API; Firestore has no substring search.
- Revocation is a records marker — it cannot stop a running offline installation.
- A production deployment needs the API deployed with real Firebase credentials;
  that is out of scope here and was not performed.
