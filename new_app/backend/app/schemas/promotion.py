"""Promotion schemas (Phase 18).

Money fields are Decimal — never float (Phase 0 money rule); JSON emits
decimal strings and Flutter parses money as strings.

Business rules encoded here:
- ``client_request_id`` REQUIRED on create (idempotent, expenses pattern)
- ``name`` required, trimmed, 1..200, blank rejected
- ``promotion_type`` must be one of {percentage, fixed_price}
- ``value`` Decimal >= 0 (percent range 0 < v <= 100 is checked in the
  service so the error carries a stable code, INVALID_PROMOTION_VALUE)
- ``product_ids`` >= 1 — the bulk apply payload (one transactional
  request, never a per-product loop)
- multi-product + fixed_price is rejected in the SERVICE with 422
  MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED (also guarded in the Flutter UI)
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field, field_validator

from app.schemas.common import StrictBaseModel

# Same bound the expense money fields use (NUMERIC(18,3) column).
MONEY_MAX = Decimal("999999999999.999")

PROMOTION_TYPES = ("percentage", "fixed_price")


class PromotionProductRef(StrictBaseModel):
    """Lightweight product reference inside a promotion response."""

    id: uuid.UUID
    name: str


class PromotionCreateRequest(StrictBaseModel):
    """POST /api/v1/promotions.

    ``client_request_id`` is required: a repeat with the same key and the
    same payload returns the original promotion with
    ``idempotent_replay=true``; a different payload is 409
    IDEMPOTENCY_CONFLICT.
    """

    client_request_id: str = Field(..., min_length=1, max_length=100)
    name: str = Field(..., min_length=1, max_length=200)
    promotion_type: str = Field(default="percentage", max_length=20)
    value: Decimal = Field(..., ge=0, max_digits=18, decimal_places=3)
    product_ids: list[uuid.UUID] = Field(..., min_length=1)
    is_active: bool = True

    @field_validator("client_request_id")
    @classmethod
    def _non_blank_request_id(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("client_request_id must not be blank")
        return stripped

    @field_validator("name")
    @classmethod
    def _non_blank_name(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("promotion_type")
    @classmethod
    def _known_type(cls, v: str) -> str:
        stripped = (v or "").strip()
        if stripped not in PROMOTION_TYPES:
            allowed = ", ".join(PROMOTION_TYPES)
            raise ValueError(f"promotion_type must be one of: {allowed}")
        return stripped

    @field_validator("product_ids")
    @classmethod
    def _dedupe_product_ids(cls, v: list[uuid.UUID]) -> list[uuid.UUID]:
        # A multi-select can submit the same product twice; membership is
        # a set, so duplicates collapse silently (order preserved).
        return list(dict.fromkeys(v))


class PromotionUpdateRequest(StrictBaseModel):
    """PUT /api/v1/promotions/{id} — partial update.

    Unset fields are preserved; ``product_ids`` replaces the whole set.
    """

    name: str | None = Field(None, min_length=1, max_length=200)
    promotion_type: str | None = Field(None, max_length=20)
    value: Decimal | None = Field(None, ge=0, max_digits=18, decimal_places=3)
    product_ids: list[uuid.UUID] | None = Field(None, min_length=1)
    is_active: bool | None = None

    @field_validator("name")
    @classmethod
    def _non_blank_name(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("promotion_type")
    @classmethod
    def _known_type(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        if stripped not in PROMOTION_TYPES:
            allowed = ", ".join(PROMOTION_TYPES)
            raise ValueError(f"promotion_type must be one of: {allowed}")
        return stripped

    @field_validator("product_ids")
    @classmethod
    def _dedupe_product_ids(
        cls, v: list[uuid.UUID] | None
    ) -> list[uuid.UUID] | None:
        if v is None:
            return None
        return list(dict.fromkeys(v))


class PromotionResponse(StrictBaseModel):
    """One promotion as returned by the API."""

    id: uuid.UUID
    name: str
    promotion_type: str
    value: Decimal
    is_active: bool
    products: list[PromotionProductRef] = Field(default_factory=list)
    product_ids: list[uuid.UUID] = Field(default_factory=list)
    product_count: int = 0
    client_request_id: str | None = None
    created_by: uuid.UUID | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    idempotent_replay: bool = False


class ProductPromotionInfo(StrictBaseModel):
    """Active promotion attached to a product response (POS display).

    ``price`` is the SERVER-computed effective promotional unit price for
    this product (Decimal, quantized to 0.001) — clients never re-derive
    it from the percent, so every surface agrees on the same number.
    """

    id: uuid.UUID
    name: str
    promotion_type: str
    value: Decimal
    price: Decimal
