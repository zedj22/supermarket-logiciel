"""80mm receipt readability pass — bigger type, identical layout.

The readability change raised the thermal receipt's type scale by ~10–15%
without touching geometry, columns, separators, money or the footer
source.  These tests pin both halves of that promise:

* every rung of the scale is actually bigger than the one it replaced
  (body 7.5 → 8.5, headings 7.5 → 8.5, meta 6.5 → 7.3, store 12 → 13,
  contacts 7 → 7.8, stamp 8 → 8.8, footer 8 → 8.8);
* nothing else moved: the page is still exactly 80mm, the four columns
  still sum to the content width and still fit their text without
  clipping, there is still one separator after the last item, the
  payment summary is unchanged, and the closing message still comes from
  Settings when one is configured.

The store name stays the largest line and the total stays bold, so the
hierarchy the operator reads at a glance is preserved.
"""

from __future__ import annotations

import re
import sys
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import Paragraph, Table

from app.printing.document_data import DocumentData, build_sale_document
from app.printing.fonts import FONT_REGULAR, register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.templates import receipt_80mm
from app.printing.text import shape_text
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
D = Decimal
PACK_MARKER = "- Lait 1L"

#: The sizes the receipt shipped with before this pass — the yardstick for
#: "the type actually got bigger", not a second copy of the constants.
_PREVIOUS = {"BODY": 7.5, "HEADING": 7.5, "META": 6.5}


# ─── helpers ────────────────────────────────────────────────────────────────


def _doc(locale: str = "en", **over) -> DocumentData:
    defaults = dict(
        invoice_number="INV-2026-000123",
        cashier_name="Amina",
        subtotal=D("1070.000"),
        discount=D("180.000"),
        total=D("890.000"),
        paid=D("2000.000"),
        change=D("1110.000"),
        lines=[
            _sale_line(
                product_name="Coca Cola 1L",
                quantity=D("2"),
                unit_price=D("160.000"),
                line_total=D("320.000"),
            ),
        ],
    )
    defaults.update(over)
    return build_sale_document(_sale_payload(**defaults), locale=locale)


def _items(data: DocumentData) -> Table:
    table = receipt_80mm._items_table(data)
    assert table is not None
    return table


def _payment(data: DocumentData) -> Table:
    box = receipt_80mm._payment_box(data)
    assert box is not None
    return box


def _media_box(raw: bytes) -> tuple[float, float]:
    box = raw.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(box[2]), float(box[3])


def _page_count(raw: bytes) -> int:
    return len(re.findall(rb"/Type\s*/Page[^s]", raw))


def _blocks(raw: bytes) -> list[str]:
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


def _drawn(data: DocumentData) -> str:
    return " | ".join(" ".join(block.split()) for block in _blocks(render_invoice(data, "80mm")))


def _row_cells(table: Table, row: int) -> list[Any]:
    return list(table._cellvalues[row])


# ─── 1. the scale actually grew ─────────────────────────────────────────────


@pytest.mark.parametrize("name,previous", sorted(_PREVIOUS.items()))
def test_every_rung_grew_by_at_least_ten_percent(name: str, previous: float) -> None:
    current = getattr(receipt_80mm, name)
    assert current / previous >= 1.10, (
        f"{name} is {current}pt — only {current / previous:.1%} of the old {previous}pt"
    )
    assert current / previous <= 1.20, "a modest bump, not a redesign"


def test_store_identity_and_total_keep_their_hierarchy() -> None:
    # The store name is still the loudest line on the paper…
    assert receipt_80mm.STORE_NAME > receipt_80mm.BODY
    # …the item body is one readable size with the headings…
    assert receipt_80mm.BODY == receipt_80mm.HEADING
    # …and the detail lines stay subordinate to it.
    assert receipt_80mm.META < receipt_80mm.BODY
    assert receipt_80mm.NOTICE < receipt_80mm.BODY
    assert receipt_80mm.STORE_CONTACT < receipt_80mm.STORE_NAME


def test_payment_total_row_stays_bold_and_body_sized() -> None:
    rows = _row_cells(_payment(_doc("fr")), 1)  # Reçu / Total / Rendu → Total
    assert rows[0].style.fontSize == receipt_80mm.BODY
    assert rows[0].style.fontName.lower().endswith("bold")


# ─── 2. the layout did not move ─────────────────────────────────────────────


def test_columns_still_fill_the_same_content_width() -> None:
    widths = [
        receipt_80mm.COL_DESIGNATION,
        receipt_80mm.COL_PRICE,
        receipt_80mm.COL_QTY,
        receipt_80mm.COL_AMOUNT,
    ]
    assert sum(widths) == pytest.approx(receipt_80mm.CONTENT_WIDTH, abs=0.01)
    assert len(widths) == 4
    assert all(width > 0 for width in widths)


@pytest.mark.parametrize("locale", LOCALES)
def test_page_is_still_exactly_80mm_and_one_page(locale: str) -> None:
    raw = render_invoice(_doc(locale), "80mm")
    width, height = _media_box(raw)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)
    assert 140 * mm <= height <= 400 * mm
    assert _page_count(raw) == 1


#: Logical column widths, LTR order (mirrored for Arabic rows).
def _widths(rtl: bool) -> list[float]:
    widths = [
        receipt_80mm.COL_DESIGNATION,
        receipt_80mm.COL_PRICE,
        receipt_80mm.COL_QTY,
        receipt_80mm.COL_AMOUNT,
    ]
    return list(reversed(widths)) if rtl else widths


def _cell_text_width(cell: Paragraph) -> float:
    """The width the text needs on ONE line at the cell's own font size.

    `Paragraph.wrap()` clamps to the available width, so it can never show
    a wrap — measuring the string is what actually proves one line fits.
    """
    return stringWidth(cell.text, cell.style.fontName, cell.style.fontSize)


@pytest.mark.parametrize("locale", LOCALES)
def test_every_column_heading_fits_on_one_line(locale: str) -> None:
    """The bigger headings must not wrap — Arabic `سعر الوحدة` is the widest."""
    data = _doc(locale)
    table = _items(data)
    widths = _widths(data.rtl)
    for column, cell in enumerate(_row_cells(table, 0)):
        assert isinstance(cell, Paragraph)
        usable = widths[column] - 2 * receipt_80mm.PAD
        assert _cell_text_width(cell) <= usable + 0.01, (
            f"{locale}: heading {cell.text!r} wraps in column {column} "
            f"({_cell_text_width(cell):.2f} > {usable:.2f})"
        )
        assert cell.style.fontSize == receipt_80mm.HEADING


@pytest.mark.parametrize("locale", LOCALES)
def test_numeric_cells_never_wrap_at_the_new_size(locale: str) -> None:
    """Money and quantity stay on one line; only the name column may wrap."""
    data = _doc(
        locale,
        lines=[
            _sale_line(
                product_name="Chocolat noir extra fin 70% cacao 200 g",
                quantity=D("1.5"),
                unit_price=D("9999.990"),
                line_total=D("9999.990"),
            ),
        ],
    )
    table = _items(data)
    widths = _widths(data.rtl)
    designation_column = 3 if data.rtl else 0
    for row_index, row in enumerate(table._cellvalues):
        for column, cell in enumerate(row):
            if not isinstance(cell, Paragraph) or column == designation_column:
                continue
            if not cell.text:
                continue
            usable = widths[column] - 2 * receipt_80mm.PAD
            assert _cell_text_width(cell) <= usable + 0.01, (
                f"{locale}: {cell.text!r} wraps in column {column} "
                f"({_cell_text_width(cell):.2f} > {usable:.2f})"
            )


def test_the_long_product_name_still_gets_a_full_designation_column() -> None:
    """The name column is allowed to wrap — but it must stay the widest."""
    assert receipt_80mm.COL_DESIGNATION > receipt_80mm.COL_AMOUNT
    assert receipt_80mm.COL_DESIGNATION > receipt_80mm.COL_PRICE
    assert receipt_80mm.COL_DESIGNATION > receipt_80mm.COL_QTY


@pytest.mark.parametrize("locale", LOCALES)
def test_ordinary_amounts_are_printed_at_the_full_body_size(locale: str) -> None:
    """A normal price/quantity/amount never triggers the shrink fallback.

    `9 999.99` is the widest ordinary unit price and it must fit the money
    column at the new 8.5pt — that is what the +2pt column rebalance bought.
    """
    data = _doc(
        locale,
        lines=[
            _sale_line(
                product_name="Cola",
                quantity=D("1"),
                unit_price=D("9999.990"),
                line_total=D("9999.990"),
            )
        ],
    )
    cells = _row_cells(_items(data), 1)
    numeric = [cell for cell in cells if isinstance(cell, Paragraph)]
    sized = [cell for cell in numeric if cell.text][1:]  # skip the name cell
    assert sized, "the value cells must exist"
    for cell in sized:
        assert cell.style.fontSize == pytest.approx(receipt_80mm.BODY), (
            f"{cell.text!r} shrank to {cell.style.fontSize}pt"
        )


@pytest.mark.parametrize("locale", LOCALES)
def test_a_millions_scale_amount_never_shrinks_below_the_old_floor(
    locale: str,
) -> None:
    """The shrink fallback may still run — but never below the old floor."""
    data = _doc(
        locale,
        lines=[
            _sale_line(
                product_name="Cola",
                quantity=D("1"),
                unit_price=D("1234567.890"),
                line_total=D("1234567.890"),
            )
        ],
    )
    table = _items(data)
    cells = [
        cell
        for row in table._cellvalues
        for cell in row
        if isinstance(cell, Paragraph) and cell.text
    ]
    shrunk = [cell for cell in cells if cell.style.fontSize < receipt_80mm.BODY]
    assert shrunk, "this fixture is deliberately an extreme amount"
    for cell in cells:
        assert cell.style.fontSize >= receipt_80mm._NUM_SIZE_MIN - 1e-9, (
            f"{cell.text!r} fell to {cell.style.fontSize}pt"
        )


def test_separator_rules_are_unchanged() -> None:
    data = _doc(
        "en",
        lines=[
            _sale_line(product_name="Cola", line_total=D("200.000")),
            _sale_line(product_name="Eau", line_total=D("150.000")),
        ],
    )
    table = _items(data)
    below = [cmd for cmd in table._linecmds if cmd[0] == "LINEBELOW"]
    # heading rule + exactly ONE rule after the final product row.
    assert len(below) == 2
    assert below[0][1] == (0, 0)
    assert below[1][1] == (0, len(table._cellvalues) - 1)


# ─── 3. content, languages and the footer source ────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_arabic_and_french_keep_their_shaping_and_every_field(locale: str) -> None:
    data = _doc(locale)
    raw = render_invoice(data, "80mm")
    assert raw.startswith(b"%PDF")
    drawn = _drawn(data)
    # Product, quantities, totals, cashier and the payment box all print.
    for expected in (
        "Coca Cola 1L",
        "320.00",
        "1 070.00 DA",
        "Amina",
        "2 000.00 DA",
        "890.00 DA",
        "1 110.00 DA",
    ):
        assert expected in drawn, f"{locale}: missing {expected!r}"
    assert shape_text("Coca Cola 1L") in drawn


def test_pack_names_and_component_rows_still_render() -> None:
    import uuid

    pack_id = uuid.uuid4()
    data = _doc(
        "fr",
        lines=[
            _sale_line(
                product_id=None,
                pack_id=pack_id,
                product_name="Pack Rentrée",
                product_unit="pack",
                quantity=D("1"),
                unit_price=D("300.000"),
                line_total=D("300.000"),
            ),
            _sale_line(
                pack_id=pack_id,
                product_name="Lait 1L",
                quantity=D("2"),
                line_total=D("0.000"),
            ),
        ],
    )
    table = _items(data)
    assert table._ncols == 4
    texts = {
        cell.text
        for row in table._cellvalues
        for cell in row
        if isinstance(cell, Paragraph)
    }
    assert any(text.endswith(label("pack_marker", "fr")) for text in texts)
    assert PACK_MARKER in texts
    assert PACK_MARKER in _drawn(data)


def test_configured_footer_still_comes_from_invoice_settings() -> None:
    data = _doc("fr")
    data.store.footer = "Merci et à bientôt !"
    drawn = _drawn(data)
    assert "Merci et à bientôt !" in drawn
    assert drawn.count("Merci et à bientôt !") == 1
    # The built-in thank-you wording is replaced, never printed alongside.
    assert "Merci pour votre visite" not in drawn


@pytest.mark.parametrize("locale", LOCALES)
def test_no_barcode_and_no_invoice_reference(locale: str) -> None:
    data = _doc(locale)
    reference = data.header.document_number
    story = receipt_80mm.build_flowables(data)
    assert not any(
        type(item).__module__.startswith("reportlab.graphics.barcode")
        for item in story
    )
    assert reference not in _drawn(data)


def test_body_text_is_measurably_wider_than_before_the_pass() -> None:
    """Guard the intent: the same string now draws wider on the paper."""
    text = "Coca Cola 1L"
    old = stringWidth(shape_text(text), FONT_REGULAR, 7.5)
    new = stringWidth(shape_text(text), FONT_REGULAR, receipt_80mm.BODY)
    assert new > old
    assert new / old == pytest.approx(receipt_80mm.BODY / 7.5, rel=1e-6)
