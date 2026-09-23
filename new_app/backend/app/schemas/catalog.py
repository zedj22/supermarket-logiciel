"""Pydantic schemas for products and categories (Phase 5).

Request/response schemas for the catalog module. Money and quantity
fields use Decimal to match the NUMERIC(18,3) columns — never binary
float for persisted business values.
"""

from __future__ import annotations

import os
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from pydantic import Field, field_validator

from app.models.enums import ProductUnit
from app.schemas.common import StrictBaseModel

# Supported image file extensions (legacy-compatible, local paths only).
ALLOWED_IMAGE_EXTENSIONS: frozenset[str] = frozenset(
    {".png", ".jpg", ".jpeg", ".webp", ".bmp"}
)

# Barcode column length (products.barcode is VARCHAR(50)).
BARCODE_MAX_LENGTH = 50


def _non_blank(value: str, field_name: str) -> str:
    """Strip whitespace and reject blank strings."""
    stripped = value.strip()
    if not stripped:
        raise ValueError(f"{field_name} must not be blank")
    return stripped


def _validate_image_path(value: str | None) -> str | None:
    """Validate a local product image path (type + length only)."""
    if value is None:
        return None
    stripped = value.strip()
    if not stripped:
        return None
    if len(stripped) > 500:
        raise ValueError("image_path must be at most 500 characters")
    ext = os.path.splitext(stripped)[1].lower()
    if ext not in ALLOWED_IMAGE_EXTENSIONS:
        raise ValueError(
            "image_path must be a png, jpg, jpeg, webp, or bmp file"
        )
    return stripped


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------


class CategoryResponse(StrictBaseModel):
    """Category response with active product count."""

    id: UUID
    name: str
    parent_id: UUID | None = None
    sort_order: int = 0
    product_count: int = 0
    is_archived: bool = False
    archived_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class CategoryCreateRequest(StrictBaseModel):
    """Create a product category."""

    name: str = Field(..., min_length=1, max_length=100)
    parent_id: UUID | None = None
    sort_order: int = Field(default=0, ge=-10_000, le=10_000)

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, value: str) -> str:
        return _non_blank(value, "name")


class CategoryUpdateRequest(StrictBaseModel):
    """Partial update of a product category. Unset fields are preserved."""

    name: str | None = Field(None, min_length=1, max_length=100)
    parent_id: UUID | None = None
    sort_order: int | None = Field(None, ge=-10_000, le=10_000)

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _non_blank(value, "name")


class CategoryListResponse(StrictBaseModel):
    """Paginated category list."""

    items: list[CategoryResponse]
    total: int
    page: int
    page_size: int
    pages: int


# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------


class ProductResponse(StrictBaseModel):
    """Product response (no variant details — Phase 6)."""

    id: UUID
    name: str
    barcode: str | None = None
    sku: str | None = None
    description: str | None = None
    unit: str = ProductUnit.PIECE.value
    price: Decimal
    cost: Decimal
    quantity: Decimal
    low_stock_threshold: Decimal = Decimal("5")
    allow_negative_stock: bool = False
    expiry_date: date | None = None
    image_path: str | None = None
    category_id: UUID | None = None
    category_name: str | None = None
    is_archived: bool = False
    archived_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class ProductCreateRequest(StrictBaseModel):
    """Create a product. Name and price are required; others optional."""

    name: str = Field(..., min_length=1, max_length=200)
    barcode: str | None = Field(None, max_length=BARCODE_MAX_LENGTH)
    sku: str | None = Field(None, max_length=50)
    description: str | None = Field(None, max_length=5_000)
    unit: str = Field(
        default=ProductUnit.PIECE.value,
        max_length=20,
    )
    price: Decimal = Field(..., ge=0, max_digits=18, decimal_places=3)
    cost: Decimal = Field(default=Decimal("0"), ge=0, max_digits=18, decimal_places=3)
    quantity: Decimal = Field(
        default=Decimal("0"), ge=0, max_digits=18, decimal_places=3
    )
    low_stock_threshold: Decimal = Field(
        default=Decimal("5"), ge=0, max_digits=18, decimal_places=3
    )
    allow_negative_stock: bool = False
    expiry_date: date | None = None
    image_path: str | None = None
    category_id: UUID | None = None

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, value: str) -> str:
        return _non_blank(value, "name")

    @field_validator("barcode", "sku")
    @classmethod
    def optional_string_not_blank(
        cls, value: str | None
    ) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @field_validator("unit")
    @classmethod
    def unit_must_be_known(cls, value: str) -> str:
        allowed = {u.value for u in ProductUnit}
        if value not in allowed:
            raise ValueError(
                f"unit must be one of: {', '.join(sorted(allowed))}"
            )
        return value

    @field_validator("image_path")
    @classmethod
    def image_path_valid(cls, value: str | None) -> str | None:
        return _validate_image_path(value)


class ProductUpdateRequest(StrictBaseModel):
    """Partial update of a product. Unset fields are preserved."""

    name: str | None = Field(None, min_length=1, max_length=200)
    barcode: str | None = Field(None, max_length=BARCODE_MAX_LENGTH)
    sku: str | None = Field(None, max_length=50)
    description: str | None = Field(None, max_length=5_000)
    unit: str | None = Field(None, max_length=20)
    price: Decimal | None = Field(None, ge=0, max_digits=18, decimal_places=3)
    cost: Decimal | None = Field(
        None, ge=0, max_digits=18, decimal_places=3
    )
    quantity: Decimal | None = Field(
        None, ge=0, max_digits=18, decimal_places=3
    )
    low_stock_threshold: Decimal | None = Field(
        None, ge=0, max_digits=18, decimal_places=3
    )
    allow_negative_stock: bool | None = None
    expiry_date: date | None = None
    image_path: str | None = None
    category_id: UUID | None = None

    @field_validator("name")
    @classmethod
    def name_not_blank(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _non_blank(value, "name")

    @field_validator("barcode", "sku")
    @classmethod
    def optional_string_not_blank(
        cls, value: str | None
    ) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @field_validator("unit")
    @classmethod
    def unit_must_be_known(cls, value: str | None) -> str | None:
        if value is None:
            return None
        allowed = {u.value for u in ProductUnit}
        if value not in allowed:
            raise ValueError(
                f"unit must be one of: {', '.join(sorted(allowed))}"
            )
        return value

    @field_validator("image_path")
    @classmethod
    def image_path_valid(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _validate_image_path(value)


class ProductListResponse(StrictBaseModel):
    """Paginated product list."""

    items: list[ProductResponse]
    total: int
    page: int
    page_size: int
    pages: int


class ProductSearchResponse(StrictBaseModel):
    """Bounded product search result."""

    items: list[ProductResponse]
    total: int
