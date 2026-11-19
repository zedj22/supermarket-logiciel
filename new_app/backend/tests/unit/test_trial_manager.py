"""Phase L1: Free Trial engine — deterministic clock, no sleeps.

Covers §12 L1 / §13.1 (`trial`) and the lifecycle table §5 (T1–T5) with an
injected clock (§13.3: "trial clock simulation via injectable clock — never
by actually waiting 10 days").

Policy pinned here:
  * the trial is created exactly once, on the first backend start (D5),
  * it counts 10 calendar days / 240 elapsed hours (D2) and a restart never
    resets it,
  * a rolled-back clock is detected and clamped forward (§5 T4 / R2) so it
    can never extend the trial,
  * missing state (`None`) is not corrupt state (raises), and both fail
    closed at the guard,
  * trial state lives outside PostgreSQL, so no dump/restore moves it (D).
"""

from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy import create_engine

from app.core.config import settings
from app.db.base import Base
from app.licensing import trial as trial_module
from app.licensing.state_store import (
    StateFileCorruptedError,
    StateStore,
    StateStoreError,
    dpapi_available,
)
from app.licensing.trial import STATE_NAME, TrialManager, TrialStatus
from app.services import backup as backup_service

UTC = timezone.utc

#: Fixed reference instant — every test is expressed relative to it.
T0 = datetime(2026, 3, 1, 8, 0, 0, tzinfo=UTC)

DAY = timedelta(days=1)
HOUR = timedelta(hours=1)
SECOND = timedelta(seconds=1)

#: §5 D2: 10 calendar days == 240 elapsed hours.
TRIAL_LENGTH = timedelta(days=10)


class Clock:
    """Injectable clock: set/advance it explicitly, never sleep."""

    def __init__(self, now: datetime = T0) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def set(self, now: datetime) -> None:
        self.now = now

    def advance(self, delta: timedelta) -> None:
        self.now += delta


@pytest.fixture()
def clock() -> Clock:
    return Clock(T0)


@pytest.fixture()
def state_dir(tmp_path: Path) -> Path:
    return tmp_path / "license"


def _plain_store(state_dir: Path) -> StateStore:
    """A non-DPAPI store so envelopes stay inspectable on every platform."""
    return StateStore(state_dir, use_dpapi=False)


def _manager(state_dir: Path, clock: Clock, **kwargs) -> TrialManager:
    kwargs.setdefault("store", _plain_store(state_dir))
    kwargs.setdefault("clock", clock)
    return TrialManager(state_dir=state_dir, **kwargs)


def _envelope(state_dir: Path) -> dict:
    return json.loads((state_dir / f"{STATE_NAME}.state").read_text(encoding="utf-8"))


def _payload(state_dir: Path) -> dict:
    """Decoded (plain-protection) payload — only valid for `_plain_store`."""
    envelope = _envelope(state_dir)
    assert envelope["protection"] == "plain", "test helper requires a plain store"
    return json.loads(base64.b64decode(envelope["data"]).decode("utf-8"))


# ── T1/D5: start once, on the first backend start ─────────────────────────


def test_first_startup_creates_trial_state_exactly_once(state_dir, clock):
    manager = _manager(state_dir, clock)

    assert manager.status() is None, "nothing exists before the first start"
    assert not manager.state_path.exists()

    status = manager.ensure_started()
    assert manager.state_path.is_file()
    assert status.first_launch_at == T0
    assert status.expires_at == T0 + TRIAL_LENGTH
    assert status.mode == "trial"
    assert status.active and not status.expired

    created = manager.state_path.read_bytes()

    # A second backend start (same instant) must not rewrite the trial.
    again = _manager(state_dir, clock).ensure_started()
    assert again.first_launch_at == status.first_launch_at
    assert again.install_id == status.install_id
    assert manager.state_path.read_bytes() == created


def test_repeated_startup_preserves_the_original_start_time(state_dir, clock):
    first = _manager(state_dir, clock).ensure_started()

    clock.advance(3 * DAY + 5 * HOUR)  # several restarts later
    second = _manager(state_dir, clock).ensure_started()

    assert second.first_launch_at == first.first_launch_at == T0
    assert second.expires_at == first.expires_at == T0 + TRIAL_LENGTH
    assert second.install_id == first.install_id
    assert second.observed_at == T0 + 3 * DAY + 5 * HOUR
    assert second.remaining == TRIAL_LENGTH - (3 * DAY + 5 * HOUR)


def test_restart_does_not_reset_the_trial(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    clock.advance(9 * DAY)

    restarted = _manager(state_dir, clock)  # brand-new manager == new process
    status = restarted.ensure_started()

    assert status.first_launch_at == T0
    assert status.observed_at == T0 + 9 * DAY
    assert status.remaining == DAY
    assert status.active, "day 9 of 10 is still active"


def test_state_payload_holds_exactly_the_documented_fields(state_dir, clock):
    _manager(state_dir, clock).ensure_started()

    payload = _payload(state_dir)
    assert set(payload) == {
        "install_id",
        "first_launch_at",
        "last_seen_at",
        "max_seen_at",
    }
    # Installation-based, not hardware-based (requirement A / D5).
    assert len(payload["install_id"]) == 36 and payload["install_id"].count("-") == 4
    for field in ("first_launch_at", "last_seen_at", "max_seen_at"):
        parsed = datetime.fromisoformat(payload[field])
        assert parsed.tzinfo is not None and parsed.utcoffset() == timedelta(0)
        assert parsed.microsecond == 0


def test_trial_days_is_configurable_and_never_below_one(state_dir, clock):
    three_days = _manager(state_dir, clock, trial_days=3).ensure_started()
    assert three_days.expires_at == T0 + 3 * DAY
    assert three_days.trial_days == 3

    with pytest.raises(ValueError, match="TRIAL_DAYS"):
        TrialManager(state_dir=state_dir, trial_days=0, store=_plain_store(state_dir))


# ── D2/T5: the 240-hour boundary ───────────────────────────────────────────


def test_trial_is_active_before_the_240_hour_boundary(state_dir, clock):
    _manager(state_dir, clock).ensure_started()

    clock.set(T0 + 239 * HOUR - SECOND)
    just_before = _manager(state_dir, clock).status()
    assert just_before is not None and just_before.active
    assert just_before.remaining == HOUR + SECOND

    clock.set(T0 + 239 * HOUR)
    one_hour_left = _manager(state_dir, clock).status()
    assert one_hour_left is not None and one_hour_left.active
    assert one_hour_left.remaining == HOUR


def test_trial_expires_at_the_240_hour_boundary(state_dir, clock):
    _manager(state_dir, clock).ensure_started()

    # §5 T5: expired only when now > expires_at — the exact boundary is
    # still inside the trial, one second after it is not.
    clock.set(T0 + TRIAL_LENGTH)
    at_boundary = _manager(state_dir, clock).status()
    assert at_boundary is not None
    assert at_boundary.expires_at == T0 + TRIAL_LENGTH
    assert at_boundary.observed_at == at_boundary.expires_at
    assert at_boundary.active and not at_boundary.expired
    assert at_boundary.remaining == timedelta(0)
    assert at_boundary.mode == "trial"

    clock.set(T0 + TRIAL_LENGTH + SECOND)
    after_boundary = _manager(state_dir, clock).status()
    assert after_boundary is not None
    assert after_boundary.expired and not after_boundary.active
    assert after_boundary.mode == "trial_expired"
    assert after_boundary.remaining == timedelta(0)


def test_trial_counts_while_the_application_is_closed(state_dir, clock):
    """D2: 240 *elapsed* hours, not 240 hours of cumulative usage."""
    _manager(state_dir, clock).ensure_started()
    clock.advance(TRIAL_LENGTH + HOUR)  # no status() calls at all in between
    status = _manager(state_dir, clock).status()
    assert status is not None and status.expired


# ── T4/R2: clock rollback ──────────────────────────────────────────────────


def test_clock_rollback_is_detected_and_clamped_forward(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    clock.set(T0 + 3 * DAY)
    observed = _manager(state_dir, clock).status()
    assert observed is not None and observed.max_seen_at == T0 + 3 * DAY

    clock.set(T0 + DAY)  # the admin winds the clock back two days
    rolled = _manager(state_dir, clock).status()
    assert rolled is not None
    assert rolled.rollback_detected is True
    # Clamped forward: licensing time never moves backwards (T4).
    assert rolled.observed_at == T0 + 3 * DAY
    assert rolled.max_seen_at == T0 + 3 * DAY
    assert rolled.expires_at == T0 + TRIAL_LENGTH
    assert rolled.active


def test_rollback_is_not_persisted_away(state_dir, clock):
    """The rollback signal survives reads: nothing is written while behind."""
    _manager(state_dir, clock).ensure_started()
    clock.set(T0 + 3 * DAY)
    _manager(state_dir, clock).status()
    high_water = _payload(state_dir)

    clock.set(T0 + DAY)
    _manager(state_dir, clock).status()
    _manager(state_dir, clock).status()

    assert _payload(state_dir) == high_water
    assert datetime.fromisoformat(high_water["max_seen_at"]) == T0 + 3 * DAY
    assert datetime.fromisoformat(high_water["last_seen_at"]) == T0 + 3 * DAY


def test_rollback_never_extends_the_trial(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    clock.set(T0 + TRIAL_LENGTH + HOUR)
    expired = _manager(state_dir, clock).status()
    assert expired is not None and expired.expired

    clock.set(T0 + DAY)  # winding back cannot resurrect an expired trial
    after = _manager(state_dir, clock).status()
    assert after is not None
    assert after.rollback_detected is True
    assert after.expired
    assert after.observed_at == T0 + TRIAL_LENGTH + HOUR


def test_forward_clock_jump_can_only_shorten_the_trial(state_dir, clock):
    """Documented limitation: a clock that runs ahead is never trusted back."""
    _manager(state_dir, clock).ensure_started()
    clock.set(T0 + 20 * DAY)  # bogus year-ahead jump
    jumped = _manager(state_dir, clock).status()
    assert jumped is not None and jumped.expired
    assert jumped.max_seen_at == T0 + 20 * DAY

    clock.set(T0 + 2 * DAY)  # owner notices and corrects the clock
    corrected = _manager(state_dir, clock).status()
    assert corrected is not None
    assert corrected.expired, "the jump is permanent — fail-closed, never extended"
    assert corrected.observed_at == T0 + 20 * DAY


def test_max_seen_at_is_persisted_for_advancing_observations(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    clock.set(T0 + 30 * SECOND)
    _manager(state_dir, clock).status()

    payload = _payload(state_dir)
    assert datetime.fromisoformat(payload["max_seen_at"]) == T0 + 30 * SECOND
    assert datetime.fromisoformat(payload["last_seen_at"]) == T0 + 30 * SECOND
    assert datetime.fromisoformat(payload["first_launch_at"]) == T0


# ── missing ≠ corrupt, both fail closed ────────────────────────────────────


def test_missing_state_is_not_an_error(state_dir, clock):
    manager = _manager(state_dir, clock)
    assert manager.status() is None, "missing means 'no trial', not 'corrupt'"
    assert not manager.state_path.exists()

    started = manager.ensure_started()
    assert manager.status() is not None
    assert started.install_id == manager.status().install_id


def test_corrupt_envelope_fails_closed(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    path = _manager(state_dir, clock).state_path
    original = path.read_bytes()

    corruptions = {
        "empty file": b"",
        "not json": b"definitely not json",
        "truncated json": original[: len(original) // 2],
        "json list": b"[]",
        "unknown envelope version": json.dumps(
            {**_envelope(state_dir), "v": 99}
        ).encode("utf-8"),
        "tampered payload": json.dumps(
            {**_envelope(state_dir), "data": base64.b64encode(b'{"v":1}').decode("ascii")}
        ).encode("utf-8"),
        "tampered mac": json.dumps(
            {**_envelope(state_dir), "mac": "00" * 32}
        ).encode("utf-8"),
    }
    reader = _manager(state_dir, clock)
    for label, blob in corruptions.items():
        path.write_bytes(blob)
        with pytest.raises(StateFileCorruptedError):
            reader.status()
        assert path.read_bytes() == blob, label

    path.write_bytes(original)
    assert reader.status() is not None, "the untouched file still verifies"


@pytest.mark.parametrize(
    "payload",
    [
        {"first_launch_at": "soon", "last_seen_at": "x", "max_seen_at": "y",
         "install_id": "not-a-uuid"},
        {"first_launch_at": "2026-03-01T08:00:00", "last_seen_at": "2026-03-01T08:00:00",
         "max_seen_at": "2026-03-01T08:00:00", "install_id":
         "6f9619ff-8b86-d011-b42d-00cf4fc964ff"},
        {"first_launch_at": "2026-03-01T08:00:00+00:00",
         "last_seen_at": "2026-03-01T07:00:00+00:00",
         "max_seen_at": "2026-03-01T07:00:00+00:00",
         "install_id": "6f9619ff-8b86-d011-b42d-00cf4fc964ff"},
        {"first_launch_at": "2026-03-01T08:00:00+00:00",
         "last_seen_at": "2026-03-02T08:00:00+00:00",
         "max_seen_at": "2026-03-01T09:00:00+00:00",
         "install_id": "6f9619ff-8b86-d011-b42d-00cf4fc964ff"},
        {"first_launch_at": "2026-03-01T08:00:00+00:00",
         "max_seen_at": "2026-03-01T08:00:00+00:00",
         "install_id": "6f9619ff-8b86-d011-b42d-00cf4fc964ff"},
    ],
    ids=["garbage", "naive-timestamp", "last-before-first", "max-before-last",
         "missing-field"],
)
def test_invalid_payload_fails_closed(state_dir, clock, payload):
    """A syntactically valid file with impossible content is still corrupt."""
    store = _plain_store(state_dir)
    store.write(STATE_NAME, payload)
    with pytest.raises(StateFileCorruptedError):
        TrialManager(state_dir=state_dir, store=store, clock=clock).status()


def test_unreadable_state_is_not_silently_restarted(state_dir, clock):
    """Never silently restart or extend a trial after invalid state (§4)."""
    store = _plain_store(state_dir)
    store.write(STATE_NAME, {"nonsense": True})
    manager = TrialManager(state_dir=state_dir, store=store, clock=clock)

    with pytest.raises(StateFileCorruptedError):
        manager.ensure_started()
    assert _payload(state_dir) == {"nonsense": True}, "the bad file is left as-is"


# ── D: trial state is structurally outside PostgreSQL ──────────────────────


def test_trial_state_is_outside_the_database(state_dir, clock):
    _manager(state_dir, clock).ensure_started()
    trial_file = state_dir / f"{STATE_NAME}.state"
    assert trial_file.is_file()

    # 1. Nothing licensing-related is mapped into the ORM, so `pg_dump`
    #    cannot carry it. (conftest imports app.main, which registers every
    #    model on Base.metadata before any test runs.)
    offending = [
        name
        for name in list(Base.metadata.tables)
        + [
            f"{table.name}.{column.name}"
            for table in Base.metadata.tables.values()
            for column in table.columns
        ]
        if "trial" in name.lower() or "license" in name.lower()
    ]
    assert offending == []

    # 2. The state directory is a plain directory, distinct from the
    #    database URL and from the backup catalogue.
    state_root = Path(settings.LICENSE_STATE_DIR)
    state_root.mkdir(parents=True, exist_ok=True)  # created by the 1st start
    assert state_root.is_dir()
    assert "postgresql" not in str(state_root).lower()
    assert state_root != Path(settings.BACKUP_DIR)
    assert state_root.name == "license" and state_root.parent.name == "data"

    # 3. Structural independence: the backup service never references
    #    licensing *state*, and the trial engine never references the DB.
    #    Phase L1-D lets the service consult the shared §4.4 policy —
    #    a pure decision table that reads the state through TrialManager —
    #    so the import itself is allowed, but no state path, store or
    #    fingerprint may appear in the backup code.
    backup_source = Path(backup_service.__file__).read_text(encoding="utf-8")
    assert "LICENSE_STATE_DIR" not in backup_source
    for token in ("StateStore", "TrialManager", "STATE_NAME", "install_id"):
        assert token not in backup_source, token
    licensing_imports = [
        line.strip()
        for line in backup_source.splitlines()
        if "app.licensing" in line
    ]
    assert licensing_imports, "L1-D: the service must consult the policy"
    assert all("backup_policy" in line for line in licensing_imports), (
        "the backup service may only import app.licensing.backup_policy "
        f"(the §4.4 decision table), got: {licensing_imports}"
    )
    trial_source = Path(trial_module.__file__).read_text(encoding="utf-8")
    assert "sqlalchemy" not in trial_source.lower()
    assert "app.db" not in trial_source

    # 4. Tearing down and rebuilding every table leaves the trial intact.
    before = trial_file.read_bytes()
    engine = create_engine("sqlite://")
    try:
        Base.metadata.drop_all(bind=engine)
        Base.metadata.create_all(bind=engine)
    finally:
        engine.dispose()
    assert trial_file.read_bytes() == before
    assert _manager(state_dir, clock).status() is not None


# ── platform protection (L0 store, exercised through the trial) ────────────


@pytest.mark.skipif(not dpapi_available(), reason="DPAPI is Windows-only")
def test_trial_state_is_dpapi_sealed_on_windows(tmp_path: Path, clock):
    manager = TrialManager(state_dir=tmp_path, clock=clock)  # platform default
    manager.ensure_started()

    raw = manager.state_path.read_bytes()
    assert _envelope(tmp_path)["protection"] == "dpapi"
    assert b"first_launch_at" not in raw and b"install_id" not in raw

    status = manager.status()
    assert isinstance(status, TrialStatus)
    assert status.first_launch_at == T0


def test_manager_reads_the_configured_state_dir_by_default(state_dir, clock, monkeypatch):
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(state_dir))
    manager = TrialManager.from_settings(clock=clock)
    assert manager.state_dir == state_dir
    manager.ensure_started()
    assert manager.status() is not None


def test_state_store_errors_are_the_fail_closed_signal(state_dir, clock):
    """Any store failure is a StateStoreError the guard converts to 503."""
    store = _plain_store(state_dir)
    store.write(
        STATE_NAME,
        {
            "first_launch_at": "2026-03-01T08:00:00+00:00",
            "last_seen_at": "2026-03-01T08:00:00+00:00",
            "max_seen_at": "2026-03-01T08:00:00+00:00",
            "install_id": "6f9619ff-8b86-d011-b42d-00cf4fc964ff",
        },
    )

    # The integrity key itself is tampered with; the guard builds a fresh
    # manager per request, so the next read must fail closed.
    (state_dir / "hmac.key").write_bytes(b"!!!not base64!!!")
    restarted = TrialManager(state_dir=state_dir, store=_plain_store(state_dir), clock=clock)
    with pytest.raises(StateStoreError):
        restarted.status()
