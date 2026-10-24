"""Zakat al-Tijarah (commercial goods) calculation domain — Klick POS.

This module is a *transparent, configurable calculation aid*. It never
touches sales, inventory, accounting or POS data — it reads the values
the operator provides (plus optional imported stock totals) and returns
a result the operator can inspect, save as a snapshot and export.

Official reference (Algerian Ministry of Religious Affairs and
Endowments, marw.gov.dz, page “كيف تحسب زكاة مالك؟”):

- Nisab = the value of 85 grams of gold.
- The nisab published by the Ministry for the year 1447 is 2,295,000 DA
  (85 g × 27,000 DA/g, AGENOR 18k gold). It is exposed through
  ``OFFICIAL_NISAB_REFERENCE`` as a *reference only*: this engine never
  silently adopts it. The nisab actually used in a calculation comes
  either from the gold price the operator enters (85 × price) or from an
  explicit manual override.
- Rate = 2.5 % of the zakatable net, computed with the published formula
  ``(amount × 2.5) / 100``.
- One full lunar year (hawl, ~354 days) must complete while the wealth
  is held before zakat is due.
- Commercial goods are valued at market price on the zakat day, plus
  cash and expected (collectible) receivables, minus merchant debts.
- Confirmed collectible debts are taxed at recovery; doubtful debts are
  taxed at 2.5 % only when actually recovered — so doubtful amounts are
  never added to the zakatable base here (they stay informational).

Default method (labelled “official ministry formula” in the UI):

- inventory: every in-stock product line at its current selling price as
  the market-price proxy (no live market feed exists in this app),
- cash: operator-entered (the drawer is not aggregated automatically),
- receivables: operator-entered collectible amount; the customer debt
  ledger total is imported as a *reference* to detect double counting,
- debts: all entered liabilities are deducted (``deduct_all``).

Any missing input makes the result ``provisional``: the estimate is
still shown (``provisional_zakat_due``) but ``zakat_due`` stays
``None`` so a provisional number can never be mistaken for a settled
figure.  The zakat due is only a *final* amount when the nisab and the
hawl are both known, every zakatable input was provided, the net is not
negative and the hawl has completed.

All money math is Decimal and is quantized only through
``quantize_money`` (NUMERIC(18,3), ROUND_HALF_EVEN).
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal
from typing import Sequence

from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money

#: Zakat rate — 2.5 %, the published value.
ZAKAT_RATE = Decimal("0.025")
#: Rate in percent, used by the PDF/UI formula line `(net × 2.5) / 100`.
ZAKAT_RATE_PCT = Decimal("2.5")
#: Nisab is the value of this many grams of gold.
NISAB_GOLD_GRAMS = Decimal("85")
#: One lunar (Hijri) year in solar days — the conservative 354-day rule.
HAWL_DAYS = 354

ZERO = Decimal("0.000")


class DebtTreatment(str, enum.Enum):
    """How entered merchant liabilities are treated in the formula.

    ``DEDUCT_ALL`` — deduct every entered liability. This is the default
    and matches the ministry formula "minus merchant debts".
    ``DEDUCT_DUE_ONLY`` — deduct only liabilities the operator marked as
    currently due (``due=True``); entries whose due status is unknown or
    false are skipped and reported in ``liabilities_skipped_*``.
    ``NO_DEDUCTION`` — deduct nothing; the operator keeps debts
    off-record for this calculation.
    """

    DEDUCT_ALL = "deduct_all"
    DEDUCT_DUE_ONLY = "deduct_due_only"
    NO_DEDUCTION = "no_deduction"


class InventoryBasis(str, enum.Enum):
    """Valuation basis for the imported merchandise lines.

    ``WHOLESALE`` values every line at the product's configured wholesale
    price (``products.wholesale_price``); a line with no configured
    wholesale price (NULL — never coerced to 0) falls back to the retail
    market price and the fallback is reported through the
    ``WHOLESALE_RETAIL_FALLBACK`` warning so the choice stays transparent.
    """

    MARKET = "market"  # current selling price (market-price proxy)
    COST = "cost"  # moving average cost (PMP)
    WHOLESALE = "wholesale"  # configured wholesale price (retail fallback)
    OVERRIDE = "override"  # operator-entered total, reason mandatory


class NisabSource(str, enum.Enum):
    GOLD_PRICE = "gold_price"  # 85 g × entered gold price
    MANUAL = "manual"  # explicit operator override
    NONE = "none"  # unknown — result is provisional


class ZakatStatus(str, enum.Enum):
    FINAL = "final"  # every input known, due amount settled
    PROVISIONAL = "provisional"  # estimate only — inputs missing


#: Missing-input field codes a provisional result can carry.
MISSING_NISAB = "nisab"
MISSING_HAWL = "hawl_start"
MISSING_INVENTORY = "inventory"
MISSING_CASH = "cash"
MISSING_RECEIVABLES = "collectible_receivables"

#: The official nisab the Ministry published for 1447 — reference data
#: surfaced in the API context so the operator can verify their own gold
#: price. Never used in a calculation unless explicitly overridden.
OFFICIAL_NISAB_REFERENCE: dict[str, object] = {
    "hijri_year": 1447,
    "amount": Decimal("2295000.000"),
    "gold_price_per_gram": Decimal("27000.000"),
    "purity": "18k",
    "source": "marw.gov.dz",
    "note": (
        "Ministry-published nisab for the year 1447 (85 g × 27,000 DA/g, "
        "AGENOR 18k). Verify the current gold price before relying on it."
    ),
}


@dataclass(frozen=True)
class LineItem:
    """One operator-entered amount (cash item, extra receivable, debt)."""

    label: str
    amount: Decimal
    #: Only meaningful on liability lines: None = unknown due status.
    due: bool | None = None


@dataclass(frozen=True)
class InventoryRow:
    """One imported product line valued for the calculation."""

    product_id: str
    name: str
    quantity: Decimal
    market_unit_price: Decimal
    cost_unit_price: Decimal
    #: Configured wholesale unit price — None = never configured (NULL
    #: is never coerced to 0; 0 would be a valid free price).
    wholesale_unit_price: Decimal | None = None
    included: bool = True

    def line_value(self, basis: str) -> Decimal:
        if basis == InventoryBasis.WHOLESALE.value:
            # Transparent fallback: no configured wholesale price → the
            # retail market price (the line is reported as a fallback).
            unit = (
                self.wholesale_unit_price
                if self.wholesale_unit_price is not None
                else self.market_unit_price
            )
        elif basis == InventoryBasis.MARKET.value:
            unit = self.market_unit_price
        else:
            unit = self.cost_unit_price
        return to_decimal(self.quantity) * to_decimal(unit)


@dataclass
class ZakatWarning:
    """A warning or informational note attached to a result.

    ``code`` is stable and localized client-side (``zakat_warn_*``); the
    optional ``detail`` dict carries stringified numbers for display.
    """

    code: str
    detail: dict[str, str] = field(default_factory=dict)


@dataclass
class ZakatResult:
    """Everything the calculation produced — the domain contract."""

    zakat_date: date
    status: str
    missing_fields: list[str]
    warnings: list[ZakatWarning]

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
    #: Stock-only breakdown (informational — NEVER added to the net a
    #: second time): quantity still in stock (base units), reference
    #: cost value, reference market (retail) value, and the 2.5 % figure
    #: on the merchandise value alone (clearly not the full liability).
    inventory_quantity: Decimal | None
    inventory_cost_value: Decimal | None
    inventory_market_value: Decimal | None
    inventory_stock_only_zakat: Decimal | None

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

    @property
    def is_final(self) -> bool:
        return self.status == ZakatStatus.FINAL.value


def zakat_amount(net: Decimal) -> Decimal:
    """Zakat due on a zakatable net: ``(net × 2.5) / 100``.

    Quantized once, at the end, with the project-wide money rounding
    (NUMERIC(18,3), ROUND_HALF_EVEN).
    """
    raw = to_decimal(net) * ZAKAT_RATE_PCT / Decimal("100")
    return quantize_money(raw)


def _line_total(items: Sequence[LineItem]) -> Decimal:
    return quantize_money(sum((to_decimal(i.amount) for i in items), ZERO))


def _normalized_labels(items: Sequence[LineItem]) -> list[str]:
    return [i.label.strip().lower() for i in items if i.label.strip()]


def _duplicate_labels(*groups: Sequence[LineItem]) -> list[str]:
    """Labels used more than once across all entered line groups."""
    seen: dict[str, int] = {}
    for group in groups:
        for label in _normalized_labels(group):
            seen[label] = seen.get(label, 0) + 1
    return sorted(label for label, count in seen.items() if count > 1)


def _d(value: Decimal | None) -> str:
    """Stringify a Decimal for warning details."""
    return format(quantize_money(value), "f") if value is not None else ""


def calculate_zakat(
    *,
    zakat_date: date,
    hawl_start_date: date | None = None,
    gold_price_per_gram: Decimal | None = None,
    nisab_override: Decimal | None = None,
    inventory_basis: str = InventoryBasis.MARKET.value,
    inventory_override_value: Decimal | None = None,
    inventory_override_reason: str | None = None,
    inventory_rows: Sequence[InventoryRow] = (),
    inventory_imported: bool = True,
    cash_provided: bool = False,
    cash_items: Sequence[LineItem] = (),
    collectible_receivables: Decimal | None = None,
    doubtful_receivables: Decimal | None = None,
    other_receivable_items: Sequence[LineItem] = (),
    debt_treatment: str = DebtTreatment.DEDUCT_ALL.value,
    liability_items: Sequence[LineItem] = (),
    ledger_receivable_total: Decimal | None = None,
) -> ZakatResult:
    """Run the full zakat calculation.

    Pure function: no I/O, no session, no clock reads — the caller passes
    ``zakat_date`` explicitly so results are reproducible.
    """
    warnings: list[ZakatWarning] = []
    missing: list[str] = []

    # -- 1. Nisab -----------------------------------------------------
    if nisab_override is not None:
        nisab = quantize_money(nisab_override)
        nisab_source = NisabSource.MANUAL.value
    elif gold_price_per_gram is not None:
        nisab = quantize_money(NISAB_GOLD_GRAMS * to_decimal(gold_price_per_gram))
        nisab_source = NisabSource.GOLD_PRICE.value
        warnings.append(
            ZakatWarning(
                "GOLD_PRICE_MANUAL",
                {"grams": format(NISAB_GOLD_GRAMS, "f")},
            )
        )
    else:
        nisab = None
        nisab_source = None
        missing.append(MISSING_NISAB)
        warnings.append(ZakatWarning("MISSING_NISAB"))

    # -- 2. Hawl ------------------------------------------------------
    hawl_elapsed: int | None = None
    hawl_completed: bool | None = None
    if hawl_start_date is None:
        missing.append(MISSING_HAWL)
        warnings.append(ZakatWarning("MISSING_HAWL_START"))
    else:
        hawl_elapsed = (zakat_date - hawl_start_date).days
        if hawl_elapsed < 0:
            hawl_completed = False
            warnings.append(
                ZakatWarning(
                    "HAWL_START_AFTER_DATE",
                    {"hawl_start": hawl_start_date.isoformat()},
                )
            )
        else:
            hawl_completed = hawl_elapsed >= HAWL_DAYS
            if not hawl_completed:
                warnings.append(
                    ZakatWarning(
                        "HAWL_NOT_COMPLETED",
                        {
                            "days": str(hawl_elapsed),
                            "required": str(HAWL_DAYS),
                        },
                    )
                )

    # -- 3. Inventory -------------------------------------------------
    included_rows = [r for r in inventory_rows if r.included]
    excluded_rows = [r for r in inventory_rows if not r.included]
    excluded_value = quantize_money(
        sum((r.line_value(inventory_basis) for r in excluded_rows), ZERO)
    )
    imported_value: Decimal | None = None
    if inventory_basis != InventoryBasis.OVERRIDE.value:
        imported_value = quantize_money(
            sum((r.line_value(inventory_basis) for r in included_rows), ZERO)
        )

    if inventory_basis == InventoryBasis.OVERRIDE.value:
        inventory_source = "override"
        inventory_value = (
            quantize_money(inventory_override_value)
            if inventory_override_value is not None
            else None
        )
        if inventory_value is None:
            missing.append(MISSING_INVENTORY)
            warnings.append(ZakatWarning("MISSING_INVENTORY"))
        else:
            warnings.append(
                ZakatWarning(
                    "INVENTORY_OVERRIDE_APPLIED",
                    {"value": _d(inventory_value)},
                )
            )
            if not (inventory_override_reason or "").strip():
                warnings.append(ZakatWarning("INVENTORY_OVERRIDE_NO_REASON"))
    else:
        inventory_source = "imported"
        if not inventory_imported:
            inventory_value = None
            missing.append(MISSING_INVENTORY)
            warnings.append(ZakatWarning("MISSING_INVENTORY"))
        else:
            inventory_value = imported_value

    if excluded_rows:
        warnings.append(
            ZakatWarning(
                "INVENTORY_EXCLUDED_LINES",
                {
                    "count": str(len(excluded_rows)),
                    "value": _d(excluded_value),
                },
            )
        )
    negative_stock = [r for r in included_rows if to_decimal(r.quantity) < 0]
    if negative_stock:
        warnings.append(
            ZakatWarning("NEGATIVE_STOCK_LINES", {"count": str(len(negative_stock))})
        )

    # Stock-only breakdown — the quantity actually still in stock (the
    # caller passes CURRENT ``products.quantity``; sold units are simply
    # not there anymore) plus the two reference valuations. Informational
    # only: none of these is added to the net again (no double counting).
    inventory_quantity: Decimal | None = None
    inventory_cost_value: Decimal | None = None
    inventory_market_value: Decimal | None = None
    if inventory_imported:
        inventory_quantity = quantize_money(
            sum((to_decimal(r.quantity) for r in included_rows), ZERO)
        )
        inventory_cost_value = quantize_money(
            sum(
                (
                    to_decimal(r.quantity) * to_decimal(r.cost_unit_price)
                    for r in included_rows
                ),
                ZERO,
            )
        )
        inventory_market_value = quantize_money(
            sum(
                (
                    to_decimal(r.quantity) * to_decimal(r.market_unit_price)
                    for r in included_rows
                ),
                ZERO,
            )
        )
        if inventory_basis == InventoryBasis.WHOLESALE.value:
            fallback_rows = [
                r for r in included_rows if r.wholesale_unit_price is None
            ]
            if fallback_rows:
                warnings.append(
                    ZakatWarning(
                        "WHOLESALE_RETAIL_FALLBACK",
                        {"count": str(len(fallback_rows))},
                    )
                )
    # 2.5 % on the merchandise value ALONE — a clearly-labelled stock-only
    # estimate, not the complete business zakat (cash, receivables and
    # liabilities stay in the net formula below, once).
    inventory_stock_only_zakat: Decimal | None = (
        zakat_amount(inventory_value) if inventory_value is not None else None
    )

    # -- 4. Cash ------------------------------------------------------
    cash_total: Decimal | None = None
    if not cash_provided:
        missing.append(MISSING_CASH)
        warnings.append(ZakatWarning("MISSING_CASH"))
    else:
        cash_total = _line_total(cash_items)
        if not cash_items:
            # The operator asserted cash exists but sent no amounts —
            # typically a partially-filled form line that a client dropped.
            # Surface it loudly instead of silently reporting 0.000.
            warnings.append(ZakatWarning("CASH_PROVIDED_EMPTY"))

    # -- 5. Receivables -----------------------------------------------
    other_receivables_total = _line_total(other_receivable_items)
    if collectible_receivables is None:
        missing.append(MISSING_RECEIVABLES)
        warnings.append(ZakatWarning("MISSING_RECEIVABLES"))
        receivables_included_total: Decimal | None = None
    else:
        receivables_included_total = quantize_money(
            to_decimal(collectible_receivables) + other_receivables_total
        )
    if doubtful_receivables is not None and to_decimal(doubtful_receivables) > 0:
        warnings.append(
            ZakatWarning(
                "DOUBTFUL_EXCLUDED",
                {"value": _d(to_decimal(doubtful_receivables))},
            )
        )
    if (
        collectible_receivables is not None
        and ledger_receivable_total is not None
        and to_decimal(collectible_receivables) > to_decimal(ledger_receivable_total)
    ):
        warnings.append(
            ZakatWarning(
                "RECEIVABLES_EXCEED_LEDGER",
                {
                    "collectible": _d(to_decimal(collectible_receivables)),
                    "ledger": _d(to_decimal(ledger_receivable_total)),
                },
            )
        )

    # -- 6. Liabilities / deductions ----------------------------------
    liabilities_total = _line_total(liability_items)
    if debt_treatment == DebtTreatment.DEDUCT_ALL.value:
        deductions = liabilities_total
        skipped_amount = ZERO
        skipped_count = 0
    elif debt_treatment == DebtTreatment.DEDUCT_DUE_ONLY.value:
        due_items = [i for i in liability_items if i.due is True]
        skipped_items = [i for i in liability_items if i.due is not True]
        deductions = _line_total(due_items)
        skipped_amount = quantize_money(liabilities_total - deductions)
        skipped_count = len(skipped_items)
        if skipped_count:
            warnings.append(
                ZakatWarning(
                    "DEBT_DUE_ONLY_SKIPPED",
                    {
                        "count": str(skipped_count),
                        "amount": _d(skipped_amount),
                    },
                )
            )
    elif debt_treatment == DebtTreatment.NO_DEDUCTION.value:
        deductions = ZERO
        skipped_amount = liabilities_total
        skipped_count = len(liability_items)
        if skipped_count:
            warnings.append(
                ZakatWarning(
                    "DEBT_NO_DEDUCTION_APPLIED",
                    {"count": str(skipped_count), "amount": _d(liabilities_total)},
                )
            )
    else:  # pragma: no cover - schema restricts the value
        raise ValueError(f"unknown debt_treatment: {debt_treatment}")

    duplicates = _duplicate_labels(cash_items, other_receivable_items, liability_items)
    if duplicates:
        warnings.append(ZakatWarning("DUPLICATE_LABEL", {"labels": ", ".join(duplicates)}))

    # -- 7. Net zakatable base ----------------------------------------
    net_raw = (
        (inventory_value if inventory_value is not None else ZERO)
        + (cash_total if cash_total is not None else ZERO)
        + (receivables_included_total if receivables_included_total is not None else ZERO)
        - deductions
    )
    if net_raw < 0:
        net = ZERO
        warnings.append(
            ZakatWarning(
                "NEGATIVE_NET_CLAMPED",
                {"raw": format(quantize_money(net_raw), "f")},
            )
        )
    else:
        net = quantize_money(net_raw)

    status = ZakatStatus.FINAL.value if not missing else ZakatStatus.PROVISIONAL.value
    if status == ZakatStatus.PROVISIONAL.value:
        warnings.append(ZakatWarning("PROVISIONAL_RESULT"))

    # -- 8. Eligibility + due amount ----------------------------------
    reaches_nisab: bool | None = None if nisab is None else net >= nisab
    eligibility: list[str] = []
    if reaches_nisab is False:
        eligibility.append("BELOW_NISAB")
        warnings.append(
            ZakatWarning(
                "BELOW_NISAB", {"net": _d(net), "nisab": _d(nisab)}
            )
        )
    if hawl_completed is False:
        eligibility.append("HAWL_INCOMPLETE")

    provisional_due: Decimal | None = None
    zakat_due: Decimal | None = None
    if status == ZakatStatus.PROVISIONAL.value:
        provisional_due = zakat_amount(net)
    else:
        eligible = bool(reaches_nisab) and bool(hawl_completed)
        zakat_due = zakat_amount(net) if eligible else ZERO
        if not eligible and "BELOW_NISAB" not in eligibility and "HAWL_INCOMPLETE" not in eligibility:
            eligibility.append("NOT_ELIGIBLE")

    return ZakatResult(
        zakat_date=zakat_date,
        status=status,
        missing_fields=missing,
        warnings=warnings,
        hawl_start_date=hawl_start_date,
        hawl_days_elapsed=hawl_elapsed,
        hawl_completed=hawl_completed,
        gold_price_per_gram=(
            quantize_money(gold_price_per_gram) if gold_price_per_gram is not None else None
        ),
        nisab_amount=nisab,
        nisab_source=nisab_source,
        inventory_basis=inventory_basis,
        inventory_value=inventory_value,
        inventory_source=inventory_source,
        inventory_imported_value=imported_value,
        inventory_excluded_value=excluded_value,
        inventory_product_count=len(inventory_rows),
        inventory_included_count=len(included_rows),
        inventory_quantity=inventory_quantity,
        inventory_cost_value=inventory_cost_value,
        inventory_market_value=inventory_market_value,
        inventory_stock_only_zakat=inventory_stock_only_zakat,
        cash_provided=cash_provided,
        cash_total=cash_total,
        cash_item_count=len(cash_items),
        collectible_receivables=(
            quantize_money(collectible_receivables)
            if collectible_receivables is not None
            else None
        ),
        doubtful_receivables=(
            quantize_money(doubtful_receivables) if doubtful_receivables is not None else None
        ),
        other_receivables_total=other_receivables_total,
        receivables_included_total=receivables_included_total,
        receivable_item_count=len(other_receivable_items),
        debt_treatment=debt_treatment,
        liabilities_total_entered=liabilities_total,
        deductions_applied=deductions,
        liabilities_skipped_amount=skipped_amount,
        liabilities_skipped_count=skipped_count,
        liability_item_count=len(liability_items),
        net_zakatable=net,
        zakat_rate=ZAKAT_RATE,
        zakat_due=zakat_due,
        provisional_zakat_due=provisional_due,
        reaches_nisab=reaches_nisab,
        eligibility_reasons=eligibility,
    )
