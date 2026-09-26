"""Customer and debt schemas (Phase 8 search + Phase 9 management).

Money fields are Decimal — never float (Phase 0 money rule). JSON
serialization therefore emits decimal strings, matching the Phase 8
sale response convention; Flutter parses money as strings too.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field, field_validator

from app.schemas.common import StrictBaseModel


class CustomerResponse(StrictBaseModel):
    """Customer as returned by list/search/detail endpoints."""

    id: uuid.UUID
    name: str
    phone: str | None = None
    address: str | None = None
    balance: Decimal = Decimal("0")
    debt_ceiling: Decimal = Decimal("0")
    is_archived: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None


class CustomerListResponse(StrictBaseModel):
    items: list[CustomerResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class CustomerCreateRequest(StrictBaseModel):
    """POST /api/v1/customers — create a customer.

    ``balance`` is intentionally absent: it is a cached ledger projection
    and is never client-writable (Phase 9 rule).
    """

    name: str = Field(..., min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=30)
    address: str | None = None
    debt_ceiling: Decimal = Field(default=Decimal("0"), ge=0)

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("phone")
    @classmethod
    def _phone_empty_becomes_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class CustomerUpdateRequest(StrictBaseModel):
    """PUT /api/v1/customers/{id} — partial update (only sent fields change).

    ``balance`` is intentionally absent: never client-writable.
    """

    name: str | None = Field(default=None, max_length=200)
    phone: str | None = Field(default=None, max_length=30)
    address: str | None = None
    debt_ceiling: Decimal | None = Field(default=None, ge=0)

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("phone")
    @classmethod
    def _phone_empty_becomes_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


# ---------------------------------------------------------------------------
# Debt ledger
# ---------------------------------------------------------------------------


class DebtEntryResponse(StrictBaseModel):
    """One customer debt ledger row (append-only history)."""

    id: uuid.UUID
    customer_id: uuid.UUID
    entry_type: str
    amount: Decimal
    note: str | None = None
    reference_sale_id: uuid.UUID | None = None
    invoice_number: str | None = None
    user_id: uuid.UUID | None = None
    user_name: str | None = None
    entry_date: datetime
    created_at: datetime | None = None
    # Computed running balance AFTER this entry (sale +, payment -,
    # adjustment +0) - derived from the append-only ledger, never stored.
    balance_after: Decimal | None = None


class DebtHistoryResponse(StrictBaseModel):
    items: list[DebtEntryResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class DebtPaymentRequest(StrictBaseModel):
    """POST /api/v1/customers/{id}/pay — record a debt payment.

    ``client_request_id`` mirrors the Phase 8 sales idempotency contract:
    a repeat with the same key returns the original result without
    deducting the balance twice. Optional so the Phase 0 blueprint payload
    (amount + note) stays valid.
    """

    amount: Decimal = Field(..., gt=0, le=Decimal("999999999999.999"))
    note: str | None = Field(default=None, max_length=2000)
    client_request_id: str | None = Field(default=None, max_length=100)

    @field_validator("client_request_id")
    @classmethod
    def _blank_request_id_becomes_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class DebtPaymentResponse(StrictBaseModel):
    """Result of a payment command.

    ``balance`` is the customer's balance after this command executed —
    for an idempotent replay it is the customer's current balance.
    ``idempotent_replay`` marks repeats of the same ``client_request_id``.
    """

    id: uuid.UUID
    customer_id: uuid.UUID
    entry_type: str
    amount: Decimal
    balance: Decimal
    note: str | None = None
    client_request_id: str | None = None
    entry_date: datetime
    idempotent_replay: bool = False


class DebtSummaryResponse(StrictBaseModel):
    total_debt: Decimal
    customers_with_debt: int
