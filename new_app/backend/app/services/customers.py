"""Customer management service (Phase 9).

Business orchestration for customer CRUD + soft-archive, with audit
trail writes for every mutation. Transactions are owned by the service
(``BaseService.transaction``). Balance is never mutated here — only
SaleService (credit sale) and DebtService (payment) touch it, always
together with a debt ledger entry.
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
from app.models.party import Customer
from app.repositories.party import CustomerRepository
from app.schemas.party import CustomerCreateRequest, CustomerUpdateRequest
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

_UPDATABLE_FIELDS = frozenset({"name", "phone", "address", "debt_ceiling"})


def _phone_digits(value: str) -> str:
    """Digits-only view of a phone string for conservative comparison."""
    return "".join(ch for ch in value if ch.isdigit())


class CustomerService(BaseService):
    """Application service for customer master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = CustomerRepository(db)

    # ── Reads ──────────────────────────────────────────────────────────

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        q: str | None = None,
        include_archived: bool = False,
        has_debt: bool = False,
    ) -> tuple[list[Customer], int]:
        return self.repo.search(
            q=q,
            include_archived=include_archived,
            has_debt=has_debt,
            page=page,
            page_size=page_size,
        )

    def get(self, customer_id: uuid.UUID) -> Customer:
        """Fetch a customer or raise a structured 404."""
        return self.repo.get_by_id_or_none(customer_id)

    def lookup_by_phone(
        self, digits: str, *, limit: int = 20
    ) -> tuple[list[Customer], int]:
        """Exact phone match after CONSERVATIVE digit normalization (Phase E).

        Both sides are compared as digits only, so ``0550 12 34 56``,
        ``0550-12-34-56`` and ``0550123456`` all match each other — but
        stored formats are never rewritten and no Algerian prefix
        handling (+213 / trunk 0) is applied: ``0550123456`` and
        ``+213550123456`` are different writings and deliberately do NOT
        match.  Duplicate phone numbers are a fact of life here, so the
        caller gets the full match list (up to ``limit``) plus the total
        count for a disambiguation UI.  Archived customers are excluded,
        mirroring the search contract.
        """
        from sqlalchemy import select

        rows = self.db.scalars(
            select(Customer)
            .where(
                Customer.archived_at.is_(None),
                Customer.phone.is_not(None),
            )
            .order_by(Customer.name.asc(), Customer.id.asc())
        ).all()
        matched = [
            c for c in rows if _phone_digits(c.phone) == digits
        ]
        return matched[:limit], len(matched)

    # ── Writes ─────────────────────────────────────────────────────────

    def create(
        self, request: CustomerCreateRequest, *, actor_id: uuid.UUID | None
    ) -> Customer:
        """Create a customer. Balance starts at 0 (server-side only)."""
        with self.transaction():
            customer = Customer(
                name=request.name,
                phone=request.phone,
                address=request.address,
                debt_ceiling=quantize_money(request.debt_ceiling),
            )
            self.repo.create(customer)
            self._audit(
                AuditAction.CREATE,
                entity_id=customer.id,
                actor_id=actor_id,
                details=f"created customer {customer.name!r}",
            )
        logger.info("customer_created", customer_id=str(customer.id))
        return customer

    def update(
        self,
        customer_id: uuid.UUID,
        request: CustomerUpdateRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> Customer:
        """Partial update. Balance is not a client-writable field."""
        customer = self.get(customer_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)
        # Defense in depth: the schema has no other fields, but never
        # allow balance/ledger state to be set through CRUD.
        updates = {k: v for k, v in updates.items() if k in _UPDATABLE_FIELDS}

        if "debt_ceiling" in updates:
            updates["debt_ceiling"] = quantize_money(updates["debt_ceiling"])

        if updates:
            with self.transaction():
                for key, value in updates.items():
                    setattr(customer, key, value)
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=customer.id,
                    actor_id=actor_id,
                    details="updated fields: " + ", ".join(sorted(updates)),
                )
            logger.info(
                "customer_updated",
                customer_id=str(customer.id),
                fields=sorted(updates),
            )
        return customer

    def archive(
        self, customer_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> Customer:
        """Soft-archive a customer (blueprint: delete with data retention).

        Restriction: a customer with an outstanding balance cannot be
        archived — sales history keeps referencing the customer row, so
        destructive deletion is never an option.
        """
        customer = self.get(customer_id)
        balance = quantize_money(to_decimal(customer.balance))

        if balance != 0:
            raise ConflictError(
                message="Customer with outstanding debt cannot be archived",
                code="OUTSTANDING_DEBT",
                details={
                    "customer_id": str(customer.id),
                    "balance": str(balance),
                    "reason": "outstanding_balance",
                },
            )

        if customer.archived_at is None:
            with self.transaction():
                customer.archived_at = datetime.now(timezone.utc)
                self._audit(
                    AuditAction.DELETE,
                    entity_id=customer.id,
                    actor_id=actor_id,
                    details="archived customer (soft delete)",
                )
            logger.info("customer_archived", customer_id=str(customer.id))
        return customer

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
        leaves no orphan audit. Failures propagate (they roll back the
        operation) because customer mutations are auditable actions.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="customer",
                entity_id=entity_id,
                details=details,
            )
        )
