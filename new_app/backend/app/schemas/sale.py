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

from app.core.constants import MAX_SALE_LINES
from app.models.enums import PaymentMethod
from app.schemas.common import StrictBaseModel

PaymentMethodLiteral = Literal["cash", "card", "partial", "credit"]


class SaleLineRequest(StrictBaseModel):
    """One cart line as sent by the POS client.

    Exactly one target per line (Phase 10 / GATE 6):
      product line -> ``product_id`` set, ``pack_id`` omitted
      pack line    -> ``pack_id`` set,    ``product_id`` omitted
    Both or neither is a 422 — the same contract the API had before packs
    existed (``product_id`` was simply required then).

    unit_price is a client hint only — server resolves authoritative price.
    quantity is in selling units when selling_unit_id is set, otherwise base
    units (packs, for a pack line).
    """

    product_id: UUID | None = None
    pack_id: UUID | None = None
    variant_id: UUID | None = None
    selling_unit_id: UUID | None = None
    # POS "quick custom item" (price-only line). Set WITHOUT product_id and
    # pack_id: the line has no catalog product, no stock and no cost, and its
    # own name is snapshotted into sale_lines.product_name (an existing
    # column — no schema change). ``unit_price`` is the authoritative price
    # of such a line, because there is no catalog price to resolve.
    custom_name: str | None = Field(default=None, max_length=200)
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

    @model_validator(mode="after")
    def _exactly_one_target(self) -> SaleLineRequest:
        custom = (self.custom_name or "").strip()
        if self.product_id is None and self.pack_id is None:
            # Third shape: a price-only custom line. It must carry its own
            # name and a positive price, and it can never reference a
            # variant or a selling unit (nothing to attach them to).
            if not custom:
                raise ValueError("product_id or pack_id is required")
            if self.variant_id is not None or self.selling_unit_id is not None:
                raise ValueError(
                    "variant_id/selling_unit_id are not supported on a "
                    "custom line"
                )
            if self.unit_price <= 0:
                raise ValueError(
                    "unit_price must be greater than zero on a custom line"
                )
            return self
        if custom:
            raise ValueError(
                "custom_name is only accepted on a line without product_id "
                "and pack_id"
            )
        if self.product_id is not None and self.pack_id is not None:
            raise ValueError("product_id and pack_id are mutually exclusive")
        if self.pack_id is not None:
            if self.variant_id is not None:
                raise ValueError(
                    "variant_id is not supported on a pack line"
                )
            if self.selling_unit_id is not None:
                raise ValueError(
                    "selling_unit_id is not supported on a pack line"
                )
        return self


class CreateSaleRequest(StrictBaseModel):
    """POST /sales checkout payload.

    Does NOT include client subtotal/total/change/debt — server computes them.

    ``items`` holds the cart's DISTINCT lines: 1..``MAX_SALE_LINES``
    (10 000) entries.  Quantity never counts toward the limit — 500 of
    product A plus 700 of product B is 2 lines; 10 000 different products
    at qty 1 is 10 000 lines.  Over the limit is a 422 raised during
    request validation, before any sale row, stock movement or payment
    is written.  Checkout remains ONE atomic transaction.
    """

    client_request_id: str = Field(..., min_length=1, max_length=100)
    items: list[SaleLineRequest] = Field(
        ..., min_length=1, max_length=MAX_SALE_LINES
    )
    customer_id: UUID | None = None
    invoice_discount: Decimal = Field(default=Decimal("0"), ge=0)
    payment_method: PaymentMethodLiteral = "cash"
    paid: Decimal = Field(..., ge=0)
    loyalty_reward_percent: Decimal = Field(
        default=Decimal("0"), ge=0, le=100
    )
    """Discount percentage the cashier selected for ONE loyalty reward.

    Percent ONLY — the client never submits a monetary discount or a
    balance; the server derives the DA value from this percent and the
    eligible base under a row lock, and consumes exactly 100 points
    (requires ``customer_id`` and an available reward).  0 (default) =
    no reward, so every existing client keeps its exact payload shape.
    """
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

    Phase 10 line shapes (GATE 6):
      product line  -> product_id set,  pack_id null
      pack summary  -> product_id null, pack_id set  (charged)
      pack component-> product_id set,  pack_id set  (line_total 0)
    """

    id: UUID
    product_id: UUID | None = None
    pack_id: UUID | None = None
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


class StoreInfo(StrictBaseModel):
    """Store identity carried on document headers (G19 — Phase 15).

    Additive and detail-only: never populated on list responses.
    """

    name: str


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
    # Phase 12 (§8): void attribution. Totals above are NEVER rewritten by
    # a void — these three columns are the only trace on the sale row.
    voided_at: datetime | None = None
    voided_by: UUID | None = None
    void_reason: str | None = None
    lines: list[SaleLineResponse] = Field(default_factory=list)
    payments: list[SalePaymentResponse] = Field(default_factory=list)
    idempotent_replay: bool = False
    unit_summary: str | None = None
    """Compact sold-units line for history rows (UX FIX #12 — FIX #1).

    e.g. ``"2 Box · 48 piece"`` — grouped by sold unit, first-seen order,
    capped at three groups (then ``+N``). Computed from the persisted line
    snapshots only: informational, never feeds totals or stock.
    """
    # G19 (Phase 15): additive display names for the sale DETAIL path
    # (print / detail screen). Lists never populate them — no N+1.
    customer_name: str | None = None
    cashier_name: str | None = None
    store: StoreInfo | None = None
    # Loyalty summary (Phase C): additive, NULL = pre-loyalty / facturation
    # sale.  Mirrors the five nullable sales columns verbatim — never
    # recomputed here, so a void or report path can never disagree.
    loyalty_points_earned: Decimal | None = None
    loyalty_cashback_earned: Decimal | None = None
    loyalty_points_redeemed: Decimal | None = None
    loyalty_redeemed_value: Decimal | None = None
    amount_due: Decimal | None = None
    """Payable after invoice discount minus redeemed loyalty value.

    Null on pre-loyalty rows; the legacy fallback for ``debt`` is
    ``total`` when this is null.
    """


class PriceOverride(StrictBaseModel):
    """Server corrected a client unit_price (documented price-change policy).

    ``product_id`` is null on a pack line and ``pack_id`` is null on a
    product line — exactly one of them identifies the corrected line.
    """

    line_index: int
    product_id: UUID | None = None
    pack_id: UUID | None = None
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
    product_id: UUID | None = None
    pack_id: UUID | None = None
    variant_id: UUID | None = None
    ok: bool
    message: str | None = None
    available_stock: Decimal | None = None
    required_quantity: Decimal | None = None
    unit_price: Decimal | None = None
    is_archived: bool = False


class CartValidateRequest(StrictBaseModel):
    items: list[SaleLineRequest] = Field(
        ..., min_length=1, max_length=MAX_SALE_LINES
    )
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
    # Exactly one of product_id / pack_id (same contract as SaleLineRequest).
    product_id: UUID | None = None
    pack_id: UUID | None = None
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
    # Phase 17 pricing — wholesale snapshot of the retail branch the line
    # was priced off (display only). Kept in the hold so a restored line can
    # re-price itself when its quantity crosses the threshold again; the
    # sale itself always recomputes the authoritative price server-side.
    # Optional so holds created before this change still validate.
    retail_price: str | None = None
    wholesale_price: str | None = None
    wholesale_min_qty: str | None = None
    # Method 2 — the automatic bundle plan must come back with the cart, or a
    # resumed line silently stops re-deriving its bundle discount.
    auto_bundle_quantity: str | None = None
    auto_bundle_price: str | None = None
    # Cart-only line state the POS sends in its own snapshot (see
    # CartLine.toJson): the cashier's MANUAL total and a price-only CUSTOM
    # line's identity. The hold is the cart's own snapshot — dropping these
    # would re-price a hand-fixed line on resume and could not represent a
    # custom item at all.
    manual_total: str | None = None
    custom_line: bool | None = None
    custom_ref: str | None = None
    # Mirrors the sale-line shape: a custom line carries its own name and
    # has neither a product nor a pack.
    custom_name: str | None = Field(default=None, max_length=200)

    @model_validator(mode="after")
    def _exactly_one_target(self) -> HoldCartItem:
        if self.product_id is None and self.pack_id is None:
            # Price-only custom line — the same third shape the sale schema
            # accepts, so a cart holding one can be suspended and resumed.
            if not (self.custom_name or "").strip():
                raise ValueError("product_id or pack_id is required")
            return self
        if self.product_id is not None and self.pack_id is not None:
            raise ValueError("product_id and pack_id are mutually exclusive")
        if (self.custom_name or "").strip():
            raise ValueError(
                "custom_name is only accepted on a line without product_id "
                "and pack_id"
            )
        return self


class HoldCreateRequest(StrictBaseModel):
    device_id: str | None = Field(default=None, max_length=100)
    customer_id: UUID | None = None
    items: list[HoldCartItem] = Field(..., min_length=1, max_length=MAX_SALE_LINES)
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
