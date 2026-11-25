"""Record types shared by the service and its repositories.

These mirror the Firestore documents documented in ``README.md``.  They carry
only what the platform is allowed to hold: the hardware **digest** (never a
raw machine identifier), the unsigned request code, the signed activation code
(sealed at rest), license metadata and audit metadata.  No private key
material, ever.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Literal

__all__ = [
    "AuditEvent",
    "DeviceRecord",
    "IssueOutcome",
    "IssuedCode",
    "LicenseDraft",
    "LicenseRecord",
    "LicenseStatus",
    "ParseResult",
    "Revocation",
]

#: The only license state this platform manages.
LicenseStatus = Literal["active", "superseded", "revoked"]


@dataclass(frozen=True, slots=True)
class IssuedCode:
    """A freshly signed ``SMP1`` code plus the fields that were signed."""

    code: str
    license_id: str
    key_id: str
    issued_at: datetime
    features: tuple[str, ...]
    #: Exact canonical bytes the Ed25519 signature covers.
    payload_bytes: bytes
    signature: bytes


@dataclass(frozen=True, slots=True)
class LicenseRecord:
    """One stored license document (``licenses/{license_id}``)."""

    license_id: str
    hw_hash: str
    status: LicenseStatus
    kind: str
    key_id: str
    issued_at: datetime
    created_at: datetime
    created_by: str
    features: tuple[str, ...] = ("pos",)
    install_id: str | None = None
    request_code: str | None = None
    customer_id: str | None = None
    #: The activation code, decrypted from its sealed Firestore field.
    activation_code: str = ""
    reissued_from: str | None = None
    superseded_by: str | None = None
    revoked_at: datetime | None = None
    revoked_reason: str | None = None

    @property
    def is_active(self) -> bool:
        return self.status == "active"


@dataclass(frozen=True, slots=True)
class DeviceRecord:
    """One device document (``devices/{hw_hash}``)."""

    hw_hash: str
    first_seen_at: datetime
    last_seen_at: datetime
    install_id: str | None = None
    request_code: str | None = None
    fingerprint_display_code: str | None = None
    customer_id: str | None = None
    current_license_id: str | None = None


@dataclass(frozen=True, slots=True)
class LicenseDraft:
    """What the service hands a repository inside a transaction to store.

    All cryptographic work has already happened in ``build()``: the repository
    only persists the result, so a transaction retry can never re-sign with
    different inputs.
    """

    hw_hash: str
    issued: IssuedCode
    created_at: datetime
    created_by: str
    customer_id: str | None = None
    install_id: str | None = None
    request_code: str | None = None
    fingerprint_display_code: str | None = None
    reissued_from: str | None = None

    def to_license_record(self, *, activation_code: str) -> LicenseRecord:
        return LicenseRecord(
            license_id=self.issued.license_id,
            hw_hash=self.hw_hash,
            status="active",
            kind="lifetime",
            key_id=self.issued.key_id,
            issued_at=self.issued.issued_at,
            created_at=self.created_at,
            created_by=self.created_by,
            features=self.issued.features,
            install_id=self.install_id,
            request_code=self.request_code,
            customer_id=self.customer_id,
            activation_code=activation_code,
            reissued_from=self.reissued_from,
        )


@dataclass(frozen=True, slots=True)
class IssueOutcome:
    """Result of an issuance attempt: the code plus whether it is new."""

    license: LicenseRecord
    created: bool


@dataclass(frozen=True, slots=True)
class Revocation:
    """The administrative revocation record for one license."""

    reason: str
    revoked_at: datetime
    revoked_by: str


@dataclass(frozen=True, slots=True)
class AuditEvent:
    """One ``audit_log/{event_id}`` document."""

    event_id: str
    at: datetime
    action: str
    actor_uid: str
    actor_email: str | None = None
    license_id: str | None = None
    hw_hash: str | None = None
    client_ip: str | None = None
    details: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ParseResult:
    """The outcome of ``POST /v1/requests/parse``."""

    hw_hash: str
    install_id: str
    requested_at: datetime
    request_code: str
    fingerprint_display_code: str
    device: DeviceRecord | None
    existing_license: LicenseRecord | None
