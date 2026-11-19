"""Combined licensing authorization — Phase L2-B, §12.

One server-side answer to "may this backend serve business requests
right now?" for ``LICENSE_ENFORCEMENT=on``, computed fresh from this
server's own state on every call:

* a **valid Lifetime license** authorizes every business operation —
  signature and current-hardware binding re-verified by
  `LicenseManager.status()` on this very read — whatever the trial says
  (an expired or even corrupt trial state cannot demote it);
* without one, an **active Free Trial** authorizes exactly as Phase L1;
* otherwise the operation is refused with the typed licensing error
  (403 ``trial_expired`` / 403 ``license_required`` / 503
  ``license_status_unavailable``).

Rules pinned by the approved L2-B policy:

* ``LICENSE_ENFORCEMENT=off`` (the shipped default) performs **no state
  reads at all**: the decision is a complete no-op, like the guard.
* Enforcement ``trial`` keeps the frozen Phase L1 semantics: the
  Lifetime license is never consulted unless enforcement is ``on``
  (that path stays where it already lives, in `guard` /
  `backup_policy`).
* A missing, corrupt, unverifiable, key-less or hardware-mismatched
  license is **not** a valid license and never becomes one by existing;
  a license-side failure alone can never invalidate an active trial —
  it degrades to "no license" and the trial answers.
* Nothing here writes: no ``ensure_started()``, no trial or license
  mutation, no cached status, no client claim — read-only observation,
  and never a ``/system/info`` round trip.

Deliberately does **not** import `backup_policy`: that module consumes
this decision through :func:`app.licensing.backup_policy.apply_backup_decision`,
so the dependency points one way and no import cycle exists.  The seam
for tests is :func:`_license_manager` — nothing else may reach into the
decision.

``settings.LICENSE_ENFORCEMENT`` is a validated ``Literal`` with exactly
three values (startup rejects anything else), so the branches below
cover the whole configuration space.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from app.core.config import settings
from app.core.exceptions import AppError
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
)
from app.licensing.license_manager import LicenseManager, LicenseStatus
from app.licensing.state_store import StateStoreError
from app.licensing.trial import TrialManager, TrialStatus

__all__ = [
    "AuthorizationDecision",
    "Outcome",
    "decide_licensing",
]

#: What one authorization pass concluded (L2-B §12).
Outcome = Literal[
    "disabled",
    "lifetime",
    "trial_active",
    "trial_expired",
    "trial_missing",
    "trial_unavailable",
]

#: Outcomes that refuse *every* non-allowlisted business request.
_DENYING_OUTCOMES = frozenset(
    {"trial_expired", "trial_missing", "trial_unavailable"}
)


@dataclass(frozen=True, slots=True)
class AuthorizationDecision:
    """One read-only observation of this backend's licensing state.

    ``trial`` is ``None`` whenever it was not read (enforcement ``off``,
    or a valid Lifetime license answered first); ``lifetime`` is ``None``
    whenever no *valid* license was observed — a record that exists but
    fails re-verification simply is not a license.
    """

    enforcement: str
    outcome: Outcome
    trial: TrialStatus | None = None
    lifetime: LicenseStatus | None = None

    @property
    def authorized(self) -> bool:
        """True when business requests may proceed (§4 policy)."""
        return self.outcome in ("disabled", "lifetime", "trial_active")

    @property
    def license_mode(self) -> str | None:
        """``mode`` for the §4.4 backup matrix, ``None`` when there is none.

        ``trial_active`` maps to the existing ``trial`` row so the
        approved matrix needs no new data — Phase L2-B only has to
        *produce* ``lifetime``.
        """
        if self.outcome == "lifetime":
            return "lifetime"
        if self.outcome == "trial_active":
            return "trial"
        if self.outcome == "trial_expired":
            return "trial_expired"
        return None

    def denial_error(self) -> AppError | None:
        """The typed refusal for this outcome, or ``None`` when allowed.

        ``lifetime`` and ``trial_active`` never refuse here (backup rows
        are applied separately on top of an active trial); ``disabled``
        refuses nothing because it decided nothing.
        """
        if self.outcome == "trial_expired":
            expires_at = self.trial.expires_at if self.trial is not None else None
            when = f" at {expires_at.isoformat()}" if expires_at else ""
            return TrialExpiredError(f"the free trial expired{when}")
        if self.outcome == "trial_missing":
            return LicenseRequiredError(
                "no lifetime license and no trial are installed on this backend"
            )
        if self.outcome == "trial_unavailable":
            return LicenseStatusUnavailableError(
                "license and trial state could not be verified on this backend"
            )
        return None

    @property
    def denies_business(self) -> bool:
        """True for the outcomes that close every non-backup business route."""
        return self.outcome in _DENYING_OUTCOMES


def _license_manager() -> LicenseManager:
    """The one `LicenseManager` factory (also the tests' seam).

    Built fresh per decision — no shared cache, no re-used status: every
    pass re-reads ``license.state`` and re-verifies signature + hardware
    binding through `LicenseManager.status()`.
    """
    return LicenseManager.from_settings()


def _lifetime_observation() -> LicenseStatus | None:
    """Verified Lifetime status, or ``None`` when there is no valid one.

    Any license-side failure — record corrupt, signature/key problem,
    hardware mismatch, unreadable key file or state directory, missing
    hardware identifier — means the same thing: *no license*.  It is
    never fatal on its own (it must not demote an active trial) and it
    is never "valid" (a present-but-broken file is not a license).
    """
    try:
        return _license_manager().status()
    except (AppError, StateStoreError, OSError, ValueError):
        return None


def _trial_observation() -> tuple[TrialStatus | None, bool]:
    """``(status, unreadable)`` — ``None`` means no trial is installed.

    The boolean distinguishes *missing* (a reinstall may start a new
    trial on the next start) from *unreadable/tampered* ("cannot tell"),
    which the decision answers with the 503 fail-closed error.  A missing
    file is never created here and an unreadable one is never repaired.
    """
    try:
        return TrialManager.from_settings().status(), False
    except (StateStoreError, OSError, ValueError):
        return None, True


def decide_licensing() -> AuthorizationDecision:
    """The single authorization pass (Phase L2-B §4).

    Order is part of the policy: enforcement ``off`` short-circuits with
    **zero reads**; under ``on`` the Lifetime license is consulted
    *first*, so a valid license authorizes without even looking at the
    trial (a corrupt trial cannot demote it, and the trial's monotonic
    clock is not advanced by a licensed install).  Only when no valid
    license was found does the trial observation answer.
    """
    enforcement = settings.LICENSE_ENFORCEMENT
    if enforcement == "off":
        return AuthorizationDecision(enforcement=enforcement, outcome="disabled")

    if enforcement == "on":
        lifetime = _lifetime_observation()
        if lifetime is not None:
            return AuthorizationDecision(
                enforcement=enforcement,
                outcome="lifetime",
                lifetime=lifetime,
            )

    # No valid license (or enforcement `trial`, where a Lifetime license
    # is never consulted): the Free Trial answers, frozen L1 semantics.
    trial, unreadable = _trial_observation()
    if unreadable:
        outcome: Outcome = "trial_unavailable"
    elif trial is None:
        outcome = "trial_missing"
    elif trial.active:
        outcome = "trial_active"
    else:
        outcome = "trial_expired"
    return AuthorizationDecision(
        enforcement=enforcement,
        outcome=outcome,
        trial=trial,
    )
