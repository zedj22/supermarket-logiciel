"""Catalog repositories: products and categories.

Persistence-only. All queries are server-side with pagination, an
ordering allowlist, and bounded search results — no full-table loads.
"""

from __future__ import annotations

import uuid
from decimal import Decimal
from typing import Sequence

from sqlalchemy import asc, desc, func, or_, select

from app.models.catalog import (
    Category,
    Product,
    ProductPurchaseUnit,
    ProductSellingUnit,
    ProductStockPackage,
    ProductVariant,
)
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

# Phase 17 §17.8 - the match count is a second pass over the same predicate,
# and an unbounded pass (empty query, or a term that matches every row) was
# the reason POS lookup missed the Phase 0 "p95 < 100 ms" target at
# 100 000 products: 46 ms of COUNT on top of an indexed item query.
# The count therefore stops at this bound.  Nothing consumes a total above
# it - the Flutter POS / pack / purchase / return pickers read only `items`.
SEARCH_TOTAL_CAP = 10_000


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

        Returns (items, total). Category loads via Product.category
        selectin only. Product.variants / Product.selling_units are
        noload on the model — never fetched on this path.
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
        ``total`` is capped at :data:`SEARCH_TOTAL_CAP` (see above).
        """
        bounded_limit = max(1, min(limit, MAX_SEARCH_LIMIT))

        predicates = []
        if barcode and barcode.strip():
            predicates.append(Product.barcode == barcode.strip())
        elif text and text.strip():
            pattern = f"%{text.strip()}%"
            predicates.append(
                or_(Product.name.ilike(pattern), Product.barcode.ilike(pattern))
            )
        if not include_archived:
            predicates.append(Product.archived_at.is_(None))

        count_stmt = select(func.count()).select_from(
            select(Product.id).where(*predicates).limit(SEARCH_TOTAL_CAP).subquery()
        )
        stmt = select(Product).where(*predicates)

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


class ProductVariantRepository(BaseRepository[ProductVariant]):
    """Persistence for product variants (loaded on demand — no N+1)."""

    model = ProductVariant

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[ProductVariant]:
        """All variants for one product, active first then by name."""
        stmt = select(ProductVariant).where(
            ProductVariant.product_id == product_id
        )
        if not include_archived:
            stmt = stmt.where(ProductVariant.archived_at.is_(None))
        stmt = stmt.order_by(
            ProductVariant.archived_at.is_not(None),
            ProductVariant.name.asc(),
            ProductVariant.id,
        )
        return list(self.db.scalars(stmt).all())

    def name_exists_for_product(
        self,
        product_id: uuid.UUID,
        name: str,
        exclude_id: uuid.UUID | None = None,
    ) -> bool:
        stmt = select(ProductVariant.id).where(
            ProductVariant.product_id == product_id,
            ProductVariant.name == name,
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductVariant.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def barcode_exists(
        self, barcode: str, exclude_id: uuid.UUID | None = None
    ) -> bool:
        stmt = select(ProductVariant.id).where(
            ProductVariant.barcode == barcode
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductVariant.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def find_by_barcode(
        self, barcode: str, *, include_archived: bool = False
    ) -> ProductVariant | None:
        stmt = select(ProductVariant).where(
            ProductVariant.barcode == barcode
        )
        if not include_archived:
            stmt = stmt.where(ProductVariant.archived_at.is_(None))
        return self.db.scalar(stmt)


class SellingUnitRepository(BaseRepository[ProductSellingUnit]):
    """Persistence for commercial selling units."""

    model = ProductSellingUnit

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[ProductSellingUnit]:
        stmt = select(ProductSellingUnit).where(
            ProductSellingUnit.product_id == product_id
        )
        if not include_archived:
            stmt = stmt.where(ProductSellingUnit.archived_at.is_(None))
        stmt = stmt.order_by(
            ProductSellingUnit.is_base_unit.desc(),
            ProductSellingUnit.multiplier.asc(),
            ProductSellingUnit.name.asc(),
        )
        return list(self.db.scalars(stmt).all())

    def get_base_unit(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> ProductSellingUnit | None:
        stmt = select(ProductSellingUnit).where(
            ProductSellingUnit.product_id == product_id,
            ProductSellingUnit.is_base_unit.is_(True),
        )
        if not include_archived:
            stmt = stmt.where(ProductSellingUnit.archived_at.is_(None))
        return self.db.scalar(stmt)

    def name_exists_for_product(
        self,
        product_id: uuid.UUID,
        name: str,
        exclude_id: uuid.UUID | None = None,
    ) -> bool:
        stmt = select(ProductSellingUnit.id).where(
            ProductSellingUnit.product_id == product_id,
            ProductSellingUnit.name == name,
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductSellingUnit.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def barcode_exists(
        self, barcode: str, exclude_id: uuid.UUID | None = None
    ) -> bool:
        """Barcode unique across selling units (and products checked in service)."""
        stmt = select(ProductSellingUnit.id).where(
            ProductSellingUnit.barcode == barcode
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductSellingUnit.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def find_by_barcode(
        self, barcode: str, *, include_archived: bool = False
    ) -> ProductSellingUnit | None:
        stmt = select(ProductSellingUnit).where(
            ProductSellingUnit.barcode == barcode
        )
        if not include_archived:
            stmt = stmt.where(ProductSellingUnit.archived_at.is_(None))
        return self.db.scalar(stmt)


class PurchaseUnitRepository(BaseRepository[ProductPurchaseUnit]):
    """Persistence for purchase packaging units."""

    model = ProductPurchaseUnit

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[ProductPurchaseUnit]:
        stmt = select(ProductPurchaseUnit).where(
            ProductPurchaseUnit.product_id == product_id
        )
        if not include_archived:
            stmt = stmt.where(ProductPurchaseUnit.archived_at.is_(None))
        stmt = stmt.order_by(
            ProductPurchaseUnit.is_default.desc(),
            ProductPurchaseUnit.multiplier.asc(),
            ProductPurchaseUnit.name.asc(),
        )
        return list(self.db.scalars(stmt).all())

    def name_exists_for_product(
        self,
        product_id: uuid.UUID,
        name: str,
        exclude_id: uuid.UUID | None = None,
    ) -> bool:
        stmt = select(ProductPurchaseUnit.id).where(
            ProductPurchaseUnit.product_id == product_id,
            ProductPurchaseUnit.name == name,
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductPurchaseUnit.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def barcode_exists(
        self, barcode: str, exclude_id: uuid.UUID | None = None
    ) -> bool:
        stmt = select(ProductPurchaseUnit.id).where(
            ProductPurchaseUnit.barcode == barcode
        )
        if exclude_id is not None:
            stmt = stmt.where(ProductPurchaseUnit.id != exclude_id)
        return self.db.scalar(stmt) is not None

    def find_by_barcode(
        self, barcode: str, *, include_archived: bool = False
    ) -> ProductPurchaseUnit | None:
        stmt = select(ProductPurchaseUnit).where(
            ProductPurchaseUnit.barcode == barcode
        )
        if not include_archived:
            stmt = stmt.where(ProductPurchaseUnit.archived_at.is_(None))
        return self.db.scalar(stmt)

    def get_default(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> ProductPurchaseUnit | None:
        stmt = select(ProductPurchaseUnit).where(
            ProductPurchaseUnit.product_id == product_id,
            ProductPurchaseUnit.is_default.is_(True),
        )
        if not include_archived:
            stmt = stmt.where(ProductPurchaseUnit.archived_at.is_(None))
        return self.db.scalar(stmt)


class StockPackageRepository(BaseRepository[ProductStockPackage]):
    """Persistence for sealed full-package counts."""

    model = ProductStockPackage

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[ProductStockPackage]:
        stmt = select(ProductStockPackage).where(
            ProductStockPackage.product_id == product_id
        )
        if not include_archived:
            stmt = stmt.where(ProductStockPackage.archived_at.is_(None))
        stmt = stmt.order_by(ProductStockPackage.purchase_unit_id)
        return list(self.db.scalars(stmt).all())

    def get_for_unit(
        self, product_id: uuid.UUID, purchase_unit_id: uuid.UUID
    ) -> ProductStockPackage | None:
        stmt = select(ProductStockPackage).where(
            ProductStockPackage.product_id == product_id,
            ProductStockPackage.purchase_unit_id == purchase_unit_id,
        )
        return self.db.scalar(stmt)
