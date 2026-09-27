"""Supplier ledger service (Phase 11).

Owns the only path that changes a supplier balance *besides* purchase
receive/cancel: recording supplier payments. Every balance change is
written together with an append-only ledger entry in one transaction.

Conventions mirrored from DebtService (Phase 9):
- Decimal arithmetic, quantized to NUMERIC(18,3) — never float math.
- Optimistic idempotency via ``client_request_id`` (unique column): a
  repeated payment command returns the original entry instead of
  deducting twice.
- Row-level lock (``SELECT ... FOR UPDATE``) serializes concurrent
  payments for the same supplier.

Overpayment policy: rejected (GATE 10). A payment may never exceed the
outstanding balance, so the balance can never go negative and no
supplier advance semantics are invented — same verified rule as customer
debt payments and legacy ``record_supplier_payment`` ("المبلغ أكبر من
رصيد المورد").
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import BusinessRuleError, ConflictError, NotFoundError
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.models.supplier_ledger import SupplierLedgerEntry
from app.repositories.party import SupplierRepository
from app.repositories.purchase import SupplierLedgerEntryRepository
from app.schemas.party import SupplierPaymentRequest, SupplierPaymentResponse
from app.services.base import BaseService

logger = structlog.get_logger(__name__)


class SupplierLedgerService(BaseService):
    """Application service for supplier payables (history + payments)."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.suppliers = SupplierRepository(db)
        self.ledger = SupplierLedgerEntryRepository(db)

    # ── Reads ──────────────────────────────────────────────────────────

    def history(
        self,
        supplier_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[SupplierLedgerEntry], int]:
        """Paginated ledger history for one supplier (newest first).

        Raises a structured 404 for an unknown supplier rather than
        returning an empty page (customer routes parity).
        """
        if self.suppliers.get_by_id(supplier_id) is None:
            raise NotFoundError(
                message="Supplier not found",
                details={"supplier_id": str(supplier_id)},
            )
        return self.ledger.history_for_supplier(
            supplier_id, page=page, page_size=page_size
        )

    def balance_after_map(
        self, supplier_id: uuid.UUID
    ) -> dict[uuid.UUID, Decimal]:
        """Running balance after each ledger entry (computed read model)."""
        return self.ledger.balance_after_map(supplier_id)

    # ── Payments ───────────────────────────────────────────────────────

    def pay(
        self,
        supplier_id: uuid.UUID,
        request: SupplierPaymentRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> SupplierPaymentResponse:
        """Record a supplier payment atomically.

        Ledger append + balance update + audit row commit together or
        roll back together.
        """
        crid = request.client_request_id

        # Fast-path idempotency: the same command already succeeded.
        if crid is not None:
            existing = self.ledger.find_by_client_request_id(crid)
            if existing is not None:
                return self._replay(existing, expected_supplier_id=supplier_id)

        try:
            return self._record(supplier_id, request, actor_id=actor_id)
        except ConflictError:
            # Unique client_request_id race: another request won between
            # the fast-path check and our insert — return theirs.
            if crid is not None:
                winner = self.ledger.find_by_client_request_id(crid)
                if winner is not None:
                    logger.info(
                        "supplier_payment_idempotent_race_replay",
                        client_request_id=crid,
                        entry_id=str(winner.id),
                    )
                    return self._replay(
                        winner, expected_supplier_id=supplier_id, raced=True
                    )
            raise

    def _record(
        self,
        supplier_id: uuid.UUID,
        request: SupplierPaymentRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> SupplierPaymentResponse:
        with self.transaction() as tx:
            # Row lock: concurrent payments for this supplier serialize.
            supplier = self.suppliers.get_for_update(supplier_id)
            if supplier is None:
                raise NotFoundError(
                    message="Supplier not found",
                    details={"supplier_id": str(supplier_id)},
                )
            if supplier.archived_at is not None:
                raise BusinessRuleError(
                    message="Archived suppliers cannot receive payments",
                    code="SUPPLIER_ARCHIVED",
                    details={"supplier_id": str(supplier_id)},
                )

            balance = quantize_money(to_decimal(supplier.balance))
            amount = quantize_money(to_decimal(request.amount))
            if amount <= 0:
                raise BusinessRuleError(
                    message="Payment amount must be greater than zero",
                    code="SUPPLIER_PAYMENT_AMOUNT_INVALID",
                    details={"amount": str(amount)},
                )
            if amount > balance:
                # Legacy-verified rule: never allow overpayment.
                raise BusinessRuleError(
                    message="Payment amount exceeds the outstanding balance",
                    code="SUPPLIER_PAYMENT_EXCEEDS_BALANCE",
                    details={
                        "amount": str(amount),
                        "balance": str(balance),
                    },
                )

            new_balance = quantize_money(balance - amount)
            entry = SupplierLedgerEntry(
                supplier_id=supplier.id,
                entry_type="payment",
                amount=amount,
                note=request.note,
                client_request_id=request.client_request_id,
                user_id=actor_id,
            )
            tx.add(entry)
            supplier.balance = new_balance
            tx.add(
                AuditLog(
                    user_id=actor_id,
                    action=AuditAction.PAYMENT.value,
                    entity_type="supplier",
                    entity_id=supplier.id,
                    details=(
                        f"supplier payment {amount} "
                        f"(balance {balance} -> {new_balance})"
                    ),
                )
            )
            tx.flush()
            entry_id = entry.id

        # Re-read after commit so the server-side entry_date default is
        # populated (DebtService pattern).
        saved = self.ledger.get_by_id(entry_id)
        if saved is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Payment committed but could not be re-read",
                details={"entry_id": str(entry_id)},
            )

        logger.info(
            "supplier_payment_recorded",
            supplier_id=str(supplier_id),
            amount=str(amount),
            balance_after=str(new_balance),
            idempotent=bool(request.client_request_id),
        )
        return SupplierPaymentResponse(
            id=entry_id,
            supplier_id=supplier_id,
            entry_type="payment",
            amount=amount,
            balance=new_balance,
            note=request.note,
            client_request_id=request.client_request_id,
            entry_date=saved.entry_date,
            idempotent_replay=False,
        )

    def _replay(
        self,
        entry: SupplierLedgerEntry,
        *,
        expected_supplier_id: uuid.UUID,
        raced: bool = False,
    ) -> SupplierPaymentResponse:
        """Return the original result of an already-processed command."""
        if entry.supplier_id != expected_supplier_id:
            raise ConflictError(
                message="client_request_id was already used for another supplier",
                details={
                    "client_request_id": entry.client_request_id,
                    "supplier_id": str(entry.supplier_id),
                },
            )
        supplier = self.suppliers.get_by_id(entry.supplier_id)
        if supplier is None:  # pragma: no cover — FK guarantees existence
            raise NotFoundError(
                message="Supplier not found",
                details={"supplier_id": str(entry.supplier_id)},
            )
        return SupplierPaymentResponse(
            id=entry.id,
            supplier_id=entry.supplier_id,
            entry_type=entry.entry_type,
            amount=quantize_money(to_decimal(entry.amount)),
            balance=quantize_money(to_decimal(supplier.balance)),
            note=entry.note,
            client_request_id=entry.client_request_id,
            entry_date=entry.entry_date,
            idempotent_replay=True,
        )
