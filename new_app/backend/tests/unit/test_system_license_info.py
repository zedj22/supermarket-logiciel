"""Phase L1-B: informational license/trial status on GET /system/info.

Guarantees pinned here:

* active trial → ``mode=trial`` / ``status=active`` with the full clock,
* expired trial → ``mode=trial_expired`` / ``status=expired``,
  ``remaining_seconds`` clamped at 0 and the endpoint still 200
  (an expired trial is informational here, never a connection failure),
* missing state → controlled ``unknown``/``unavailable`` with null
  timestamps; corrupted state → the same, with no internal details,
* ``remaining_seconds`` matches the trial clock and is never negative,
* every pre-existing response field (incl. ``protocol=1``) is untouched
  and the model can still be constructed without the new field,
* ``/system/info`` never creates or restarts a trial,
* no hardware identifier, fingerprint, HMAC/DPAPI material, state-file
  content or filesystem path is ever exposed.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.api.v1.system import LicenseInfo, SystemInfoResponse
from app.core.config import settings
from app.db.session import get_db
from app.licensing.trial import STATE_NAME, TrialManager
from app.main import app

UTC = timezone.utc


@pytest.fixture()
def trial_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point licensing at a throwaway state dir before the app starts."""
    state_dir = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    return state_dir


@pytest.fixture()
def client(db_engine, trial_state: Path):
    """Conftest client, but bound to this test's license state directory."""
    from sqlalchemy.orm import sessionmaker

    def override_get_db():
        connection = db_engine.connect()
        transaction = connection.begin()
        session = sessionmaker(bind=connection)()
        try:
            yield session
        finally:
            session.close()
            transaction.rollback()
            connection.close()

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> None:
    """Create ``trial.state`` as if the first backend start was `age` ago."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()


def _license(client) -> dict:
    """GET /system/info and return its ``license`` payload (must be 200)."""
    response = client.get("/api/v1/system/info")
    assert response.status_code == 200, response.text
    return response.json()["license"]


# ── active trial ───────────────────────────────────────────────────────


def test_active_trial_reports_trial_mode(client):
    lic = _license(client)
    assert lic["mode"] == "trial"
    assert lic["status"] == "active"
    assert lic["trial_active"] is True
    assert lic["trial_expired"] is False
    assert lic["trial_days"] == settings.TRIAL_DAYS
    assert lic["remaining_seconds"] > 0
    for key in ("first_launch_at", "expires_at", "observed_at"):
        assert lic[key] is not None
        datetime.fromisoformat(lic[key])  # ISO 8601 or the parse fails


def test_active_trial_remaining_seconds_is_within_the_trial(client):
    lic = _license(client)
    total = int(timedelta(days=settings.TRIAL_DAYS).total_seconds())
    assert 0 < lic["remaining_seconds"] <= total


# ── expired trial ──────────────────────────────────────────────────────


def test_expired_trial_reports_trial_expired_mode(client, trial_state):
    _seed_trial(trial_state, age=timedelta(days=settings.TRIAL_DAYS + 1))

    response = client.get("/api/v1/system/info")
    assert response.status_code == 200, "an expired trial must not fail the endpoint"
    lic = response.json()["license"]
    assert lic["mode"] == "trial_expired"
    assert lic["status"] == "expired"
    assert lic["trial_active"] is False
    assert lic["trial_expired"] is True
    assert lic["remaining_seconds"] == 0
    assert lic["first_launch_at"] is not None
    assert lic["expires_at"] is not None


def test_remaining_seconds_never_goes_negative(client, trial_state):
    _seed_trial(trial_state, age=timedelta(days=40))  # long past expiry
    lic = _license(client)
    assert lic["remaining_seconds"] == 0
    assert lic["remaining_seconds"] >= 0


def test_remaining_seconds_matches_the_trial_clock(client, trial_state):
    age = timedelta(days=settings.TRIAL_DAYS / 2)  # halfway through
    _seed_trial(trial_state, age=age)
    lic = _license(client)
    expected = int((timedelta(days=settings.TRIAL_DAYS) - age).total_seconds())
    # Allow for the milliseconds that pass between seeding and reading.
    assert expected - 60 <= lic["remaining_seconds"] <= expected


# ── missing / uninitialized state ──────────────────────────────────────


def test_missing_trial_state_reports_unavailable(client, trial_state):
    (trial_state / f"{STATE_NAME}.state").unlink()

    lic = _license(client)
    assert lic["mode"] == "unknown"
    assert lic["status"] == "unavailable"
    assert lic["trial_active"] is False
    assert lic["trial_expired"] is False
    assert lic["first_launch_at"] is None
    assert lic["expires_at"] is None
    assert lic["observed_at"] is None
    assert lic["remaining_seconds"] == 0
    assert lic["trial_days"] == settings.TRIAL_DAYS
    assert not (trial_state / f"{STATE_NAME}.state").exists(), (
        "a read must not re-create the trial it just reported as missing"
    )


def test_system_info_never_creates_trial_state(client, tmp_path, monkeypatch):
    fresh = tmp_path / "never_created"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(fresh))

    lic = _license(client)
    assert lic["mode"] == "unknown"
    assert lic["status"] == "unavailable"
    assert not fresh.exists(), "a read must not create the state directory"


# ── corrupted state ────────────────────────────────────────────────────


def test_corrupted_trial_state_reports_unavailable(client, trial_state, tmp_path):
    (trial_state / f"{STATE_NAME}.state").write_bytes(b"not a valid envelope")

    response = client.get("/api/v1/system/info")
    assert response.status_code == 200, "corrupt state must not fail the endpoint"
    lic = response.json()["license"]
    assert lic["mode"] == "unknown"
    assert lic["status"] == "unavailable"
    assert lic["trial_active"] is False
    assert lic["trial_expired"] is False
    assert lic["first_launch_at"] is None
    assert lic["remaining_seconds"] == 0

    flat = json.dumps(response.json()).lower()
    for leak in ("corrupt", "hmac", "envelope", "dpapi", "traceback", "trial.state"):
        assert leak not in flat, leak
    assert tmp_path.name.lower() not in flat, "state path must not leak"


# ── contract preservation ──────────────────────────────────────────────


def test_existing_response_fields_and_protocol_remain(client):
    body = client.get("/api/v1/system/info").json()
    for key in (
        "name",
        "version",
        "environment",
        "database_status",
        "timestamp",
        "protocol",
        "server_id",
    ):
        assert key in body, key
    assert body["protocol"] == 1
    assert isinstance(body["license"], dict)
    assert settings.LICENSE_ENFORCEMENT == "off"


def test_license_field_is_optional_for_existing_clients():
    """The model still constructs without the new field (old callers)."""
    legacy = SystemInfoResponse(
        name="Store",
        version="1.0.0",
        environment="testing",
        database_status="connected",
        timestamp="2026-01-01T00:00:00+00:00",
    )
    assert legacy.protocol == 1
    assert legacy.license.mode == "unknown"
    assert legacy.license.status == "unavailable"
    assert legacy.license.trial_days == settings.TRIAL_DAYS


def test_license_payload_has_exactly_the_documented_fields(client):
    lic = _license(client)
    assert set(lic) == {
        "mode",
        "status",
        "trial_active",
        "trial_expired",
        "first_launch_at",
        "expires_at",
        "observed_at",
        "remaining_seconds",
        "trial_days",
    }


def test_license_info_rejects_unknown_mode_values():
    with pytest.raises(ValueError):
        LicenseInfo(mode="lifetime")


# ── no sensitive exposure ──────────────────────────────────────────────


def test_license_field_exposes_no_fingerprint_or_state_internals(
    client, trial_state, tmp_path
):
    response = client.get("/api/v1/system/info")
    assert response.status_code == 200
    flat = json.dumps(response.json()).lower()
    for leak in (
        "fingerprint",
        "machine_guid",
        "machineguid",
        "hmac",
        "dpapi",
        "envelope",
        "trial.state",
        "state_store",
        "install_id",
        "private",
    ):
        assert leak not in flat, leak
    assert tmp_path.name.lower() not in flat, "state path must not leak"
