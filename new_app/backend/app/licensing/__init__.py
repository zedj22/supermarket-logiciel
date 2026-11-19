"""Licensing subsystem (Phase L0 foundations + Phase L1 trial engine +
Phase L1-A hardware fingerprint + Phase L1-D backup policy + Phase L2-A
Lifetime activation + Phase L2-B enforcement integration).

Contents:

* `errors` - typed licensing errors and their lowercase code registry.
* `authorization` - the Phase L2-B combined decision: one read-only pass
  that admits a valid Lifetime license **or** an active Free Trial under
  ``LICENSE_ENFORCEMENT=on``, and refuses everything else fail-closed
  (§12 / §4 policy).
* `backup_policy` - the �4.4 backup action matrix as shared data: the
  router guard and `BackupService` both classify and enforce through it,
  so a direct service call cannot bypass a Trial restriction (L1-D) or a
  Lifetime decision (L2-B).
* `fingerprint` - `HardwareFingerprintService`: the �4.3 machine
  fingerprint (SHA-256 over MachineGuid + system-volume serial +
  hostname) used to bind Lifetime licenses (L1-A, activated in L2-A).
* `state_store` - atomic, integrity-checked, DPAPI-sealed file store for
  license/trial state (kept out of PostgreSQL on purpose).
* `verification_keys` - loader for the public Ed25519 verification keys.
* `activation_code` - the two customer-copyable code formats: unsigned
  ``SMPr1.`` activation requests and signed ``SMP1.`` Lifetime codes,
  with strict parsing, schema validation and Ed25519 verification (L2-A).
* `license_manager` - `LicenseManager`: activation request, activation
  and read-only re-verification of the stored Lifetime license
  (`license.state`, outside PostgreSQL), reusing `StateStore`,
  `verification_keys` and `HardwareFingerprintService` (L2-A).
* `guard` - router-level license guard: a no-op while
  ``LICENSE_ENFORCEMENT=off`` (the shipped default), the Free Trial
  engine under ``trial`` (Phase L1), the combined Lifetime/Trial
  decision under ``on`` (Phase L2-B).
* `trial` - `TrialManager` / `TrialStatus`: the 10-calendar-day (240 h)
  offline trial, started once on the first backend start (D5) with a
  persisted monotonic clock guard (�5 T4).

Lifetime activation (License Manager, `/license` endpoints) shipped its
**backend foundation** in Phase L2-A, and Phase L2-B (�12) wired it into
the ``LICENSE_ENFORCEMENT=on`` matrix that *uses* the Lifetime status:
a valid license (or an active trial) authorizes business routes, backups
and the §4.4 rows, decided server-side on every request.
"""

from __future__ import annotations

from app.licensing.activation_code import (
    ACTIVATION_PREFIX,
    REQUEST_PREFIX,
    ActivationPayload,
    build_request_code,
    build_request_payload,
    canonical_json,
    encode_activation_code,
    verify_activation_code,
)
from app.licensing.authorization import (
    AuthorizationDecision,
    Outcome,
    decide_licensing,
)
from app.licensing.backup_policy import (
    BACKUP_ACTIONS,
    LICENSE_BACKUP_GRANTS,
    apply_backup_decision,
    backup_action_allowed,
    backup_denied_error,
    classify_backup_action,
    current_trial_status,
    require_backup_action,
)
from app.licensing.errors import (
    LICENSING_ERROR_CODES,
    LicenseBoundElsewhereError,
    LicenseInvalidError,
    LicenseInvalidKeyError,
    LicenseRequiredError,
    LicenseStatusUnavailableError,
    TrialExpiredError,
    TrialRestoreForbiddenError,
    TrialUploadForbiddenError,
)
from app.licensing.fingerprint import (
    HardwareFingerprintService,
    HardwareIdentifierUnavailableError,
    HardwareInfoProvider,
    StaticHardwareInfoProvider,
    WindowsHardwareInfoProvider,
)
from app.licensing.guard import ALLOW_PATHS, is_allowlisted, license_guard
from app.licensing.license_manager import (
    LICENSE_STATE_NAME,
    ActivationRequest,
    LicenseManager,
    LicenseStatus,
)
from app.licensing.state_store import (
    StateFileCorruptedError,
    StateProtectionUnavailableError,
    StateStore,
    StateStoreError,
    dpapi_available,
)
from app.licensing.trial import STATE_NAME, TrialManager, TrialStatus
from app.licensing.verification_keys import (
    VerificationKeysError,
    load_verification_keys,
)

__all__ = [
    "ACTIVATION_PREFIX",
    "ALLOW_PATHS",
    "BACKUP_ACTIONS",
    "LICENSE_BACKUP_GRANTS",
    "LICENSE_STATE_NAME",
    "LICENSING_ERROR_CODES",
    "REQUEST_PREFIX",
    "STATE_NAME",
    "ActivationPayload",
    "ActivationRequest",
    "AuthorizationDecision",
    "HardwareFingerprintService",
    "HardwareIdentifierUnavailableError",
    "HardwareInfoProvider",
    "LicenseBoundElsewhereError",
    "LicenseInvalidError",
    "LicenseInvalidKeyError",
    "LicenseManager",
    "LicenseRequiredError",
    "LicenseStatus",
    "LicenseStatusUnavailableError",
    "Outcome",
    "StateFileCorruptedError",
    "StateProtectionUnavailableError",
    "StateStore",
    "StateStoreError",
    "StaticHardwareInfoProvider",
    "TrialExpiredError",
    "TrialManager",
    "TrialRestoreForbiddenError",
    "TrialStatus",
    "TrialUploadForbiddenError",
    "VerificationKeysError",
    "WindowsHardwareInfoProvider",
    "apply_backup_decision",
    "backup_action_allowed",
    "backup_denied_error",
    "build_request_code",
    "build_request_payload",
    "canonical_json",
    "classify_backup_action",
    "current_trial_status",
    "decide_licensing",
    "dpapi_available",
    "encode_activation_code",
    "is_allowlisted",
    "license_guard",
    "load_verification_keys",
    "require_backup_action",
    "verify_activation_code",
]
