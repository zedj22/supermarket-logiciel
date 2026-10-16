"""Persistence for zakat snapshots, payments and the context imports.

The context queries (product valuation rows, AR/AP reference totals)
live here too: they are read-only projections the zakat screen imports,
never writes to the business tables.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.domain.unit_conversions import to_decimal
from app.models.catalog import Product
from app.models.party import Customer, Supplier
from app.models.zakat import ZakatCalculation, ZakatPayment
from app.repositories.base import BaseRepository

#: How many debtors / payables the context endpoint returns as candidates.
REFERENCE_ROWS_LIMIT = 100


class ZakatRepository(BaseRepository[ZakatCalculation]):
    """Zakat calculation snapshots (immutable, newest first)."""

    model = ZakatCalculation

    def find_by_client_request_id(self, key: str) -> ZakatCalculation | None:
        stmt = select(ZakatCalculation).where(
            ZakatCalculation.client_request_id == key
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def page(self, *, page: int, page_size: int) -> tuple[list[ZakatCalculation], int]:
        total = self.db.scalar(
            select(func.count()).select_from(ZakatCalculation)
        ) or 0
        rows = self.db.scalars(
            select(ZakatCalculation)
            .order_by(ZakatCalculation.created_at.desc(), ZakatCalculation.id)
            .offset((page - 1) * page_size)
            .limit(page_size)
        ).all()
        return list(rows), int(total)

    # ------------------------------------------------------------------
    # Context imports (read-only projections)
    # ------------------------------------------------------------------

    def product_valuation_rows(self) -> list[Product]:
        """Non-archived products with the fields the valuation needs."""
        return list(
            self.db.scalars(
                select(Product)
                .where(Product.archived_at.is_(None))
                .order_by(Product.name, Product.id)
            ).all()
        )

    def ar_summary(self) -> tuple[Decimal, int, list[Customer]]:
        """Customer ledger: (total outstanding, debtor count, top rows)."""
        total = self.db.scalar(
            select(func.coalesce(func.sum(Customer.balance), 0)).where(
                Customer.balance > 0
            )
        )
        count = self.db.scalar(
            select(func.count()).where(Customer.balance > 0)
        ) or 0
        debtors = list(
            self.db.scalars(
                select(Customer)
                .where(Customer.balance > 0)
                .order_by(Customer.name, Customer.id)
                .limit(REFERENCE_ROWS_LIMIT)
            ).all()
        )
        return to_decimal(total), int(count), debtors

    def ap_summary(self) -> tuple[Decimal, int, list[Supplier]]:
        """Supplier ledger: (total owed, supplier count, top rows)."""
        total = self.db.scalar(
            select(func.coalesce(func.sum(Supplier.balance), 0)).where(
                Supplier.balance > 0
            )
        )
        count = self.db.scalar(
            select(func.count()).where(Supplier.balance > 0)
        ) or 0
        suppliers = list(
            self.db.scalars(
                select(Supplier)
                .where(Supplier.balance > 0)
                .order_by(Supplier.name, Supplier.id)
                .limit(REFERENCE_ROWS_LIMIT)
            ).all()
        )
        return to_decimal(total), int(count), suppliers


class ZakatPaymentRepository(BaseRepository[ZakatPayment]):
    """Append-only payment records for one calculation."""

    model = ZakatPayment

    def __init__(self, db: Session):
        super().__init__(db)

    def find_by_client_request_id(self, key: str) -> ZakatPayment | None:
        stmt = select(ZakatPayment).where(ZakatPayment.client_request_id == key)
        return self.db.execute(stmt).scalar_one_or_none()

    def total_for_calculation(self, calculation_id: uuid.UUID) -> Decimal:
        total = self.db.scalar(
            select(func.coalesce(func.sum(ZakatPayment.amount), 0)).where(
                ZakatPayment.calculation_id == calculation_id
            )
        )
        return to_decimal(total)
