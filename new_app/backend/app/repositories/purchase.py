"""Purchase + supplier-ledger persistence (Phase 11).

Repositories stay persistence-only: queries, filters, locks, and the
read models needed for history and idempotent replay. All business
rules live in the services.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import func, or_, select

from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.party import Supplier
from app.models.purchase import Purchase
from app.models.supplier_ledger import SupplierLedgerEntry
from app.repositories.base import BaseRepository

PURCHASE_SORT_FIELDS = frozenset(
    {"purchase_date", "created_at", "invoice_number", "total", "status"}
)


class PurchaseRepository(BaseRepository[Purchase]):
    """Purchase document persistence."""

    model = Purchase

    @staticmethod
    def _base_stmt(
        q: str | None,
        status: str | None,
        supplier_id: uuid.UUID | None,
    ):
        stmt = select(Purchase)
        if status:
            stmt = stmt.where(Purchase.status == status)
        if supplier_id is not None:
            stmt = stmt.where(Purchase.supplier_id == supplier_id)
        if q:
            pattern = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(
                    Purchase.invoice_number.ilike(pattern),
                    Purchase.note.ilike(pattern),
                    Purchase.supplier.has(Supplier.name.ilike(pattern)),
                )
            )
        return stmt

    def search(
        self,
        *,
        q: str | None = None,
        status: str | None = None,
        supplier_id: uuid.UUID | None = None,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[Purchase], int]:
        """Paginated purchase search, newest first.

        Ordered by purchase_date DESC with id DESC as a stable
        tie-breaker so pagination never repeats or skips rows.
        """
        stmt = self._base_stmt(q, status, supplier_id)
        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(
                    Purchase.purchase_date.desc(), Purchase.id.desc()
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total

    def find_by_client_request_id(self, client_request_id: str) -> Purchase | None:
        stmt = select(self.model).where(
            self.model.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def get_for_update(self, purchase_id: uuid.UUID) -> Purchase | None:
        """Fetch a purchase with a row-level lock.

        Receive/cancel serialize on this lock so a duplicate receive can
        never double-apply stock (GATE 17/18): the second transaction
        waits, then observes status != draft and raises 409.
        """
        stmt = (
            select(Purchase)
            .where(Purchase.id == purchase_id)
            .with_for_update()
        )
        return self.db.execute(stmt).scalar_one_or_none()


class SupplierLedgerEntryRepository(BaseRepository[SupplierLedgerEntry]):
    """Supplier ledger persistence (append-only, mirrors debt ledger)."""

    model = SupplierLedgerEntry

    def history_for_supplier(
        self,
        supplier_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[SupplierLedgerEntry], int]:
        stmt = select(self.model).where(self.model.supplier_id == supplier_id)
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
    ) -> SupplierLedgerEntry | None:
        stmt = select(self.model).where(
            self.model.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def balance_after_map(
        self, supplier_id: uuid.UUID
    ) -> dict[uuid.UUID, Decimal]:
        """Running payable balance AFTER every entry of one supplier.

        Chronological prefix sum mirroring ledger_sum_for_supplier:
        purchase +, payment -, purchase_cancel -, quantized per step so
        values match suppliers.balance exactly. Computed (never stored).
        """
        rows = self.db.execute(
            select(
                self.model.id,
                self.model.entry_type,
                self.model.amount,
            )
            .where(self.model.supplier_id == supplier_id)
            .order_by(self.model.entry_date.asc(), self.model.id.asc())
        ).all()
        running = Decimal("0")
        result: dict[uuid.UUID, Decimal] = {}
        for entry_id, entry_type, amount in rows:
            value = to_decimal(amount)
            if entry_type == "purchase":
                running += value
            elif entry_type in ("payment", "purchase_cancel"):
                running -= value
            result[entry_id] = quantize_money(running)
        return result

    def ledger_sum_for_supplier(self, supplier_id: uuid.UUID) -> Decimal:
        """Authoritative payable from entries: purchases - payments - cancels.

        Used to reconcile suppliers.balance (cached projection) against
        the append-only ledger in transactions and tests.
        """
        rows = self.db.execute(
            select(
                self.model.entry_type,
                func.coalesce(func.sum(self.model.amount), 0),
            )
            .where(self.model.supplier_id == supplier_id)
            .group_by(self.model.entry_type)
        ).all()
        totals = {entry_type: to_decimal(amount) for entry_type, amount in rows}
        return (
            totals.get("purchase", Decimal("0"))
            - totals.get("payment", Decimal("0"))
            - totals.get("purchase_cancel", Decimal("0"))
        )
