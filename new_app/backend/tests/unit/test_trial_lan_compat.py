"""Phase L1 × Phase 16: the Free Trial engine and the LAN guards together.

Pins the decisions that cut across both phases:

  D1   an active trial serves paired LAN clients exactly as a licensed
       install would — the trial is a *main-PC* decision (§4.4), never a
       per-till one;
  T6   the pairing / bootstrap surface stays reachable while the trial
       runs **and** after it expires, so a store can still be repaired;
  §4.4 guard ordering: rate limit → device guard → **license guard**, so
       pairing and device errors are never masked by licensing ones — and
       licensing has no loopback exemption (Q6 covers the device guard
       only).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api.v1 import router as router_module
from app.core.config import settings
from app.db.base import Base
from app.db.session import get_db
from app.licensing.trial import STATE_NAME, TrialManager
from app.main import app
from app.services.auth import AuthService
from app.services.devices import reset_process_state
from tests.unit.test_phase16_devices import (
    DEVICE_ID,
    _approve_pairing,
    _login,
    _pairing_code,
    _peer_client,
)

UTC = timezone.utc


# ── fixtures (Phase 16 harness + a throwaway license state dir) ────────────


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def testing_session(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, testing_session):
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    session.commit()
    yield session
    session.close()


@pytest.fixture()
def trial_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """The app must start with licensing pointed at a throwaway directory."""
    state_dir = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    return state_dir


@pytest.fixture()
def client(engine, testing_session, db, trial_state):
    def override_get_db():
        session = testing_session()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


@pytest.fixture(autouse=True)
def clean_process_state():
    """Pairing code / rate limiters / token vault are process-global."""
    reset_process_state()
    yield
    reset_process_state()


@pytest.fixture()
def lan_on(monkeypatch: pytest.MonkeyPatch) -> bool:
    monkeypatch.setattr(settings, "LAN_MODE", True)
    return True


@pytest.fixture()
def trial_enforcement(monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    return "trial"


@pytest.fixture()
def admin_headers(client) -> dict:
    return _login(client, "Admin", "1234")


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> Path:
    """Rewrite ``trial.state`` as if the first backend start was `age` ago."""
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()
    return state_dir


def _paired_client_headers(client, admin_headers) -> dict:
    """Pair + approve, returning the headers a real LAN till would send."""
    code = _pairing_code(client, admin_headers)
    _device_id, token = _approve_pairing(client, code, admin_headers)
    return {
        **admin_headers,
        "X-Device-ID": DEVICE_ID,
        "X-Device-Token": token,
    }


# ── guard ordering (§11.2) ─────────────────────────────────────────────────


def test_license_guard_is_the_last_router_dependency():
    # 1. The central router declares them in exactly this order …
    wrappers = [d.dependency.__name__ for d in router_module.api_router.dependencies]
    assert wrappers == ["api_rate_guard", "device_guard", "license_guard"], wrappers

    # 2. … and every feature router included underneath inherits that same
    #    ordered list, so a device/pairing error is always raised before a
    #    licensing one on every single route.
    for included in router_module.api_router.routes:
        context = included.include_context
        names = [d.dependency.__name__ for d in context.dependencies]
        assert names == ["api_rate_guard", "device_guard", "license_guard"], (
            context.prefix,
            names,
        )


# ── D1: an active trial serves the LAN ────────────────────────────────────


def test_active_trial_serves_a_paired_lan_client(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    headers = _paired_client_headers(client, admin_headers)

    resp = client.get("/api/v1/users", headers=headers)
    assert resp.status_code == 200, resp.text
    for licensing_code in ("trial_expired", "license_required",
                           "license_status_unavailable"):
        assert licensing_code not in resp.text


def test_active_trial_leaves_the_server_pos_working_over_loopback(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    """Q6 + D1: the store server's own till is not special to licensing."""
    resp = _peer_client("127.0.0.1").get(
        "/api/v1/dashboard", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text


# ── expired: the trial is enforced for every peer ─────────────────────────


def test_expired_trial_blocks_a_paired_lan_client(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    headers = _paired_client_headers(client, admin_headers)
    _seed_trial(trial_state, age=timedelta(days=11))

    resp = client.get("/api/v1/users", headers=headers)
    assert resp.status_code == 403, resp.text
    assert resp.json()["error"]["code"] == "trial_expired"


def test_expired_trial_blocks_the_server_pos_over_loopback(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    """No loopback exemption: licensing applies to the Main PC itself."""
    _seed_trial(trial_state, age=timedelta(days=11))
    resp = _peer_client("127.0.0.1").get(
        "/api/v1/dashboard", headers=admin_headers
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "trial_expired"


def test_device_errors_are_never_masked_by_licensing(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    """Ordering: an unpaired identity fails in the device guard first."""
    _seed_trial(trial_state, age=timedelta(days=11))

    # A remote peer that never paired is a *device* problem, not a license one.
    remote = _peer_client("192.168.1.50").get(
        "/api/v1/products", headers=admin_headers
    )
    assert remote.status_code == 401
    assert remote.json()["error"]["code"] == "device_required"

    # A paired device with a bad token is a device problem too.
    code = _pairing_code(client, admin_headers)
    assert code
    bad = client.get(
        "/api/v1/users",
        headers={
            **admin_headers,
            "X-Device-ID": DEVICE_ID,
            "X-Device-Token": "x" * 40,
        },
    )
    assert bad.status_code == 403
    assert bad.json()["error"]["code"] == "device_not_paired"


def test_active_trial_does_not_hide_device_errors(
    client, admin_headers, trial_state, trial_enforcement, lan_on
):
    """With the trial running the device contract is byte-for-byte intact."""
    resp = client.get(
        "/api/v1/users",
        headers={
            **admin_headers,
            "X-Device-ID": DEVICE_ID,
            "X-Device-Token": "wrong-token",
        },
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "device_not_paired"


# ── T6: pairing stays reachable in every trial state ──────────────────────


def test_pairing_surface_stays_open_while_the_trial_expires(
    client, trial_state, trial_enforcement, lan_on
):
    _seed_trial(trial_state, age=timedelta(days=11))

    # Login itself must still work, or nobody could ever approve a device.
    headers = _login(client, "Admin", "1234")

    code = _pairing_code(client, headers)
    assert len(code) == 6

    pair = client.post(
        "/api/v1/devices/pair",
        json={
            "device_id": DEVICE_ID,
            "display_name": "Till 1",
            "pairing_code": code,
            "client_version": "1.0.0",
        },
    )
    assert pair.status_code == 201, pair.text
    pairing_id = pair.json()["pairing_id"]

    poll = client.get(f"/api/v1/devices/pairings/{pairing_id}")
    assert poll.status_code == 200
    assert poll.json()["status"] == "pending"

    approve = client.post(f"/api/v1/devices/{DEVICE_ID}/approve", headers=headers)
    assert approve.status_code == 200, approve.text

    final = client.get(f"/api/v1/devices/pairings/{pairing_id}").json()
    assert final["status"] == "approved"
    assert final["device_token"]


def test_bootstrap_surface_is_reachable_while_the_trial_expires(
    client, trial_state, trial_enforcement
):
    _seed_trial(trial_state, age=timedelta(days=11))

    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/system/info").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
    # /devices is license-allowlisted: a 401 here is authentication.
    assert client.get("/api/v1/devices").status_code == 401
