# Security review — Phase 6 (Cloud Run readiness), updated in Phase 6.9

Scope: the License Manager only (`new_app/license_manager/`). No KlickPOS POS
code, no SMP1 v1 contract change, no cloud resource created, no IAM role granted,
no production Firestore document written.

Status vocabulary: **PASS** (verified here), **FAIL** (verified broken),
**BLOCKED** (needs external setup), **NOT TESTED**.

---

## 1. Verified controls

| # | Control | Where | Verified by | Status |
|---|---|---|---|---|
| 1 | Firebase ID token verified with `check_revoked=True` | `service/auth.py` | `tests/test_firebase_verifier.py` (stubbed SDK) + Phase 5 live token against the real project | PASS |
| 2 | Token project pinning (`aud` **and** `iss`) | `service/auth.py::_assert_bound_to_project` | `tests/test_firebase_verifier.py` | PASS |
| 3 | Administrator allowlist, fail-closed when empty | `service/auth.py::_is_allowlisted`, `Settings.allowlist_is_empty` | `tests/test_auth.py`, `tests/test_dev_auth.py` | PASS |
| 4 | Cloud Run service identity: audience + caller SA pinned | `service/cloud_run.py` | `tests/test_service_identity.py` (15 tests) | PASS |
| 5 | Service gate runs **before** the Firebase gate | `service/api.py::_actor` | `test_the_service_identity_is_checked_before_the_firebase_token` | PASS |
| 6 | Browser cannot inject the service header | `app/api/license/[...path]/route.ts` (allow-list of forwarded headers) | `tests/proxy.test.ts` — "ignores a service identity header sent by the browser" | PASS |
| 7 | Service token never reaches a browser bundle | `lib/server-identity.ts` is imported only by the route handler; no `NEXT_PUBLIC_` prefix | `tests/proxy.test.ts`, `tests/server-identity.test.ts` | PASS |
| 8 | Proxy fails closed when its identity is unavailable | route handler → `503 service_identity_unavailable`, API never contacted | `tests/proxy.test.ts` | PASS |
| 9 | Proxy never caches | `cache-control: no-store` on every response | `tests/proxy.test.ts`, `tests/api.test.ts` | PASS |
| 10 | Development auth/keys refused in production | `Settings.__post_init__`, `EnvironmentSecretFetcher`, `FirebaseTokenVerifier.__init__`, `FirestoreLicenseRepository.connect` | `tests/test_environment_guards.py`, `tests/test_service_identity.py` | PASS |
| 11 | Emulator variables refused in production | same | `tests/test_environment_guards.py` | PASS |
| 12 | Duplicate prevention inside a Firestore transaction | `service/firestore_repository.py` | `tests/test_duplicates.py`, `tests/test_firestore_emulator.py` (5 concurrent threads → 1 license) | PASS |
| 13 | Activation code stored only as AES-256-GCM envelope bound to the license id | `service/crypto.py` | `tests/test_firestore_emulator.py` (no `SMP1` in the stored field) | PASS |
| 14 | Lists never decrypt activation codes | `_license_summary_from_doc` | emulator test "listings do not decrypt" | PASS |
| 15 | Code retrieval is audited | `service/service.py::get_code` → `activation_code_viewed` | emulator end-to-end test | PASS |
| 16 | Ed25519 issuance re-verified with the customer verifier + signer public half | `service/signing.py` | `tests/test_compatibility.py`, `tests/test_issue.py` | PASS |
| 17 | Signing refused unless the key id is in the packaged customer keys | `LicenseIssuer.issue` | `tests/test_signing_keys.py` | PASS |
| 18 | Request body cap before parsing | `service/limits.py::BodyLimitMiddleware` | `tests/test_limits.py` | PASS |
| 19 | Per-administrator rate limits | `service/limits.py` | `tests/test_limits.py` | PASS |
| 20 | Forwarded client address only when the proxy is trusted | `api.py::_client_ip` | `tests/test_client_ip.py` | PASS |
| 21 | No CORS middleware (same-origin only) | `service/api.py` | reviewed; proxy tests exercise the same-origin path | PASS |
| 22 | Errors carry a stable code, never a provider message | `service/errors.py`, handlers | `tests/test_auth.py`, `tests/api.test.ts` | PASS |
| 23 | No secret/token/code in logs | reviewed `api.py`, `auth.py`, `secrets.py`, `service.py`; `tests/api.test.ts` "never logs the activation code" | PASS (code review + test) |
| 24 | JSON logs opt-in only | `service/cloud_logging.py` | `tests/test_cloud_logging.py` | PASS |
| 25 | Containers run non-root, without secrets or ADC files | `Dockerfile`, `dashboard/Dockerfile`, ignore files | both images built and inspected: UID 10001, no `.env`/ADC/key files (Phase 6.8.2–6.9) | PASS |
| 26 | App Check token verified **server-side** with the Admin SDK and pinned to the Firebase project (`aud = projects/<number>`) | `service/auth.py::_assert_app_check_project` | `tests/test_app_check.py` (11 tests) | PASS |
| 27 | The dashboard sends an App Check token but never treats it as proof; no token is fabricated on failure | `dashboard/lib/app-check.ts`, `dashboard/lib/api.ts` | `dashboard/tests/app-check.test.ts`, `dashboard/tests/api.test.ts` | PASS |
| 28 | App Check can never replace the ID token or the allowlist | `service/auth.py::authenticate_admin` | `tests/test_auth.py` (valid App Check without ID token → 401; stranger → 403) | PASS |
| 29 | Production refuses App Check enforcement without a pinned audience | `service/settings.py::__post_init__` | `tests/test_app_check.py` | PASS |
| 30 | Firestore queries use the supported `filter=FieldFilter(...)` API | `service/firestore_repository.py` | `tests/test_firestore_filters.py`; the in-process fake **rejects** the deprecated positional form | PASS |

---

## 2. Findings and residual risks

| # | Finding | Severity | Status | Recommended action |
|---|---|---|---|---|
| R1 | Both images are **built and smoke-tested**, and both were **scanned** with Docker Scout in Phase 6.8.2 (see §5). Findings are all upstream (base OS, npm's bundled CLI, Next's own postcss) with **no fixed version available**; re-running the scan is required after every rebuild. | Low | PASS (build + scan) | Re-scan on each rebuild; track the openssl/zlib advisories and rebuild when Alpine/Debian publish fixes. |
| R2 | Rate limiting is **per instance** (in-memory). With `--max-instances=10` the effective limit is up to 10× the configured value. | Low | NOT TESTED | Keep `max-instances` modest; add a shared limiter (e.g. Firestore/Redis counter) only if abuse is observed. Documented, not silently ignored. |
| R3 | App Check is **implemented on both sides** (client token via reCAPTCHA Enterprise, server verification with project pinning) but **not enforced**: `LICENSE_API_REQUIRE_APP_CHECK=0`. Enforcing before the Console provider exists and a token-sending dashboard is deployed would lock out every administrator. | Medium | BLOCKED (Console setup only) | Register the provider/site key in staging, verify traffic, then set the flag — §6.3 of `cloud-run.md`. |
| R4 | Firestore security rules (`firebase/firestore.rules`, deny-all) are **not deployed**. The Admin SDK bypasses rules, so this does not affect the API, but any other client (or a console-created database with relaxed rules) would be exposed. | Medium | BLOCKED | `firebase deploy --only firestore:rules` before go-live; verify in the console that rules are the deny-all file. |
| R5 | The proxy has no explicit upstream timeout. A hung API call holds the request until Cloud Run's timeout (30s configured for the dashboard). | Low | NOT TESTED | Acceptable with the configured request timeout; add `AbortSignal.timeout()` to the proxy's `fetch` if you want a faster, controlled 504. |
| R6 | A missing signing secret or Firestore answers `503`; a missing *credential* answers `401`, which the dashboard renders as "Your session has expired. Please sign in again." A signed-in administrator can therefore be told to sign in when the real problem is server-side configuration. | Low | PASS (documented) | Pre-existing, deliberate error-contract decision. If it becomes confusing, map `503` before `401` in the dashboard copy — do not change the API contract. |
| R7 | `/healthz` discloses `environment` (`development` / `production`). | Info | PASS | Harmless: no data, no version, no config. Keep it. |
| R8 | No CSP header (documented rationale: Firebase Auth origins). `X-Frame-Options: DENY`, `nosniff`, `no-referrer`, `Permissions-Policy` are set. | Low | PASS | Add a CSP with an explicit `connect-src`/`frame-src` for Firebase Auth in a later hardening pass; test sign-in before enabling. |
| R9 | A personal ADC account (`islemze2@gmail.com`) was used to *verify the integration* in Phase 5. It must never become a runtime identity. | High if misused | PASS for Phase 6 (no runtime uses it) | Provision the dedicated runtime SAs (§3 of `cloud-run.md`); never mount ADC into a container. |
| R10 | Service-to-service verification is defence in depth **on top of** Cloud Run IAM. If an operator deploys Service A with `--allow-unauthenticated`, the in-process gate still holds (401/403) — but the service is publicly reachable and the browser could reach it directly (it would still need a valid Firebase token). | Medium | NOT TESTED (no deployment) | Never deploy A with `--allow-unauthenticated`; the checklist requires an unauthenticated `curl` to fail at the edge. |
| R11 | Cloud Run's `X-Serverless-Authorization` header is consumed at the edge and is not visible to the app, which is why the app verifies its own dedicated header instead. If Cloud Run's behaviour changes, the in-process check would see no token and answer `401 service_identity_required` — fail-closed, not fail-open. | Info | PASS | None; re-verify after any Cloud Run runtime upgrade. |
| R12 | `LICENSE_API_TRUST_PROXY=1` is correct **only** behind Cloud Run's front end. Setting it on a laptop would let a caller forge the audit-trail address. | Low | PASS (env template is deployment-specific) | Keep the template comment; never copy the Cloud Run env file to a local run. |

---

## 3. Things this review did **not** test

* Real Cloud Run: ingress, IAM edge rejection, metadata-server token minting,
  cold starts, concurrency behaviour, request timeout enforcement.
* Real Secret Manager read **by the runtime service account** (Phase 5 read
  secret material only through a personal ADC-backed development path).
* Real Firestore writes of any kind (production database untouched, staging
  project does not exist yet).
* Google OIDC token verification against *real* Google certificates — the
  verifier is tested with a stubbed `verify_oauth2_token`; the real call is
  exercised only in Cloud Run.
* App Check against the real reCAPTCHA/Firebase service: the client and the
  server verification are implemented and unit-tested, but no real App Check
  token has been minted yet (no Console configuration in this phase).
* Container vulnerability scanning and image build.
* Backup/restore of Firestore and of the secrets.

---

## 4. Container image scan results (Phase 6.8.2, API refreshed 6.8.3, dashboard hardened 6.9)

Tool: Docker Scout v1.24.0, `docker scout cves <image> --only-severity critical,high,medium`.
"Not fixed" means Scout's advisory data lists no fixed version; it does **not**
mean the finding is harmless.

### `klickpos-license-api:local` — 0 critical / 8 high / 12 medium

Phase 6.8.3 rebuilt this image from a runtime-only dependency set: the image
installs `requirements-runtime.txt` (test tooling lives only in
`requirements.txt`) and removes `pip` from the runtime layer. Before the change
the same scan reported 0C/8H/17M in 5 packages; the 5 dropped MEDIUM findings
were all `pip` 25.0.1. Every remaining finding is in the **base image**
(`python:3.12-slim`), so the application still adds none of its own.

| Severity | Package | Findings | Fixed version |
|---|---|---|---|
| HIGH | openssl 3.5.7-1~deb13u3 | 4 | not fixed |
| HIGH | glibc 2.41-12+deb13u4 | 2 | not fixed |
| HIGH | zlib 1.3.dfsg.1-1 | 2 | not fixed |
| MEDIUM | glibc | 9 | not fixed |
| MEDIUM | openssl | 2 | not fixed |
| MEDIUM | tar 1.35+dfsg-3.1 | 1 | not fixed |

`pytest`, `pluggy` and `iniconfig` are gone from the image. `httpx` is still
present but is **not** test-only: `firebase-admin` 7.8.0 requires
`httpx[http2]==0.28.1` directly.

### `klickpos-license-dashboard:local` — 0 critical / 3 high / 2 medium

Phase 6.9 removed the CRITICAL. The base image stays `node:22-alpine`
(maintained, smallest supported Next.js standalone target); the Dockerfile now
runs `apk upgrade` in the runtime stage, which installs **zlib 1.4-r0** — the
published fix for CVE-2026-4738 (`<1.4-r0`) — together with openssl 3.5.9-r1
(which fixes the 4 HIGH openssl findings). npm / npx / corepack / yarn were also
removed from the runtime filesystem: they are build tools the container never
executes, and their bundled tree carried 11 HIGH + 12 MEDIUM findings.

| Severity | Package | Findings | Where | Fixed version |
|---|---|---|---|---|
| HIGH | postcss 8.4.31 | 2 | **our runtime tree** (`/app/node_modules/next/node_modules/postcss`, bundled by Next) | not fixed (Next pins it) |
| HIGH | musl 1.2.6-r3 | 1 | alpine base (no newer musl in 3.24) | not fixed |
| MEDIUM | postcss 8.4.31 | 2 | same | not fixed |

Before → after: 1C/17H/15M (27 findings, 12 packages) → **0C/3H/2M** (5 findings,
2 packages). The two remaining packages are upstream (Alpine's musl) or shipped
by Next itself; neither has a fixed version available to this project.

Image size: 325 MB → **334 MB**. The `apk upgrade` adds the patched packages, and
removing npm only adds a whiteout layer (Docker layers are additive, so size does
not shrink); the win is attack surface and findings, not bytes.

Mitigations that follow from this:

* no npm/npx/corepack/yarn in the runtime image at all, so no package manager
  can be used from a compromised container;
* `postcss` is only reachable through Next's own build/runtime plumbing and
  depends on an upstream Next release — re-scan after every Next upgrade;
* no compiler or shell toolchain beyond the base image's own busybox.

## 5. Conclusion

The design is fail-closed at every layer that this phase could implement and
test: no token → 401; wrong project → 401; not allowlisted → 403; not the
dashboard's service account → 403; misconfigured deployment → refuses to start.
The remaining risks are **operational** (App Check Console configuration and
enforcement timing, Firestore rules deployment, dedicated runtime identities,
staging validation) and are listed, not hidden. Nothing here justifies calling the project production-ready on its own.
