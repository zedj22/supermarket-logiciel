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


# ---------------------------------------------------------------------------
# Suppliers (Phase 11)
# ---------------------------------------------------------------------------


class SupplierResponse(StrictBaseModel):
    """Supplier as returned by list/detail endpoints.

    ``balance`` is the cached supplier-ledger projection — reads only;
    it is never accepted on create/update (server-owned, Phase 11).
    """

    id: uuid.UUID
    name: str
    phone: str | None = None
    address: str | None = None
    email: str | None = None
    contact_person: str | None = None
    notes: str | None = None
    balance: Decimal = Decimal("0")
    is_archived: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None


class SupplierListResponse(StrictBaseModel):
    items: list[SupplierResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


def _strip_blank(v: str | None) -> str | None:
    if v is None:
        return None
    stripped = v.strip()
    return stripped or None


class SupplierCreateRequest(StrictBaseModel):
    """POST /api/v1/suppliers — create a supplier.

    ``balance`` is intentionally absent: cached ledger projection, never
    client-writable (same rule as customers, Phase 9). Duplicate names
    are allowed (customer/legacy parity — no unique constraint).
    """

    name: str = Field(..., min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=30)
    address: str | None = None
    email: str | None = Field(default=None, max_length=100)
    contact_person: str | None = Field(default=None, max_length=100)
    notes: str | None = None

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("phone", "email", "contact_person")
    @classmethod
    def _blank_becomes_none(cls, v: str | None) -> str | None:
        return _strip_blank(v)


class SupplierUpdateRequest(StrictBaseModel):
    """PUT /api/v1/suppliers/{id} — partial update (only sent fields change).

    ``balance`` is intentionally absent: never client-writable.
    """

    name: str | None = Field(default=None, max_length=200)
    phone: str | None = Field(default=None, max_length=30)
    address: str | None = None
    email: str | None = Field(default=None, max_length=100)
    contact_person: str | None = Field(default=None, max_length=100)
    notes: str | None = None

    @field_validator("name")
    @classmethod
    def _name_not_blank(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        if not stripped:
            raise ValueError("name must not be blank")
        return stripped

    @field_validator("phone", "email", "contact_person")
    @classmethod
    def _blank_becomes_none(cls, v: str | None) -> str | None:
        return _strip_blank(v)


# ---------------------------------------------------------------------------
# Supplier ledger (Phase 11)
# ---------------------------------------------------------------------------


class SupplierLedgerEntryResponse(StrictBaseModel):
    """One supplier ledger row (append-only payables history)."""

    id: uuid.UUID
    supplier_id: uuid.UUID
    entry_type: str  # purchase | payment | purchase_cancel
    amount: Decimal
    note: str | None = None
    reference_purchase_id: uuid.UUID | None = None
    invoice_number: str | None = None
    user_id: uuid.UUID | None = None
    user_name: str | None = None
    entry_date: datetime
    created_at: datetime | None = None
    # Computed running balance AFTER this entry (purchase +, payment -,
    # purchase_cancel -) — derived from the ledger, never stored.
    balance_after: Decimal | None = None


class SupplierLedgerResponse(StrictBaseModel):
    items: list[SupplierLedgerEntryResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class SupplierPaymentRequest(StrictBaseModel):
    """POST /api/v1/suppliers/{id}/payments — record a supplier payment.

    ``client_request_id`` mirrors the Phase 9 contract: a repeat with the
    same key returns the original result without deducting twice.
    Optional so a bare amount payload stays valid.
    """

    amount: Decimal = Field(..., gt=0, le=Decimal("999999999999.999"))
    note: str | None = Field(default=None, max_length=2000)
    client_request_id: str | None = Field(default=None, max_length=100)

    @field_validator("client_request_id")
    @classmethod
    def _blank_request_id_becomes_none(cls, v: str | None) -> str | None:
        return _strip_blank(v)


class SupplierPaymentResponse(StrictBaseModel):
    """Result of a supplier payment command.

    ``balance`` is the supplier's balance after this command executed —
    for an idempotent replay it is the current balance.
    """

    id: uuid.UUID
    supplier_id: uuid.UUID
    entry_type: str
    amount: Decimal
    balance: Decimal
    note: str | None = None
    client_request_id: str | None = None
    entry_date: datetime
    idempotent_replay: bool = False
