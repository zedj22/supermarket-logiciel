"""Activation codes — request codes out, signed Lifetime codes in (L2-A).

Two customer-copyable text formats live here, both built from the same
**deterministic canonical JSON** (sorted keys, compact separators, UTF-8,
``ensure_ascii=false``, ``allow_nan=false``) so an owner's Generator and
this backend always produce byte-identical encodings:

``SMPr1.<BASE32_PAYLOAD>``
    The unsigned *activation request* this backend generates from the
    installation id, the hardware fingerprint and a timestamp.  It is a
    **request, not a licence**: it proves nothing, authorizes nothing and
    contains no secret.  The owner pastes it into the offline License
    Generator (Phase L2-D).

``SMP1.<BASE32_PAYLOAD>.<BASE32_SIGNATURE>``
    The *Lifetime activation code* the Generator returns: canonical JSON
    payload plus a raw Ed25519 signature, both Base32-encoded **without
    padding**.  Exactly three dot-separated segments, so a request code
    can never be mistaken for a licence (and vice versa).

Signed payload (exact, strict key set — no other field is accepted)::

    {"v": 1, "key_id": "...", "license_id": "...", "kind": "lifetime",
     "issued_at": "<UTC ISO-8601>", "hw_hash": "<64 lowercase hex>",
     "features": ["pos", "..."]}

Guarantees enforced by :func:`verify_activation_code`, in this order:

* bounded size (``SMP1`` codes are at most 512 characters) and exact
  structure before anything is decoded;
* strict Base32 (``A-Z2-7``, unpadded) for both segments;
* UTF-8 JSON with **duplicate keys rejected** and NaN/Infinity rejected;
* the exact required field set — missing *or* unknown fields fail;
* ``v == 1``, ``kind == "lifetime"``, ISO-8601 ``issued_at`` with a
  timezone, a 64-character lowercase hex ``hw_hash``, and a strict
  feature list;
* the signature verified over the **exact decoded payload bytes** (never
  over a re-serialized object) with the public key named by ``key_id``;
* only then is the hardware hash compared with the current machine.

Every failure surfaces as one of the existing controlled licensing
errors (``license_invalid`` / ``license_invalid_key`` /
``license_bound_elsewhere``) with a generic message: no cryptographic
exception detail, no payload and no code fragment is ever echoed.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
)

__all__ = [
    "ACTIVATION_PREFIX",
    "LICENSE_KIND",
    "LICENSE_VERSION",
    "MAX_ACTIVATION_CODE_CHARS",
    "MAX_FEATURES",
    "PAYLOAD_FIELDS",
    "REQUEST_PREFIX",
    "ActivationPayload",
    "build_request_code",
    "build_request_payload",
    "canonical_json",
    "encode_activation_code",
    "verify_activation_code",
]

UTC = timezone.utc

#: Activation-code family prefix (exactly these 4 characters, case-sens.).
ACTIVATION_PREFIX = "SMP1"
#: Unsigned activation-request prefix — structurally different by design.
REQUEST_PREFIX = "SMPr1"

#: Strict cap on a customer-pasted activation code (~512 characters).
MAX_ACTIVATION_CODE_CHARS = 512
#: Same bound for a pasted request code (defensive; it is far smaller).
MAX_REQUEST_CODE_CHARS = 512

#: Payload schema version carried in both formats.
LICENSE_VERSION = 1
#: The only license kind Phase L2 supports (no expiry, no subscription).
LICENSE_KIND = "lifetime"

#: The exact signed field set — nothing missing, nothing extra.
PAYLOAD_FIELDS: frozenset[str] = frozenset(
    {"v", "key_id", "license_id", "kind", "issued_at", "hw_hash", "features"}
)

#: Ed25519 signature size (RFC 8032).
ED25519_SIGNATURE_BYTES = 64
#: 64-character lowercase SHA-256 hex digest (fully anchored: ``match``
#: only anchors at the start, and a trailing-newline bypass of ``$`` is
#: not acceptable for a security check).
_HW_HASH_RE = re.compile(r"\A[0-9a-f]{64}\Z")
#: License id: URL-safe, bounded, starts alphanumeric.
_LICENSE_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{7,63}\Z")
#: Feature grants: lowercase snake-ish tokens, strictly bounded.
_FEATURE_RE = re.compile(r"\A[a-z][a-z0-9_]{0,31}\Z")
#: How many feature grants one license may carry.
MAX_FEATURES = 32
#: Base32 alphabet without padding characters.
_B32_RE = re.compile(r"\A[A-Z2-7]+\Z")


@dataclass(frozen=True, slots=True)
class ActivationPayload:
    """A fully validated, signature-checked activation code."""

    v: int
    key_id: str
    license_id: str
    kind: str
    issued_at: datetime
    hw_hash: str
    features: tuple[str, ...]
    #: Exact bytes the Ed25519 signature covers (kept for persistence).
    payload_bytes: bytes
    #: Raw 64-byte Ed25519 signature (kept for persistence).
    signature: bytes


# ---------------------------------------------------------------------------
# canonical JSON
# ---------------------------------------------------------------------------


def canonical_json(payload: Mapping[str, Any]) -> bytes:
    """Deterministic UTF-8 encoding used by both code formats.

    Sorted keys + compact separators mean the same logical payload always
    produces the same bytes, which is what makes a signature (and a
    determinism test) meaningful.
    """
    return json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")


def _stamp(moment: datetime) -> str:
    """Second-precision UTC ISO-8601 with ``+00:00`` (never ``Z``)."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=UTC)
    else:
        moment = moment.astimezone(UTC)
    return moment.replace(microsecond=0).isoformat()


# ---------------------------------------------------------------------------
# Base32 helpers (no padding)
# ---------------------------------------------------------------------------


def _b32encode(raw: bytes) -> str:
    return base64.b32encode(raw).decode("ascii").rstrip("=")


def _b32decode(segment: str) -> bytes:
    """Strict, unpadded Base32 decode → ``license_invalid`` on any flaw."""
    if not segment or not _B32_RE.match(segment):
        raise LicenseInvalidError("the activation code is malformed")
    padded = segment + "=" * (-len(segment) % 8)
    try:
        return base64.b32decode(padded)
    except (binascii.Error, ValueError) as exc:
        raise LicenseInvalidError("the activation code is malformed") from exc


def _split(code: str, *, prefix: str, segments: int, what: str) -> list[str]:
    """Structure check: bounded, exact segment count, exact prefix."""
    if not isinstance(code, str):
        raise LicenseInvalidError(f"the {what} is malformed")
    cleaned = code.strip()
    if not cleaned:
        raise LicenseInvalidError(f"the {what} is empty")
    if len(cleaned) > MAX_ACTIVATION_CODE_CHARS:
        raise LicenseInvalidError(f"the {what} is too long")
    parts = cleaned.split(".")
    if len(parts) != segments:
        raise LicenseInvalidError(f"the {what} must have {segments} segments")
    if parts[0] != prefix:
        raise LicenseInvalidError(f"the {what} has an unknown prefix")
    if any(not part for part in parts):
        raise LicenseInvalidError(f"the {what} contains an empty segment")
    return parts


# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate field {key!r}")
        seen.add(key)
    return dict(pairs)


def _reject_constant(value: str) -> None:
    """``json.loads`` accepts NaN/Infinity by default — we never do."""
    raise ValueError(f"non-finite number {value}")


def loads_strict(raw: bytes, *, what: str) -> dict[str, Any]:
    """Parse a payload: UTF-8, object-shaped, duplicate/NaN-free.

    Raises ``license_invalid`` for anything unexpected — never echoes the
    payload or the underlying decoder message.
    """
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise LicenseInvalidError(f"the {what} payload is not UTF-8") from exc
    try:
        value: Any = json.loads(
            text, object_pairs_hook=_reject_duplicates, parse_constant=_reject_constant
        )
    except ValueError as exc:
        raise LicenseInvalidError(f"the {what} payload is not valid JSON") from exc
    if not isinstance(value, dict):
        raise LicenseInvalidError(f"the {what} payload is not a JSON object")
    return value


# ---------------------------------------------------------------------------
# payload schema
# ---------------------------------------------------------------------------


def validate_payload(document: Mapping[str, Any], *, what: str = "license") -> None:
    """Strict field-set + per-field validation of a signed payload."""
    keys = set(document)
    if keys != PAYLOAD_FIELDS:
        raise LicenseInvalidError(f"the {what} payload fields are invalid")

    version = document["v"]
    if type(version) is not int or version != LICENSE_VERSION:
        raise LicenseInvalidError(f"the {what} payload version is unsupported")

    for field in ("key_id", "license_id", "kind", "issued_at", "hw_hash"):
        if not isinstance(document[field], str):
            raise LicenseInvalidError(f"the {what} payload fields are invalid")

    if not _LICENSE_ID_RE.match(document["license_id"]):
        raise LicenseInvalidError(f"the {what} payload fields are invalid")

    if document["kind"] != LICENSE_KIND:
        raise LicenseInvalidError(f"license kind {document['kind']!r} is unsupported")

    try:
        issued = datetime.fromisoformat(document["issued_at"])
    except ValueError as exc:
        raise LicenseInvalidError("the issue timestamp is not ISO-8601") from exc
    if issued.tzinfo is None:
        raise LicenseInvalidError("the issue timestamp is not ISO-8601")

    if not _HW_HASH_RE.match(document["hw_hash"]):
        raise LicenseInvalidError("the hardware hash is not a SHA-256 hex digest")

    features = document["features"]
    if not isinstance(features, list) or len(features) > MAX_FEATURES:
        raise LicenseInvalidError("the feature list is invalid")
    seen: set[str] = set()
    for entry in features:
        if not isinstance(entry, str) or not _FEATURE_RE.match(entry) or entry in seen:
            raise LicenseInvalidError("the feature list is invalid")
        seen.add(entry)


# ---------------------------------------------------------------------------
# request code (outbound)
# ---------------------------------------------------------------------------


def build_request_payload(
    *, install_id: str, hw_hash: str, requested_at: datetime
) -> dict[str, Any]:
    """The versioned canonical request payload (§6).

    Unsigned by construction: it carries an installation id, a one-way
    hardware digest and a timestamp — no secret, no entitlement.
    """
    return {
        "v": LICENSE_VERSION,
        "install_id": install_id,
        "hw_hash": hw_hash,
        "requested_at": _stamp(requested_at),
    }


def build_request_code(payload: Mapping[str, Any]) -> str:
    """Encode a request payload as ``SMPr1.<BASE32>`` (unsigned)."""
    encoded = _b32encode(canonical_json(payload))
    code = f"{REQUEST_PREFIX}.{encoded}"
    if len(code) > MAX_REQUEST_CODE_CHARS:
        raise LicenseInvalidError("the activation request is too long")
    return code


# ---------------------------------------------------------------------------
# activation code (inbound)
# ---------------------------------------------------------------------------


def encode_activation_code(payload: Mapping[str, Any], signature: bytes) -> str:
    """Encode canonical payload + raw signature as ``SMP1.<B32>.<B32>``.

    Format-side helper shared by the License Generator and the tests.
    It performs **no signing and no verification** — the caller supplies
    an already-produced Ed25519 signature over
    ``canonical_json(payload)``.
    """
    if len(signature) != ED25519_SIGNATURE_BYTES:
        raise LicenseInvalidError("the license signature has the wrong length")
    code = f"{ACTIVATION_PREFIX}.{_b32encode(canonical_json(payload))}."
    code += _b32encode(signature)
    if len(code) > MAX_ACTIVATION_CODE_CHARS:
        raise LicenseInvalidError("the activation code is too long")
    return code


def verify_activation_code(
    code: str,
    *,
    keys: Mapping[str, bytes],
    expected_hw_hash: str,
) -> ActivationPayload:
    """Parse, schema-check, signature-check and hardware-bind a code.

    Parameters
    ----------
    code:
        The customer-pasted ``SMP1.…`` activation code.
    keys:
        ``{key_id: 32 raw public-key bytes}`` as loaded by
        `load_verification_keys`.  An empty mapping (shipped state) can
        never verify anything.
    expected_hw_hash:
        The fingerprint of **this** machine, computed server-side.  The
        caller never accepts a client-supplied hash as the authority.

    Raises ``license_invalid`` (format/schema/signature),
    ``license_invalid_key`` (unknown or unusable key) or
    ``license_bound_elsewhere`` (valid code, different machine).
    """
    parts = _split(code, prefix=ACTIVATION_PREFIX, segments=3, what="activation code")
    payload_bytes = _b32decode(parts[1])
    signature = _b32decode(parts[2])

    document = loads_strict(payload_bytes, what="license")
    validate_payload(document)

    if len(signature) != ED25519_SIGNATURE_BYTES:
        raise LicenseInvalidError("the license signature has the wrong length")

    public = keys.get(document["key_id"])
    if public is None:
        raise LicenseInvalidKeyError(
            "the license references an unknown verification key"
        )
    try:
        Ed25519PublicKey.from_public_bytes(public).verify(signature, payload_bytes)
    except (InvalidSignature, ValueError, TypeError) as exc:
        # Deliberately generic: the library's message never reaches a log
        # line or an API response.
        raise LicenseInvalidError("the license signature does not verify") from exc

    if document["hw_hash"] != expected_hw_hash:
        raise LicenseBoundElsewhereError(
            "the license is issued for different hardware"
        )

    issued_at = datetime.fromisoformat(document["issued_at"]).astimezone(UTC)
    return ActivationPayload(
        v=document["v"],
        key_id=document["key_id"],
        license_id=document["license_id"],
        kind=document["kind"],
        issued_at=issued_at,
        hw_hash=document["hw_hash"],
        features=tuple(document["features"]),
        payload_bytes=payload_bytes,
        signature=signature,
    )
