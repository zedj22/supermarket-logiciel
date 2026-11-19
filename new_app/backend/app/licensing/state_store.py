"""File-based licensing state store (Phase L0 foundations).

Why files and not PostgreSQL: the trial/license state must survive a
database restore *and* must never ride along inside one — `pg_dump` copies
tables, never this directory (§7.5, §11.2).  `LICENSE_STATE_DIR` resolves
to `<backend>/data/license` by default, mirroring `SERVER_ID_FILE`.

On-disk layout (inside the state directory)::

    trial.state           one envelope per state name (JSON, atomic write)
    hmac.key              per-install 32-byte integrity key (DPAPI-sealed
                          when available)

Envelope format::

    {"v": 1, "protection": "dpapi" | "plain",
     "data": "<base64 payload>", "mac": "<hex HMAC-SHA256>"}

Guarantees (Phase L0):

* **Atomic** — write to a temp file in the same directory, fsync, then
  `os.replace`; a crash can never leave a half-written state file, and a
  failed write leaves the previous content untouched.
* **Integrity** — HMAC-SHA256 over the canonical JSON payload with a
  per-install key; a tampered or truncated envelope raises a typed error.
* **Confidentiality** — on Windows the payload (and the HMAC key) are
  wrapped with DPAPI in **machine scope** (`CRYPTPROTECT_LOCAL_MACHINE`),
  so any local account on the machine can decrypt but nothing readable
  leaves the box in plaintext.  Elsewhere (development/test, non-Windows)
  a safe plain fallback is used; the fallback is an explicit choice, never
  a silent downgrade of an already-sealed file.
* **Missing is not an error** — a state file that does not exist yet is
  just "no state" (`None`); Phase L0 ships with no state at all.
* **Corrupted is fail-closed** — unreadable, tampered, truncated or
  wrongly-sealed files raise `StateFileCorruptedError`; callers must
  treat that as "no usable state", never as valid state.

Only *public* licensing state belongs here.  Private signing material
never does (§10.1).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import uuid
from collections.abc import Mapping
from pathlib import Path
from typing import Any

__all__ = [
    "StateFileCorruptedError",
    "StateProtectionUnavailableError",
    "StateStore",
    "StateStoreError",
    "dpapi_available",
]

#: Envelope schema version.  Bump only with a migration for old files.
_ENVELOPE_VERSION = 1

#: HMAC key length in bytes (SHA-256 block size).
_HMAC_KEY_BYTES = 32

#: `protection` values we understand.
_PROTECTION_DPAPI = "dpapi"
_PROTECTION_PLAIN = "plain"

#: State names are path components: reject anything that could escape the
#: directory (`..`, separators, absolute paths) before touching the FS.
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")

# DPAPI flags: never show a UI prompt, and seal to the MACHINE scope so
# every local account on this PC can unprotect (service + interactive).
_CRYPTPROTECT_UI_FORBIDDEN = 0x1
_CRYPTPROTECT_LOCAL_MACHINE = 0x4


class StateStoreError(Exception):
    """Base class for licensing state-store failures."""


class StateFileCorruptedError(StateStoreError):
    """A state (or HMAC key) file exists but cannot be trusted.

    Raised for: non-JSON content, truncated/empty files, MAC mismatch,
    unknown envelope version or protection mode, undecodable payloads and
    unusable HMAC key material.  Callers must treat it as fail-closed —
    the state is absent, not valid.
    """


class StateProtectionUnavailableError(StateStoreError):
    """A file is DPAPI-sealed but this runtime cannot unprotect it.

    Distinct from corruption: the file may be perfectly fine on the
    machine that wrote it.  Raised when a `dpapi` envelope is read with
    DPAPI explicitly disabled or unavailable.
    """


if sys.platform == "win32":  # pragma: no cover - exercised by Windows tests
    import ctypes
    from ctypes import wintypes

    class _DataBlob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_byte))]

    #: DPAPI entry points live in crypt32.dll (documented DLL since
    #: Vista; they are *not* exported by advapi32 on current Windows).
    _DPAPI_OK: bool | None = None

    def dpapi_available() -> bool:
        """True when DPAPI (machine scope) can be used on this host.

        Probed once and cached: the DLLs always exist on Windows, but a
        hardened/odd image could still lack the exports — in that case
        callers fall back to the plain store instead of crashing.
        """
        global _DPAPI_OK
        if _DPAPI_OK is None:
            try:
                crypt32 = ctypes.WinDLL("crypt32")
                bool(crypt32.CryptProtectData)
                bool(crypt32.CryptUnprotectData)
                _DPAPI_OK = True
            except (OSError, AttributeError):
                _DPAPI_OK = False
        return _DPAPI_OK

    def _protect(data: bytes) -> bytes:
        """Seal `data` with `CryptProtectData` (machine scope, no UI)."""
        return _transform(data, protect=True)

    def _unprotect(data: bytes) -> bytes:
        """Unseal data written by `_protect` on this machine."""
        return _transform(data, protect=False)

    def _transform(data: bytes, *, protect: bool) -> bytes:
        crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        func = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
        func.restype = wintypes.BOOL

        buffer = ctypes.create_string_buffer(data, len(data))
        inbound = _DataBlob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
        outbound = _DataBlob()
        flags = _CRYPTPROTECT_UI_FORBIDDEN | _CRYPTPROTECT_LOCAL_MACHINE
        ok = func(
            ctypes.byref(inbound),
            None,
            None,
            None,
            None,
            flags,
            ctypes.byref(outbound),
        )
        if not ok:
            # 13 = ERROR_INVALID_PARAMETER, 5 = ACCESS_DENIED, etc.
            raise StateStoreError(
                f"dpapi_{'protect' if protect else 'unprotect'}_failed"
                f" (winerror={ctypes.get_last_error()})"
            )
        try:
            return ctypes.string_at(outbound.pbData, outbound.cbData)
        finally:
            kernel32.LocalFree(outbound.pbData)

else:

    def dpapi_available() -> bool:
        """DPAPI only exists on Windows."""
        return False

    def _protect(data: bytes) -> bytes:
        raise StateStoreError("dpapi_unavailable")

    def _unprotect(data: bytes) -> bytes:
        raise StateStoreError("dpapi_unavailable")


class StateStore:
    """Read/write named licensing state blobs under one directory.

    Parameters
    ----------
    root:
        State directory (created on first write).
    use_dpapi:
        `True` seals payloads with Windows DPAPI (raises if unavailable),
        `False` uses the plain fallback, `None` (default) auto-selects:
        DPAPI on Windows, plain elsewhere — the development/test path.
    hmac_key:
        Explicit 32-byte integrity key; when omitted one is loaded from
        (or created in) `<root>/hmac.key`.
    """

    def __init__(
        self,
        root: str | Path,
        *,
        use_dpapi: bool | None = None,
        hmac_key: bytes | None = None,
    ) -> None:
        self.root = Path(root)
        if use_dpapi is None:
            use_dpapi = dpapi_available()
        elif use_dpapi and not dpapi_available():
            raise StateStoreError("dpapi_requested_but_unavailable")
        self._dpapi = bool(use_dpapi)
        if hmac_key is not None:
            if len(hmac_key) != _HMAC_KEY_BYTES:
                raise StateStoreError("hmac_key_must_be_32_bytes")
            self._hmac_key: bytes | None = hmac_key
        else:
            self._hmac_key = None  # loaded lazily, only when material is needed

    # ------------------------------------------------------------------
    # paths
    # ------------------------------------------------------------------
    def path_for(self, name: str) -> Path:
        """Absolute path of the envelope for `name` (validated)."""
        if not isinstance(name, str) or not _NAME_RE.match(name):
            raise ValueError(f"invalid state name: {name!r}")
        return self.root / f"{name}.state"

    @property
    def key_path(self) -> Path:
        """Path of the per-install HMAC key file."""
        return self.root / "hmac.key"

    # ------------------------------------------------------------------
    # public API
    # ------------------------------------------------------------------
    def exists(self, name: str) -> bool:
        """True when a state file for `name` is present on disk."""
        return self.path_for(name).is_file()

    def read(self, name: str) -> dict[str, Any] | None:
        """Return the stored mapping, `None` when absent.

        Raises `StateFileCorruptedError` when the file exists but cannot
        be trusted, `StateProtectionUnavailableError` when it is DPAPI-
        sealed and DPAPI is not usable here.
        """
        path = self.path_for(name)
        try:
            raw = path.read_bytes()
        except FileNotFoundError:
            return None
        envelope = self._decode_envelope(raw)
        payload = self._open_payload(envelope, source=str(path))
        try:
            decoded: Any = json.loads(payload)
        except (ValueError, UnicodeDecodeError) as exc:
            raise StateFileCorruptedError(f"{name}: payload is not JSON") from exc
        if not isinstance(decoded, dict):
            raise StateFileCorruptedError(f"{name}: payload is not a JSON object")
        return decoded

    def write(self, name: str, payload: Mapping[str, Any]) -> Path:
        """Atomically store `payload` under `name`; returns the file path."""
        path = self.path_for(name)
        try:
            plaintext = json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
        except (TypeError, ValueError) as exc:
            raise StateStoreError(f"{name}: payload is not JSON-serializable") from exc

        key = self._load_hmac_key(create=True)
        if self._dpapi:
            try:
                sealed = _protect(plaintext)
            except StateStoreError:
                raise
            protection, data = _PROTECTION_DPAPI, sealed
        else:
            protection, data = _PROTECTION_PLAIN, plaintext

        envelope = {
            "v": _ENVELOPE_VERSION,
            "protection": protection,
            "data": base64.b64encode(data).decode("ascii"),
            "mac": hmac.new(key, plaintext, hashlib.sha256).hexdigest(),
        }
        blob = (
            json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode("utf-8")
            + b"\n"
        )
        self._atomic_write(path, blob)
        return path

    def delete(self, name: str) -> bool:
        """Remove the state file for `name`; True if one existed."""
        path = self.path_for(name)
        try:
            path.unlink()
        except FileNotFoundError:
            return False
        return True

    # ------------------------------------------------------------------
    # internals
    # ------------------------------------------------------------------
    def _decode_envelope(self, raw: bytes) -> dict[str, str]:
        """Parse and structurally validate the envelope JSON."""
        source = "envelope"
        try:
            envelope: Any = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise StateFileCorruptedError(f"{source}: not valid JSON") from exc
        if not isinstance(envelope, dict):
            raise StateFileCorruptedError(f"{source}: not a JSON object")
        if envelope.get("v") != _ENVELOPE_VERSION:
            raise StateFileCorruptedError(f"{source}: unsupported version")
        protection = envelope.get("protection")
        if protection not in (_PROTECTION_DPAPI, _PROTECTION_PLAIN):
            raise StateFileCorruptedError(f"{source}: unknown protection mode")
        data = envelope.get("data")
        mac = envelope.get("mac")
        if not isinstance(data, str) or not isinstance(mac, str):
            raise StateFileCorruptedError(f"{source}: missing fields")
        return envelope

    def _open_payload(self, envelope: dict[str, str], *, source: str) -> bytes:
        """Verify integrity and return the plaintext payload bytes."""
        if envelope["protection"] == _PROTECTION_DPAPI:
            if not self._dpapi:
                raise StateProtectionUnavailableError(
                    f"{source}: sealed with DPAPI but DPAPI is unavailable"
                )
            try:
                data = base64.b64decode(envelope["data"], validate=True)
            except (ValueError, TypeError) as exc:
                raise StateFileCorruptedError(f"{source}: undecodable data") from exc
            try:
                plaintext = _unprotect(data)
            except StateStoreError as exc:
                raise StateFileCorruptedError(f"{source}: DPAPI unprotect failed") from exc
        else:
            try:
                plaintext = base64.b64decode(envelope["data"], validate=True)
            except (ValueError, TypeError) as exc:
                raise StateFileCorruptedError(f"{source}: undecodable data") from exc

        try:
            expected = bytes.fromhex(envelope["mac"])
        except ValueError as exc:
            raise StateFileCorruptedError(f"{source}: malformed mac") from exc
        actual = hmac.new(self._load_hmac_key(create=False), plaintext, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, actual):
            raise StateFileCorruptedError(f"{source}: integrity check failed")
        return plaintext

    def _load_hmac_key(self, *, create: bool) -> bytes:
        """Load (or create) the per-install HMAC key."""
        if self._hmac_key is not None:
            return self._hmac_key
        try:
            stored_text = self.key_path.read_text(encoding="ascii").strip()
        except FileNotFoundError:
            if not create:
                raise StateFileCorruptedError("hmac.key is missing") from None
            key = secrets.token_bytes(_HMAC_KEY_BYTES)
            encoded = base64.b64encode(key).decode("ascii")
            if self._dpapi:
                encoded = base64.b64encode(_protect(key)).decode("ascii")
            self._atomic_write(self.key_path, (encoded + "\n").encode("ascii"))
            self._hmac_key = key
            return key
        try:
            material: bytes = base64.b64decode(stored_text, validate=True)
        except (ValueError, TypeError) as exc:
            raise StateFileCorruptedError("hmac.key is not valid base64") from exc
        if self._dpapi:
            try:
                material = _unprotect(material)
            except StateStoreError as exc:
                raise StateFileCorruptedError("hmac.key could not be unsealed") from exc
        if len(material) != _HMAC_KEY_BYTES:
            raise StateFileCorruptedError("hmac.key has the wrong length")
        self._hmac_key = material
        return material

    @staticmethod
    def _atomic_write(path: Path, blob: bytes) -> None:
        """Write `blob` to `path` atomically (temp file + `os.replace`)."""
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            with open(tmp, "wb") as handle:
                handle.write(blob)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, path)
        except OSError as exc:
            try:
                tmp.unlink()
            except OSError:
                pass
            raise StateStoreError(f"atomic write failed for {path.name}") from exc
