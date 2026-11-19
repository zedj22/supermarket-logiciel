"""Phase L1-E — Trial lifecycle and enforcement, end to end.

Where the other L1 files pin *units* (``test_trial_manager``), *one matrix
row* (``test_license_guard_trial``), or *one layer* (``test_backup_license_
enforcement``), this file drives the **whole installed backend** — the real
FastAPI app with its lifespan, router-level license guard, ``/system/info``
and ``BackupService`` policy entry — through the complete §5 lifecycle and
the three ``LICENSE_ENFORCEMENT`` modes.

Two rules the whole file obeys:

* **No real waiting, no developer clock.**  Time is a fixture
  (:class:`FrozenClock`) that replaces ``app.licensing.trial._utc_now``, so
  "day 9", "exactly 240 h" and "clock rolled back" are all set explicitly
  and asserted exactly.
* **A throwaway state directory.**  Every test points ``LICENSE_STATE_DIR``
  at ``tmp_path`` before the lifespan runs, so nothing touches the
  developer's ``<backend>/data/license``.

Coverage map (L1-E §3 / §4):

    §3.1  fresh install, no trial state
    §3.2  first backend start initializes the trial
    §3.3  active across the whole 240-hour window
    §3.4  restarting does not restart the trial
    §3.5  repeated /system/info requests do not restart the trial
    §3.6  exactly-at-expiry boundary per the TrialManager contract
    §3.7  expired after the boundary
    §3.8  clock rollback handled by max_seen_at
    §3.9  missing / corrupted state fails closed
    §3.10 trial state independent of PostgreSQL (and of any backup)
    §4    off / trial / on at the router **and** the service layer
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.db.session import get_db
from app.licensing import trial as trial_module
from app.licensing.backup_policy import require_backup_action
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialRestoreForbiddenError,
    TrialUploadForbiddenError,
)
from app.licensing.state_store import StateFileCorruptedError
from app.licensing.trial import STATE_NAME, TrialManager, TrialStatus
from app.main import app

UTC = timezone.utc

#: Frozen "first backend start".  Nothing in this file asks the machine
#: what time it is — every observation is measured against this instant.
T0 = datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)

#: The approved trial length (D2): 10 calendar days = 240 elapsed hours.
WINDOW = timedelta(days=10)


# ── fixtures ────────────────────────────────────────────────────────────────


@dataclass
class FrozenClock:
    """A controllable "now" installed in place of the real UTC clock."""

    moment: datetime = T0
    #: Every value the clock ever returned, so a test can prove which
    #: instants the application actually observed.
    reads: list[datetime] = field(default_factory=list)

    def __call__(self) -> datetime:
        self.reads.append(self.moment)
        return self.moment

    def advance(self, delta: timedelta) -> datetime:
        self.moment = self.moment + delta
        return self.moment

    def set(self, moment: datetime) -> datetime:
        self.moment = moment
        return self.moment


@pytest.fixture()
def clock(monkeypatch: pytest.MonkeyPatch) -> FrozenClock:
    """Freeze the trial engine's wall clock before the app starts.

    ``TrialManager.__init__`` binds ``clock or _utc_now`` at construction
    time, so patching the module global before the lifespan runs is enough
    to give *every* later reader — guard, ``/system/info`` and
    ``BackupService`` — the same controlled time.
    """
    frozen = FrozenClock()
    monkeypatch.setattr(trial_module, "_utc_now", frozen)
    return frozen


@pytest.fixture()
def trial_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point licensing at a throwaway state dir before the app starts."""
    state_dir = tmp_path / "data" / "license"
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    return state_dir


@pytest.fixture()
def client(db_engine, trial_state: Path, clock: FrozenClock):
    """The real mounted app, running its lifespan against `trial_state`."""
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


def _state_file(trial_state: Path) -> Path:
    return trial_state / f"{STATE_NAME}.state"


def _status(trial_state: Path) -> TrialStatus | None:
    """Read the state exactly as the guard does (same manager, same clock)."""
    return TrialManager(state_dir=trial_state).status()


def _license(client) -> dict:
    resp = client.get("/api/v1/system/info")
    assert resp.status_code == 200, resp.text
    return resp.json()["license"]


def _error(resp) -> dict:
    assert resp.status_code >= 400, resp.text
    payload = resp.json()
    assert "error" in payload, payload
    return payload["error"]


# ── §3.1 / §3.2 — fresh install → first start ───────────────────────────────


def test_fresh_install_has_no_trial_until_the_first_backend_start(
    trial_state, clock
):
    """A brand-new install has *no* trial — and the first start makes one."""
    assert not _state_file(trial_state).exists(), "nothing may pre-create it"
    assert TrialManager(state_dir=trial_state).status() is None
    assert clock.moment == T0

    with TestClient(app):  # entering the app = the first backend start
        started = _status(trial_state)

    assert _state_file(trial_state).exists()
    assert started is not None
    assert started.mode == "trial"
    assert started.first_launch_at == T0
    assert started.expires_at - started.first_launch_at == WINDOW
    assert started.trial_days == 10


def test_the_first_start_is_the_only_creator_of_the_state(
    client, trial_state, clock
):
    """§5 T1 idempotence at the manager layer, with the clock frozen."""
    first = _status(trial_state)
    again = TrialManager(state_dir=trial_state).ensure_started()

    assert first.install_id == again.install_id
    assert first.first_launch_at == again.first_launch_at == T0
    assert _state_file(trial_state).read_bytes()  # still a real envelope


# ── §3.3 / §3.6 / §3.7 — the 240-hour window, boundary and expiry ───────────


def test_the_trial_serves_every_hour_of_the_240_hour_window(
    client, trial_state, clock, trial_enforcement
):
    """Active for the whole window; health/system stay up at every step.

    Steps jump the clock (no sleeping) from hour 0 to hour 240, asserting
    on each one that ``/system/info`` still reports an active trial and
    that a business route is refused only by *authentication* — the sign
    that the license guard let it through.
    """
    assert _license(client)["mode"] == "trial"

    for hours in (1, 24, 120, 239, 240):
        clock.set(T0 + timedelta(hours=hours))

        snapshot = _license(client)
        assert snapshot["mode"] == "trial", hours
        assert snapshot["status"] == "active", hours
        assert snapshot["trial_active"] is True
        expected_left = int((WINDOW - timedelta(hours=hours)).total_seconds())
        assert snapshot["remaining_seconds"] == expected_left, hours

        # Guard passed (a 401 is authentication, not licensing) …
        business = client.get("/api/v1/products")
        assert business.status_code == 401, (hours, business.status_code)
        # … and the bootstrap surface is always up.
        assert client.get("/api/v1/health").status_code == 200
        assert _status(trial_state).active is True


def test_exactly_at_the_240_hour_boundary_the_trial_is_still_active(
    client, trial_state, clock, trial_enforcement
):
    """§5 T5 contract: expired only *strictly after* ``expires_at``."""
    clock.set(T0 + WINDOW)

    snapshot = _license(client)
    assert snapshot["mode"] == "trial"
    assert snapshot["status"] == "active"
    assert snapshot["remaining_seconds"] == 0, "at the boundary, not past it"
    assert snapshot["expires_at"].startswith("2026-01-11T00:00:00+00:00")

    assert client.get("/api/v1/products").status_code == 401
    assert _status(trial_state).active is True
    assert _status(trial_state).mode == "trial"


def test_one_second_past_the_boundary_the_trial_is_expired(
    client, trial_state, clock, trial_enforcement
):
    clock.set(T0 + WINDOW + timedelta(seconds=1))

    snapshot = _license(client)
    assert snapshot["mode"] == "trial_expired"
    assert snapshot["status"] == "expired"
    assert snapshot["trial_expired"] is True
    assert snapshot["remaining_seconds"] == 0

    blocked = client.get("/api/v1/products")
    assert blocked.status_code == 403
    error = _error(blocked)
    assert error["code"] == "trial_expired"
    assert error["message_key"] == "errors.license.trialExpired"
    assert _status(trial_state).expired is True


# ── §3.4 / §3.5 — restarts and repeated reads never restart the trial ───────


def test_restarting_the_backend_does_not_restart_the_trial(
    trial_state, clock, trial_enforcement
):
    """D5: the clock keeps running while the application is closed."""
    with TestClient(app) as first:
        assert first.get("/api/v1/health").status_code == 200
        original = _status(trial_state)
    assert original is not None

    # The store is closed for a week — and comes back on a later day.
    clock.set(T0 + timedelta(days=7))
    with TestClient(app) as restarted:
        assert restarted.get("/api/v1/health").status_code == 200
        after = _status(trial_state)

    assert after.install_id == original.install_id
    assert after.first_launch_at == T0, "a restart must not move day zero"
    assert after.expires_at == original.expires_at == T0 + WINDOW
    assert after.mode == "trial", "seven days in, the trial is still running"

    # The restarted backend enforces from the *original* start too.
    clock.set(T0 + timedelta(days=11))
    resp = restarted.get("/api/v1/products")
    assert resp.status_code == 403
    assert _error(resp)["code"] == "trial_expired"


def test_repeated_system_info_requests_never_restart_the_trial(
    client, trial_state, clock
):
    """L1-B: reading the licence is read-only, however often it is read."""
    before_bytes = _state_file(trial_state).read_bytes()
    first = _license(client)
    clock.set(T0 + timedelta(days=3))

    # The first read at the new instant is allowed to clamp ``max_seen``
    # forward; everything after it must be a pure read.
    _license(client)
    after_first_read = _state_file(trial_state).read_bytes()

    snapshots = [_license(client) for _ in range(9)]
    after_bytes = _state_file(trial_state).read_bytes()
    after = _status(trial_state)

    assert after.first_launch_at == T0
    assert first["first_launch_at"] == T0.isoformat()
    assert after.expires_at.isoformat() == first["expires_at"]
    assert after.mode == "trial"
    assert {s["first_launch_at"] for s in snapshots} == {T0.isoformat()}
    assert {s["expires_at"] for s in snapshots} == {first["expires_at"]}
    # Same frozen instant → nothing advanced → not one of the nine reads
    # rewrote the file (one write/second is the documented upper bound).
    assert after_bytes == after_first_read, "a read must not rewrite the state"
    assert after_first_read != before_bytes, "the day-3 clamp did persist"


# ── §3.8 — clock rollback ───────────────────────────────────────────────────


def test_clock_rollback_never_extends_the_trial(
    client, trial_state, clock, trial_enforcement
):
    """§5 T4: ``observed_at = max(wall clock, max_seen_at)``."""
    clock.set(T0 + timedelta(days=5))
    progressed = _license(client)
    assert progressed["mode"] == "trial"
    assert progressed["remaining_seconds"] == int(timedelta(days=5).total_seconds())

    # Somebody rolls the machine clock back a week.
    clock.set(T0 - timedelta(days=2))
    observed = _status(trial_state)

    assert observed.rollback_detected is True
    assert observed.observed_at == T0 + timedelta(days=5), "clamped forward"
    assert observed.max_seen_at == T0 + timedelta(days=5)
    # The API keeps reporting the clamped observation, not the rolled-back
    # wall clock, so the remaining time can only shrink.
    rolled = _license(client)
    assert rolled["observed_at"].startswith("2026-01-06T00:00:00+00:00")
    assert rolled["remaining_seconds"] == int(timedelta(days=5).total_seconds())
    assert client.get("/api/v1/products").status_code == 401, "still active"

    # …and even at the rolled-back instant the trial can only get shorter.
    clock.set(T0 + WINDOW + timedelta(hours=1))
    assert _license(client)["mode"] == "trial_expired"


def test_rollback_is_not_persisted_away(client, trial_state, clock):
    """The clamped mark survives the trip through the file."""
    clock.set(T0 + timedelta(days=4))
    _license(client)  # persists max_seen_at = T0+4d

    clock.set(T0)
    _license(client)  # observes the rollback, rewrites nothing
    reloaded = TrialManager(state_dir=trial_state, clock=clock).status()
    assert reloaded.max_seen_at == T0 + timedelta(days=4)
    assert reloaded.rollback_detected is True


# ── §3.9 — missing and corrupted state fail closed ──────────────────────────


def test_missing_state_fails_closed_and_is_never_recreated_by_a_read(
    client, trial_state, clock, trial_enforcement
):
    _state_file(trial_state).unlink()
    assert not _state_file(trial_state).exists()

    snapshot = _license(client)
    assert snapshot["mode"] == "unknown"
    assert snapshot["status"] == "unavailable"
    assert snapshot["trial_active"] is False
    assert snapshot["first_launch_at"] is None

    blocked = client.get("/api/v1/products")
    assert blocked.status_code == 403
    assert _error(blocked)["code"] == "license_required"
    assert client.get("/api/v1/health").status_code == 200

    # Neither the endpoint nor the guard may silently start a new trial
    # (R3: reinstalling is what starts the next one, and only at startup).
    assert not _state_file(trial_state).exists()


def test_corrupted_state_fails_closed_everywhere(
    client, trial_state, clock, trial_enforcement
):
    _state_file(trial_state).write_bytes(b"not a sealed envelope")

    snapshot = _license(client)
    assert snapshot["mode"] == "unknown"
    assert snapshot["status"] == "unavailable"

    blocked = client.get("/api/v1/products")
    assert blocked.status_code == 503
    assert _error(blocked)["code"] == "license_status_unavailable"
    # …and it stays a licensing answer, not a network one.
    assert blocked.headers["content-type"].startswith("application/json")
    assert str(trial_state) not in blocked.text

    with pytest.raises(StateFileCorruptedError):
        TrialManager(state_dir=trial_state, clock=clock).status()
    with pytest.raises(LicenseStatusUnavailableError):
        require_backup_action("list")


# ── §3.10 — the trial lives outside PostgreSQL ──────────────────────────────


def test_trial_state_is_independent_of_postgresql():
    """No licence/trial table, column or relationship exists in the ORM.

    A ``pg_dump``/restore therefore cannot carry, restore or reset the
    trial: the only state is the ``trial.state`` file under
    ``LICENSE_STATE_DIR``.
    """
    from app.db.base import Base

    forbidden = ("license", "licence", "trial", "install_id")
    for table_name, table in Base.metadata.tables.items():
        columns = {c.name for c in table.columns}
        hits = [c for c in columns if any(k in c.lower() for k in forbidden)]
        assert not hits, (table_name, hits)
        assert not any(k in table_name.lower() for k in forbidden), table_name

    # The state directory is a plain directory outside any database file.
    resolved = Path(settings.LICENSE_STATE_DIR)
    assert resolved.name == "license" and resolved.parent.name == "data"


def test_the_database_backup_service_copies_no_licensing_state():
    """``BackupService`` may consult the policy — nothing else.

    The AST (comments and docstrings stripped) must reach exactly one
    licensing symbol: ``require_backup_action``.  No state directory, no
    state file name, no envelope, no hardware identifier — so nothing
    licence-related can be read, dumped into an archive or restored from
    one.
    """
    import ast

    source = Path("app/services/backup.py").read_text(encoding="utf-8")
    tree = ast.parse(source)

    reachable = {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
        and node.module
        and node.module.startswith("app.licensing")
        for alias in node.names
    }
    assert reachable == {"require_backup_action"}, reachable

    for node in ast.walk(tree):  # drop every docstring
        body = getattr(node, "body", None)
        if (
            isinstance(body, list)
            and body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)
        ):
            body[0:1] = []

    executable = ast.unparse(tree).lower()
    for forbidden in (
        "license_state_dir",
        "state_name",
        "trial.state",
        "statefile",
        "hardwarefingerprint",
        "machineguid",
        "dpapi",
    ):
        assert forbidden not in executable, forbidden


# ── §4 — enforcement modes at the router *and* the service layer ────────────


def test_off_is_a_complete_no_op_even_for_an_expired_trial(
    client, trial_state, clock, monkeypatch
):
    """L0 exit criterion, re-checked with a deliberately expired state."""
    assert settings.LICENSE_ENFORCEMENT == "off"
    clock.set(T0 + WINDOW + timedelta(days=1))

    assert client.get("/api/v1/products").status_code == 401
    assert client.get("/api/v1/health").status_code == 200
    assert "trial" not in client.get("/api/v1/products").text.lower()
    # The service layer reads no state at all while off.
    require_backup_action("create")
    require_backup_action("upload")
    require_backup_action("restore")

    # …and a *corrupt* state changes nothing either.
    _state_file(trial_state).write_bytes(b"garbage")
    assert client.get("/api/v1/products").status_code == 401
    require_backup_action("list")

    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "trial")
    assert client.get("/api/v1/products").status_code == 503


def test_trial_mode_agrees_at_both_layers_for_an_active_trial(
    client, trial_state, clock, trial_enforcement
):
    """D1: one answer from the guard and one from the service."""
    assert client.get("/api/v1/products").status_code == 401  # guard: pass
    assert client.get("/api/v1/auth/login-users").status_code == 200
    require_backup_action("create")  # service: pass
    require_backup_action("list")
    require_backup_action("inspect")
    require_backup_action("download")


def test_trial_mode_refuses_upload_and_restore_at_both_layers(
    client, trial_state, clock, trial_enforcement
):
    """D6: the guard answers 403 and the service raises, same code."""
    guard_upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", b"SELECT 1;", "application/sql")},
    )
    assert guard_upload.status_code == 403
    assert _error(guard_upload)["code"] == "trial_upload_forbidden"

    guard_restore = client.post(
        "/api/v1/backups/1/restore", json={"confirm": True}
    )
    assert guard_restore.status_code == 403
    assert _error(guard_restore)["code"] == "trial_restore_forbidden"

    with pytest.raises(TrialUploadForbiddenError) as upload:
        require_backup_action("upload")
    assert upload.value.code == "trial_upload_forbidden"
    with pytest.raises(TrialRestoreForbiddenError) as restore:
        require_backup_action("restore")
    assert restore.value.code == "trial_restore_forbidden"


def test_trial_mode_agrees_at_both_layers_for_an_expired_trial(
    client, trial_state, clock, trial_enforcement
):
    clock.set(T0 + WINDOW + timedelta(days=1))

    # Router: business closed, read-only rescue open.
    assert _error(client.get("/api/v1/products"))["code"] == "trial_expired"
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups/1/download").status_code == 401

    # Service: the same verdict without a request in sight.
    with pytest.raises(TrialExpiredError) as create:
        require_backup_action("create")
    assert create.value.code == "trial_expired"
    with pytest.raises(TrialExpiredError):
        require_backup_action("upload")
    with pytest.raises(TrialExpiredError):
        require_backup_action("restore")
    require_backup_action("list")
    require_backup_action("download")

    # §4.4 / D3: inspecting is not part of "list + download only".
    with pytest.raises(TrialExpiredError):
        require_backup_action("inspect")
    assert _error(client.get("/api/v1/backups/1/inspect"))["code"] == (
        "trial_expired"
    )


def test_missing_state_is_license_required_at_both_layers(
    client, trial_state, clock, trial_enforcement
):
    _state_file(trial_state).unlink()

    assert _error(client.get("/api/v1/products"))["code"] == "license_required"
    with pytest.raises(LicenseRequiredError) as service:
        require_backup_action("create")
    assert service.value.code == "license_required"
    # The service refuses *every* action, not only the write ones.
    for action in ("create", "list", "download", "upload", "restore"):
        with pytest.raises(LicenseRequiredError):
            require_backup_action(action)


def test_on_admits_an_active_trial_at_both_layers(
    client, trial_state, clock, monkeypatch
):
    """Phase L2-B policy: ``on`` admits *either* an active Trial *or* a valid Lifetime license.

    This pins the **Trial** half of that decision end to end — router
    guard, ``BackupService`` policy entry and the §4.4 backup rows —
    replacing the pre-L2-B behaviour this very test used to pin (``on``
    failing closed even for an active trial, see the L1-E report).
    The Lifetime half is covered by ``test_backup_lifetime_enforcement``
    and ``test_license_guard_on``.
    """
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")
    assert _status(trial_state).active is True, "the trial really is active"

    # Business routes pass the guard: a 401 is authentication, not licensing.
    assert client.get("/api/v1/products").status_code == 401

    # The §4.4 matrix still answers backup rows for an active trial.
    assert client.get("/api/v1/backups").status_code == 401
    upload = client.post(
        "/api/v1/backups/upload",
        files={"file": ("dump.sql", b"not-a-dump", "application/sql")},
    )
    assert _error(upload)["code"] == "trial_upload_forbidden"
    restore = client.post(
        "/api/v1/backups/1/restore", json={"confirm": True}
    )
    assert _error(restore)["code"] == "trial_restore_forbidden"

    # Service layer: the same decision, applied from the same state.
    require_backup_action("list")
    with pytest.raises(TrialUploadForbiddenError):
        require_backup_action("upload")
    with pytest.raises(TrialRestoreForbiddenError):
        require_backup_action("restore")

    # The public status contract is untouched by the enforcement mode.
    assert _license(client)["mode"] == "trial"
    assert _license(client)["status"] == "active"


def test_on_keeps_the_repair_surface_reachable(
    client, trial_state, clock, monkeypatch
):
    monkeypatch.setattr(settings, "LICENSE_ENFORCEMENT", "on")

    assert client.get("/api/v1/health").status_code == 200
    assert client.get("/api/v1/system/info").status_code == 200
    assert client.get("/api/v1/auth/login-users").status_code == 200
    # /license stays reachable so an install can be activated later (L2);
    # since Phase L2-A it is a real route answering 200 under `on`.
    assert client.get("/api/v1/license/status").status_code == 200


def test_expired_trial_is_an_http_answer_not_a_connection_failure(
    client, trial_state, clock, trial_enforcement
):
    """§4: the client must never read licensing as "the server is down"."""
    clock.set(T0 + WINDOW + timedelta(seconds=1))

    resp = client.get("/api/v1/products")
    assert resp.status_code == 403
    assert resp.headers["content-type"].startswith("application/json")
    assert resp.elapsed is not None  # a normal, answered request
    body = resp.json()["error"]
    assert body["code"] == "trial_expired"
    assert set(body) >= {"code", "message", "message_key"}
    # Distinct from the transport layer entirely.
    assert "network" not in resp.text.lower()
    assert "retry" not in body["code"]
