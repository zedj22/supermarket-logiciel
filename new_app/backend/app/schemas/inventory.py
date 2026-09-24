"""Pydantic schemas for inventory (Phase 7).

Money and quantity fields use Decimal to match NUMERIC(18,3) columns.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from app.schemas.common import StrictBaseModel

# Neutral default persisted when an increase omits reason (not localized).
INCREASE_DEFAULT_REASON = "Manual stock increase"


# ---------------------------------------------------------------------------
# Inventory list (products with stock + valuation)
# ---------------------------------------------------------------------------


class InventoryItemResponse(StrictBaseModel):
    """One row of the inventory list: stock + PMP + valuation."""

    product_id: UUID
    name: str
    barcode: str | None = None
    unit: str = "piece"
    quantity: Decimal
    low_stock_threshold: Decimal = Decimal("5")
    allow_negative_stock: bool = False
    cost: Decimal  # nominal / last-purchase reference
    avg_cost: Decimal  # authoritative PMP
    stock_value: Decimal  # quantity × avg_cost
    price: Decimal
    is_archived: bool = False
    category_id: UUID | None = None
    category_name: str | None = None
    updated_at: datetime


class InventoryListResponse(StrictBaseModel):
    """Paginated inventory list."""

    items: list[InventoryItemResponse]
    total: int
    page: int
    page_size: int
    pages: int
    total_stock_value: Decimal = Decimal("0")


# ---------------------------------------------------------------------------
# Movement journal
# ---------------------------------------------------------------------------


class InventoryMovementResponse(StrictBaseModel):
    """One stock movement (immutable journal entry)."""

    id: UUID
    product_id: UUID
    product_name: str | None = None
    variant_id: UUID | None = None
    variant_name: str | None = None
    movement_type: str
    quantity_change: Decimal
    quantity_before: Decimal
    quantity_after: Decimal
    document_quantity: Decimal | None = None
    document_unit: str | None = None
    purchase_unit_id: UUID | None = None
    packages_change: Decimal | None = None
    unit_cost: Decimal | None = None
    avg_cost_after: Decimal | None = None
    reason: str | None = None
    source_document_type: str | None = None
    source_document_id: UUID | None = None
    user_id: UUID | None = None
    user_name: str | None = None
    device_id: str | None = None
    movement_date: datetime
    created_at: datetime


class InventoryMovementListResponse(StrictBaseModel):
    """Paginated movement journal."""

    items: list[InventoryMovementResponse]
    total: int
    page: int
    page_size: int
    pages: int


# ---------------------------------------------------------------------------
# Adjust request
# ---------------------------------------------------------------------------


class InventoryAdjustRequest(StrictBaseModel):
    """Stock adjustment: increase / decrease / set to an absolute quantity.

    Inventory uses BASE units only (no unit selector in the UI).
    - variant_id set → adjusts variant.quantity only (product qty untouched).
    - purchase_unit_id set → quantity is whole packages (never fractional);
      base delta = quantity × multiplier; package stock is updated.
      (API capability for packaging workflows — not sent by AdjustDialog.)
    - unit_cost on increase → updates product.avg_cost via weighted average
      in base units.
    - operation=set → quantity is the NEW absolute stock in base units.
    - reason: OPTIONAL on increase (blank → INCREASE_DEFAULT_REASON in service);
      REQUIRED non-blank on decrease/set (422 if missing/blank).
    """

    product_id: UUID
    variant_id: UUID | None = None
    operation: str = Field(..., pattern="^(increase|decrease|set)$")
    quantity: Decimal = Field(..., ge=0, max_digits=18, decimal_places=3)
    unit_cost: Decimal | None = Field(
        None, ge=0, max_digits=18, decimal_places=3
    )
    purchase_unit_id: UUID | None = None
    reason: str | None = Field(None, max_length=500)
    note: str | None = Field(None, max_length=2000)

    @field_validator("reason", "unit_cost", "note", mode="before")
    @classmethod
    def optional_fields_blank_to_none(cls, value: object) -> object:
        """Treat missing/blank optional fields as None before type coercion."""
        if isinstance(value, str):
            stripped = value.strip()
            return stripped or None
        return value

    @model_validator(mode="after")
    def reason_required_for_decrease_and_set(self) -> InventoryAdjustRequest:
        if self.operation in ("decrease", "set") and not self.reason:
            raise ValueError("reason is required for decrease and set")
        return self


# ---------------------------------------------------------------------------
# Product stock detail
# ---------------------------------------------------------------------------


class InventoryProductDetailResponse(StrictBaseModel):
    """Full stock detail for one product: valuation + packaging + variants."""

    product_id: UUID
    name: str
    barcode: str | None = None
    unit: str = "piece"
    quantity: Decimal
    cost: Decimal
    avg_cost: Decimal
    stock_value: Decimal
    price: Decimal
    low_stock_threshold: Decimal = Decimal("5")
    allow_negative_stock: bool = False
    is_archived: bool = False
    packaging: dict  # PackagingStateResponse.model_dump()
    variants: list[dict]  # [{id, name, quantity, ...}]
    purchase_units: list[dict]  # [{id, name, multiplier, ...}]
    recent_movements: list[InventoryMovementResponse] = Field(default_factory=list)
