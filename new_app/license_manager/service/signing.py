"""Signing material and ``SMP1`` issuance.

The issuance path is deliberately a *thin* re-use of the customer contract:
``validate_payload`` → ``canonical_json`` → Ed25519 ``sign`` →
``encode_activation_code`` → ``verify_activation_code``.  It produces the same
bytes the offline generator produces for the same inputs (a test pins that
byte-for-byte equality against ``tools.license_generator.generator``).

Two self-checks run before a code is ever returned, both fail-closed:

1. the signing ``key_id`` must be present in the **packaged customer
   verification keys** — otherwise the customer's backend would answer
   ``license_invalid_key`` and the administrator would be handing over a dead
   code;
2. the finished code is verified with the customer's own verifier against
   those packaged keys, and again against the signer's own public half.
"""

from __future__ import annotations

import base64
import binascii
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Protocol

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from service import shared
from service.contracts import IssuedCode
from service.errors import (
    SigningKeyError,
    SigningKeyNotPublishedError,
    ValidationFailedError,
)
from service.secrets import SecretFetcher

__all__ = [
    "ED25519_SEED_BYTES",
    "LicenseIssuer",
    "SigningKey",
    "SigningKeyProvider",
    "StaticSigningKeyProvider",
    "load_signing_key",
    "load_signing_key_from_secret",
]

#: Ed25519 private seed size (RFC 8032).
ED25519_SEED_BYTES = 32

UTC = timezone.utc


@dataclass(frozen=True, slots=True)
class SigningKey:
    """One in-memory Ed25519 keypair.

    ``private_key`` is excluded from ``repr`` so an accidental log line cannot
    print key material.  The seed is never stored on this object at all.
    """

    key_id: str
    private_key: Ed25519PrivateKey = field(repr=False)
    public: bytes = b""

    @classmethod
    def from_seed(cls, key_id: str, seed: bytes) -> SigningKey:
        if not shared.is_valid_key_id(key_id):
            raise SigningKeyError(
                "the signing key id does not satisfy the license key-id contract"
            )
        if not isinstance(seed, bytes) or len(seed) != ED25519_SEED_BYTES:
            raise SigningKeyError(
                f"an Ed25519 signing seed must be exactly {ED25519_SEED_BYTES} bytes"
            )
        try:
            private = Ed25519PrivateKey.from_private_bytes(seed)
        except ValueError as exc:
            raise SigningKeyError("the Ed25519 signing seed is unusable") from exc
        return cls(
            key_id=key_id,
            private_key=private,
            public=private.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            ),
        )


class SigningKeyProvider(Protocol):
    """Where a signing keypair comes from."""

    def load(self) -> SigningKey: ...


@dataclass(frozen=True, slots=True)
class StaticSigningKeyProvider:
    """A fixed keypair — tests and local development only."""

    key: SigningKey

    def load(self) -> SigningKey:
        return self.key


def _decode_seed(value: object, *, what: str) -> bytes:
    if not isinstance(value, str):
        raise SigningKeyError(f"{what} must be base64 text")
    try:
        seed = base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SigningKeyError(f"{what} is not valid base64") from exc
    if len(seed) != ED25519_SEED_BYTES:
        raise SigningKeyError(
            f"{what} must decode to exactly {ED25519_SEED_BYTES} bytes"
        )
    return seed


#: The signing secret is a JSON object with exactly these two fields.
_SIGNING_SECRET_FIELDS = frozenset({"key_id", "seed_b64"})


def load_signing_key(payload: str) -> SigningKey:
    """Parse the signing secret: ``{"key_id": "...", "seed_b64": "..."}``.

    The document is strict on purpose — no extra field may ride along, so a
    hand-edited secret cannot smuggle anything into the signing path.
    """
    try:
        document: Any = json.loads(payload)
    except ValueError as exc:
        raise SigningKeyError("the signing secret is not valid JSON") from exc
    if not isinstance(document, dict):
        raise SigningKeyError("the signing secret must be a JSON object")
    if set(document) != _SIGNING_SECRET_FIELDS:
        raise SigningKeyError(
            "the signing secret must contain exactly key_id and seed_b64"
        )
    key_id = document["key_id"]
    if not isinstance(key_id, str) or not shared.is_valid_key_id(key_id):
        raise SigningKeyError(
            "the signing secret's key_id does not satisfy the key-id contract"
        )
    return SigningKey.from_seed(key_id, _decode_seed(document["seed_b64"], what="seed_b64"))


def load_signing_key_from_secret(
    fetcher: SecretFetcher, *, name: str, version: str = "latest"
) -> SigningKey:
    """Fetch and parse the signing secret (Secret Manager in production)."""
    return load_signing_key(fetcher.fetch(name, version))


class _LazySigningKeyProvider:
    """Load the signing key once, on first use, and keep it in memory only."""

    def __init__(self, loader: Callable[[], SigningKey]) -> None:
        self._loader = loader
        self._key: SigningKey | None = None

    def load(self) -> SigningKey:
        if self._key is None:
            self._key = self._loader()
        return self._key


def lazy_key_provider(loader: Callable[[], SigningKey]) -> SigningKeyProvider:
    """Wrap a loader so a cold start does not touch the secret backend."""
    return _LazySigningKeyProvider(loader)


class LicenseIssuer:
    """Sign ``SMP1`` lifetime codes with the existing contract functions."""

    def __init__(
        self,
        *,
        key: SigningKey,
        verification_keys: Mapping[str, bytes],
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._key = key
        self._verification_keys = dict(verification_keys)
        self._clock = clock or (lambda: datetime.now(UTC))

    @property
    def key_id(self) -> str:
        return self._key.key_id

    @property
    def verification_key_ids(self) -> tuple[str, ...]:
        return tuple(sorted(self._verification_keys))

    def is_published(self) -> bool:
        """True when the customer package ships this key id."""
        return self._key.key_id in self._verification_keys

    def issue(
        self,
        *,
        hw_hash: str,
        features: tuple[str, ...] = ("pos",),
        license_id: str | None = None,
        issued_at: datetime | None = None,
    ) -> IssuedCode:
        """Produce one signed lifetime activation code for ``hw_hash``.

        Raises ``SigningKeyNotPublishedError`` when the package does not ship
        this key id, and ``ValidationFailedError`` when the contract rejects
        the payload — in both cases nothing is returned and nothing is stored.
        """
        if not shared.is_valid_hw_hash(hw_hash):
            raise ValidationFailedError(
                "the hardware fingerprint must be a 64-character lowercase "
                "SHA-256 hex digest"
            )
        if not self.is_published():
            raise SigningKeyNotPublishedError(
                "the signing key id is not present in the packaged customer "
                "verification keys, so a code signed with it could never be "
                "activated; provision the public key first"
            )

        moment = issued_at if issued_at is not None else self._clock()
        identifier = license_id or shared.request_parser.generate_license_id()
        if not shared.is_valid_license_id(identifier):
            raise ValidationFailedError(
                "the license id must be 8-64 characters of [A-Za-z0-9_-] "
                "starting with a letter or digit"
            )

        payload = {
            "v": shared.LICENSE_VERSION,
            "key_id": self._key.key_id,
            "license_id": identifier,
            "kind": shared.LICENSE_KIND,
            "issued_at": shared.contract._stamp(moment),
            "hw_hash": hw_hash,
            "features": list(features),
        }
        try:
            shared.validate_payload(payload)
        except Exception as exc:
            raise ValidationFailedError(
                "the license payload was rejected by the SMP1 contract"
            ) from exc

        payload_bytes = shared.canonical_json(payload)
        signature = self._key.private_key.sign(payload_bytes)
        try:
            code = shared.encode_activation_code(payload, signature)
        except Exception as exc:
            raise ValidationFailedError(
                "the activation code would violate the SMP1 size contract; "
                "grant fewer or shorter features"
            ) from exc

        # Fail-closed self-checks: the customer's verifier must accept it.
        try:
            shared.verify_activation_code(
                code, keys=self._verification_keys, expected_hw_hash=hw_hash
            )
            shared.verify_activation_code(
                code, keys={self._key.key_id: self._key.public}, expected_hw_hash=hw_hash
            )
        except SigningKeyNotPublishedError:
            raise
        except Exception as exc:
            raise SigningKeyError(
                "the generated activation code failed self-verification and "
                "was withheld"
            ) from exc

        return IssuedCode(
            code=code,
            license_id=identifier,
            key_id=self._key.key_id,
            issued_at=datetime.fromisoformat(payload["issued_at"]).astimezone(UTC),
            features=tuple(payload["features"]),
            payload_bytes=payload_bytes,
            signature=signature,
        )
