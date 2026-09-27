"""Supplier management service (Phase 11).

Business orchestration for supplier CRUD + soft-archive, with audit trail
writes for every mutation. Mirrors CustomerService (Phase 9).

Balance is NEVER mutated here — only PurchaseService (receive/cancel)
and SupplierLedgerService (payment) move ``suppliers.balance``, always
together with an append-only supplier_ledger_entries row (GATE 10).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.models.party import Supplier
from app.repositories.party import SupplierRepository
from app.schemas.party import SupplierCreateRequest, SupplierUpdateRequest
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

_UPDATABLE_FIELDS = frozenset(
    {"name", "phone", "address", "email", "contact_person", "notes"}
)


class SupplierService(BaseService):
    """Application service for supplier master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = SupplierRepository(db)

    # ── Reads ──────────────────────────────────────────────────────────

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        q: str | None = None,
        include_archived: bool = False,
    ) -> tuple[list[Supplier], int]:
        return self.repo.search(
            q=q,
            include_archived=include_archived,
            page=page,
            page_size=page_size,
        )

    def get(self, supplier_id: uuid.UUID) -> Supplier:
        """Fetch a supplier or raise a structured 404."""
        return self.repo.get_by_id_or_none(supplier_id)

    # ── Writes ─────────────────────────────────────────────────────────

    def create(
        self, request: SupplierCreateRequest, *, actor_id: uuid.UUID | None
    ) -> Supplier:
        """Create a supplier. Balance starts at 0 (server-side only).

        Duplicate names are allowed (customer/legacy parity — no unique
        constraint on supplier names; documented decision GATE 1).
        """
        with self.transaction():
            supplier = Supplier(
                name=request.name,
                phone=request.phone,
                address=request.address,
                email=request.email,
                contact_person=request.contact_person,
                notes=request.notes,
            )
            self.repo.create(supplier)
            self._audit(
                AuditAction.CREATE,
                entity_id=supplier.id,
                actor_id=actor_id,
                details=f"created supplier {supplier.name!r}",
            )
        logger.info("supplier_created", supplier_id=str(supplier.id))
        return supplier

    def update(
        self,
        supplier_id: uuid.UUID,
        request: SupplierUpdateRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> Supplier:
        """Partial update. Balance is not a client-writable field."""
        supplier = self.get(supplier_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)
        # Defense in depth: never allow balance/ledger state via CRUD.
        updates = {k: v for k, v in updates.items() if k in _UPDATABLE_FIELDS}

        if updates:
            with self.transaction():
                for key, value in updates.items():
                    setattr(supplier, key, value)
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=supplier.id,
                    actor_id=actor_id,
                    details="updated fields: " + ", ".join(sorted(updates)),
                )
            logger.info(
                "supplier_updated",
                supplier_id=str(supplier.id),
                fields=sorted(updates),
            )
        return supplier

    def archive(
        self, supplier_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> Supplier:
        """Soft-archive a supplier (blueprint: delete with retention).

        Restriction (blueprint L435-437): a supplier with an outstanding
        balance cannot be deleted/archived — purchase history keeps
        referencing the row, so destructive deletion is never an option.
        """
        supplier = self.get(supplier_id)
        balance = quantize_money(to_decimal(supplier.balance))

        if balance != 0:
            raise ConflictError(
                message="Supplier with outstanding balance cannot be archived",
                code="OUTSTANDING_SUPPLIER_BALANCE",
                details={
                    "supplier_id": str(supplier.id),
                    "balance": str(balance),
                    "reason": "outstanding_balance",
                },
            )

        if supplier.archived_at is None:
            with self.transaction():
                supplier.archived_at = datetime.now(timezone.utc)
                self._audit(
                    AuditAction.DELETE,
                    entity_id=supplier.id,
                    actor_id=actor_id,
                    details="archived supplier (soft delete)",
                )
            logger.info("supplier_archived", supplier_id=str(supplier.id))
        return supplier

    # ── Audit ──────────────────────────────────────────────────────────

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        Audit rows ride the same transaction as the mutation: a committed
        mutation always has its audit entry, and a rolled-back mutation
        leaves no orphan audit.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="supplier",
                entity_id=entity_id,
                details=details,
            )
        )
