# Public verification keys (`verification_keys.json`)

**What this file is:** the packaged set of *public* Ed25519 keys the
Supermarket Pro backend uses to verify signed Lifetime activation codes
(Phase L2-A, §10.1).

**What it is not:** customer state, a secret, or a place for private key
material. It is never written at runtime, never stored in
`LICENSE_STATE_DIR`, never included in a PostgreSQL dump and never
included in a backup archive.

## Format

A flat JSON object mapping a key id to the base64 encoding of exactly 32
raw public-key bytes (RFC 8032 Ed25519):

```json
{
  "k1": "<standard base64 of exactly 32 raw bytes>",
  "k2": "..."
}
```

* Key ids match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`.
* Any key id may be referenced by an activation code; an unknown id makes
  the code fail closed (`403 license_invalid_key`).
* Duplicate ids, non-object top level, invalid base64 or a wrong key
  length make the whole file unreadable (`VerificationKeysError`), which
  the LicenseManager turns into a fail-closed 503 — a broken key file
  never authorizes anything.
* A **missing or empty** file (the shipped state: `{}`) means "no keys
  shipped yet": every activation attempt fails closed. It is impossible
  for an empty file to authorize a license.

## Production provisioning (release process)

1. The offline **License Generator** (`new_app/backend/tools/license_generator`,
   Phase L2-D) is the only component that ever holds a private signing
   key. Keystores live outside every git work tree on the owner's
   machine; the tool refuses to run inside one. Operations, backup and
   rotation are covered in `docs/LICENSE_GENERATOR_OPERATIONS.md`.
2. Create the key **explicitly** (never implicitly, never from a build):

   ```
   python -m tools.license_generator keygen --key-id k1 --key-dir <keystore outside the repo>
   ```
3. Publish it and record the release in one owner-side pass:

   ```
   python -m tools.license_generator provision-release \
       --key-id k1 \
       --keys-out     app/licensing/verification_keys.json \
       --metadata-out app/licensing/release_metadata.json \
       --key-dir <keystore>
   ```

   `provision-release` only **reads** the keystore (an unknown id is an
   error, so a key can never be created implicitly), merges the public
   entry additively — an existing id keeps its exact value — and writes
   `release_metadata.json`, which records the `sha256:` fingerprint of
   every shipped public key so "what did we ship?" can be answered and
   re-verified later (`app/licensing/release_metadata.py`). Both files
   are re-validated through the backend's own loaders before the pass
   returns, and `--dry-run` performs every check while writing nothing.
   See `docs/R4_PRODUCTION_LICENSING.md` §2.
4. The private half stays with the owner/Generator. It is never placed in
   `.env`, in configuration, in PostgreSQL, in the StateStore, in this
   repository, in tests, or in any customer file.
5. Tests generate throwaway keypairs in-process
   (`Ed25519PrivateKey.generate()` or `keygen` into `tmp_path`) and point
   `LICENSE_VERIFICATION_KEYS_FILE` at a temporary copy — no test ever
   uses production key material.

## Rotation / retention

* **Never remove a key id while any issued license still references
  it** — existing licenses would stop verifying and their installs would
  report no license (fail closed). Add new ids for new keys; retiring an
  id is only safe once no supported license uses it.
* Adding a key id is backwards compatible: old licenses keep verifying
  against their own ids, and `provision-release` records the new id
  alongside the old ones.
* This file is part of the application package: it is updated by the
  release process, not by the running application.

## Why an empty file ships

The License Generator now exists (L2-D), but no **production** key has
been generated in this checkout: key generation is an explicit owner
action on an offline machine, never part of a build. Shipping `{}` keeps
the verification path real (loader, validation and fail-closed behaviour
are all exercised) while making it structurally impossible for a build
to accept a forged license. The first production provisioning replaces
`{}` with the exported public entry of the owner's first key id.
