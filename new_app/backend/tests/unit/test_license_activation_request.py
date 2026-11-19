"""Phase L2-A — activation **request** codes (outbound, unsigned).

The request code is what the owner copies out of Supermarket Pro and
pastes into the offline License Generator.  These tests pin:

* the installation id is the *existing* Trial id (never a new one);
* the hardware digest is the *current* server-side fingerprint;
* the encoding is deterministic and canonical;
* no raw identifier and no secret ever leaves the backend;
* a missing/corrupt trial fails closed instead of inventing an identity;
* building a request never starts, restarts or extends a trial.
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.licensing.activation_code import (
    MAX_REQUEST_CODE_CHARS,
    REQUEST_PREFIX,
    build_request_code,
    build_request_payload,
    canonical_json,
)
from app.licensing.errors import LicenseRequiredError, LicenseStatusUnavailableError
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    HardwareIdentifierUnavailableError,
    StaticHardwareInfoProvider,
)
from app.licensing.license_manager import LicenseManager
from app.licensing.state_store import StateFileCorruptedError, StateStore
from app.licensing.trial import TrialManager

UTC = timezone.utc
T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)

PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2a-request",
    system_volume_serial="SERIAL-L2A",
    hostname="main-pc",
)

INSTALL_ID = "4e4f3f4e-0000-4000-8000-000000000001"


@dataclass
class Clock:
    moment: datetime = T0

    def __call__(self) -> datetime:
        return self.moment


class BrokenFingerprint:
    """A fingerprint source whose identifiers cannot be read (fail closed)."""

    def fingerprint(self) -> str:
        raise HardwareIdentifierUnavailableError("machine_guid", "registry_unreadable")

    def display_code(self) -> str:  # pragma: no cover - never reached
        raise AssertionError("display_code must not be reached")


def decode_request_code(code: str) -> dict:
    """Split/decode an ``SMPr1.`` code exactly as the Generator will."""
    prefix, segment = code.split(".")
    assert prefix == REQUEST_PREFIX
    payload = json.loads(base64.b32decode(segment + "=" * (-len(segment) % 8)))
    assert isinstance(payload, dict)
    return payload


@pytest.fixture()
def state_dir(tmp_path: Path) -> Path:
    return tmp_path / "data" / "license"


@pytest.fixture()
def store(state_dir: Path) -> StateStore:
    return StateStore(state_dir, use_dpapi=False)


@pytest.fixture()
def clock() -> Clock:
    return Clock()


@pytest.fixture()
def trial(state_dir: Path, store: StateStore, clock: Clock) -> TrialManager:
    return TrialManager(state_dir=state_dir, store=store, clock=clock)


@pytest.fixture()
def manager(
    state_dir: Path, store: StateStore, clock: Clock, trial: TrialManager
) -> LicenseManager:
    return LicenseManager(
        state_dir=state_dir,
        store=store,
        fingerprint=HardwareFingerprintService(PROVIDER),
        clock=clock,
        trial=trial,
    )


def _seed_trial(trial: TrialManager) -> str:
    return trial.ensure_started().install_id


# ── content ─────────────────────────────────────────────────────────────────


def test_request_reuses_the_existing_trial_installation_id(manager, trial):
    install_id = _seed_trial(trial)

    payload = decode_request_code(manager.build_activation_request().request_code)

    assert payload["install_id"] == install_id
    assert payload["v"] == 1
    assert set(payload) == {"v", "install_id", "hw_hash", "requested_at"}


def test_request_carries_the_current_fingerprint_and_no_raw_identifier(
    manager, trial
):
    _seed_trial(trial)
    request = manager.build_activation_request()
    payload = decode_request_code(request.request_code)

    expected = HardwareFingerprintService(PROVIDER).fingerprint()
    assert payload["hw_hash"] == expected
    assert len(payload["hw_hash"]) == 64 and payload["hw_hash"].islower()

    for secret in (
        PROVIDER.machine_guid,
        PROVIDER.system_volume_serial,
        PROVIDER.hostname,
    ):
        assert secret not in request.request_code
        assert secret not in request.fingerprint_display_code
        assert secret.lower() not in request.request_code.lower()

    # Display form: 13 groups of four Base32 characters (the digest again).
    assert len(request.fingerprint_display_code.split("-")) == 13


def test_request_is_unsigned_and_structurally_not_a_license(manager, trial):
    _seed_trial(trial)
    code = manager.build_activation_request().request_code

    # Two segments (prefix + payload): an activation code always has three.
    assert code.count(".") == 1
    assert code.startswith(f"{REQUEST_PREFIX}.")
    assert len(code) <= MAX_REQUEST_CODE_CHARS


def test_request_code_is_deterministic_for_fixed_inputs(state_dir, store):
    def build() -> str:
        clock = Clock(T0)
        trial = TrialManager(state_dir=state_dir, store=store, clock=clock)
        trial.ensure_started()
        manager = LicenseManager(
            store=store,
            fingerprint=HardwareFingerprintService(PROVIDER),
            clock=clock,
            trial=trial,
        )
        return manager.build_activation_request().request_code

    assert build() == build()


def test_canonical_json_is_sorted_compact_and_utf8():
    payload = build_request_payload(
        install_id=INSTALL_ID, hw_hash="a" * 64, requested_at=T0
    )
    assert payload == {
        "v": 1,
        "install_id": INSTALL_ID,
        "hw_hash": "a" * 64,
        "requested_at": "2026-01-01T00:00:00+00:00",
    }
    encoded = canonical_json(payload)
    assert b", " not in encoded and b": " not in encoded
    assert encoded == (
        b'{"hw_hash":"' + b"a" * 64 + b'","install_id":"' + INSTALL_ID.encode() + b'",'
        b'"requested_at":"2026-01-01T00:00:00+00:00","v":1}'
    )
    assert build_request_code(payload) == build_request_code(payload)


# ── trial interaction ───────────────────────────────────────────────────────


def test_request_does_not_start_a_trial_when_none_exists(manager, state_dir):
    with pytest.raises(LicenseRequiredError) as exc:
        manager.build_activation_request()

    assert exc.value.code == "license_required"
    assert not (state_dir / "trial.state").exists()
    assert not (state_dir / "license.state").exists()


def test_request_does_not_restart_or_extend_an_existing_trial(manager, trial):
    install_id = _seed_trial(trial)
    before = trial.status()
    assert before is not None

    manager.build_activation_request()

    after = trial.status()
    assert after is not None
    assert after.install_id == install_id
    assert after.first_launch_at == before.first_launch_at
    assert after.max_seen_at == before.max_seen_at
    assert after.expires_at == before.expires_at


def test_corrupt_trial_state_fails_closed_without_inventing_an_identity(
    manager, state_dir, trial
):
    _seed_trial(trial)
    (state_dir / "trial.state").write_bytes(b"not an envelope")
    before = (state_dir / "trial.state").read_bytes()

    with pytest.raises(LicenseStatusUnavailableError) as exc:
        manager.build_activation_request()

    assert exc.value.status_code == 503
    assert exc.value.code == "license_status_unavailable"
    # Nothing rewritten, nothing invented.
    assert (state_dir / "trial.state").read_bytes() == before
    assert not (state_dir / "license.state").exists()


def test_missing_trial_state_fails_closed(manager, state_dir, trial):
    _seed_trial(trial)
    (state_dir / "trial.state").unlink()

    with pytest.raises(LicenseRequiredError):
        manager.build_activation_request()
    assert not (state_dir / "trial.state").exists()


def test_unavailable_hardware_fails_closed(manager, trial):
    _seed_trial(trial)
    broken = LicenseManager(
        store=StateStore(trial.state_dir, use_dpapi=False),
        fingerprint=BrokenFingerprint(),
        trial=trial,
    )

    with pytest.raises(LicenseStatusUnavailableError) as exc:
        broken.build_activation_request()
    assert exc.value.code == "license_status_unavailable"
    assert "machine_guid" not in exc.value.message


def test_corrupt_trial_state_is_the_state_store_error_family(trial, state_dir):
    """Fixture sanity: garbage really is 'cannot tell', not 'no trial'."""
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "trial.state").write_bytes(b"{}")
    with pytest.raises(StateFileCorruptedError):
        trial.status()
