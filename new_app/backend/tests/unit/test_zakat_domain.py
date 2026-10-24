"""Zakat domain engine tests (app/domain/zakat.py).

Covers the ministry formula end to end with hand-computed expectations:

- rate math `(net × 2.5) / 100` with HALF_EVEN money rounding,
- nisab from 85 g × gold price (and the official 1447 reference value),
- hawl (354 days) gating,
- provisional vs final status and the ``missing_fields`` contract,
- the three debt treatments,
- double-count / duplicate-label / doubtful-debt guards,
- negative-net clamping and inventory exclusion.

Pure functions only — no session, no HTTP.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from app.domain.zakat import (
    HAWL_DAYS,
    NISAB_GOLD_GRAMS,
    OFFICIAL_NISAB_REFERENCE,
    InventoryRow,
    LineItem,
    calculate_zakat,
    zakat_amount,
)

TODAY = date(2026, 10, 16)
LONG_AGO = date(2023, 1, 1)  # well past one lunar year


def _codes(result) -> set[str]:
    return {w.code for w in result.warnings}


def _base(**overrides):
    kwargs = dict(
        zakat_date=TODAY,
        hawl_start_date=LONG_AGO,
        gold_price_per_gram=Decimal("27000"),
        inventory_rows=[],
        cash_provided=True,
        collectible_receivables=Decimal("0"),
    )
    kwargs.update(overrides)
    return calculate_zakat(**kwargs)


# ── rate + rounding ───────────────────────────────────────────────────────


def test_zakat_amount_matches_the_published_formula():
    assert zakat_amount(Decimal("4000000")) == Decimal("100000.000")


def test_zakat_amount_rounds_half_even_at_milli():
    # 0.02 × 0.025 = 0.0005 → HALF_EVEN → 0.000
    assert zakat_amount(Decimal("0.02")) == Decimal("0.000")
    # 0.06 × 0.025 = 0.0015 → HALF_EVEN → 0.002
    assert zakat_amount(Decimal("0.06")) == Decimal("0.002")


# ── nisab ─────────────────────────────────────────────────────────────────


def test_nisab_from_gold_price_is_85_grams():
    result = _base(collectible_receivables=Decimal("3000000"))
    assert result.nisab_amount == Decimal("2295000.000")
    assert result.nisab_source == "gold_price"
    assert result.reaches_nisab is True


def test_official_1447_reference_matches_85g_at_27000():
    ref = OFFICIAL_NISAB_REFERENCE
    assert NISAB_GOLD_GRAMS * Decimal("27000") == ref["amount"]
    assert ref["hijri_year"] == 1447


def test_manual_nisab_override_beats_gold_price():
    result = _base(nisab_override=Decimal("1000000"))
    assert result.nisab_amount == Decimal("1000000.000")
    assert result.nisab_source == "manual"


def test_below_nisab_means_no_zakat_due():
    result = _base(collectible_receivables=Decimal("1000000"))
    assert result.reaches_nisab is False
    assert result.zakat_due == Decimal("0.000")
    assert "BELOW_NISAB" in result.eligibility_reasons
    assert "BELOW_NISAB" in _codes(result)


# ── hawl ──────────────────────────────────────────────────────────────────


def test_hawl_completed_after_354_days():
    result = _base(
        hawl_start_date=TODAY.replace(year=TODAY.year - 2),
        collectible_receivables=Decimal("3000000"),
    )
    assert result.hawl_completed is True
    assert result.zakat_due == Decimal("75000.000")


def test_hawl_not_completed_blocks_due_amount():
    result = _base(
        hawl_start_date=date(2026, 1, 1),
        collectible_receivables=Decimal("3000000"),
    )
    assert result.hawl_completed is False
    assert result.zakat_due == Decimal("0.000")
    assert "HAWL_INCOMPLETE" in result.eligibility_reasons
    assert "HAWL_NOT_COMPLETED" in _codes(result)


def test_missing_hawl_start_is_provisional():
    result = _base(hawl_start_date=None)
    assert result.hawl_completed is None
    assert "hawl_start" in result.missing_fields
    assert result.status == "provisional"
    assert result.zakat_due is None
    assert result.provisional_zakat_due is not None


def test_hawl_start_after_zakat_date_is_flagged():
    result = _base(hawl_start_date=date(2027, 1, 1))
    assert "HAWL_START_AFTER_DATE" in _codes(result)
    assert result.hawl_completed is False


# ── provisional vs final ─────────────────────────────────────────────────


def test_everything_entered_is_final():
    result = _base(collectible_receivables=Decimal("3000000"))
    assert result.status == "final"
    assert result.missing_fields == []
    assert result.zakat_due == Decimal("75000.000")
    assert result.provisional_zakat_due is None


def test_missing_inputs_make_it_provisional_with_estimate():
    result = calculate_zakat(
        zakat_date=TODAY,
        gold_price_per_gram=Decimal("27000"),
        inventory_imported=False,
        cash_provided=False,
        collectible_receivables=None,
        hawl_start_date=LONG_AGO,
    )
    assert result.status == "provisional"
    assert result.zakat_due is None
    assert set(result.missing_fields) == {"inventory", "cash", "collectible_receivables"}
    # estimate still shown, computed off the known (zero) parts
    assert result.provisional_zakat_due == Decimal("0.000")


# ── inventory ─────────────────────────────────────────────────────────────


def _row(qty, price, cost, included=True, pid="p1", wholesale=None):
    return InventoryRow(
        product_id=pid,
        name=f"Product {pid}",
        quantity=Decimal(qty),
        market_unit_price=Decimal(price),
        cost_unit_price=Decimal(cost),
        wholesale_unit_price=(
            Decimal(wholesale) if wholesale is not None else None
        ),
        included=included,
    )


def test_inventory_market_basis_uses_selling_price():
    result = _base(inventory_rows=[_row("10", "500", "300")])
    assert result.inventory_value == Decimal("5000.000")
    assert result.inventory_source == "imported"
    assert result.net_zakatable == Decimal("5000.000")


def test_inventory_cost_basis_uses_avg_cost():
    result = _base(
        inventory_basis="cost",
        inventory_rows=[_row("10", "500", "300")],
    )
    assert result.inventory_value == Decimal("3000.000")


def test_excluded_lines_are_reported_but_not_counted():
    result = _base(
        inventory_rows=[
            _row("10", "500", "300", included=True, pid="keep"),
            _row("4", "1000", "800", included=False, pid="fridge"),
        ]
    )
    assert result.inventory_value == Decimal("5000.000")
    assert result.inventory_excluded_value == Decimal("4000.000")
    assert "INVENTORY_EXCLUDED_LINES" in _codes(result)


def test_override_value_is_used_and_reason_is_required_by_schema():
    result = _base(
        inventory_basis="override",
        inventory_override_value=Decimal("123456"),
        inventory_override_reason="inventaire tournant",
    )
    assert result.inventory_value == Decimal("123456.000")
    assert result.inventory_source == "override"
    assert "INVENTORY_OVERRIDE_APPLIED" in _codes(result)


def test_negative_stock_lines_are_flagged():
    result = _base(inventory_rows=[_row("-3", "100", "80")])
    assert "NEGATIVE_STOCK_LINES" in _codes(result)
    assert result.inventory_value == Decimal("-300.000")


# ── wholesale / retail valuation choice ───────────────────────────────────


def test_wholesale_basis_uses_the_configured_wholesale_price():
    result = _base(
        inventory_basis="wholesale",
        inventory_rows=[_row("10", "500", "300", wholesale="420")],
    )
    assert result.inventory_value == Decimal("4200.000")
    # every line had a configured wholesale price → no fallback warning
    assert "WHOLESALE_RETAIL_FALLBACK" not in _codes(result)


def test_wholesale_basis_falls_back_to_retail_transparently_with_warning():
    result = _base(
        inventory_basis="wholesale",
        inventory_rows=[
            _row("10", "500", "300", wholesale="420", pid="configured"),
            _row("4", "1000", "800", wholesale=None, pid="unconfigured"),
        ],
    )
    # configured line at wholesale (4,200) + unconfigured line at retail
    # (4,000) — the fallback never silently drops stock value to zero.
    assert result.inventory_value == Decimal("8200.000")
    fallback = [
        w for w in result.warnings if w.code == "WHOLESALE_RETAIL_FALLBACK"
    ]
    assert len(fallback) == 1
    assert fallback[0].detail == {"count": "1"}


def test_wholesale_zero_price_is_respected_not_treated_as_missing():
    # 0 is a valid (free) configured price — only NULL means unconfigured.
    result = _base(
        inventory_basis="wholesale",
        inventory_rows=[_row("10", "500", "300", wholesale="0")],
    )
    assert result.inventory_value == Decimal("0.000")
    assert "WHOLESALE_RETAIL_FALLBACK" not in _codes(result)


# ── stock-only breakdown (quantity / cost / market / 2.5 %) ───────────────


def test_breakdown_reports_remaining_quantity_cost_and_market_values():
    result = _base(
        inventory_rows=[
            _row("10", "500", "300", pid="a"),
            _row("4", "1000", "800", pid="b"),
        ]
    )
    # the rows carry CURRENT stock (sold units are simply not there);
    # cost and market are reference valuations of the same quantity.
    assert result.inventory_quantity == Decimal("14.000")
    assert result.inventory_cost_value == Decimal("6200.000")
    assert result.inventory_market_value == Decimal("9000.000")
    assert result.inventory_value == Decimal("9000.000")  # market basis


def test_cost_basis_valuation_differs_from_the_market_reference():
    result = _base(
        inventory_basis="cost",
        inventory_rows=[_row("10", "500", "300")],
    )
    assert result.inventory_value == Decimal("3000.000")  # basis = cost
    assert result.inventory_market_value == Decimal("5000.000")  # reference
    assert result.inventory_cost_value == Decimal("3000.000")


def test_empty_stock_breaks_down_to_zero_not_to_null():
    result = _base(inventory_rows=[_row("0", "500", "300")])
    assert result.inventory_quantity == Decimal("0.000")
    assert result.inventory_cost_value == Decimal("0.000")
    assert result.inventory_market_value == Decimal("0.000")
    assert result.inventory_value == Decimal("0.000")
    assert result.inventory_stock_only_zakat == Decimal("0.000")


def test_stock_only_zakat_is_two_and_a_half_percent_of_merchandise_alone():
    result = _base(
        inventory_rows=[_row("10", "500", "300")],
        cash_items=[LineItem(label="Caisse", amount=Decimal("3000000"))],
    )
    # stock-only: 2.5 % of the merchandise value (5,000) — informational.
    assert result.inventory_stock_only_zakat == Decimal("125.000")
    # the net counts the merchandise ONCE alongside cash and receivables
    # (no double counting) and the due is computed on the whole net
    # (3,005,000 ≥ nisab → 75,125), never on the stock-only figure.
    assert result.net_zakatable == Decimal("3005000.000")
    assert result.zakat_due == Decimal("75125.000")
    assert result.inventory_stock_only_zakat != result.zakat_due


def test_stock_only_breakdown_is_absent_without_imported_stock():
    result = _base(inventory_imported=False)
    assert result.inventory_quantity is None
    assert result.inventory_cost_value is None
    assert result.inventory_market_value is None
    assert result.inventory_stock_only_zakat is None


def test_stock_only_zakat_is_none_when_merchandise_value_is_unknown():
    # override basis without a value: no merchandise figure → no stock-only
    # estimate (never a fabricated 0).
    result = _base(inventory_basis="override")
    assert result.inventory_value is None
    assert result.inventory_stock_only_zakat is None


# ── receivables guards ───────────────────────────────────────────────────


def test_doubtful_receivables_are_excluded_with_warning():
    result = _base(
        collectible_receivables=Decimal("1000"),
        doubtful_receivables=Decimal("500"),
    )
    assert result.doubtful_receivables == Decimal("500.000")
    assert "DOUBTFUL_EXCLUDED" in _codes(result)
    # doubtful never reaches the net
    assert result.net_zakatable == Decimal("1000.000")


def test_collectible_above_ledger_total_warns_about_double_counting():
    result = _base(
        collectible_receivables=Decimal("900"),
        ledger_receivable_total=Decimal("500"),
    )
    assert "RECEIVABLES_EXCEED_LEDGER" in _codes(result)


def test_collectible_below_ledger_total_is_fine():
    result = _base(
        collectible_receivables=Decimal("400"),
        ledger_receivable_total=Decimal("500"),
    )
    assert "RECEIVABLES_EXCEED_LEDGER" not in _codes(result)


def test_other_receivable_lines_are_added():
    result = _base(
        collectible_receivables=Decimal("100"),
        other_receivable_items=[LineItem("traiteur", Decimal("50"))],
    )
    assert result.other_receivables_total == Decimal("50.000")
    assert result.receivables_included_total == Decimal("150.000")


# ── debt treatments ──────────────────────────────────────────────────────


DEBTS = [
    LineItem("supplier A", Decimal("300"), due=True),
    LineItem("supplier B", Decimal("200"), due=False),
    LineItem("supplier C", Decimal("100"), due=None),
]


def test_deduct_all_removes_every_liability():
    result = _base(
        collectible_receivables=Decimal("1000"),
        debt_treatment="deduct_all",
        liability_items=DEBTS,
    )
    assert result.deductions_applied == Decimal("600.000")
    assert result.liabilities_skipped_count == 0
    assert result.net_zakatable == Decimal("400.000")


def test_deduct_due_only_skips_unknown_due_status():
    result = _base(
        collectible_receivables=Decimal("1000"),
        debt_treatment="deduct_due_only",
        liability_items=DEBTS,
    )
    assert result.deductions_applied == Decimal("300.000")
    assert result.liabilities_skipped_count == 2
    assert result.liabilities_skipped_amount == Decimal("300.000")
    assert "DEBT_DUE_ONLY_SKIPPED" in _codes(result)


def test_no_deduction_keeps_liabilities_off_the_formula():
    result = _base(
        collectible_receivables=Decimal("1000"),
        debt_treatment="no_deduction",
        liability_items=DEBTS,
    )
    assert result.deductions_applied == Decimal("0.000")
    assert result.liabilities_skipped_amount == Decimal("600.000")
    assert "DEBT_NO_DEDUCTION_APPLIED" in _codes(result)


# ── net / clamping / duplicates ──────────────────────────────────────────


def test_negative_net_is_clamped_to_zero_with_warning():
    result = _base(
        collectible_receivables=Decimal("100"),
        liability_items=[LineItem("huge debt", Decimal("900"))],
    )
    assert result.net_zakatable == Decimal("0.000")
    assert "NEGATIVE_NET_CLAMPED" in _codes(result)


def test_duplicate_labels_across_sections_warn():
    result = _base(
        cash_provided=True,
        cash_items=[LineItem("caisse", Decimal("10"))],
        collectible_receivables=Decimal("0"),
        other_receivable_items=[LineItem("Caisse", Decimal("5"))],
    )
    warning = next(w for w in result.warnings if w.code == "DUPLICATE_LABEL")
    assert "caisse" in warning.detail["labels"]


def test_full_formula_matches_the_ministry_example():
    # goods 8,000,000 (market) + cash 500,000 + collectible 1,000,000
    # − debts 1,500,000 = net 8,000,000 → zakat 200,000
    result = _base(
        inventory_rows=[_row("1000", "8000", "6000")],
        cash_items=[LineItem("till", Decimal("500000"))],
        collectible_receivables=Decimal("1000000"),
        liability_items=[LineItem("supplier", Decimal("1500000"), due=True)],
        debt_treatment="deduct_all",
    )
    assert result.net_zakatable == Decimal("8000000.000")
    assert result.zakat_due == Decimal("200000.000")
    assert result.status == "final"


@pytest.mark.parametrize("days", [0, 353])
def test_hawl_exactly_below_threshold_is_not_completed(days):
    from datetime import timedelta

    result = _base(hawl_start_date=TODAY - timedelta(days=days))
    assert result.hawl_completed is False


def test_hawl_exactly_354_days_is_completed():
    from datetime import timedelta

    result = _base(
        hawl_start_date=TODAY - timedelta(days=HAWL_DAYS),
        collectible_receivables=Decimal("3000000"),
    )
    assert result.hawl_completed is True
    assert result.zakat_due == Decimal("75000.000")


# ── regression: cash provided but no line items survive the UI ────────────
#
# Field report (2026-10-16): operator checked "cash provided", typed
# 4,000,000 into a cash line, left the line LABEL blank.  The Flutter
# serializer dropped the partially-filled line, so the request carried
# cash_provided=True with cash_items=[].  The engine reported cash 0.000
# with NO warning and the 4,000,000 silently vanished from the net.


def _field_report_inventory():
    # Imported stock at market price = 217,895,577.85
    return [_row("1", "217895577.85", "200000000")]


def test_cash_provided_with_no_items_warns_and_totals_zero():
    result = calculate_zakat(
        zakat_date=TODAY,
        hawl_start_date=None,
        gold_price_per_gram=Decimal("20000"),
        inventory_rows=_field_report_inventory(),
        inventory_imported=True,
        cash_provided=True,
        cash_items=[],
        collectible_receivables=Decimal("200000"),
        doubtful_receivables=Decimal("100000"),
    )
    # The empty list totals 0.000 but must NOT be silent.
    assert result.cash_total == Decimal("0.000")
    assert result.cash_item_count == 0
    assert "CASH_PROVIDED_EMPTY" in _codes(result)
    # "cash" is not a missing field — the operator answered the checkbox.
    assert "cash" not in result.missing_fields
    # Exact field-report arithmetic: inventory + collectible only.
    assert result.net_zakatable == Decimal("218095577.850")
    assert result.provisional_zakat_due == Decimal("5452389.446")
    assert result.status == "provisional"
    assert "hawl_start" in result.missing_fields


def test_entered_cash_is_included_exactly_once_in_net_and_rate():
    result = calculate_zakat(
        zakat_date=TODAY,
        hawl_start_date=None,
        gold_price_per_gram=Decimal("20000"),
        inventory_rows=_field_report_inventory(),
        inventory_imported=True,
        cash_provided=True,
        cash_items=[LineItem("caisse", Decimal("4000000"))],
        collectible_receivables=Decimal("200000"),
        doubtful_receivables=Decimal("100000"),
    )
    assert result.cash_total == Decimal("4000000.000")
    assert result.cash_item_count == 1
    assert "CASH_PROVIDED_EMPTY" not in _codes(result)
    # 217,895,577.85 + 4,000,000 + 200,000 = 222,095,577.85
    assert result.net_zakatable == Decimal("222095577.850")
    # 222,095,577.85 × 2.5% = 5,552,389.44625 → HALF_EVEN → 5,552,389.446
    assert result.provisional_zakat_due == Decimal("5552389.446")
    assert result.status == "provisional"  # hawl still missing
    # Doubtful debts stay excluded, as before.
    assert "DOUBTFUL_EXCLUDED" in _codes(result)


def test_cash_counted_once_with_final_status_when_hawl_complete():
    result = calculate_zakat(
        zakat_date=TODAY,
        hawl_start_date=LONG_AGO,
        gold_price_per_gram=Decimal("20000"),
        inventory_rows=_field_report_inventory(),
        inventory_imported=True,
        cash_provided=True,
        cash_items=[LineItem("caisse", Decimal("4000000"))],
        collectible_receivables=Decimal("200000"),
    )
    assert result.status == "final"
    assert result.zakat_due == Decimal("5552389.446")
    assert result.provisional_zakat_due is None
