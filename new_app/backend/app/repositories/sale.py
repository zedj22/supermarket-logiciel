"""POS sale repository (Phase 8).

Persistence-only queries for sales, holds, and favorites.
"""

from __future__ import annotations

import uuid
from typing import Sequence

from sqlalchemy import select

from app.models.catalog import Product
from app.models.pos import PosHold, ProductFavorite
from app.models.sale import Sale
from app.repositories.base import BaseRepository


class SaleRepository(BaseRepository[Sale]):
    """Persistence for sales headers."""

    model = Sale

    def find_by_client_request_id(self, client_request_id: str) -> Sale | None:
        stmt = select(Sale).where(Sale.client_request_id == client_request_id)
        return self.db.scalar(stmt)

    def find_by_invoice_number(self, invoice_number: str) -> Sale | None:
        stmt = select(Sale).where(Sale.invoice_number == invoice_number)
        return self.db.scalar(stmt)

    def get_for_update(self, sale_id: uuid.UUID) -> Sale | None:
        """Fetch a sale with a row-level lock (Phase 12 GATE 17).

        Void and return serialize on the sale row first, so the status
        transition, the cumulative source-line cap (§11) and the
        void/return mutual exclusion (§16) cannot race. PostgreSQL takes
        the lock; SQLite (unit tests) ignores FOR UPDATE but still runs
        inside a single writer transaction.
        """
        stmt = select(Sale).where(Sale.id == sale_id).with_for_update()
        return self.db.execute(stmt).scalar_one_or_none()

    def list_recent(
        self, *, limit: int = 50, offset: int = 0, user_id: uuid.UUID | None = None
    ) -> Sequence[Sale]:
        stmt = select(Sale).order_by(Sale.sale_date.desc(), Sale.created_at.desc())
        if user_id is not None:
            stmt = stmt.where(Sale.user_id == user_id)
        stmt = stmt.offset(offset).limit(limit)
        return self.db.scalars(stmt).all()

    def count_sales(self) -> int:
        from sqlalchemy import func

        return int(self.db.scalar(select(func.count()).select_from(Sale)) or 0)


class PosHoldRepository(BaseRepository[PosHold]):
    """Persistence for server-side holds."""

    model = PosHold

    def list_for_user(
        self,
        *,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        limit: int = 100,
    ) -> Sequence[PosHold]:
        stmt = select(PosHold).order_by(PosHold.created_at.desc())
        if user_id is not None:
            stmt = stmt.where(PosHold.user_id == user_id)
        if device_id:
            stmt = stmt.where(PosHold.device_id == device_id)
        stmt = stmt.limit(limit)
        return self.db.scalars(stmt).all()


class ProductFavoriteRepository(BaseRepository[ProductFavorite]):
    """Persistence for manual POS favorites."""

    model = ProductFavorite

    def find(
        self, *, product_id: uuid.UUID, user_id: uuid.UUID | None = None
    ) -> ProductFavorite | None:
        stmt = select(ProductFavorite).where(
            ProductFavorite.product_id == product_id
        )
        if user_id is None:
            stmt = stmt.where(ProductFavorite.user_id.is_(None))
        else:
            stmt = stmt.where(ProductFavorite.user_id == user_id)
        return self.db.scalar(stmt)

    def list_for_user(
        self, *, user_id: uuid.UUID | None = None, limit: int = 50
    ) -> Sequence[ProductFavorite]:
        stmt = select(ProductFavorite).order_by(ProductFavorite.created_at.desc())
        if user_id is None:
            stmt = stmt.where(ProductFavorite.user_id.is_(None))
        else:
            stmt = stmt.where(ProductFavorite.user_id == user_id)
        stmt = stmt.limit(limit)
        return self.db.scalars(stmt).all()
