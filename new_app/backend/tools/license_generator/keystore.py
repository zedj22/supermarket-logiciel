"""Private signing-key storage for the offline License Generator (Phase L2-D).

Holds Ed25519 keypairs under explicit key ids in one dedicated file,
``signing_keystore.json``, in a directory the operator chooses.  The
directory defaults to a location **outside every git work tree** and a
key directory that sits inside one is refused outright - private key
material must never end up in an ordinary repository file.

Security invariants (all pinned by `tests/unit/test_license_generator.py`):

* keys are only ever created by an explicit ``keygen --key-id ...``;
  ``issue`` / ``export-key`` / ``list-keys`` never generate anything
  silently and never replace or delete an existing key id;
* entries store only base64 Ed25519 seeds and public halves; exports and
  logs carry public material only;
* the file is written atomically with best-effort ``0600`` permissions;
* loading re-derives every public half from its seed - a tampered or
  half-written entry is rejected instead of trusted.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)

from tools.license_generator.errors import KeystoreError

__all__ = [
    "DEFAULT_ENV_VAR",
    "DEFAULT_HOME",
    "KEY_STORE_FORMAT",
    "KEY_STORE_NAME",
    "KEY_STORE_VERSION",
    "StoredKey",
    "ensure_key_dir_allowed",
    "generate_keypair",
    "get_private_key",
    "get_public_keys",
    "load_keystore",
    "merge_verification_keys",
    "public_entry",
    "resolve_key_dir",
    "save_keystore",
]

KEY_STORE_NAME = "signing_keystore.json"
KEY_STORE_FORMAT = "supermarket-pro/license-generator-keystore"
KEY_STORE_VERSION = 1
ED25519_SEED_BYTES = 32
DEFAULT_ENV_VAR = "SP_LICENSE_GENERATOR_HOME"
DEFAULT_HOME = Path.home() / ".supermarket-pro" / "license_generator"

#: Identical pattern string to `app.licensing.verification_keys._KEY_ID_RE`
#: (anchors included) - a test pins the two together so the generator can
#: never accept an id the backend would refuse (or vice versa).
_KEY_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

_ENTRY_FIELDS = frozenset({"created_at", "label", "private", "public"})


@dataclass(frozen=True, slots=True)
class StoredKey:
    """One keystore entry: explicit id, timestamp, label, raw key bytes."""

    key_id: str
    created_at: str
    label: str
    private_seed: bytes
    public: bytes


def resolve_key_dir(explicit: str | Path | None = None) -> Path:
    """Resolve the keystore directory: CLI ``--key-dir`` > env > default."""
    if explicit is not None:
        text = str(explicit)
        if not text.strip():
            raise KeystoreError("--key-dir is empty")
        return Path(text).expanduser()
    env = os.environ.get(DEFAULT_ENV_VAR, "").strip()
    if env:
        return Path(env).expanduser()
    return DEFAULT_HOME


def ensure_key_dir_allowed(key_dir: Path) -> None:
    """Refuse any directory that lives inside a git work tree."""
    target = Path(key_dir).expanduser().resolve()
    for parent in (target, *target.parents):
        if (parent / ".git").exists():
            raise KeystoreError(
                f"refusing to use {target}: private keys must never live inside "
                f"a git work tree ({parent} contains .git) - choose a key "
                "directory outside the repository"
            )


def _require_key_id(key_id: str) -> str:
    if not isinstance(key_id, str) or not _KEY_ID_RE.match(key_id):
        raise KeystoreError(
            f"invalid key id {key_id!r} - expected 1-64 characters of "
            "[A-Za-z0-9_-] starting with a letter or digit"
        )
    return key_id


def _b64encode(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _b64decode(value: object, *, where: str) -> bytes:
    if not isinstance(value, str):
        raise KeystoreError(f"keystore entry {where} is not base64 text")
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise KeystoreError(f"keystore entry {where} is not valid base64") from exc


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise KeystoreError(f"keystore contains duplicate field {key!r}")
        document[key] = value
    return document


def _derived_public(private_seed: bytes) -> bytes:
    private = Ed25519PrivateKey.from_private_bytes(private_seed)
    return private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )


def _entry_to_key(key_id: str, entry: object) -> StoredKey:
    if not isinstance(entry, dict):
        raise KeystoreError(f"keystore entry {key_id!r} is not a JSON object")
    if set(entry) != _ENTRY_FIELDS:
        raise KeystoreError(
            f"keystore entry {key_id!r} has unexpected fields "
            f"(expected exactly {sorted(_ENTRY_FIELDS)})"
        )
    created_at = entry["created_at"]
    label = entry["label"]
    if not isinstance(created_at, str) or not isinstance(label, str):
        raise KeystoreError(f"keystore entry {key_id!r} has a non-text field")
    private_seed = _b64decode(entry["private"], where=f"{key_id}.private")
    public = _b64decode(entry["public"], where=f"{key_id}.public")
    if len(private_seed) != ED25519_SEED_BYTES:
        raise KeystoreError(
            f"keystore entry {key_id!r} does not hold a 32-byte Ed25519 seed"
        )
    if len(public) != ED25519_SEED_BYTES:
        raise KeystoreError(
            f"keystore entry {key_id!r} does not hold a 32-byte public key"
        )
    try:
        derived = _derived_public(private_seed)
    except ValueError as exc:
        raise KeystoreError(f"keystore entry {key_id!r} holds an unusable seed") from exc
    if derived != public:
        raise KeystoreError(
            f"keystore entry {key_id!r} is inconsistent - its public half does "
            "not match its private half (restore the file from backup; never "
            "generate a replacement over it)"
        )
    return StoredKey(
        key_id=key_id,
        created_at=created_at,
        label=label,
        private_seed=private_seed,
        public=public,
    )


def load_keystore(key_dir: Path) -> dict[str, StoredKey]:
    """Read the keystore; a missing file is an empty store, garbage is fatal."""
    path = Path(key_dir) / KEY_STORE_NAME
    if not path.exists():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise KeystoreError(f"cannot read the keystore at {path}") from exc
    try:
        document = json.loads(text, object_pairs_hook=_reject_duplicates)
    except KeystoreError:
        raise
    except (ValueError, UnicodeDecodeError) as exc:
        raise KeystoreError(f"the keystore at {path} is not valid JSON") from exc
    if not isinstance(document, dict):
        raise KeystoreError(f"the keystore at {path} is not a JSON object")
    return _load_entries(document, path)


def _load_entries(document: dict[str, Any], path: Path) -> dict[str, StoredKey]:
    if (
        document.get("format") != KEY_STORE_FORMAT
        or document.get("version") != KEY_STORE_VERSION
        or not isinstance(document.get("keys"), dict)
    ):
        raise KeystoreError(
            f"the keystore at {path} is not a recognized {KEY_STORE_FORMAT} document"
        )
    entries: Any = document["keys"]
    store: dict[str, StoredKey] = {}
    for key_id, entry in entries.items():
        if not isinstance(key_id, str) or not _KEY_ID_RE.match(key_id):
            raise KeystoreError(f"the keystore at {path} has an invalid key id {key_id!r}")
        store[key_id] = _entry_to_key(key_id, entry)
    return store


def save_keystore(key_dir: Path, store: dict[str, StoredKey]) -> None:
    """Write the keystore atomically with best-effort ``0600`` permissions."""
    target_dir = Path(key_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "format": KEY_STORE_FORMAT,
        "version": KEY_STORE_VERSION,
        "keys": {
            key_id: {
                "created_at": key.created_at,
                "label": key.label,
                "private": _b64encode(key.private_seed),
                "public": _b64encode(key.public),
            }
            for key_id, key in sorted(store.items())
        },
    }
    text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=target_dir,
        prefix=KEY_STORE_NAME,
        suffix=".tmp",
        delete=False,
    )
    temp_path = Path(handle.name)
    try:
        with handle:
            handle.write(text)
        try:
            os.chmod(temp_path, 0o600)
        except OSError:
            pass  # best effort - Windows may not honour POSIX modes
        os.replace(temp_path, target_dir / KEY_STORE_NAME)
    finally:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)


def generate_keypair(key_dir: Path, key_id: str, label: str = "") -> bytes:
    """Create one new keypair under an explicit id; returns the public half.

    An existing id is never replaced or deleted - rotation always means a
    *new* key id so previously issued licenses keep verifying.
    """
    _require_key_id(key_id)
    ensure_key_dir_allowed(key_dir)
    store = load_keystore(key_dir)
    if key_id in store:
        raise KeystoreError(
            f"key id {key_id!r} already exists - rotation means a NEW key id; "
            "existing keys are never replaced or deleted"
        )
    private = Ed25519PrivateKey.generate()
    private_seed = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    store[key_id] = StoredKey(
        key_id=key_id,
        created_at=datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        label=str(label),
        private_seed=private_seed,
        public=public,
    )
    save_keystore(key_dir, store)
    return public


def get_private_key(key_dir: Path, key_id: str) -> Ed25519PrivateKey:
    """Load a private key for signing - never creates anything implicitly."""
    _require_key_id(key_id)
    ensure_key_dir_allowed(key_dir)
    path = Path(key_dir) / KEY_STORE_NAME
    store = load_keystore(key_dir)
    if not store and not path.exists():
        raise KeystoreError(
            f"no keystore at {path} - keys are never generated implicitly; "
            "create one explicitly with `keygen --key-id ...`"
        )
    if key_id not in store:
        known = ", ".join(sorted(store)) or "none"
        raise KeystoreError(
            f"unknown key id {key_id!r} (existing key ids: {known}) - run "
            "`keygen --key-id ...` to create a new key; existing keys are never "
            "replaced"
        )
    return Ed25519PrivateKey.from_private_bytes(store[key_id].private_seed)


def get_public_keys(key_dir: Path) -> dict[str, bytes]:
    """Public halves of every keystore key (used by `verify`)."""
    ensure_key_dir_allowed(key_dir)
    return {key_id: key.public for key_id, key in load_keystore(key_dir).items()}


def public_entry(key_id: str, public: bytes) -> dict[str, str]:
    """The one-key public entry the backend's verification_keys.json holds."""
    _require_key_id(key_id)
    if len(public) != ED25519_SEED_BYTES:
        raise KeystoreError("an Ed25519 public key must be exactly 32 bytes")
    return {key_id: _b64encode(public)}


def merge_verification_keys(target: Path, entry: dict[str, str]) -> dict[str, str]:
    """Merge one public entry into ``target`` preserving every existing id.

    Existing key ids are never overwritten: same value is idempotent, a
    different value for a known id is refused (older licenses depend on
    it).  The result is validated through the backend's own
    ``load_verification_keys`` **before** it replaces anything.
    """
    from app.licensing.verification_keys import VerificationKeysError, load_verification_keys

    if len(entry) != 1:
        raise KeystoreError("an export entry must hold exactly one key id")
    (key_id, encoded), = entry.items()
    _require_key_id(key_id)
    public = _b64decode(encoded, where=key_id)
    if len(public) != ED25519_SEED_BYTES:
        raise KeystoreError(f"key id {key_id!r} does not hold a 32-byte public key")

    try:
        existing = load_verification_keys(target)
    except VerificationKeysError as exc:
        raise KeystoreError(
            f"refusing to update {target}: its current contents cannot be "
            f"trusted ({exc}) - restore it from a known-good copy first"
        ) from exc
    if key_id in existing:
        if existing[key_id] == public:
            return {kid: _b64encode(value) for kid, value in existing.items()}
        raise KeystoreError(
            f"key id {key_id!r} already exists in {target} with a DIFFERENT "
            "public key - refusing to replace it (issued licenses depend on it)"
        )
    merged_bytes = dict(existing)
    merged_bytes[key_id] = public
    merged = {kid: _b64encode(value) for kid, value in merged_bytes.items()}

    target.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(merged, indent=2, sort_keys=True) + "\n"
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
        try:
            reloaded = load_verification_keys(temp_path)
        except VerificationKeysError as exc:
            raise KeystoreError(
                f"refusing to update {target}: the merged key set failed "
                f"re-validation ({exc})"
            ) from exc
        if reloaded != merged_bytes:
            raise KeystoreError(
                f"refusing to update {target}: the merged key set failed "
                "re-validation"
            )
        os.replace(temp_path, target)
    finally:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)
    return merged
