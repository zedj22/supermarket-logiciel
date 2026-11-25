"""Business logic of the KlickPOS License Manager.

The service is the only place that decides *what* happens; storage lives behind
`LicenseRepository` and cryptography behind `LicenseIssuer`.  Three business
rules are enforced here, and all three are pinned by tests:

* **One license per hardware fingerprint.**  ``issue`` never signs when an
  existing license is found — it returns the original record and its original
  code, so a repeated submission can never mint a second license.
* **Issuance is a reissue-safe history.**  ``reissue`` adds a new license
  document and marks the old one ``superseded``; nothing is overwritten.
* **Revocation is administrative.**  It records who revoked what and why, and
  the response states plainly that an offline lifetime license cannot be
  deactivated remotely.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from typing import Any

from service import shared
from service.auth import AdminPrincipal
from service.contracts import (
    AuditEvent,
    DeviceRecord,
    IssueOutcome,
    LicenseDraft,
    LicenseRecord,
    ParseResult,
    Revocation,
)
from service.errors import (
    ConfirmationRequiredError,
    CustomerNotFoundError,
    DeviceNotFoundError,
    LicenseNotFoundError,
    RequestFormatInvalidError,
    ValidationFailedError,
)
from service.repository import LicenseRepository
from service.settings import Settings
from service.signing import LicenseIssuer

__all__ = [
    "EXISTING_LICENSE_NOTICE",
    "REVOCATION_NOTICE",
    "LicenseService",
]

#: Returned whenever a duplicate fingerprint finds its original license.
EXISTING_LICENSE_NOTICE = (
    "This hardware fingerprint already has a lifetime license. The original "
    "activation code is returned unchanged; no second license was created."
)

#: Returned by the revocation endpoint, every time, in those words.
REVOCATION_NOTICE = (
    "Administrative revocation recorded. A KlickPOS lifetime license is signed, "
    "stored and verified offline on the customer's own machine, so this operation "
    "cannot remotely deactivate it: the point of sale keeps running until the "
    "license file on that device is replaced or removed. Use reissue to give the "
    "customer a replacement code, and treat revocation as a records/eligibility "
    "marker, not a kill switch."
)

#: Appended when the administrator retrieves the code of a revoked license.
REVOKED_CODE_WARNING = (
    "This license is administratively revoked. The code below still activates "
    "the device it is bound to; revocation did not invalidate it."
)


#: Every dashboard search scans at most this many documents, then pages.
#: Firestore has no substring search, so a full-text index would be needed to
#: do better; for a single-administrator tool this bound is honest and cheap.
MAX_SCAN = 500


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _matches(query: str, *values: str | None) -> bool:
    needle = query.strip().lower()
    if not needle:
        return True
    return any(needle in (value or "").lower() for value in values)


class LicenseService:
    """Parse requests, issue, read, reissue and revoke lifetime licenses."""

    def __init__(
        self,
        repository: LicenseRepository,
        *,
        issuer_factory: Callable[[], LicenseIssuer],
        settings: Settings,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._repository = repository
        self._issuer_factory = issuer_factory
        self._issuer: LicenseIssuer | None = None
        self._settings = settings
        self._clock = clock or _now

    # -- helpers -------------------------------------------------------- #
    def now(self) -> datetime:
        return self._clock().astimezone(timezone.utc).replace(microsecond=0)

    @property
    def issuer(self) -> LicenseIssuer:
        """The signing issuer, resolved on first use (key stays in memory)."""
        if self._issuer is None:
            self._issuer = self._issuer_factory()
        return self._issuer

    def _audit(
        self,
        principal: AdminPrincipal,
        action: str,
        *,
        license_id: str | None = None,
        hw_hash: str | None = None,
        client_ip: str | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> AuditEvent:
        """Build one audit event (never contains a code or key material)."""
        return AuditEvent(
            event_id=uuid.uuid4().hex,
            at=self.now(),
            action=action,
            actor_uid=principal.uid,
            actor_email=principal.email,
            license_id=license_id,
            hw_hash=hw_hash,
            client_ip=client_ip,
            details=dict(details or {}),
        )

    def _audit_factory(
        self,
        principal: AdminPrincipal,
        *,
        hw_hash: str,
        client_ip: str | None,
    ) -> Callable[[str, str | None], AuditEvent]:
        def make(action: str, license_id: str | None) -> AuditEvent:
            return self._audit(
                principal,
                action,
                license_id=license_id,
                hw_hash=hw_hash,
                client_ip=client_ip,
            )

        return make

    def _existing_for(self, hw_hash: str) -> tuple[DeviceRecord | None, LicenseRecord | None]:
        device = self._repository.get_device(hw_hash)
        if device is None or not device.current_license_id:
            return device, None
        return device, self._repository.get_license(device.current_license_id)

    # -- 1. parse -------------------------------------------------------- #
    def parse(
        self, principal: AdminPrincipal, request_code: str, *, client_ip: str | None = None
    ) -> ParseResult:
        """Strictly read an ``SMPr1`` request with the existing parser."""
        try:
            parsed = shared.parse_request_code(request_code)
        except shared.RequestFormatError as exc:
            raise RequestFormatInvalidError(str(exc)) from exc

        device, existing = self._existing_for(parsed.hw_hash)
        self._repository.record_audit(
            self._audit(
                principal,
                "license_request_parsed",
                license_id=existing.license_id if existing else None,
                hw_hash=parsed.hw_hash,
                client_ip=client_ip,
                details={"install_id": parsed.install_id},
            )
        )
        return ParseResult(
            hw_hash=parsed.hw_hash,
            install_id=parsed.install_id,
            requested_at=parsed.requested_at.astimezone(timezone.utc),
            request_code=request_code.strip(),
            fingerprint_display_code=shared.display_code_for(parsed.hw_hash),
            device=device,
            existing_license=existing,
        )

    # -- 2. issue -------------------------------------------------------- #
    def issue(
        self,
        principal: AdminPrincipal,
        *,
        request_code: str | None = None,
        hw_hash: str | None = None,
        features: Any = None,
        customer_id: str | None = None,
        customer: Mapping[str, Any] | None = None,
        client_ip: str | None = None,
    ) -> IssueOutcome:
        """Create the single lifetime license for this hardware fingerprint.

        Accepts either the full ``SMPr1`` request (preferred: it carries the
        install id for the audit trail) or the bare 64-hex fingerprint digest.
        """
        if (request_code is None) == (hw_hash is None):
            raise ValidationFailedError(
                "supply exactly one of request_code or hw_hash"
            )

        install_id: str | None = None
        resolved_request: str | None = None
        if request_code is not None:
            try:
                parsed = shared.parse_request_code(request_code)
            except shared.RequestFormatError as exc:
                raise RequestFormatInvalidError(str(exc)) from exc
            digest = parsed.hw_hash
            install_id = parsed.install_id
            resolved_request = request_code.strip()
        else:
            digest = (hw_hash or "").strip().lower()
            if not shared.is_valid_hw_hash(digest):
                raise ValidationFailedError(
                    "the hardware fingerprint must be a 64-character lowercase "
                    "SHA-256 hex digest"
                )

        try:
            granted = shared.normalise_features(features)
        except ValueError as exc:
            raise ValidationFailedError(str(exc)) from exc

        device = self._repository.get_device(digest)
        resolved_customer = customer_id or (device.customer_id if device else None)
        if customer is not None:
            resolved_customer = self._store_customer(
                principal, customer, existing_id=resolved_customer
            )
        elif resolved_customer is not None and self._repository.get_customer(
            resolved_customer
        ) is None:
            raise ValidationFailedError("unknown customer_id")

        def build() -> LicenseDraft:
            issued = self.issuer.issue(hw_hash=digest, features=granted)
            return LicenseDraft(
                hw_hash=digest,
                issued=issued,
                created_at=self.now(),
                created_by=principal.uid,
                customer_id=resolved_customer,
                install_id=install_id,
                request_code=resolved_request,
                fingerprint_display_code=shared.display_code_for(digest),
            )

        outcome = self._repository.create_or_get_license(
            hw_hash=digest,
            build=build,
            make_audit=self._audit_factory(principal, hw_hash=digest, client_ip=client_ip),
        )
        return outcome

    def _store_customer(
        self,
        principal: AdminPrincipal,
        customer: Mapping[str, Any],
        *,
        existing_id: str | None,
    ) -> str:
        name = str(customer.get("name") or "").strip()
        if not name:
            raise ValidationFailedError("customer.name is required")
        identifier = existing_id or f"CUS-{uuid.uuid4().hex[:16]}"
        self._repository.upsert_customer(
            identifier,
            {
                "customer_id": identifier,
                "name": name,
                "email": str(customer.get("email") or "").strip() or None,
                "phone": str(customer.get("phone") or "").strip() or None,
                "notes": str(customer.get("notes") or "").strip() or None,
                "updated_at": self.now(),
                "updated_by": principal.uid,
            },
        )
        return identifier

    # -- 3. device ------------------------------------------------------- #
    def get_device(
        self, principal: AdminPrincipal, hw_hash: str, *, client_ip: str | None = None
    ) -> tuple[DeviceRecord, list[LicenseRecord]]:
        digest = (hw_hash or "").strip().lower()
        if not shared.is_valid_hw_hash(digest):
            raise ValidationFailedError(
                "the hardware fingerprint must be a 64-character lowercase "
                "SHA-256 hex digest"
            )
        device = self._repository.get_device(digest)
        if device is None:
            raise DeviceNotFoundError("no device is recorded for this fingerprint")
        licenses = self._repository.list_licenses_for_device(digest)
        self._repository.record_audit(
            self._audit(
                principal,
                "device_viewed",
                license_id=device.current_license_id,
                hw_hash=digest,
                client_ip=client_ip,
            )
        )
        return device, licenses

    # -- 4. code retrieval ----------------------------------------------- #
    def get_code(
        self, principal: AdminPrincipal, license_id: str, *, client_ip: str | None = None
    ) -> LicenseRecord:
        """Return the original activation code; every read is audited."""
        record = self._repository.get_license(license_id)
        if record is None:
            raise LicenseNotFoundError("no license exists with this id")
        self._repository.record_audit(
            self._audit(
                principal,
                "activation_code_viewed",
                license_id=record.license_id,
                hw_hash=record.hw_hash,
                client_ip=client_ip,
                details={"status": record.status},
            )
        )
        return record

    # -- 5. reissue ------------------------------------------------------ #
    def reissue(
        self,
        principal: AdminPrincipal,
        license_id: str,
        *,
        reason: str,
        confirm: bool,
        client_ip: str | None = None,
    ) -> tuple[LicenseRecord, LicenseRecord]:
        """Replace a license with a new one, preserving the original record."""
        if confirm is not True:
            raise ConfirmationRequiredError(
                "reissue requires explicit confirmation (confirm: true)"
            )
        cleaned = (reason or "").strip()
        if len(cleaned) < 4:
            raise ValidationFailedError(
                "a reissue reason of at least 4 characters is required"
            )
        previous = self._repository.get_license(license_id)
        if previous is None:
            raise LicenseNotFoundError("no license exists with this id")

        def build() -> LicenseDraft:
            issued = self.issuer.issue(
                hw_hash=previous.hw_hash, features=tuple(previous.features)
            )
            return LicenseDraft(
                hw_hash=previous.hw_hash,
                issued=issued,
                created_at=self.now(),
                created_by=principal.uid,
                customer_id=previous.customer_id,
                install_id=previous.install_id,
                request_code=previous.request_code,
                fingerprint_display_code=shared.display_code_for(previous.hw_hash),
                reissued_from=previous.license_id,
            )

        superseded, issued = self._repository.reissue_license(
            previous_license_id=license_id,
            build=build,
            make_audit=self._audit_factory(
                principal, hw_hash=previous.hw_hash, client_ip=client_ip
            ),
        )
        # The reason is audit metadata, not part of any signed structure.
        self._repository.record_audit(
            self._audit(
                principal,
                "license_reissue_reason",
                license_id=issued.license_id,
                hw_hash=previous.hw_hash,
                client_ip=client_ip,
                details={"reason": cleaned, "previous_license_id": license_id},
            )
        )
        return superseded, issued

    # -- 6. revoke ------------------------------------------------------- #
    def revoke(
        self,
        principal: AdminPrincipal,
        license_id: str,
        *,
        reason: str,
        client_ip: str | None = None,
    ) -> LicenseRecord:
        """Record an administrative revocation (and say what it cannot do)."""
        cleaned = (reason or "").strip()
        if len(cleaned) < 4:
            raise ValidationFailedError(
                "a revocation reason of at least 4 characters is required"
            )
        record = self._repository.get_license(license_id)
        if record is None:
            raise LicenseNotFoundError("no license exists with this id")
        return self._repository.revoke_license(
            license_id=license_id,
            revocation=Revocation(
                reason=cleaned, revoked_at=self.now(), revoked_by=principal.uid
            ),
            make_audit=self._audit_factory(
                principal, hw_hash=record.hw_hash, client_ip=client_ip
            ),
        )

    # -- 7. dashboard reads ---------------------------------------------- #
    def overview(self, principal: AdminPrincipal) -> dict[str, Any]:
        """Counts plus the two short recency lists the Overview page shows."""
        return {
            "counts": dict(self._repository.counts()),
            "recent_licenses": self._repository.list_licenses(8),
            "recent_events": self._repository.list_audit_events(8),
        }

    def search_devices(
        self, principal: AdminPrincipal, *, query: str = "", limit: int = 50
    ) -> tuple[list[tuple[DeviceRecord, LicenseRecord | None]], int]:
        scanned = self._repository.list_devices(MAX_SCAN)
        matched = [
            device
            for device in scanned
            if _matches(
                query,
                device.hw_hash,
                device.install_id,
                device.customer_id,
                device.fingerprint_display_code,
            )
        ]
        page = [
            (
                device,
                self._repository.get_license(device.current_license_id)
                if device.current_license_id
                else None,
            )
            for device in matched[:limit]
        ]
        return page, len(matched)

    def search_licenses(
        self,
        principal: AdminPrincipal,
        *,
        query: str = "",
        status: str = "",
        limit: int = 50,
    ) -> tuple[list[LicenseRecord], int]:
        scanned = self._repository.list_licenses(MAX_SCAN)
        matched = [
            record
            for record in scanned
            if (not status or record.status == status)
            and _matches(
                query,
                record.license_id,
                record.hw_hash,
                record.customer_id,
                record.install_id,
                record.key_id,
                record.status,
            )
        ]
        return matched[:limit], len(matched)

    def search_customers(
        self, principal: AdminPrincipal, *, query: str = "", limit: int = 50
    ) -> tuple[list[tuple[str, Mapping[str, Any]]], int]:
        scanned = self._repository.list_customers(MAX_SCAN)
        matched = [
            (customer_id, document)
            for customer_id, document in scanned
            if _matches(
                query,
                customer_id,
                str(document.get("name") or ""),
                str(document.get("email") or ""),
                str(document.get("phone") or ""),
            )
        ]
        return matched[:limit], len(matched)

    def get_customer(
        self, principal: AdminPrincipal, customer_id: str
    ) -> tuple[Mapping[str, Any], list[DeviceRecord], list[LicenseRecord]]:
        document = self._repository.get_customer(customer_id)
        if document is None:
            raise CustomerNotFoundError("no customer exists with this id")
        return (
            document,
            self._repository.list_devices_for_customer(customer_id),
            self._repository.list_licenses_for_customer(customer_id),
        )

    def search_audit(
        self, principal: AdminPrincipal, *, query: str = "", limit: int = 100
    ) -> tuple[list[AuditEvent], int]:
        scanned = self._repository.list_audit_events(MAX_SCAN)
        matched = [
            event
            for event in scanned
            if _matches(
                query,
                event.action,
                event.actor_uid,
                event.actor_email,
                event.license_id,
                event.hw_hash,
            )
        ]
        return matched[:limit], len(matched)
