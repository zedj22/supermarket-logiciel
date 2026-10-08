"""Invoice client service (Phase 3 — facturation service foundation).

Business orchestration for the ``invoice_clients`` master: create, get,
list/search, update, archive, unarchive, plus the new-document
availability check that later document phases will call.

Domain isolation (Phase 0/2 integration decisions — hard rules)
----------------------------------------------------------------
- The invoice client is the fiscal/document identity of factura_simple
  (name + NIF / RC / AI / NIS). The POS ``Customer`` is the debt/ledger
  master. They are fully separate: no ``customer_id`` exists here,
  Customer rows are never read or written, and no polymorphic party
  abstraction is introduced.
- There is no delete method: hard deletion is a database decision
  (FK RESTRICT on ``invoice_documents.client_id``), never an application
  command. Archiving is the only removal path.

Scope (Phase 3): service/domain only — no FastAPI schemas, routers or
endpoints (those belong to the API phase). Callers pass keyword
arguments; validation therefore lives here, following the project's
structured-error conventions (``app.core.exceptions``):

- ``name`` is required (the only required factura_simple field), trimmed,
  blank rejected, length-guarded to the Phase 2 column (200).
- Every optional string is trimmed and blank becomes NULL. The source
  stores ``""``; the Phase 2 schema is nullable, so NULL is the SP form.
- Column length guards mirror the schema (wilaya 100, phone/nif/rc/ai/nis
  30, address TEXT unbounded) so PostgreSQL never turns an overlong value
  into a 500 (SQLite would silently accept it).
- Duplicates are ALLOWED — name, phone and fiscal identifiers: neither
  the source nor the Phase 2 schema has any unique constraint, and fiscal
  identifiers are stored exactly as given (after trimming).

Archive policy: soft archive only, idempotent in both directions.
Archiving a client that documents still reference is ALLOWED — the
relationship is kept (FK RESTRICT already blocks hard deletes) and
existing documents stay valid; only attaching the client to a NEW
document is refused (``ensure_usable_for_new_document`` → 422
``INVOICE_CLIENT_ARCHIVED``).

Transactions and audit follow CustomerService: the service owns the
transaction (``BaseService.transaction``) and every mutation appends one
``audit_logs`` row in the same transaction (entity_type
``invoice_client``).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

import structlog
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.exceptions import BusinessRuleError, ValidationError
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.models.facturation import InvoiceClient, InvoiceDocument
from app.repositories.facturation import InvoiceClientRepository
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

_NAME_MAX_LENGTH = 200

_OPTIONAL_FIELD_MAX_LENGTH: dict[str, int | None] = {
    "address": None,
    "wilaya": 100,
    "phone": 30,
    "nif": 30,
    "rc": 30,
    "ai": 30,
    "nis": 30,
}


class _Unset:
    """Sentinel type: a field was NOT supplied (vs an explicit None)."""

    def __repr__(self) -> str:
        return "UNSET"


_UNSET = _Unset()


def _clean_name(value: Any) -> str:
    """Validate and trim the required name (single required field)."""
    if value is None:
        raise ValidationError(
            message="name is required",
            details={"field": "name"},
        )
    if not isinstance(value, str):
        raise ValidationError(
            message="name must be a string",
            details={"field": "name"},
        )
    name = value.strip()
    if not name:
        raise ValidationError(
            message="name must not be blank",
            details={"field": "name"},
        )
    if len(name) > _NAME_MAX_LENGTH:
        raise ValidationError(
            message=f"name must be at most {_NAME_MAX_LENGTH} characters",
            details={"field": "name", "max_length": _NAME_MAX_LENGTH},
        )
    return name


def _clean_optional(value: Any, *, field: str, max_length: int | None) -> str | None:
    """Validate and trim one optional string; blank becomes NULL."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValidationError(
            message=f"{field} must be a string",
            details={"field": field},
        )
    stripped = value.strip()
    if not stripped:
        return None
    if max_length is not None and len(stripped) > max_length:
        raise ValidationError(
            message=f"{field} must be at most {max_length} characters",
            details={"field": field, "max_length": max_length},
        )
    return stripped


class InvoiceClientService(BaseService):
    """Application service for invoice (fiscal) client master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = InvoiceClientRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        q: str | None = None,
        include_archived: bool = False,
    ) -> tuple[list[InvoiceClient], int]:
        """Paginated list; ``q`` searches name/phone (list doubles as search)."""
        return self.repo.search(
            q=q,
            include_archived=include_archived,
            page=page,
            page_size=page_size,
        )

    def get(self, client_id: uuid.UUID) -> InvoiceClient:
        """Fetch an invoice client or raise a structured 404."""
        return self.repo.get_by_id_or_none(client_id)

    def has_documents(self, client_id: uuid.UUID) -> bool:
        """True when at least one invoice document references the client."""
        client = self.get(client_id)
        count = (
            self.db.scalar(
                select(func.count())
                .select_from(InvoiceDocument)
                .where(InvoiceDocument.client_id == client.id)
            )
            or 0
        )
        return count > 0

    def ensure_usable_for_new_document(self, client_id: uuid.UUID) -> InvoiceClient:
        """Return a client usable for a NEW document.

        Unknown id → structured 404 (source parity: the source's document
        endpoints answer 404 for an unknown client_id). Archived client →
        422 ``INVOICE_CLIENT_ARCHIVED``: existing documents keep their
        relationship, only new attachments are refused.
        """
        client = self.get(client_id)
        if client.archived_at is not None:
            raise BusinessRuleError(
                message="Archived invoice clients cannot receive new documents",
                code="INVOICE_CLIENT_ARCHIVED",
                details={"client_id": str(client.id)},
            )
        return client

    def create(
        self,
        *,
        name: str | None = None,
        address: str | None = None,
        wilaya: str | None = None,
        phone: str | None = None,
        nif: str | None = None,
        rc: str | None = None,
        ai: str | None = None,
        nis: str | None = None,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceClient:
        """Create an invoice client (``name`` is the only required field)."""
        values: dict[str, Any] = {"name": _clean_name(name)}
        values.update(
            {
                field: _clean_optional(
                    value,
                    field=field,
                    max_length=_OPTIONAL_FIELD_MAX_LENGTH[field],
                )
                for field, value in (
                    ("address", address),
                    ("wilaya", wilaya),
                    ("phone", phone),
                    ("nif", nif),
                    ("rc", rc),
                    ("ai", ai),
                    ("nis", nis),
                )
            }
        )

        with self.transaction():
            client = InvoiceClient(**values)
            self.repo.create(client)
            self._audit(
                AuditAction.CREATE,
                entity_id=client.id,
                actor_id=actor_id,
                details=f"created invoice client {client.name!r}",
            )
        logger.info("invoice_client_created", client_id=str(client.id))
        return client

    def update(
        self,
        client_id: uuid.UUID,
        *,
        name: str | None | _Unset = _UNSET,
        address: str | None | _Unset = _UNSET,
        wilaya: str | None | _Unset = _UNSET,
        phone: str | None | _Unset = _UNSET,
        nif: str | None | _Unset = _UNSET,
        rc: str | None | _Unset = _UNSET,
        ai: str | None | _Unset = _UNSET,
        nis: str | None | _Unset = _UNSET,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceClient:
        """Partial update: only supplied fields change, unset stays put.

        An explicit ``None`` (or blank string) clears an optional field to
        NULL; an explicit ``None``/blank for ``name`` is rejected (name is
        required and NOT NULL). Supplying no fields is a no-op — the row
        is returned untouched and no audit row is written.
        """
        client = self.get(client_id)

        raw: dict[str, Any] = {
            "name": name,
            "address": address,
            "wilaya": wilaya,
            "phone": phone,
            "nif": nif,
            "rc": rc,
            "ai": ai,
            "nis": nis,
        }
        updates = {field: value for field, value in raw.items() if not isinstance(value, _Unset)}

        if "name" in updates:
            updates["name"] = _clean_name(updates["name"])
        for field, max_length in _OPTIONAL_FIELD_MAX_LENGTH.items():
            if field in updates:
                updates[field] = _clean_optional(
                    updates[field],
                    field=field,
                    max_length=max_length,
                )

        if updates:
            with self.transaction():
                for field, value in updates.items():
                    setattr(client, field, value)
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="updated fields: " + ", ".join(sorted(updates)),
                )
            logger.info(
                "invoice_client_updated",
                client_id=str(client.id),
                fields=sorted(updates),
            )
        return client

    def archive(self, client_id: uuid.UUID, *, actor_id: uuid.UUID | None = None) -> InvoiceClient:
        """Soft-archive an invoice client (data retention, never a delete).

        ALLOWED even while documents reference the client — the
        relationship is kept and existing documents stay valid; only new
        documents are refused (``ensure_usable_for_new_document``).
        Idempotent: archiving an archived client is a no-op.
        """
        client = self.get(client_id)
        if client.archived_at is None:
            with self.transaction():
                client.archived_at = datetime.now(timezone.utc)
                self._audit(
                    AuditAction.DELETE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="archived invoice client (soft delete)",
                )
            logger.info("invoice_client_archived", client_id=str(client.id))
        return client

    def unarchive(
        self, client_id: uuid.UUID, *, actor_id: uuid.UUID | None = None
    ) -> InvoiceClient:
        """Restore a soft-archived invoice client. Idempotent."""
        client = self.get(client_id)
        if client.archived_at is not None:
            with self.transaction():
                client.archived_at = None
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="unarchived invoice client",
                )
            logger.info("invoice_client_unarchived", client_id=str(client.id))
        return client

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        Audit rows ride the same transaction as the mutation (the
        CustomerService contract): a committed mutation always has its
        audit entry, and a rolled-back mutation leaves no orphan audit.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="invoice_client",
                entity_id=entity_id,
                details=details,
            )
        )
