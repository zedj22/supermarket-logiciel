"""The compatibility proof: an API-issued code activates the KlickPOS backend.

This module does not simulate the customer side — it calls the real
``LicenseManager`` from ``new_app/backend/app/licensing`` with a real
``StateStore`` on disk, a real ``TrialManager`` and the real
``HardwareFingerprintService``.  ``LicenseManager.activate`` is exactly what
``POST /api/v1/license/activate`` calls on the customer's PC, so a pass here
means the desktop activation protocol is untouched and fully supported.
"""

from __future__ import annotations

import pytest
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.state_store import StateStore
from app.licensing.trial import TrialManager

from service import shared
from testkit import HW_B, issue

#: A fixed machine, so the digest is deterministic in this test.
MACHINE = StaticHardwareInfoProvider(
    machine_guid="{8F0A1C3E-1111-4222-8333-944455556666}",
    system_volume_serial="0x1A2B-3C4D",
    hostname="CAISSE-PC",
)
OTHER_MACHINE = StaticHardwareInfoProvider(
    machine_guid="{00000000-0000-0000-0000-000000000001}",
    system_volume_serial="0xDEAD-BEEF",
    hostname="AUTRE-PC",
)


def _manager(tmp_path, fingerprint, keys_file, *, subdir: str = "state"):
    state_dir = tmp_path / subdir
    return LicenseManager(
        state_dir=state_dir,
        store=StateStore(state_dir, use_dpapi=False),
        keys_path=keys_file,
        fingerprint=fingerprint,
        trial=TrialManager(state_dir=state_dir),
    )


def test_an_api_issued_code_activates_the_real_klickpos_license_manager(
    client, admin_headers, keys_file, tmp_path
):
    fingerprint = HardwareFingerprintService(MACHINE)
    hw_hash = fingerprint.fingerprint()

    issued = issue(client, admin_headers, hw_hash)["license"]

    manager = _manager(tmp_path, fingerprint, keys_file)
    status = manager.activate(issued["activation_code"])

    assert status.mode == "lifetime"
    assert status.license_id == issued["license_id"]
    assert status.license_type == "lifetime"
    assert status.features == ("pos",)
    assert status.hw_hash == hw_hash


def test_the_activation_survives_a_backend_restart(
    client, admin_headers, keys_file, tmp_path
):
    fingerprint = HardwareFingerprintService(MACHINE)
    issued = issue(client, admin_headers, fingerprint.fingerprint())["license"]
    _manager(tmp_path, fingerprint, keys_file).activate(issued["activation_code"])

    # A brand-new manager on the same directory — the state a process restart
    # would find on disk (signature and hardware binding re-verified on read).
    restarted = _manager(tmp_path, fingerprint, keys_file)
    assert restarted.status() is not None
    assert restarted.status().license_id == issued["license_id"]


def test_the_code_is_refused_on_other_hardware(client, admin_headers, keys_file, tmp_path):
    from app.licensing.errors import LicenseBoundElsewhereError

    issued = issue(client, admin_headers, HardwareFingerprintService(MACHINE).fingerprint())[
        "license"
    ]
    other = _manager(tmp_path, HardwareFingerprintService(OTHER_MACHINE), keys_file, subdir="other")
    with pytest.raises(LicenseBoundElsewhereError) as excinfo:
        other.activate(issued["activation_code"])
    assert excinfo.value.code == "license_bound_elsewhere"
    assert other.status() is None


def test_the_request_the_customer_pastes_is_the_one_the_backend_generates(
    keys_file, tmp_path
):
    """The API parses the *same* SMPr1 the customer's own manager produces."""
    fingerprint = HardwareFingerprintService(MACHINE)
    state_dir = tmp_path / "customer"
    manager = LicenseManager(
        state_dir=state_dir,
        store=StateStore(state_dir, use_dpapi=False),
        keys_path=keys_file,
        fingerprint=fingerprint,
        trial=TrialManager(state_dir=state_dir),
    )
    manager._trial.ensure_started()
    generated = manager.build_activation_request()

    parsed = shared.parse_request_code(generated.request_code)
    assert parsed.hw_hash == fingerprint.fingerprint()
    assert parsed.install_id == manager._trial.status().install_id
    assert generated.fingerprint_display_code == shared.display_code_for(parsed.hw_hash)


def test_the_smp1_and_smpr1_wire_formats_are_unchanged():
    """Guard rails for the whole project: these constants must never move."""
    assert shared.ACTIVATION_PREFIX == "SMP1"
    assert shared.REQUEST_PREFIX == "SMPr1"
    assert shared.LICENSE_VERSION == 1
    assert shared.LICENSE_KIND == "lifetime"
    assert shared.PAYLOAD_FIELDS == frozenset(
        {"v", "key_id", "license_id", "kind", "issued_at", "hw_hash", "features"}
    )
    assert shared.MAX_ACTIVATION_CODE_CHARS == 512


def test_a_code_from_the_api_is_accepted_by_the_packaged_verifier_alone(
    client, admin_headers, keys_file
):
    """No service-specific verification: the customer package's keys suffice."""
    code = issue(client, admin_headers, HW_B)["license"]["activation_code"]
    keys = shared.load_customer_verification_keys(str(keys_file))
    payload = shared.verify_activation_code(code, keys=keys, expected_hw_hash=HW_B)
    assert payload.kind == "lifetime"
    assert payload.v == 1


def test_the_service_never_uses_a_different_canonical_encoding(
    client, admin_headers, keys_file
):
    """The signed bytes must be the contract's own canonical JSON."""
    code = issue(client, admin_headers, HW_B)["license"]["activation_code"]
    payload = shared.verify_activation_code(
        code,
        keys=shared.load_customer_verification_keys(str(keys_file)),
        expected_hw_hash=HW_B,
    )
    import json

    assert payload.payload_bytes == shared.canonical_json(
        json.loads(payload.payload_bytes)
    )
