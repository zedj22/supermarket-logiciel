"""Loader and validation for the public Ed25519 verification keys (L0).

Phase L2 activation verifies a license signature against a **public**
verification key selected by the key id embedded in the license (§10.1).
This module only ever loads *public* material — 32 raw bytes per key,
base64-encoded — and refuses anything else.  Private signing keys live in
the offline License Generator, never in this repository or on the server.

File format (JSON, ``new_app/backend/data/license/verification_keys.json``
by default in later phases)::

    {
      "k1": "<standard base64 of exactly 32 raw bytes>",
      "k2": "..."
    }

Tolerance policy mirrors the rest of Phase L0: a **missing** file means
"no keys shipped yet" and loads as an empty mapping (callers then treat
every signature as unverifiable — fail-closed by construction), while a
**malformed** file raises `VerificationKeysError` so a corrupted install
is never silently downgraded to "no keys".
"""

from __future__ import annotations

import base64
import json
import re
from pathlib import Path
from typing import Any

__all__ = [
    "VerificationKeysError",
    "is_valid_key_id",
    "load_verification_keys",
]

#: Ed25519 public key size in bytes (RFC 8032).
ED25519_PUBLIC_KEY_BYTES = 32

#: Key ids travel inside licenses and URL-ish contexts: keep them boring.
_KEY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class VerificationKeysError(Exception):
    """The verification-keys file exists but cannot be trusted.

    Raised for: non-JSON content, a non-object top level, invalid key
    ids, values that are not base64 of exactly 32 bytes, and duplicate
    key ids (which `json.loads` would otherwise silently collapse).
    """


def is_valid_key_id(key_id: object) -> bool:
    """True when `key_id` satisfies the shipped key-id contract.

    The single public predicate for the pattern above, so sibling
    modules (release metadata, the Generator) can validate an id exactly
    the way this loader does instead of re-declaring the regex.
    """
    return isinstance(key_id, str) and bool(_KEY_ID_RE.match(key_id))


def load_verification_keys(path: str | Path) -> dict[str, bytes]:
    """Load `path` as ``{key_id: 32-byte public key}``.

    * File missing → ``{}`` (no keys shipped yet; signatures cannot be
      verified, which callers must treat as fail-closed).
    * File present but invalid → `VerificationKeysError`.

    Raises `OSError` only for unexpected I/O failures other than
    "file not found".
    """
    target = Path(path)
    try:
        raw = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except UnicodeDecodeError as exc:
        raise VerificationKeysError(f"{target.name}: not UTF-8") from exc

    try:
        document: Any = json.loads(raw, object_pairs_hook=_reject_duplicates)
    except ValueError as exc:
        raise VerificationKeysError(f"{target.name}: invalid JSON ({exc})") from exc
    if not isinstance(document, dict):
        raise VerificationKeysError(f"{target.name}: top level must be an object")

    keys: dict[str, bytes] = {}
    for key_id, value in document.items():
        if not isinstance(key_id, str) or not _KEY_ID_RE.match(key_id):
            raise VerificationKeysError(f"{target.name}: invalid key id {key_id!r}")
        if not isinstance(value, str):
            raise VerificationKeysError(
                f"{target.name}: key {key_id!r} must be a base64 string"
            )
        try:
            material = base64.b64decode(value, validate=True)
        except (ValueError, TypeError) as exc:
            raise VerificationKeysError(
                f"{target.name}: key {key_id!r} is not valid base64"
            ) from exc
        if len(material) != ED25519_PUBLIC_KEY_BYTES:
            raise VerificationKeysError(
                f"{target.name}: key {key_id!r} must be "
                f"{ED25519_PUBLIC_KEY_BYTES} bytes, got {len(material)}"
            )
        keys[key_id] = material
    return keys


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """`object_pairs_hook` that fails loudly on duplicate key ids."""
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate key id {key!r}")
        seen.add(key)
    return dict(pairs)
