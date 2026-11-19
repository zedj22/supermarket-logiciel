"""Phase L1-A: hardware fingerprint determinism, sensitivity and hygiene.

§4.3 defines the fingerprint as SHA-256 over three Windows identifiers;
§13.1 requires that it is stable across runs, that changing any single
component changes it, and that no raw identifier (nor PII) ever appears
in the fingerprint, the display code or an error message.

Everything here runs against :class:`StaticHardwareInfoProvider` or
hand-written fakes — never the host machine — except the clearly marked
``win32_only`` Windows-provider tests.
"""

from __future__ import annotations

import base64
import ctypes
import hashlib
import re
import struct
import sys

import pytest

from app.core.config import settings
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    HardwareIdentifierUnavailableError,
    HardwareInfoProvider,
    StaticHardwareInfoProvider,
    WindowsHardwareInfoProvider,
)

#: The three components in their fixed hashing order (§4.3).
COMPONENTS = ("machine_guid", "system_volume_serial", "hostname")

#: RFC 4648 Base32, no padding, 13 groups of four (64 chars incl. dashes).
DISPLAY_CODE_RE = re.compile(r"^(?:[A-Z2-7]{4}-){12}[A-Z2-7]{4}$")
HEX_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")

#: Golden vector: the documented construction over these normalised
#: inputs ("guid-one", "123456", "host") — pins tag, length prefixes
#: and component order against accidental algorithm changes.
GOLDEN_FINGERPRINT = "b49d3adc2ff00380303bb6bb508ab7a717176e3a1e9caa114ccff0a4734843fa"
GOLDEN_DISPLAY_CODE = (
    "WSOT-VXBP-6ABY-AMB3-W25V-BCVX-U4LR-O3R2-D2OK-UEKM-Z7YK-I42I-IP5A"
)

#: Deliberately distinctive raw values (braces, ``0x``, dashes, spaces)
#: that can never appear inside a hex digest or a Base32 display code.
RAW_GUID = "{9f8e7d6c-5b4a-3210-SuperSecret-GUID}"
RAW_SERIAL = "0xDEAD-BEEF CAFE-SECRET"
RAW_HOST = "Secret-Box-Name"

BASE_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-1",
    system_volume_serial="SERIAL1",
    hostname="host-1",
)


def _service(**overrides: str) -> HardwareFingerprintService:
    """Service over ``BASE_PROVIDER`` with the named components replaced."""
    values = {
        "machine_guid": "guid-1",
        "system_volume_serial": "SERIAL1",
        "hostname": "host-1",
    }
    values.update(overrides)
    return HardwareFingerprintService(StaticHardwareInfoProvider(**values))


def _fake_kernel32(
    *, directory: str | None = "C:\\Windows", volume_ok: bool = False
) -> object:
    """Stand-in for ``kernel32`` exposing only what the provider touches."""

    class _FakeFunc:
        def __init__(self, fn):
            self._fn = fn
            self.argtypes = None
            self.restype = None

        def __call__(self, *args):
            return self._fn(*args)

    def get_windows_directory(buffer, size):
        if directory is None:
            return 0
        buffer.value = directory
        return len(directory)

    def get_volume_information(*args):
        return 1 if volume_ok else 0

    fake = type("FakeKernel32", (), {})()
    fake.GetWindowsDirectoryW = _FakeFunc(get_windows_directory)
    fake.GetVolumeInformationW = _FakeFunc(get_volume_information)
    return fake


win32_only = pytest.mark.skipif(sys.platform != "win32", reason="requires Windows APIs")


# ── determinism (§13.1) ───────────────────────────────────────────────


def test_fingerprint_is_deterministic_across_instances_and_calls():
    first = HardwareFingerprintService(BASE_PROVIDER)
    second = HardwareFingerprintService(
        StaticHardwareInfoProvider("guid-1", "SERIAL1", "host-1")
    )
    assert first.fingerprint() == first.fingerprint()
    assert first.fingerprint() == second.fingerprint()
    assert first.display_code() == second.display_code()


def test_fingerprint_is_64_lowercase_hex():
    assert HEX_DIGEST_RE.match(_service().fingerprint())


def test_fingerprint_matches_the_documented_construction():
    """Pins tag + big-endian length prefixes + component order."""
    service = _service(
        machine_guid="{Guid-One}",
        system_volume_serial="0x12-34 56",
        hostname="HOST.",
    )
    expected = hashlib.sha256(b"supermarket-pro/hardware-fingerprint/v1")
    for value in ("guid-one", "123456", "host"):  # after normalisation
        payload = value.encode("utf-8")
        expected.update(struct.pack(">I", len(payload)))
        expected.update(payload)
    assert service.fingerprint() == expected.hexdigest()


def test_golden_vector_is_pinned():
    service = _service(
        machine_guid="{Guid-One}",
        system_volume_serial="0x12-34 56",
        hostname="HOST.",
    )
    assert service.fingerprint() == GOLDEN_FINGERPRINT
    assert service.display_code() == GOLDEN_DISPLAY_CODE


def test_not_a_naive_concatenation():
    service = _service(
        machine_guid="{Guid-One}",
        system_volume_serial="0x12-34 56",
        hostname="HOST.",
    )
    naive = hashlib.sha256(b"guid-one" + b"123456" + b"host").hexdigest()
    assert service.fingerprint() != naive


# ── sensitivity to each component (§13.1) ─────────────────────────────


@pytest.mark.parametrize(
    "overrides",
    [
        {"machine_guid": "guid-2"},
        {"system_volume_serial": "SERIAL2"},
        {"hostname": "host-2"},
    ],
    ids=["machine_guid", "system_volume_serial", "hostname"],
)
def test_changing_one_component_changes_the_fingerprint(overrides):
    assert _service().fingerprint() != _service(**overrides).fingerprint()


@pytest.mark.parametrize(
    "overrides",
    [
        {"machine_guid": "guid-2"},
        {"system_volume_serial": "SERIAL2"},
        {"hostname": "host-2"},
    ],
    ids=["machine_guid", "system_volume_serial", "hostname"],
)
def test_changing_one_component_changes_the_display_code(overrides):
    assert _service().display_code() != _service(**overrides).display_code()


# ── fail-closed input validation ──────────────────────────────────────


@pytest.mark.parametrize(
    ("component", "value"),
    [
        (component, value)
        for component, blanks in (
            ("machine_guid", ["", "   ", "\t", "{}", " { } "]),
            ("system_volume_serial", ["", "   ", "\t", "0x", "0X", " - "]),
            ("hostname", ["", "   ", "\t", ".", "..", " . "]),
        )
        for value in blanks
    ],
)
def test_blank_identifier_raises_empty(component, value):
    service = _service(**{component: value})
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        service.fingerprint()
    assert excinfo.value.component == component
    assert excinfo.value.reason == "empty"


@pytest.mark.parametrize("component", COMPONENTS)
@pytest.mark.parametrize("value", [42, None, b"raw", ["x"], {"k": "v"}, 3.5, True])
def test_non_string_identifier_raises_not_a_string(component, value):
    service = _service(**{component: value})
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        service.fingerprint()
    assert excinfo.value.component == component
    assert excinfo.value.reason == "not_a_string"


@pytest.mark.parametrize("component", COMPONENTS)
def test_implausibly_long_identifier_raises(component):
    service = _service(**{component: "x" * 256})
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        service.fingerprint()
    assert excinfo.value.component == component
    assert excinfo.value.reason == "implausible_length"


@pytest.mark.parametrize("component", COMPONENTS)
def test_exactly_255_characters_is_accepted(component):
    service = _service(**{component: "x" * 255})
    assert HEX_DIGEST_RE.match(service.fingerprint())


# ── normalisation equivalence (§4.3) ──────────────────────────────────


@pytest.mark.parametrize(
    ("messy", "clean"),
    [
        (("{AbC-123}", "0xab-cd 1234", "HOST."), ("abc-123", "ABCD1234", "host")),
        (("{abc-123}", "ABCD1234", "host."), ("abc-123", "ABCD1234", "host")),
        (("  abc-123  ", " ab cd 1234 ", "host"), ("abc-123", "ABCD1234", "host")),
    ],
)
def test_equivalent_identifiers_hash_the_same(messy, clean):
    left = HardwareFingerprintService(StaticHardwareInfoProvider(*messy))
    right = HardwareFingerprintService(StaticHardwareInfoProvider(*clean))
    assert left.fingerprint() == right.fingerprint()
    assert left.display_code() == right.display_code()


# ── error hygiene: no raw identifiers (§13.1) ─────────────────────────


def test_error_message_names_component_and_reason_only():
    exc = HardwareIdentifierUnavailableError("machine_guid", "empty")
    assert str(exc) == "hardware identifier unavailable: machine_guid (empty)"
    assert exc.component == "machine_guid"
    assert exc.reason == "empty"


def test_raw_identifiers_never_appear_in_outputs():
    service = HardwareFingerprintService(
        StaticHardwareInfoProvider(RAW_GUID, RAW_SERIAL, RAW_HOST)
    )
    fingerprint = service.fingerprint()
    display_code = service.display_code()
    for raw in (RAW_GUID, RAW_SERIAL, RAW_HOST):
        assert raw not in fingerprint
        assert raw not in display_code
        assert raw not in f"{fingerprint} {display_code}"


def test_raw_identifier_never_appears_in_an_error_message():
    secret = "SuperSecretValue"

    class _ExplodingProvider:
        @property
        def machine_guid(self) -> str:
            raise RuntimeError(f"boom: {secret}")

        @property
        def system_volume_serial(self) -> str:
            return "serial-1"

        @property
        def hostname(self) -> str:
            return "host-1"

    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        HardwareFingerprintService(_ExplodingProvider()).fingerprint()
    assert str(excinfo.value) == (
        "hardware identifier unavailable: machine_guid (read_failed)"
    )
    assert secret not in str(excinfo.value)


# ── provider failure handling ─────────────────────────────────────────


def test_provider_exception_becomes_read_failed():
    class _ExplodingProvider:
        @property
        def machine_guid(self) -> str:
            raise OSError("registry gone")

        @property
        def system_volume_serial(self) -> str:
            return "serial-1"

        @property
        def hostname(self) -> str:
            return "host-1"

    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        HardwareFingerprintService(_ExplodingProvider()).fingerprint()
    assert (excinfo.value.component, excinfo.value.reason) == (
        "machine_guid",
        "read_failed",
    )


def test_provider_hiu_is_passed_through_untouched():
    class _DenyingProvider:
        @property
        def machine_guid(self) -> str:
            raise HardwareIdentifierUnavailableError(
                "machine_guid", "registry_unreadable"
            )

        @property
        def system_volume_serial(self) -> str:
            return "serial-1"

        @property
        def hostname(self) -> str:
            return "host-1"

    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        HardwareFingerprintService(_DenyingProvider()).fingerprint()
    assert excinfo.value.reason == "registry_unreadable"


def test_flaky_provider_never_yields_a_silently_different_fingerprint():
    class _FlakyProvider:
        def __init__(self) -> None:
            self.machine_guid_reads = 0

        @property
        def machine_guid(self) -> str:
            self.machine_guid_reads += 1
            if self.machine_guid_reads > 1:
                raise RuntimeError("transient registry failure")
            return "stable-guid"

        @property
        def system_volume_serial(self) -> str:
            return "serial-1"

        @property
        def hostname(self) -> str:
            return "host-1"

    provider = _FlakyProvider()
    service = HardwareFingerprintService(provider)
    first = service.fingerprint()  # works on the first read…
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        service.fingerprint()  # …and fails loudly on the second
    assert excinfo.value.reason == "read_failed"
    assert provider.machine_guid_reads == 2
    assert HEX_DIGEST_RE.match(first)


# ── display code (§4.3) ──────────────────────────────────────────────


def test_display_code_matches_the_grouped_base32_shape():
    assert DISPLAY_CODE_RE.match(_service().display_code())


def test_display_code_is_base32_of_the_digest():
    service = _service()
    encoded = base64.b32encode(bytes.fromhex(service.fingerprint())).decode("ascii")
    stripped = encoded.rstrip("=")
    expected = "-".join(
        stripped[index : index + 4] for index in range(0, len(stripped), 4)
    )
    assert service.display_code() == expected


def test_display_code_carries_no_hex_digest_verbatim():
    service = _service()
    assert service.fingerprint() not in service.display_code()


# ── platform guard / Windows provider ────────────────────────────────


def test_default_provider_construction_never_fails():
    assert HardwareFingerprintService() is not None


def test_non_windows_platform_fails_closed_with_windows_required(monkeypatch):
    monkeypatch.setattr(sys, "platform", "linux")
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        HardwareFingerprintService().fingerprint()
    assert (excinfo.value.component, excinfo.value.reason) == (
        "machine_guid",
        "windows_required",
    )


@pytest.mark.parametrize("component", COMPONENTS)
def test_windows_provider_guards_every_component(monkeypatch, component):
    monkeypatch.setattr(sys, "platform", "linux")
    provider = WindowsHardwareInfoProvider()
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        getattr(provider, component)
    assert (excinfo.value.component, excinfo.value.reason) == (
        component,
        "windows_required",
    )


def test_static_provider_satisfies_the_protocol():
    assert isinstance(
        StaticHardwareInfoProvider("g", "s", "h"), HardwareInfoProvider
    )


@win32_only
def test_machine_guid_registry_failure_is_registry_unreadable(monkeypatch):
    import winreg

    def _boom(*_args, **_kwargs):
        raise OSError("access denied")

    monkeypatch.setattr(winreg, "OpenKey", _boom)
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        _ = WindowsHardwareInfoProvider().machine_guid
    assert (excinfo.value.component, excinfo.value.reason) == (
        "machine_guid",
        "registry_unreadable",
    )


@win32_only
def test_windows_directory_failure_is_windows_directory_unreadable(monkeypatch):
    monkeypatch.setattr(
        ctypes, "WinDLL", lambda *_args, **_kwargs: _fake_kernel32(directory=None)
    )
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        _ = WindowsHardwareInfoProvider().system_volume_serial
    assert (excinfo.value.component, excinfo.value.reason) == (
        "system_volume_serial",
        "windows_directory_unreadable",
    )


@win32_only
def test_directory_without_a_drive_root_is_windows_directory_unreadable(monkeypatch):
    monkeypatch.setattr(
        ctypes,
        "WinDLL",
        lambda *_args, **_kwargs: _fake_kernel32(directory="weirdpath"),
    )
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        _ = WindowsHardwareInfoProvider().system_volume_serial
    assert excinfo.value.reason == "windows_directory_unreadable"


@win32_only
def test_volume_information_failure_is_volume_serial_unreadable(monkeypatch):
    monkeypatch.setattr(
        ctypes,
        "WinDLL",
        lambda *_args, **_kwargs: _fake_kernel32(directory="C:\\Windows"),
    )
    with pytest.raises(HardwareIdentifierUnavailableError) as excinfo:
        _ = WindowsHardwareInfoProvider().system_volume_serial
    assert (excinfo.value.component, excinfo.value.reason) == (
        "system_volume_serial",
        "volume_serial_unreadable",
    )


@win32_only
def test_real_machine_fingerprint_is_stable_across_instances():
    first = HardwareFingerprintService().fingerprint()
    second = HardwareFingerprintService().fingerprint()
    assert first == second
    assert HEX_DIGEST_RE.match(first)


# ── no persistence ────────────────────────────────────────────────────


def test_service_persists_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(tmp_path))
    service = _service()
    service.fingerprint()
    service.display_code()
    assert list(tmp_path.iterdir()) == []
