"""Debt ledger service (Phase 9).

Owns the only paths that change a customer balance *besides* a credit
sale: recording debt payments. Every balance change is written together
with an append-only ledger entry in one transaction (Phase 0 rule).

Conventions mirrored from SaleService:
- Decimal arithmetic, quantized to NUMERIC(18,3) — never float math.
- Optimistic idempotency via ``client_request_id`` (unique column): a
  repeated payment command returns the original entry instead of
  deducting twice.
- Row-level lock (``SELECT ... FOR UPDATE``) serializes concurrent
  payments for the same customer.

Overpayment policy: rejected. A payment may never exceed the outstanding
balance, so the balance can never go negative and no advance-credit
semantics are invented. This matches the verified legacy guard in
``python_app/gui/main_window.py`` ("Cannot pay more than the current
debt") and Phase 0 §payment rules ("payment must not silently create a
negative balance").
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
from app.models.debt import DebtLedgerEntry
from app.models.enums import AuditAction
from app.repositories.debt import DebtLedgerEntryRepository
from app.repositories.party import CustomerRepository
from app.schemas.party import DebtPaymentRequest, DebtPaymentResponse
from app.services.base import BaseService
from app.services.loyalty import LoyaltyEngine

logger = structlog.get_logger(__name__)


class DebtService(BaseService):
    """Application service for customer debt (payments + history)."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.customers = CustomerRepository(db)
        self.ledger = DebtLedgerEntryRepository(db)

    # ── Reads ──────────────────────────────────────────────────────────

    def history(
        self,
        customer_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[DebtLedgerEntry], int]:
        """Paginated debt history for one customer (newest first).

        Raises a structured 404 for an unknown customer rather than
        returning an empty page (blueprint: customer routes 404).
        """
        if self.customers.get_by_id(customer_id) is None:
            raise NotFoundError(
                message="Customer not found",
                details={"customer_id": str(customer_id)},
            )
        return self.ledger.history_for_customer(
            customer_id, page=page, page_size=page_size
        )

    def summary(self) -> tuple[object, int]:
        """Total outstanding debt + debtor count across customers."""
        return self.customers.total_outstanding()

    def balance_after_map(
        self, customer_id: uuid.UUID
    ) -> dict[uuid.UUID, Decimal]:
        """Running balance after each ledger entry (computed read model).

        Returned separately from history() so the page of entries can be
        merged with full-history balances without changing that contract.
        """
        return self.ledger.balance_after_map(customer_id)

    # ── Payments ───────────────────────────────────────────────────────

    def pay(
        self,
        customer_id: uuid.UUID,
        request: DebtPaymentRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> DebtPaymentResponse:
        """Record a debt payment atomically.

        Ledger append + balance update + audit row commit together or
        roll back together.
        """
        crid = request.client_request_id

        # Fast-path idempotency: the same command already succeeded.
        if crid is not None:
            existing = self.ledger.find_by_client_request_id(crid)
            if existing is not None:
                return self._replay(existing, expected_customer_id=customer_id)

        try:
            return self._record(customer_id, request, actor_id=actor_id)
        except ConflictError:
            # Unique client_request_id race: another request won between
            # the fast-path check and our insert — return theirs.
            if crid is not None:
                winner = self.ledger.find_by_client_request_id(crid)
                if winner is not None:
                    logger.info(
                        "debt_payment_idempotent_race_replay",
                        client_request_id=crid,
                        entry_id=str(winner.id),
                    )
                    return self._replay(
                        winner, expected_customer_id=customer_id, raced=True
                    )
            raise

    def _record(
        self,
        customer_id: uuid.UUID,
        request: DebtPaymentRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> DebtPaymentResponse:
        with self.transaction() as tx:
            # Row lock: concurrent payments for this customer serialize.
            customer = self.customers.get_for_update(customer_id)
            if customer is None:
                raise NotFoundError(
                    message="Customer not found",
                    details={"customer_id": str(customer_id)},
                )
            if customer.archived_at is not None:
                raise BusinessRuleError(
                    message="Archived customers cannot receive payments",
                    code="CUSTOMER_ARCHIVED",
                    details={"customer_id": str(customer_id)},
                )

            balance = quantize_money(to_decimal(customer.balance))
            amount = quantize_money(to_decimal(request.amount))
            if amount <= 0:
                raise BusinessRuleError(
                    message="Payment amount must be greater than zero",
                    code="PAYMENT_AMOUNT_INVALID",
                    details={"amount": str(amount)},
                )
            if amount > balance:
                # Legacy-verified rule: never allow overpayment (no
                # negative balance, no invented advance semantics).
                raise BusinessRuleError(
                    message="Payment amount exceeds the outstanding balance",
                    code="PAYMENT_EXCEEDS_BALANCE",
                    details={
                        "amount": str(amount),
                        "balance": str(balance),
                    },
                )

            new_balance = quantize_money(balance - amount)
            entry = DebtLedgerEntry(
                customer_id=customer.id,
                entry_type="payment",
                amount=amount,
                note=request.note,
                client_request_id=request.client_request_id,
                user_id=actor_id,
            )
            tx.add(entry)
            customer.balance = new_balance
            tx.add(
                AuditLog(
                    user_id=actor_id,
                    action=AuditAction.PAYMENT.value,
                    entity_type="customer",
                    entity_id=customer.id,
                    details=(
                        f"debt payment {amount} "
                        f"(balance {balance} -> {new_balance})"
                    ),
                )
            )
            tx.flush()
            entry_id = entry.id

            # Phase D: loyalty earn on the amount actually applied to the
            # debt, in the SAME transaction as the payment.  Lock order:
            # customer row (FOR UPDATE, above) → loyalty account (inside
            # engine.post) — sale/customer always before the account.
            # Idempotency: a replayed client_request_id returns before
            # _record ever runs, a unique-id race fails at the flush
            # above before this block, and source_event_key
            # ``debt_settle:{entry_id}`` makes a second award for the same
            # ledger entry impossible even if a caller retries the post.
            engine = LoyaltyEngine(self.db)
            settings = engine.settings_snapshot()
            if settings["earn_on_debt_settlement"]:
                rewards = engine.calculate_earn(
                    qualifying_amount=amount, settings=settings
                )
                if rewards.points > 0 or rewards.cashback > 0:
                    engine.post(
                        customer_id=customer.id,
                        event_type="debt_settlement_earn",
                        source_event_key=f"debt_settle:{entry_id}",
                        points_delta=rewards.points,
                        cashback_delta=rewards.cashback,
                        created_by=actor_id,
                        note=f"Debt payment {amount}",
                    )

        # Re-read after commit so the server-side entry_date default is
        # populated (same pattern as SaleService re-reading the sale).
        saved = self.ledger.get_by_id(entry_id)
        if saved is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Payment committed but could not be re-read",
                details={"entry_id": str(entry_id)},
            )
        entry_date = saved.entry_date

        logger.info(
            "debt_payment_recorded",
            customer_id=str(customer_id),
            amount=str(amount),
            balance_after=str(new_balance),
            idempotent=bool(request.client_request_id),
        )
        return DebtPaymentResponse(
            id=entry_id,
            customer_id=customer_id,
            entry_type="payment",
            amount=amount,
            balance=new_balance,
            note=request.note,
            client_request_id=request.client_request_id,
            entry_date=entry_date,
            idempotent_replay=False,
        )

    def _replay(
        self,
        entry: DebtLedgerEntry,
        *,
        expected_customer_id: uuid.UUID,
        raced: bool = False,
    ) -> DebtPaymentResponse:
        """Return the original result of an already-processed command."""
        if entry.customer_id != expected_customer_id:
            raise ConflictError(
                message="client_request_id was already used for another customer",
                details={
                    "client_request_id": entry.client_request_id,
                    "customer_id": str(entry.customer_id),
                },
            )
        customer = self.customers.get_by_id(entry.customer_id)
        if customer is None:  # pragma: no cover — FK guarantees existence
            raise NotFoundError(
                message="Customer not found",
                details={"customer_id": str(entry.customer_id)},
            )
        return DebtPaymentResponse(
            id=entry.id,
            customer_id=entry.customer_id,
            entry_type=entry.entry_type,
            amount=quantize_money(to_decimal(entry.amount)),
            balance=quantize_money(to_decimal(customer.balance)),
            note=entry.note,
            client_request_id=entry.client_request_id,
            entry_date=entry.entry_date,
            idempotent_replay=True,
        )
