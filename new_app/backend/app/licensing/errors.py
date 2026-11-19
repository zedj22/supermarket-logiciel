"""Typed licensing errors (Phase L0 foundations).

Every error carries a **lowercase, snake_case** ``code`` — the same
convention the Flutter client already understands from the Phase 16 device
guard (``device_required`` | ``device_not_paired`` | ``device_revoked``) —
plus an HTTP status and a client-side i18n ``message_key``.

Codes live here (not inline in routers) so the Phase L1/L2 managers, the
fail-closed guard and the client translation tables all reference one
registry.  Nothing in this module is raised by Phase L0's shipped default
path (enforcement is ``off``); the classes exist so L1/L2 can adopt them
without renaming codes later.
"""

from __future__ import annotations

from app.core.exceptions import AppError

__all__ = [
    "LicenseBoundElsewhereError",
    "LicenseInvalidError",
    "LicenseInvalidKeyError",
    "LicenseRequiredError",
    "LicenseStatusUnavailableError",
    "LICENSING_ERROR_CODES",
    "TrialExpiredError",
    "TrialRestoreForbiddenError",
    "TrialUploadForbiddenError",
]


class LicenseRequiredError(AppError):
    """No license is installed and no trial is active."""

    code = "license_required"
    status_code = 403
    message_key = "errors.license.required"


class TrialExpiredError(AppError):
    """The local trial window has elapsed (fail-closed, see §9)."""

    code = "trial_expired"
    status_code = 403
    message_key = "errors.license.trialExpired"


class TrialRestoreForbiddenError(AppError):
    """A backup restore would resurrect a consumed/expired trial (§7.5)."""

    code = "trial_restore_forbidden"
    status_code = 403
    message_key = "errors.license.trialRestoreForbidden"


class TrialUploadForbiddenError(AppError):
    """Backup upload rejected: it would carry licensing state (§7.5)."""

    code = "trial_upload_forbidden"
    status_code = 403
    message_key = "errors.license.trialUploadForbidden"


class LicenseInvalidError(AppError):
    """The installed license blob failed signature/binding validation."""

    code = "license_invalid"
    status_code = 403
    message_key = "errors.license.invalid"


class LicenseInvalidKeyError(AppError):
    """The license references an unknown or unusable verification key."""

    code = "license_invalid_key"
    status_code = 403
    message_key = "errors.license.invalidKey"


class LicenseBoundElsewhereError(AppError):
    """The license is cryptographically bound to a different install."""

    code = "license_bound_elsewhere"
    status_code = 403
    message_key = "errors.license.boundElsewhere"


class LicenseStatusUnavailableError(AppError):
    """Fail-closed 503: license state cannot be established (guard, §10.3).

    Used when enforcement is enabled but the licensing state itself
    cannot be read or verified (unreadable trial/license files, unusable
    verification keys, unavailable hardware fingerprint).  A missing
    license is *not* this error — it is the 403 ``license_required``.
    Never fail open on a licensing question.
    """

    code = "license_status_unavailable"
    status_code = 503
    message_key = "errors.license.statusUnavailable"


#: Every licensing code this backend can emit.  The client keeps its own
#: copy for translation; a mismatch is a contract bug (§11.4).
LICENSING_ERROR_CODES: frozenset[str] = frozenset(
    {
        "license_required",
        "trial_expired",
        "trial_restore_forbidden",
        "trial_upload_forbidden",
        "license_invalid",
        "license_invalid_key",
        "license_bound_elsewhere",
        "license_status_unavailable",
    }
)
