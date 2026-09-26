"""Debt ledger persistence (Phase 9).

The ledger is append-only — there is no update/delete path here, only
inserts (via the service) and the read models needed for history,
idempotent payment replay, and projection reconciliation.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.debt import DebtLedgerEntry
from app.repositories.base import BaseRepository


class DebtLedgerEntryRepository(BaseRepository[DebtLedgerEntry]):
    model = DebtLedgerEntry

    def history_for_customer(
        self,
        customer_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[DebtLedgerEntry], int]:
        """Paginated ledger history, newest first.

        Ordered by entry_date DESC with id DESC as a stable tie-breaker
        (entry_date is a transaction timestamp, so ties are common).
        """
        stmt = select(self.model).where(self.model.customer_id == customer_id)
        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(
                    self.model.entry_date.desc(), self.model.id.desc()
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total

    def find_by_client_request_id(
        self, client_request_id: str
    ) -> DebtLedgerEntry | None:
        stmt = select(self.model).where(
            self.model.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def balance_after_map(
        self, customer_id: uuid.UUID
    ) -> dict[uuid.UUID, Decimal]:
        """Running debt balance AFTER every entry of one customer.

        Chronological prefix sum mirroring ledger_sum_for_customer: sale
        adds, payment subtracts, any other entry type (adjustment)
        contributes zero. Computed here (not stored) so the append-only
        ledger model and schema stay untouched; each step is quantized
        to NUMERIC(18,3) so values match customers.balance exactly.
        """
        rows = self.db.execute(
            select(
                self.model.id,
                self.model.entry_type,
                self.model.amount,
            )
            .where(self.model.customer_id == customer_id)
            .order_by(self.model.entry_date.asc(), self.model.id.asc())
        ).all()
        running = Decimal("0")
        result: dict[uuid.UUID, Decimal] = {}
        for entry_id, entry_type, amount in rows:
            value = to_decimal(amount)
            if entry_type == "sale":
                running += value
            elif entry_type == "payment":
                running -= value
            result[entry_id] = quantize_money(running)
        return result

    def ledger_sum_for_customer(self, customer_id: uuid.UUID) -> Decimal:
        """Authoritative debt from entries: sales - payments.

        Used to reconcile customers.balance (the cached projection)
        against the append-only ledger in tests and diagnostics.
        """
        rows = self.db.execute(
            select(
                self.model.entry_type,
                func.coalesce(func.sum(self.model.amount), 0),
            )
            .where(self.model.customer_id == customer_id)
            .group_by(self.model.entry_type)
        ).all()
        totals = {entry_type: to_decimal(amount) for entry_type, amount in rows}
        return totals.get("sale", Decimal("0")) - totals.get(
            "payment", Decimal("0")
        )
