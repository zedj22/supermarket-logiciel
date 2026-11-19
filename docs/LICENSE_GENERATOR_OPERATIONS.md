# License Generator - Operations Manual (Phase L2-D)

The offline License Generator creates Ed25519 keypairs and signs
Lifetime activation codes (`SMP1.…`) for Supermarket Pro installations.
It runs **only on the owner's machine, offline**; it is the single
component that ever holds a private signing key.

Source: `new_app/backend/tools/license_generator/`
Tests: `new_app/backend/tests/unit/test_license_generator.py`
Contract: Phase L2-A (`app/licensing/activation_code.py`) - the
generator imports the same canonical JSON, encoder and verifier, so an
issued code is byte-exact by construction and is self-verified with the
backend verifier before it is printed.

---

## 1. Security boundary (what never happens)

* Private keys exist in exactly one place: `signing_keystore.json`
  inside the keystore directory (see §2). Nowhere else - not in the
  customer application, not in the backend package, not in
  `verification_keys.json`, not in logs, not in issuance records, not
  in any repository file.
* Every command prints **public material only**. Private seeds never
  appear on stdout, stderr, in the issuance ledger or in any export.
* The generator refuses any key directory that sits inside a git work
  tree (a `.git` directory in the path is a hard stop), so a private
  keystore can never be committed by accident.
* `pyproject.toml` packages only `app*`; the `tools/` package is not
  part of the customer distribution (pinned by test).
* Keys are only created by an explicit `keygen --key-id …`. Issuing,
  exporting and listing never generate, replace or delete a key.

## 2. Keystore location and format

Resolution order for the keystore directory:

1. `--key-dir DIR` on the command line,
2. the `SP_LICENSE_GENERATOR_HOME` environment variable,
3. `~/.supermarket-pro/license_generator` (default).

Contents of the directory:

| File | Purpose | Secret? |
| --- | --- | --- |
| `signing_keystore.json` | all keypairs (id, created-at, label, base64 seed, base64 public) | **yes - private** |
| `issuance_log.jsonl` | append-only ledger of issued licenses | no (no hardware hash, no key material) |

* The keystore is written atomically (temp file + rename) with
  best-effort `0600` permissions on POSIX systems.
* On load, every public half is re-derived from its seed; a tampered or
  half-written entry is rejected instead of trusted.
* An existing key id is **never** replaced or deleted - rotation means
  a new id (§5).

## 3. First-time setup

Run from `new_app/backend` with the project virtualenv:

```powershell
.\.venv\Scripts\python.exe -m tools.license_generator keygen --key-id k1 --label "primary"
```

* stdout is the one-key public entry (`{"k1": "<base64>"}`), the only
  thing that ever leaves the owner machine toward a build;
* an existing id fails with exit code 2 - pick a new id, never reuse.
* Optional: `list-keys` shows ids, creation times and public halves.

## 4. Issuing a license (the normal loop)

1. **Customer side (backend, online):** the installation prints its
   activation request `SMPr1.…` (`POST /api/v1/license/activation-request`,
   or the licensing screen in the app).
2. **Owner side (offline):**

   ```powershell
   .\.venv\Scripts\python.exe -m tools.license_generator issue --key-id k1 --request "SMPr1.…"
   ```

   * stdout is the signed `SMP1.…` code and nothing else; a one-line
     summary (license id, key id, issued-at, features) goes to stderr;
   * the request is parsed strictly: wrong prefix/segments/encoding,
     malformed ids or hashes, unsupported version or fields are all
     refused (exit 2) before anything is signed;
   * every code is self-verified with the backend's own verifier before
     it is printed - an unverifiable code is never emitted;
   * `--features pos,inventory` grants features (default `pos`), at most
     32, each `[a-z][a-z0-9_]{0,31}`;
   * a license id is generated per issue (`LIC-<16 hex>`); use
     `--license-id` only when re-issuing deliberately;
   * the issuance is recorded in `issuance_log.jsonl` with license id,
     key id, install id, issued-at and features - never the hardware
     hash.
   * `--request-file FILE` (or `--request-file -` / stdin) reads the
     request from a file or pipe instead.
3. **Customer side:** the code is pasted back into the app/backend
   (`POST /api/v1/license/activate`). It verifies against the public
   key id embedded in the code and binds to that machine's hardware
   hash; a second activation of the same code is idempotent.

## 5. Publishing public keys (provisioning)

```powershell
.\.venv\Scripts\python.exe -m tools.license_generator export-key --key-id k1 --out ..\app\licensing\verification_keys.json
```

* Prints the public entry on stdout; with `--out` it is merged into the
  target file **additively**: existing key ids keep their exact values,
  same id + same value is a no-op, same id + different value is
  refused (exit 2) because issued licenses depend on it.
* The merged file is validated through the backend loader *before* it
  replaces anything, so a bad merge can never corrupt provisioning.
* The updated `verification_keys.json` ships with the next application
  release; the running application never writes it.

## 6. Rotation

1. `keygen --key-id k2` (new id - old ids stay untouched).
2. Issue new licenses with `k2`.
3. `export-key --key-id k2 --out <verification_keys.json>` and ship it
   in a release (old `k1` entry remains - old licenses keep verifying).
4. **Never delete an id while any supported license references it.**
   Retire an id only when no live installation uses licenses signed by
   it (the issuance ledger tells you which ids were used).

## 7. Backup

Back up the whole keystore directory (both files) on every keygen:

* keep at least two copies, offline, **encrypted at rest** (the
  keystore is the private key - treat it like a password vault);
* verify a restore periodically by running `list-keys` against the copy
  and `issue`-ing a throwaway request on a test machine;
* the ledger travels with it: it is the record of what was issued under
  which key id;
* never back up a keystore into any repository, chat, email or ticket.

## 8. Recovery

| Situation | Action |
| --- | --- |
| Keystore lost | Nothing can be signed until you restore a backup or create a **new key id** (`keygen --key-id k3`). Licenses already issued keep verifying: their public ids are already shipped. Re-issue anything missing under the new id. |
| Keystore corrupted / tampered detected | Do **not** generate over it. Restore from backup (the loader rejects entries whose public half does not match the seed, so a half-written file cannot silently sign). |
| Issuance ledger lost | Nothing fails - it is an audit aid, not an input. Reconstruct from your own order records if needed. |
| Customer lost their activation code | Re-issue from a fresh request on that machine; use the same key id while it exists. Each issue mints a new license id. |
| Activation fails `license_invalid_key` | The shipped `verification_keys.json` lacks the code's key id: export it and ship an updated release (§5). |
| Activation fails `license_bound_elsewhere` | The code was issued for another machine's hash - re-issue from this machine's request. |
| `verification_keys.json` corrupted | Restore it from the last release; `export-key --out` refuses to write over a file it cannot read (exit 2). |
| Wrong `--key-dir` / missing keystore | Exit 2 with an explicit message; the tool never creates keys implicitly to "help". |

## 9. Verification (before shipping)

```powershell
# offline check of a code against the keystore's public halves
.\.venv\Scripts\python.exe -m tools.license_generator verify "SMP1.…" --hw-hash <64-hex>

# or against a packaged verification_keys.json
.\.venv\Scripts\python.exe -m tools.license_generator verify "SMP1.…" --hw-hash <64-hex> --keys-file ..\app\licensing\verification_keys.json
```

* exit 0: verified (license id, key id, kind, issued-at, features);
* exit 1: the backend verifier rejected it (`license_invalid`,
  `license_invalid_key`, `license_bound_elsewhere`);
* exit 2: operator/input error (bad hash shape, unreadable key file).

Run the automated suite after any change to the generator:

```powershell
.\.venv\Scripts\python.exe -m pytest tests\unit\test_license_generator.py
.\.venv\Scripts\python.exe -m ruff check tools tests\unit\test_license_generator.py
```

## 10. Command reference and exit codes

| Command | Purpose |
| --- | --- |
| `keygen --key-id ID [--label T]` | create one keypair (explicit id only) |
| `list-keys` | inventory of ids + public halves |
| `export-key --key-id ID [--out FILE]` | publish/merge a public entry |
| `issue --key-id ID (--request C \| --request-file F) [--features CSV] [--license-id ID]` | sign a Lifetime code from an SMPr1 request |
| `verify CODE --hw-hash H [--keys-file F \| --key-dir D]` | check a code with the backend verifier |

Exit codes: `0` success, `1` a rejected code or hash (backend error code
is printed), `2` an operator/input error. Errors are always a single
`error: …` line on stderr - never a traceback, never key material.
