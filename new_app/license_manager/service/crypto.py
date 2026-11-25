"""At-rest protection for the stored activation code.

The activation code is delivered to the administrator from this service, so
it *is* stored — but only as an AES-256-GCM envelope, never as plaintext and
never as a value the browser could read straight out of Firestore.  The key
lives in Google Cloud Secret Manager (``LICENSE_API_CODE_ENC_SECRET``) and is
held in memory only.

Envelope format (a single Firestore string field)::

    gcm1:<base64 12-byte nonce>:<base64 ciphertext+tag>

``gcm1`` leaves room for a future algorithm change; the associated data binds
the ciphertext to the license id, so a sealed code cannot be moved onto a
different license document.
"""

from __future__ import annotations

import base64
import binascii
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from service.errors import SigningKeyError

__all__ = ["CIPHER_VERSION", "ActivationCodeCipher"]

CIPHER_VERSION = "gcm1"
_KEY_BYTES = 32
_NONCE_BYTES = 12


class ActivationCodeCipher:
    """Seal and open activation codes with AES-256-GCM."""

    def __init__(self, key: bytes) -> None:
        if not isinstance(key, bytes) or len(key) != _KEY_BYTES:
            raise SigningKeyError(
                "the activation-code encryption key must be exactly 32 bytes"
            )
        self._aead = AESGCM(key)

    @classmethod
    def from_base64(cls, value: str) -> ActivationCodeCipher:
        """Build from a base64 32-byte key (as stored in Secret Manager)."""
        try:
            raw = base64.b64decode((value or "").strip(), validate=True)
        except (binascii.Error, ValueError) as exc:
            raise SigningKeyError(
                "the activation-code encryption key is not valid base64"
            ) from exc
        return cls(raw)

    def seal(self, *, license_id: str, code: str) -> str:
        """Encrypt ``code`` for storage beside ``license_id``."""
        if not code:
            raise ValueError("refusing to seal an empty activation code")
        nonce = os.urandom(_NONCE_BYTES)
        sealed = self._aead.encrypt(
            nonce, code.encode("utf-8"), license_id.encode("utf-8")
        )
        return ":".join(
            (
                CIPHER_VERSION,
                base64.b64encode(nonce).decode("ascii"),
                base64.b64encode(sealed).decode("ascii"),
            )
        )

    def open(self, *, license_id: str, envelope: str) -> str:
        """Decrypt a stored envelope (fail-closed on tamper or key change)."""
        try:
            version, nonce_b64, sealed_b64 = (envelope or "").split(":", 2)
        except ValueError as exc:
            raise SigningKeyError(
                "the stored activation code is not in a recognized format"
            ) from exc
        if version != CIPHER_VERSION:
            raise SigningKeyError(
                "the stored activation code uses an unsupported envelope version"
            )
        try:
            nonce = base64.b64decode(nonce_b64, validate=True)
            sealed = base64.b64decode(sealed_b64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise SigningKeyError(
                "the stored activation code is not valid base64"
            ) from exc
        try:
            plain = self._aead.decrypt(nonce, sealed, license_id.encode("utf-8"))
        except (InvalidTag, ValueError) as exc:
            raise SigningKeyError(
                "the stored activation code could not be decrypted"
            ) from exc
        return plain.decode("utf-8")
