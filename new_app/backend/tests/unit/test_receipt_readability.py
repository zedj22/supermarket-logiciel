"""80mm receipt readability passes — bigger type, identical layout.

Three readability steps raised the thermal receipt's type scale
(7.5 → 8.5 → 9.0 → 11.0 body).  The third was a real step (~22%), not
another 5% nudge: the 9pt body was still hard to read on thermal paper, so
the ledger columns were rebalanced from measurement to pay for it.  These
tests pin both halves of that promise:

* every rung of the scale is bigger than the one the previous release
  shipped (body 9 → 11, headings 9 → 10.5, meta 7.7 → 9) and the printed
  sizes are the ones the operator asked for;
* nothing else moved: the page is still exactly 80mm, the four columns
  still sum to the content width and still fit their text without
  clipping, there is still one separator after the last item, the
  payment summary is unchanged, and the closing message still comes from
  Settings when one is configured.

The store name stays the largest line and the total is now a step above
the body, bold, so the hierarchy the operator reads at a glance is
preserved — and the figure the customer checks is the easiest to read.
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
from app.printing.fonts import FONT_BOLD, FONT_REGULAR, register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.templates import receipt_80mm
from app.printing.text import shape_text
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
D = Decimal
PACK_MARKER = "- Lait 1L"

#: The sizes the PREVIOUS release shipped — the yardstick for "the type
#: actually got bigger again", not a second copy of the constants.
_PREVIOUS = {"BODY": 9.0, "HEADING": 9.0, "META": 7.7}

#: The original 7.5pt body, kept so the cumulative gain stays guarded.
_ORIGINAL_BODY = 7.5


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
def test_every_rung_grew_since_the_previous_release(name: str, previous: float) -> None:
    current = getattr(receipt_80mm, name)
    assert current / previous >= 1.15, (
        f"{name} is {current}pt — only {current / previous:.1%} of the previous {previous}pt"
    )
    assert current / previous <= 1.30, "a step up, not a redesign of the scale"


def test_the_printed_sizes_are_the_ones_the_operator_asked_for() -> None:
    """11pt body / 10.5pt headings / 9pt meta — measured on the paper."""
    assert receipt_80mm.BODY == pytest.approx(11.0, abs=0.01)
    assert receipt_80mm.HEADING == pytest.approx(10.5, abs=0.01)
    assert receipt_80mm.META == pytest.approx(9.0, abs=0.01)


def test_the_body_is_still_bigger_than_the_original_7_5pt() -> None:
    assert receipt_80mm.BODY / _ORIGINAL_BODY == pytest.approx(1.47, abs=0.01)


def test_store_identity_and_total_keep_their_hierarchy() -> None:
    # The store name is still the loudest line on the paper…
    assert receipt_80mm.STORE_NAME > receipt_80mm.BODY
    # …the headings sit just below the body (they are the scarce width)…
    assert receipt_80mm.HEADING < receipt_80mm.BODY
    # …the payment-box total is the loudest NUMBER, above the body…
    assert receipt_80mm.TOTAL > receipt_80mm.BODY
    assert receipt_80mm.TOTAL < receipt_80mm.STORE_NAME
    # …and the detail lines stay subordinate to it.
    assert receipt_80mm.META < receipt_80mm.BODY
    assert receipt_80mm.NOTICE < receipt_80mm.BODY
    assert receipt_80mm.STORE_CONTACT < receipt_80mm.STORE_NAME


@pytest.mark.parametrize("locale", LOCALES)
def test_payment_total_row_is_bold_and_a_step_above_the_body(locale: str) -> None:
    rows = _row_cells(_payment(_doc(locale)), 1)  # Reçu / Total / Rendu → Total
    for cell in rows:
        assert cell.style.fontSize == receipt_80mm.TOTAL, (
            f"{locale}: total row printed at {cell.style.fontSize}pt"
        )
        assert cell.style.fontName.lower().endswith("bold")


def test_the_total_is_wide_enough_for_a_large_amount_at_its_larger_size() -> None:
    """The 13pt total never shrinks for a normal 4-digit amount."""
    data = _doc("fr", paid=D("12000.000"), total=D("12000.000"), change=D("0"))
    rows = _row_cells(_payment(data), 1)
    money = [cell for cell in rows if "12" in cell.text]
    assert money, "the total value must be in the box"
    assert money[0].style.fontSize == receipt_80mm.TOTAL


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


def test_the_price_column_fits_the_widest_heading_in_any_locale() -> None:
    """The column rebalance is sized from measurement, not from one locale.

    Arabic `سعر الوحدة` (the widest) and English `Unit price` must both have
    room inside COL_PRICE at the current heading size, with no shrinking and
    no second line — that is exactly why the price column grew by 5.5pt.
    """
    usable = receipt_80mm.COL_PRICE - 2 * receipt_80mm.PAD
    widest = 0.0
    for locale in LOCALES:
        text = shape_text(label(receipt_80mm.RECEIPT_COLUMNS[1], locale))
        width = stringWidth(text, FONT_BOLD, receipt_80mm.HEADING)
        widest = max(widest, width)
        assert width <= usable + 0.01, (
            f"{locale}: {label(receipt_80mm.RECEIPT_COLUMNS[1], locale)!r} "
            f"needs {width:.2f}pt, column has {usable:.2f}pt"
        )
    # The margin is real, not sub-pixel luck.
    assert usable - widest >= 0.3


def test_the_quantity_heading_fits_the_narrow_ledger_column() -> None:
    """Arabic `الكمية` is the widest quantity heading (26.20pt at 10.5)."""
    usable = receipt_80mm.COL_QTY - 2 * receipt_80mm.PAD
    for locale in LOCALES:
        width = stringWidth(
            shape_text(label(receipt_80mm.RECEIPT_COLUMNS[2], locale)),
            FONT_BOLD,
            receipt_80mm.HEADING,
        )
        assert width <= usable + 0.01, f"{locale}: quantity heading wraps"
    assert usable - width >= 0.25


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
    """A three-digit price/quantity/amount never triggers the shrink fallback.

    `999.99` fits the money column at the full 11pt — that is what the
    measured rebalance bought (44.79pt column, 42.19pt usable, 35.99pt of
    text).
    """
    data = _doc(
        locale,
        lines=[
            _sale_line(
                product_name="Cola",
                quantity=D("1"),
                unit_price=D("999.990"),
                line_total=D("999.990"),
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
def test_a_four_digit_amount_keeps_its_readability(locale: str) -> None:
    """`9 999.99` may shrink — but never to the old size, and never to a gap.

    The name column had to keep 64pt usable for ordinary product names, so
    the very widest ordinary amount gives up a few 0.25pt steps instead of
    wrapping or touching its neighbour: 9.5pt on paper, still bigger than
    the 9pt this cell shipped at before.
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
    cells = [
        cell
        for cell in _row_cells(_items(data), 1)
        if isinstance(cell, Paragraph) and cell.text
    ][1:]  # skip the name cell
    for cell in cells:
        assert cell.style.fontSize >= receipt_80mm.BODY - 1.5, (
            f"{cell.text!r} fell to {cell.style.fontSize}pt"
        )
        assert cell.style.fontSize <= receipt_80mm.BODY


@pytest.mark.parametrize("locale", LOCALES)
def test_a_wide_amount_never_touches_the_quantity_cell(locale: str) -> None:
    """Two adjacent numbers must be separated by more than a digit space.

    The columns are 2.6pt apart; without the reserved gutter a shrunk
    amount would sit ~2.7pt from the quantity and print as `1 1 350.00`.
    """
    data = _doc(
        locale,
        lines=[
            _sale_line(
                product_name="Huile",
                quantity=D("1"),
                unit_price=D("1350.000"),
                line_total=D("1350.000"),
            )
        ],
    )
    table = _items(data)
    widths = _widths(data.rtl)
    money_columns = (1, 3)  # logical price / amount
    checked = 0
    for column, cell in enumerate(_row_cells(table, 1)):
        if not isinstance(cell, Paragraph) or "1 350.00" not in cell.text:
            continue
        gap = widths[column] - _cell_text_width(cell)
        checked += 1
        assert gap >= 5.0, f"{locale}: {cell.text!r} leaves only {gap:.2f}pt of gutter"
    assert checked == len(money_columns), f"{locale}: expected both money cells"


def test_an_ordinary_product_name_stays_on_one_line() -> None:
    """The whole point of the rebalance: 11-char names do not wrap at 11pt.

    Longer names (`Lait Candia 1L`, 69.3pt) wrap onto a second line — that
    is the unavoidable trade on 80mm paper, and the name column is still
    the widest of the four.
    """
    usable = receipt_80mm.COL_DESIGNATION - 2 * receipt_80mm.PAD
    for name in ("Coca Cola 1L", "Huile 5L", "Eau 1.5L"):
        width = stringWidth(shape_text(name), FONT_REGULAR, receipt_80mm.BODY)
        assert width <= usable + 0.01, (
            f"{name!r} needs {width:.2f}pt, name column has {usable:.2f}pt"
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
    old = stringWidth(shape_text(text), FONT_REGULAR, _PREVIOUS["BODY"])
    new = stringWidth(shape_text(text), FONT_REGULAR, receipt_80mm.BODY)
    assert new > old
    assert new / old == pytest.approx(
        receipt_80mm.BODY / _PREVIOUS["BODY"], rel=1e-6
    )
