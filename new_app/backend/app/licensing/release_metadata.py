"""Release metadata for the packaged public verification keys (R4 §2).

`verification_keys.json` answers *"which public keys may verify an
activation code?"*.  This module answers the release-engineering
question *"what exactly did we ship, and can we prove it later?"* by
recording, for every shipped key id, a **fingerprint** of its public
half:

``app/licensing/release_metadata.json``::

    {
      "format": "supermarket-pro/release-keys",
      "version": 1,
      "keys": {"k1": "sha256:<64 lowercase hex>"}
    }

The fingerprint is ``sha256:`` + the SHA-256 of the raw 32 public bytes
(RFC 8032) — a stable, standard digest an operator can recompute from
the shipped key file without any tooling.  It is **public information**:
it cannot derive the private key and it is safe in the customer package.

Guarantees (all pinned by ``tests/unit/test_release_provisioning.py``):

* the file holds key ids and hex digests **only** — no key bytes, no
  seed, no signature, no hardware identifier, no timestamp that could
  leak operator information;
* a **missing** file means "no release recorded yet" and loads as an
  empty mapping; a **malformed** file raises `ReleaseMetadataError` so a
  corrupted install is never silently read as "no metadata";
* `validate_release_metadata` cross-checks the recorded fingerprints
  against the shipped `verification_keys.json` and fails on any
  mismatch or on a recorded id that is not shipped;
* nothing at runtime writes this file — provisioning is an explicit
  owner-side operation (`tools.license_generator provision-release`).
"""

from __future__ import annotations

import hashlib
import json
import re
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from app.licensing.verification_keys import (
    ED25519_PUBLIC_KEY_BYTES,
    VerificationKeysError,
    is_valid_key_id,
    load_verification_keys,
)

__all__ = [
    "FINGERPRINT_ALGORITHM",
    "RELEASE_METADATA_FORMAT",
    "RELEASE_METADATA_VERSION",
    "ReleaseMetadataError",
    "ReleaseMetadataReport",
    "fingerprints_from_keys",
    "load_release_metadata",
    "public_fingerprint",
    "validate_release_metadata",
    "write_release_metadata",
]

RELEASE_METADATA_FORMAT = "supermarket-pro/release-keys"
RELEASE_METADATA_VERSION = 1
FINGERPRINT_ALGORITHM = "sha256"

_FINGERPRINT_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_ENTRY_FIELDS = frozenset({"format", "version", "keys"})


class ReleaseMetadataError(Exception):
    """The release-metadata file exists but cannot be trusted.

    Raised for: non-JSON content, a non-object top level, an unknown
    format/version, invalid key ids, and fingerprints that are not
    ``sha256:<64 lowercase hex>``.
    """


def public_fingerprint(public: bytes) -> str:
    """``sha256:<hex>`` over the raw 32-byte Ed25519 public key."""
    if not isinstance(public, bytes) or len(public) != ED25519_PUBLIC_KEY_BYTES:
        raise ReleaseMetadataError(
            f"a public key must be exactly {ED25519_PUBLIC_KEY_BYTES} bytes"
        )
    return f"{FINGERPRINT_ALGORITHM}:{hashlib.sha256(public).hexdigest()}"


def fingerprints_from_keys(keys: Mapping[str, bytes]) -> dict[str, str]:
    """``{key_id: fingerprint}`` for a whole shipped key set."""
    return {key_id: public_fingerprint(public) for key_id, public in sorted(keys.items())}


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate field {key!r}")
        seen.add(key)
    return dict(pairs)


def load_release_metadata(path: str | Path) -> dict[str, str]:
    """Load `path` as ``{key_id: fingerprint}``.

    Missing file → ``{}`` (no release recorded yet).  Present but
    invalid → `ReleaseMetadataError`.
    """
    target = Path(path)
    try:
        raw = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except UnicodeDecodeError as exc:
        raise ReleaseMetadataError(f"{target.name}: not UTF-8") from exc

    try:
        document: Any = json.loads(raw, object_pairs_hook=_reject_duplicates)
    except ValueError as exc:
        raise ReleaseMetadataError(f"{target.name}: invalid JSON ({exc})") from exc
    if not isinstance(document, dict):
        raise ReleaseMetadataError(f"{target.name}: top level must be an object")
    if set(document) != _ENTRY_FIELDS:
        raise ReleaseMetadataError(
            f"{target.name}: expected exactly {sorted(_ENTRY_FIELDS)}, "
            f"got {sorted(document)}"
        )
    if document["format"] != RELEASE_METADATA_FORMAT:
        raise ReleaseMetadataError(f"{target.name}: unknown format")
    if document["version"] != RELEASE_METADATA_VERSION:
        raise ReleaseMetadataError(f"{target.name}: unsupported version")
    keys = document["keys"]
    if not isinstance(keys, dict):
        raise ReleaseMetadataError(f"{target.name}: 'keys' must be an object")

    loaded: dict[str, str] = {}
    for key_id, fingerprint in keys.items():
        if not is_valid_key_id(key_id):
            raise ReleaseMetadataError(f"{target.name}: invalid key id {key_id!r}")
        if not isinstance(fingerprint, str) or not _FINGERPRINT_RE.match(fingerprint):
            raise ReleaseMetadataError(
                f"{target.name}: key {key_id!r} must hold a "
                f"{FINGERPRINT_ALGORITHM} fingerprint of 64 lowercase hex digits"
            )
        loaded[key_id] = fingerprint
    return loaded


def write_release_metadata(path: str | Path, fingerprints: Mapping[str, str]) -> None:
    """Atomically write ``{key_id: fingerprint}`` as a release record.

    Refuses anything that is not already a validated fingerprint so a
    typo can never become the shipped record.  The file is public
    material only — this function never receives, and cannot derive, a
    private key.
    """
    target = Path(path)
    entries: dict[str, str] = {}
    for key_id, fingerprint in sorted(fingerprints.items()):
        if not is_valid_key_id(key_id):
            raise ReleaseMetadataError(f"invalid key id {key_id!r}")
        if not isinstance(fingerprint, str) or not _FINGERPRINT_RE.match(fingerprint):
            raise ReleaseMetadataError(
                f"key {key_id!r} must hold a {FINGERPRINT_ALGORITHM} fingerprint "
                "of 64 lowercase hex digits"
            )
        entries[key_id] = fingerprint

    payload = {
        "format": RELEASE_METADATA_FORMAT,
        "version": RELEASE_METADATA_VERSION,
        "keys": entries,
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=target.parent,
        prefix=target.name,
        suffix=".tmp",
        delete=False,
    )
    temp_path = Path(handle.name)
    try:
        with handle:
            handle.write(text)
        if load_release_metadata(temp_path) != entries:
            raise ReleaseMetadataError(
                f"refusing to write {target}: the record failed re-validation"
            )
        temp_path.replace(target)
    finally:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)


@dataclass(frozen=True, slots=True)
class ReleaseMetadataReport:
    """What a cross-check of the shipped keys against the record found."""

    #: shipped key ids whose recorded fingerprint matches the key file
    matched: tuple[str, ...]
    #: shipped key ids with **no** recorded fingerprint (provisioning gap)
    unrecorded: tuple[str, ...]

    @property
    def ok(self) -> bool:
        """True when every shipped key id is recorded and correct."""
        return not self.unrecorded


def validate_release_metadata(
    keys_path: str | Path,
    metadata_path: str | Path,
    *,
    strict: bool = True,
) -> ReleaseMetadataReport:
    """Cross-check `metadata_path` against the shipped `keys_path`.

    Fails with `ReleaseMetadataError` when a recorded key id is not
    shipped (the record claims a key the package does not carry) or when
    a recorded fingerprint does not match the shipped public key.

    ``strict`` (the default) additionally fails when a shipped key id is
    missing from the record — a release must record every key it ships.
    ``strict=False`` downgrades that to `ReleaseMetadataReport.unrecorded`
    so a partial inspection can still report the other failures.
    """
    try:
        shipped = load_verification_keys(keys_path)
    except VerificationKeysError as exc:
        raise ReleaseMetadataError(
            f"the shipped verification keys cannot be trusted ({exc})"
        ) from exc
    recorded = load_release_metadata(metadata_path)

    unknown = sorted(set(recorded) - set(shipped))
    if unknown:
        raise ReleaseMetadataError(
            f"{Path(metadata_path).name}: records key id(s) {', '.join(unknown)} "
            f"that are not present in {Path(keys_path).name}"
        )

    mismatched = sorted(
        key_id
        for key_id in recorded
        if recorded[key_id] != public_fingerprint(shipped[key_id])
    )
    if mismatched:
        raise ReleaseMetadataError(
            f"{Path(metadata_path).name}: fingerprint(s) for "
            f"{', '.join(mismatched)} do not match the shipped public keys"
        )

    unrecorded = tuple(sorted(set(shipped) - set(recorded)))
    if strict and unrecorded:
        raise ReleaseMetadataError(
            f"{Path(metadata_path).name}: shipped key id(s) "
            f"{', '.join(unrecorded)} are not recorded"
        )
    return ReleaseMetadataReport(
        matched=tuple(sorted(recorded)),
        unrecorded=unrecorded,
    )
