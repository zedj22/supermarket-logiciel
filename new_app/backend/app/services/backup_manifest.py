"""Backup manifest v2 — versioning, signing and verification (Phase L3, §8).

The sidecar manifest evolves **additively** (audit §8): every v1 key
stays exactly as it is, and v2 adds ``format_version``, ``payload_sha256``
(alias of ``sha256``), ``created_by: {app_version, install_id}``,
``signature``, ``key_id`` and ``public_key``.

v2 documents are signed with this install's Ed25519 keypair
(``<LICENSE_STATE_DIR>/install.keypair`` — a StateStore envelope, so
DPAPI + HMAC + atomic write, never a bare file) and carry the public half
*inside* the document.  That makes verification self-contained: a restore
proves tamper-evidence without reading any local licensing state, so the
archive stays portable across machines and a foreign install can verify
it (§8 cross-PC scenario; no hardware comparison anywhere).

Trust model (audit R10): the signature proves the document has not been
modified since a Supermarket Pro install signed it — tamper-evidence and
format provenance, **not** publisher authenticity: anyone can mint their
own install keypair.  The private seed never leaves the state directory
and never appears in a manifest, an audit row or a log line.

Version handling is explicit and never reinterpreted:

* ``format_version`` absent or ``1`` → v1 path: the caller applies
  SHA-256 and structural checks only (this function just returns 1);
* ``2`` → every required field validated, ``payload_sha256`` bound to
  ``sha256`` (and to the caller's file hash when given), Ed25519
  signature verified over the canonical document minus ``signature``;
* anything else → ``BACKUP_MANIFEST_UNSUPPORTED`` refusal.
"""

from __future__ import annotations

import base64
from collections.abc import Mapping
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from app.core.config import settings
from app.core.exceptions import ValidationError
from app.licensing.activation_code import canonical_json
from app.licensing.state_store import StateStore, StateStoreError
from app.licensing.trial import TrialManager

#: The manifest version this build writes (audit §8).
FORMAT_VERSION = 2

#: ``key_id`` recorded in v2 manifests: the per-install signing key.
INSTALL_KEY_ID = "install"

#: State blob name for the signing keypair (StateStore appends its
#: ``.state`` envelope suffix, exactly like ``trial`` → ``trial.state``).
_KEY_STATE_NAME = "install.keypair"
_KEY_PAYLOAD_VERSION = 1
_SEED_BYTES = 32
_SIGNATURE_BYTES = 64

#: Every field a v2 document must carry besides the v1 keys.
V2_REQUIRED_FIELDS = (
    "sha256",
    "payload_sha256",
    "created_by",
    "signature",
    "key_id",
    "public_key",
)

#: Stable refusal codes (HTTP 422 through ``ValidationError``).
UNSUPPORTED = "BACKUP_MANIFEST_UNSUPPORTED"
INVALID = "BACKUP_MANIFEST_INVALID"
SIGNATURE_INVALID = "BACKUP_MANIFEST_SIGNATURE_INVALID"
SIGNING_FAILED = "BACKUP_MANIFEST_SIGNING_FAILED"

__all__ = [
    "FORMAT_VERSION",
    "INSTALL_KEY_ID",
    "SIGNATURE_INVALID",
    "SIGNING_FAILED",
    "UNSUPPORTED",
    "INVALID",
    "V2_REQUIRED_FIELDS",
    "finalize_manifest",
    "verify_manifest",
]


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _unb64(value: object, *, field: str) -> bytes:
    if not isinstance(value, str):
        raise ValidationError(
            f"backup manifest field {field!r} is not base64 text",
            code=INVALID,
            details={"field": field},
        )
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValidationError(
            f"backup manifest field {field!r} is not valid base64",
            code=INVALID,
            details={"field": field},
        ) from exc


def _is_sha256_hex(value: object) -> bool:
    if not isinstance(value, str) or len(value) != 64:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return value == value.lower()


def _declared_version(manifest: Mapping[str, Any]) -> int:
    """Declared ``format_version``; absent means v1 (audit §8)."""
    raw = manifest.get("format_version", 1)
    if isinstance(raw, bool) or not isinstance(raw, int):
        # A string "2" is malformed, not a version we silently parse.
        raise ValidationError(
            "backup manifest format_version must be an integer",
            code=INVALID,
            details={"field": "format_version"},
        )
    return raw


def _current_install_id() -> str | None:
    """This install's trial id for ``created_by`` — provenance only.

    A missing or unreadable trial never blocks a backup: the field is
    informational, the signature is what matters.  (Read-only: never
    ``ensure_started`` — the trial starts on first backend start, D5.)
    """
    try:
        status = TrialManager.from_settings().status()
    except (StateStoreError, OSError, ValueError):
        return None
    return status.install_id if status is not None else None


def _load_or_create_keypair() -> Ed25519PrivateKey:
    """This install's Ed25519 signing key (created on first use).

    Stored through :class:`StateStore`, so the seed sits in a DPAPI-sealed,
    HMAC-verified, atomically written envelope.  Any state problem fails
    closed: a manifest this build writes is always signed, never silently
    downgraded to an unsigned document.
    """
    store = StateStore(settings.LICENSE_STATE_DIR)
    try:
        payload = store.read(_KEY_STATE_NAME)
        if payload is None:
            private = Ed25519PrivateKey.generate()
            seed = private.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
            store.write(
                _KEY_STATE_NAME,
                {"v": _KEY_PAYLOAD_VERSION, "seed": _b64(seed)},
            )
            return private
        if payload.get("v") != _KEY_PAYLOAD_VERSION:
            raise StateStoreError(
                f"{_KEY_STATE_NAME}: unsupported key payload version"
            )
        seed = _unb64(payload.get("seed"), field="seed")
        if len(seed) != _SEED_BYTES:
            raise StateStoreError(
                f"{_KEY_STATE_NAME}: seed must be {_SEED_BYTES} bytes"
            )
        return Ed25519PrivateKey.from_private_bytes(seed)
    except (StateStoreError, OSError, ValueError) as exc:
        raise ValidationError(
            "the install signing key is unavailable, so this backup "
            "cannot be recorded as a signed v2 manifest",
            code=SIGNING_FAILED,
        ) from exc


def finalize_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Return a v2 copy of a v1-shaped manifest, signed by this install.

    Adds ``format_version``/``payload_sha256``/``created_by``/``key_id``/
    ``public_key`` and the ``signature`` over the canonical document
    minus ``signature`` itself.  The input is never mutated.
    """
    if "sha256" not in manifest:
        raise ValidationError(
            "cannot sign a backup manifest without sha256",
            code=INVALID,
            details={"field": "sha256"},
        )
    doc: dict[str, Any] = dict(manifest)
    doc["format_version"] = FORMAT_VERSION
    doc["payload_sha256"] = manifest["sha256"]
    doc["created_by"] = {
        "app_version": settings.VERSION,
        "install_id": _current_install_id(),
    }
    doc["key_id"] = INSTALL_KEY_ID
    private = _load_or_create_keypair()
    public_raw = private.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    doc["public_key"] = _b64(public_raw)
    unsigned = {k: v for k, v in doc.items() if k != "signature"}
    try:
        document = canonical_json(unsigned)
    except (TypeError, ValueError) as exc:
        raise ValidationError(
            "the backup manifest cannot be canonicalized for signing",
            code=INVALID,
        ) from exc
    doc["signature"] = _b64(private.sign(document))
    return doc


def verify_manifest(
    manifest: Mapping[str, Any],
    *,
    expected_sha256: str | None = None,
) -> int:
    """Validate a sidecar document; return its format version.

    v1 documents (absent or explicit ``format_version: 1``) are accepted
    as-is — the caller applies SHA-256 and structural checks.  v2
    documents must carry every required field, a payload hash bound to
    ``sha256`` (and to ``expected_sha256`` when the caller holds the
    file's actual hash) and a valid Ed25519 signature over the canonical
    document minus ``signature``.  Unknown versions are refused, never
    reinterpreted.
    """
    if not isinstance(manifest, Mapping):
        raise ValidationError(
            "the backup manifest is not a JSON object",
            code=INVALID,
        )
    version = _declared_version(manifest)
    if version == 1:
        return 1
    if version != FORMAT_VERSION:
        raise ValidationError(
            f"backup manifest format_version {version} is not supported "
            "by this build",
            code=UNSUPPORTED,
            details={"format_version": version},
        )

    missing = [f for f in V2_REQUIRED_FIELDS if f not in manifest]
    if missing:
        raise ValidationError(
            "the v2 backup manifest is missing required fields",
            code=INVALID,
            details={"missing": missing},
        )

    payload_sha = manifest["payload_sha256"]
    recorded_sha = manifest["sha256"]
    if not _is_sha256_hex(payload_sha):
        raise ValidationError(
            "payload_sha256 is not a SHA-256 hex digest",
            code=INVALID,
            details={"field": "payload_sha256"},
        )
    if not _is_sha256_hex(recorded_sha):
        raise ValidationError(
            "sha256 is not a SHA-256 hex digest",
            code=INVALID,
            details={"field": "sha256"},
        )
    if payload_sha != recorded_sha:
        raise ValidationError(
            "payload_sha256 does not match sha256",
            code=INVALID,
            details={"field": "payload_sha256"},
        )
    if expected_sha256 is not None and payload_sha != expected_sha256:
        raise ValidationError(
            "the dump bytes do not match the manifest payload hash",
            code=INVALID,
            details={"field": "payload_sha256"},
        )

    created_by = manifest["created_by"]
    if (
        not isinstance(created_by, Mapping)
        or "app_version" not in created_by
        or "install_id" not in created_by
    ):
        raise ValidationError(
            "created_by must carry app_version and install_id",
            code=INVALID,
            details={"field": "created_by"},
        )

    key_id = manifest["key_id"]
    if not isinstance(key_id, str) or not key_id:
        raise ValidationError(
            "key_id must be a non-empty string",
            code=INVALID,
            details={"field": "key_id"},
        )

    signature = _unb64(manifest["signature"], field="signature")
    public_raw = _unb64(manifest["public_key"], field="public_key")
    if len(signature) != _SIGNATURE_BYTES:
        raise ValidationError(
            f"signature must be {_SIGNATURE_BYTES} bytes",
            code=INVALID,
            details={"field": "signature"},
        )
    if len(public_raw) != _SEED_BYTES:
        raise ValidationError(
            f"public_key must be {_SEED_BYTES} bytes",
            code=INVALID,
            details={"field": "public_key"},
        )

    unsigned = {k: v for k, v in manifest.items() if k != "signature"}
    try:
        document = canonical_json(unsigned)
    except (TypeError, ValueError) as exc:
        raise ValidationError(
            "the backup manifest cannot be canonicalized for verification",
            code=INVALID,
        ) from exc
    try:
        Ed25519PublicKey.from_public_bytes(public_raw).verify(
            signature, document
        )
    except (InvalidSignature, ValueError) as exc:
        raise ValidationError(
            "the backup manifest signature does not verify; the backup "
            "has been modified and will not be restored",
            code=SIGNATURE_INVALID,
        ) from exc
    return FORMAT_VERSION
