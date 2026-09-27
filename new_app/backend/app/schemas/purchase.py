"""Purchase schemas (Phase 11).

Money and quantity fields are Decimal — never float (Phase 0 money rule).
JSON serialization emits decimal strings; Flutter parses money as strings
(moneyToMilli). Document semantics (GATE 4/5):

- line.quantity   = document units (packages when purchase_unit_id set,
                    otherwise base units)
- line.unit_cost  = cost per document unit (per package for package lines)
- line_total      = quantity × unit_cost
- subtotal        = Σ line_total
- total           = subtotal − discount   (document discount only, no tax)
- paid            = amount settled at receipt (cash/credit/partial)
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field, field_validator

from app.schemas.common import StrictBaseModel

MONEY_MAX = Decimal("999999999999.999")
QTY_MAX = Decimal("999999999999.999")


class PurchaseLineRequest(StrictBaseModel):
    """One purchase line as submitted by clients."""

    product_id: uuid.UUID
    variant_id: uuid.UUID | None = None
    purchase_unit_id: uuid.UUID | None = None
    quantity: Decimal = Field(..., gt=0, le=QTY_MAX)
    unit_cost: Decimal = Field(..., ge=0, le=MONEY_MAX)


class PurchaseCreateRequest(StrictBaseModel):
    """POST /api/v1/purchases.

    ``receive=True`` (default) creates AND receives the document in ONE
    atomic transaction (Phase 0 blueprint parity). ``receive=False``
    saves an editable draft with no stock/PMP/payable effects.

    ``client_request_id`` mirrors the Phase 8/9 idempotency contract:
    a repeat with the same key returns the original purchase instead of
    receiving stock twice.
    """

    supplier_id: uuid.UUID
    lines: list[PurchaseLineRequest] = Field(..., min_length=1)
    discount: Decimal = Field(default=Decimal("0"), ge=0, le=MONEY_MAX)
    paid: Decimal = Field(default=Decimal("0"), ge=0, le=MONEY_MAX)
    note: str | None = Field(default=None, max_length=2000)
    device_id: str | None = Field(default=None, max_length=100)
    client_request_id: str | None = Field(default=None, max_length=100)
    receive: bool = True

    @field_validator("client_request_id")
    @classmethod
    def _blank_request_id_becomes_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class PurchaseUpdateRequest(StrictBaseModel):
    """PUT /api/v1/purchases/{id} — draft-only partial update.

    Only fields present in the body change. ``lines`` (when present)
    replace the whole line set and snapshots are recomputed. Received and
    cancelled documents are immutable (409 INVALID_PURCHASE_STATE).
    """

    supplier_id: uuid.UUID | None = None
    lines: list[PurchaseLineRequest] | None = Field(default=None, min_length=1)
    discount: Decimal | None = Field(default=None, ge=0, le=MONEY_MAX)
    paid: Decimal | None = Field(default=None, ge=0, le=MONEY_MAX)
    note: str | None = Field(default=None, max_length=2000)
    device_id: str | None = Field(default=None, max_length=100)


class PurchaseLineResponse(StrictBaseModel):
    """Stored purchase line with historical snapshots (GATE 15)."""

    id: uuid.UUID
    product_id: uuid.UUID
    variant_id: uuid.UUID | None = None
    product_name: str
    product_sku: str | None = None
    product_barcode: str | None = None
    product_unit: str
    purchase_unit_id: uuid.UUID | None = None
    purchase_unit_name: str | None = None
    unit_multiplier: Decimal | None = None
    quantity: Decimal
    unit_cost: Decimal
    base_qty_equivalent: Decimal | None = None
    line_total: Decimal


class PurchaseResponse(StrictBaseModel):
    """Purchase header + lines as returned by the API."""

    id: uuid.UUID
    invoice_number: str
    status: str
    supplier_id: uuid.UUID
    supplier_name: str | None = None
    user_id: uuid.UUID | None = None
    subtotal: Decimal
    discount: Decimal
    total: Decimal
    paid: Decimal
    note: str | None = None
    device_id: str | None = None
    client_request_id: str | None = None
    purchase_date: datetime
    received_at: datetime | None = None
    cancelled_at: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    lines: list[PurchaseLineResponse] = Field(default_factory=list)
    idempotent_replay: bool = False


class PurchaseListResponse(StrictBaseModel):
    items: list[PurchaseResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1
