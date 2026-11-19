"""Release provisioning — publish public keys and record the release (R4 §2).

The one owner-side operation that turns a keypair in the offline
keystore into a **shipped** verification key plus its release record.
It is deliberately narrow:

* keys are only ever **read** here — an id that does not already exist
  fails with `KeystoreError`, so this command can never generate a
  production key implicitly (`keygen --key-id …` stays the only way to
  create one, and is never called from here);
* `verification_keys.json` is updated through the existing, tested
  :func:`tools.license_generator.keystore.merge_verification_keys`, so
  every previously shipped id keeps its exact value and a known id with
  a *different* public key is refused;
* `release_metadata.json` is written only after every conflict has been
  pre-checked, so a refusal can never leave the two files disagreeing;
* both files are re-validated through the backend's own loaders before
  the function returns;
* nothing here reads, writes, prints or copies a private half — the
  input is `StoredKey.public` and nothing else.

Runs on the owner's machine like the rest of the Generator
(``python -m tools.license_generator provision-release …``).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from app.licensing.release_metadata import (
    ReleaseMetadataError,
    fingerprints_from_keys,
    load_release_metadata,
    validate_release_metadata,
    write_release_metadata,
)
from app.licensing.verification_keys import (
    VerificationKeysError,
    load_verification_keys,
)
from tools.license_generator import keystore
from tools.license_generator.errors import KeystoreError

__all__ = ["ReleaseProvisioningResult", "provision_release"]


@dataclass(frozen=True, slots=True)
class ReleaseProvisioningResult:
    """What one provisioning pass published (public material only)."""

    key_ids: tuple[str, ...]
    fingerprints: tuple[tuple[str, str], ...]
    keys_out: Path
    metadata_out: Path
    dry_run: bool

    @property
    def recorded(self) -> dict[str, str]:
        """Every key id the release record now carries (not just the new)."""
        return dict(self.fingerprints)


def _conflict(key_id: str, where: Path) -> KeystoreError:
    return KeystoreError(
        f"key id {key_id!r} already exists in {where} with a DIFFERENT public key "
        "- refusing to replace it (issued licenses depend on it)"
    )


def provision_release(
    *,
    key_dir: Path,
    key_ids: list[str] | tuple[str, ...],
    keys_out: str | Path,
    metadata_out: str | Path,
    dry_run: bool = False,
) -> ReleaseProvisioningResult:
    """Publish `key_ids` into `keys_out` and record them in `metadata_out`.

    Every step is validated before anything is written: an unknown key
    id, a conflicting public key, an untrusted target file or an
    inconsistent release record aborts the whole pass with nothing
    changed.  `dry_run=True` performs the same checks and writes nothing.
    """
    if not key_ids:
        raise KeystoreError(
            "at least one --key-id is required - keys are never provisioned implicitly"
        )
    if len(set(key_ids)) != len(key_ids):
        raise KeystoreError("duplicate --key-id: each key id may be given once")

    key_dir = Path(key_dir)
    keystore.ensure_key_dir_allowed(key_dir)
    # Read-only: load_keystore never creates, replaces or deletes a key.
    store = keystore.load_keystore(key_dir)

    for key_id in key_ids:
        if key_id not in store:
            known = ", ".join(sorted(store)) or "none"
            raise KeystoreError(
                f"unknown key id {key_id!r} (existing key ids: {known}) - "
                "provisioning only publishes keys created by an explicit "
                "`keygen --key-id ...`"
            )

    keys_path = Path(keys_out)
    metadata_path = Path(metadata_out)

    try:
        shipped = load_verification_keys(keys_path)
    except VerificationKeysError as exc:
        raise KeystoreError(
            f"refusing to update {keys_path}: its current contents cannot be "
            f"trusted ({exc}) - restore it from a known-good copy first"
        ) from exc

    # The set this pass would leave behind, computed before any write.
    prospective = dict(shipped)
    for key_id in key_ids:
        public = store[key_id].public
        if key_id in prospective and prospective[key_id] != public:
            raise _conflict(key_id, keys_path)
        prospective[key_id] = public

    fingerprints = fingerprints_from_keys(prospective)
    try:
        recorded = load_release_metadata(metadata_path)
    except ReleaseMetadataError as exc:
        raise KeystoreError(
            f"refusing to update {metadata_path}: its current contents cannot be "
            f"trusted ({exc}) - restore it from a known-good copy first"
        ) from exc
    for key_id, fingerprint in recorded.items():
        if key_id not in fingerprints:
            raise KeystoreError(
                f"{metadata_path} records key id {key_id!r} which is not present "
                f"in {keys_path} - restore a consistent pair before provisioning"
            )
        if fingerprints[key_id] != fingerprint:
            raise KeystoreError(
                f"key id {key_id!r} is already recorded in {metadata_path} with a "
                "DIFFERENT fingerprint - refusing to replace it (issued licenses "
                "depend on it)"
            )

    result = ReleaseProvisioningResult(
        key_ids=tuple(key_ids),
        fingerprints=tuple(sorted(fingerprints.items())),
        keys_out=keys_path,
        metadata_out=metadata_path,
        dry_run=dry_run,
    )

    if dry_run:
        return result

    # Both conflict sets are empty, so these two writes cannot fail on a
    # content check; `merge_verification_keys` still re-validates through
    # the backend loader immediately before replacing the file.
    for key_id in key_ids:
        keystore.merge_verification_keys(
            keys_path, keystore.public_entry(key_id, store[key_id].public)
        )
    written = load_verification_keys(keys_path)
    if written != prospective:
        raise KeystoreError(
            f"refusing to continue: {keys_path} does not hold the expected key set"
        )
    write_release_metadata(metadata_path, fingerprints)

    # Final proof: the shipped pair is consistent, strictly.
    validate_release_metadata(keys_path, metadata_path, strict=True)
    return result
