"""Catalog services: products and categories (Phase 5).

Business orchestration, validation beyond schema constraints, and
transaction boundaries. Archive (soft-delete) is the only removal
path — master data with historical references is never hard-deleted.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Sequence

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import (
    BusinessRuleError,
    ConflictError,
    ValidationError,
)
from app.models.catalog import Category, Product
from app.repositories.catalog import (
    DEFAULT_SEARCH_LIMIT,
    CategoryRepository,
    ProductRepository,
)
from app.schemas.catalog import (
    CategoryCreateRequest,
    CategoryUpdateRequest,
    ProductCreateRequest,
    ProductUpdateRequest,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

VALID_STATUS_FILTERS = frozenset({"active", "archived", "all"})


def _normalize_status(status: str) -> str:
    normalized = (status or "active").strip().lower()
    if normalized not in VALID_STATUS_FILTERS:
        raise ValidationError(
            message="status must be one of: active, archived, all",
            details={"status": status},
        )
    return normalized


class CategoryService(BaseService):
    """Application service for category master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = CategoryRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 100,
        search: str | None = None,
        status: str = "all",
        sort_by: str = "sort_order",
        sort_order: str = "asc",
    ) -> tuple[list[tuple[Category, int]], int]:
        status = _normalize_status(status)
        return self.repo.list_with_counts(
            page=page,
            page_size=page_size,
            search=search,
            status=status,
            sort_by=sort_by,
            sort_order=sort_order,
        )

    def get(self, category_id: uuid.UUID) -> Category:
        return self.repo.get_by_id_or_none(category_id)

    def _ensure_name_available(
        self, name: str, exclude_id: uuid.UUID | None = None
    ) -> None:
        if self.repo.name_exists(name, exclude_id=exclude_id):
            raise ConflictError(
                message="A category with this name already exists",
                details={"name": name},
            )

    def _ensure_parent_valid(
        self,
        parent_id: uuid.UUID | None,
        exclude_id: uuid.UUID | None = None,
    ) -> None:
        if parent_id is None:
            return
        if exclude_id is not None and parent_id == exclude_id:
            raise ValidationError(
                message="A category cannot be its own parent",
                details={"parent_id": str(parent_id)},
            )
        parent = self.repo.get_by_id(parent_id)
        if parent is None:
            raise ValidationError(
                message="Parent category not found",
                details={"parent_id": str(parent_id)},
            )

    def create(self, request: CategoryCreateRequest) -> Category:
        self._ensure_name_available(request.name)
        self._ensure_parent_valid(request.parent_id)

        with self.transaction():
            category = Category(
                name=request.name,
                parent_id=request.parent_id,
                sort_order=request.sort_order,
            )
            self.repo.create(category)
        logger.info("category_created", category_id=str(category.id), name=category.name)
        return category

    def update(
        self, category_id: uuid.UUID, request: CategoryUpdateRequest
    ) -> Category:
        category = self.get(category_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "name" in updates and updates["name"] != category.name:
            self._ensure_name_available(updates["name"], exclude_id=category_id)
        if "parent_id" in updates:
            self._ensure_parent_valid(
                updates["parent_id"], exclude_id=category_id
            )

        with self.transaction():
            for key, value in updates.items():
                setattr(category, key, value)
        logger.info("category_updated", category_id=str(category.id))
        return category

    def archive(self, category_id: uuid.UUID) -> Category:
        """Soft-archive a category. Product links are preserved."""
        category = self.get(category_id)
        if category.archived_at is None:
            with self.transaction():
                category.archived_at = datetime.now(timezone.utc)
            logger.info("category_archived", category_id=str(category.id))
        return category


class ProductService(BaseService):
    """Application service for product master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ProductRepository(db)
        self.categories = CategoryRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        search: str | None = None,
        category_id: uuid.UUID | None = None,
        status: str = "active",
        sort_by: str = "name",
        sort_order: str = "asc",
    ) -> tuple[Sequence[Product], int]:
        status = _normalize_status(status)
        return self.repo.list_products(
            page=page,
            page_size=page_size,
            search=search,
            category_id=category_id,
            status=status,
            sort_by=sort_by,
            sort_order=sort_order,
        )

    def get(self, product_id: uuid.UUID) -> Product:
        return self.repo.get_by_id_or_none(product_id)

    def search(
        self,
        *,
        text: str | None = None,
        barcode: str | None = None,
        include_archived: bool = False,
        limit: int = DEFAULT_SEARCH_LIMIT,
    ) -> tuple[Sequence[Product], int]:
        return self.repo.search(
            text=text,
            barcode=barcode,
            include_archived=include_archived,
            limit=limit,
        )

    def list_low_stock(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        threshold: Decimal | None = None,
    ) -> tuple[Sequence[Product], int]:
        return self.repo.list_low_stock(
            page=page, page_size=page_size, threshold=threshold
        )

    def _ensure_barcode_available(
        self, barcode: str | None, exclude_id: uuid.UUID | None = None
    ) -> None:
        if not barcode:
            return
        if self.repo.barcode_exists(barcode, exclude_id=exclude_id):
            raise ConflictError(
                message="A product with this barcode already exists",
                details={"barcode": barcode},
            )

    def _ensure_category_usable(self, category_id: uuid.UUID | None) -> None:
        """Category must exist; archived categories reject new products."""
        if category_id is None:
            return
        category = self.categories.get_by_id(category_id)
        if category is None:
            raise ValidationError(
                message="Category not found",
                details={"category_id": str(category_id)},
            )
        if category.archived_at is not None:
            raise BusinessRuleError(
                message="Cannot assign a product to an archived category",
                details={"category_id": str(category_id)},
            )

    def create(self, request: ProductCreateRequest) -> Product:
        self._ensure_barcode_available(request.barcode)
        self._ensure_category_usable(request.category_id)

        payload = request.model_dump()
        with self.transaction():
            product = Product(**payload)
            self.repo.create(product)
        logger.info(
            "product_created",
            product_id=str(product.id),
            name=product.name,
            barcode=product.barcode,
        )
        return product

    def update(
        self, product_id: uuid.UUID, request: ProductUpdateRequest
    ) -> Product:
        product = self.get(product_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "barcode" in updates:
            new_barcode = updates["barcode"]
            if new_barcode != product.barcode:
                self._ensure_barcode_available(
                    new_barcode, exclude_id=product_id
                )
        if "category_id" in updates and updates["category_id"] != product.category_id:
            self._ensure_category_usable(updates["category_id"])

        with self.transaction():
            for key, value in updates.items():
                setattr(product, key, value)
        logger.info("product_updated", product_id=str(product.id))
        return product

    def archive(self, product_id: uuid.UUID) -> Product:
        """Soft-archive a product (DELETE endpoint — never a hard delete)."""
        product = self.get(product_id)
        if product.archived_at is None:
            with self.transaction():
                product.archived_at = datetime.now(timezone.utc)
            logger.info("product_archived", product_id=str(product.id))
        return product
