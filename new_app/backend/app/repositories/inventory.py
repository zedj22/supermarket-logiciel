"""Inventory repositories: stock movement journal (Phase 7).

Persistence-only. Pagination + ordering allowlist — no full-table loads.
"""

from __future__ import annotations

import uuid
from typing import Sequence

from sqlalchemy import asc, desc, func, or_, select
from sqlalchemy.orm import Session

from app.models.catalog import Product, ProductVariant
from app.models.inventory import InventoryMovement
from app.repositories.base import BaseRepository

# Ordering allowlists (never accept arbitrary column names from clients).
MOVEMENT_SORT_FIELDS: frozenset[str] = frozenset(
    {
        "movement_date",
        "created_at",
        "quantity_change",
        "movement_type",
    }
)

MOVEMENT_TYPE_FILTERS: frozenset[str] = frozenset(
    {
        "sale",
        "sale_void",
        "purchase",
        "purchase_delete",
        "return",
        "adjustment",
        "pack_component",
        "package_break",
        "package_receive",
    }
)


class InventoryMovementRepository(BaseRepository[InventoryMovement]):
    """Persistence for inventory_movements."""

    model = InventoryMovement

    def list_movements(
        self,
        *,
        page: int,
        page_size: int,
        product_id: uuid.UUID | None = None,
        variant_id: uuid.UUID | None = None,
        movement_type: str | None = None,
        search: str | None = None,
        sort_by: str = "movement_date",
        sort_order: str = "desc",
    ) -> tuple[Sequence[InventoryMovement], int]:
        """Paginated movement journal with filters."""
        filters: list = []

        if product_id is not None:
            filters.append(InventoryMovement.product_id == product_id)
        if variant_id is not None:
            filters.append(InventoryMovement.variant_id == variant_id)
        if movement_type and movement_type in MOVEMENT_TYPE_FILTERS:
            filters.append(InventoryMovement.movement_type == movement_type)
        if search and search.strip():
            pattern = f"%{search.strip()}%"
            filters.append(
                or_(
                    InventoryMovement.reason.ilike(pattern),
                    InventoryMovement.document_unit.ilike(pattern),
                )
            )

        count_stmt = select(func.count()).select_from(InventoryMovement)
        for f in filters:
            count_stmt = count_stmt.where(f)
        total = self.db.scalar(count_stmt) or 0

        stmt = select(InventoryMovement)
        for f in filters:
            stmt = stmt.where(f)

        order_col = (
            sort_by if sort_by in MOVEMENT_SORT_FIELDS else "movement_date"
        )
        direction = desc if sort_order.lower() == "desc" else asc
        stmt = stmt.order_by(
            direction(getattr(InventoryMovement, order_col)),
            InventoryMovement.id,
        )

        offset = (page - 1) * page_size
        stmt = stmt.offset(offset).limit(page_size)

        items = self.db.scalars(stmt).all()
        return items, total

    def list_recent_for_product(
        self, product_id: uuid.UUID, *, limit: int = 20
    ) -> Sequence[InventoryMovement]:
        """Most recent movements for one product (detail panel)."""
        stmt = (
            select(InventoryMovement)
            .where(InventoryMovement.product_id == product_id)
            .order_by(
                InventoryMovement.movement_date.desc(),
                InventoryMovement.id.desc(),
            )
            .limit(max(1, min(limit, 100)))
        )
        return self.db.scalars(stmt).all()

    def list_products_with_stock(
        self,
        *,
        page: int,
        page_size: int,
        search: str | None = None,
        status: str = "active",
        low_stock_only: bool = False,
        sort_by: str = "name",
        sort_order: str = "asc",
    ) -> tuple[Sequence[Product], int]:
        """Paginated product list for the inventory workspace."""
        filters: list = []

        if status == "active":
            filters.append(Product.archived_at.is_(None))
        elif status == "archived":
            filters.append(Product.archived_at.is_not(None))

        if search and search.strip():
            pattern = f"%{search.strip()}%"
            filters.append(
                or_(Product.name.ilike(pattern), Product.barcode.ilike(pattern))
            )

        if low_stock_only:
            filters.append(Product.quantity <= Product.low_stock_threshold)

        count_stmt = select(func.count()).select_from(Product)
        for f in filters:
            count_stmt = count_stmt.where(f)
        total = self.db.scalar(count_stmt) or 0

        stmt = select(Product)
        for f in filters:
            stmt = stmt.where(f)

        allowed = {"name", "quantity", "avg_cost", "price", "updated_at"}
        order_col = sort_by if sort_by in allowed else "name"
        direction = desc if sort_order.lower() == "desc" else asc
        stmt = stmt.order_by(direction(getattr(Product, order_col)), Product.id)

        offset = (page - 1) * page_size
        stmt = stmt.offset(offset).limit(page_size)

        items = self.db.scalars(stmt).all()
        return items, total

    def total_stock_value(self, *, include_archived: bool = False) -> float:
        """SUM(quantity × avg_cost) across products (for the list header)."""
        stmt = select(
            func.coalesce(
                func.sum(Product.quantity * Product.avg_cost), 0
            )
        )
        if not include_archived:
            stmt = stmt.where(Product.archived_at.is_(None))
        return float(self.db.scalar(stmt) or 0)

    def get_variant(
        self, variant_id: uuid.UUID
    ) -> ProductVariant | None:
        return self.db.get(ProductVariant, variant_id)
