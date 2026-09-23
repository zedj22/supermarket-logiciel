"""Phase 6 tests — unit conversions (pure domain, no I/O).

Covers:
- selling_to_base / base_to_selling_available / mixed_sale_base_cost
- validate_multiplier (positive, finite)
- can_fulfill
- effective_unit_price (independent price, never multiplier × base)
- weighted (decimal) quantities
- scenario: Fromage Test piece×1 / box×24, stock 240
"""

from __future__ import annotations

from decimal import Decimal

from decimal import InvalidOperation

import pytest

from app.domain.unit_conversions import (
    base_to_selling_available,
    can_fulfill,
    effective_unit_price,
    mixed_sale_base_cost,
    selling_to_base,
    to_decimal,
    validate_multiplier,
)


class TestSellingToBase:
    def test_piece_multiplier_one(self):
        assert selling_to_base(5, 1) == Decimal("5.000")

    def test_box_multiplier_24(self):
        assert selling_to_base(1, 24) == Decimal("24.000")
        assert selling_to_base(2, 24) == Decimal("48.000")

    def test_decimal_selling_qty(self):
        assert selling_to_base(Decimal("1.5"), 2) == Decimal("3.000")

    def test_zero(self):
        assert selling_to_base(0, 24) == Decimal("0.000")

    def test_negative_raises(self):
        with pytest.raises(InvalidOperation):
            selling_to_base(-1, 24)

    def test_quantizes_to_three_places(self):
        result = selling_to_base(Decimal("0.333"), Decimal("3"))
        assert result == Decimal("0.999")
        assert result.as_tuple().exponent == -3


class TestValidateMultiplier:
    def test_valid(self):
        assert validate_multiplier(24) == Decimal("24")
        assert validate_multiplier(Decimal("0.5")) == Decimal("0.5")

    def test_zero_raises(self):
        with pytest.raises(InvalidOperation):
            validate_multiplier(0)

    def test_negative_raises(self):
        with pytest.raises(InvalidOperation):
            validate_multiplier(-1)


class TestBaseToSellingAvailable:
    def test_full_boxes(self):
        # 240 base / 24 = 10 boxes
        assert base_to_selling_available(240, 24) == Decimal("10.000")

    def test_partial_boxes_floor(self):
        # 250 / 24 = 10.416… → 10 whole boxes
        assert base_to_selling_available(250, 24) == Decimal("10.000")

    def test_insufficient_for_one(self):
        assert base_to_selling_available(10, 24) == Decimal("0.000")

    def test_zero_stock(self):
        assert base_to_selling_available(0, 24) == Decimal("0.000")

    def test_piece_units(self):
        assert base_to_selling_available(240, 1) == Decimal("240.000")


class TestCanFulfill:
    def test_exact(self):
        assert can_fulfill(24, 24) is True

    def test_more_than_needed(self):
        assert can_fulfill(25, 24) is True

    def test_less_than_needed(self):
        assert can_fulfill(23, 24) is False


class TestMixedSaleBaseCost:
    def test_scenario_1_box(self):
        # 1 box ×24 → 24 base
        assert mixed_sale_base_cost([(1, 24)]) == Decimal("24.000")

    def test_scenario_5_pieces(self):
        assert mixed_sale_base_cost([(5, 1)]) == Decimal("5.000")

    def test_scenario_2_boxes(self):
        assert mixed_sale_base_cost([(2, 24)]) == Decimal("48.000")

    def test_scenario_1_box_plus_7_pieces(self):
        # 1×24 + 7×1 = 31 base
        assert mixed_sale_base_cost([(1, 24), (7, 1)]) == Decimal("31.000")

    def test_empty(self):
        assert mixed_sale_base_cost([]) == Decimal("0.000")


class TestEffectiveUnitPrice:
    def test_independent_price_wins(self):
        # Box sells at 220, not 24 × 10
        assert effective_unit_price(220, 10) == Decimal("220")

    def test_null_price_inherits_product_price_as_is(self):
        # Never multiplier × base_price
        assert effective_unit_price(None, 10) == Decimal("10")

    def test_zero_price_is_valid(self):
        assert effective_unit_price(0, 10) == Decimal("0")


class TestFromageScenario:
    """Fromage Test: stock 240 pieces, Piece×1 @10, Boîte×24 @220."""

    STOCK = Decimal("240")
    MULT_BOX = Decimal("24")
    MULT_PIECE = Decimal("1")

    def test_availability(self):
        assert base_to_selling_available(self.STOCK, self.MULT_PIECE) == Decimal("240.000")
        assert base_to_selling_available(self.STOCK, self.MULT_BOX) == Decimal("10.000")

    def test_after_1_box(self):
        remaining = self.STOCK - selling_to_base(1, self.MULT_BOX)
        assert remaining == Decimal("216.000")

    def test_after_5_pieces(self):
        remaining = self.STOCK - selling_to_base(5, self.MULT_PIECE)
        assert remaining == Decimal("235.000")

    def test_after_2_boxes(self):
        remaining = self.STOCK - selling_to_base(2, self.MULT_BOX)
        assert remaining == Decimal("192.000")

    def test_after_1_box_and_7_pieces(self):
        cost = mixed_sale_base_cost([(1, self.MULT_BOX), (7, self.MULT_PIECE)])
        remaining = self.STOCK - cost
        assert remaining == Decimal("209.000")

    def test_can_sell_10_boxes_not_11(self):
        assert can_fulfill(self.STOCK, selling_to_base(10, self.MULT_BOX)) is True
        assert can_fulfill(self.STOCK, selling_to_base(11, self.MULT_BOX)) is False


class TestWeightedQuantities:
    def test_kg_style_decimal(self):
        # 1.25 kg at multiplier 1 → 1.250 base
        assert selling_to_base(Decimal("1.25"), 1) == Decimal("1.250")

    def test_half_unit(self):
        # Selling unit with multiplier 0.5 (e.g. half-pack)
        assert selling_to_base(2, Decimal("0.5")) == Decimal("1.000")

    def test_to_decimal_from_str(self):
        assert to_decimal("1.5") == Decimal("1.5")
