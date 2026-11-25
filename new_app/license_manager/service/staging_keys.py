"""Startup validation of the staging-only public verification keys.

Phase 8.4.3.  When ``LICENSE_API_REQUIRE_STAGING_KEYS=1`` the service must not
come up unless its **staging** key file is present, well-formed and publishes
the configured staging key id.

This runs from ``service.api.create_app`` — i.e. at import time for
``uvicorn service.api:app`` and for ``scripts/preflight.py`` — so a missing or
broken mount fails the deployment instead of letting the service start and
answer ``503 signing_key_not_published`` on every issuance.  It is never run
when the flag is off, so production (whose packaged file *is* the production
key file) is completely unaffected.

Nothing here reads private material: the input is a public key file, and the
only thing reported is the path, the problem and the expected key id.
"""

from __future__ import annotations

from app.licensing.verification_keys import (
    VerificationKeysError,
    is_valid_key_id,
    load_verification_keys,
)

from service.errors import SigningKeyError
from service.settings import Settings

__all__ = ["ensure_staging_keys"]


def ensure_staging_keys(settings: Settings) -> tuple[str, ...]:
    """Validate the staging key file, or raise ``SigningKeyError``.

    Fails closed on: an unknown id shape, a missing file, unreadable or
    malformed JSON, an empty key set, and a file that does not publish the
    configured staging key id.  Messages never contain a key byte or another
    entry from the file.
    """
    path = settings.verification_keys_path
    key_id = (settings.staging_key_id or "").strip()

    if not is_valid_key_id(key_id):
        raise SigningKeyError(
            f"the configured staging key id {key_id!r} is not a valid license "
            "key id, so no keys file could publish it"
        )

    try:
        present = path.is_file()
    except OSError:  # pragma: no cover - unreadable parent directory
        present = False
    if not present:
        raise SigningKeyError(
            f"the staging verification keys file {path} is missing: the image "
            "must carry deploy/staging/verification_keys.staging.json"
        )

    try:
        keys = load_verification_keys(path)
    except VerificationKeysError as exc:
        raise SigningKeyError(
            f"the staging verification keys file {path} is not a usable public "
            f"key file ({exc})"
        ) from exc
    except OSError as exc:  # pragma: no cover - permission problems
        raise SigningKeyError(
            f"the staging verification keys file {path} could not be read"
        ) from exc

    if not keys:
        raise SigningKeyError(
            f"the staging verification keys file {path} ships no key ids, so a "
            "code signed in staging could never be activated"
        )
    if key_id not in keys:
        raise SigningKeyError(
            f"the staging verification keys file {path} does not publish the "
            f"configured staging key id {key_id!r}"
        )
    return tuple(sorted(keys))
