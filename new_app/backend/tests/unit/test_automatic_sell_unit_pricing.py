"""Contract: the POS "automatic sell-unit pricing" (Method 2) payload.

The Flutter cart prices a Method 2 line as

    line_total = floor(q / sell_qty) * sell_unit_price
               + (q % sell_qty) * unit_price

and expresses that as the EXISTING line fields:

    quantity      = q                (base units)
    unit_price    = regular price    (500)
    line_discount = q * 500 - line_total

so no schema change is needed. This module pins the backend half of that
contract: :meth:`SaleService._apply_line_discount` must accept those lines
and store exactly the amount the cashier saw in the cart.

Reference configuration: 500 DA per unit, sell unit = 4 units at 1 900 DA.
"""

from decimal import Decimal
from types import SimpleNamespace

import pytest

from app.services.sale import MONEY_QUANTUM, _ResolvedLine, _money
from app.services.sale import SaleService

REGULAR_PRICE = Decimal("500")
SELL_QTY = 4
SELL_PRICE = Decimal("1900")

# The table from the specification (quantity → amount the cashier pays).
EXPECTED_TOTALS = {
    1: Decimal("500"),
    2: Decimal("1000"),
    3: Decimal("1500"),
    4: Decimal("1900"),
    5: Decimal("2400"),
    6: Decimal("2900"),
    7: Decimal("3400"),
    8: Decimal("3800"),
    9: Decimal("4300"),
    10: Decimal("4800"),
    11: Decimal("5300"),
    12: Decimal("5700"),
}


def cart_amount(quantity: int) -> Decimal | None:
    """The client formula (core/sell_unit_pricing.dart), in exact decimals."""
    if quantity < 0:
        return None
    bundles, remaining = divmod(quantity, SELL_QTY)
    return (bundles * SELL_PRICE) + (remaining * REGULAR_PRICE)


def payload(quantity: int) -> SimpleNamespace:
    """Exactly what ``CartLine.toSaleJson`` sends for a Method 2 line."""
    total = cart_amount(quantity)
    discount = (quantity * REGULAR_PRICE) - total
    assert discount >= 0
    return SimpleNamespace(
        line_discount=str(discount.normalize()),
        unit_price=str(REGULAR_PRICE),
    )


def resolved_line(quantity: int) -> _ResolvedLine:
    line = object.__new__(_ResolvedLine)
    line.line_gross = _money(REGULAR_PRICE * Decimal(quantity))
    line.line_discount = Decimal("0")
    line.line_total = line.line_gross
    return line


def apply_discount(line: _ResolvedLine, item: SimpleNamespace) -> None:
    # The method only touches the line and the item; no instance state.
    SaleService._apply_line_discount(None, line, item, 0)  # type: ignore[arg-type]


@pytest.mark.parametrize("quantity", sorted(EXPECTED_TOTALS))
def test_stored_line_total_matches_the_cart_amount(quantity: int) -> None:
    line = resolved_line(quantity)
    apply_discount(line, payload(quantity))

    expected = EXPECTED_TOTALS[quantity]
    assert cart_amount(quantity) == expected
    assert line.line_total == expected
    # The persisted line total is what the invoice and history print, so the
    # cart and the saved sale can never disagree.
    assert line.line_total.quantize(MONEY_QUANTUM) == expected
    assert line.line_total == line.line_gross - line.line_discount


@pytest.mark.parametrize("quantity", sorted(EXPECTED_TOTALS))
def test_discount_is_a_real_bundle_saving(quantity: int) -> None:
    line = resolved_line(quantity)
    item = payload(quantity)
    apply_discount(line, item)

    bundles = quantity // SELL_QTY
    assert line.line_discount == bundles * (SELL_QTY * REGULAR_PRICE - SELL_PRICE)
    assert line.line_discount <= line.line_gross


def test_empty_or_bundleless_quantities_carry_no_discount() -> None:
    for quantity in (1, 2, 3):
        line = resolved_line(quantity)
        item = payload(quantity)
        assert Decimal(item.line_discount) == Decimal("0")
        apply_discount(line, item)
        assert line.line_discount == Decimal("0")
        assert line.line_total == REGULAR_PRICE * Decimal(quantity)


def test_a_negative_discount_is_still_rejected() -> None:
    from app.core.exceptions import ValidationError

    line = resolved_line(4)
    item = SimpleNamespace(line_discount="-1", unit_price="500")
    with pytest.raises(ValidationError):
        apply_discount(line, item)


def test_a_discount_above_the_gross_is_still_rejected() -> None:
    """A mis-priced bundle must fail loudly, never persist a negative line."""
    from app.core.exceptions import ValidationError

    line = resolved_line(4)
    item = SimpleNamespace(line_discount="2100", unit_price="500")  # gross 2000
    with pytest.raises(ValidationError):
        apply_discount(line, item)


def test_mixed_method2_lines_sum_to_the_cart_total() -> None:
    """Two lines, one per pricing mode, summing as the cart shows them."""
    auto = resolved_line(5)
    apply_discount(auto, payload(5))
    assert auto.line_total == Decimal("2400")

    # A Method 1 line: the picker stamped the sell-unit price directly.
    manual = object.__new__(_ResolvedLine)
    manual.line_gross = _money(SELL_PRICE * Decimal("1"))
    manual.line_discount = Decimal("0")
    manual.line_total = manual.line_gross
    assert manual.line_total == Decimal("1900")

    assert auto.line_total + manual.line_total == Decimal("4300")
