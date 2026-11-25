# KlickPOS License Manager — Staging on Render Free

Phase 8.3.2 preparation. **Nothing in this document has been executed against
Render, Google Cloud or Firebase.** It records the configuration the code now
supports, the reasons for it, and the steps an operator will take later.

Related: `cloud-run.md` (production architecture, unchanged) and
`../deploy/staging.env.template` (the placeholders below, in one file).

---

## 1. The shape

```
administrator's browser
   │  Google sign-in (Firebase Auth, staging project)
   ▼
┌──────────────────────────── Render Free, one container ────────────────────┐
│  Next.js standalone  ── listens on $PORT (public)                          │
│    • public Firebase web config (inlined at image build)                    │
│    • /api/license/* Route Handler: adds Authorization passthrough only      │
│    • proxy target: LICENSE_API_BASE_URL (server-only, read per request)     │
│                        │  http://127.0.0.1:8000                            │
│                        ▼                                                    │
│  FastAPI (uvicorn)   ── 127.0.0.1:8000 ONLY, never published                │
│    • Firebase ID token (check_revoked) + project aud/iss pinning            │
│    • administrator allowlist, optional App Check                            │
│    • Firestore Admin SDK (staging service account via ADC file)             │
│    • signing seed + AES key from read-only files in LICENSE_API_SECRET_DIR   │
└────────────────────────────────────────────────────────────────────────────┘
```

Consequences that must hold:

* FastAPI binds `127.0.0.1`, so only the Next.js process in the same container
  can reach it. There is no Cloud Run IAM edge and no metadata server, which is
  why `LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER=0` and
  `LICENSE_DASHBOARD_API_AUDIENCE` is empty.
* Render terminates TLS; the container itself speaks plain HTTP on `$PORT`.
* Both processes must handle `SIGTERM` (Render sends it on redeploy) and the
  container must run as a non-root user. No secret, no service-account JSON and
  no `.env` may be copied into an image layer — secrets are mounted at runtime.
* The combined image is `Dockerfile.render` (context `new_app/`); see §10.

---

## 2. Why the code had to change for this host

| Blocker | Before | Now |
|---|---|---|
| B1 — secrets | `container.py` used Secret Manager whenever `LICENSE_API_ENV=production`; Render/Spark have no Secret Manager | `LICENSE_API_SECRET_SOURCE=file` selects `FileSecretFetcher`, reading named files from `LICENSE_API_SECRET_DIR`. Secret Manager stays the default, unchanged |
| B3 — dashboard build | `dashboard/Dockerfile` passed no `NEXT_PUBLIC_*` to `npm run build`, so the image shipped an empty Firebase config | explicit build `ARG`/`ENV` block, plus a `prebuild` gate that refuses to build without the four values that matter |
| B4 — proxy target | the handler read `NEXT_PUBLIC_API_BASE_URL`, which Next inlines at build time | it reads the server-only `LICENSE_API_BASE_URL` per request; the public name remains a build-time fallback for the Phase 6 Cloud Run deployment |
| live check | `check_live_firebase.py` hard-coded production's project/uid/e-mail | `--staging --project … --uid …` (or `LICENSE_API_CHECK_*`), production defaults preserved, `--staging` refuses to fall back |

---

## 3. Secret files

`LICENSE_API_SECRET_SOURCE=file` with `LICENSE_API_SECRET_DIR=/etc/secrets`
(Render's mount point) means one file per configured secret **name**:

| File | Content | Format |
|---|---|---|
| `/etc/secrets/LICENSE_API_SIGNING_SECRET` | Ed25519 signing record | JSON: `{"key_id": "<key-id>", "seed_b64": "<base64 of 32 bytes>"}` — exactly those two fields |
| `/etc/secrets/LICENSE_API_CODE_ENC_SECRET` | AES-256-GCM key | base64 text of exactly 32 random bytes |

Properties enforced by `service/secrets.py::FileSecretFetcher` (and pinned by
`tests/test_secret_source.py`):

* the directory is resolved once at construction; a missing directory is a
  startup failure, not a silent empty backend;
* a secret name is a **file name**: `/`, `\`, drive letters, `.`, `..`, leading
  dots and absolute paths are refused before anything is opened;
* the file must resolve inside that directory, must not be a symlink, and must
  be a regular file (`O_NOFOLLOW` closes the check/open gap where supported);
* missing, unreadable, empty, oversized (> 64 KiB) or non-UTF-8 files fail
  closed with the controlled `signing_unavailable` error — no message contains a
  path or a byte of secret material, and nothing is logged;
* one trailing newline is dropped, because mounted files usually have one;
* there is **no** fallback to environment values; `EnvironmentSecretFetcher`
  still refuses to exist in production.

`*_SECRET_VERSION` variables are a Secret Manager concept and are ignored by the
file source, so a deployment can keep them configured while switching backends.
Rotation with files = replace the file's content and restart the service.

The service account JSON is a *different* file: it is read by `google-auth`
through `GOOGLE_APPLICATION_CREDENTIALS`, never by `FileSecretFetcher`.

### 3.1 Verification keys — staging's own public key file

Staging never reads the packaged production keys. `LICENSE_API_VERIFICATION_KEYS_FILE`
is absolute and is resolved once at startup (`service/settings.py`), and the
template pins it at the staging-only pair kept beside it in Git:

| | |
|---|---|
| `/app/license_manager/deploy/staging/verification_keys.staging.json` | staging public keys — currently the single id `stg-2026-11` |
| `deploy/staging/release_metadata.staging.json` | its `sha256:` fingerprints (release record; not needed at runtime) |
| `backend/app/licensing/verification_keys.json` | **production** keys — present in the same image, never referenced here |

The staging pair is public material produced offline by
`tools.license_generator provision-release`; the private half lives only in the
offline keystore and in the mounted signing secret. It is deliberately **not**
under `backend/app/`, so it can never reach a customer package
(`backend/customer_package.json` includes `app/` and `../lib` only).

`LICENSE_API_REQUIRE_STAGING_KEYS=1` makes the wiring fail closed in two stages:

1. **Configuration** (`service/settings.py`). `Settings` refuses to build when
the configured path resolves to *any* known production key file — the packaged
`backend/app/licensing/verification_keys.json` **and** its production container
path `/app/backend/app/licensing/verification_keys.json` — compared as
normalised identities (lexical `..`/relative spelling plus a symlink resolution),
so no equivalent spelling slips through.
2. **Startup** (`service/staging_keys.py`, called from `service.api.create_app`,
i.e. at import time for `uvicorn service.api:app`). The file must exist, be valid
JSON with the expected structure, not be empty, and publish the configured
staging key id (`LICENSE_API_STAGING_KEY_ID`, default `stg-2026-11`). Any
failure raises before the ASGI app exists, so the deploy crashes instead of
serving `503 signing_key_not_published` on every issuance.

3. **Signing seed** (`service/signing_key_match.py`, same `create_app` point,
   opt-in via `LICENSE_API_REQUIRE_SIGNING_KEY_MATCH=1`). A keys file cannot
   prove the mounted *seed* belongs to it, and the issuer's publication check
   compares ids only. The guard loads the seed through the same provider
   (`FileSecretFetcher` here, Secret Manager on Cloud Run), derives the Ed25519
   public half and compares it with the key published for
   `LICENSE_API_STAGING_KEY_ID` using `hmac.compare_digest`. A missing secret,
   a malformed or wrong-length seed, a seed whose `key_id` differs, a missing
   published id, or a plain mismatch all raise before the ASGI app exists. No
   message or log line carries a seed or key byte — only the path and id.

Production leaves both flags off (and the id variable unset): none of these
stages runs there, and its packaged production file stays the sole source of
verification keys. Error messages name the path, the problem and the expected
id — never a key byte or another entry from the file.

### 3.2 Preparing the staging signing secret file

`LICENSE_API_SIGNING_SECRET` is produced **offline, from the owner-side
keystore**; nothing in the running service generates or writes key material.
The exporter is `scripts/export_signing_secret.py`; it resolves `new_app/backend`
from its own location, so it can be run from any directory:

```bash
cd new_app/license_manager
./.venv/Scripts/python.exe scripts/export_signing_secret.py \
  --key-dir D:/klickpos-keys/staging \
  --key-id stg-2026-11 \
  --out D:/klickpos-keys/staging/LICENSE_API_SIGNING_SECRET
```

`--key-dir`, `--key-id` and `--out` are all required. The script:

* reads the keystore with the existing read-only
  `tools.license_generator.keystore.load_keystore`; it never calls
  `save_keystore`, `generate_keypair` or `merge_verification_keys`, so the
  original keystore is **preserved byte for byte** — it is hashed in memory
  before and after the export and the run reports
  `source keystore unchanged: yes`;
* **refuses an output inside this repository or inside any Git work tree**, and
  refuses a file that already exists (`O_CREAT|O_EXCL`), so it can never
  overwrite the keystore or a previous secret;
* writes JSON with exactly `key_id` and `seed_b64` (base64 of the 32-byte
  seed), requests mode `0600` where the platform honours it, flushes and
  `fsync`s, then re-reads the new file to validate it without printing any
  value;
* prints only the key id, the output path and whether the keystore stayed
  unchanged — never the seed, the JSON or a `repr()` of the key record. On
  failure it exits `2` with a one-line reason and removes only the file it had
  just created.

Mount the resulting file read-only at `/etc/secrets/LICENSE_API_SIGNING_SECRET`
(§3 above). **The private seed must never be shared or committed:** no chat, no
build argument, no image layer, no repository file — the offline keystore stays
the only source of truth, and it must be kept (and backed up) as-is. Note that
`0600` on a POSIX host is not readable by the container's runtime user (uid
10001), so grant read access at mount time instead of loosening the file.

---

## 4. Public build arguments (dashboard image)

Next.js inlines `NEXT_PUBLIC_*` at build time, so these must be build arguments:

| Build argument | Required | Notes |
|---|---|---|
| `NEXT_PUBLIC_FIREBASE_API_KEY` | yes | staging web app key (public) |
| `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | yes | `klickpos-license-free-8029b.firebaseapp.com` |
| `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | yes | `klickpos-license-free-8029b` |
| `NEXT_PUBLIC_FIREBASE_APP_ID` | yes | staging web app id (public) |
| `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | recommended | staging project number |
| `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | optional | no code path uses Storage today |
| `NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY` | deferred | only after App Check registration (§5) |
| `NEXT_PUBLIC_FIREBASE_APPCHECK_DEBUG_TOKEN` | must be empty | a baked debug token bypasses App Check |
| `NEXT_PUBLIC_FIREBASE_AUTH_EMULATOR_HOST` | must be empty | accepts unsigned emulator tokens |
| `NEXT_PUBLIC_API_BASE_URL` | leave empty | legacy build-time fallback; the runtime `LICENSE_API_BASE_URL` is used instead |

`npm run build` runs `prebuild` → `scripts/public-build-env.mjs`, which fails
the build (exit 1) when a required value is missing or a development-only switch
is set. `LICENSE_DASHBOARD_ALLOW_DEVELOPMENT_SWITCHES=1` is the deliberate,
loud local-build escape hatch and must never be used for an image.

**Nothing else may be a build argument.** Signing seeds, AES keys,
service-account JSON and Secret Manager values never appear on a build command
line: build arguments are recorded in the image history.

---

## 5. Why App Check stays disabled in staging

1. App Check registration needs the dashboard's origin, and the Render hostname
   does not exist until the service does. Registering early would create a key
   for a hostname that never serves traffic.
2. `NEXT_PUBLIC_FIREBASE_APPCHECK_SITE_KEY` is a **build** argument. It cannot be
   filled in after the image exists, so enabling App Check means one more image
   build — not a variables-only change.
3. The API only verifies App Check when `LICENSE_API_REQUIRE_APP_CHECK=1`. With
   it on and no token-sending dashboard deployed, **every** administrator gets
   `401 app_check_failed`.
4. With it off, nothing is weakened that was not already the design: Firestore
   rules deny all client access, the ID token is verified with revocation
   checking, and the allowlist is enforced per request. App Check is defence in
   depth against a stolen ID token, not the authentication mechanism.

Order when the hostname is known: add it to Authentication → Authorized domains
→ register the web app with reCAPTCHA Enterprise (a key for that hostname, plus
`localhost` for local testing) → put the site key in the build arguments →
rebuild → watch App Check metrics until requests verify → only then set
`LICENSE_API_REQUIRE_APP_CHECK=1` and `LICENSE_API_APP_CHECK_AUDIENCE=<project
number>` and restart the API.

reCAPTCHA Enterprise is usable on Spark: 10,000 assessments per month at no
cost; Spark only limits the configurable score levels.

---

## 6. Firestore `(default)`

The staging database is the default native database (`(default)`, `eur3`).
`LICENSE_API_FIRESTORE_DATABASE` must therefore stay **empty**:
`service/firestore_repository.py::connect` passes a `database=` argument only
when the value is non-empty, and the Admin SDK client then uses `(default)`.

---

## 7. Staging vs production matrix

| Setting | Staging (Render Free) | Production (Cloud Run) |
|---|---|---|
| Project | `klickpos-license-free-8029b` | `klickpos-license-manager` (unchanged) |
| Plan | Firebase Spark | as deployed today |
| Firestore | `(default)`, `eur3`, Native | production database (unchanged) |
| `LICENSE_API_ENV` | `production` | `production` |
| Secret source | `file` (`/etc/secrets`) | `secretmanager` (default) |
| Secret versions | ignored by the file source | pinned explicit versions |
| Google identity | mounted service-account JSON via `GOOGLE_APPLICATION_CREDENTIALS` | runtime service account (ADC) |
| Service-to-service auth | none (loopback only) | Cloud Run invoker + OIDC audience |
| `LICENSE_API_REQUIRE_CLOUD_RUN_INVOKER` | `0` | `1` |
| `LICENSE_DASHBOARD_API_AUDIENCE` | empty | the API's Cloud Run URL |
| Proxy target | `LICENSE_API_BASE_URL=http://127.0.0.1:8000` | same variable, the API URL |
| `LICENSE_API_TRUST_PROXY` | `0` | `1` |
| `LICENSE_API_REQUIRE_APP_CHECK` | `0` until verified | `1` after staging proves it |
| Keys | throwaway Ed25519 keypair + fresh AES key, staging-only | production material, unchanged |
| Image | `license_manager/Dockerfile.render`, context `new_app/` (§10) | `license_manager/Dockerfile` + `dashboard/Dockerfile` |
| Health-check path | `/healthz` (dashboard route; 200 only when the API answers too) | Cloud Run startup probe on the API's `/healthz` |
| Verification keys file | `deploy/staging/verification_keys.staging.json` (in image, `LICENSE_API_REQUIRE_STAGING_KEYS=1`) | `backend/app/licensing/verification_keys.json` (in image, flag off) |
| Seed ↔ published key match | `LICENSE_API_REQUIRE_SIGNING_KEY_MATCH=1` (startup, constant time) | off — no change |
| Admins | staging uid/email (new uid per project) | production allowlist, unchanged |
| `LICENSE_API_SECRET_SOURCE` unset | — | means `secretmanager`: no production change required |

Using `LICENSE_API_ENV=production` in staging is deliberate: it exercises the
real fail-closed guards (no dev seeds, no emulator variables, pinned `aud`/`iss`,
required secret names) instead of a configuration that only works because the
guards are off.

---

## 8. Safe migration sequence (future phases, nothing executed)

| # | Step | Gate |
|---|---|---|
| 1 | Add the Render hostname to Authentication → Authorized domains | Console change |
| 2 | Create staging-only Ed25519 keypair + AES key and a least-privilege service account (`roles/datastore.user`, Firebase Auth viewer), mounted as files; publish the public half into `deploy/staging/verification_keys.staging.json` (done: `stg-2026-11`) | Phase 8.4, separate approval |
| 3 | Build the combined image with the public build arguments (`docker build -f license_manager/Dockerfile.render … new_app`, §10); verify `/healthz` and that `/v1/overview` answers `401` without a token | local build + smoke |
| 4 | Deploy to Render with `deploy/staging.env.template` values; confirm the API port is not published | Phase 8.7, separate approval |
| 5 | Sign in once, copy the staging uid, set the allowlist, restart | Console read + env change |
| 6 | Deploy `firebase/firestore:rules` to the staging project | separate approval |
| 7 | Issue one staging test license end to end; confirm the document and audit event land in staging Firestore | functional check |
| 8 | Register App Check, rebuild with the site key, verify tokens, then enable enforcement | last, reversible |

### Combined Dockerfile (Phase 8.5)

`license_manager/Dockerfile.render` builds the staging container. It is a
multi-stage build whose **context is `new_app/`** (the API imports
`backend/app` read-only):

```bash
docker build -f license_manager/Dockerfile.render \
  --build-arg NEXT_PUBLIC_FIREBASE_API_KEY=… \
  --build-arg NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=klickpos-license-free-8029b.firebaseapp.com \
  --build-arg NEXT_PUBLIC_FIREBASE_PROJECT_ID=klickpos-license-free-8029b \
  --build-arg NEXT_PUBLIC_FIREBASE_APP_ID=… \
  -t klickpos-license-staging:local new_app
```

| Stage | Purpose |
|---|---|
| `python-deps` (`python:3.12.11-slim-bookworm`) | installs `requirements-runtime.txt` only — no test tooling |
| `dashboard-deps` / `dashboard-build` (`node:22.20.0-bookworm-slim`) | `npm ci` from the lockfile, then `next build` with the public Firebase build arguments; produces the standalone output |
| `runtime` (the Python image + only the `node` binary) | both processes, non-root (uid 10001), no npm/pip |

Runtime layout (all paths the service already expects):

| Path | Content |
|---|---|
| `/app/backend/app`, `/app/backend/tools` | the licensing contract, read-only |
| `/app/license_manager/service` | the API |
| `/app/license_manager/deploy/staging/` | staging **public** verification keys only |
| `/app/license_manager/scripts/render_startup_check.py` | fail-closed configuration check |
| `/app/license_manager/deploy/render/entrypoint.sh` | process supervisor (PID 1) |
| `/app/dashboard` | Next.js standalone server + static assets |

`Dockerfile.render.dockerignore` keeps credentials, `.env` files, keystores,
`node_modules`, host build output, tests and the unrelated POS sources out of
the build context. It also excludes the **production** key files
(`backend/app/licensing/verification_keys.json`, `release_metadata.json`), so
the staging image cannot even accidentally carry them.

Startup sequence (`entrypoint.sh`):

1. `render_startup_check.py` validates the configuration **before** anything
   listens: the staging key file and its published id, the signing seed
   (and, with `LICENSE_API_REQUIRE_SIGNING_KEY_MATCH=1`, that it matches the
   published key), and the AES-256-GCM key (32 bytes, seal/open round trip).
   Any failure exits non-zero, so Render fails the deploy instead of serving a
   broken instance.
2. uvicorn starts on `127.0.0.1:8000`; the supervisor polls its `/healthz`
   (up to 30 s) and refuses to continue if it does not answer.
3. Next starts on `0.0.0.0:$PORT`. `/healthz` on the public port proxies the
   API's own health, so Render's health check cannot pass while the API is
   down.
4. `wait -n` supervises both: whichever exits first stops the other and the
   container exits non-zero. `SIGTERM`/`SIGINT` are forwarded to both and
   reaped, so no orphan keeps the port.

Build arguments are **public only**. Never pass a seed, AES key,
service-account JSON or Secret Manager value as a build argument: build
arguments are recorded in the image history.

---

## 9. Known gaps

* The combined image and its supervisor exist (Phase 8.5), but the RSS
  measurement under load has **not** been taken yet. Render Free gives 512 MB
  and both processes live in the same cgroup; measure before relying on the
  free plan.
* No staging service account exists yet, so `GOOGLE_APPLICATION_CREDENTIALS`
  cannot be exercised: the file-backed secret path is covered by tests, the
  Google credential path is not.
* `FirebaseTokenVerifier` still needs the Firebase Auth user lookup permission
  (`check_revoked=True`); the staging service account must be granted the
  viewer role for it, or every request answers `401`.
* Firestore rules must be deployed to the new project before the first write.
