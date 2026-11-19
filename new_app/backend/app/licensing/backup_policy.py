"""Backup action policy — Phase L1-D, §4.4 matrix as shared *data*.

Two enforcement layers must agree on one answer for every backup
operation, so the answer lives here instead of being written twice:

* the **router guard** (``app.licensing.guard``) classifies the incoming
  request path/method with :func:`classify_backup_action` and refuses it
  before authentication is even considered;
* **``BackupService``** calls :func:`require_backup_action` at the top of
  every public method, so a direct internal service call — a future
  endpoint, a script, a test — cannot bypass what the guard would refuse.

Nothing here trusts the client: the mode comes from
:class:`app.licensing.trial.TrialManager` reading ``trial.state`` on the
server, never from a Flutter-provided status or a request header.

Action matrix (rows = license mode, columns = backup action)::

    action        create  list  download  upload  restore  inspect
    --------------------------------------------------------------
    trial            ✓      ✓      ✓        ✗       ✗        ✓
    trial_expired    ✗      ✓      ✓        ✗       ✗        ✗
    lifetime         ✓      ✓      ✓        ✓       ✓        ✓

``trial_expired`` keeps **list + download** so an operator whose trial has
elapsed can still rescue the data already on the server (D3), while
``create``/``upload``/``restore`` — everything that writes — stays closed.
``lifetime`` is produced by Phase L2-B's combined decision: a valid
Lifetime license unlocks every row, no service, route or test had to be
redesigned to accept it.

Modes of ``LICENSE_ENFORCEMENT`` (read per call, like the guard):

* ``off`` — :func:`require_backup_action` is a complete no-op: no state is
  read, no decision is taken (L0 exit criterion, unchanged).
* ``trial`` — the matrix above answers, fail-closed (frozen Phase L1;
  a Lifetime license is never consulted in this mode).
* ``on`` — Phase L2-B: the combined decision of
  :mod:`app.licensing.authorization` picks ``lifetime``, ``trial`` or
  ``trial_expired`` and the same matrix answers.  Missing state ⇒ 403
  ``license_required``, unverifiable state ⇒ 503
  ``license_status_unavailable``.  Never fail open on a licensing question.
"""

from __future__ import annotations

import re
from datetime import datetime

from app.core.config import settings
from app.core.exceptions import AppError
from app.licensing.authorization import AuthorizationDecision, decide_licensing
from app.licensing.errors import (
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialRestoreForbiddenError,
    TrialUploadForbiddenError,
)
from app.licensing.state_store import StateStoreError
from app.licensing.trial import TrialManager, TrialStatus

__all__ = [
    "BACKUP_ACTIONS",
    "LICENSE_BACKUP_GRANTS",
    "apply_backup_decision",
    "backup_action_allowed",
    "backup_denied_error",
    "classify_backup_action",
    "current_trial_status",
    "require_backup_action",
]

#: Every backup operation the service exposes, as classified by
#: :func:`classify_backup_action`.  Anything not in this set is not a
#: backup operation (and therefore never "allowed by the backup matrix").
BACKUP_ACTIONS = frozenset(
    {"create", "list", "download", "upload", "restore", "inspect"}
)

#: Which backup actions each license mode grants (§4.4).  A mode missing
#: here grants nothing — an unknown mode must never read as "licensed".
LICENSE_BACKUP_GRANTS: dict[str, frozenset[str]] = {
    # Active trial: keep create/download (export stays available, D6) but
    # refuse the two operations that would write an archive into this
    # install (upload, restore).
    "trial": frozenset({"create", "list", "download", "inspect"}),
    # Expired: read-only data rescue only (D3) — list and download stay up.
    "trial_expired": frozenset({"list", "download"}),
    # Phase L2-B: a valid Lifetime license unlocks everything — this row
    # is what the combined decision produces for a licensed install.
    "lifetime": BACKUP_ACTIONS,
}

#: The backup routes classified against the §4.4 rows.  Mirrors the URL
#: space of ``api/v1/backups`` (router prefix ``/backups`` under
#: ``/api/v1``); ``{backup_id}`` is any non-empty segment, exactly like
#: the ``Path(ge=1)`` parameter the route itself declares.
_BACKUPS = "/api/v1/backups"
_DOWNLOAD_RE = re.compile(rf"{_BACKUPS}/[^/]+/download")
_INSPECT_RE = re.compile(rf"{_BACKUPS}/[^/]+/inspect")
_RESTORE_RE = re.compile(rf"{_BACKUPS}/[^/]+/restore")
_UPLOAD = f"{_BACKUPS}/upload"


def classify_backup_action(method: str, path: str) -> str | None:
    """Classify a request path/method as one backup action, else ``None``.

    Every route of the backups router maps to exactly one action, so a
    typo'd or unknown path falls through to ``None`` — the guard then
    treats it as a non-backup request (ordinary expired-trial rule) and
    the service never accepts it as a granted action either.
    """
    method = method.upper()
    if path == _BACKUPS:
        if method == "POST":
            return "create"
        if method == "GET":
            return "list"
        return None
    if not path.startswith(_BACKUPS + "/"):
        return None
    if method == "POST" and path == _UPLOAD:
        return "upload"
    if method == "POST" and _RESTORE_RE.fullmatch(path):
        return "restore"
    if method == "GET" and _DOWNLOAD_RE.fullmatch(path):
        return "download"
    if method == "GET" and _INSPECT_RE.fullmatch(path):
        return "inspect"
    return None


def backup_action_allowed(action: str, *, mode: str) -> bool:
    """True when [mode] grants [action]; an unknown mode grants nothing."""
    return action in LICENSE_BACKUP_GRANTS.get(mode, frozenset())


def backup_denied_error(
    action: str,
    *,
    mode: str,
    expires_at: datetime | None = None,
) -> AppError:
    """The typed refusal for one denied ``(mode, action)`` pair.

    Always a licensing error the client already knows how to translate
    (``trial_upload_forbidden``, ``trial_restore_forbidden``,
    ``trial_expired``, ``license_status_unavailable``) — never "allowed".
    """
    if mode == "trial":
        if action == "restore":
            return TrialRestoreForbiddenError(
                "backup restore is not allowed during the trial"
            )
        if action == "upload":
            return TrialUploadForbiddenError(
                "backup upload is not allowed during the trial"
            )
        # The trial row only ever denies upload/restore; anything else
        # reaching here is a policy bug — refuse rather than fall open.
        return LicenseRequiredError(
            "this backup action requires a valid license"
        )
    if mode == "trial_expired":
        when = f" at {expires_at.isoformat()}" if expires_at else ""
        return TrialExpiredError(f"the free trial expired{when}")
    # Unknown mode (or a mode with no matrix row) — fail closed.
    return LicenseStatusUnavailableError(
        "license state could not be established for this backup action"
    )


def current_trial_status() -> TrialStatus | None:
    """Current trial observation, ``None`` when no trial is installed.

    Fail-closed: state that exists but cannot be verified (bad HMAC,
    truncated envelope, unreadable directory) raises 503
    ``license_status_unavailable`` — never an active trial, never
    "allowed".  Missing state is *not* corrupt state, so it returns
    ``None`` (the caller decides what "no trial" means).
    """
    try:
        return TrialManager.from_settings().status()
    except (StateStoreError, OSError, ValueError) as exc:
        raise LicenseStatusUnavailableError(
            "trial state could not be verified on this backend"
        ) from exc


def apply_backup_decision(action: str, decision: AuthorizationDecision) -> None:
    """Apply the §4.4 matrix to one already-taken combined decision.

    Shared by the router guard (``guard._enforce_on``) and
    :func:`require_backup_action` under ``LICENSE_ENFORCEMENT=on``
    (Phase L2-B), so both enforcement layers answer a backup question
    from the *same* decision object, the same way — a direct service
    call cannot grant what the guard would refuse, and vice versa.

    * ``lifetime`` (a valid Lifetime license) grants every action;
    * ``trial`` / ``trial_expired`` are answered by the matrix row above
      with the existing typed refusals;
    * outcomes with no matrix row (trial missing or unverifiable) are
      answered by the decision's own typed refusal — never as "allowed".
    """
    mode = decision.license_mode
    if mode is not None and backup_action_allowed(action, mode=mode):
        return
    if mode is None:
        # trial_missing / trial_unavailable: the decision already carries
        # the typed refusal; no matrix row exists for "cannot tell".
        refusal = decision.denial_error()
        if refusal is not None:
            raise refusal
    # Denied row (active trial's upload/restore, expired trial's writes)
    # or an unreachable modeless decision — the shared typed refusals.
    raise backup_denied_error(
        action,
        mode=mode if mode is not None else "",
        expires_at=(
            decision.trial.expires_at if decision.trial is not None else None
        ),
    )


def require_backup_action(action: str) -> None:
    """Service-level §4.4 enforcement for one backup action.

    Raises the typed licensing error when the action is not permitted for
    the *server's own* license state, and returns silently when licensing
    is disabled (``LICENSE_ENFORCEMENT=off``) or the action is granted.

    Called at the top of every ``BackupService`` public method — before a
    dump is taken, before an uploaded byte is accepted, and before any
    destructive restore work begins.
    """
    enforcement = settings.LICENSE_ENFORCEMENT
    if enforcement == "off":
        # Phase L0/L1 default: no state read, no decision, no error.
        return
    if enforcement == "on":
        # Phase L2-B: the combined Lifetime/Trial decision answers, and
        # the shared matrix application keeps this layer identical to
        # what the router guard decided for the same request.
        apply_backup_decision(action, decide_licensing())
        return
    if enforcement != "trial":
        # Unreachable with the validated Literal; fail closed, never open.
        raise LicenseStatusUnavailableError(
            f"license enforcement {enforcement!r} is not a recognized mode"
        )

    status = current_trial_status()
    if status is None:
        raise LicenseRequiredError("no trial is installed on this backend")
    if backup_action_allowed(action, mode=status.mode):
        return
    raise backup_denied_error(
        action, mode=status.mode, expires_at=status.expires_at
    )
