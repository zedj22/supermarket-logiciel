"""Pydantic schemas for POS sales, holds, and favorites (Phase 8).

Money and quantity fields use Decimal. Client totals are never trusted —
the service recomputes everything from authoritative product/variant prices.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from app.models.enums import PaymentMethod
from app.schemas.common import StrictBaseModel

PaymentMethodLiteral = Literal["cash", "card", "partial", "credit"]


class SaleLineRequest(StrictBaseModel):
    """One cart line as sent by the POS client.

    unit_price is a client hint only — server resolves authoritative price.
    quantity is in selling units when selling_unit_id is set, otherwise base units.
    """

    product_id: UUID
    variant_id: UUID | None = None
    selling_unit_id: UUID | None = None
    quantity: Decimal = Field(..., gt=0, le=Decimal("999999"))
    unit_price: Decimal = Field(default=Decimal("0"), ge=0)
    line_discount: Decimal = Field(default=Decimal("0"), ge=0)
    barcode: str | None = Field(default=None, max_length=50)

    @field_validator("line_discount")
    @classmethod
    def _non_negative_discount(cls, v: Decimal) -> Decimal:
        if v < 0:
            raise ValueError("line_discount must be >= 0")
        return v


class CreateSaleRequest(StrictBaseModel):
    """POST /sales checkout payload.

    Does NOT include client subtotal/total/change/debt — server computes them.
    """

    client_request_id: str = Field(..., min_length=1, max_length=100)
    items: list[SaleLineRequest] = Field(..., min_length=1, max_length=200)
    customer_id: UUID | None = None
    invoice_discount: Decimal = Field(default=Decimal("0"), ge=0)
    payment_method: PaymentMethodLiteral = "cash"
    paid: Decimal = Field(..., ge=0)
    device_id: str | None = Field(default=None, max_length=100)
    note: str | None = Field(default=None, max_length=2000)

    @field_validator("client_request_id")
    @classmethod
    def _non_blank_request_id(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("client_request_id must not be blank")
        return stripped

    @model_validator(mode="after")
    def _items_unique_enough(self) -> CreateSaleRequest:
        if not self.items:
            raise ValueError("items must not be empty")
        return self


class SaleLineResponse(StrictBaseModel):
    """Persisted sale line snapshot.

    Every field is historical: values captured at checkout, never
    re-read from the catalog (UX FIX #11). The three nullable display
    fields are null for base-unit sales and for pre-Phase-8 rows.
    """

    id: UUID
    product_id: UUID
    variant_id: UUID | None = None
    product_name: str
    product_sku: str | None = None
    product_barcode: str | None = None
    product_unit: str
    variant_name: str | None = None
    selling_unit_name: str | None = None
    selling_unit_multiplier: Decimal | None = None
    unit_price: Decimal
    unit_cost: Decimal
    quantity: Decimal
    line_discount: Decimal
    line_total: Decimal


class SalePaymentResponse(StrictBaseModel):
    id: UUID
    method: str
    amount: Decimal


class SaleResponse(StrictBaseModel):
    """Checkout result — only returned after a successful commit."""

    id: UUID
    invoice_number: str
    client_request_id: str | None = None
    customer_id: UUID | None = None
    status: str
    subtotal: Decimal
    discount: Decimal  # invoice-level only
    total: Decimal
    paid: Decimal
    change: Decimal
    debt: Decimal = Decimal("0")
    payment_method: str
    device_id: str | None = None
    note: str | None = None
    sale_date: datetime
    lines: list[SaleLineResponse] = Field(default_factory=list)
    payments: list[SalePaymentResponse] = Field(default_factory=list)
    idempotent_replay: bool = False
    unit_summary: str | None = None
    """Compact sold-units line for history rows (UX FIX #12 — FIX #1).

    e.g. ``"2 Box · 48 piece"`` — grouped by sold unit, first-seen order,
    capped at three groups (then ``+N``). Computed from the persisted line
    snapshots only: informational, never feeds totals or stock.
    """


class PriceOverride(StrictBaseModel):
    """Server corrected a client unit_price (documented price-change policy)."""

    line_index: int
    product_id: UUID
    requested_unit_price: Decimal
    applied_unit_price: Decimal


class SaleCreateResponse(SaleResponse):
    """POST /sales response including any server-side price corrections."""

    price_overrides: list[PriceOverride] = Field(default_factory=list)


class SaleListResponse(StrictBaseModel):
    """Paginated minimal sale history."""

    items: list[SaleResponse]
    total: int
    page: int
    page_size: int
    pages: int


class CartLineValidation(StrictBaseModel):
    line_index: int
    product_id: UUID
    variant_id: UUID | None = None
    ok: bool
    message: str | None = None
    available_stock: Decimal | None = None
    required_quantity: Decimal | None = None
    unit_price: Decimal | None = None
    is_archived: bool = False


class CartValidateRequest(StrictBaseModel):
    items: list[SaleLineRequest] = Field(..., min_length=1, max_length=200)
    customer_id: UUID | None = None
    invoice_discount: Decimal = Field(default=Decimal("0"), ge=0)
    payment_method: PaymentMethodLiteral = "cash"
    paid: Decimal = Field(default=Decimal("0"), ge=0)


class CartValidateResponse(StrictBaseModel):
    ok: bool
    lines: list[CartLineValidation]
    subtotal: Decimal = Decimal("0")
    discount: Decimal = Decimal("0")
    total: Decimal = Decimal("0")
    paid: Decimal = Decimal("0")
    change: Decimal = Decimal("0")
    debt: Decimal = Decimal("0")
    errors: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Holds
# ---------------------------------------------------------------------------


class HoldCartItem(StrictBaseModel):
    product_id: UUID
    variant_id: UUID | None = None
    selling_unit_id: UUID | None = None
    quantity: Decimal = Field(..., gt=0)
    unit_price: Decimal = Field(default=Decimal("0"), ge=0)
    line_discount: Decimal = Field(default=Decimal("0"), ge=0)
    barcode: str | None = Field(default=None, max_length=50)
    # Display snapshot (Phase 8 FIX #10): restored carts show product /
    # unit names straight from the hold snapshot — no catalog lookup.
    # Optional so holds created before this change still validate.
    product_name: str | None = None
    variant_name: str | None = None
    product_unit: str | None = None
    unit_name: str | None = None
    base_unit_price: str | None = None
    unit_multiplier: str | None = None
    available_stock: str | None = None


class HoldCreateRequest(StrictBaseModel):
    device_id: str | None = Field(default=None, max_length=100)
    customer_id: UUID | None = None
    items: list[HoldCartItem] = Field(..., min_length=1, max_length=200)
    invoice_discount: Decimal = Field(default=Decimal("0"), ge=0)
    note: str | None = Field(default=None, max_length=500)


class HoldResponse(StrictBaseModel):
    id: UUID
    user_id: UUID | None = None
    device_id: str | None = None
    customer_id: UUID | None = None
    items: list[HoldCartItem] = Field(default_factory=list)
    invoice_discount: Decimal = Decimal("0")
    note: str | None = None
    created_at: datetime


class HoldListResponse(StrictBaseModel):
    items: list[HoldResponse]
    total: int


class HoldRestoreResponse(StrictBaseModel):
    """Restore returns the snapshot plus current stock/price revalidation."""

    hold: HoldResponse
    lines: list[CartLineValidation]
    ok: bool
    errors: list[str] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Favorites
# ---------------------------------------------------------------------------


class FavoriteResponse(StrictBaseModel):
    id: UUID
    product_id: UUID
    product_name: str | None = None
    barcode: str | None = None
    price: Decimal | None = None
    quantity: Decimal | None = None
    is_archived: bool = False
    created_at: datetime


class FavoriteListResponse(StrictBaseModel):
    items: list[FavoriteResponse]
    total: int


class FavoriteToggleResponse(StrictBaseModel):
    favorited: bool
    product_id: UUID
