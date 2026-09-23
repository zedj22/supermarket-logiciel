"""Phase 6 architectural correction — purchase packaging / stock-breaking.

Covers the Fromage end-to-end scenario (authoritative) and packaging domain
rules: document-unit preservation, explicit breaking, no negative stock.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from app.domain.packaging import (
    PackagingError,
    PackagingState,
    PurchaseUnitDef,
    base_equivalent,
    break_one_package,
    nominal_base_unit_cost,
    receive_packages,
    sell_base_units,
    sell_packages,
)

Q = Decimal


def _box() -> PurchaseUnitDef:
    return PurchaseUnitDef(id="box", name="Box", multiplier=Q("24"))


def _fromage_state() -> PackagingState:
    """Start empty, receive 10 Box ×24 → full 10, loose 0, total 240."""
    box = _box()
    state = PackagingState(total_base=Q("0"))
    receive_packages(state, box, Q("10"))
    return state


class TestFromageScenario:
    """Authoritative Fromage sequence from the architectural-correction brief."""

    def test_initial_receive_10_boxes(self):
        state = _fromage_state()
        assert state.full("box") == Q("10")
        assert state.loose_base == Q("0")
        assert state.total_base == Q("240")

    def test_sell_3_pieces(self):
        state = _fromage_state()
        sell_base_units(state, Q("3"))
        assert state.full("box") == Q("9")
        assert state.loose_base == Q("21")
        assert state.total_base == Q("237")

    def test_sell_1_box_sealed(self):
        state = _fromage_state()
        sell_base_units(state, Q("3"))
        sell_packages(state, _box(), Q("1"))
        assert state.full("box") == Q("8")
        assert state.loose_base == Q("21")
        assert state.total_base == Q("213")

    def test_purchase_2_boxes(self):
        state = _fromage_state()
        sell_base_units(state, Q("3"))
        sell_packages(state, _box(), Q("1"))
        receive_packages(state, _box(), Q("2"))
        assert state.full("box") == Q("10")
        assert state.loose_base == Q("21")
        assert state.total_base == Q("261")

    def test_sell_45_pieces_with_break(self):
        """Sell 45: consume 21 loose, break 1 Box (shortfall 24 = exact), sell 45."""
        state = _fromage_state()
        # State after prior steps: full 10, loose 21, total 261
        # (simplified path for this focused test — start at 10 full / 0 loose / 240)
        # Rebuild intermediate: 10 full, 0 loose, 240; sell 3 → 9/21/237;
        # receive enough so sell-45 has exact break. Use brief path:
        # receive 10 Box → 10/0/240; sell 3 → 9/21/237; then sell 45.
        # From brief: after sell 3, sell 1 Box, purchase 2 Box → 10/21/261.
        # Then sell 45: loose 21, need 24 more, break 1 Box exact.
        state = _fromage_state()
        sell_base_units(state, Q("3"))  # 9/21/237
        sell_packages(state, _box(), Q("1"))  # 8/21/213
        receive_packages(state, _box(), Q("2"))  # 10/21/261
        sell_base_units(state, Q("45"))
        assert state.full("box") == Q("9")
        assert state.loose_base == Q("0")
        assert state.total_base == Q("216")

    def test_insufficient_stock_raises(self):
        state = PackagingState(total_base=Q("0"))
        receive_packages(state, _box(), Q("1"))
        with pytest.raises(PackagingError):
            sell_base_units(state, Q("25"))  # only 24 available

    def test_never_negative(self):
        state = _fromage_state()
        sell_base_units(state, Q("240"))
        assert state.total_base == Q("0")
        assert state.loose_base == Q("0")
        assert state.full("box") == Q("0")
        with pytest.raises(PackagingError):
            sell_base_units(state, Q("1"))


class TestDocumentUnitPreservation:
    def test_receive_keeps_document_qty(self):
        state = PackagingState(total_base=Q("0"))
        receive_packages(state, _box(), Q("10"))
        # Document is 10 Box — never rewritten to 240
        assert state.full("box") == Q("10")
        assert base_equivalent(Q("10"), Q("24")) == Q("240")

    def test_sell_packages_requires_full(self):
        state = _fromage_state()
        with pytest.raises(PackagingError):
            sell_packages(state, _box(), Q("11"))  # only 10

    def test_base_equivalent(self):
        assert base_equivalent(Q("10"), Q("24")) == Q("240")
        assert base_equivalent(Q("2.5"), Q("4")) == Q("10")

    def test_nominal_base_unit_cost(self):
        # 10 Box × 200 DA → per Piece = 200 / 24
        cost = nominal_base_unit_cost(Q("200"), Q("24"))
        assert cost == (Q("200") / Q("24")).quantize(Q("0.001"))


class TestBreakOnePackage:
    def test_break_moves_to_loose_without_changing_total(self):
        state = _fromage_state()
        before = state.total_base
        break_one_package(state, _box())
        assert state.full("box") == Q("9")
        assert state.loose_base == Q("24")
        assert state.total_base == before

    def test_break_without_package_raises(self):
        state = PackagingState(total_base=Q("0"))
        with pytest.raises(PackagingError):
            break_one_package(state, _box())


class TestBreakingAlgorithm:
    def test_prefers_exact_fit_package(self):
        """Need 24 with only Box ×24 stocked → exact break."""
        state = PackagingState(
            full_packages={"box": Q("1")},
            loose_base=Q("0"),
            total_base=Q("24"),
            units={"box": _box()},
        )
        sell_base_units(state, Q("24"))
        assert state.full_packages.get("box", Q("0")) == Q("0")
        assert state.loose_base == Q("0")
        assert state.total_base == Q("0")

    def test_loose_consumed_before_breaking(self):
        state = PackagingState(
            full_packages={"box": Q("1")},
            loose_base=Q("5"),
            total_base=Q("29"),
            units={"box": _box()},
        )
        sell_base_units(state, Q("5"))
        assert state.full("box") == Q("1")
        assert state.loose_base == Q("0")
        assert state.total_base == Q("24")
