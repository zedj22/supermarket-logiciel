"""Return / void schemas (Phase 12).

Money and quantity fields are Decimal — never float (Phase 0 money rule).
JSON serialization emits decimal strings; Flutter parses money as strings.

Document semantics (decision record §12):
- line.quantity      = quantity in the SOURCE LINE's own unit (linked) or
                       in base units (independent)
- line.quantity_base = base units actually restored to stock (§15)
- line.line_total    = pro-rata refund for that line, net of the line
                       discount (§12); sums to ``subtotal``
- header.subtotal    = Σ line.line_total
- header.discount    = invoice-discount share (linked returns only)
- header.total       = subtotal − discount = refund due

``POST /sales/{id}/void`` and ``POST /returns`` never rewrite the sale
snapshot (§8): the void response only reports what was reversed.
"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Literal, get_args
from uuid import UUID

from pydantic import ConfigDict, Field, field_validator

from app.core.constants import MAX_SALE_LINES
from app.schemas.common import StrictBaseModel
from app.schemas.sale import SaleResponse

MONEY_MAX = Decimal("999999999999.999")
QTY_MAX = Decimal("999999999999.999")

ReturnReasonLiteral = Literal[
    "defective", "wrong_item", "customer_change", "expired", "other"
]

# Supported return-reason vocabulary. A supplied reason must be one of
# these; an ABSENT reason is equally valid (Phase 12 fix round 1).
RETURN_REASONS: frozenset[str] = frozenset(get_args(ReturnReasonLiteral))


class ReturnLineRequest(StrictBaseModel):
    """One requested return line.

    Exactly one target per line (mirror of the Phase 10 sale-line rule):

    * ``sale_line_id`` set → linked line; the source sale line decides the
      product / pack / variant / unit snapshots. Any of ``product_id``,
      ``variant_id``, ``pack_id`` that is present must match that line.
    * ``sale_line_id`` absent → independent line; ``product_id`` is
      required (``pack_id`` is rejected: pack restoration must derive its
      components from a sale's own lines, never from today's pack_items).

    quantity is in the source line's own unit for a linked line (selling
    unit when the sale used one) and in base units for an independent one.
    """

    sale_line_id: UUID | None = None
    product_id: UUID | None = None
    variant_id: UUID | None = None
    pack_id: UUID | None = None
    quantity: Decimal = Field(..., gt=0, le=QTY_MAX)


class ReturnCreateRequest(StrictBaseModel):
    """POST /api/v1/returns — posts a fully-formed return document (§9).

    ``client_request_id`` is required (§16 idempotency): a repeat with the
    same key returns the original document with ``idempotent_replay=true``.

    ``reason`` is OPTIONAL for both linked and independent returns (Phase 12
    fix round 1, product-owner decision): omitted, ``null`` and blank all
    mean "no reason" and persist as NULL. A supplied reason must still be
    one of the supported vocabulary values. Authorization of a return stays
    actor + audit row (§10). Voiding keeps its own mandatory reason.

    ``lines`` holds the DISTINCT return lines: 1..``MAX_SALE_LINES``
    (10 000) entries — the SAME cap as ``CreateSaleRequest.items``, so every
    sale the POS can create can also be returned in full (quantity never
    counts toward the limit). Over the cap is a 422 raised during request
    validation, before any write.
    """

    client_request_id: str = Field(..., min_length=1, max_length=100)
    sale_id: UUID | None = None
    customer_id: UUID | None = None
    reason: str | None = None
    note: str | None = Field(default=None, max_length=2000)
    lines: list[ReturnLineRequest] = Field(
        ..., min_length=1, max_length=MAX_SALE_LINES
    )
    device_id: str | None = Field(default=None, max_length=100)
    # §22 spells the device field ``device``; ``device_id`` matches every
    # other request schema in this API. Both are accepted, header wins.
    device: str | None = Field(default=None, max_length=100)

    @field_validator("client_request_id")
    @classmethod
    def _non_blank_request_id(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("client_request_id must not be blank")
        return stripped

    @field_validator("reason")
    @classmethod
    def _optional_reason(cls, v: str | None) -> str | None:
        """Optional reason: None / blank → no reason (NULL).

        When a reason IS supplied it must belong to the supported
        vocabulary — an unknown value is still a 422.
        """
        if v is None:
            return None
        stripped = v.strip()
        if not stripped:
            return None
        if stripped not in RETURN_REASONS:
            raise ValueError(
                "reason must be one of: "
                + ", ".join(sorted(RETURN_REASONS))
            )
        return stripped

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class VoidRequest(StrictBaseModel):
    """POST /api/v1/sales/{sale_id}/void — reason is mandatory (§8).

    Blank after strip → 422, mirroring the Phase 7 "reason required on
    decrease" convention. The typed reason lands on ``sales.void_reason``.
    """

    reason: str = Field(..., min_length=1, max_length=500)

    @field_validator("reason")
    @classmethod
    def _non_blank_reason(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("reason must not be blank")
        return stripped


class ReturnLineResponse(StrictBaseModel):
    """Persisted return line with historical snapshots (§5).

    Fields are copied from the source sale line (or the catalog for an
    independent return) at posting time and never re-read later.
    """

    id: UUID
    sale_line_id: UUID | None = None
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
    quantity_base: Decimal | None = None
    line_discount: Decimal
    line_total: Decimal


class ReturnResponse(StrictBaseModel):
    """Return header + lines."""

    id: UUID
    return_number: str
    sale_id: UUID | None = None
    invoice_number: str | None = None
    customer_id: UUID | None = None
    user_id: UUID | None = None
    # Optional (Phase 12 fix round 1): NULL when the operator gave none.
    reason: str | None = None
    subtotal: Decimal
    discount: Decimal
    total: Decimal
    note: str | None = None
    device_id: str | None = None
    client_request_id: str | None = None
    return_date: datetime
    lines: list[ReturnLineResponse] = Field(default_factory=list)


class ReturnListResponse(StrictBaseModel):
    """Paginated return history (§22 filters arrive as query params)."""

    items: list[ReturnResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class ReturnCreateResponse(StrictBaseModel):
    """POST /api/v1/returns result.

    ``credit_reversed`` is the debt portion actually forgiven (§17) and
    ``cash_pending = refund_total − credit_reversed`` is the still-owed
    cash/card refund, which Phase 12 records but does not execute (§18).
    """

    model_config = ConfigDict(
        from_attributes=True,
        str_strip_whitespace=True,
        populate_by_name=True,
    )

    return_: ReturnResponse = Field(..., alias="return")
    idempotent_replay: bool = False
    refund_total: Decimal
    credit_reversed: Decimal
    cash_pending: Decimal


class VoidResponse(StrictBaseModel):
    """POST /api/v1/sales/{sale_id}/void result (§8, §18).

    ``refund_due`` is ``sale.total`` — the sale snapshot is never
    rewritten, so the refund base is the original invoice total.
    """

    sale: SaleResponse
    credit_reversed: Decimal
    refund_due: Decimal
    cash_pending: Decimal
