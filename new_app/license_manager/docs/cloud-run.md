# KlickPOS License Manager on Google Cloud Run

Phase 6 preparation. **Nothing in this document has been executed against
Google Cloud.** It is the written plan plus the artifacts (Dockerfiles, env
templates, code, tests) that make it executable by the operator.

Every value that would be a credential is a placeholder such as
`<dashboard-runtime-sa>` or `<version-number>`.

---

## 1. Architecture

```
                            ┌────────────────────────────────┐
   administrator's browser  │  Google sign-in (Firebase Auth)│
        │                   └────────────────────────────────┘
        │  1. same-origin page + Firebase ID token
        ▼
┌──────────────────────────────────────────────────────────────┐
│ Service B — klickpos-license-dashboard   (Next.js, public)    │
│ https://dashboard…run.app                                     │
│                                                               │
│  • Firebase Web App config (public by design)                 │
│  • Route Handler  /api/license/*  ← same-origin proxy         │
│      └─ mints its own OIDC token from the metadata server      │
│         (audience = API URL) via the attached runtime SA       │
│  • never ships a service token or secret to the browser        │
└──────────────────────────────────────────────────────────────┘
        │  2. POST/GET, two credentials:
        │     Authorization: Bearer <Firebase ID token>          (administrator)
        │     x-serverless-authorization: Bearer <OIDC>          (Cloud Run IAM edge)
        │     x-klickpos-service-authorization: Bearer <OIDC>    (verified in-process)
        ▼
┌──────────────────────────────────────────────────────────────┐
│ Service A — klickpos-license-api   (FastAPI, private)         │
│ https://api…run.app   --no-allow-unauthenticated               │
│                                                               │
│  0. Cloud Run IAM: only the dashboard SA holds run.invoker     │
│  1. service/cloud_run.py: verify the same OIDC token again     │
│     (audience + caller service-account allowlist)              │
│  2. service/auth.py: firebase_admin.verify_id_token(           │
│        check_revoked=True)  + administrator allowlist          │
│  3. App Check (optional, LICENSE_API_REQUIRE_APP_CHECK)        │
│                                                               │
│  Firestore Admin SDK only ──► Firestore (licenses, devices,    │
│  Secret Manager ──────────►   customers, audit_log)            │
│  (Ed25519 seed, AES-256-GCM key)                               │
└──────────────────────────────────────────────────────────────┘
```

The browser never resolves the API hostname, never holds a Google Cloud token
and never talks to Firestore.

### What changed in Phase 6 (and why)

| Change | Reason |
|---|---|
| `service/cloud_run.py` + `service_identity` in `api.py` | The API now validates the *calling service* (Google OIDC token: audience + caller service account) in addition to the administrator's Firebase token. |
| `dashboard/app/api/license/[...path]/route.ts` | A `next.config.ts` **rewrite can only forward what the browser sent**; it cannot attach a second credential. The Route Handler adds the dashboard's identity token while leaving `Authorization` untouched. |
| `dashboard/lib/server-identity.ts` | Mints and caches the OIDC token from the metadata server; the token is a service credential and never reaches a browser bundle. |
| `next.config.ts` | Rewrite removed (superseded by the handler), `output: "standalone"` for a slim image. |
| `Dockerfile`, `dashboard/Dockerfile`, ignore files, `deploy/*.env.template` | Deployment artifacts, non-root, no secrets baked in. |
| `service/cloud_logging.py` | Opt-in JSON logs (`LICENSE_API_LOG_JSON=1`). |

The API's **existing** authentication and authorization behaviour is unchanged
when `LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER` is unset (local runs and the whole
existing test suite keep working byte-for-byte).

---

## 2. Cloud Run service configuration

### Service A — `klickpos-license-api`

| Setting | Value | Why |
|---|---|---|
| Image | `…/klickpos-license-api:<git-sha>` | Immutable tag per deploy |
| Region | `<region>` (co-located with Firestore) | Latency; Firestore location is fixed |
| Ingress | all | Cloud Run IAM still gates it |
| Authentication | **`--no-allow-unauthenticated`** | Only `run.invoker` holders get in |
| Service account | `klickpos-api-runtime@<project>.iam.gserviceaccount.com` | Dedicated runtime identity, never a personal ADC |
| Port | `8080` (`PORT` is read by the image) | Cloud Run default |
| CPU / memory | 1 vCPU / 512 MiB to start | Pure Python + I/O |
| Min instances | `1` in production, `0` in staging | Cold start + Secret Manager fetch on first issuance |
| Max instances | `10` | Bounds the in-memory rate limiter's blast radius (§8) |
| Concurrency | `40` | Sync FastAPI in a thread pool; keeps a single instance responsive |
| Request timeout | `60s` | No endpoint is long-running |
| Startup probe | HTTP `GET /healthz` (port 8080) | No credentials, no store |
| Secrets | `LICENSE_API_SIGNING_SECRET`, `LICENSE_API_CODE_ENC_SECRET` mounted via `--set-secrets` **or** fetched by name (the code fetches by name; both are supported) | Values never appear in env or image |
| Env | `deploy/api.env.template` | Names only for secrets |

### Service B — `klickpos-license-dashboard`

| Setting | Value | Why |
|---|---|---|
| Image | `…/klickpos-license-dashboard:<git-sha>` | |
| Authentication | **`--allow-unauthenticated`** | The public entry point; Firebase Auth protects the console itself |
| Service account | `klickpos-dashboard-runtime@<project>.iam.gserviceaccount.com` | Needs exactly `run.invoker` on Service A |
| Port | `8080` | `PORT`/`HOSTNAME` honoured by the standalone Next server |
| CPU / memory | 1 vCPU / 512 MiB | |
| Min / max instances | `0` / `10` | |
| Concurrency | `80` | Next server handles concurrent requests well |
| Request timeout | `30s` | Proxy hop only |
| Env | `deploy/dashboard.env.template` | Public Firebase config + `LICENSE_DASHBOARD_API_AUDIENCE` |

Both services: `--set-secrets` is **not** used for the API's two secrets in this
design (the process fetches by name so it can fail closed per request rather
than at boot); if the operator prefers mounting, mount them as files and point
`LICENSE_API_SIGNING_SECRET` at the secret name — the code path is unchanged.

---

## 3. Identities and IAM (least privilege)

Create these **manually** (not done here):

```bash
gcloud iam service-accounts create klickpos-api-runtime \
  --project=<project> --display-name="KlickPOS License API runtime"
gcloud iam service-accounts create klickpos-dashboard-runtime \
  --project=<project> --display-name="KlickPOS License Dashboard runtime"
```

| # | Identity | Role | Resource scope | Reason | Service |
|---|---|---|---|---|---|
| 1 | `klickpos-api-runtime` | `roles/datastore.user` | Project (or the specific database) | Read/write `licenses`, `devices`, `customers`, `audit_log` through the Admin SDK | API |
| 2 | `klickpos-api-runtime` | `roles/firebaseauth.viewer` | Project | `verify_id_token(check_revoked=True)` performs the user lookup (`firebaseauth.users.get`) | API |
| 3 | `klickpos-api-runtime` | `roles/secretmanager.secretAccessor` | **Each secret** (`LICENSE_API_SIGNING_SECRET`, `LICENSE_API_CODE_ENC_SECRET`), not the project | Read the two secret versions | API |
| 4 | `klickpos-api-runtime` | `roles/serviceusage.serviceUsageConsumer` | Project | Only if quota/billing for this project is consumed by a different quota project; verify by call | API |
| 5 | `klickpos-dashboard-runtime` | `roles/run.invoker` | **Service A only** (`--service=klickpos-license-api`) | Call the private API | Dashboard |
| 6 | Deployer (your user or a CI identity) | `roles/run.admin`, `roles/iam.serviceAccountUser` (on both runtime SAs), `roles/artifactregistry.writer` | Project | Deploy; must be able to act as the runtime SAs | Build/deploy |
| 7 | Cloud Build SA | `roles/artifactregistry.writer`, `roles/logs.writer` | Project | Push the image, write build logs | Build |

Deliberately **not** granted: `roles/editor`, `roles/owner`, `roles/datastore.owner`,
`roles/secretmanager.admin`, project-wide `roles/run.invoker`, Firestore client
SDK access, any Firebase Auth write permission (`users.update`, `users.delete`
are not needed — revocation checking only reads).

Notes:

* `roles/firebaseauth.viewer` is the smallest predefined role that carries
  `firebaseauth.users.get`. If your organisation forbids Firebase roles on
  service accounts, a custom role with only `firebaseauth.users.get` is enough.
* Identity #1/#2/#3 belong to the **API**, #5 to the **dashboard**. The
  dashboard never reads Firestore and never reads a secret.
* A personal ADC account (`islemze2@gmail.com`) must **not** be a runtime
  identity: Cloud Run does not attach personal credentials, and a personal
  account's access dies with the person.

---

## 4. Secret Manager

The backend is chosen by `LICENSE_API_SECRET_SOURCE` and defaults to
`secretmanager`, so everything in this section is unchanged by Phase 8.3.2. A
host without Secret Manager (Render Free on the Firebase Spark plan) sets
`LICENSE_API_SECRET_SOURCE=file` instead and mounts one file per secret name in
`LICENSE_API_SECRET_DIR`; see `render-staging.md` §3. Version variables are a
Secret Manager concept and are ignored by the file source.

### Required secrets and exact formats

| Secret | Format | Produced by |
|---|---|---|
| `LICENSE_API_SIGNING_SECRET` | JSON text: `{"key_id": "<key-id>", "seed_b64": "<base64 of 32 bytes>"}` — **exactly** those two fields | Owner-side offline key generation (`tools/license_generator`), never this service |
| `LICENSE_API_CODE_ENC_SECRET` | base64 text of exactly 32 random bytes (AES-256 key) | `openssl rand -base64 32` (or equivalent), once |

The code parses these with `service/signing.py::load_signing_key` and
`service/crypto.py::ActivationCodeCipher.from_base64`. **Do not** change
serialisation, add fields, or regenerate the AES key for an existing database:
stored codes are sealed with it (`gcm1:<nonce>:<ciphertext+tag>`, license id as
associated data). Losing or rotating it makes every stored activation code
unreadable — see §4.4.

### 4.1 Provisioning procedure (manual, not executed here)

Placeholders only; run in a shell you control, never in CI logs.

```bash
# 1. Create the secrets (no version yet).
gcloud secrets create LICENSE_API_SIGNING_SECRET --replication-policy=automatic --project=<project>
gcloud secrets create LICENSE_API_CODE_ENC_SECRET    --replication-policy=automatic --project=<project>

# 2. Add version 1 from a file that never enters git or an image.
#    Generate the AES key like this (write it to a local file you delete after):
openssl rand -base64 32 > /secure/path/code_enc.key
gcloud secrets versions add LICENSE_API_CODE_ENC_SECRET \
  --data-file=/secure/path/code_enc.key --project=<project>
shred -u /secure/path/code_enc.key    # or: rm, then empty the trash

#    The signing secret file must already exist (owner-side key generation):
#    {"key_id": "<key-id>", "seed_b64": "<base64-32-bytes>"}
gcloud secrets versions add LICENSE_API_SIGNING_SECRET \
  --data-file=/secure/path/signing_secret.json --project=<project>
rm -f /secure/path/signing_secret.json

# 3. Grant only the API runtime SA, only on these two secrets.
gcloud secrets add-iam-policy-binding LICENSE_API_SIGNING_SECRET \
  --member=serviceAccount:klickpos-api-runtime@<project>.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor --project=<project>
gcloud secrets add-iam-policy-binding LICENSE_API_CODE_ENC_SECRET \
  --member=serviceAccount:klickpos-api-runtime@<project>.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor --project=<project>
```

The signing `key_id` must already be present in the packaged customer keys
(`new_app/backend/app/licensing/verification_keys.json`); otherwise issuance
fails closed with `503 signing_key_not_published`. Publishing a new public key
to the customer package is an offline, owner-side step.

### 4.2 Version pinning policy

* `LICENSE_API_SIGNING_SECRET_VERSION` and `LICENSE_API_CODE_ENC_SECRET_VERSION`
  are set to an **explicit version number** in production (not `latest`), so a
  deploy cannot silently pick up a new key.
* `latest` is acceptable only in staging while iterating.
* Rotation = add a new version, change the env var, redeploy. Rollback = point
  back at the previous version and redeploy (§11). No code change, no rebuild.

### 4.3 Fail-closed behaviour

| Situation | Result |
|---|---|
| Secret missing / inaccessible / malformed | `503 signing_unavailable` on issuance; the token gate still answers `401` for a bad token first (an unauthenticated caller never learns that a secret is broken) |
| Development seed variables set while `LICENSE_API_ENV=production` | Process refuses to start (`ValueError`) |
| `LICENSE_API_ENV` unset | Defaults to development; a Cloud Run deployment must set `production` explicitly |
| Secret name empty in production | Refuses to start |

There is **no fallback** from Secret Manager to environment values in
production: `EnvironmentSecretFetcher` itself raises outside development.

### 4.4 Rotation and recovery

| Secret | Rotation | Recovery if lost |
|---|---|---|
| `LICENSE_API_CODE_ENC_SECRET` | Only with a migration: open every stored envelope with the old key and re-seal with the new one (a scripted, offline, audited operation). Until then, **do not rotate** — the dashboard's "show code" would fail closed for old licenses. | Unrecoverable from this service; restore from your Secret Manager backup/export. Firestore still holds the *signatures*, so a replacement license can be reissued per device. |
| `LICENSE_API_SIGNING_SECRET` | Normal key rotation: generate a new keypair offline, publish the new public key in the customer package (release), add a new secret version, bump the version env var. Old codes keep verifying because old key ids stay in the customer package. | Recover the seed from your offline key custody. Losing it only stops *new* issuance with that key id; existing licenses remain valid. |

Backups: export both secrets to your organisation's secret backup (e.g. a
sealed offline copy). Never store them in this repository, an image, or a
document.

---

## 5. Firestore

* The API uses the **Admin SDK only** (`google.cloud.firestore`), which bypasses
  security rules — the rules are for any other client, not for this service.
* No browser code imports a Firestore SDK; the dashboard only calls `/api/license/*`.
* Collection layout is unchanged: `customers`, `devices`, `licenses`, `audit_log`.
* `firebase/firestore.rules` is deny-all. **It still has to be deployed**
  (`firebase deploy --only firestore:rules`) — do not assume a new database has
  the rules you expect. This is a separate manual step (§12).
* `firebase/firestore.indexes.json` is empty; the queries used
  (`where` on a single field, `order_by` on a single field, `count()`) need no
  composite index.

---

## 6. App Check

Implemented in Phase 6.9, end to end, with **enforcement still off**.

### 6.1 Flow

```
browser                        Next server (Cloud Run)        License API (Cloud Run)
  │                                    │                              │
  │ Firebase Auth: ID token            │                              │
  │ App Check (reCAPTCHA Enterprise)   │                              │
  │  -> X-Firebase-AppCheck            │                              │
  ├──────────── /api/license/* ───────▶│ allow-lists that header,     │
  │   Authorization: Bearer <id>       │ adds its OIDC service token  │
  │   X-Firebase-AppCheck: <appcheck>  ├──── same headers + OIDC ────▶│
  │                                    │                              │ 1. service identity
  │                                    │                              │ 2. Firebase ID token
  │                                    │                              │ 3. App Check (if enforced)
  │                                    │                              │ 4. allowlist
```

* **Client** (`dashboard/lib/app-check.ts`): initializes Firebase App Check on
the same Firebase app with `ReCaptchaEnterpriseProvider` and the public
`NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY`, auto-refreshes tokens, and returns the
token for each protected call. It never asserts validity, never fabricates a
token, and returns `null` when App Check is not configured or the SDK fails.
* **Transport** (`dashboard/lib/api.ts`): adds `X-Firebase-AppCheck` next to the
  `Authorization` header. The proxy forwards only that allow-listed header and
  still adds its own service identity; a browser cannot supply either the
  service header or a "verified" claim.
* **Server** (`service/auth.py`): `firebase_admin.app_check.verify_token` runs
  inside the Admin SDK, then `_assert_app_check_project` pins the token's
  `aud` (`projects/<project number>`) to `LICENSE_API_APP_CHECK_AUDIENCE`.
  A missing, forged or foreign-project token is `401 app_check_failed` **after**
  the service-identity and ID-token gates have passed. App Check is never a
  substitute for either.
* **Fail-closed**: processing stops at the first failed gate; with enforcement
  on, a missing token is never "warned about" and allowed through.

### 6.2 Configuration

| Where | Variable | Value |
|---|---|---|
| Dashboard runtime/build | `NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY` | reCAPTCHA Enterprise site key (public) |
| Dashboard, local only | `NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN` | debug token UUID, or `true`; never in staging/production |
| API | `LICENSE_API_REQUIRE_APP_CHECK` | `0` until staging proves the traffic |
| API | `LICENSE_API_APP_CHECK_AUDIENCE` | Firebase **project number**; required in production when the flag is `1` (startup refuses otherwise) |

### 6.3 Firebase Console work required for staging (not performed)

1. Firebase Console → **App Check** → **Apps** → register the dashboard web app
   with the **reCAPTCHA Enterprise** provider.
2. Create (or reuse) a reCAPTCHA Enterprise key for the dashboard's origin(s)
   (`https://<dashboard-url>` and, for local testing, `localhost`) and paste its
   **site key** into `NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY`.
3. **App Check → Apps → Manage debug tokens**: add a debug token for local
   development, put it in `.env.local` only.
4. Watch **App Check → Metrics** until the dashboard's requests are verified
   (non-zero "verified" share, rejected failures near zero).
5. Only then set `LICENSE_API_REQUIRE_APP_CHECK=1` and
   `LICENSE_API_APP_CHECK_AUDIENCE=<project number>` on the **staging** API and
   redeploy it.
6. Do **not** enable "Enforced" for Firestore / Identity Toolkit / Cloud Run in
   the Console yet; the API's own flag is the only enforcement in this project.
7. Repeat in production only after staging is verified; never flip enforcement
   before a dashboard build that sends tokens is deployed.

The App Check token is **not** an identity: it says "the request came from our
app", never "this is administrator X".

---

## 7. Staging environment

### 7.1 Recommended shape

A **separate Google Cloud / Firebase project** (`klickpos-license-staging`),
because:

* Firebase Authentication is per project — staging administrators are different
  *users*, and their UIDs must not overlap production's allowlist;
* Firestore, Secret Manager, service accounts, Cloud Run URLs, logs and billing
  are isolated by construction;
* a second Firestore *database* inside the production project would share the
  billing/quota and the same IAM surface, and the Admin SDK default database
  differs — more footguns than it saves.

Nothing is created automatically. Checklist (manual, in this order):

1. Create project `klickpos-license-staging` and note `<staging-project>`.
2. Enable APIs: Cloud Run, Artifact Registry, Cloud Build, Firestore,
   Secret Manager, Identity Toolkit (Firebase Auth), Service Usage.
3. `firebase projects:addfirebase <staging-project>` (or Firebase Console →
   Add project); create a **Firestore** database in the same region as
   production-adjacent choice (e.g. `europe-west1`), native mode.
4. Enable Firebase Authentication → Google provider. **Not** email/password, not
   anonymous.
5. Register a **staging Web App**; copy its public config into
   `deploy/dashboard.env.staging` (local, git-ignored).
6. Authorised domains for the staging dashboard URL (Cloud Run hostname) so the
   Google popup works.
7. Create staging administrators (a test Google account) and record their UID.
8. Create the two staging runtime service accounts (§3, same names, staging project).
9. Create staging-only secrets (§4) with **test** material:
   * a throwaway Ed25519 keypair whose `key_id` is published in a staging copy of
     `verification_keys.json`;
   * a fresh random AES key.
   **Never** reuse development or production keys.
10. Create Artifact Registry repository `klickpos` in `<staging-region>`.
11. Deploy Service A, read its URL, then Service B with that URL as
    `LICENSE_API_BASE_URL` and `LICENSE_DASHBOARD_API_AUDIENCE`, then grant
    `run.invoker` on A to B's service account.
12. Deploy Firestore rules (`firebase deploy --only firestore:rules
    --project=<staging-project>`).

### 7.2 Staging vs production configuration

| Setting | Staging | Production |
|---|---|---|
| Project | `klickpos-license-staging` | `klickpos-license-manager` |
| `LICENSE_API_ENV` | `production` (same code path as prod!) | `production` |
| Firestore | staging database | production database |
| Secrets | staging-only test material | production material, version pinned |
| `LICENSE_API_ADMIN_UIDS/EMAILS` | staging test account | production administrator |
| Min instances | `0` | `1` |
| `LICENSE_API_REQUIRE_APP_CHECK` | `1` after validation | `1` after validation |
| Cloud Run service names | `klickpos-license-api-staging`, `klickpos-license-dashboard-staging` | `klickpos-license-api`, `klickpos-license-dashboard` |
| Logs | staging project logs | production project logs |
| `NEXT_PUBLIC_API_BASE_URL` | staging API URL | production API URL |

Using `LICENSE_API_ENV=production` in staging is deliberate: it exercises the
real fail-closed guards instead of a "it works because the guard is off" state.

For a **no-billing** host (Render Free plus a Firebase Spark project, where
Secret Manager does not exist), use the file secret source and the combined
container instead: `render-staging.md` and `../deploy/staging.env.template`.
Production on Cloud Run is unaffected by that path.

---

## 8. Local Docker build and smoke tests

```bash
# API — context is new_app/ because it imports the licensing contract read-only
docker build -f new_app/license_manager/Dockerfile -t klickpos-license-api:local new_app

# Dashboard — context is new_app/license_manager/
docker build -f new_app/license_manager/dashboard/Dockerfile \
  -t klickpos-license-dashboard:local new_app/license_manager
```

**Context root matters.** `license_manager/.dockerignore` is only applied when
`license_manager` *is* the context (that is the command above). If you build
with `dashboard` itself as the context, `dashboard/.dockerignore` applies
instead; both files exist for that reason.

**Pitfall fixed in Phase 6.8.1:** a bare `node_modules` / `.next` pattern in a
`.dockerignore` is anchored at the context root, so it did *not* exclude
`dashboard/node_modules` (785 MB context). Worse, `COPY dashboard/ ./` then
merged the host dependency tree over the image's own `node_modules`, and
BuildKit failed with `chmod … read-only file system`. The Dockerfile now copies
explicit source paths only; never reintroduce a whole-directory copy into a
directory that already holds `node_modules`.

Smoke test (no cloud, no secrets, no writes):

```bash
# API: development env with a throwaway seed so it can boot without Secret Manager
docker run --rm -p 8080:8080 \
  -e LICENSE_API_ENV=development \
  -e LICENSE_API_FIREBASE_PROJECT_ID=klickpos-license-manager \
  -e LICENSE_API_ADMIN_UIDS=<admin-uid> \
  -e LICENSE_API_DEV_SIGNING_SEED_B64=<throwaway-base64-32-bytes> \
  -e LICENSE_API_DEV_CODE_ENC_KEY_B64=<throwaway-base64-32-bytes> \
  -e LICENSE_API_VERIFICATION_KEYS_FILE=/app/backend/app/licensing/verification_keys.json \
  klickpos-license-api:local
curl -fsS http://127.0.0.1:8080/healthz     # {"status":"ok","environment":"development"}
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/v1/overview   # 401

# Dashboard (built with the public Firebase build args — see render-staging.md §4)
docker run --rm -p 8081:8080 \
  -e LICENSE_API_BASE_URL=http://127.0.0.1:8080 \
  klickpos-license-dashboard:local
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/login       # 200
```

Image hygiene checks:

```bash
docker run --rm klickpos-license-api:local sh -c 'id -u; ls /app'   # 10001, no .env, no ADC
docker history --no-trunc klickpos-license-api:local | grep -i -E 'secret|seed|password' || true
```

Vulnerability scanning: enable Artifact Registry's automatic scanning, or run
`docker scout cves <image>` / `trivy image <image>` in CI, and fail the build on
`CRITICAL`. Rebuild regularly: `python:3.12-slim` and `node:22-alpine` receive
patches, and images built from them inherit them only on rebuild.

---

## 9. Deployment procedure (manual; not executed in Phase 6)

```bash
# 0. Build and push
gcloud builds submit --tag <region>-docker.pkg.dev/<project>/klickpos/license-api:<sha> \
  --file=new_app/license_manager/Dockerfile new_app
gcloud builds submit --tag <region>-docker.pkg.dev/<project>/klickpos/license-dashboard:<sha> \
  --file=new_app/license_manager/dashboard/Dockerfile new_app/license_manager

# 1. Service A (private)
gcloud run deploy klickpos-license-api \
  --image=<region>-docker.pkg.dev/<project>/klickpos/license-api:<sha> \
  --region=<region> --no-allow-unauthenticated \
  --service-account=klickpos-api-runtime@<project>.iam.gserviceaccount.com \
  --min-instances=1 --max-instances=10 --concurrency=40 --timeout=60 \
  --env-vars-file=deploy/api.env.production --project=<project>

API_URL=$(gcloud run services describe klickpos-license-api --region=<region> \
  --format='value(status.url)' --project=<project>)

# 2. Service B (public), pointed at A
gcloud run deploy klickpos-license-dashboard \
  --image=<region>-docker.pkg.dev/<project>/klickpos/license-dashboard:<sha> \
  --region=<region> --allow-unauthenticated \
  --service-account=klickpos-dashboard-runtime@<project>.iam.gserviceaccount.com \
  --min-instances=1 --max-instances=10 --concurrency=80 --timeout=30 \
  --set-env-vars=LICENSE_API_BASE_URL=$API_URL,LICENSE_DASHBOARD_API_AUDIENCE=$API_URL \
  --env-vars-file=deploy/dashboard.env.production --project=<project>
# (use one mechanism per variable; --set-env-vars above shows the two that must
#  match the deployed URL — put them in the env file instead if you prefer)

# 3. Only the dashboard may invoke A
gcloud run services add-iam-policy-binding klickpos-license-api \
  --region=<region> --project=<project> \
  --member=serviceAccount:klickpos-dashboard-runtime@<project>.iam.gserviceaccount.com \
  --role=roles/run.invoker
```

`LICENSE_API_CLOUD_RUN_AUDIENCE` in the API's env file must be exactly `$API_URL`
(no trailing slash needed — it is normalised). A mismatch makes every proxied
call `401 service_identity_required`.

---

## 10. Environment variables reference

### License API

| Variable | Required | Purpose |
|---|---|---|
| `LICENSE_API_ENV` | yes (`production`) | Guard selection; `production` refuses dev keys/emulators |
| `LICENSE_API_FIREBASE_PROJECT_ID` | yes | Admin SDK project, token audience pinning, Secret Manager project |
| `LICENSE_API_FIRESTORE_DATABASE` | no | Non-default database only |
| `LICENSE_API_ADMIN_UIDS` / `LICENSE_API_ADMIN_EMAILS` | at least one | Administrator allowlist (empty = deny everyone) |
| `LICENSE_API_SECRET_SOURCE` | no | `secretmanager` (default) or `file`; a bad value stops the process |
| `LICENSE_API_SECRET_DIR` | with `file` | Directory of read-only secret files, one per secret name |
| `LICENSE_API_SIGNING_SECRET` / `_VERSION` | yes | Secret name / pinned version (version ignored when the source is `file`) |
| `LICENSE_API_CODE_ENC_SECRET` / `_VERSION` | yes | Secret name / pinned version (version ignored when the source is `file`) |
| `LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER` | yes on Cloud Run | Enables the service-identity gate |
| `LICENSE_API_CLOUD_RUN_AUDIENCE` | with the above | This API's own URL (exact audience) |
| `LICENSE_API_CLOUD_RUN_INVOKERS` | production | Dashboard runtime SA e-mail(s) |
| `LICENSE_API_REQUIRE_APP_CHECK` | no | See §6 |
| `LICENSE_API_TRUST_PROXY` | yes on Cloud Run | Honour `X-Forwarded-For` for the audit trail |
| `LICENSE_API_RATE_LIMIT_PER_MINUTE` / `_ISSUE_LIMIT_PER_MINUTE` | no | Per-instance windows |
| `LICENSE_API_MAX_BODY_BYTES` | no | Default 8192 |
| `LICENSE_API_VERIFICATION_KEYS_FILE` | yes | Absolute path to the packaged customer keys |
| `LICENSE_API_LOG_JSON` | no | JSON logs |
| `PORT` | injected | Cloud Run port (image default 8080) |

Development-only, refused when `LICENSE_API_ENV=production`:
`LICENSE_API_DEV_SIGNING_SEED_B64`, `LICENSE_API_DEV_SIGNING_KEY_ID`,
`LICENSE_API_DEV_CODE_ENC_KEY_B64`, `LICENSE_API_DEV_AUTH_UID`.

### Dashboard

| Variable | Required | Purpose |
|---|---|---|
| `LICENSE_API_BASE_URL` | yes | Proxy target, server-only and read per request; plain `http` only for loopback |
| `NEXT_PUBLIC_API_BASE_URL` | no | Legacy build-time fallback (inlined at build); leave empty for new deployments |
| `LICENSE_DASHBOARD_API_AUDIENCE` | on Cloud Run | OIDC audience = API URL; empty disables the service identity (local only) |
| `NEXT_PUBLIC_FIREBASE_*` | yes | Public Firebase Web App config |
| `NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST` | no | Local emulator only; must be empty on Cloud Run |
| `PORT`, `HOSTNAME` | injected | Read by the standalone Next server |

---

## 11. Rollback

1. **Code rollback:** `gcloud run services update-traffic <service> --to-revisions=<previous>=100` (both services, API first when the pair changed together).
2. **Secret rollback:** point `LICENSE_API_*_SECRET_VERSION` at the previous
   version and redeploy. No rebuild. Old codes keep verifying.
3. **Firestore:** this service never migrates schemas destructively; a rollback
   targets documents written by the newer revision only. Revoke/reissue are
   additive (`status`, `superseded_by`), so an older revision reads them fine.
4. **Dashboard alone** can be rolled back independently; the API contract
   (`/v1/*`) is stable across revisions.
5. After any rollback, re-run the smoke checks in §8 and one authenticated
   `GET /v1/overview` through the dashboard.

---

## 12. Backup and disaster recovery

| Asset | Backup | RPO / RTO notes |
|---|---|---|
| Firestore | Managed backups or scheduled export to Cloud Storage (`gcloud firestore export`) | Enable before go-live; test a restore into staging, never into production |
| Signing secret | Offline sealed copy in owner custody | Losing it stops new issuance with that key id only |
| Encryption secret | Offline sealed copy | Losing it makes stored codes unreadable — back it up with the same care as Firestore |
| Verification keys | Git (they are public) + the customer package | Needed to verify codes at the customer |
| Images | Artifact Registry retains tags; keep the last known-good `<sha>` recorded | Re-deploy by digest |
| Env templates | Git (placeholders only) | Real env files are **not** in git |
| Firestore rules/indexes | Git (`firebase/`) | Re-deploy with the Firebase CLI |

A regional Firestore outage is not something this service can work around: it
answers `503 store_unavailable` and the dashboard shows a controlled error.

---

## 13. Production checklist

- [ ] Staging project created, deployed and exercised (issue → verify → reissue → revoke) against staging Firestore.
- [ ] Two runtime service accounts created; IAM matrix of §3 applied (no Editor/Owner).
- [ ] `roles/run.invoker` on Service A granted **only** to the dashboard SA.
- [ ] Service A deployed with `--no-allow-unauthenticated`; unauthenticated `curl` gets Google's 403.
- [ ] API env: `LICENSE_API_ENV=production`, project id, allowlist, secret names **with pinned versions**, audience + invoker SA.
- [ ] Secret versions exist; only the API SA can access them; no secret value in git, images, env files or logs.
- [ ] `key_id` of the signing secret is present in the packaged customer verification keys.
- [ ] Firestore rules deployed; indexes deployed.
- [ ] Dashboard env: public Firebase config, proxy target and audience = the deployed API URL.
- [ ] Google sign-in works on the Cloud Run hostname (authorised domain added).
- [ ] `/v1/overview` returns 200 through the dashboard; a request with a wrong/absent service token returns 401/403; a non-allowlisted account returns 403.
- [ ] Sign-out clears the session; `/overview` bounces to `/login`.
- [ ] App Check validated in staging before enabling it in production.
- [ ] Logs contain no token, activation code or secret; log-based metrics/alerts on `service_identity_required`, `store_unavailable`, `signing_unavailable`.
- [ ] Billing budget alert set on the project.
- [ ] Backups (Firestore export + secret custody) verified once.
- [ ] Known gaps in `docs/security-review.md` accepted or fixed.
