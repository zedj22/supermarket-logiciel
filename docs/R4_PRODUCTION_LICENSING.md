# R4 - Production Licensing Provisioning

R1 gave every installation its own writable data root, R2 gave it a real
Windows runtime with per-install secrets, and R3 gave it PostgreSQL
provisioning with a separated database credential. R4 closes the loop on
**licensing in production**: the backend can no longer start in
production with licensing silently disabled, the owner has one command
that publishes public verification keys and records what was shipped,
the customer package boundary is written down and enforced, and the
activation path is proven end to end with a test key.

R4 touches **no** licence format, fingerprint, trial, guard or
verification contract. `SMP1`/`SMPr1`, Ed25519, the 10-day trial, the
fingerprinting rules, Backup Manifest v2 and every error code keep their
existing behaviour; only *how configuration, packaging and provisioning
are wired* changed.

---

## 1. Production enforcement (§3)

`LICENSE_ENFORCEMENT` keeps its three modes and its exact semantics
(`app/licensing/guard.py`, read **per request**):

| Mode | Meaning |
| --- | --- |
| `off` | Complete no-op: no request altered, no state read, no error (L0). |
| `trial` | Free Trial engine (Phase L1). A Lifetime licence is **never** consulted in this mode. |
| `on` | Phase L2-B combined decision: a valid Lifetime licence **or** an active trial admits business routes. |

What R4 adds is a **production default** in `app/core/config.py`:

```python
@model_validator(mode="after")
def _production_enforcement_default(self) -> Settings:
    if (
        self.APP_ENV == "production"
        and "LICENSE_ENFORCEMENT" not in self.model_fields_set
    ):
        self.LICENSE_ENFORCEMENT = "trial"
    return self
```

* `APP_ENV=production` **and no value supplied** (no env var, no
  `config/.env` entry, no constructor argument) → `trial`, never `off`.
* An **explicit** value is always honoured, including an explicit `off`
  (a legitimate owner/QA decision).
* A **blank** or **unknown** value never reaches the fallback: the
  existing `Literal["off", "trial", "on"]` rejects it at startup with a
  `ValidationError` — a misconfiguration fails closed, it does not
  silently disable licensing.
* `model_fields_set` is exactly the "was it supplied?" test:
  pydantic-settings records a field there only when the environment, the
  dotenv file or the caller actually provided it. Verified both ways in
  `tests/unit/test_production_enforcement_config.py`.
* Development and testing keep the historical default `off`, so the
  guard stays a no-op for developers until they opt in.

Because `guard.py` reads the setting per request, a configuration change
is picked up without rebuilding the application.

### The startup warning

`app/main.py` logs one structured warning when production is running
with enforcement deliberately off:

```
license_enforcement_disabled_in_production enforcement=off
  hint='set LICENSE_ENFORCEMENT=trial (Free Trial) or on (Lifetime or Free Trial) in <DATA_DIR>/config/.env'
```

It fires **only** under `APP_ENV=production`; development never warns.
The warning is additive — it does not change any response, status code
or guard behaviour.

### `trial` versus the audit's Phase L5 target

The R4 brief mandates the installer template default `trial`, while
`docs/LICENSING_SYSTEM_ARCHITECTURE_AUDIT_v2.md` Phase L5 targets `on`
at installer time. Both are recorded here deliberately:

* `trial` is the **conservative** default: the Free Trial engine is
  fully active from the first start, and nothing about a Lifetime
  licence can be misread as granted.
* `on` is what a **billing release** ships with, because in `trial`
  mode a Lifetime licence is never consulted (frozen Phase L1
  semantics) — activation and persistence still work, but the licence
  does not open business routes until the mode is raised.
* The template therefore documents both and ships `trial`; raising it to
  `on` is a one-line change in `<DATA_DIR>/config/.env` when the owner
  starts billing.

Nothing in R4 changes the meaning of either mode.

### The template: `production.env.example`

A new, comment-heavy template for the installer-written
`<DATA_DIR>/config/.env` (development keeps using `.env` exactly as
before). It sets `APP_ENV=production`, `LICENSE_ENFORCEMENT=trial`,
`TRIAL_DAYS=10`, leaves `LICENSE_STATE_DIR`/`LICENSE_VERIFICATION_KEYS_FILE`
empty (auto-resolved under `DATA_DIR` / the packaged key file), and
**contains no secret values at all**: `APP_SECRET_KEY` and
`JWT_SECRET_KEY` come from R2's `secrets.env` via the launcher, and the
database password comes from R3's `database.env`.

---

## 2. Release provisioning (§2)

One owner-side command publishes a public key and records the release:

```
python -m tools.license_generator keygen --key-id k1 --key-dir <keystore outside the repo>
python -m tools.license_generator provision-release \
    --key-id k1 \
    --keys-out    app/licensing/verification_keys.json \
    --metadata-out app/licensing/release_metadata.json \
    --key-dir <keystore>
```

Implemented by `tools/license_generator/release.py::provision_release`
plus the `provision-release` CLI subcommand. The pass is deliberately
narrow:

* **Keys are only read.** An id that does not already exist fails with
  `KeystoreError`; this command can never generate a key implicitly.
  `keygen --key-id …` stays the only way to create one.
* **Everything is pre-checked before anything is written**: unknown id,
  a conflicting public key for an id already shipped, an untrusted
  target file, a release record that names a key the package does not
  carry, and a recorded fingerprint that no longer matches. A refusal
  leaves both files byte-identical.
* **Merge is additive** through the existing, tested
  `keystore.merge_verification_keys`, so a previously shipped id keeps
  its exact value.
* **Both files are re-validated** through the backend's own loaders
  before the function returns, and the pair is cross-checked strictly.
* **No private half is ever read, printed or copied** — the only input
  used from the keystore is `StoredKey.public`.
* `--dry-run` performs every check and writes nothing.

### The release record: `release_metadata.json`

`app/licensing/release_metadata.py` (shipped) + the packaged
`app/licensing/release_metadata.json`:

```json
{
  "format": "supermarket-pro/release-keys",
  "version": 1,
  "keys": { "k1": "sha256:<64 lowercase hex>" }
}
```

The fingerprint is `sha256:` over the raw 32 public bytes — a stable,
standard digest an operator can recompute from the shipped key file
with no tooling. It is public information: it cannot derive the private
key.

* A **missing** file means "no release recorded yet" and loads as `{}`.
* A **malformed** file raises `ReleaseMetadataError` — a corrupted
  install is never silently read as "no metadata".
* `validate_release_metadata(keys, metadata, strict=True)` fails on a
  recorded id that is not shipped, on a fingerprint that does not
  match, and (strict) on a shipped id that was never recorded.
* Nothing at runtime writes this file; provisioning is an explicit
  owner-side operation.

---

## 3. Customer package boundary (§4)

`new_app/backend/customer_package.json` is the written definition of
what a customer receives. The application never reads it; it is a
release-engineering contract enforced by
`tests/unit/test_customer_package_boundary.py`.

**Shipped roots:** `app/` (the backend Python package — `pyproject.toml`
packages only `app*`) and `../lib/` (the Flutter sources), plus the
runtime files the installer copies (`run_production.py`,
`production.env.example`, `winsw/`, `migrations/`, `alembic.ini`,
`pyproject.toml`).

**Shipped licensing surface:** every module under `app/licensing/`,
`app/api/v1/license.py`, `app/core/config.py`, `app/core/secrets.py`,
`verification_keys.json`, `release_metadata.json`,
`verification_keys.README.md`, and the Flutter licensing UI +
localization (`new_app/lib/features/licensing/*.dart`,
`new_app/lib/core/strings.dart`).

**Excluded:** `tools/` (the whole owner-only Generator, including
`signing_keystore.json` and `issuance_log.jsonl`), `tests/`,
`../test/` (developer Flutter tests), `.env`, `data/`, `__pycache__/`,
and every `*.key` / `*.pem` / `*.p12` / `*.pfx` / `*.jks` / `*.der` /
`*.crt`.

**Forbidden content in any shipped file:** `-----BEGIN` (PEM),
`"private":` (keystore JSON shape), `private_seed`,
`signing_keystore.json`, `issuance_log.jsonl`.

Two structural guarantees back the content scan:

* `find_packages(include=["app*"])` ships **only** the `app` tree —
  `tools.license_generator` exists in the source tree but never in the
  distribution;
* no module under `app/` imports `tools` — the running backend cannot
  reach private-key code even by accident.

The one legitimate private-key construction inside the package is
`app/services/backup_manifest.py`, which builds an Ed25519 key from the
**per-install backup signing key** held in `<DATA_DIR>`; that key is
generated at runtime and never appears in the package, which is why it
is documented rather than forbidden.

---

## 4. Runtime credentials — the R5 handoff (§5)

Two runtime secret files exist under `<DATA_DIR>/config/`, written by
different functions and read by different code:

| File | Written by | Read by | Contains |
| --- | --- | --- | --- |
| `secrets.env` | `ensure_production_secrets()` (R2) | the production launcher, before `Settings` is constructed | `APP_SECRET_KEY`, `JWT_SECRET_KEY` |
| `database.env` | `ensure_database_password()` (R3) | `load_database_password()` — **wired in R5** | `DATABASE_PASSWORD` |

**The exact handoff R5 must implement:**

1. `run_production.py` keeps generating/loading `secrets.env` first and
   publishing the two application secrets into the process environment
   before importing `Settings` (R2 behaviour, unchanged).
2. R5 then reads `database.env` with `load_database_password(data_dir)`
   and builds the `DATABASE_URL` for the **application role** from it —
   the URL is published to the process environment the same way, so
   `Settings` picks it up through pydantic-settings' normal
   env-over-dotenv precedence.
3. `PG_ADMIN_URL` (the maintenance/superuser credential, R3) is
   supplied only to the provisioning pass as an explicit argument; it
   is never written to `database.env`, never published to the
   application's environment, and never logged.
4. Neither file is read by `app/core/config.py`: the settings layer
   sees only `.env` plus process environment. This boundary is pinned by
   `tests/unit/test_secret_file_separation.py`
   (`test_the_settings_layer_never_reads_database_env`).

**R4 does not wire this.** The brief explicitly excludes the production
launcher from this round, so `run_production.py` still does not consume
`database.env`; R3's `docs/R3_POSTGRESQL_PROVISIONING.md` records the
same gap. R4 only proves the two files stay disjoint and that nothing
in the settings layer can accidentally read the database credential.

> **R5 status:** the handoff is now implemented —
> `run_production.py` calls `load_database_password(data_dir)` and
> publishes the assembled `DATABASE_URL` before `Settings()` is
> imported (exported `DATABASE_URL` still wins, `PG_ADMIN_URL` is never
> read, the URL never reaches the `--check` report). Pinned by
> `tests/unit/test_database_env_handoff.py`.

---

## 5. Activation end to end (§6)

`tests/integration/test_license_activation_e2e.py` walks the whole
customer path over HTTP with a **test** key generated into `tmp_path`
(no production key is ever generated):

1. `POST /api/v1/license/activation-request` on the Main PC returns the
   unsigned `SMPr1` request (and leaks no hardware identifier);
2. the owner issues a Lifetime licence for that request with
   `generator.issue_license(...)` (the owner-side ledger lands in the
   throwaway keystore, not in the package);
3. `POST /api/v1/license/activate` verifies signature + hardware and
   persists → `mode=lifetime`;
4. `GET /api/v1/license/status` reports `lifetime`;
5. a **brand-new** `LicenseManager` and `TestClient` — the state a
   process restart would find on disk — still report `lifetime`, and
   re-activating the same code is an idempotent no-op;
6. the same code issued for *different* hardware →
   `403 license_bound_elsewhere`, nothing written;
7. a licence signed by a key the package does not ship →
   `403 license_invalid_key`;
8. malformed codes → `403 license_invalid` and no licence installed.

No PostgreSQL is involved: the licence routes carry no database
dependency, so this runs everywhere the unit suite runs.

---

## 6. Files added / changed by R4

**Added**

| File | Purpose |
| --- | --- |
| `app/licensing/release_metadata.py` | Release-record loader/writer/validator (shipped). |
| `app/licensing/release_metadata.json` | The shipped release record (currently `{}`). |
| `tools/license_generator/release.py` | `provision_release()` owner-side pass. |
| `customer_package.json` | The customer package definition (§4). |
| `production.env.example` | Production `.env` template (§3). |
| `tests/unit/test_production_enforcement_config.py` | §3. |
| `tests/unit/test_release_provisioning.py` | §2. |
| `tests/unit/test_customer_package_boundary.py` | §4. |
| `tests/unit/test_secret_file_separation.py` | §5. |
| `tests/integration/test_license_activation_e2e.py` | §6. |
| `docs/R4_PRODUCTION_LICENSING.md` | This document. |

**Changed**

| File | Change |
| --- | --- |
| `app/core/config.py` | Production enforcement default (§3); the placeholder warning now uses an ASCII hyphen instead of `—` so subprocess stderr is decodable on a cp1252 Windows console (message only — no behaviour change, all existing `pytest.warns`/substring assertions still match). |
| `app/main.py` | `_warn_if_production_enforcement_is_off()` called from `lifespan` after `start_trial()`. |
| `tools/license_generator/cli.py` | New `provision-release` subcommand + `_cmd_provision_release`. |
| `app/licensing/verification_keys.py` | New public `is_valid_key_id()` (added to `__all__`). |
| `app/licensing/verification_keys.README.md` | Provisioning section now documents `provision-release` and the release record. |

---

## 7. Safety guarantees, as tested

* **Production never defaults to `off`.** Omitted → `trial`; explicit →
  honoured; blank/unknown → `ValidationError`; development → `off`.
* **`off` in production is loud.** One structured warning, only in
  production, with the exact remediation.
* **No production key is generated anywhere in R4** — every test key is
  created in `tmp_path` by `keygen`, and no test writes to
  `app/licensing/verification_keys.json`.
* **Provisioning is read-only w.r.t. keys.** Unknown id → error, and
  the test asserts the keystore gained no entry.
* **A refusal never half-writes.** Unknown id, fingerprint conflict,
  unrecorded-id conflict and a corrupt keys file all leave both output
  files byte-identical.
* **`--dry-run` writes nothing.**
* **Shipped files carry no private material** — content scan across both
  package roots, plus a loader-level assertion that every shipped entry
  is exactly 32 raw public bytes.
* **The Generator never ships** — `find_packages(include=["app*"])` and
  no `app` module imports `tools`.
* **The two runtime secret files stay disjoint** and the settings layer
  reads neither `database.env` nor its contents.
* **Activation fails closed** on wrong hardware, unknown key and
  malformed codes, and never destroys an already-valid licence.

### Deliberately out of scope / known limits

* **No production key is generated** — that stays an explicit owner
  action on an offline machine. This checkout keeps shipping
  `verification_keys.json` = `{}` and `release_metadata.json` = `keys: {}`.
* **No Installer, no production launcher change** — R5 wires
  `database.env` into `run_production.py` (§4) and the installer writes
  `production.env.example`'s values into `<DATA_DIR>/config/.env`.
* **`trial` is the shipped template default, not `on`** — see §1; the
  audit's Phase L5 `on` target is a one-line operator change.
* **No PostgreSQL, Flutter or POS feature changes**; no changes to
  `new_app_upload/`, `new_app_upload.zip`, `tatus`, SMP1/SMPr1 formats,
  Ed25519 contracts, the 10-day trial, fingerprinting or Backup
  Manifest v2.
* **No database is provisioned or modified**, production or test.

---

## 8. Evidence from this machine

| Check | Result |
| --- | --- |
| `ruff check` on every R4-touched file | clean (pre-existing `F401`/`N806` in `app/core/security.py` and `app/core/seed.py` untouched) |
| R4 test files (83 tests) | **83 passed** |
| Licensing / config / secrets / launcher suites (24 files) | **633 passed, 2 skipped** |
| Full backend suite | **3698 passed, 1646 skipped, 17 failed** |
| The 17 failures | all pre-existing stale `HEAD_REV = 'a7c1e9f3b5d2'` assertions in `test_migrations.py`, `test_phase2_facturation_migration.py`, `test_phase6_settings_migration.py` (actual head `e5b7d2c9a41f`) — identical to the R3 baseline, +83 = the new R4 tests |
| `flutter test` (in `new_app`) | **All tests passed** (2913) |
| `provision-release` smoke (subprocess, temp keystore) | `SMOKE OK` — keygen → provision → idempotent → unknown id `rc=2` with byte-identical files → dry run writes nothing → `k2` added preserving `k1` → no private seed in either output |
| Git | HEAD unchanged at `7d634bf`; no commit, push, reset, clean, checkout or stash performed |
| Untouched | `new_app_upload/`, `new_app_upload.zip`, `tatus` (mtimes verified), `new_app/backend/.env` |
