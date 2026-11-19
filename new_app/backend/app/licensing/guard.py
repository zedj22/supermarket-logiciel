"""Router-level license guard — Phase L0 foundation, Phase L1 + L2-B.

Mounted as a router-level dependency on ``api_router`` (after the device
guard, so pairing errors are never masked by licensing ones) and, like
the device guard, applied to every ``/api/v1`` route including ones added
later.

Modes of ``LICENSE_ENFORCEMENT`` (read per call):

* ``off`` (the shipped default) — a **complete no-op**: no request is
  altered, no file is read, no error is produced (L0 exit criterion).
* ``trial`` (Phase L1) — the Free Trial engine answers the question:
  - allowlisted paths pass (bootstrap surface);
  - trial **active** → business routes behave exactly as before, except
    ``POST /backups/upload`` (``403 trial_upload_forbidden``, D6) and
    ``POST /backups/{id}/restore`` (``403 trial_restore_forbidden``, §8);
  - trial **expired** → business routes and backup creation return
    ``403 trial_expired``, while backup **listing and download** stay
    reachable as read-only data rescue (D3);
  - state **missing** → ``403 license_required``; state **unverifiable**
    → ``503 license_status_unavailable``.  Neither is ever answered "yes".
  A Lifetime license is never consulted in this mode (frozen L1).
* ``on`` (Phase L2-B) — the combined decision of
  :mod:`app.licensing.authorization` answers:
  - a **valid Lifetime license** (signature + hardware re-verified on
    this pass) allows every business route, whatever the trial says;
  - otherwise an **active trial** behaves exactly like ``trial`` mode
    (same backup rows, same typed refusals);
  - without a license, an **expired** trial → ``403 trial_expired``
    (backup listing/download still reachable, D3), **missing** state →
    ``403 license_required``, **unverifiable** state → ``503
    license_status_unavailable``.  Never fail open on a licensing question.

Deliberately different from the device guard: there is **no loopback
 exemption** and no ``LAN_MODE`` gating — licensing applies to the local
POS on the server PC exactly as to a remote till (owner Q6 covers the
device guard only), and it is governed solely by ``LICENSE_ENFORCEMENT``.
A Main PC with an active trial therefore serves paired LAN clients (D1),
and once it expires the same server-side check blocks them too.
"""

from __future__ import annotations

from fastapi import Request

from app.core.config import settings
from app.licensing.authorization import decide_licensing
from app.licensing.backup_policy import (
    apply_backup_decision,
    backup_action_allowed,
    backup_denied_error,
    classify_backup_action,
    current_trial_status,
)
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
)
from app.licensing.trial import TrialStatus

__all__ = ["ALLOW_PATHS", "is_allowlisted", "license_guard"]

#: The surface that must stay reachable before any license state exists.
#: Mirrors the device-guard allowlist plus `/license` — an unlicensed
#: install has to be able to *reach* the activation endpoints.
ALLOW_PATHS = (
    "/api/v1/health",
    "/api/v1/system/info",
    "/api/v1/auth",
    "/api/v1/devices",
    "/api/v1/license",
)


def is_allowlisted(path: str) -> bool:
    """True for the bootstrap surface, where no license exists yet."""
    for prefix in ALLOW_PATHS:
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def _backup_action(method: str, path: str) -> str | None:
    """Classify a request against the §4.4 backup rows, ``None`` if not one.

    Thin alias of the shared classifier (Phase L1-D): the router guard and
    ``BackupService`` must classify the same URL space the same way.
    """
    return classify_backup_action(method, path)


def _trial_status() -> TrialStatus | None:
    """Current trial observation from ``LICENSE_STATE_DIR`` (fail-closed).

    Delegates to the shared reader so this guard and ``BackupService``
    observe one state file one way: unreadable/tampered/unsealed state is
    "cannot tell" ≠ "licensed" (503 ``license_status_unavailable``).
    """
    return current_trial_status()


def _enforce_trial(request: Request) -> None:
    """Apply §4.4 matrix rows for ``LICENSE_ENFORCEMENT=trial`` (Phase L1)."""
    status = _trial_status()
    if status is None:
        # Missing state is not corrupt state: it means no trial exists
        # (startup could not create one, or the file was removed — R3 lets
        # a reinstall start a new trial on the NEXT backend start).
        raise LicenseRequiredError("no trial is installed on this backend")

    action = _backup_action(request.method, request.url.path)
    if action is not None:
        # Backup rows are answered by the shared policy (Phase L1-D), so
        # the router guard and BackupService can never disagree — and a
        # direct service call cannot bypass what the guard would refuse.
        if backup_action_allowed(action, mode=status.mode):
            return
        raise backup_denied_error(
            action, mode=status.mode, expires_at=status.expires_at
        )

    if status.active:
        return
    # Expired: every non-backup business route is closed.  Backup listing
    # and download stay reachable above (D3, read-only data rescue).
    raise TrialExpiredError(
        f"the free trial expired at {status.expires_at.isoformat()}"
    )


def _enforce_on(request: Request) -> None:
    """Combined Lifetime / Free-Trial enforcement (Phase L2-B, §12).

    One decision per request: the Lifetime license is re-verified first,
    the trial answers only when no valid license exists, and backup rows
    go through the shared matrix application so this layer and
    ``BackupService`` cannot disagree.
    """
    decision = decide_licensing()

    action = _backup_action(request.method, request.url.path)
    if action is not None:
        apply_backup_decision(action, decision)
        return

    refusal = decision.denial_error()
    if refusal is not None:
        raise refusal
    # `disabled` (impossible here), `lifetime` or `trial_active` → pass.


async def license_guard(request: Request) -> None:
    """Licensing dependency; a complete no-op while enforcement is disabled.

    Reads ``LICENSE_ENFORCEMENT`` per call so configuration changes are
    picked up without rebuilding the app (and tests can flip it safely).
    """
    enforcement = settings.LICENSE_ENFORCEMENT
    if enforcement == "off":
        # Phase L0/L1 default: untouched request, no state read, no error.
        return
    if is_allowlisted(request.url.path):
        return
    if enforcement == "trial":
        _enforce_trial(request)
        return
    if enforcement == "on":
        _enforce_on(request)
        return
    # Unreachable with the validated Literal — fail closed, never open.
    raise LicenseStatusUnavailableError(
        f"license enforcement {enforcement!r} is not a recognized mode"
    )
