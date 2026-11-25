# KlickPOS License Manager — License API (Phase 2)

Private, administrator-only backend that issues **KlickPOS lifetime activation
codes**. It reuses the customer application's own licensing contract, so a code
it produces activates an existing KlickPOS install with **no change to the
desktop activation protocol**.

* Signing, canonical JSON, `SMPr1` parsing and `SMP1` encoding all come from
  `new_app/backend/app/licensing/activation_code.py` and
  `new_app/backend/tools/license_generator/` — imported, never re-implemented.
* The customer's verifier (`app/licensing/activation_code.py::verify_activation_code`)
  checks the codes against the packaged `verification_keys.json` exactly as it
  does today.
* One license type only: **lifetime**. There is no expiry, no subscription, no
  trial issued here, and no `expires_at` field anywhere in the signed payload.

Run the tests:

```bash
cd new_app/license_manager
../backend/.venv/Scripts/python.exe -m pytest -q          # Windows
```

Run the service (needs the cloud configuration in §7):

```bash
uvicorn service.api:app --host 0.0.0.0 --port 8080
```

---

## 1. Endpoints

All routes are administrator-only (Firebase ID token + server-side allowlist,
plus App Check when required). Errors share one envelope:

```json
{"error": {"code": "snake_case_code", "message": "…", "details": {}}}
```

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/healthz` | Liveness only (public, no data) |
| `POST` | `/v1/requests/parse` | Strictly parse an `SMPr1` request with the existing generator parser; return `hw_hash`, `install_id`, the display code and any existing license |
| `POST` | `/v1/licenses` | Create the single lifetime license for a fingerprint (or return the existing one). Signs with the existing contract, self-verifies against the packaged keys, stores transactionally |
| `GET` | `/v1/devices/{hw_hash}` | Existing device, its license history and notices |
| `GET` | `/v1/licenses/{license_id}/code` | The original activation code (audited, `Cache-Control: no-store`) |
| `POST` | `/v1/licenses/{license_id}/reissue` | Replacement license; the original record and its history are preserved (`confirm: true` required) |
| `POST` | `/v1/licenses/{license_id}/revoke` | Records administrative revocation and states that an offline lifetime license cannot be deactivated remotely |

### Request/response shapes

```jsonc
// POST /v1/requests/parse
{"request_code": "SMPr1.…"}
// -> {"hw_hash": "…64 hex…", "install_id": "…", "requested_at": "…",
//     "fingerprint_display_code": "ABCD-EFGH-…", "existing_license": null|{…},
//     "device": null|{…}}

// POST /v1/licenses   (exactly one of request_code / hw_hash)
{"request_code": "SMPr1.…", "features": ["pos"], "customer": {"name": "…"}}
// -> 201 {"created": true,  "license": {…, "activation_code": "SMP1.…"}, "notice": null}
// -> 200 {"created": false, "license": {…original code…}, "notice": "…"}

// POST /v1/licenses/{id}/reissue
{"reason": "mainboard replaced", "confirm": true}
// -> {"previous": {…status: "superseded"…}, "license": {…new code…}, "notice": "…"}

// POST /v1/licenses/{id}/revoke
{"reason": "refund issued"}
// -> {"license": {…status: "revoked"…}, "notice": "…cannot remotely deactivate…"}
```

Status codes: `200/201` ok, `401` no/invalid token (or App Check), `403` not on
the allowlist, `404` unknown device/license, `409` illegal state transition,
`413` body too large, `422` invalid input, `429` rate limited, `503` store or
signing material unavailable, `500` unexpected (never carries internals).

---

## 2. Firestore schema

```
customers/{customer_id}
devices/{hw_hash}            <- document id IS the fingerprint digest
licenses/{license_id}
audit_log/{event_id}
```

**`devices/{hw_hash}`** — the uniqueness key that makes duplicate prevention
atomic.

| field | meaning |
| --- | --- |
| `hw_hash` | 64-hex SHA-256 hardware digest (mirrors the document id) |
| `install_id` | installation id from the `SMPr1` request (provenance) |
| `request_code` | the original unsigned `SMPr1` string |
| `fingerprint_display_code` | grouped Base32 form for support conversations |
| `customer_id` | owning customer, if any |
| `current_license_id` | the active license document |
| `first_seen_at`, `last_seen_at` | timestamps |

**`licenses/{license_id}`** — immutable except for `status`, `superseded_by`,
`revoked_at`, `revoked_reason`.

| field | meaning |
| --- | --- |
| `license_id`, `hw_hash`, `customer_id`, `install_id`, `request_code` | identity/provenance |
| `kind` | always `"lifetime"` |
| `key_id` | the signing key id inside the signed payload |
| `issued_at` | the signed timestamp (second precision, UTC) |
| `features` | signed feature grants (`["pos"]` by default) |
| `activation_code_sealed` | **AES-256-GCM envelope** (`gcm1:<nonce>:<ct+tag>`, AAD = license id) |
| `status` | `active` \| `superseded` \| `revoked` |
| `created_at`, `created_by` | who issued it, when |
| `reissued_from`, `superseded_by` | the reissue chain |
| `revoked_at`, `revoked_reason` | administrative revocation |

**`customers/{customer_id}`** — `customer_id`, `name`, `email`, `phone`,
`notes`, `updated_at`, `updated_by`.

**`audit_log/{event_id}`** — `at`, `action`, `actor_uid`, `actor_email`,
`license_id`, `hw_hash`, `client_ip`, `details`. Actions:
`license_request_parsed`, `license_issued`, `license_existing_returned`,
`device_viewed`, `activation_code_viewed`, `license_superseded`,
`license_reissued`, `license_reissue_reason`, `license_revoked`.

Never stored: raw machine identifiers (the digest is one-way and is all this
service ever receives), private key material, plaintext activation codes.

---

## 3. Authentication and authorization

1. `Authorization: Bearer <Firebase ID token>` →
   `firebase_admin.auth.verify_id_token(token, check_revoked=True)`. Every
   failure is the same `401 unauthorized`; provider text is never echoed.
   The verified claims must also be minted for **this** project: `aud` must
   equal `LICENSE_API_FIREBASE_PROJECT_ID` and `iss` must equal
   `https://securetoken.google.com/<project>`, so a token from another Firebase
   project is refused even if the SDK's default app was configured wrongly.
2. **Server-side allowlist**: `LICENSE_API_ADMIN_UIDS` (comma-separated uids)
   and/or `LICENSE_API_ADMIN_EMAILS` (case-insensitive). An **empty allowlist
   denies everyone** — a misconfigured deploy is closed, not open. This list
   lives only in the service environment, never in the browser or Firestore.
3. **App Check** (optional, recommended): with
   `LICENSE_API_REQUIRE_APP_CHECK=1` a verified `X-Firebase-AppCheck` token is
   also required, so a stolen ID token is not sufficient on its own.

The browser never reads Firestore and never sees key material: every activation
code it displays came from an audited call to this API, and Firestore rules
should deny all client access (Admin SDK only).

### 3a. Phase 5.1 — real Firebase Authentication (Google only)

Firebase project: **`klickpos-license-manager`**. The dashboard signs
administrators in with the Google popup and nothing else; the development token
path was removed from the dashboard.

**Dashboard (`dashboard/.env.local`, public values):**

```bash
NEXT_PUBLIC_FIREBASE_API_KEY=<from Firebase Console → Project settings → Web app>
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=klickpos-license-manager.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=klickpos-license-manager
NEXT_PUBLIC_FIREBASE_APP_ID=<from the same config panel>
# Server-only: the proxy reads it per request (no NEXT_PUBLIC_ prefix).
LICENSE_API_BASE_URL=http://127.0.0.1:8000
```

`NEXT_PUBLIC_DEV_AUTH_UID` no longer exists on the dashboard side. These values
are public configuration, not secrets; never put key material here.

**Firebase Console:**

1. Authentication → Sign-in method → **Google** enabled (only provider).
2. Authentication → Settings → **Authorized domains**: `localhost`,
   `klickpos-license-manager.firebaseapp.com`, `klickpos-license-manager.web.app`.
3. Project settings → Your apps → the registered **Web app** supplies the config
   above.

**License API:**

```bash
LICENSE_API_ENV=development                 # or production
LICENSE_API_FIREBASE_PROJECT_ID=klickpos-license-manager
LICENSE_API_ADMIN_UIDS=<administrator Firebase UID>
# and/or
LICENSE_API_ADMIN_EMAILS=<administrator Google email>
```

The allowlist stays mandatory and fail-closed: a valid Google token from an
account that is not listed gets `403 admin_not_allowlisted`, and an empty
allowlist denies everyone.

**Credentials for verification.** `verify_id_token(check_revoked=True)` needs
google-auth credentials, because the revocation check reads the user record:

```bash
# either Application Default Credentials from your own Google account
gcloud auth application-default login
# or a service-account key kept outside the repo
export GOOGLE_APPLICATION_CREDENTIALS=/path/outside/repo/service-account.json
```

Without them the API answers `401`/`503` — it never skips verification. The
emulator escape hatch (`FIREBASE_AUTH_EMULATOR_HOST`) is refused outright when
`LICENSE_API_ENV=production`, and it must not be set for the real project.

**Is the credential good enough?** `scripts/check_live_firebase.py` answers that
without writing anything: it resolves ADC, forces a real token refresh, reads
Firestore through `FirestoreLicenseRepository` (list + counts only), performs
the Admin SDK user lookup that `check_revoked=True` uses, and prints which
allowlist entries are configured. Google's own 403 text (which names the
missing permission or API) is the diagnosis when something is not granted.
The ADC identity needs, at minimum:

| Capability | Permission | Minimum role |
|---|---|---|
| Read/write license documents | `datastore.entities.*` | `roles/datastore.user` |
| Service usage (quota) for calls without a quota project | `serviceusage.services.use` | `roles/serviceusage.serviceUsageConsumer` |
| Revocation check (`check_revoked=True`) / user lookup | `firebaseauth.users.get` | `roles/firebaseauth.viewer` |

Token signature verification itself needs no IAM permission: the SDK fetches
google's public certificates. Only the revocation lookup touches IAM.

### 3b. Phase 6 — Google Cloud Run readiness (prepared, not deployed)

Two services: a **private** FastAPI License API and a **public** Next.js
dashboard. The full design, IAM matrix, Secret Manager procedure, staging
checklist, Docker instructions and production checklist live in
[`docs/cloud-run.md`](docs/cloud-run.md); the security findings live in
[`docs/security-review.md`](docs/security-review.md).

What changed in the code:

* the dashboard proxy is now a Route Handler
  (`dashboard/app/api/license/[...path]/route.ts`) instead of a `next.config.ts`
  rewrite, because the API now requires a **service** credential that only the
  server can mint;
* `dashboard/lib/server-identity.ts` obtains that Google OIDC token from the
  metadata server (audience = the API's Cloud Run URL) and caches it;
* `service/cloud_run.py` verifies the same token in-process (audience + caller
  service account), **before** the Firebase token is checked;
* containers, ignore files and env templates: `Dockerfile`,
  `Dockerfile.dockerignore`, `dashboard/Dockerfile`, `.dockerignore`,
  `deploy/*.env.template`; the single-container Render image is
  `Dockerfile.render` + `Dockerfile.render.dockerignore`, with the supervisor
  `deploy/render/entrypoint.sh` (see `docs/render-staging.md` §10).

New API settings (all off unless set, so local runs are unchanged):

```bash
LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER=1
LICENSE_API_CLOUD_RUN_AUDIENCE=https://<api-service>-<hash>-<region>.a.run.app
LICENSE_API_CLOUD_RUN_INVOKERS=<dashboard-runtime-sa>@<project>.iam.gserviceaccount.com
```

Dashboard: `LICENSE_DASHBOARD_API_AUDIENCE` (server-only, same URL). Empty =
no service identity, which is correct for a local run and refused for Cloud Run
by the API's gate.

Requests carry two credentials, which are never interchangeable:

| Header | Credential | Verified by |
|---|---|---|
| `Authorization` | administrator's Firebase ID token | `firebase_admin`, revocation + allowlist |
| `x-klickpos-service-authorization` | Google OIDC token of the dashboard's runtime SA | `service/cloud_run.py` (audience + SA e-mail) |
| `x-serverless-authorization` | the same OIDC token | Cloud Run IAM at the edge (stripped before the container) |

A browser cannot supply either service header: the proxy forwards only an
allow-listed set of request headers and mints the token itself.


---

## 4. Signing-key handling

* Production seed: Google Cloud Secret Manager
  (`LICENSE_API_SIGNING_SECRET`), payload
  `{"key_id": "…", "seed_b64": "<32-byte Ed25519 seed>"}` — strict: exactly
  those two fields.
* Fetched **once, on first issuance**, into process memory
  (`container.load_issuer_factory` → `signing.lazy_key_provider`). Never
  written to disk, never logged, never placed in an environment variable in
  production, never in Firestore, never in the browser.
* `Settings` refuses to start in production if the development seed variables
  are set, or if the project id / secret names are missing.
* **Never generates keys.** `keygen` remains an offline, owner-side operation
  (`tools/license_generator`).
* Fail-closed checks before any code is returned:
  1. the `key_id` must exist in the **packaged customer verification keys**, or
     the API answers `503 signing_key_not_published` and stores nothing;
  2. the finished code is re-verified with `verify_activation_code` against
     those packaged keys, and again against the signer's own public half.
* Rotation = a new `key_id` published into the customer package
  (`provision-release`); old ids stay so previously issued codes keep working.
* Test and production keys stay separate: the suite generates a throwaway
  Ed25519 pair per test; `test-2026` in the repo is test material and is never
  used here.

---

## 5. Duplicate prevention

`licenses` are keyed by `license_id`, but uniqueness is enforced on
`devices/{hw_hash}` inside **one Firestore transaction**
(`firestore_repository.py::_create_or_get`):

1. read `devices/{hw_hash}` in the transaction;
2. if it already has a `current_license_id`, read that license, write one
   `license_existing_returned` audit entry and return it — **nothing is signed**;
3. otherwise sign once (`build()` runs inside the transaction) and write the
   license, the device and the `license_issued` audit entry in the same commit.

Concurrent requests for one fingerprint therefore serialise on that document:
the second transaction observes the first commit and returns the existing
license. `tests/test_duplicates.py` proves this with 8 threads (memory
repository) and 6 concurrent HTTP requests asserting the issuer was called
**once**.

---

## 6. Revocation semantics (read this before using the endpoint)

A KlickPOS lifetime license is signed material stored on the customer's own
machine (`license.state`) and verified offline. This API has no channel into
that machine, so:

* revocation **records** who revoked what and why, and marks the record
  `revoked`;
* it **cannot** make the customer's POS stop working;
* the only practical lever is `reissue` (send a replacement code and have the
  customer activate it) — the device keeps whichever code it last activated;
* retiring a whole `key_id` invalidates every license signed with it, so it is
  not a per-customer tool.

Every revocation response says this in `notice`, and `GET …/code` adds a
warning when the license is revoked.

---

## 7. Configuration and missing cloud setup

Environment variables (no secret values):

| variable | required | meaning |
| --- | --- | --- |
| `LICENSE_API_ENV` | yes | `development` / `testing` / `production` |
| `LICENSE_API_FIREBASE_PROJECT_ID` | in production | Firebase/GCP project (real tokens must be minted for it — `aud`/`iss` are pinned) |
| `LICENSE_API_ADMIN_UIDS` | yes (one of the two) | allowlisted uids |
| `LICENSE_API_ADMIN_EMAILS` | yes (one of the two) | allowlisted emails |
| `LICENSE_API_REQUIRE_APP_CHECK` | no | `1` to require App Check |
| `LICENSE_API_FIRESTORE_DATABASE` | no | named database; leave **empty** for `(default)` |
| `LICENSE_API_SECRET_SOURCE` | no | `secretmanager` (default, Cloud Run) or `file` (read-only mounted files; Render Free / Firebase Spark, which have no Secret Manager) |
| `LICENSE_API_SECRET_DIR` | with `file` | directory holding one file per secret name; mounted at runtime, never in an image |
| `LICENSE_API_SIGNING_SECRET` | in production | secret name for the seed (a Secret Manager name, or a file name under `LICENSE_API_SECRET_DIR`) |
| `LICENSE_API_SIGNING_SECRET_VERSION` | no | defaults to `latest` |
| `LICENSE_API_CODE_ENC_SECRET` | in production | Secret Manager secret for the AES key |
| `LICENSE_API_CODE_ENC_SECRET_VERSION` | no | defaults to `latest` |
| `LICENSE_API_VERIFICATION_KEYS_FILE` | no | defaults to the packaged `app/licensing/verification_keys.json`; the staging deployment points it at `deploy/staging/verification_keys.staging.json` |
| `LICENSE_API_REQUIRE_STAGING_KEYS` | no | `1` refuses to start when the keys file resolves to a known production key file, and validates the staging file at startup — staging isolation, off by default |
| `LICENSE_API_STAGING_KEY_ID` | no | key id the staging file must publish when the flag above is on (default `stg-2026-11`); ignored by production |
| `LICENSE_API_REQUIRE_SIGNING_KEY_MATCH` | no | `1` derives the Ed25519 public key from the configured signing seed at startup and requires it to match the key published for `LICENSE_API_STAGING_KEY_ID` (constant-time); fails closed on a missing, malformed or mismatched seed — staging-only, off by default |
| `LICENSE_API_DEV_SIGNING_KEY_ID` | no | dev-only key id (default `dev-local`) |
| `LICENSE_API_RATE_LIMIT_PER_MINUTE` | no | reads per administrator (default 60) |
| `LICENSE_API_ISSUE_LIMIT_PER_MINUTE` | no | issuances per administrator (default 20) |
| `LICENSE_API_MAX_BODY_BYTES` | no | request body cap (default 8192) |
| `LICENSE_API_TRUST_PROXY` | no | `1` to record the audit client address from `X-Forwarded-For` — set only behind a trusted proxy |

With `LICENSE_API_SECRET_SOURCE=file`, `service/secrets.py::FileSecretFetcher`
reads `<LICENSE_API_SECRET_DIR>/<name>` and refuses anything that is not a
plain regular file directly inside that directory: path separators, `..`, drive
letters, absolute paths and symlinks are rejected before opening, and missing,
empty, unreadable or non-UTF-8 files fail closed with `503 signing_unavailable`.
There is **no** fallback to environment values in either direction, and the
`*_SECRET_VERSION` variables are ignored by the file source. Secret Manager
remains the default, so production on Cloud Run needs no change. See
`docs/render-staging.md` for the staging layout and the required dashboard build
arguments.

Development-only (refused when `LICENSE_API_ENV=production`):
`LICENSE_API_DEV_SIGNING_SEED_B64`, `LICENSE_API_DEV_CODE_ENC_KEY_B64`, and
`LICENSE_API_DEV_AUTH_UID` — the last one accepts `Authorization: Bearer
dev:<uid>` for that uid (which still has to be on the administrator allowlist)
so the API itself can be exercised with `curl` or the test suite without a
Firebase project. The **dashboard never sends such a token** since Phase 5.1
removed its development sign-in; leave `LICENSE_API_DEV_AUTH_UID` unset for any
production-like run.

The audit trail records the caller's address only when
`LICENSE_API_TRUST_PROXY=1`. Without it, a request that carries
`X-Forwarded-For` is logged with **no** address at all: uvicorn's
`--proxy-headers` is on by default and trusts loopback, so it may already have
rewritten `request.client` from that very header — neither value is evidence.
Set the flag only behind a proxy you control that overwrites the header, and
run the service with `--forwarded-allow-ips=<that proxy>`.

### Dashboard read endpoints (Phase 3)

The web dashboard has to list and search records and show totals, which the
original API could not do (it only fetched one device by its exact digest).
Five read-only, administrator-only endpoints were added; none of them ever
returns an activation code:

| Route | Returns |
| --- | --- |
| `GET /v1/overview` | counts + 8 recent licenses + 8 recent audit events |
| `GET /v1/devices?query=&limit=` | devices with their current license |
| `GET /v1/licenses?query=&status=&limit=` | license summaries |
| `GET /v1/customers?query=&limit=` | customer summaries |
| `GET /v1/customers/{customer_id}` | one customer with its devices and licenses |
| `GET /v1/audit?query=&limit=` | audit events, newest first |

Searches filter a bounded page of the most recent 500 documents (Firestore has
no substring search). Deeper full-text search would need an index service.

**Still required before this can serve traffic (not done in this phase):**

1. a Firebase project, a web app and **Firebase Authentication** with **Google**
   as the only provider and at least one administrator account (done:
   `klickpos-license-manager`, web app registered, Google enabled);
2. **Firebase App Check** registration for the dashboard origin (if enforced);
3. the **Firestore** database (native mode) and the four collections — they are
   created implicitly on first write, but indexes for
   `licenses where hw_hash ==` are worth adding;
4. **Firestore security rules** denying all client access (Admin SDK only);
5. a **production Ed25519 keypair** generated offline with
   `python -m tools.license_generator keygen --key-id <id> --key-dir <outside repo>`
   and published with `provision-release` into the **customer package's**
   `verification_keys.json` — until customer builds ship that public key, codes
   are unverifiable on their machines;
6. two **Secret Manager** secrets: `…/signing` (JSON `{key_id, seed_b64}`) and
   `…/code-encryption` (base64 32-byte AES key);
7. a service account with `roles/datastore.user`,
   `roles/secretmanager.secretAccessor` and Firebase Auth token verification;
8. **CORS** for the dashboard origin if the Next.js app calls this API from a
   browser (not configured here — add it deliberately, with exact origins);
9. the deployment itself (Cloud Run or equivalent) — **not** performed.

Deployment dependencies (`requirements-runtime.txt`, the only file the API image
installs): `firebase-admin`,
`google-cloud-firestore`, `google-cloud-secret-manager` — imported lazily, so
the test suite runs without them — plus `sqlalchemy` and `pydantic-settings`,
which are required **transitively**: importing the customer package runs
`app/licensing/__init__.py`, whose `app.core.exceptions` imports sqlalchemy and
whose `app.core.config` imports pydantic-settings. A clean environment without
them cannot even import the licensing contract.

`requirements.txt` is `-r requirements-runtime.txt` plus the test-only packages
(`pytest`, `httpx`); it is for local development and the test suite, never for
the image.

Two production guards fail loudly instead of degrading silently:
`FIREBASE_AUTH_EMULATOR_HOST` (would accept unsigned emulator tokens) and
`FIRESTORE_EMULATOR_HOST` (would write licences to a laptop database) both
raise at construction when `LICENSE_API_ENV=production`.

---

## 7b. Local development without cloud credentials

Everything except *real* Firebase token verification can run locally.

```bash
cd new_app/license_manager
python -m venv .venv && ./.venv/Scripts/python.exe -m pip install -r requirements.txt

# 1. Firestore emulator (no project, no credentials; needs Java 17+)
curl -o /tmp/emulator.jar https://storage.googleapis.com/firebase-preview-drop/emulator/cloud-firestore-emulator-v1.19.8.jar
java -jar /tmp/emulator.jar --host 127.0.0.1 --port 8081

# 2. Real Firestore integration tests against it
FIRESTORE_EMULATOR_HOST=127.0.0.1:8081 FIRESTORE_EMULATOR_PROJECT=demo-klickpos \
  ./.venv/Scripts/python.exe -m pytest tests/test_firestore_emulator.py -q

# 3. Readiness report (PASS/FAIL per check, never prints secrets)
./.venv/Scripts/python.exe scripts/preflight.py

# 4. Read-only live check against the real project (no writes, no tokens printed)
./.venv/Scripts/python.exe scripts/check_live_firebase.py

# 5. Container images (see docs/cloud-run.md §8 for the smoke tests)
docker build -f Dockerfile -t klickpos-license-api:local ..
docker build -f dashboard/Dockerfile -t klickpos-license-dashboard:local .

# 6. Combined Render staging image — context is `new_app/`, not this directory
docker build -f license_manager/Dockerfile.render \
  --build-arg NEXT_PUBLIC_FIREBASE_API_KEY=… \
  --build-arg NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=klickpos-license-free-8029b.firebaseapp.com \
  --build-arg NEXT_PUBLIC_FIREBASE_PROJECT_ID=klickpos-license-free-8029b \
  --build-arg NEXT_PUBLIC_FIREBASE_APP_ID=… \
  -t klickpos-license-staging:local ..
```

Both scripts are safe to point at the real project: the preflight Firestore
probe is read-only unless you pass `--write-probe`, which is meant for emulators
and scratch projects only.

For a local HTTP server you also need a token verifier. Real Firebase tokens
require Application Default Credentials (`gcloud auth application-default login`);
otherwise point `FIREBASE_AUTH_EMULATOR_HOST` at the Firebase Auth emulator.
`tests/test_firestore_emulator.py::test_the_http_api_works_end_to_end_against_real_firestore`
walks the full HTTP path against emulated Firestore with a development signing
seed and no production key material.

---

## 8. Manual testing

### Locally, without cloud services (recommended first)

```bash
cd new_app/license_manager
# throwaway keypair for the local run (never a production key)
../backend/.venv/Scripts/python.exe - <<'PY'
import base64, json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
k = Ed25519PrivateKey.generate()
seed = k.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                       serialization.NoEncryption())
pub = k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print("SEED=" + base64.b64encode(seed).decode())
print("PUB=" + base64.b64encode(pub).decode())
PY
```

Then export, pointing the service at a temp keys file containing that public
half, and start it:

```bash
export LICENSE_API_ENV=testing
export LICENSE_API_ADMIN_UIDS=admin-1
export LICENSE_API_DEV_SIGNING_SEED_B64=<SEED>
export LICENSE_API_DEV_CODE_ENC_KEY_B64=$(python -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())")
export LICENSE_API_VERIFICATION_KEYS_FILE=/path/to/verification_keys.json   # {"dev-local": "<PUB>"}
uvicorn service.api:app --port 8080
```

(With `LICENSE_API_ENV=testing` the container still builds a Firestore client on
the first request; for a cloud-free end-to-end walk use the test suite instead,
or point `FIRESTORE_EMULATOR_HOST` at the Firestore emulator.)

### Against the deployed service

1. Sign in to the dashboard, copy the ID token from the browser session.
2. On the customer machine: **Settings → License → activation request** →
   copy the `SMPr1…` code (and/or the displayed fingerprint code).
3. Parse it:
   ```bash
   curl -s -X POST https://API/v1/requests/parse \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"request_code":"SMPr1.…"}'
   ```
4. Issue:
   ```bash
   curl -s -X POST https://API/v1/licenses \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"request_code":"SMPr1.…","customer":{"name":"Epicerie Al Noor"}}'
   ```
   → copy `license.activation_code` and send it to the customer.
5. Customer pastes it in **Settings → License → activation code**; the POS must
   report **Lifetime / active** and keep working after a restart.
6. Submit the same fingerprint again → `200` with `created: false` and the
   **same** `activation_code`.
7. Retrieve it later:
   `curl -s https://API/v1/licenses/<license_id>/code -H "Authorization: Bearer $TOKEN"`
   (check `Cache-Control: no-store` in `-i`, and that an
   `activation_code_viewed` audit entry appeared).
8. Reissue and revoke with `confirm: true` / a reason, then confirm the old
   license shows `superseded` / `revoked` and still has its original code.

### Cross-check with the customer verifier

```bash
cd new_app/backend
./.venv/Scripts/python.exe -m tools.license_generator verify "<SMP1 code>" \
   --hw-hash <64-hex digest> --keys-file app/licensing/verification_keys.json
```

---

## 9. Files

```
new_app/license_manager/
├── README.md
├── dashboard/                Next.js administrator dashboard (see its README)
├── pyproject.toml            ruff + pytest configuration
├── pytest.ini                test paths
├── requirements-runtime.txt  production dependencies (installed in the image)
├── requirements.txt          runtime + test dependencies (local development)
├── testkit.py                shared test constants/helpers
├── firebase/
│   ├── firebase.json         rules/indexes deployment config
│   ├── firestore.rules       deny-all: the Admin SDK bypasses rules
│   └── firestore.indexes.json   empty — no composite index is needed
├── scripts/
│   ├── preflight.py          readiness report (PASS/FAIL, never prints secrets)
│   └── check_live_firebase.py  read-only ADC/Firestore/Auth check, real project
├── service/
│   ├── api.py                FastAPI app, routes, error envelope, no-store
│   ├── auth.py               Firebase ID token, allowlist, App Check
│   ├── bootstrap.py          sys.path wiring to new_app/backend
│   ├── shared.py             the only imports of the existing licensing code
│   ├── contracts.py          record types
│   ├── container.py          dependency container + lazy production wiring
│   ├── crypto.py             AES-256-GCM envelope for stored codes
│   ├── errors.py             controlled error family
│   ├── firestore_repository.py   transactions, duplicate prevention
│   ├── limits.py             body cap middleware + sliding-window limits
│   ├── repository.py         repository protocol + in-memory implementation
│   ├── secrets.py            Secret Manager / environment fetchers
│   ├── service.py            business rules (issue, reissue, revoke, audit)
│   ├── settings.py           environment configuration
│   └── signing.py            Ed25519 signing + SMP1 issuance + self-checks
└── tests/                    154 tests (see §10)
```

No existing KlickPOS file was modified for this phase.

---

## 10. Test coverage

| File | Covers |
| --- | --- |
| `test_parse.py` | valid/invalid `SMPr1`, field-set closure, existing-license detection, display-code parity, delegation to the generator parser |
| `test_issue.py` | lifetime issuance, exact SMP1 field set, **byte-identical output vs `tools.license_generator`**, hardware binding, unpublished-key refusal, device/license documents, sealed code, customer details, audit |
| `test_duplicates.py` | repeated submission returns the original, one document only, 8-thread and 6-request concurrency (issuer called once) |
| `test_code_retrieval.py` | original code, `no-store`, audit per read, 404s, superseded and revoked cases |
| `test_reissue.py` | new id, preserved original, superseded chain, audit, confirmation, conflicts |
| `test_revoke.py` | status/reason/timestamp, notice wording, code still verifies, idempotency, conflicts, resubmission behaviour |
| `test_auth.py` | 401 matrix, allowlist (uid/email/empty/case), App Check, no provider leakage |
| `test_firebase_verifier.py` | real `firebase_admin` adapter: `check_revoked=True`, project pinning (wrong/missing `aud`, foreign `iss`), revoked/expired/invalid-signature tokens as one generic 401, allowlist pass/deny, emulator refused in production |
| `test_signing_keys.py` | secret parsing, settings guards, issuer guards, AES-GCM envelope and tamper/wrong-AAD cases |
| `test_store_failures.py` | 503 mapping, no internals on 500, missing SDK, and the full production Firestore path against a fake |
| `test_compatibility.py` | **real `LicenseManager.activate`** accepts an API-issued code, restart, other-hardware refusal, protocol constants |
| `test_limits.py` | 413 body cap, strict bodies, per-administrator rate limits |
| `test_firestore_emulator.py` | **real Firestore** (emulator): document shape, read-back through a second client, duplicate prevention, 5-thread concurrency, reissue/revoke, and the full HTTP path end to end. Skipped unless `FIRESTORE_EMULATOR_HOST` is set |
| `test_environment_guards.py` | emulator variables refused in production, configurable dev key id, production still rejects dev signing material |
| `test_transaction_contention.py` | the aborted-transaction fallback: the winner's license is returned, nothing is re-signed, unrelated errors still propagate |

---

## 11. Two Firestore behaviours worth knowing (found with the emulator)

1. **Every transaction read must precede every write.** `reissue_license`
   originally read the `devices` document after staging the license writes;
   Firestore rejects that. The fake client happily accepted it, which is why
   this only surfaced against a real server. Reads are now batched first.
2. **Optimistic transactions can give up.** Five simultaneous requests for one
   fingerprint overloaded the SDK's retry budget
   (`Failed to commit transaction in 5 attempts`). A losing request now reads
   the committed winner (short bounded poll, 15 × 200 ms) and returns it as
   `created: false`; it never signs twice. Arbitrary errors are not swallowed.

Anything that talks to Firestore therefore must be verified against a real
server, not only `tests/fakes.py`.
