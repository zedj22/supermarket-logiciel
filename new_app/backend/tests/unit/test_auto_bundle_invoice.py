"""Invoice presentation for Method 2 (automatic sell-unit) lines.

A Method 2 line persists the REGULAR unit price and carries the bundle
saving as its line discount:

    quantity = 5      unit_price = 500.00
    line_discount = 100.00   →   line_total = 2400.00

The rendered invoice must therefore show, for that line: product name,
quantity, the regular unit price, the bundle discount amount and the final
line total — the same numbers the cart displayed and the sale persisted.
Bundle quantity/price themselves are NOT part of the persisted sale line
(no schema change was made), so the receipt shows the resulting SAVING,
which is the amount that matters to the shopper; the cashier sees the
"4 × 1900" bundle in the POS cart instead.

A sale with no sell units keeps its previous layout: no discount row, no
"line discounts" totals row.
"""

from __future__ import annotations

import sys
from decimal import Decimal
from pathlib import Path

import pytest

from app.printing.document_data import build_sale_document
from app.printing.fonts import register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.text import format_money
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
D = Decimal

REGULAR_PRICE = D("500.000")
LINE_DISCOUNT = D("100.000")  # 5 units → one complete 4-unit bundle
LINE_TOTAL = D("2400.000")
LINE_SUBTOTAL = D("2500.000")


def _bundle_payload(**over):
    """One Method 2 line: 5 × 500.00 with a 100.00 bundle discount."""
    data = dict(
        subtotal=LINE_SUBTOTAL,
        discount=D("0.000"),
        total=LINE_TOTAL,
        paid=LINE_TOTAL,
        change=D("0.000"),
        debt=D("0.000"),
        lines=[
            _sale_line(
                product_name="Bread",
                product_sku=None,
                product_barcode=None,
                quantity=D("5"),
                unit_price=REGULAR_PRICE,
                line_discount=LINE_DISCOUNT,
                line_total=LINE_TOTAL,
            )
        ],
        payments=[],
    )
    data.update(over)
    return _sale_payload(**data)


def _plain_payload(**over):
    """The same product without any sell unit: no discount anywhere."""
    data = dict(
        subtotal=D("2000.000"),
        discount=D("0.000"),
        total=D("2000.000"),
        paid=D("2000.000"),
        lines=[
            _sale_line(
                product_name="Bread",
                product_sku=None,
                product_barcode=None,
                quantity=D("4"),
                unit_price=REGULAR_PRICE,
                line_discount=D("0.000"),
                line_total=D("2000.000"),
            )
        ],
        payments=[],
    )
    data.update(over)
    return _sale_payload(**data)


def _compact(text: str) -> str:
    """Document text without thousands grouping ("2 400.00 DA" → "2400.00DA")."""
    return text.replace(" ", "")


def _blocks(raw: bytes) -> list[str]:
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


@pytest.mark.parametrize("locale", LOCALES)
def test_bundle_line_carries_every_documented_field(locale: str) -> None:
    data = build_sale_document(_bundle_payload(), locale=locale)
    line = data.lines[0]

    assert line.name == "Bread"                                  # product name
    assert line.qty == "5"                                       # quantity
    assert line.unit_price == format_money(REGULAR_PRICE)        # REGULAR price
    assert line.line_discount == format_money(LINE_DISCOUNT)     # bundle saving
    assert line.line_total == format_money(LINE_TOTAL)           # final total
    # The saving is also summed for the document footer.
    assert data.totals is not None
    assert data.totals.line_discounts_sum == format_money(LINE_DISCOUNT)
    assert data.totals.total == format_money(LINE_TOTAL)


@pytest.mark.parametrize("paper", ["80mm", "A4"])
@pytest.mark.parametrize("locale", LOCALES)
def test_bundle_invoice_renders_in_every_locale(paper: str, locale: str) -> None:
    data = build_sale_document(_bundle_payload(), locale=locale)
    raw = render_invoice(data, paper=paper)
    assert raw.startswith(b"%PDF")
    assert len(raw) > 1000

    blocks = _blocks(raw)
    # The amount is printed whatever the script: digits stay in visual
    # order in the Arabic receipt too (one bidi pass, §15.7 A8).
    assert any("100.00" in _compact(b) for b in blocks), blocks
    assert any("2400.00" in _compact(b) for b in blocks), blocks
    if locale in ("en", "fr"):
        # The discount is LABELLED, not just a bare number.
        assert any(label("discount", locale) in b for b in blocks), blocks


def test_plain_sale_layout_is_unchanged() -> None:
    """No sell unit → no discount row and no "line discounts" total."""
    for locale in LOCALES:
        data = build_sale_document(_plain_payload(), locale=locale)
        line = data.lines[0]
        assert line.line_discount is None
        assert line.unit_price == format_money(REGULAR_PRICE)
        assert line.line_total == format_money(D("2000.000"))
        assert data.totals is not None
        assert data.totals.line_discounts_sum is None
        raw = render_invoice(data, paper="80mm")
        assert raw.startswith(b"%PDF")


def test_invoice_line_total_equals_persisted_amount() -> None:
    """The invoice NEVER recomputes: it prints the stored line totals."""
    data = build_sale_document(_bundle_payload(), locale="en")
    line = data.lines[0]
    # What the invoice prints is exactly what the sale stored: the regular
    # price × quantity, less the derived bundle discount.
    assert format_money((D(line.qty) * REGULAR_PRICE) - LINE_DISCOUNT) == (
        line.line_total
    )
    assert line.line_total == format_money(LINE_TOTAL)
    assert line.line_discount == format_money(LINE_DISCOUNT)
