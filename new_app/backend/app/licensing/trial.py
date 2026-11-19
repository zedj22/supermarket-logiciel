"""Free Trial engine — Phase L1 of the licensing system.

Runs the approved **10 calendar days / 240 elapsed hours** offline trial
(decision D2) on top of the Phase L0 :class:`StateStore`.

State lives in ``<LICENSE_STATE_DIR>/trial.state`` — deliberately **outside
PostgreSQL** (§4.2) — and holds exactly the four fields of §4.2 / §5 T1::

    {"install_id", "first_launch_at", "last_seen_at", "max_seen_at"}

Lifecycle (§5):

* **Start (D5/T1)** — the first backend start that finds no state file
  creates it (`ensure_started`, called from the app lifespan). Later starts
  never re-create or shift it: the trial counts while the application is
  closed, and a restart never resets it.
* **Evaluate** — `status()` returns the current observation, or ``None``
  when no trial has ever been started.  *Missing is not corrupt*: absence
  means "no trial installed", a file that cannot be trusted raises
  :class:`StateFileCorruptedError`.
* **Expire (D2/T5)** — ``expires_at = first_launch_at + trial_days``; the
  trial is expired strictly *after* that instant (``observed_at >
  expires_at``), i.e. 240 h after the first backend start.
* **Clock rollback (T4/R2)** — ``observed_at = max(wall clock,
  max_seen_at)`` with ``max_seen_at`` persisted on every observation that
  advances it, so moving the clock backwards can never extend the trial;
  the attempt is reported as ``rollback_detected``.
* **Fail closed** — a state file that exists but cannot be verified (bad
  HMAC, truncated/rewritten envelope, out-of-order timestamps, garbage)
  raises :class:`StateFileCorruptedError`.  Callers must treat that as "no
  usable trial" and refuse service — never as an active trial, and never
  by silently restarting it.

Clock policy
------------
The wall clock is injected (``clock=``) so the whole lifecycle is testable
without sleeping (§13.3).  Timestamps are stored at second precision in UTC
(``…+00:00``), which also caps persistence at **one write per second** —
``max_seen_at`` is only written when it actually advances.

Honest limitations (§4.4 / §9)
------------------------------
This is an offline trial: no server, no internet, no trusted timestamp.  A
local Windows administrator can delete ``trial.state`` (allowed by policy
R3 — that is what reinstalling means), edit and re-seal files with DPAPI,
or patch the backend.  DPAPI + HMAC + the monotonic ``max_seen_at`` guard
raise the cost above casual editing; they do **not** make the trial
tamper-proof, and no claim is made to the contrary.  A clock that is
*ahead* of reality shortens the trial (fail-closed) and is recorded
permanently — an unverifiable timestamp never extends a trial.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.core.config import settings
from app.licensing.state_store import StateFileCorruptedError, StateStore

__all__ = [
    "STATE_NAME",
    "TrialManager",
    "TrialStatus",
]

#: Envelope name inside ``LICENSE_STATE_DIR`` → ``trial.state``.
STATE_NAME = "trial"

UTC = timezone.utc

#: Injectable clock: anything returning "the current time".
Clock = Callable[[], datetime]


def _as_utc(moment: datetime) -> datetime:
    """Normalise to an aware UTC datetime (naive input is read as UTC)."""
    if moment.tzinfo is None:
        return moment.replace(tzinfo=UTC)
    return moment.astimezone(UTC)


def _utc_now() -> datetime:
    return _as_utc(datetime.now(timezone.utc))


def _stamp(moment: datetime) -> str:
    """Second-precision UTC ISO-8601 with ``+00:00`` (never ``Z``)."""
    return _as_utc(moment).replace(microsecond=0).isoformat()


def _parse_stamp(value: object, field: str) -> datetime:
    """Parse a stored timestamp, fail-closed on anything unexpected."""
    if not isinstance(value, str):
        raise StateFileCorruptedError(f"{STATE_NAME}: {field} is missing or not a string")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as exc:
        raise StateFileCorruptedError(
            f"{STATE_NAME}: {field} is not an ISO-8601 timestamp"
        ) from exc
    if parsed.tzinfo is None:
        raise StateFileCorruptedError(f"{STATE_NAME}: {field} is timezone-naive")
    return parsed.astimezone(UTC)


@dataclass(frozen=True, slots=True)
class TrialStatus:
    """One observation of the trial clock (all times are UTC)."""

    install_id: str
    first_launch_at: datetime
    expires_at: datetime
    observed_at: datetime
    last_seen_at: datetime
    max_seen_at: datetime
    trial_days: int
    rollback_detected: bool = False

    @property
    def active(self) -> bool:
        """§5 T5: expired only when ``observed_at > expires_at``."""
        return self.observed_at <= self.expires_at

    @property
    def expired(self) -> bool:
        return not self.active

    @property
    def mode(self) -> str:
        """``mode`` as used by §5 (T2 ``trial``, T5 ``trial_expired``)."""
        return "trial" if self.active else "trial_expired"

    @property
    def remaining(self) -> timedelta:
        left = self.expires_at - self.observed_at
        return left if left > timedelta(0) else timedelta(0)


class TrialManager:
    """Read/write and evaluate one installation's trial.

    Parameters
    ----------
    state_dir:
        Directory holding ``trial.state`` (defaults to
        ``settings.LICENSE_STATE_DIR``).  Deliberately a plain directory:
        no part of this state can ride along in a `pg_dump` (§4.2).
    trial_days:
        Trial length in calendar days (defaults to ``settings.TRIAL_DAYS``;
        the approved value is 10 → 240 elapsed hours, D2).
    store:
        Explicit :class:`StateStore` (tests use ``use_dpapi=False`` to keep
        envelopes inspectable).  When omitted one is built from `state_dir`
        with the platform default protection.
    clock:
        Injectable "now" (defaults to the real UTC clock).

    Every method can raise the L0 :class:`StateStoreError` family; callers
    must treat those as *fail-closed*, never as an active trial.
    """

    def __init__(
        self,
        state_dir: str | Path | None = None,
        *,
        trial_days: int | None = None,
        store: StateStore | None = None,
        clock: Clock | None = None,
    ) -> None:
        if store is None:
            root = Path(state_dir if state_dir is not None else settings.LICENSE_STATE_DIR)
            if str(root) in ("", "."):
                raise ValueError("license state directory must be a real path")
            store = StateStore(root)
        self._store = store
        if trial_days is None:
            trial_days = settings.TRIAL_DAYS
        if trial_days < 1:
            raise ValueError("TRIAL_DAYS must be at least 1 day")
        self.trial_days = int(trial_days)
        self._clock: Clock = clock or _utc_now

    @classmethod
    def from_settings(cls, *, clock: Clock | None = None) -> TrialManager:
        """Manager bound to the configured state dir and trial length."""
        return cls(
            state_dir=settings.LICENSE_STATE_DIR,
            trial_days=settings.TRIAL_DAYS,
            clock=clock,
        )

    # ------------------------------------------------------------------
    # paths / time
    # ------------------------------------------------------------------
    @property
    def state_path(self) -> Path:
        """Absolute path of this installation's ``trial.state``."""
        return self._store.path_for(STATE_NAME)

    @property
    def state_dir(self) -> Path:
        return self._store.root

    def now(self) -> datetime:
        """Current wall clock, normalised to second-precision UTC."""
        return _as_utc(self._clock()).replace(microsecond=0)

    # ------------------------------------------------------------------
    # lifecycle (§5)
    # ------------------------------------------------------------------
    def status(self) -> TrialStatus | None:
        """Current observation, ``None`` when no trial exists yet.

        Raises :class:`StateFileCorruptedError` when the file exists but
        cannot be trusted (missing ≠ corrupt — see module docstring).
        """
        payload = self._store.read(STATE_NAME)
        if payload is None:
            return None
        return self._observe(payload)

    def ensure_started(self) -> TrialStatus:
        """Start the trial once, on the first backend start (D5/T1).

        Idempotent: an existing trial is never re-created, shortened or
        shifted, whatever the clock says now.
        """
        payload = self._store.read(STATE_NAME)
        if payload is None:
            return self._create()
        return self._observe(payload)

    # ------------------------------------------------------------------
    # internals
    # ------------------------------------------------------------------
    def _create(self) -> TrialStatus:
        wall = self.now()
        stamp = _stamp(wall)
        payload = {
            "install_id": str(uuid.uuid4()),
            "first_launch_at": stamp,
            "last_seen_at": stamp,
            "max_seen_at": stamp,
        }
        self._store.write(STATE_NAME, payload)
        expires_at = wall + timedelta(days=self.trial_days)
        return TrialStatus(
            install_id=payload["install_id"],
            first_launch_at=wall,
            expires_at=expires_at,
            observed_at=wall,
            last_seen_at=wall,
            max_seen_at=wall,
            trial_days=self.trial_days,
        )

    def _observe(self, payload: object) -> TrialStatus:
        install_id, first, last_seen, max_seen = self._validate(payload)

        wall = self.now()
        # §5 T4: the clock can never move time backwards for licensing.
        rollback_detected = wall < last_seen
        observed_at = max(wall, max_seen)

        if observed_at > max_seen:
            # The monotonic mark advanced → persist it. Timestamps are
            # second-precision, so this is at most one atomic write/second
            # and never happens while the clock is rolled back.
            self._store.write(
                STATE_NAME,
                {
                    "install_id": install_id,
                    "first_launch_at": _stamp(first),
                    "last_seen_at": _stamp(wall),
                    "max_seen_at": _stamp(observed_at),
                },
            )
            last_seen = wall
            max_seen = observed_at

        return TrialStatus(
            install_id=install_id,
            first_launch_at=first,
            expires_at=first + timedelta(days=self.trial_days),
            observed_at=observed_at,
            last_seen_at=last_seen,
            max_seen_at=max_seen,
            trial_days=self.trial_days,
            rollback_detected=rollback_detected,
        )

    @staticmethod
    def _validate(payload: object) -> tuple[str, datetime, datetime, datetime]:
        """Structural + semantic check of a stored payload (fail-closed)."""
        if not isinstance(payload, dict):
            raise StateFileCorruptedError(f"{STATE_NAME}: payload is not an object")

        install_id = payload.get("install_id")
        if not isinstance(install_id, str):
            raise StateFileCorruptedError(f"{STATE_NAME}: install_id is missing or not a string")
        try:
            uuid.UUID(install_id)
        except ValueError as exc:
            raise StateFileCorruptedError(f"{STATE_NAME}: install_id is not a UUID") from exc

        first = _parse_stamp(payload.get("first_launch_at"), "first_launch_at")
        last = _parse_stamp(payload.get("last_seen_at"), "last_seen_at")
        max_seen = _parse_stamp(payload.get("max_seen_at"), "max_seen_at")

        # Order is an integrity property of our own writes: a trial can
        # never start after it was last seen, and time never goes back.
        if not first <= last <= max_seen:
            raise StateFileCorruptedError(
                f"{STATE_NAME}: timestamps out of order "
                f"(first_launch_at <= last_seen_at <= max_seen_at)"
            )
        return install_id, first, last, max_seen
