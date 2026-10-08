"""Facturation domain tests (Phase 1).

Ported assertions from ``factura_simple/backend/test_calc.py`` (never
weakened), plus line/totals/stamp-duty/words/validation/determinism
coverage and a LIVE parity sweep that loads the factura_simple source
module and compares both implementations (skipped when the reference
project is absent).
"""

from __future__ import annotations

import importlib.util
from decimal import Decimal
from functools import lru_cache
from pathlib import Path
from types import ModuleType

import pytest

from app.domain.facturation import (
    DOC_TYPES,
    DOCUMENT_PHRASES,
    PAYMENT_METHODS,
    TVA_RATES,
    FacturationError,
    FactureLine,
    LineTotals,
    amount_in_words,
    calculate_document_totals,
    calculate_line,
    calculate_totals,
    money,
    number_to_words_fr,
    stamp_duty,
    validate_doc_type,
    validate_document_inputs,
    validate_line,
    validate_payment_method,
)

D = Decimal

# Live reference for the parity sweep (read-only; skipped if absent).
FACTURA_SIMPLE_CALC = Path(r"C:\Users\MSI\Desktop\factura_simple\backend\calc.py")


@lru_cache(maxsize=1)
def _load_source_calc() -> ModuleType:
    spec = importlib.util.spec_from_file_location("factura_simple_calc", FACTURA_SIMPLE_CALC)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _line(qty: str, price: str, tva: str, discount: str = "0") -> FactureLine:
    return FactureLine(D(qty), D(price), D(tva), D(discount))


def to_dec(value: object) -> Decimal:
    """Decimal coercion helper for parity fixtures."""
    return value if isinstance(value, Decimal) else D(str(value))


# ---------------------------------------------------------------------------
# A/B/C/D/E — line calculation, discount, TVA, precision, half-up rounding
# ---------------------------------------------------------------------------


class TestLineCalculation:
    def test_basic_line_2x100_tva19(self) -> None:
        totals = calculate_line(_line("2", "100", "19"))
        assert totals.net_ht == D("200.00")
        assert totals.tva == D("38.00")
        assert totals.total_ttc == D("238.00")
        assert totals.gross == D("200.00")
        assert totals.discount_amount == D("0.00")

    def test_discount_10_percent(self) -> None:
        totals = calculate_line(_line("1", "1000", "19", "10"))
        assert totals.gross == D("1000.00")
        assert totals.discount_amount == D("100.00")
        assert totals.net_ht == D("900.00")
        assert totals.tva == D("171.00")
        assert totals.total_ttc == D("1071.00")

    @pytest.mark.parametrize(
        ("tva_rate", "expected_tva"),
        [("0", "0.00"), ("9", "9.00"), ("19", "19.00")],
    )
    def test_tva_rates(self, tva_rate: str, expected_tva: str) -> None:
        totals = calculate_line(_line("1", "100", tva_rate))
        assert totals.net_ht == D("100.00")
        assert totals.tva == D(expected_tva)

    def test_price_zero_is_valid_line(self) -> None:
        totals = calculate_line(_line("1", "0", "19"))
        assert totals.net_ht == D("0.00")
        assert totals.tva == D("0.00")

    def test_decimal_precision_three_tenths(self) -> None:
        # 3 * 0.1 is 0.30000000000000004 in binary float — exact in Decimal.
        totals = calculate_line(_line("3", "0.1", "19"))
        assert totals.net_ht == D("0.30")
        assert totals.tva == D("0.06")  # 0.057 rounds half-up to 0.06

    def test_tva_derives_from_raw_net_ht_not_rounded_net(self) -> None:
        # Rounding ORDER contract: net 0.0263 rounds to 0.03, but TVA must
        # come from the RAW 0.0263 (0.004997 -> 0.00), never from 0.03
        # (which would be 0.01). Source compute_line behaviour.
        totals = calculate_line(_line("1", "0.0263", "19"))
        assert totals.net_ht == D("0.03")
        assert totals.tva == D("0.00")
        assert totals.total_ttc == D("0.03")

    @pytest.mark.parametrize(
        ("value", "expected"),
        [("0.005", "0.01"), ("1.005", "1.01"), ("2.675", "2.68"), ("-0.005", "-0.01")],
    )
    def test_money_half_up_boundary(self, value: str, expected: str) -> None:
        # ROUND_HALF_UP, not banker's rounding and not float round().
        assert money(value) == D(expected)

    def test_line_net_half_up_boundary(self) -> None:
        # 1.01 with 50% off = 0.505 raw -> HALF_UP -> 0.51 (0.50 would be
        # banker's rounding).
        totals = calculate_line(_line("1", "1.01", "19", "50"))
        assert totals.net_ht == D("0.51")
        assert totals.tva == D("0.10")  # raw 0.505 * 0.19 = 0.09595

    def test_line_fields_are_consistent(self) -> None:
        totals = calculate_line(_line("7", "19.99", "9", "33.33"))
        assert isinstance(totals, LineTotals)
        assert totals.total_ttc == totals.net_ht + totals.tva
        assert totals.gross - totals.discount_amount == totals.net_ht


# ---------------------------------------------------------------------------
# F — document totals with multiple lines
# ---------------------------------------------------------------------------


class TestDocumentTotals:
    def test_source_example_totals(self) -> None:
        # test_calc.py: 1 x 10000 @19 cash -> 10000 / 1900 / 11900 / 119 / 12019
        totals = calculate_totals([_line("1", "10000", "19")], cash=True)
        assert totals.total_ht == D("10000.00")
        assert totals.total_tva == D("1900.00")
        assert totals.total_ttc == D("11900.00")
        assert totals.timbre == D("119")
        assert totals.net_a_payer == D("12019.00")

    def test_multiple_lines_sum_rounded_per_line_values(self) -> None:
        lines = [
            _line("2", "100", "19"),  # 200.00 / 38.00
            _line("1", "50", "9", "10"),  # 45.00  / 4.05
            _line("3", "0.1", "19"),  # 0.30   / 0.06
        ]
        totals = calculate_totals(lines, cash=False)
        assert totals.total_ht == D("245.30")
        assert totals.total_tva == D("42.11")
        assert totals.total_ttc == D("287.41")
        assert totals.timbre == D("0.00")  # <= 300 and non-cash
        assert totals.net_a_payer == D("287.41")

    def test_totals_ttc_is_ht_plus_tva(self) -> None:
        totals = calculate_totals(
            [_line("4", "123.45", "9"), _line("1", "77.77", "0")],
            cash=False,
        )
        assert totals.total_ttc == totals.total_ht + totals.total_tva

    def test_as_dict_matches_source_keys(self) -> None:
        totals = calculate_totals([_line("1", "100", "19")], cash=False)
        assert list(totals.as_dict()) == [
            "total_ht",
            "total_tva",
            "total_ttc",
            "timbre",
            "net_a_payer",
        ]

    def test_empty_lines_are_zero_totals_permissive_core(self) -> None:
        # Source compute_totals([]) -> all zeros; validation (>= 1 line)
        # is explicit via validate_document_inputs.
        totals = calculate_totals([], cash=True)
        assert totals.total_ht == D("0.00")
        assert totals.net_a_payer == D("0.00")


# ---------------------------------------------------------------------------
# G — stamp duty boundaries
# ---------------------------------------------------------------------------


class TestStampDuty:
    @pytest.mark.parametrize(
        ("total", "expected"),
        [
            ("0", "0"),
            ("250", "0"),
            ("300", "0"),  # exactly 300 -> free
            ("300.01", "5"),  # just above -> ceil(3.0001)=4 -> min 5
            ("301", "5"),  # ceil(3.01)=4 -> min 5
            ("400", "5"),  # 1% = 4 -> min 5
            ("500", "5"),  # 1% = 5
            ("501", "6"),  # ceil(5.01)=6
            ("30000", "300"),  # tier-1 top, exact 1%
            ("30000.01", "451"),  # tier 1.5%: 450.00015 -> ceil 451
            ("30001", "451"),  # 450.015 -> ceil 451
            ("100000", "1500"),  # tier-2 top, exact 1.5%
            ("100001", "2001"),  # tier 2%: 2000.02 -> ceil 2001
            ("999999", "20000"),  # 19999.98 -> ceil 20000
        ],
    )
    def test_cash_boundaries(self, total: str, expected: str) -> None:
        assert stamp_duty(D(total), cash=True) == D(expected)

    @pytest.mark.parametrize("total", ["0", "301", "11900", "100001"])
    def test_non_cash_is_always_zero(self, total: str) -> None:
        assert stamp_duty(D(total), cash=False) == D("0")

    def test_source_assertions(self) -> None:
        # Ported verbatim from test_calc.py.
        assert stamp_duty(D("250"), cash=True) == 0
        assert stamp_duty(D("11900"), cash=True) == 119
        assert stamp_duty(D("11900"), cash=False) == 0


# ---------------------------------------------------------------------------
# H/I — amount in words + document phrases
# ---------------------------------------------------------------------------


class TestAmountInWords:
    @pytest.mark.parametrize(
        ("n", "expected"),
        [
            (0, "zéro"),
            (1, "un"),
            (10, "dix"),
            (21, "vingt et un"),
            (70, "soixante-dix"),
            (71, "soixante et onze"),
            (77, "soixante-dix-sept"),
            (79, "soixante-dix-neuf"),
            (80, "quatre-vingts"),
            (81, "quatre-vingt-un"),
            (91, "quatre-vingt-onze"),
            (99, "quatre-vingt-dix-neuf"),
            (100, "cent"),
            (101, "cent un"),
            (200, "deux cents"),
            (201, "deux cent un"),
            (999, "neuf cent quatre-vingt-dix-neuf"),
            (1000, "mille"),
            (80000, "quatre-vingt mille"),
            (41055, "quarante et un mille cinquante-cinq"),
            (1_000_000, "un million"),
            (1_000_001, "un million un"),
            (2_500_000, "deux millions cinq cent mille"),
        ],
    )
    def test_number_to_words(self, n: int, expected: str) -> None:
        assert number_to_words_fr(n) == expected

    @pytest.mark.parametrize(
        ("amount", "expected_body"),
        [
            (0, "Zéro dinar algérien."),
            (1, "Un dinar algérien."),
            (10, "Dix dinars algériens."),
            (21, "Vingt et un dinars algériens."),  # plural after 1 (source rule)
            ("41055", "Quarante et un mille cinquante-cinq dinars algériens."),
            (
                "1234.56",
                "Mille deux cent trente-quatre dinars algériens et cinquante-six centimes.",
            ),
            ("1.5", "Un dinar algérien et cinquante centimes."),
            ("0.05", "Zéro dinar algérien et cinq centimes."),
        ],
    )
    def test_amount_body(self, amount: str, expected_body: str) -> None:
        phrase = DOCUMENT_PHRASES["FAC"]
        assert amount_in_words(amount) == f"Arrêté {phrase} à la somme de : {expected_body}"

    @pytest.mark.parametrize("doc_type", sorted(DOC_TYPES))
    def test_document_phrase_per_type(self, doc_type: str) -> None:
        result = amount_in_words(D("1000"), doc_type)
        phrase = DOCUMENT_PHRASES[doc_type]
        assert result == f"Arrêté {phrase} à la somme de : Mille dinars algériens."

    def test_unknown_doc_type_falls_back_to_fac_phrase(self) -> None:
        assert amount_in_words(D("1000"), "XX") == amount_in_words(D("1000"), "FAC")


# ---------------------------------------------------------------------------
# J — determinism
# ---------------------------------------------------------------------------


class TestDeterminism:
    def test_totals_and_words_are_deterministic(self) -> None:
        lines = [_line("3", "199.99", "19", "7.5"), _line("1", "0.07", "9")]
        first = calculate_totals(lines, cash=True)
        second = calculate_totals(lines, cash=True)
        assert first == second
        assert amount_in_words(first.net_a_payer) == amount_in_words(second.net_a_payer)
        assert stamp_duty(first.total_ttc, True) == stamp_duty(second.total_ttc, True)


# ---------------------------------------------------------------------------
# K — validation boundaries
# ---------------------------------------------------------------------------


class TestValidation:
    @pytest.mark.parametrize("doc_type", sorted(DOC_TYPES))
    def test_valid_doc_types(self, doc_type: str) -> None:
        assert validate_doc_type(doc_type) == doc_type

    @pytest.mark.parametrize("bad", ["", "XX", "fac", "FACTURE", "FACC"])
    def test_invalid_doc_types(self, bad: str) -> None:
        with pytest.raises(FacturationError):
            validate_doc_type(bad)

    @pytest.mark.parametrize("method", sorted(PAYMENT_METHODS))
    def test_valid_payment_methods(self, method: str) -> None:
        assert validate_payment_method(method) == method

    @pytest.mark.parametrize("bad", ["", "card", "wire", "Cash", "CHECK"])
    def test_invalid_payment_methods(self, bad: str) -> None:
        with pytest.raises(FacturationError):
            validate_payment_method(bad)

    @pytest.mark.parametrize("rate", ["0", "9", "19"])
    def test_valid_tva_rates(self, rate: str) -> None:
        validate_line(_line("1", "1", rate))

    @pytest.mark.parametrize("rate", ["1", "7", "19.5", "-9", "20"])
    def test_invalid_tva_rates(self, rate: str) -> None:
        with pytest.raises(FacturationError):
            validate_line(_line("1", "1", rate))

    @pytest.mark.parametrize(
        ("qty", "price", "discount"),
        [
            ("0", "1", "0"),
            ("-1", "1", "0"),
            ("1", "-0.01", "0"),
            ("1", "1", "-0.01"),
            ("1", "1", "100.01"),
            ("0.000", "0", "100"),
        ],
    )
    def test_invalid_line_numbers(self, qty: str, price: str, discount: str) -> None:
        with pytest.raises(FacturationError):
            validate_line(_line(qty, price, "19", discount))

    @pytest.mark.parametrize(
        ("qty", "price", "discount"),
        [("0.001", "0", "0"), ("1", "0", "100"), ("10", "0.01", "100")],
    )
    def test_boundary_line_numbers_are_valid(self, qty: str, price: str, discount: str) -> None:
        validate_line(_line(qty, price, "19", discount))

    @pytest.mark.parametrize("bad", ["NaN", "Infinity", "-Infinity", "abc", ""])
    def test_non_finite_or_non_decimal_values(self, bad: str) -> None:
        with pytest.raises(FacturationError):
            validate_line(FactureLine(bad, "1", "19", "0"))

    def test_validate_line_returns_the_line(self) -> None:
        line = _line("2", "5", "9")
        assert validate_line(line) is line

    def test_validate_document_inputs_requires_lines(self) -> None:
        with pytest.raises(FacturationError, match="at least one line"):
            validate_document_inputs("FAC", "cash", [])

    def test_validate_document_inputs_rejects_bad_members(self) -> None:
        with pytest.raises(FacturationError):
            validate_document_inputs("XX", "cash", [_line("1", "1", "19")])
        with pytest.raises(FacturationError):
            validate_document_inputs("FAC", "card", [_line("1", "1", "19")])
        with pytest.raises(FacturationError):
            validate_document_inputs("FAC", "cash", [_line("1", "1", "7")])

    def test_calculate_document_totals_validates_first(self) -> None:
        with pytest.raises(FacturationError):
            calculate_document_totals(
                [_line("1", "1", "19")],
                doc_type="XX",
                payment_method="cash",
            )


# ---------------------------------------------------------------------------
# Facade semantics — FAC/cash/show_timbre wiring (main.py parity)
# ---------------------------------------------------------------------------


class TestDocumentFacade:
    def _big_cash_lines(self) -> list[FactureLine]:
        return [_line("1", "10000", "19")]  # TTC 11900 -> timbre 119

    def test_fac_cash_applies_timbre(self) -> None:
        totals = calculate_document_totals(
            self._big_cash_lines(), doc_type="FAC", payment_method="cash"
        )
        assert totals.timbre == D("119")
        assert totals.net_a_payer == D("12019.00")

    @pytest.mark.parametrize("doc_type", ["DEV", "PRO", "BC", "BL"])
    def test_non_fac_never_applies_timbre(self, doc_type: str) -> None:
        totals = calculate_document_totals(
            self._big_cash_lines(), doc_type=doc_type, payment_method="cash"
        )
        assert totals.timbre == D("0")
        assert totals.net_a_payer == totals.total_ttc

    @pytest.mark.parametrize("method", ["transfer", "cheque"])
    def test_fac_non_cash_never_applies_timbre(self, method: str) -> None:
        totals = calculate_document_totals(
            self._big_cash_lines(), doc_type="FAC", payment_method=method
        )
        assert totals.timbre == D("0")

    def test_show_timbre_false_removes_duty_from_net(self) -> None:
        # Source coupling: show_timbre gates the CALCULATION, not only display.
        totals = calculate_document_totals(
            self._big_cash_lines(),
            doc_type="FAC",
            payment_method="cash",
            show_timbre=False,
        )
        assert totals.timbre == D("0")
        assert totals.net_a_payer == totals.total_ttc == D("11900.00")

    def test_show_timbre_default_is_true(self) -> None:
        totals = calculate_document_totals(
            self._big_cash_lines(), doc_type="FAC", payment_method="cash"
        )
        assert totals.timbre == D("119")

    def test_fac_cash_below_threshold_has_no_timbre(self) -> None:
        totals = calculate_document_totals(
            [_line("1", "250", "0")], doc_type="FAC", payment_method="cash"
        )
        assert totals.timbre == D("0")
        assert totals.net_a_payer == D("250.00")

    def test_tva_rates_constant_matches_source_set(self) -> None:
        assert TVA_RATES == frozenset({D(0), D(9), D(19)})


# ---------------------------------------------------------------------------
# §12 — live parity against the factura_simple reference implementation
# ---------------------------------------------------------------------------

_PARITY_SKIP = pytest.mark.skipif(
    not FACTURA_SIMPLE_CALC.exists(),
    reason="factura_simple reference project not available on this machine",
)


@_PARITY_SKIP
class TestSourceParity:
    """Same inputs through factura_simple.calc and this domain — equal outputs."""

    @pytest.mark.parametrize(
        "qty",
        ["1", "2", "3.5", "0.25"],
    )
    @pytest.mark.parametrize(
        "price",
        ["0.01", "0.1", "1", "19.99", "10000", "120000"],
    )
    @pytest.mark.parametrize("tva", ["0", "9", "19"])
    @pytest.mark.parametrize("discount", ["0", "5", "33.33", "100"])
    def test_line_parity(self, qty: str, price: str, tva: str, discount: str) -> None:
        source = _load_source_calc()
        ours = calculate_line(_line(qty, price, tva, discount))
        src_net, src_tva = source.compute_line(source.Line(D(qty), D(price), D(tva), D(discount)))
        assert ours.net_ht == src_net
        assert ours.tva == src_tva

    @pytest.mark.parametrize(
        "total",
        [
            "0",
            "250",
            "300",
            "300.01",
            "301",
            "400",
            "500",
            "501",
            "30000",
            "30000.01",
            "30001",
            "100000",
            "100001",
            "999999",
        ],
    )
    @pytest.mark.parametrize("cash", [True, False])
    def test_stamp_duty_parity(self, total: str, cash: bool) -> None:
        source = _load_source_calc()
        assert stamp_duty(D(total), cash) == source.stamp_duty(D(total), cash)

    _LINE_SETS: list[list[FactureLine]] = [
        [_line("1", "10000", "19")],
        [_line("2", "100", "19"), _line("1", "50", "9", "10")],
        [_line("1", "120000", "0"), _line("1", "30000", "19", "5")],
        [_line("3", "0.1", "19")],
        [_line("1", "0.0263", "19")],
        [_line("10", "333.33", "9", "33.33")],
        [_line("1", "0.01", "19"), _line("1", "0.02", "0")],
        [_line("0.5", "1999.995", "19", "99.99")],
    ]

    @pytest.mark.parametrize("show_timbre", [True, False])
    @pytest.mark.parametrize("payment", ["cash", "transfer", "cheque"])
    @pytest.mark.parametrize("doc_type", ["FAC", "DEV", "PRO", "BC", "BL"])
    def test_document_totals_parity(self, doc_type: str, payment: str, show_timbre: bool) -> None:
        source = _load_source_calc()
        for lines in self._LINE_SETS:
            src_lines = [
                source.Line(
                    to_dec(ln.qty),
                    to_dec(ln.unit_price_ht),
                    to_dec(ln.tva_rate),
                    to_dec(ln.discount_pct),
                )
                for ln in lines
            ]
            cash = doc_type == "FAC" and payment == "cash"
            src = source.compute_totals(src_lines, cash=cash, apply_timbre=show_timbre)
            ours = calculate_document_totals(
                lines,
                doc_type=doc_type,
                payment_method=payment,
                show_timbre=show_timbre,
            )
            assert ours.as_dict() == src
            # End-to-end: amount_in_words on the computed net.
            assert amount_in_words(ours.net_a_payer, doc_type) == source.amount_in_words(
                src["net_a_payer"], doc_type
            )

    @pytest.mark.parametrize("doc_type", ["FAC", "DEV", "PRO", "BC", "BL", "XX"])
    @pytest.mark.parametrize(
        "amount",
        [
            "0",
            "1",
            "10",
            "21",
            "71",
            "80",
            "91",
            "100",
            "200",
            "1000",
            "41055",
            "1000000",
            "1234.56",
            "0.05",
            "999999.99",
        ],
    )
    def test_amount_in_words_parity(self, amount: str, doc_type: str) -> None:
        source = _load_source_calc()
        assert amount_in_words(amount, doc_type) == source.amount_in_words(amount, doc_type)

    @pytest.mark.parametrize(
        "n",
        list(range(0, 1201)) + [2000, 41055, 80000, 999999, 1_000_000, 2_500_000, 41_055_123],
    )
    def test_number_to_words_parity(self, n: int) -> None:
        source = _load_source_calc()
        assert number_to_words_fr(n) == source.number_to_words_fr(n)
