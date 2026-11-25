"""Startup check that the staging signing seed matches its published key.

Phase 8.4.4.  ``LICENSE_API_REQUIRE_STAGING_KEYS`` proves the staging keys file
is present and well-formed; it cannot see the *private* half.  A staging seed
copied from another keypair still parses, still signs, and still passes the
issuer's id-only publication check — the first sign of trouble would be a
customer's ``license_invalid_key``.

With ``LICENSE_API_REQUIRE_SIGNING_KEY_MATCH=1`` the service therefore, at
application construction (``service.api.create_app``, i.e. import time for
``uvicorn service.api:app``):

1. loads the configured signing secret through the deployment's existing
   provider (``FileSecretFetcher`` on Render, Secret Manager on Cloud Run — no
   new dependency and no fallback);
2. derives the Ed25519 public half from that seed;
3. reads the public key the verification keys file publishes for
   ``LICENSE_API_STAGING_KEY_ID``;
4. compares the two byte strings with :func:`hmac.compare_digest`.

Any failure — missing secret, malformed seed or key file, wrong length, a seed
whose ``key_id`` is not the configured staging id, or a plain mismatch — raises
``SigningKeyError`` before the ASGI app exists, so the process fails to start
instead of issuing unverifiable codes.

Nothing here reports key material: messages carry the key *id*, the *path* and
the problem only.  The flag is off by default, so production behaviour (and its
lazy secret fetch on first use) is unchanged.
"""

from __future__ import annotations

import hmac

from app.licensing.verification_keys import (
    ED25519_PUBLIC_KEY_BYTES,
    VerificationKeysError,
    is_valid_key_id,
    load_verification_keys,
)

from service.container import load_configured_signing_key
from service.errors import SigningKeyError
from service.settings import Settings

__all__ = ["ensure_signing_key_matches"]


def _published_key(settings: Settings, key_id: str) -> bytes:
    """The public key the configured keys file publishes for ``key_id``."""
    path = settings.verification_keys_path
    try:
        keys = load_verification_keys(path)
    except VerificationKeysError as exc:
        raise SigningKeyError(
            f"the verification keys file {path} is not a usable public key "
            f"file ({exc})"
        ) from exc
    except OSError as exc:  # pragma: no cover - permission problems
        raise SigningKeyError(
            f"the verification keys file {path} could not be read"
        ) from exc

    published = keys.get(key_id)
    if published is None:
        if not keys:
            raise SigningKeyError(
                f"the verification keys file {path} ships no key ids, so the "
                f"configured signing seed could not be matched to {key_id!r}"
            )
        raise SigningKeyError(
            f"the verification keys file {path} does not publish the "
            f"configured staging key id {key_id!r}, so the configured signing "
            "seed cannot be matched to a published key"
        )
    if len(published) != ED25519_PUBLIC_KEY_BYTES:  # pragma: no cover - loader
        raise SigningKeyError(
            f"the published public key for {key_id!r} is not a "
            f"{ED25519_PUBLIC_KEY_BYTES}-byte Ed25519 key"
        )
    return published


def ensure_signing_key_matches(settings: Settings) -> str:
    """Validate the seed ↔ published-key pair, or raise ``SigningKeyError``.

    Returns the key id that was verified.  Never includes the seed or a key
    byte in an exception message.
    """
    key_id = (settings.staging_key_id or "").strip()
    if not is_valid_key_id(key_id):
        raise SigningKeyError(
            f"the configured staging key id {key_id!r} is not a valid license "
            "key id, so no published key could be matched against the signing "
            "seed"
        )

    # 1. The seed itself, through the deployment's own secret provider.  A
    #    missing or malformed secret stops here, before the keys file is read.
    signing = load_configured_signing_key(settings)

    # 2. The public half the staging client will actually verify against.
    published = _published_key(settings, key_id)

    # 3. The seed must belong to the configured id at all; a valid keypair
    #    published under another id is a configuration mistake, not a match.
    if signing.key_id != key_id:
        raise SigningKeyError(
            f"the configured signing secret belongs to key id "
            f"{signing.key_id!r}, not the configured staging key id {key_id!r}"
        )

    if len(signing.public) != len(published) or not hmac.compare_digest(
        signing.public, published
    ):
        raise SigningKeyError(
            f"the public key derived from the configured signing seed does "
            f"not match the public key published for key id {key_id!r}: codes "
            "signed with this seed could never be activated"
        )

    return key_id
