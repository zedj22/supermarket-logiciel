"""Repository contract and its in-memory implementation.

The one rule that matters here is **atomic duplicate prevention**: the
existence check and the license write happen inside a single transaction keyed
by ``devices/{hw_hash}``.  In Firestore that is ``firestore.transactional``
(``firestore_repository.py``); here it is one lock, so tests can hammer the
service from several threads and assert that exactly one license is created.

``InMemoryLicenseRepository`` is also what ``service.api.create_app`` uses when
no Firestore client is supplied, so the API can be exercised end to end —
including HTTP — without any cloud dependency.
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Mapping
from dataclasses import replace
from datetime import datetime, timezone
from typing import Any, Protocol

from service.contracts import (
    AuditEvent,
    DeviceRecord,
    IssueOutcome,
    LicenseDraft,
    LicenseRecord,
    Revocation,
)
from service.crypto import ActivationCodeCipher
from service.errors import (
    DeviceNotFoundError,
    LicenseConflictError,
    LicenseNotFoundError,
)

__all__ = ["AuditFactory", "InMemoryLicenseRepository", "LicenseRepository"]

#: Builds an audit event for an action inside a transaction.
AuditFactory = Callable[[str, "str | None"], AuditEvent]


class LicenseRepository(Protocol):
    """Storage contract (Firestore in production, memory in tests)."""

    def get_customer(self, customer_id: str) -> Mapping[str, Any] | None: ...

    def upsert_customer(
        self, customer_id: str, document: Mapping[str, Any]
    ) -> str: ...

    def get_device(self, hw_hash: str) -> DeviceRecord | None: ...

    def get_license(self, license_id: str) -> LicenseRecord | None: ...

    def list_licenses_for_device(self, hw_hash: str) -> list[LicenseRecord]: ...

    def create_or_get_license(
        self, *, hw_hash: str, build: Callable[[], LicenseDraft], make_audit: AuditFactory
    ) -> IssueOutcome: ...

    def reissue_license(
        self,
        *,
        previous_license_id: str,
        build: Callable[[], LicenseDraft],
        make_audit: AuditFactory,
    ) -> tuple[LicenseRecord, LicenseRecord]: ...

    def revoke_license(
        self,
        *,
        license_id: str,
        revocation: Revocation,
        make_audit: AuditFactory,
    ) -> LicenseRecord: ...

    def record_audit(self, event: AuditEvent) -> None: ...

    # -- dashboard reads (read-only, never return activation codes) ------ #
    def list_devices(self, limit: int) -> list[DeviceRecord]: ...

    def list_licenses(self, limit: int) -> list[LicenseRecord]: ...

    def list_customers(self, limit: int) -> list[tuple[str, Mapping[str, Any]]]: ...

    def list_audit_events(self, limit: int) -> list[AuditEvent]: ...

    def list_devices_for_customer(self, customer_id: str) -> list[DeviceRecord]: ...

    def list_licenses_for_customer(self, customer_id: str) -> list[LicenseRecord]: ...

    def counts(self) -> Mapping[str, int]: ...


class InMemoryLicenseRepository:
    """Thread-safe, process-local implementation of `LicenseRepository`."""

    def __init__(
        self,
        cipher: ActivationCodeCipher,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._cipher = cipher
        self._lock = threading.RLock()
        self._devices: dict[str, DeviceRecord] = {}
        self._licenses: dict[str, LicenseRecord] = {}
        self._customers: dict[str, dict[str, Any]] = {}
        self.audit_events: list[AuditEvent] = []
        self._clock = clock or (lambda: datetime.now(timezone.utc))

    # -- helpers -------------------------------------------------------- #
    def _store_draft(self, draft: LicenseDraft) -> LicenseRecord:
        """Seal the code and keep the record (caller holds the lock)."""
        if draft.issued.license_id in self._licenses:
            raise LicenseConflictError(
                "a license with this id already exists; issue a new id"
            )
        sealed = self._cipher.seal(
            license_id=draft.issued.license_id, code=draft.issued.code
        )
        record = draft.to_license_record(
            activation_code=self._cipher.open(
                license_id=draft.issued.license_id, envelope=sealed
            )
        )
        self._licenses[record.license_id] = record
        return record

    def _touch_device(self, draft: LicenseDraft, *, now: datetime) -> DeviceRecord:
        previous = self._devices.get(draft.hw_hash)
        device = DeviceRecord(
            hw_hash=draft.hw_hash,
            first_seen_at=previous.first_seen_at if previous is not None else now,
            last_seen_at=now,
            install_id=draft.install_id or (previous.install_id if previous else None),
            request_code=draft.request_code or (previous.request_code if previous else None),
            fingerprint_display_code=(
                draft.fingerprint_display_code
                or (previous.fingerprint_display_code if previous else None)
            ),
            customer_id=draft.customer_id or (previous.customer_id if previous else None),
            current_license_id=draft.issued.license_id,
        )
        self._devices[draft.hw_hash] = device
        return device

    # -- customers ------------------------------------------------------ #
    def get_customer(self, customer_id: str) -> Mapping[str, Any] | None:
        with self._lock:
            found = self._customers.get(customer_id)
            return dict(found) if found is not None else None

    def upsert_customer(self, customer_id: str, document: Mapping[str, Any]) -> str:
        with self._lock:
            self._customers[customer_id] = dict(document)
            return customer_id

    # -- devices -------------------------------------------------------- #
    def get_device(self, hw_hash: str) -> DeviceRecord | None:
        with self._lock:
            return self._devices.get(hw_hash)

    def get_license(self, license_id: str) -> LicenseRecord | None:
        with self._lock:
            return self._licenses.get(license_id)

    def list_licenses_for_device(self, hw_hash: str) -> list[LicenseRecord]:
        with self._lock:
            found = [record for record in self._licenses.values() if record.hw_hash == hw_hash]
        return sorted(found, key=lambda record: record.created_at, reverse=True)

    # -- issuance (atomic) ---------------------------------------------- #
    def create_or_get_license(
        self, *, hw_hash: str, build: Callable[[], LicenseDraft], make_audit: AuditFactory
    ) -> IssueOutcome:
        with self._lock:
            device = self._devices.get(hw_hash)
            if device is not None and device.current_license_id:
                existing = self._licenses.get(device.current_license_id)
                if existing is not None:
                    self.audit_events.append(
                        make_audit("license_existing_returned", existing.license_id)
                    )
                    return IssueOutcome(license=existing, created=False)

            draft = build()
            if draft.hw_hash != hw_hash:
                raise LicenseConflictError(
                    "the signing inputs did not match the requested device"
                )
            record = self._store_draft(draft)
            self._touch_device(draft, now=draft.created_at)
            self.audit_events.append(make_audit("license_issued", record.license_id))
            return IssueOutcome(license=record, created=True)

    def reissue_license(
        self,
        *,
        previous_license_id: str,
        build: Callable[[], LicenseDraft],
        make_audit: AuditFactory,
    ) -> tuple[LicenseRecord, LicenseRecord]:
        with self._lock:
            previous = self._licenses.get(previous_license_id)
            if previous is None:
                raise LicenseNotFoundError("no license exists with this id")
            if previous.status == "superseded":
                raise LicenseConflictError(
                    "this license was already replaced; reissue from the current license"
                )
            draft = build()
            if draft.hw_hash != previous.hw_hash:
                raise LicenseConflictError(
                    "a reissue must target the same hardware fingerprint"
                )
            if draft.issued.license_id == previous.license_id:
                raise LicenseConflictError(
                    "a reissue must produce a new license id"
                )
            new_record = self._store_draft(draft)
            superseded = replace(
                previous, status="superseded", superseded_by=new_record.license_id
            )
            self._licenses[previous.license_id] = superseded
            self._touch_device(draft, now=draft.created_at)
            self.audit_events.append(
                make_audit("license_superseded", previous.license_id)
            )
            self.audit_events.append(
                make_audit("license_reissued", new_record.license_id)
            )
            return superseded, new_record

    def revoke_license(
        self,
        *,
        license_id: str,
        revocation: Revocation,
        make_audit: AuditFactory,
    ) -> LicenseRecord:
        with self._lock:
            record = self._licenses.get(license_id)
            if record is None:
                raise LicenseNotFoundError("no license exists with this id")
            if record.status == "revoked":
                return record
            if record.status != "active":
                raise LicenseConflictError(
                    "only the current license can be revoked; this one was replaced"
                )
            revoked = replace(
                record,
                status="revoked",
                revoked_at=revocation.revoked_at,
                revoked_reason=revocation.reason,
            )
            self._licenses[license_id] = revoked
            self.audit_events.append(make_audit("license_revoked", license_id))
            return revoked

    # -- audit ---------------------------------------------------------- #
    def record_audit(self, event: AuditEvent) -> None:
        with self._lock:
            self.audit_events.append(event)

    # -- dashboard reads -------------------------------------------------- #
    def list_devices(self, limit: int) -> list[DeviceRecord]:
        with self._lock:
            devices = sorted(
                self._devices.values(), key=lambda device: device.last_seen_at, reverse=True
            )
        return devices[:limit]

    def list_licenses(self, limit: int) -> list[LicenseRecord]:
        with self._lock:
            licenses = sorted(
                self._licenses.values(), key=lambda record: record.created_at, reverse=True
            )
        return licenses[:limit]

    def list_customers(self, limit: int) -> list[tuple[str, Mapping[str, Any]]]:
        with self._lock:
            items = sorted(self._customers.items(), key=lambda item: item[0])
        return [(customer_id, dict(document)) for customer_id, document in items[:limit]]

    def list_audit_events(self, limit: int) -> list[AuditEvent]:
        with self._lock:
            events = sorted(self.audit_events, key=lambda event: event.at, reverse=True)
        return events[:limit]

    def list_devices_for_customer(self, customer_id: str) -> list[DeviceRecord]:
        with self._lock:
            devices = [
                device for device in self._devices.values() if device.customer_id == customer_id
            ]
        return sorted(devices, key=lambda device: device.last_seen_at, reverse=True)

    def list_licenses_for_customer(self, customer_id: str) -> list[LicenseRecord]:
        with self._lock:
            licenses = [
                record
                for record in self._licenses.values()
                if record.customer_id == customer_id
            ]
        return sorted(licenses, key=lambda record: record.created_at, reverse=True)

    def counts(self) -> Mapping[str, int]:
        with self._lock:
            licenses = list(self._licenses.values())
            return {
                "customers": len(self._customers),
                "devices": len(self._devices),
                "active_licenses": sum(1 for r in licenses if r.status == "active"),
                "revoked_licenses": sum(1 for r in licenses if r.status == "revoked"),
                "superseded_licenses": sum(1 for r in licenses if r.status == "superseded"),
            }

    # -- test helpers ---------------------------------------------------- #
    def audit_actions(self) -> list[str]:
        with self._lock:
            return [event.action for event in self.audit_events]

    def require_device(self, hw_hash: str) -> DeviceRecord:
        device = self.get_device(hw_hash)
        if device is None:
            raise DeviceNotFoundError("no device is recorded for this fingerprint")
        return device
