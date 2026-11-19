"""Phase L2-A — `LicenseManager`: persistence, re-verification, lifecycle.

Test keypairs are generated in-process and written only to a temp
``verification_keys.json``; no production key material exists anywhere.

The contract pinned here:

* activation writes only after full validation (a failed attempt can
  never destroy an installed license);
* every ``status()`` re-verifies the Ed25519 signature, the duplicated
  record fields **and** the hardware binding — the StateStore HMAC alone
  is never proof of authenticity;
* missing/unusable keys and unreadable hardware fail closed;
* the trial file is read-only: activation never starts, restarts or
  extends a trial, and works after the trial has expired;
* an activation survives a restart (it lives in state, not memory).
"""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from app.core.exceptions import AppError
from app.licensing.activation_code import (
    canonical_json,
    encode_activation_code,
)
from app.licensing.errors import (
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
    LicenseStatusUnavailableError,
)
from app.licensing.fingerprint import HardwareFingerprintService, StaticHardwareInfoProvider
from app.licensing.license_manager import (
    LICENSE_STATE_NAME,
    LicenseManager,
    LicenseStatus,
)
from app.licensing.state_store import StateStore, StateStoreError
from app.licensing.trial import TrialManager

UTC = timezone.utc
T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)

PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-l2a-manager",
    system_volume_serial="SERIAL-L2A-M",
    hostname="main-pc-m",
)
HW = HardwareFingerprintService(PROVIDER).fingerprint()

OTHER_PROVIDER = StaticHardwareInfoProvider(
    machine_guid="guid-other-pc",
    system_volume_serial="SERIAL-OTHER",
    hostname="other-pc",
)

KEY_ID = "k1"


@dataclass
class Clock:
    moment: datetime = T0

    def __call__(self) -> datetime:
        return self.moment


@pytest.fixture(scope="module")
def private() -> Ed25519PrivateKey:
    return Ed25519PrivateKey.generate()


def raw_public(private: Ed25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def write_keys(path: Path, keys: dict[str, bytes]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        key_id: base64.b64encode(material).decode("ascii")
        for key_id, material in keys.items()
    }
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def make_code(
    private: Ed25519PrivateKey,
    *,
    hw_hash: str = HW,
    license_id: str = "LIC-2026-0001",
    key_id: str = KEY_ID,
    issued_at: str = "2026-01-01T00:00:00+00:00",
    features: list[str] | None = None,
) -> str:
    body = {
        "v": 1,
        "key_id": key_id,
        "license_id": license_id,
        "kind": "lifetime",
        "issued_at": issued_at,
        "hw_hash": hw_hash,
        "features": features if features is not None else ["pos"],
    }
    return encode_activation_code(body, private.sign(canonical_json(body)))


@dataclass
class Env:
    state_dir: Path
    store: StateStore
    keys_path: Path
    clock: Clock
    provider: StaticHardwareInfoProvider
    trial: TrialManager

    def manager(self, *, provider: StaticHardwareInfoProvider | None = None,
                keys_path: Path | None = None) -> LicenseManager:
        return LicenseManager(
            state_dir=self.state_dir,
            store=self.store,
            keys_path=keys_path if keys_path is not None else self.keys_path,
            fingerprint=HardwareFingerprintService(provider or self.provider),
            clock=self.clock,
            trial=self.trial,
        )


@pytest.fixture()
def env(tmp_path: Path, private: Ed25519PrivateKey) -> Env:
    state_dir = tmp_path / "data" / "license"
    store = StateStore(state_dir, use_dpapi=False)
    keys_path = write_keys(tmp_path / "keys" / "verification_keys.json", {KEY_ID: raw_public(private)})
    clock = Clock()
    trial = TrialManager(state_dir=state_dir, store=store, clock=clock)
    return Env(state_dir=state_dir, store=store, keys_path=keys_path,
               clock=clock, provider=PROVIDER, trial=trial)


def record_path(env: Env) -> Path:
    return env.store.path_for(LICENSE_STATE_NAME)


# ── happy path ──────────────────────────────────────────────────────────────


def test_status_without_a_license_is_none(env):
    assert env.manager().status() is None


def test_valid_activation_persists_and_status_re_verifies(env, private):
    status = env.manager().activate(make_code(private))

    assert isinstance(status, LicenseStatus)
    assert status.license_id == "LIC-2026-0001"
    assert status.key_id == KEY_ID
    assert status.license_type == "lifetime"
    assert status.mode == "lifetime"
    assert status.hw_hash == HW
    assert status.features == ("pos",)
    assert status.activated_at == T0
    assert record_path(env).exists()

    # status() is a fresh read + full re-verification, not a cached value.
    reread = env.manager().status()
    assert reread == status


def test_stored_record_carries_no_secret_or_raw_identifier(env, private):
    env.manager().activate(make_code(private))

    data = record_path(env).read_bytes()
    lowered = data.lower()
    for secret in (PROVIDER.machine_guid, PROVIDER.hostname, PROVIDER.system_volume_serial):
        assert secret.lower().encode() not in lowered
    assert b"ed25519" not in lowered
    assert raw_public(private) not in data


def test_activation_survives_a_restart(env, private):
    env.manager().activate(make_code(private))

    restarted = env.manager()  # brand-new instance, same on-disk state
    status = restarted.status()
    assert status is not None
    assert status.license_id == "LIC-2026-0001"
    assert status.activated_at == T0


# ── idempotency / replacement ───────────────────────────────────────────────


def test_reactivating_the_same_code_is_a_true_no_op(env, private):
    first = env.manager().activate(make_code(private))
    before = record_path(env).read_bytes()

    env.clock.moment = datetime(2026, 1, 3, tzinfo=UTC)
    second = env.manager().activate(make_code(private))

    assert second == first
    assert second.activated_at == T0
    assert record_path(env).read_bytes() == before


def test_a_new_verified_license_replaces_the_previous_one(env, private):
    env.manager().activate(make_code(private))

    replacement = env.manager().activate(
        make_code(private, license_id="LIC-2026-0002", features=["pos", "inventory"])
    )

    assert replacement.license_id == "LIC-2026-0002"
    assert replacement.features == ("pos", "inventory")
    status = env.manager().status()
    assert status is not None and status.license_id == "LIC-2026-0002"


# ── a failed activation can never destroy an installed license ──────────────


@pytest.mark.parametrize(
    "attack",
    [
        pytest.param(lambda priv: make_code(priv, hw_hash="f" * 64), id="wrong_hardware"),
        pytest.param(lambda priv: make_code(priv, key_id="k9"), id="unknown_key"),
        pytest.param(lambda priv: "SMP1.ABC.DEF", id="garbage"),
        pytest.param(lambda priv: make_code(priv, issued_at="not-a-time"), id="bad_schema"),
    ],
)
def test_failed_activation_leaves_the_installed_license_intact(env, private, attack):
    valid = make_code(private)
    installed = env.manager().activate(valid)
    before = record_path(env).read_bytes()

    with pytest.raises(AppError):
        env.manager().activate(attack(private))

    assert record_path(env).read_bytes() == before
    status = env.manager().status()
    assert status == installed


def test_tampered_signature_is_detected_on_read(env, private):
    env.manager().activate(make_code(private))
    record = env.store.read(LICENSE_STATE_NAME)
    assert isinstance(record, dict)
    signature = bytearray(base64.b64decode(record["signature_b64"]))
    signature[0] ^= 0x01
    record["signature_b64"] = base64.b64encode(bytes(signature)).decode("ascii")
    env.store.write(LICENSE_STATE_NAME, record)

    with pytest.raises(LicenseInvalidError):
        env.manager().status()


def test_tampered_payload_is_detected_on_read(env, private):
    env.manager().activate(make_code(private))
    record = env.store.read(LICENSE_STATE_NAME)
    assert isinstance(record, dict)
    document = json.loads(base64.b64decode(record["payload_b64"]))
    document["features"] = ["pos", "admin"]
    record["payload_b64"] = base64.b64encode(
        json.dumps(document, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    env.store.write(LICENSE_STATE_NAME, record)

    with pytest.raises(LicenseInvalidError):
        env.manager().status()


def test_record_fields_diverging_from_the_signed_payload_fail_on_read(env, private):
    env.manager().activate(make_code(private))
    record = env.store.read(LICENSE_STATE_NAME)
    assert isinstance(record, dict)
    record["license_id"] = "LIC-2026-0009"
    env.store.write(LICENSE_STATE_NAME, record)

    with pytest.raises(LicenseInvalidError) as exc:
        env.manager().status()
    assert "does not match" in str(exc.value)


def test_unreadable_activation_time_fails_closed(env, private):
    env.manager().activate(make_code(private))
    record = env.store.read(LICENSE_STATE_NAME)
    assert isinstance(record, dict)
    record["activated_at"] = "yesterday"
    env.store.write(LICENSE_STATE_NAME, record)

    with pytest.raises(LicenseInvalidError):
        env.manager().status()


def test_corrupt_state_file_fails_closed(env, private):
    env.manager().activate(make_code(private))
    record_path(env).write_bytes(b"not an envelope")

    with pytest.raises((AppError, StateStoreError, OSError)):
        env.manager().status()


# ── keys ────────────────────────────────────────────────────────────────────


def test_missing_verification_keys_never_verify(tmp_path, private, env):
    manager = env.manager(keys_path=tmp_path / "nope" / "verification_keys.json")

    with pytest.raises(LicenseInvalidKeyError) as exc:
        manager.activate(make_code(private))
    assert exc.value.code == "license_invalid_key"
    assert not record_path(env).exists()


def test_empty_verification_keys_file_never_verifies(tmp_path, private, env):
    empty = tmp_path / "keys" / "empty.json"
    empty.write_text("{}", encoding="utf-8")

    with pytest.raises(LicenseInvalidKeyError):
        env.manager(keys_path=empty).activate(make_code(private))
    assert not record_path(env).exists()


def test_unreadable_verification_keys_file_fails_closed_as_503(tmp_path, private, env):
    broken = tmp_path / "keys" / "broken.json"
    broken.write_text('{"k1": ', encoding="utf-8")

    with pytest.raises(LicenseStatusUnavailableError) as exc:
        env.manager(keys_path=broken).activate(make_code(private))
    assert exc.value.status_code == 503
    assert "k1" not in str(exc.value)
    assert not record_path(env).exists()


def test_installed_license_is_not_reportable_once_the_key_file_disappears(env, private):
    env.manager().activate(make_code(private))
    env.keys_path.unlink()

    # No key can verify the stored signature → fail closed, never "active".
    with pytest.raises((LicenseInvalidKeyError, LicenseStatusUnavailableError)):
        env.manager().status()


# ── hardware binding ────────────────────────────────────────────────────────


def test_a_foreign_machine_cannot_activate_this_licenses_code(env, private):
    with pytest.raises(LicenseBoundElsewhereError) as exc:
        env.manager().activate(make_code(private, hw_hash="f" * 64))
    assert exc.value.status_code == 403
    assert not record_path(env).exists()


def test_hardware_change_invalidates_an_installed_license(env, private):
    env.manager().activate(make_code(private))

    moved = env.manager(provider=OTHER_PROVIDER)
    with pytest.raises(LicenseBoundElsewhereError) as exc:
        moved.status()
    assert exc.value.code == "license_bound_elsewhere"

    # The original machine still reads it fine (nothing was destroyed).
    assert env.manager().status() is not None


# ── trial interaction ───────────────────────────────────────────────────────


def test_activation_works_after_the_trial_has_expired(env, private):
    trial = env.trial.ensure_started()
    env.clock.moment = trial.expires_at + timedelta(days=1)
    assert env.trial.status().expired is True

    status = env.manager().activate(make_code(private))

    assert status.license_type == "lifetime"
    assert env.trial.status().expired is True


def test_activation_never_creates_a_trial(env, private):
    assert env.trial.status() is None

    env.manager().activate(make_code(private))

    assert env.trial.status() is None
    assert not (env.state_dir / "trial.state").exists()


def test_activation_never_moves_or_extends_a_trial(env, private):
    before = env.trial.ensure_started()
    trial_bytes = (env.state_dir / "trial.state").read_bytes()

    env.clock.moment = datetime(2026, 1, 5, tzinfo=UTC)
    env.manager().activate(make_code(private))

    # Activation itself must not have written the trial envelope at all.
    assert (env.state_dir / "trial.state").read_bytes() == trial_bytes

    after = env.trial.status()
    assert after.install_id == before.install_id
    assert after.first_launch_at == before.first_launch_at
    assert after.expires_at == before.expires_at
    # (max_seen_at may legitimately advance when *observed* later — the
    # byte-equality check above already proves activation wrote nothing.)
    assert env.state_dir.joinpath("trial.state").exists()


def test_activation_request_reads_the_trial_install_id(env, private):
    install_id = env.trial.ensure_started().install_id

    request = env.manager().build_activation_request()

    payload = json.loads(
        base64.b32decode(request.request_code.split(".")[1] + "=" * (-len(request.request_code.split(".")[1]) % 8))
    )
    assert payload["install_id"] == install_id
    assert payload["hw_hash"] == HW

