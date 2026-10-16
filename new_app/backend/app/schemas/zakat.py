"""Zakat calculation API schemas.

Money validation mirrors the house rules (Decimal, ``0 <= value <=
MONEY_MAX``); the calculation payload is accepted once and the *server*
is the only place the formula runs — the client never multiplies.

``ZakatCalculateRequest`` is also what a saved snapshot stores verbatim
(``inputs`` JSON), so a saved calculation is fully reproducible.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import Field, model_validator

from app.schemas.common import StrictBaseModel

MONEY_MAX = Decimal("999999999999.999")

#: One page of imported inventory lines returned by the context endpoint.
INVENTORY_LINES_LIMIT = 500
#: Hard cap on operator-entered line items per section.
LINE_ITEMS_MAX = 200

InventoryBasisLiteral = Literal["market", "cost", "override"]
DebtTreatmentLiteral = Literal["deduct_all", "deduct_due_only", "no_deduction"]
PaymentMethodLiteral = Literal["cash", "transfer", "cheque", "other"]


class ZakatLineInput(StrictBaseModel):
    """One operator-entered amount (cash item, extra receivable, debt)."""

    label: str = Field(min_length=1, max_length=120)
    amount: Decimal = Field(ge=0, le=MONEY_MAX)
    #: Liability lines only: None = due status unknown.
    due: bool | None = None


class ZakatCalculateRequest(StrictBaseModel):
    """Everything needed to run one calculation (also the stored input)."""

    zakat_date: date
    hawl_start_date: date | None = None

    gold_price_per_gram: Decimal | None = Field(None, ge=0, le=MONEY_MAX)
    nisab_override: Decimal | None = Field(None, ge=0, le=MONEY_MAX)

    inventory_basis: InventoryBasisLiteral = "market"
    inventory_override_value: Decimal | None = Field(None, ge=0, le=MONEY_MAX)
    inventory_override_reason: str | None = Field(None, max_length=255)
    use_imported_inventory: bool = True
    excluded_product_ids: list[uuid.UUID] = Field(default_factory=list)

    cash_provided: bool = False
    cash_items: list[ZakatLineInput] = Field(default_factory=list)

    collectible_receivables: Decimal | None = Field(None, ge=0, le=MONEY_MAX)
    doubtful_receivables: Decimal | None = Field(None, ge=0, le=MONEY_MAX)
    other_receivable_items: list[ZakatLineInput] = Field(default_factory=list)

    debt_treatment: DebtTreatmentLiteral = "deduct_all"
    liability_items: list[ZakatLineInput] = Field(default_factory=list)

    notes: str | None = Field(None, max_length=500)

    @model_validator(mode="after")
    def _check_rules(self) -> "ZakatCalculateRequest":
        if self.hawl_start_date is not None and self.hawl_start_date > self.zakat_date:
            raise ValueError("hawl_start_date must not be after zakat_date")
        if self.inventory_basis == "override":
            if self.inventory_override_value is None:
                raise ValueError(
                    "inventory_override_value is required when "
                    "inventory_basis is 'override'"
                )
            if not (self.inventory_override_reason or "").strip():
                raise ValueError(
                    "inventory_override_reason is required when "
                    "inventory_basis is 'override'"
                )
        if self.nisab_override is not None and self.gold_price_per_gram is not None:
            raise ValueError(
                "provide either gold_price_per_gram or nisab_override, not both"
            )
        for name, items in (
            ("cash_items", self.cash_items),
            ("other_receivable_items", self.other_receivable_items),
            ("liability_items", self.liability_items),
        ):
            if len(items) > LINE_ITEMS_MAX:
                raise ValueError(f"{name} exceeds the {LINE_ITEMS_MAX} item limit")
        if len(self.excluded_product_ids) > LINE_ITEMS_MAX:
            raise ValueError(
                f"excluded_product_ids exceeds the {LINE_ITEMS_MAX} item limit"
            )
        return self


class ZakatWarningModel(StrictBaseModel):
    code: str
    detail: dict[str, str] = Field(default_factory=dict)


class ZakatResultResponse(StrictBaseModel):
    """Mirror of ``app.domain.zakat.ZakatResult`` on the wire."""

    zakat_date: date
    status: str
    missing_fields: list[str]
    warnings: list[ZakatWarningModel]

    hawl_start_date: date | None
    hawl_days_elapsed: int | None
    hawl_completed: bool | None

    gold_price_per_gram: Decimal | None
    nisab_amount: Decimal | None
    nisab_source: str | None

    inventory_basis: str
    inventory_value: Decimal | None
    inventory_source: str
    inventory_imported_value: Decimal | None
    inventory_excluded_value: Decimal
    inventory_product_count: int
    inventory_included_count: int

    cash_provided: bool
    cash_total: Decimal | None
    cash_item_count: int

    collectible_receivables: Decimal | None
    doubtful_receivables: Decimal | None
    other_receivables_total: Decimal
    receivables_included_total: Decimal | None
    receivable_item_count: int

    debt_treatment: str
    liabilities_total_entered: Decimal
    deductions_applied: Decimal
    liabilities_skipped_amount: Decimal
    liabilities_skipped_count: int
    liability_item_count: int

    net_zakatable: Decimal
    zakat_rate: Decimal
    zakat_due: Decimal | None
    provisional_zakat_due: Decimal | None
    reaches_nisab: bool | None
    eligibility_reasons: list[str]


class ZakatInventoryLine(StrictBaseModel):
    product_id: uuid.UUID
    name: str
    unit: str
    quantity: Decimal
    market_unit_price: Decimal
    cost_unit_price: Decimal
    market_value: Decimal
    cost_value: Decimal


class ZakatContextInventory(StrictBaseModel):
    product_count: int
    total_market_value: Decimal
    total_cost_value: Decimal
    truncated: bool
    lines: list[ZakatInventoryLine]


class ZakatDebtor(StrictBaseModel):
    customer_id: uuid.UUID
    name: str
    phone: str | None
    balance: Decimal


class ZakatPayable(StrictBaseModel):
    supplier_id: uuid.UUID
    name: str
    phone: str | None
    balance: Decimal


class ZakatContextReceivables(StrictBaseModel):
    ledger_total: Decimal
    debtor_count: int
    debtors: list[ZakatDebtor]


class ZakatContextLiabilities(StrictBaseModel):
    supplier_balance_total: Decimal
    supplier_count: int
    suppliers: list[ZakatPayable]


class OfficialNisabReference(StrictBaseModel):
    hijri_year: int
    amount: Decimal
    gold_price_per_gram: Decimal
    purity: str
    source: str
    note: str


class ZakatDefaults(StrictBaseModel):
    zakat_rate: Decimal
    hawl_days: int
    nisab_gold_grams: Decimal
    inventory_basis: InventoryBasisLiteral
    debt_treatment: DebtTreatmentLiteral


class ZakatContext(StrictBaseModel):
    """One call that seeds the whole screen (form defaults + imports)."""

    store_name: str
    store_phone: str
    store_address: str
    today: date
    official_nisab_reference: OfficialNisabReference
    defaults: ZakatDefaults
    inventory: ZakatContextInventory
    receivables_reference: ZakatContextReceivables
    liabilities_reference: ZakatContextLiabilities


class ZakatCalculateResponse(StrictBaseModel):
    store_name: str
    generated_at: datetime
    result: ZakatResultResponse


class ZakatCalculationCreateRequest(StrictBaseModel):
    """Save one calculation as an immutable snapshot (idempotent)."""

    client_request_id: str = Field(min_length=8, max_length=120)
    calculation: ZakatCalculateRequest
    notes: str | None = Field(None, max_length=500)


class ZakatPaymentCreateRequest(StrictBaseModel):
    """Record one actual zakat payment against a saved calculation."""

    client_request_id: str = Field(min_length=8, max_length=120)
    amount: Decimal = Field(gt=0, le=MONEY_MAX)
    method: PaymentMethodLiteral = "cash"
    paid_at: date | None = None
    note: str | None = Field(None, max_length=255)


class ZakatPaymentResponse(StrictBaseModel):
    id: uuid.UUID
    calculation_id: uuid.UUID
    amount: Decimal
    method: str
    paid_at: date
    note: str | None
    created_by: uuid.UUID | None
    created_at: datetime


class ZakatCalculationSummary(StrictBaseModel):
    id: uuid.UUID
    zakat_date: date
    status: str
    net_zakatable: Decimal
    zakat_due: Decimal | None
    provisional_zakat_due: Decimal | None
    nisab_amount: Decimal | None
    reaches_nisab: bool | None
    hawl_completed: bool | None
    payments_total: Decimal
    notes: str | None
    created_by: uuid.UUID | None
    created_at: datetime


class ZakatCalculationDetail(ZakatCalculationSummary):
    """Full snapshot: summary + stored result + the exact stored inputs."""

    result: ZakatResultResponse
    inputs: ZakatCalculateRequest
    payments: list[ZakatPaymentResponse] = Field(default_factory=list)
