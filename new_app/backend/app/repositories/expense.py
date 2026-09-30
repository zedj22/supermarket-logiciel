"""Expense repository (Phase 13).

Persistence-only queries for the ``expenses`` table (decision record §5).
The service owns every business rule; this module only reads, filters and
applies the status-guarded cancellation UPDATE.

Read model (§6):
- list: paginated, ordered ``expense_date DESC, id DESC`` (fixed — no
  client-sortable field), filters q / category / paid_from_drawer /
  date range / status (default ``posted``)
- summary: COUNT + SUM(amount) + SUM(amount WHERE drawer) — cancelled rows
  are excluded by default (B11). No device filtering (D5 deviation).
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

from sqlalchemy import case, func, or_, select, update

from app.domain.unit_conversions import to_decimal
from app.models.enums import ExpenseStatus
from app.models.expense import Expense
from app.repositories.base import BaseRepository

DEFAULT_STATUS = ExpenseStatus.POSTED.value


class ExpenseRepository(BaseRepository[Expense]):
    """Persistence for expense records."""

    model = Expense

    # ------------------------------------------------------------------
    # Filters (shared by list + summary)
    # ------------------------------------------------------------------

    @staticmethod
    def _filters(
        *,
        q: str | None = None,
        category: str | None = None,
        paid_from_drawer: bool | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        status: str | None = DEFAULT_STATUS,
    ) -> list:
        """Build the WHERE clause for one query (B12/B13, GATE 27)."""
        effective_status = status or DEFAULT_STATUS
        conditions: list = []

        if effective_status != "all":
            conditions.append(Expense.status == effective_status)

        if q:
            pattern = f"%{q.strip()}%"
            conditions.append(
                or_(Expense.title.ilike(pattern), Expense.note.ilike(pattern))
            )
        if category:
            conditions.append(Expense.category == category)
        if paid_from_drawer is not None:
            conditions.append(Expense.paid_from_drawer.is_(paid_from_drawer))

        if date_from is not None:
            conditions.append(
                Expense.expense_date
                >= datetime.combine(date_from, time.min, tzinfo=timezone.utc)
            )
        if date_to is not None:
            # Inclusive calendar day (B13): the whole of date_to counts.
            next_day = datetime.combine(
                date_to + timedelta(days=1), time.min, tzinfo=timezone.utc
            )
            conditions.append(Expense.expense_date < next_day)

        return conditions

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def search(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        q: str | None = None,
        category: str | None = None,
        paid_from_drawer: bool | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        status: str | None = DEFAULT_STATUS,
    ) -> tuple[list[Expense], int]:
        """Paginated expense list, newest first (GATE 12)."""
        conditions = self._filters(
            q=q,
            category=category,
            paid_from_drawer=paid_from_drawer,
            date_from=date_from,
            date_to=date_to,
            status=status,
        )
        stmt = select(self.model)
        if conditions:
            stmt = stmt.where(*conditions)

        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(
                    Expense.expense_date.desc(), Expense.id.desc()
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), int(total)

    def summary(
        self,
        *,
        q: str | None = None,
        category: str | None = None,
        paid_from_drawer: bool | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        status: str | None = DEFAULT_STATUS,
    ) -> tuple[int, Decimal, Decimal, Decimal]:
        """(count, total, drawer, external) over the filtered set.

        Cancelled rows are excluded unless ``status`` says otherwise
        (B11), so drawer + external always sums to total.
        """
        conditions = self._filters(
            q=q,
            category=category,
            paid_from_drawer=paid_from_drawer,
            date_from=date_from,
            date_to=date_to,
            status=status,
        )
        drawer_sum = func.coalesce(
            func.sum(
                case(
                    (Expense.paid_from_drawer.is_(True), Expense.amount),
                    else_=0,
                )
            ),
            0,
        )
        stmt = select(
            func.count(Expense.id),
            func.coalesce(func.sum(Expense.amount), 0),
            drawer_sum,
        )
        if conditions:
            stmt = stmt.where(*conditions)

        count, total, drawer = self.db.execute(stmt).one()
        total_d = to_decimal(total)
        drawer_d = to_decimal(drawer)
        return int(count or 0), total_d, drawer_d, total_d - drawer_d

    def find_by_client_request_id(
        self, client_request_id: str
    ) -> Expense | None:
        stmt = select(self.model).where(
            self.model.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    # ------------------------------------------------------------------
    # Writes (the service drives them inside one transaction)
    # ------------------------------------------------------------------

    def cancel(
        self,
        expense_id: uuid.UUID,
        *,
        reason: str,
        cancelled_by: uuid.UUID | None,
        cancelled_at: datetime,
    ) -> bool:
        """Status-guarded cancellation — posted → cancelled, never DELETE.

        Returns False when the row is missing or already cancelled, so a
        concurrent second cancellation loses the race cleanly (409).
        """
        result = self.db.execute(
            update(self.model)
            .where(
                self.model.id == expense_id,
                self.model.status == ExpenseStatus.POSTED.value,
            )
            .values(
                status=ExpenseStatus.CANCELLED.value,
                cancelled_at=cancelled_at,
                cancelled_by=cancelled_by,
                cancel_reason=reason,
            )
        )
        return bool(result.rowcount)
