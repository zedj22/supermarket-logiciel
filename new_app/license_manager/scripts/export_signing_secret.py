"""Export the staging Ed25519 signing seed as a License Manager runtime secret.

The running service never generates key material: it *reads* two mounted files
(``service/secrets.py::FileSecretFetcher``).  This script is the owner-side step
that turns the offline keystore entry into the first of them::

    signing_keystore.json  ──(read-only)──►  LICENSE_API_SIGNING_SECRET
                                             {"key_id": "...", "seed_b64": "..."}

Invariants (each one is deliberate):

* **Read-only source.**  It loads the keystore with the existing backend
  function ``tools.license_generator.keystore.load_keystore`` and never calls
  ``save_keystore``, ``generate_keypair`` or ``merge_verification_keys``.  The
  keystore is therefore never rewritten, renamed, chmod-ed or replaced, and the
  script proves it: it hashes the file in memory before and after the export
  and prints only whether it changed.
* **Exclusive output.**  ``O_CREAT | O_EXCL`` means an existing file is never
  overwritten — neither a previous secret nor (by construction) the keystore,
  which lives in a differently named file.  Mode ``0600`` is requested where the
  platform honours it; on Windows it is advisory and real protection comes from
  the directory's ACL, so the path must be on a private volume.
* **No secret in output.**  The seed is base64-encoded straight into the file.
  Nothing prints the seed, the JSON, ``repr(store)`` or ``repr(key)``; on
  success the script names the key id and the output path only, and on failure
  it prints a one-line reason that carries no key material.
* **Outside the repository.**  The output may not live inside this checkout or
  inside any Git work tree, so a secret file can never be committed or swept
  into a Docker build context.

The runtime format is fixed by ``service/signing.py::load_signing_key``: exactly
``key_id`` and ``seed_b64``, the latter decoding to 32 bytes.

Usage::

    python scripts/export_signing_secret.py \
        --key-dir <keystore-directory> \
        --key-id stg-2026-11 \
        --out <path>/LICENSE_API_SIGNING_SECRET
"""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any

SCRIPT_PATH = Path(__file__).resolve()
#: ``license_manager/scripts/export_signing_secret.py`` → ``license_manager``
LICENSE_MANAGER_ROOT = SCRIPT_PATH.parents[1]
#: → ``new_app`` (the directory that holds ``backend`` and ``license_manager``)
NEW_APP_ROOT = LICENSE_MANAGER_ROOT.parent
#: Where ``app`` and ``tools`` live; ``keystore.py`` is imported from here.
BACKEND_ROOT = NEW_APP_ROOT / "backend"

#: The runtime secret contract — ``service/signing.py::_SIGNING_SECRET_FIELDS``
#: and ``ED25519_SEED_BYTES``.  Nothing else may appear in the file.
RUNTIME_FIELDS = frozenset({"key_id", "seed_b64"})
SEED_BYTES = 32

#: Process exit code for any refusal (argparse itself uses 2 as well).
EXIT_REFUSED = 2


class ExportError(RuntimeError):
    """A refusal this script can explain without revealing key material."""


# --------------------------------------------------------------------------- #
# Import the backend's keystore module (read-only API only)
# --------------------------------------------------------------------------- #
def _keystore_module() -> Any:
    """Import ``tools.license_generator.keystore`` from ``new_app/backend``.

    The backend is resolved from this file's own location, so the script works
    from any current directory and never depends on ``PYTHONPATH``.  Only the
    keystore module is imported; the CLI is deliberately not, so no command
    path that could write a keystore is ever reachable from here.
    """
    keystore_file = BACKEND_ROOT / "tools" / "license_generator" / "keystore.py"
    if not keystore_file.is_file():
        raise ExportError(
            f"the KlickPOS backend keystore module was not found at {keystore_file}"
        )
    target = str(BACKEND_ROOT)
    if target in sys.path:
        sys.path.remove(target)
    sys.path.insert(0, target)
    from tools.license_generator import keystore  # noqa: PLC0415 - path set above

    return keystore


# --------------------------------------------------------------------------- #
# Path guards
# --------------------------------------------------------------------------- #
def _git_work_tree(path: Path) -> Path | None:
    """The nearest ancestor that is a Git work tree, or ``None``."""
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def _guard_output(out: str | Path) -> Path:
    """Resolve the output path and refuse anything inside a repository."""
    resolved = Path(out).expanduser().resolve()
    repository = NEW_APP_ROOT.resolve()
    if resolved == repository or repository in resolved.parents:
        raise ExportError(
            f"refusing to write {resolved}: the runtime secret must stay "
            f"outside this project ({repository})"
        )
    work_tree = _git_work_tree(resolved.parent)
    if work_tree is not None:
        raise ExportError(
            f"refusing to write {resolved}: private key material must never "
            f"live inside a git work tree ({work_tree} contains .git)"
        )
    if not resolved.parent.is_dir():
        raise ExportError(f"the output directory {resolved.parent} does not exist")
    if resolved.exists():
        # Reported here for a clear message; the write itself is also O_EXCL.
        raise ExportError(f"refusing to overwrite the existing file {resolved}")
    return resolved


def _guard_key_dir(key_dir: str | Path) -> Path:
    """Resolve the keystore directory and require it to exist."""
    resolved = Path(key_dir).expanduser().resolve()
    if not resolved.is_dir():
        raise ExportError(f"the keystore directory {resolved} does not exist")
    return resolved


def _keystore_file(key_dir: Path, keystore: Any) -> Path:
    """The keystore file itself, which must be an existing regular file."""
    path = key_dir / keystore.KEY_STORE_NAME
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise ExportError(
            f"no keystore at {path} - keys are never generated by this script"
        ) from exc
    except OSError as exc:
        raise ExportError(f"cannot inspect the keystore at {path}") from exc
    if path.is_symlink() or not stat.S_ISREG(info.st_mode):
        raise ExportError(f"the keystore at {path} is not a regular file")
    return path


def _snapshot(path: Path) -> tuple[int, int, str]:
    """Size, mtime and content digest — compared in memory, never printed."""
    try:
        info = path.stat()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise ExportError(f"cannot read the keystore at {path}") from exc
    return (info.st_size, info.st_mtime_ns, digest)


# --------------------------------------------------------------------------- #
# Selection, serialization, validation
# --------------------------------------------------------------------------- #
def _select_key(store: dict[str, Any], key_id: str) -> Any:
    """The one entry for ``key_id``; a missing or inconsistent id is fatal."""
    if not store:
        raise ExportError("the keystore holds no keys")
    key = store.get(key_id)
    if key is None:
        known = ", ".join(sorted(store))
        raise ExportError(f"key id {key_id!r} is not in the keystore (found: {known})")
    if key.key_id != key_id:
        # The loader derives key_id from the JSON object key, so this is a
        # defensive check rather than an expected state.
        raise ExportError(
            f"the keystore entry for {key_id!r} reports a different key id"
        )
    return key


def _runtime_payload(key: Any) -> bytes:
    """Serialize ``{"key_id", "seed_b64"}`` as UTF-8 bytes (nothing printed)."""
    seed = key.private_seed
    if not isinstance(seed, bytes) or len(seed) != SEED_BYTES:
        raise ExportError(
            f"the loaded signing seed is not exactly {SEED_BYTES} bytes"
        )
    document = {
        "key_id": key.key_id,
        "seed_b64": base64.b64encode(seed).decode("ascii"),
    }
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_exclusive(out: Path, payload: bytes) -> None:
    """Create ``out`` exclusively, write, flush, fsync; never overwrite."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    try:
        descriptor = os.open(os.fspath(out), flags, 0o600)
    except FileExistsError as exc:
        raise ExportError(f"refusing to overwrite the existing file {out}") from exc
    except OSError as exc:
        raise ExportError(
            f"cannot create {out}: {exc.strerror or type(exc).__name__}"
        ) from exc
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        # Only the file this call created is removed; the keystore is untouched.
        with contextlib.suppress(OSError):
            out.unlink()
        raise


def _validate_output_file(out: Path, expected_key_id: str) -> None:
    """Re-read the new file and check it, without printing any value."""
    try:
        raw = out.read_bytes()
    except OSError as exc:
        raise ExportError(f"cannot re-read the written file {out}") from exc
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ExportError("the written file is not valid UTF-8 JSON") from exc
    if not isinstance(document, dict):
        raise ExportError("the written file is not a JSON object")
    if set(document) != RUNTIME_FIELDS:
        raise ExportError(
            "the written file does not contain exactly key_id and seed_b64"
        )
    if document["key_id"] != expected_key_id:
        raise ExportError("the written file carries an unexpected key id")
    encoded = document["seed_b64"]
    if not isinstance(encoded, str):
        raise ExportError("the written seed_b64 is not text")
    try:
        seed = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ExportError("the written seed_b64 is not valid base64") from exc
    if len(seed) != SEED_BYTES:
        raise ExportError(
            f"the written seed does not decode to {SEED_BYTES} bytes"
        )
    # Deliberately dropped: the decoded seed never leaves this scope.


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="export_signing_secret.py",
        description=(
            "Export one signing key from the offline keystore as the License "
            "Manager runtime secret. Reads the keystore read-only, never "
            "overwrites an existing file and never prints private material."
        ),
    )
    parser.add_argument(
        "--key-dir",
        required=True,
        metavar="DIR",
        help="directory holding signing_keystore.json (outside the repository)",
    )
    parser.add_argument(
        "--key-id",
        required=True,
        metavar="ID",
        help="existing key id to export (staging: stg-2026-11)",
    )
    parser.add_argument(
        "--out",
        required=True,
        metavar="FILE",
        help="new file to create, e.g. <private-dir>/LICENSE_API_SIGNING_SECRET",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        # 1. The destination is checked before the keystore is opened at all.
        out = _guard_output(args.out)
        key_dir = _guard_key_dir(args.key_dir)
        keystore = _keystore_module()
        keystore_path = _keystore_file(key_dir, keystore)

        # 2. Read-only load, then the exact key the operator named.
        before = _snapshot(keystore_path)
        store = keystore.load_keystore(key_dir)
        key = _select_key(store, args.key_id)
        payload = _runtime_payload(key)

        # 3. Exclusive create; on any later failure only that file is removed.
        _write_exclusive(out, payload)
        try:
            _validate_output_file(out, args.key_id)
            after = _snapshot(keystore_path)
            if before != after:
                raise ExportError(
                    "the source keystore changed during the export; the "
                    "written file has been removed"
                )
        except BaseException:
            with contextlib.suppress(OSError):
                out.unlink()
            raise
        del payload, store, key
    except ExportError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_REFUSED
    except Exception as exc:  # noqa: BLE001 - class name only, never a value
        print(f"error: {type(exc).__name__}", file=sys.stderr)
        return EXIT_REFUSED

    # 4. Success: key id, path, and whether the keystore stayed unchanged.
    print(f"exported key id {args.key_id!r} to {out}")
    print("source keystore unchanged: yes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
