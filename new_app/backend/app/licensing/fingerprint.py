"""Hardware fingerprint — Phase L1-A of the licensing system.

Implements §4.3: a stable SHA-256 fingerprint of three Windows
identifiers — the registry ``MachineGuid``, the system volume serial and
the hostname — rendered as a grouped Base32 display code.  The value
binds a **Lifetime** license to one machine (§6.1); it is *never* used
for backup restore (§4.3), never written to logs or API responses, and
is one-way: neither the digest nor the display code reveals an input.

Construction (§4.3 / §13.1)
----------------------------
The three identifiers are read fresh on every call (no cache), each one
normalised (trimmed, case-folded, braces / ``0x`` / separator noise
removed), then hashed as::

    SHA-256( b"supermarket-pro/hardware-fingerprint/v1"
             || u32be(len) || utf8(machine_guid)
             || u32be(len) || utf8(system_volume_serial)
             || u32be(len) || utf8(hostname) )

The fixed domain-separation tag and the big-endian length prefixes make
the byte stream unambiguous: no two different identifier triples can be
made to hash alike by re-drawing the boundaries between values.  The
digest is 64 lowercase hex characters; `display_code` re-encodes it as
Base32 (``A-Z2-7``, padding stripped) in groups of four joined by
``-`` — 13 groups — so a human can read the code off one machine and
type it on another without ever seeing a raw identifier.

Hardware changes and honest limitations (§4.4 / §13.1)
------------------------------------------------------
* The fingerprint is stable across reboots and program restarts on an
  unchanged installation (§13.1) and changes when **any** of the three
  inputs changes: a reinstalled OS (new MachineGuid), a reformatted
  system volume, or a renamed computer.  A Lifetime license bound before
  such a change stops matching; recovery is the §6.3 support-side rebind
  flow, never an automatic fallback.
* No TPM and no DPAPI are involved: the inputs are ordinary readable
  machine identifiers, so the fingerprint works on any supported
  Windows box (§4.3).
* It is a cost raiser, not a secret: a local administrator can read the
  same three values and recompute the digest, or patch the backend.
  It is never the sole protection for anything.
* An identifier that cannot be read or trusted raises
  :class:`HardwareIdentifierUnavailableError` carrying only the
  component name and a reason — never the value — and callers must
  treat that as "fingerprint unavailable" and fail closed (§13.1: no
  raw identifiers in errors, nothing machine-specific in the display
  code).
"""

from __future__ import annotations

import base64
import ctypes
import hashlib
import socket
import struct
import sys
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

__all__ = [
    "HardwareFingerprintService",
    "HardwareIdentifierUnavailableError",
    "HardwareInfoProvider",
    "StaticHardwareInfoProvider",
    "WindowsHardwareInfoProvider",
]

#: Domain-separation tag; bump ``v1`` if the construction ever changes.
_HASH_CONTEXT = b"supermarket-pro/hardware-fingerprint/v1"

#: The three §4.3 identifiers, in the fixed order they are hashed.
_COMPONENTS = ("machine_guid", "system_volume_serial", "hostname")

#: Plausibility cap: real values are far shorter (GUID 36 chars, serial
#: 8, hostname at most 255 per Windows); anything longer is garbage and
#: must never silently become part of a Lifetime binding.
_MAX_IDENTIFIER_CHARS = 255


class HardwareIdentifierUnavailableError(Exception):
    """One hardware identifier could not be read or trusted (fail-closed).

    Carries only ``component`` (which identifier) and ``reason`` (why) —
    never the identifier's value — so anything surfacing ``str(error)``
    can never leak machine identifiers (§13.1).
    """

    def __init__(self, component: str, reason: str) -> None:
        self.component = component
        self.reason = reason
        super().__init__(f"hardware identifier unavailable: {component} ({reason})")


@runtime_checkable
class HardwareInfoProvider(Protocol):
    """The three §4.3 identifiers, read from wherever the host keeps them."""

    @property
    def machine_guid(self) -> str:
        """Windows registry ``MachineGuid`` (stable per OS install)."""
        ...

    @property
    def system_volume_serial(self) -> str:
        """Volume serial number of the drive holding ``%SystemRoot%``."""
        ...

    @property
    def hostname(self) -> str:
        """Computer name of this machine."""
        ...


@dataclass(frozen=True, slots=True)
class StaticHardwareInfoProvider:
    """Fixed identifier values — development and tests only.

    Injected explicitly, never chosen automatically.  This is how the
    deterministic §13.1 tests exercise the hashing path without reading
    (or depending on) the host machine's hardware.
    """

    machine_guid: str
    system_volume_serial: str
    hostname: str


class WindowsHardwareInfoProvider:
    """Reads the three §4.3 identifiers from the local Windows machine.

    Every access is lazy and guarded: nothing Windows-only is imported
    at module import time (so this file imports on any platform), and a
    non-Windows platform raises
    :class:`HardwareIdentifierUnavailableError` with reason
    ``windows_required`` instead of failing at construction.
    """

    @property
    def machine_guid(self) -> str:
        """``HKLM\\SOFTWARE\\Microsoft\\Cryptography\\MachineGuid`` (64-bit view)."""
        self._require_windows("machine_guid")
        try:
            import winreg
        except ImportError as exc:
            raise HardwareIdentifierUnavailableError(
                "machine_guid", "windows_required"
            ) from exc
        try:
            with winreg.OpenKey(
                winreg.HKEY_LOCAL_MACHINE,
                "SOFTWARE\\Microsoft\\Cryptography",
                0,
                winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
            ) as key:
                value, _value_type = winreg.QueryValueEx(key, "MachineGuid")
        except OSError as exc:
            raise HardwareIdentifierUnavailableError(
                "machine_guid", "registry_unreadable"
            ) from exc
        return value

    @property
    def system_volume_serial(self) -> str:
        """Volume serial of ``%SystemRoot%``'s drive, as 8 uppercase hex digits."""
        self._require_windows("system_volume_serial")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        get_windows_directory = kernel32.GetWindowsDirectoryW
        get_windows_directory.argtypes = [ctypes.c_wchar_p, ctypes.c_uint]
        get_windows_directory.restype = ctypes.c_uint
        buffer = ctypes.create_unicode_buffer(32768)
        length = get_windows_directory(buffer, len(buffer))
        if length == 0 or length >= len(buffer):
            raise HardwareIdentifierUnavailableError(
                "system_volume_serial", "windows_directory_unreadable"
            )
        windows_directory = buffer.value
        if len(windows_directory) < 2 or windows_directory[1] != ":":
            raise HardwareIdentifierUnavailableError(
                "system_volume_serial", "windows_directory_unreadable"
            )
        root = f"{windows_directory[0]}:\\"

        get_volume_information = kernel32.GetVolumeInformationW
        get_volume_information.argtypes = [
            ctypes.c_wchar_p,
            ctypes.c_wchar_p,
            ctypes.c_uint,
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.c_wchar_p,
            ctypes.c_uint,
        ]
        get_volume_information.restype = ctypes.c_int
        serial = ctypes.c_uint(0)
        ok = get_volume_information(root, None, 0, ctypes.byref(serial), None, None, None, 0)
        if not ok:
            raise HardwareIdentifierUnavailableError(
                "system_volume_serial", "volume_serial_unreadable"
            )
        return f"{serial.value:08X}"

    @property
    def hostname(self) -> str:
        """Computer name via ``socket.gethostname()`` (Windows branch)."""
        self._require_windows("hostname")
        return socket.gethostname()

    @staticmethod
    def _require_windows(component: str) -> None:
        if sys.platform != "win32":
            raise HardwareIdentifierUnavailableError(component, "windows_required")


def _normalize(component: str, value: object) -> str:
    """Canonical form of one identifier (case/separator noise removed).

    Fail-closed: non-strings, empty results and implausibly long values
    raise :class:`HardwareIdentifierUnavailableError` rather than being
    coerced — a truncated or bogus identifier must never quietly become
    part of a Lifetime binding.
    """
    if not isinstance(value, str):
        raise HardwareIdentifierUnavailableError(component, "not_a_string")
    text = value.strip()
    if component == "machine_guid":
        text = text.strip("{}").strip().lower()
    elif component == "system_volume_serial":
        if text[:2].lower() == "0x":
            text = text[2:]
        text = text.upper().replace("-", "").replace(" ", "")
    else:
        text = text.lower().rstrip(".").strip()
    if not text:
        raise HardwareIdentifierUnavailableError(component, "empty")
    if len(text) > _MAX_IDENTIFIER_CHARS:
        raise HardwareIdentifierUnavailableError(component, "implausible_length")
    return text


class HardwareFingerprintService:
    """§4.3 hardware fingerprint: SHA-256 over three machine identifiers.

    Parameters
    ----------
    provider:
        Where the identifiers come from.  Defaults to
        :class:`WindowsHardwareInfoProvider` (the real machine); tests
        inject :class:`StaticHardwareInfoProvider` or a fake so the
        suite never depends on the dev machine's hardware (§13.3).

    Every call re-reads and re-hashes (a pure function of the current
    identifiers): repeated calls on an unchanged machine agree, and a
    changed identifier changes the digest.  Nothing is persisted, no
    identifier is logged, and no value shorter than the digest ever
    leaves this class.
    """

    def __init__(self, provider: HardwareInfoProvider | None = None) -> None:
        self._provider: HardwareInfoProvider = (
            provider if provider is not None else WindowsHardwareInfoProvider()
        )

    def fingerprint(self) -> str:
        """64-character lowercase hex digest of the three identifiers.

        Raises :class:`HardwareIdentifierUnavailableError` when any
        identifier cannot be read or normalised — fail-closed: callers
        must never substitute a partial or default fingerprint.
        """
        digest = hashlib.sha256(_HASH_CONTEXT)
        for component in _COMPONENTS:
            payload = self._read(component).encode("utf-8")
            digest.update(struct.pack(">I", len(payload)))
            digest.update(payload)
        return digest.hexdigest()

    def display_code(self) -> str:
        """Human-readable form of `fingerprint` (§4.3): grouped Base32.

        ``AAAA-BBBB-…`` — 13 groups of four characters from ``A-Z2-7``.
        It is the digest re-encoded, so it carries exactly the same
        one-way information and reveals no raw identifier.
        """
        encoded = base64.b32encode(bytes.fromhex(self.fingerprint())).decode("ascii")
        stripped = encoded.rstrip("=")
        chunks = [stripped[index : index + 4] for index in range(0, len(stripped), 4)]
        return "-".join(chunks)

    def _read(self, component: str) -> str:
        """Read + normalise one identifier, mapping failures to HIU."""
        try:
            raw = getattr(self._provider, component)
        except HardwareIdentifierUnavailableError:
            raise
        except Exception as exc:
            raise HardwareIdentifierUnavailableError(component, "read_failed") from exc
        return _normalize(component, raw)
