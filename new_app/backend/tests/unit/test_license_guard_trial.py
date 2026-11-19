"""Phase L1: license guard under ``LICENSE_ENFORCEMENT=trial``.

Matrix of §4.4 with the Free Trial engine answering the question, plus the
start-up wiring of §11.2 (`main.py` lifespan) and the D3/D6 backup rows.

Guarantees pinned here:
  * default ``off`` stays a complete no-op — even with an expired trial on
    disk (L0 exit criterion, unchanged),
  * active trial ⇒ business routes behave exactly as before,
  * expired trial ⇒ business routes/backup creation 403 ``trial_expired``,
    backup **list + download** still reachable (D3), upload/restore refused,
  * missing state ⇒ 403 ``license_required``; unverifiable state ⇒ 503
    ``license_status_unavailable`` — neither is ever answered "allowed",
  * the bootstrap surface (health/system/auth/devices/license) stays open
    in every state, so a locked install can still be repaired.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.db.session import get_db
from app.licensing.trial import STATE_NAME, TrialManager, TrialStatus
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


@pytest.fixture()
def trial_enforcement(monkeypatch: pytest.MonkeyPatch) -> str:
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    return "trial"


def _seed_trial(state_dir: Path, *, age: timedelta = timedelta(0)) -> Path:
    """Create (or replace) ``trial.state`` as if the first backend start
    happened `age` ago — the guard re-reads it on every request."""
    # Drop whatever the lifespan already wrote: the trial must *start* at
    # `first_launch_at`, not merely observe it (§5 T3).
    (state_dir / f"{STATE_NAME}.state").unlink(missing_ok=True)
    first_start = datetime.now(UTC) - age
    TrialManager(state_dir=state_dir, clock=lambda: first_start).ensure_started()
    return state_dir


def _status(state_dir: Path) -> TrialStatus:
    return TrialManager(state_dir=state_dir).status()


def _error(resp) -> dict:
    assert resp.status_code >= 400, resp.text
    return resp.json()["error"]


# ── default: enforcement off, guard a complete no-op ──────────────────────


def test_enforcement_is_off_by_default(client, trial_state):
    assert settings.LICENSE_ENFORCEMENT == "off"
    _seed_trial(trial_state, age=timedelta(days=11))  # expired on disk

    resp = client.get("/api/v1/products")
    assert resp.status_code == 401, "off ⇒ no licensing decision at all"
    body = resp.text.lower()
    assert "trial" not in body and "license" not in body
    assert client.get("/api/v1/health").status_code == 200


# ── §11.2 / D5: the lifespan starts the trial ─────────────────────────────


def test_lifespan_starts_the_trial_on_the_first_backend_start(client, trial_state):
    status = _status(trial_state)
    assert status is not None, "entering the app must create trial.state"
    assert status.mode == "trial"
    assert status.expires_at - status.first_launch_at == timedelta(days=10)


def test_a_second_startup_does_not_reset_the_trial(client, trial_state):
    before = _status(trial_state)
    assert before is not None

    with TestClient(app) as restarted:  # a full restart of the backend
        assert restarted.get("/api/v1/health").status_code == 200
    after = _status(trial_state)

    assert after is not None
    assert after.install_id == before.install_id
    assert after.first_launch_at == before.first_launch_at
    assert after.expires_at == before.expires_at


def test_startup_failure_never_blocks_the_api(trial_state, monkeypatch):
    """§11.2: mirror the discovery pattern — log, never refuse to serve."""
    import app.main as main_module

    class _BrokenStore:
        @classmethod
        def from_settings(cls, **kwargs):
            raise OSError("license state directory is read-only")

    monkeypatch.setattr(main_module, "TrialManager", _BrokenStore)
    with TestClient(app) as broken:
        assert broken.get("/api/v1/health").status_code == 200
        # …and the state that could not be verified fails closed later.
        monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
        resp = broken.get("/api/v1/products")
        assert resp.status_code == 403
        assert _error(resp)["code"] == "license_required"


# ── active trial: business as usual, D6 upload/restore only ──────────────


def test_active_trial_leaves_business_routes_unchanged(
    client, trial_state, trial_enforcement
):
    _seed_trial(trial_state)

    resp = client.get("/api/v1/products")
    assert resp.status_code == 401, "reached authentication, not licensing"
    body = resp.text.lower()
    assert "trial" not in body and "license" not in body

    assert client.get("/api/v1/auth/login-users").status_code == 200
    assert client.get("/api/v1/health").status_code == 200
    assert _status(trial_state).mode == "trial"


def test_active_trial_still_refuses_backup_upload_and_restore(
    client, trial_state, trial_enforcement
):
    """D6 / §8: the only two routes an active trial does not get."""
    _seed_trial(trial_state)

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", b"SELECT 1;", "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_upload_forbidden"
    assert _error(upload)["message_key"] == "errors.license.trialUploadForbidden"

    restore = client.post("/api/v1/backups/1/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_restore_forbidden"
    assert _error(restore)["message_key"] == "errors.license.trialRestoreForbidden"

    # Export stays available (D6): these pass the guard and reach auth.
    assert client.post("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/1/download").status_code == 401


# ── expired trial ─────────────────────────────────────────────────────────


def test_expired_trial_blocks_business_routes(client, trial_state, trial_enforcement):
    _seed_trial(trial_state, age=timedelta(days=11))

    for path in ("/api/v1/products", "/api/v1/sales", "/api/v1/customers",
                 "/api/v1/reports/financial", "/api/v1/dashboard",
                 "/api/v1/settings"):
        resp = client.get(path)
        assert resp.status_code == 403, (path, resp.status_code, resp.text)
        error = _error(resp)
        assert error["code"] == "trial_expired"
        assert error["message_key"] == "errors.license.trialExpired"

    assert _status(trial_state).expired


def test_expired_trial_keeps_the_bootstrap_surface_open(
    client, trial_state, trial_enforcement
):
    """§5 T6: health/system/auth/devices (and /license) never lock out."""
    _seed_trial(trial_state, age=timedelta(days=11))

    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200
    assert client.get("/api/v1/system/info").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
    # /devices is allowlisted: the 401 below is authentication, not licensing.
    assert client.get("/api/v1/devices").status_code == 401
    # /license is allowlisted and, since Phase L2-A, a real route: an
    # expired trial must still be able to reach activation and read status.
    assert client.get("/api/v1/license/status").status_code == 200


def test_expired_trial_allows_backup_list_and_download_only(
    client, trial_state, trial_enforcement
):
    """D3: read-only data rescue stays up; create/upload/restore do not."""
    _seed_trial(trial_state, age=timedelta(days=11))

    # Allowed by the guard (they stop at authentication instead) …
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/1/download").status_code == 401

    # … refused by the guard …
    create = client.post("/api/v1/backups")
    assert create.status_code == 403
    assert _error(create)["code"] == "trial_expired"

    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", b"SELECT 1;", "application/sql")},
    )
    assert upload.status_code == 403
    assert _error(upload)["code"] == "trial_expired"

    restore = client.post("/api/v1/backups/1/restore", json={"confirm": True})
    assert restore.status_code == 403
    assert _error(restore)["code"] == "trial_expired"

    # §4.4 lists list + download only: inspecting is not part of D3.
    inspect = client.get("/api/v1/backups/1/inspect")
    assert inspect.status_code == 403
    assert _error(inspect)["code"] == "trial_expired"


# ── missing vs corrupt — both fail closed, with distinct codes ────────────


def test_missing_trial_state_is_license_required(client, trial_state, trial_enforcement):
    (trial_state / f"{STATE_NAME}.state").unlink()

    resp = client.get("/api/v1/products")
    assert resp.status_code == 403
    assert _error(resp)["code"] == "license_required"
    assert _error(resp)["message_key"] == "errors.license.required"
    assert client.get("/api/v1/health").status_code == 200


def test_corrupt_trial_state_is_503_and_never_allowed(
    client, trial_state, trial_enforcement
):
    _seed_trial(trial_state)
    (trial_state / f"{STATE_NAME}.state").write_bytes(b"garbage, not an envelope")

    resp = client.get("/api/v1/products")
    assert resp.status_code == 503
    assert _error(resp)["code"] == "license_status_unavailable"
    assert _error(resp)["message_key"] == "errors.license.statusUnavailable"

    # Fail closed, not open: the bootstrap surface is still served.
    assert client.get("/api/v1/health").status_code == 200
    # …and with enforcement off nothing changes at all.
    settings.LICENSE_ENFORCEMENT = "off"
    try:
        assert client.get("/api/v1/products").status_code == 401
    finally:
        settings.LICENSE_ENFORCEMENT = "trial"


def test_tampered_trial_state_is_detected(client, trial_state, trial_enforcement):
    """Flipping a byte of the sealed payload breaks the HMAC → 503."""
    _seed_trial(trial_state)
    path = trial_state / f"{STATE_NAME}.state"
    raw = path.read_bytes()
    flipped = bytearray(raw)
    flipped[len(flipped) // 2] ^= 0xFF
    path.write_bytes(bytes(flipped))

    resp = client.get("/api/v1/products")
    assert resp.status_code == 503
    assert _error(resp)["code"] == "license_status_unavailable"


def test_error_payloads_never_leak_state_paths(client, trial_state, trial_enforcement):
    _seed_trial(trial_state, age=timedelta(days=11))
    resp = client.get("/api/v1/products")
    assert resp.status_code == 403
    assert str(trial_state) not in resp.text
    assert "hmac" not in resp.text.lower()
