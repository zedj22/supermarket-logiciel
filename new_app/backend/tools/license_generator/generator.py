"""Strict ``SMPr1`` reading and signed ``SMP1`` issuance (Phase L2-D).

The generator reuses the L2-A contract module directly -
``canonical_json``, ``encode_activation_code``, ``validate_payload`` and
``verify_activation_code`` are imported from
``app.licensing.activation_code`` - so an issued code is byte-exact by
construction and is **self-verified with the backend verifier before it
is ever printed**.

Requests (``SMPr1....``) are unsigned, so this module implements a strict
read-only parser against the same rules L2-A wrote: exactly two segments,
strict unpadded Base32, UTF-8 JSON object, duplicate keys and NaN
rejected, the exact field set, version 1, contract-shaped ids/hashes and
a timezone-bearing ISO-8601 timestamp.  Nothing is "salvaged": the first
violation raises ``RequestFormatError``.

Issuance records a secret-free JSONL ledger line (license id, key id,
install id, issued-at, features - never the hardware hash, never key
material) inside the keystore directory.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
import secrets
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization

from app.core.exceptions import AppError
from app.licensing.activation_code import (
    LICENSE_KIND,
    LICENSE_VERSION,
    MAX_FEATURES,
    MAX_REQUEST_CODE_CHARS,
    REQUEST_PREFIX,
    canonical_json,
    encode_activation_code,
    validate_payload,
    verify_activation_code,
)
from tools.license_generator.errors import IssueError, RequestFormatError
from tools.license_generator.keystore import get_private_key

__all__ = [
    "ActivationRequest",
    "IssuedLicense",
    "ISSUANCE_LOG_NAME",
    "issue_license",
    "parse_request_code",
]

ISSUANCE_LOG_NAME = "issuance_log.jsonl"

#: Exactly the fields `build_request_payload` writes (L2-A).  The set is
#: enforced as a whole - unknown or missing fields are refused.
REQUEST_FIELDS = frozenset({"v", "install_id", "hw_hash", "requested_at"})

#: Mirrors of the L2-A private patterns, pinned to the originals by
#: tests so the generator can never accept something the backend rejects.
_B32_RE = re.compile(r"\A[A-Z2-7]+\Z")
_HW_HASH_RE = re.compile(r"\A[0-9a-f]{64}\Z")
_INSTALL_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_FEATURE_RE = re.compile(r"\A[a-z][a-z0-9_]{0,31}\Z")
_LICENSE_ID_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]{7,63}\Z")

_LEDGER_FIELDS = frozenset(
    {"recorded_at", "license_id", "key_id", "install_id", "issued_at", "features"}
)


@dataclass(frozen=True, slots=True)
class ActivationRequest:
    """A strictly parsed ``SMPr1`` request."""

    install_id: str
    hw_hash: str
    requested_at: datetime
    payload_bytes: bytes


@dataclass(frozen=True, slots=True)
class IssuedLicense:
    """What `issue_license` produced - the code plus its public summary."""

    code: str
    license_id: str
    key_id: str
    install_id: str
    issued_at: str
    hw_hash: str
    features: tuple[str, ...]


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise RequestFormatError(
                f"the request payload contains the duplicate field {key!r}"
            )
        document[key] = value
    return document


def _reject_constant(value: str) -> Any:
    raise RequestFormatError(f"the request payload contains the invalid number {value!r}")


def _decode_segment(segment: str, *, what: str) -> bytes:
    if not _B32_RE.match(segment):
        raise RequestFormatError(
            f"the {what} segment is not strict Base32 (uppercase A-Z and 2-7, unpadded)"
        )
    try:
        return base64.b32decode(segment + "=" * (-len(segment) % 8))
    except (binascii.Error, ValueError) as exc:
        raise RequestFormatError(f"the {what} segment is not decodable Base32") from exc


def parse_request_code(code: object) -> ActivationRequest:
    """Strictly read an ``SMPr1`` activation request.

    Mirrors L2-A's format rules; raises ``RequestFormatError`` on the
    first violation without ever echoing the pasted code back.
    """
    if not isinstance(code, str):
        raise RequestFormatError("the activation request must be text")
    cleaned = code.strip()
    if not cleaned:
        raise RequestFormatError("the activation request is empty")
    if len(cleaned) > MAX_REQUEST_CODE_CHARS:
        raise RequestFormatError(
            f"the activation request is longer than {MAX_REQUEST_CODE_CHARS} characters"
        )
    parts = cleaned.split(".")
    if len(parts) != 2:
        raise RequestFormatError(
            "the activation request must have exactly two segments (SMPr1.<payload>)"
        )
    prefix, payload_segment = parts
    if prefix != REQUEST_PREFIX:
        raise RequestFormatError(
            f"unknown request prefix {prefix!r} (expected {REQUEST_PREFIX!r})"
        )
    if not payload_segment:
        raise RequestFormatError("the request payload segment is empty")
    raw = _decode_segment(payload_segment, what="request payload")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RequestFormatError("the request payload is not UTF-8 text") from exc
    try:
        document = json.loads(
            text,
            object_pairs_hook=_reject_duplicates,
            parse_constant=_reject_constant,
        )
    except RequestFormatError:
        raise
    except ValueError as exc:
        raise RequestFormatError("the request payload is not valid JSON") from exc
    if not isinstance(document, dict):
        raise RequestFormatError("the request payload is not a JSON object")
    if set(document) != REQUEST_FIELDS:
        expected = ", ".join(sorted(REQUEST_FIELDS))
        raise RequestFormatError(
            f"the request payload fields are invalid (expected exactly {expected})"
        )
    version = document["v"]
    if type(version) is not int or version != 1:
        raise RequestFormatError("the request payload version is not supported")
    for field in ("install_id", "hw_hash", "requested_at"):
        if not isinstance(document[field], str):
            raise RequestFormatError(f"the request field {field!r} must be text")
    install_id: str = document["install_id"]
    hw_hash: str = document["hw_hash"]
    requested_at: str = document["requested_at"]
    if not _INSTALL_ID_RE.match(install_id):
        raise RequestFormatError(
            "the installation id is malformed (1-128 characters of "
            "[A-Za-z0-9._-] starting with a letter or digit)"
        )
    if not _HW_HASH_RE.match(hw_hash):
        raise RequestFormatError(
            "the hardware hash must be 64 lowercase hex characters (SHA-256)"
        )
    try:
        requested = datetime.fromisoformat(requested_at)
    except ValueError as exc:
        raise RequestFormatError("the request timestamp is not ISO-8601") from exc
    if requested.tzinfo is None:
        raise RequestFormatError("the request timestamp must carry a UTC offset")
    return ActivationRequest(
        install_id=install_id,
        hw_hash=hw_hash,
        requested_at=requested,
        payload_bytes=canonical_json(document),
    )


def _stamp(moment: datetime) -> str:
    """Second-precision UTC ISO-8601 with ``+00:00`` - never ``Z``.

    Byte-identical to ``app.licensing.activation_code._stamp``; a test
    pins the two implementations together.
    """
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    else:
        moment = moment.astimezone(timezone.utc)
    return moment.replace(microsecond=0).isoformat()


def generate_license_id() -> str:
    """A fresh contract-valid license id - unique per issued license."""
    return "LIC-" + secrets.token_hex(8)


def _normalize_features(features: Iterable[str]) -> tuple[str, ...]:
    if isinstance(features, str):
        raise IssueError(
            "features must be a sequence of names, not a single string "
            '(use ["pos"] rather than "pos")'
        )
    try:
        granted = tuple(features)
    except TypeError as exc:
        raise IssueError("features must be a sequence of names") from exc
    if len(granted) > MAX_FEATURES:
        raise IssueError(f"at most {MAX_FEATURES} features may be granted")
    seen: set[str] = set()
    for feature in granted:
        if not isinstance(feature, str) or not _FEATURE_RE.match(feature):
            raise IssueError(
                f"invalid feature grant {feature!r} - expected 1-32 characters of "
                "[a-z0-9_] starting with a lowercase letter"
            )
        if feature in seen:
            raise IssueError(f"feature {feature!r} is granted twice")
        seen.add(feature)
    return granted


def _append_ledger(key_dir: Path, entry: dict[str, Any]) -> None:
    if set(entry) != _LEDGER_FIELDS:
        raise IssueError(
            "internal: issuance ledger entries may only contain "
            f"{sorted(_LEDGER_FIELDS)} - never hardware hashes or key material"
        )
    path = Path(key_dir) / ISSUANCE_LOG_NAME
    try:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
    except OSError as exc:
        raise IssueError(
            f"could not record the issuance in {path} - the code was withheld"
        ) from exc


def issue_license(
    request_code: object,
    *,
    key_id: str,
    key_dir: Path,
    features: Iterable[str] = ("pos",),
    license_id: str | None = None,
    issued_at: datetime | None = None,
) -> IssuedLicense:
    """Sign a Lifetime activation code for a strictly parsed request.

    Fails closed: the code is returned only after the L2-A contract
    validator and the backend verifier both accept it, and only after the
    secret-free ledger line is on disk.  A missing keystore or key id is
    a ``KeystoreError`` - keys are never generated implicitly.
    """
    request = parse_request_code(request_code)
    granted = _normalize_features(features)
    if license_id is None:
        license_id = generate_license_id()
    elif not isinstance(license_id, str) or not _LICENSE_ID_RE.match(license_id):
        raise IssueError(
            f"invalid license id {license_id!r} - expected 8-64 characters of "
            "[A-Za-z0-9_-] starting with a letter or digit"
        )
    private = get_private_key(key_dir, key_id)
    moment = issued_at if issued_at is not None else datetime.now(timezone.utc)
    payload = {
        "v": LICENSE_VERSION,
        "key_id": key_id,
        "license_id": license_id,
        "kind": LICENSE_KIND,
        "issued_at": _stamp(moment),
        "hw_hash": request.hw_hash,
        "features": list(granted),
    }
    try:
        validate_payload(payload)
    except AppError as exc:
        raise IssueError(
            f"the license payload was rejected by the L2-A contract: {exc}"
        ) from exc
    payload_bytes = canonical_json(payload)
    signature = private.sign(payload_bytes)
    try:
        code = encode_activation_code(payload, signature)
    except AppError as exc:
        raise IssueError(
            "the activation code would exceed the 512-character contract limit - "
            f"grant fewer or shorter features ({len(granted)} granted): {exc}"
        ) from exc

    # Self-verify with the backend's own verifier before anything is printed:
    # if this tool cannot verify it, the customer app never will.
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    try:
        verify_activation_code(
            code,
            keys={key_id: public},
            expected_hw_hash=request.hw_hash,
        )
    except AppError as exc:
        raise IssueError(
            f"self-verification failed - refusing to emit the code: {exc}"
        ) from exc

    _append_ledger(
        key_dir,
        {
            "recorded_at": _stamp(datetime.now(timezone.utc)),
            "license_id": license_id,
            "key_id": key_id,
            "install_id": request.install_id,
            "issued_at": payload["issued_at"],
            "features": list(granted),
        },
    )
    return IssuedLicense(
        code=code,
        license_id=license_id,
        key_id=key_id,
        install_id=request.install_id,
        issued_at=payload["issued_at"],
        hw_hash=request.hw_hash,
        features=granted,
    )
