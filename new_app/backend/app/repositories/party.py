"""Customer + supplier persistence (Phase 9 customers, Phase 11 suppliers).

Reuses the read surface Phase 8 shipped (search/list ordering stays
identical so the POS picker contract does not regress) and adds the
write-side helpers needed by customer management: row-locked fetch for
concurrent balance updates and the AR summary aggregate.

SupplierRepository mirrors CustomerRepository (Phase 11): name/phone
search, row-locked fetch for payables serialization.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.domain.unit_conversions import to_decimal
from app.models.party import Customer, Supplier
from app.repositories.base import BaseRepository


class CustomerRepository(BaseRepository[Customer]):
    model = Customer

    @staticmethod
    def _base_stmt(q: str | None, include_archived: bool, has_debt: bool = False):
        stmt = select(Customer)
        if not include_archived:
            stmt = stmt.where(Customer.archived_at.is_(None))
        if q:
            pattern = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(
                    Customer.name.ilike(pattern),
                    Customer.phone.ilike(pattern),
                )
            )
        if has_debt:
            stmt = stmt.where(Customer.balance > 0)
        return stmt

    def search(
        self,
        *,
        q: str | None = None,
        include_archived: bool = False,
        has_debt: bool = False,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[Customer], int]:
        """Paginated name/phone search.

        Ordering is deterministic: name ASC, then id as a stable
        tie-breaker so pagination never repeats or skips rows.
        ``has_debt=True`` narrows the list to debtors (balance > 0) for
        the debts screen; archived customers always carry balance 0 so
        they are naturally excluded.
        """
        stmt = self._base_stmt(q, include_archived, has_debt)
        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(Customer.name, Customer.id)
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total

    def get_for_update(self, customer_id: uuid.UUID) -> Customer | None:
        """Fetch a customer with a row-level lock (balance serialization).

        Two concurrent debt payments must not read the same balance and
        write it twice; the lock serializes them. PostgreSQL takes the
        lock; SQLite (unit tests) ignores FOR UPDATE but still runs
        inside a single writer transaction.
        """
        stmt = (
            select(Customer)
            .where(Customer.id == customer_id)
            .with_for_update()
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def total_outstanding(self) -> tuple[Decimal, int]:
        """AR summary: sum of positive balances + count of debtors.

        Archived customers always carry balance 0 (archiving is blocked
        with outstanding debt), so they can never inflate this figure.
        """
        total = self.db.scalar(
            select(func.coalesce(func.sum(Customer.balance), 0)).where(
                Customer.balance > 0
            )
        )
        count = self.db.scalar(
            select(func.count()).where(Customer.balance > 0)
        ) or 0
        return to_decimal(total), int(count)


class SupplierRepository(BaseRepository[Supplier]):
    """Supplier master persistence (Phase 11).

    Mirrors CustomerRepository: name/phone ``q`` search, deterministic
    ordering (name ASC, id tie-break), and a row-locked fetch used to
    serialize concurrent balance updates (receive / payment / cancel).
    """

    model = Supplier

    @staticmethod
    def _base_stmt(q: str | None, include_archived: bool):
        stmt = select(Supplier)
        if not include_archived:
            stmt = stmt.where(Supplier.archived_at.is_(None))
        if q:
            pattern = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(
                    Supplier.name.ilike(pattern),
                    Supplier.phone.ilike(pattern),
                )
            )
        return stmt

    def search(
        self,
        *,
        q: str | None = None,
        include_archived: bool = False,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[Supplier], int]:
        stmt = self._base_stmt(q, include_archived)
        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(Supplier.name, Supplier.id)
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total

    def get_for_update(self, supplier_id: uuid.UUID) -> Supplier | None:
        """Fetch a supplier with a row-level lock (payables serialization)."""
        stmt = (
            select(Supplier)
            .where(Supplier.id == supplier_id)
            .with_for_update()
        )
        return self.db.execute(stmt).scalar_one_or_none()
