"""Catalog repositories: products and categories.

Persistence-only. All queries are server-side with pagination, an
ordering allowlist, and bounded search results — no full-table loads.
"""

from __future__ import annotations

import uuid
from decimal import Decimal
from typing import Sequence

from sqlalchemy import asc, desc, func, or_, select

from app.models.catalog import Category, Product
from app.repositories.base import BaseRepository

# Ordering allowlists (never accept arbitrary column names from clients).
PRODUCT_SORT_FIELDS: frozenset[str] = frozenset(
    {
        "name",
        "barcode",
        "price",
        "cost",
        "quantity",
        "created_at",
        "updated_at",
    }
)

CATEGORY_SORT_FIELDS: frozenset[str] = frozenset(
    {"name", "sort_order", "created_at", "updated_at"}
)

DEFAULT_SEARCH_LIMIT = 20
MAX_SEARCH_LIMIT = 50


class ProductRepository(BaseRepository[Product]):
    """Persistence for products."""

    model = Product

    def list_products(
        self,
        *,
        page: int,
        page_size: int,
        search: str | None = None,
        category_id: uuid.UUID | None = None,
        status: str = "active",
        sort_by: str = "name",
        sort_order: str = "asc",
    ) -> tuple[Sequence[Product], int]:
        """Paginated product list with search/category/archive filters.

        Returns (items, total). Category data loads via the model's
        existing selectin relationship (constant queries, not N+1).
        """
        filters: list = []

        if status == "active":
            filters.append(Product.archived_at.is_(None))
        elif status == "archived":
            filters.append(Product.archived_at.is_not(None))
        # status == "all" → no archive filter

        if category_id is not None:
            filters.append(Product.category_id == category_id)

        if search and search.strip():
            pattern = f"%{search.strip()}%"
            filters.append(
                or_(Product.name.ilike(pattern), Product.barcode.ilike(pattern))
            )

        count_stmt = select(func.count()).select_from(Product)
        for f in filters:
            count_stmt = count_stmt.where(f)
        total = self.db.scalar(count_stmt) or 0

        stmt = select(Product)
        for f in filters:
            stmt = stmt.where(f)

        order_col = (
            sort_by if sort_by in PRODUCT_SORT_FIELDS else "name"
        )
        direction = desc if sort_order.lower() == "desc" else asc
        stmt = stmt.order_by(direction(getattr(Product, order_col)), Product.id)

        offset = (page - 1) * page_size
        stmt = stmt.offset(offset).limit(page_size)

        items = self.db.scalars(stmt).all()
        return items, total

    def search(
        self,
        *,
        text: str | None = None,
        barcode: str | None = None,
        include_archived: bool = False,
        limit: int = DEFAULT_SEARCH_LIMIT,
    ) -> tuple[Sequence[Product], int]:
        """Bounded catalog search: exact barcode and/or name/barcode LIKE.

        Exact barcode (POS scan path) takes precedence over text matching.
        """
        bounded_limit = max(1, min(limit, MAX_SEARCH_LIMIT))

        stmt = select(Product)
        count_stmt = select(func.count()).select_from(Product)

        if barcode and barcode.strip():
            exact = barcode.strip()
            stmt = stmt.where(Product.barcode == exact)
            count_stmt = count_stmt.where(Product.barcode == exact)
        elif text and text.strip():
            pattern = f"%{text.strip()}%"
            clause = or_(Product.name.ilike(pattern), Product.barcode.ilike(pattern))
            stmt = stmt.where(clause)
            count_stmt = count_stmt.where(clause)

        if not include_archived:
            stmt = stmt.where(Product.archived_at.is_(None))
            count_stmt = count_stmt.where(Product.archived_at.is_(None))

        total = self.db.scalar(count_stmt) or 0
        stmt = stmt.order_by(Product.name, Product.id).limit(bounded_limit)
        items = self.db.scalars(stmt).all()
        return items, total

    def list_low_stock(
        self,
        *,
        page: int,
        page_size: int,
        threshold: Decimal | None = None,
    ) -> tuple[Sequence[Product], int]:
        """Active products at or below their low-stock threshold.

        If `threshold` is provided, it overrides each product's own
        low_stock_threshold for this query only.
        """
        if threshold is not None:
            low = Product.quantity <= threshold
        else:
            low = Product.quantity <= Product.low_stock_threshold

        base = select(Product).where(Product.archived_at.is_(None), low)
        count_stmt = (
            select(func.count())
            .select_from(Product)
            .where(Product.archived_at.is_(None), low)
        )
        total = self.db.scalar(count_stmt) or 0
        stmt = base.order_by(Product.quantity.asc(), Product.name.asc())
        stmt = stmt.offset((page - 1) * page_size).limit(page_size)
        items = self.db.scalars(stmt).all()
        return items, total

    def barcode_exists(
        self, barcode: str, exclude_id: uuid.UUID | None = None
    ) -> bool:
        """True when another product already uses this barcode."""
        stmt = select(Product.id).where(Product.barcode == barcode)
        if exclude_id is not None:
            stmt = stmt.where(Product.id != exclude_id)
        return self.db.scalar(stmt) is not None


class CategoryRepository(BaseRepository[Category]):
    """Persistence for categories."""

    model = Category

    def list_with_counts(
        self,
        *,
        page: int,
        page_size: int,
        search: str | None = None,
        status: str = "all",
        sort_by: str = "sort_order",
        sort_order: str = "asc",
    ) -> tuple[list[tuple[Category, int]], int]:
        """List categories with active-product counts in ONE query.

        Uses a grouped subquery + LEFT JOIN — no per-category count
        queries (avoids N+1).
        """
        count_subq = (
            select(
                Product.category_id.label("category_id"),
                func.count().label("active_products"),
            )
            .where(Product.archived_at.is_(None))
            .group_by(Product.category_id)
            .subquery()
        )

        filters: list = []
        if status == "active":
            filters.append(Category.archived_at.is_(None))
        elif status == "archived":
            filters.append(Category.archived_at.is_not(None))

        if search and search.strip():
            filters.append(Category.name.ilike(f"%{search.strip()}%"))

        count_stmt = select(func.count()).select_from(Category)
        for f in filters:
            count_stmt = count_stmt.where(f)
        total = self.db.scalar(count_stmt) or 0

        stmt = (
            select(Category, func.coalesce(count_subq.c.active_products, 0))
            .outerjoin(
                count_subq, count_subq.c.category_id == Category.id
            )
        )
        for f in filters:
            stmt = stmt.where(f)

        order_field = sort_by if sort_by in CATEGORY_SORT_FIELDS else "sort_order"
        direction = desc if sort_order.lower() == "desc" else asc
        stmt = stmt.order_by(
            direction(getattr(Category, order_field)), Category.name
        )
        stmt = stmt.offset((page - 1) * page_size).limit(page_size)

        rows = self.db.execute(stmt).all()
        return [(row[0], int(row[1])) for row in rows], total

    def name_exists(
        self, name: str, exclude_id: uuid.UUID | None = None
    ) -> bool:
        """True when another category already uses this name."""
        stmt = select(Category.id).where(Category.name == name)
        if exclude_id is not None:
            stmt = stmt.where(Category.id != exclude_id)
        return self.db.scalar(stmt) is not None
