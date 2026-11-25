"""Fail-closed configuration check for the combined Render container.

Runs from `deploy/render/entrypoint.sh` **before** uvicorn or Next start, so a
deployment missing any required piece crashes instead of coming up and
answering ``503`` on every issuance:

* the staging verification keys file (when ``LICENSE_API_REQUIRE_STAGING_KEYS``
  is on) — present, valid, publishing the configured staging key id;
* the Ed25519 signing seed — readable through the configured provider, and
  matching the published key when ``LICENSE_API_REQUIRE_SIGNING_KEY_MATCH`` is
  on. The AES key and the signing seed are fetched lazily by the running
  service, so without this check a missing mount would only surface on the
  first request;
* in production (and only there — the staging flags below are not used as a
  workaround), the loaded signing key is published in the configured
  verification-keys file and its derived public half matches the published
  one, so a wrong seed or a stale keys file fails the deploy instead of
  producing ``503 signing_key_not_published`` on the first issuance;
* the activation-code AES-256-GCM key — readable and exactly 32 bytes (proven
  by a seal/open round trip of a throwaway probe string).

Every check uses the same code the service uses (`service.container`,
`service.staging_keys`, `service.signing_key_match`), so this script cannot
drift from the runtime. Nothing secret is printed: a line names the check, the
key *id* and the verified shape; never a seed, a key byte or a secret value.
Exit code 0 means "safe to start"; anything else means "refuse to start".

This file is only referenced by the Render image. The Cloud Run images and the
service's own import path are unchanged.
"""

from __future__ import annotations

import hmac
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[1]
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

_PASS = "PASS"
_FAIL = "FAIL"
_WARN = "WARN"


def _report(status: str, label: str, detail: str = "") -> None:
    line = f"[{status}] {label}"
    if detail:
        line = f"{line} - {detail}"
    print(line, file=sys.stderr if status == _FAIL else sys.stdout, flush=True)


def _production_signing_key(settings) -> str:
    """Prove the issuer's signing key is published, with a matching public half.

    Production has no staging flags to lean on, so this is the only startup
    proof that the seed the issuer will sign with belongs to a key id the
    shipped customer package actually trusts. Both halves are read through the
    existing loaders (``load_configured_signing_key`` honours the configured
    secret provider, ``load_verification_keys`` is the contract's own parser and
    length validator), and the comparison is constant time. Nothing here is
    re-implemented and no message carries a seed, a key byte or file content —
    only the key id and the path.
    """
    from app.licensing.verification_keys import (
        ED25519_PUBLIC_KEY_BYTES,
        VerificationKeysError,
        load_verification_keys,
    )

    from service.container import load_configured_signing_key
    from service.errors import SigningKeyError

    signing = load_configured_signing_key(settings)
    path = settings.verification_keys_path

    try:
        present = path.is_file()
    except OSError:  # pragma: no cover - unreadable parent directory
        present = False
    if not present:
        raise SigningKeyError(
            f"the verification keys file {path} is missing: set "
            "LICENSE_API_VERIFICATION_KEYS_FILE to the packaged public keys"
        )

    try:
        published = load_verification_keys(path)
    except VerificationKeysError as exc:
        raise SigningKeyError(
            f"the verification keys file {path} is not a usable public key "
            f"file ({exc})"
        ) from exc
    except OSError as exc:  # pragma: no cover - permission problems
        raise SigningKeyError(
            f"the verification keys file {path} could not be read"
        ) from exc

    if not published:
        raise SigningKeyError(
            f"the verification keys file {path} ships no key ids, so the "
            f"signing key {signing.key_id!r} could never be accepted by the "
            "customer application"
        )
    if signing.key_id not in published:
        raise SigningKeyError(
            f"the verification keys file {path} does not publish the signing "
            f"key id {signing.key_id!r}: every code signed with it would be "
            "rejected by the customer application"
        )

    key = published[signing.key_id]
    if (
        len(key) != ED25519_PUBLIC_KEY_BYTES
        or len(signing.public) != len(key)
        or not hmac.compare_digest(signing.public, key)
    ):
        raise SigningKeyError(
            "the public key derived from the configured signing seed does not "
            f"match the public key published for key id {signing.key_id!r}: "
            "codes signed with this seed could never be activated"
        )
    return f"key_id={signing.key_id}"


def main() -> int:
    try:
        # Importing the `service` package runs `create_app` (service/__init__.py
        # imports service.api), so the staging guards execute here as well — a
        # broken configuration raises at import, which is the fail-closed path
        # a uvicorn start would take.
        from service.settings import load_settings

        settings = load_settings()
    except Exception as exc:  # noqa: BLE001 - classify, never echo values
        _report(_FAIL, "startup guards", type(exc).__name__)
        return 1
    _report(_PASS, "settings and startup guards", f"env={settings.env}")

    from service.container import load_code_cipher, load_configured_signing_key
    from service.errors import SigningKeyError
    from service.signing_key_match import ensure_signing_key_matches
    from service.staging_keys import ensure_staging_keys

    failures = 0

    def run(label: str, func) -> None:
        nonlocal failures
        try:
            detail = func()
        except (SigningKeyError, ValueError, OSError) as exc:
            # Class name only: provider messages can carry infrastructure
            # detail, and key material must never reach a log line.
            _report(_FAIL, label, type(exc).__name__)
            failures += 1
            return
        except Exception as exc:  # noqa: BLE001
            _report(_FAIL, label, type(exc).__name__)
            failures += 1
            return
        _report(_PASS, label, detail or "")

    if settings.require_staging_keys:
        run(
            "staging verification keys",
            lambda: f"{len(ensure_staging_keys(settings))} key id(s)",
        )
    else:
        _report(_WARN, "staging verification keys", "LICENSE_API_REQUIRE_STAGING_KEYS is off")

    if settings.require_signing_key_match:
        run(
            "signing seed matches the published key",
            lambda: f"key_id={ensure_signing_key_matches(settings)}",
        )
    else:
        run(
            "signing seed loads",
            lambda: f"key_id={load_configured_signing_key(settings).key_id}",
        )

    # Production (a staging deployment sets LICENSE_API_REQUIRE_STAGING_KEYS and
    # keeps its own guards instead). A missing keys mount, an unpublished key id
    # or a seed that belongs to another keypair all fail the deploy here rather
    # than on the first issuance.
    if settings.is_production and not settings.require_staging_keys:
        run(
            "production signing key is published",
            lambda: _production_signing_key(settings),
        )

    def _code_key() -> str:
        cipher = load_code_cipher(settings)
        probe = "SMP1.STARTUP.PROBE"
        sealed = cipher.seal(license_id="startup-check", code=probe)
        if cipher.open(license_id="startup-check", envelope=sealed) != probe:
            raise SigningKeyError(
                "the activation-code key failed its seal/open round trip"
            )
        return "32-byte key, seal/open ok"

    run("activation-code key", _code_key)

    if settings.allowlist_is_empty:
        # Not fatal: the service starts and deliberately refuses every caller.
        _report(_WARN, "administrator allowlist", "empty: every request will be refused")

    if failures:
        _report(_FAIL, "summary", f"{failures} check(s) failed; refusing to start")
        return 1
    _report(_PASS, "summary", "configuration is complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
