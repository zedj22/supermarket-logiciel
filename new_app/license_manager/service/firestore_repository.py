"""Firestore implementation of `LicenseRepository`.

Every mutation runs inside one Firestore transaction keyed by
``devices/{hw_hash}`` (for issuance) or ``licenses/{license_id}`` (for reissue
and revocation).  The read and the write of the duplicate check are therefore
in the same transaction: two simultaneous requests for one fingerprint can
never both create a license — the second transaction observes the first
commit and returns the existing record instead.

Document layout (see ``README.md``)::

    customers/{customer_id}
    devices/{hw_hash}
    licenses/{license_id}
    audit_log/{event_id}

The activation code is persisted only as an AES-GCM envelope
(``activation_code_sealed``); the repository seals and opens it, so nothing
above this layer ever stores plaintext.  Raw machine identifiers are never
received by this service and never written.
"""

from __future__ import annotations

import os
import time
from collections.abc import Callable, Mapping
from dataclasses import replace
from datetime import datetime, timezone
from typing import Any

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
    ApiError,
    LicenseConflictError,
    LicenseNotFoundError,
    StoreUnavailableError,
)
from service.repository import AuditFactory

__all__ = ["COLLECTIONS", "FirestoreLicenseRepository"]

#: Collection names — the documented schema.
COLLECTIONS = {
    "customers": "customers",
    "devices": "devices",
    "licenses": "licenses",
    "audit": "audit_log",
}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _is_transaction_contention(exc: BaseException) -> bool:
    """True when the Firestore SDK gave up retrying an aborted transaction."""
    if type(exc).__name__ == "Aborted":
        return True
    return isinstance(exc, ValueError) and "Failed to commit transaction" in str(exc)


def _import_firestore() -> Any:
    """Import ``google.cloud.firestore`` lazily (deployment dependency)."""
    try:
        from google.cloud import firestore
    except ImportError as exc:  # pragma: no cover - deployment dependency
        raise StoreUnavailableError(
            "Firestore support is not installed on this host "
            "(pip install google-cloud-firestore)"
        ) from exc
    return firestore


def _storage_errors() -> tuple[type[BaseException], ...]:
    try:
        from google.api_core import exceptions as gexc

        return (gexc.GoogleAPIError,)
    except ImportError:  # pragma: no cover - deployment dependency
        return ()


class FirestoreLicenseRepository:
    """Transactional Firestore persistence for licenses and audit events."""

    def __init__(
        self,
        client: Any,
        cipher: ActivationCodeCipher,
        *,
        firestore_module: Any = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._firestore = firestore_module if firestore_module is not None else _import_firestore()
        self._db = client
        self._cipher = cipher
        self._storage_errors = _storage_errors()
        self._clock = clock or _now

    # -- construction --------------------------------------------------- #
    @classmethod
    def connect(
        cls,
        cipher: ActivationCodeCipher,
        *,
        project_id: str = "",
        database: str = "",
        credentials: Any = None,
        env: str = "development",
    ) -> FirestoreLicenseRepository:
        """Build a client from Application Default Credentials.

        Refuses to run against the local emulator in production: licences
        issued there would simply not exist in the real database.
        """
        if env == "production" and os.environ.get("FIRESTORE_EMULATOR_HOST"):
            raise StoreUnavailableError(
                "FIRESTORE_EMULATOR_HOST must never be set in production"
            )
        firestore = _import_firestore()
        kwargs: dict[str, Any] = {}
        if project_id:
            kwargs["project"] = project_id
        if database:
            kwargs["database"] = database
        if credentials is not None:
            kwargs["credentials"] = credentials
        try:
            client = firestore.Client(**kwargs)
        except Exception as exc:
            raise StoreUnavailableError(
                "the Firestore client could not be created"
            ) from exc
        return cls(client, cipher, firestore_module=firestore)

    # -- plumbing ------------------------------------------------------- #
    def _collection(self, name: str) -> Any:
        return self._db.collection(COLLECTIONS[name])

    def _run(self, operation: Callable[[], Any]) -> Any:
        """Translate provider failures into the controlled 503 error."""
        try:
            return operation()
        except ApiError:
            raise
        except self._storage_errors as exc:
            raise StoreUnavailableError(
                "the license store is temporarily unavailable"
            ) from exc

    def _document(self, name: str, document_id: str) -> Any:
        return self._collection(name).document(document_id)

    # -- mapping -------------------------------------------------------- #
    def _license_to_doc(self, draft: LicenseDraft) -> dict[str, Any]:
        issued = draft.issued
        return {
            "license_id": issued.license_id,
            "hw_hash": draft.hw_hash,
            "status": "active",
            "kind": "lifetime",
            "key_id": issued.key_id,
            "issued_at": issued.issued_at,
            "created_at": draft.created_at,
            "created_by": draft.created_by,
            "features": list(issued.features),
            "install_id": draft.install_id,
            "request_code": draft.request_code,
            "customer_id": draft.customer_id,
            "activation_code_sealed": self._cipher.seal(
                license_id=issued.license_id, code=issued.code
            ),
            "reissued_from": draft.reissued_from,
            "superseded_by": None,
            "revoked_at": None,
            "revoked_reason": None,
        }

    def _license_summary_from_doc(
        self, document_id: str, data: Mapping[str, Any]
    ) -> LicenseRecord:
        """A license record that never decrypts its activation code.

        Used by the dashboard listings, which only show status and metadata.
        Decrypting up to 500 codes per page would widen the window in which
        plaintext exists in memory for no gain, and a record sealed with an
        older key would otherwise break the whole list.
        """
        return LicenseRecord(
            license_id=str(data.get("license_id") or document_id),
            hw_hash=str(data["hw_hash"]),
            status=str(data.get("status") or "active"),  # type: ignore[arg-type]
            kind=str(data.get("kind") or "lifetime"),
            key_id=str(data["key_id"]),
            issued_at=data["issued_at"],
            created_at=data["created_at"],
            created_by=str(data.get("created_by") or ""),
            features=tuple(data.get("features") or ()),
            install_id=data.get("install_id"),
            request_code=data.get("request_code"),
            customer_id=data.get("customer_id"),
            activation_code="",
            reissued_from=data.get("reissued_from"),
            superseded_by=data.get("superseded_by"),
            revoked_at=data.get("revoked_at"),
            revoked_reason=data.get("revoked_reason"),
        )

    def _license_from_doc(self, document_id: str, data: Mapping[str, Any]) -> LicenseRecord:
        """A license record with its activation code decrypted (audited reads)."""
        sealed = data.get("activation_code_sealed")
        if not isinstance(sealed, str) or not sealed:
            raise StoreUnavailableError(
                "a stored license is missing its sealed activation code"
            )
        license_id = str(data.get("license_id") or document_id)
        return replace(
            self._license_summary_from_doc(document_id, data),
            activation_code=self._cipher.open(license_id=license_id, envelope=sealed),
        )

    @staticmethod
    def _device_to_doc(draft: LicenseDraft, *, first_seen_at: datetime) -> dict[str, Any]:
        return {
            "hw_hash": draft.hw_hash,
            "install_id": draft.install_id,
            "request_code": draft.request_code,
            "fingerprint_display_code": draft.fingerprint_display_code,
            "customer_id": draft.customer_id,
            "current_license_id": draft.issued.license_id,
            "first_seen_at": first_seen_at,
            "last_seen_at": draft.created_at,
        }

    @staticmethod
    def _device_from_doc(document_id: str, data: Mapping[str, Any]) -> DeviceRecord:
        return DeviceRecord(
            hw_hash=str(data.get("hw_hash") or document_id),
            first_seen_at=data.get("first_seen_at") or data.get("last_seen_at"),
            last_seen_at=data.get("last_seen_at"),
            install_id=data.get("install_id"),
            request_code=data.get("request_code"),
            fingerprint_display_code=data.get("fingerprint_display_code"),
            customer_id=data.get("customer_id"),
            current_license_id=data.get("current_license_id"),
        )

    @staticmethod
    def _audit_from_doc(document_id: str, data: Mapping[str, Any]) -> AuditEvent:
        return AuditEvent(
            event_id=str(data.get("event_id") or document_id),
            at=data.get("at"),
            action=str(data.get("action") or ""),
            actor_uid=str(data.get("actor_uid") or ""),
            actor_email=data.get("actor_email"),
            license_id=data.get("license_id"),
            hw_hash=data.get("hw_hash"),
            client_ip=data.get("client_ip"),
            details=dict(data.get("details") or {}),
        )

    @staticmethod
    def _audit_to_doc(event: AuditEvent) -> dict[str, Any]:
        return {
            "event_id": event.event_id,
            "at": event.at,
            "action": event.action,
            "actor_uid": event.actor_uid,
            "actor_email": event.actor_email,
            "license_id": event.license_id,
            "hw_hash": event.hw_hash,
            "client_ip": event.client_ip,
            "details": dict(event.details),
        }

    # -- reads ---------------------------------------------------------- #
    def get_customer(self, customer_id: str) -> Mapping[str, Any] | None:
        def read() -> Mapping[str, Any] | None:
            snapshot = self._document("customers", customer_id).get()
            return dict(snapshot.to_dict() or {}) if snapshot.exists else None

        return self._run(read)

    def get_device(self, hw_hash: str) -> DeviceRecord | None:
        def read() -> DeviceRecord | None:
            snapshot = self._document("devices", hw_hash).get()
            if not snapshot.exists:
                return None
            return self._device_from_doc(hw_hash, snapshot.to_dict() or {})

        return self._run(read)

    def get_license(self, license_id: str) -> LicenseRecord | None:
        def read() -> LicenseRecord | None:
            snapshot = self._document("licenses", license_id).get()
            if not snapshot.exists:
                return None
            return self._license_from_doc(license_id, snapshot.to_dict() or {})

        return self._run(read)

    def list_licenses_for_device(self, hw_hash: str) -> list[LicenseRecord]:
        def read() -> list[LicenseRecord]:
            query = self._collection("licenses").where(
                filter=self._firestore.FieldFilter("hw_hash", "==", hw_hash)
            )
            records = [
                self._license_summary_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]
            return sorted(records, key=lambda record: record.created_at, reverse=True)

        return self._run(read)

    # -- writes --------------------------------------------------------- #
    def upsert_customer(self, customer_id: str, document: Mapping[str, Any]) -> str:
        def write() -> str:
            self._document("customers", customer_id).set(dict(document), merge=True)
            return customer_id

        return self._run(write)

    def record_audit(self, event: AuditEvent) -> None:
        def write() -> None:
            self._document("audit", event.event_id).set(self._audit_to_doc(event))

        self._run(write)

    # -- dashboard reads (no activation code is ever read here) ---------- #
    def list_devices(self, limit: int) -> list[DeviceRecord]:
        def read() -> list[DeviceRecord]:
            query = (
                self._collection("devices")
                .order_by("last_seen_at", direction=self._firestore.Query.DESCENDING)
                .limit(limit)
            )
            return [
                self._device_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]

        return self._run(read)

    def list_licenses(self, limit: int) -> list[LicenseRecord]:
        def read() -> list[LicenseRecord]:
            query = (
                self._collection("licenses")
                .order_by("created_at", direction=self._firestore.Query.DESCENDING)
                .limit(limit)
            )
            return [
                self._license_summary_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]

        return self._run(read)

    def list_customers(self, limit: int) -> list[tuple[str, Mapping[str, Any]]]:
        def read() -> list[tuple[str, Mapping[str, Any]]]:
            documents = [
                (str(document.id), dict(document.to_dict() or {}))
                for document in self._collection("customers").limit(limit).stream()
            ]
            return sorted(documents, key=lambda item: str(item[1].get("name") or item[0]).lower())

        return self._run(read)

    def list_audit_events(self, limit: int) -> list[AuditEvent]:
        def read() -> list[AuditEvent]:
            query = (
                self._collection("audit")
                .order_by("at", direction=self._firestore.Query.DESCENDING)
                .limit(limit)
            )
            return [
                self._audit_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]

        return self._run(read)

    def list_devices_for_customer(self, customer_id: str) -> list[DeviceRecord]:
        def read() -> list[DeviceRecord]:
            query = self._collection("devices").where(
                filter=self._firestore.FieldFilter("customer_id", "==", customer_id)
            )
            return [
                self._device_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]

        return self._run(read)

    def list_licenses_for_customer(self, customer_id: str) -> list[LicenseRecord]:
        def read() -> list[LicenseRecord]:
            query = self._collection("licenses").where(
                filter=self._firestore.FieldFilter("customer_id", "==", customer_id)
            )
            records = [
                self._license_summary_from_doc(str(document.id), document.to_dict() or {})
                for document in query.stream()
            ]
            return sorted(records, key=lambda record: record.created_at, reverse=True)

        return self._run(read)

    def counts(self) -> Mapping[str, int]:
        def read() -> Mapping[str, int]:
            def total(name: str, field: str | None = None, value: Any = None) -> int:
                query = self._collection(name)
                if field is not None:
                    # Filter-based API: the positional
                    # ``where(field, op, value)`` overload is deprecated.
                    query = query.where(
                        filter=self._firestore.FieldFilter(field, "==", value)
                    )
                try:
                    return int(query.count().get()[0][0].value)
                except Exception:  # older SDK: count the documents instead
                    return sum(1 for _ in query.stream())

            return {
                "customers": total("customers"),
                "devices": total("devices"),
                "active_licenses": total("licenses", "status", "active"),
                "revoked_licenses": total("licenses", "status", "revoked"),
                "superseded_licenses": total("licenses", "status", "superseded"),
            }

        return self._run(read)

    # -- issuance (one transaction per device) --------------------------- #
    def create_or_get_license(
        self, *, hw_hash: str, build: Callable[[], LicenseDraft], make_audit: AuditFactory
    ) -> IssueOutcome:
        transaction = self._db.transaction()
        try:
            return self._run(
                lambda: self._firestore.transactional(self._create_or_get)(
                    transaction, hw_hash, build, make_audit
                )
            )
        except Exception as exc:
            # Heavy contention on one device document can exhaust the SDK's own
            # retries ("Failed to commit transaction in 5 attempts").  The
            # uniqueness invariant still holds -- a competing request won and
            # created the license -- so hand back the winner's license instead
            # of a 500.  Nothing is issued twice: no write happened at all.
            if not _is_transaction_contention(exc):
                raise
            existing = self._await_current_license(hw_hash)
            if existing is None:
                raise
            return IssueOutcome(license=existing, created=False)

    def _await_current_license(
        self, hw_hash: str, *, attempts: int = 15, delay: float = 0.2
    ) -> LicenseRecord | None:
        """Poll briefly for the license a competing request is committing.

        A transaction that aborted because another writer touched the device
        document may reach this read a few milliseconds before that writer's
        commit is visible, so a single read would occasionally return nothing.
        """
        for attempt in range(attempts):
            existing = self._run(lambda: self._current_license_for(hw_hash))
            if existing is not None:
                return existing
            if attempt + 1 < attempts:
                time.sleep(delay)
        return None

    def _current_license_for(self, hw_hash: str) -> LicenseRecord | None:
        """Non-transactional read of a device's current license."""
        snapshot = self._document("devices", hw_hash).get()
        if not snapshot.exists:
            return None
        current = self._device_from_doc(
            hw_hash, snapshot.to_dict() or {}
        ).current_license_id
        if not current:
            return None
        return self.get_license(current)

    def _create_or_get(
        self,
        transaction: Any,
        hw_hash: str,
        build: Callable[[], LicenseDraft],
        make_audit: AuditFactory,
    ) -> IssueOutcome:
        device_ref = self._document("devices", hw_hash)
        device_snapshot = device_ref.get(transaction=transaction)
        if device_snapshot.exists:
            device = self._device_from_doc(hw_hash, device_snapshot.to_dict() or {})
            if device.current_license_id:
                license_ref = self._document("licenses", device.current_license_id)
                license_snapshot = license_ref.get(transaction=transaction)
                if license_snapshot.exists:
                    existing = self._license_from_doc(
                        device.current_license_id, license_snapshot.to_dict() or {}
                    )
                    event = make_audit("license_existing_returned", existing.license_id)
                    transaction.set(
                        self._document("audit", event.event_id), self._audit_to_doc(event)
                    )
                    return IssueOutcome(license=existing, created=False)
            first_seen_at = device.first_seen_at
        else:
            first_seen_at = None

        draft = build()
        if draft.hw_hash != hw_hash:
            raise LicenseConflictError(
                "the signing inputs did not match the requested device"
            )
        license_ref = self._document("licenses", draft.issued.license_id)
        if license_ref.get(transaction=transaction).exists:
            raise LicenseConflictError(
                "a license with this id already exists; issue a new id"
            )
        transaction.set(license_ref, self._license_to_doc(draft))
        transaction.set(
            device_ref,
            self._device_to_doc(draft, first_seen_at=first_seen_at or draft.created_at),
        )
        event = make_audit("license_issued", draft.issued.license_id)
        transaction.set(self._document("audit", event.event_id), self._audit_to_doc(event))
        return IssueOutcome(
            license=draft.to_license_record(activation_code=draft.issued.code),
            created=True,
        )

    # -- reissue -------------------------------------------------------- #
    def reissue_license(
        self,
        *,
        previous_license_id: str,
        build: Callable[[], LicenseDraft],
        make_audit: AuditFactory,
    ) -> tuple[LicenseRecord, LicenseRecord]:
        transaction = self._db.transaction()
        return self._run(
            lambda: self._firestore.transactional(self._reissue)(
                transaction, previous_license_id, build, make_audit
            )
        )

    def _reissue(
        self,
        transaction: Any,
        previous_license_id: str,
        build: Callable[[], LicenseDraft],
        make_audit: AuditFactory,
    ) -> tuple[LicenseRecord, LicenseRecord]:
        previous_ref = self._document("licenses", previous_license_id)
        snapshot = previous_ref.get(transaction=transaction)
        if not snapshot.exists:
            raise LicenseNotFoundError("no license exists with this id")
        previous = self._license_from_doc(previous_license_id, snapshot.to_dict() or {})
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
            raise LicenseConflictError("a reissue must produce a new license id")

        # Firestore requires EVERY read in a transaction to precede every
        # write, so both remaining reads happen before the first ``set``.
        new_ref = self._document("licenses", draft.issued.license_id)
        if new_ref.get(transaction=transaction).exists:
            raise LicenseConflictError(
                "a license with this id already exists; issue a new id"
            )

        device_ref = self._document("devices", draft.hw_hash)
        device_snapshot = device_ref.get(transaction=transaction)
        first_seen_at = (
            self._device_from_doc(draft.hw_hash, device_snapshot.to_dict() or {}).first_seen_at
            if device_snapshot.exists
            else draft.created_at
        )

        # --- writes only from here on ------------------------------------- #
        transaction.set(new_ref, self._license_to_doc(draft))
        transaction.update(
            previous_ref,
            {"status": "superseded", "superseded_by": draft.issued.license_id},
        )
        transaction.set(
            device_ref, self._device_to_doc(draft, first_seen_at=first_seen_at)
        )

        for action, license_id in (
            ("license_superseded", previous.license_id),
            ("license_reissued", draft.issued.license_id),
        ):
            event = make_audit(action, license_id)
            transaction.set(self._document("audit", event.event_id), self._audit_to_doc(event))

        superseded = replace(
            previous, status="superseded", superseded_by=draft.issued.license_id
        )
        return superseded, draft.to_license_record(activation_code=draft.issued.code)

    # -- revocation ----------------------------------------------------- #
    def revoke_license(
        self,
        *,
        license_id: str,
        revocation: Revocation,
        make_audit: AuditFactory,
    ) -> LicenseRecord:
        transaction = self._db.transaction()
        return self._run(
            lambda: self._firestore.transactional(self._revoke)(
                transaction, license_id, revocation, make_audit
            )
        )

    def _revoke(
        self,
        transaction: Any,
        license_id: str,
        revocation: Revocation,
        make_audit: AuditFactory,
    ) -> LicenseRecord:
        reference = self._document("licenses", license_id)
        snapshot = reference.get(transaction=transaction)
        if not snapshot.exists:
            raise LicenseNotFoundError("no license exists with this id")
        record = self._license_from_doc(license_id, snapshot.to_dict() or {})
        if record.status == "revoked":
            return record
        if record.status != "active":
            raise LicenseConflictError(
                "only the current license can be revoked; this one was replaced"
            )
        fields = {
            "status": "revoked",
            "revoked_at": revocation.revoked_at,
            "revoked_reason": revocation.reason,
        }
        transaction.update(reference, fields)
        event = make_audit("license_revoked", license_id)
        transaction.set(self._document("audit", event.event_id), self._audit_to_doc(event))
        return LicenseRecord(
            license_id=record.license_id,
            hw_hash=record.hw_hash,
            status="revoked",
            kind=record.kind,
            key_id=record.key_id,
            issued_at=record.issued_at,
            created_at=record.created_at,
            created_by=record.created_by,
            features=record.features,
            install_id=record.install_id,
            request_code=record.request_code,
            customer_id=record.customer_id,
            activation_code=record.activation_code,
            reissued_from=record.reissued_from,
            superseded_by=record.superseded_by,
            revoked_at=revocation.revoked_at,
            revoked_reason=revocation.reason,
        )
