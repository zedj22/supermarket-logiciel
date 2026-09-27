"""Pydantic schemas for packs / bundles (Phase 10).

Request/response schemas for the pack module. Money and quantity fields
use Decimal to match the NUMERIC(18,3) columns — never binary float for
persisted business values.

Decisions applied here (docs/PHASE_10_PACKS_ANALYSIS.md):
- GATE 1: a component targets a BASE PRODUCT only. ``variant_id`` is
  accepted on the wire solely so it can be rejected with a clear 422
  instead of being silently ignored (StrictBaseModel ignores unknown keys).
  Selling units (Phase 10 fix round) are NOT a variant path: they only
  scale the quantity of that same base product via the Phase 6 rule
  ``base = quantity × multiplier``.
- GATE 3: ``price >= 0`` (0 allowed, negative rejected); no auto discount.
- ``components`` on create must be non-empty; on update they are optional
  and, when present, replace the whole component set.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import Field, field_validator, model_validator

from app.schemas.common import StrictBaseModel

PACK_NAME_MAX = 200
PACK_BARCODE_MAX = 50
PACK_MAX_COMPONENTS = 100
PACK_MAX_QUANTITY = Decimal("999999")


# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------


class PackComponentRequest(StrictBaseModel):
    """One component of a pack.

    ``quantity`` is expressed in the SELECTED UNIT:
    - ``selling_unit_id is None`` → base units (GATE 2, unchanged: a legacy
      client that never sends a unit keeps its exact old meaning),
    - ``selling_unit_id`` set → quantity in that selling unit; the service
      converts it with the Phase 6 rule ``base = quantity × multiplier``
      before persisting.

    Fractional quantities are allowed (weighted packs). ``variant_id`` is
    accepted on the wire solely so it can be rejected with a clear 422 —
    variants in packs remain unsupported (GATE 1).
    """

    product_id: UUID
    variant_id: UUID | None = None
    selling_unit_id: UUID | None = None
    quantity: Decimal = Field(..., gt=0, le=PACK_MAX_QUANTITY)

    @model_validator(mode="after")
    def _no_variant_target(self) -> PackComponentRequest:
        """GATE 1 — variants in packs remain an unresolved Phase 0 decision.

        Reject loudly rather than silently dropping the field.
        """
        if self.variant_id is not None:
            raise ValueError(
                "variant_id is not supported on pack components; "
                "a pack component must target a base product"
            )
        return self

    @field_validator("quantity")
    @classmethod
    def _positive_quantity(cls, value: Decimal) -> Decimal:
        if value <= 0:
            raise ValueError("component quantity must be > 0")
        return value


class PackComponentResponse(StrictBaseModel):
    """Component as returned by pack detail (with live catalog context).

    Everything the edit form needs to hydrate a row without re-selecting
    anything: product identity/name, the selected selling unit (snapshot),
    the quantity in that unit AND the resolved base quantity, plus the
    product's current ``avg_cost`` (Phase 7 PMP) for the informational
    profitability preview.

    ``quantity`` stays BASE units per pack (GATE 2). ``unit_quantity`` is
    the same value expressed in the selected unit — for legacy rows
    (``selling_unit_id`` NULL) it equals ``quantity`` (base ×1).
    """

    product_id: UUID
    product_name: str
    product_unit: str
    product_price: Decimal
    quantity: Decimal
    # Selling-unit identity + snapshot (NULL = product base unit).
    selling_unit_id: UUID | None = None
    selling_unit_name: str | None = None
    selling_unit_multiplier: Decimal | None = None
    unit_quantity: Decimal
    base_quantity: Decimal
    # Informational only — current PMP (Phase 7), never a persisted pack cost.
    avg_cost: Decimal = Decimal("0")


# ---------------------------------------------------------------------------
# Pack create / update
# ---------------------------------------------------------------------------


class PackCreateRequest(StrictBaseModel):
    """POST /api/v1/packs."""

    name: str = Field(..., min_length=1, max_length=PACK_NAME_MAX)
    barcode: str | None = Field(default=None, max_length=PACK_BARCODE_MAX)
    price: Decimal = Field(..., ge=0)
    is_active: bool = True
    image_path: str | None = Field(default=None, max_length=500)
    components: list[PackComponentRequest] = Field(
        ..., min_length=1, max_length=PACK_MAX_COMPONENTS
    )

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, value: str) -> str:
        stripped = value.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("barcode")
    @classmethod
    def _blank_barcode_is_none(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


class PackUpdateRequest(StrictBaseModel):
    """PUT /api/v1/packs/{id} — partial update.

    ``components`` replaces the whole component set when present; when
    omitted the existing set is left untouched.
    """

    name: str | None = Field(None, min_length=1, max_length=PACK_NAME_MAX)
    barcode: str | None = Field(default=None, max_length=PACK_BARCODE_MAX)
    price: Decimal | None = Field(default=None, ge=0)
    is_active: bool | None = None
    image_path: str | None = Field(default=None, max_length=500)
    components: list[PackComponentRequest] | None = Field(
        default=None, min_length=1, max_length=PACK_MAX_COMPONENTS
    )

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("barcode")
    @classmethod
    def _blank_barcode_is_none(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


# ---------------------------------------------------------------------------
# Pack responses
# ---------------------------------------------------------------------------


class PackResponse(StrictBaseModel):
    """Pack as returned by list/detail (components only on detail)."""

    id: UUID
    name: str
    barcode: str | None = None
    price: Decimal
    is_active: bool
    is_archived: bool = False
    archived_at: datetime | None = None
    image_path: str | None = None
    components_count: int = 0
    sum_of_parts: Decimal | None = None
    created_at: datetime
    updated_at: datetime


class PackDetailResponse(PackResponse):
    """Pack detail: list fields plus the resolved component rows.

    The three ``estimated_*`` fields are an INFORMATIONAL preview of the
    current profitability computed from each component's live
    ``avg_cost`` (Phase 7 PMP):

        estimated_cost          = Σ(base_quantity × avg_cost)
        estimated_profit        = price − estimated_cost
        estimated_margin_pct    = estimated_profit / price × 100

    Nothing is persisted (no packs.cost / margin / COGS columns) and this
    is not an accounting figure. ``estimated_margin_percent`` is ``null``
    when ``price == 0`` — the ratio is undefined, never divided by zero.
    """

    components: list[PackComponentResponse] = Field(default_factory=list)
    estimated_cost: Decimal = Decimal("0")
    estimated_profit: Decimal = Decimal("0")
    estimated_margin_percent: Decimal | None = None


class PackListResponse(StrictBaseModel):
    """Paginated pack list (implemented envelope convention, GATE 12)."""

    items: list[PackResponse]
    total: int
    page: int
    page_size: int
    pages: int


# ---------------------------------------------------------------------------
# Availability (read-only — never reserves or mutates stock)
# ---------------------------------------------------------------------------


class PackComponentAvailability(StrictBaseModel):
    """Component stock position for a requested pack quantity.

    All stock comparisons happen in BASE units (``required_*`` vs
    ``available_quantity``) because ``pack_items.quantity`` is base units —
    exactly what the sale will deduct. The ``unit_*`` fields exist so the
    UI can spell the conversion out: ``2 Box = 48 Piece``.
    """

    product_id: UUID
    product_name: str
    product_unit: str
    # Base-unit figures (authoritative — same source the sale uses).
    required_per_pack: Decimal
    required_quantity: Decimal
    available_quantity: Decimal
    ok: bool
    # Selected selling unit (snapshot; NULL = product base unit).
    selling_unit_id: UUID | None = None
    selling_unit_name: str | None = None
    selling_unit_multiplier: Decimal | None = None
    # Same figures expressed in the selected unit.
    unit_quantity: Decimal
    required_unit_quantity: Decimal


class PackAvailabilityResponse(StrictBaseModel):
    """GET /api/v1/packs/{id}/availability — informational only."""

    pack_id: UUID
    pack_name: str
    price: Decimal
    is_active: bool
    is_archived: bool
    quantity: Decimal
    saleable: bool
    max_pack_quantity: Decimal
    sum_of_parts: Decimal | None = None
    components: list[PackComponentAvailability] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)
