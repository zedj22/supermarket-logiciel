"""Phase 17 — 80mm receipt item normalization (one contract, one renderer).

Legacy defect: ``_items_table`` recorded the span row *before* appending the
item row, so reportlab spanned a row that did not exist yet and the value row
``qty | unit price | line total`` collapsed to a single cell — the locale then
decided which field survived (RTL kept the line total, LTR kept the product
name).  The same table also kept reportlab's 6pt default cell padding, which
left the money column 28.8pt wide and split every amount mid-string.

These tests pin the normalized contract:

* one item = full-width name row (spanned) + one real 3-cell value row +
  optional full-width meta / discount rows (spanned) + one separator line;
* optional rows only ever add or remove their own row — the value row lands
  in the same three columns for every line and every locale;
* every field of every line reaches the PDF (``en`` / ``fr`` / ``ar``);
* money and quantity cells fit their columns at 8.5pt.
"""

from __future__ import annotations

import sys
from decimal import Decimal
from pathlib import Path

import pytest
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import Paragraph, Table

from app.printing.document_data import (
    DocumentData,
    HeaderBlock,
    LineItem,
    MetaBlock,
    StoreBlock,
    TotalsBlock,
    build_sale_document,
)
from app.printing.fonts import FONT_REGULAR, register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.templates import invoice_80mm
from app.printing.templates.invoice_a4 import build_flowables as a4_flowables
from app.printing.text import shape_text
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
AR_NAME = "\u0643\u0648\u0643\u0627 \u0643\u0648\u0644\u0627"  # Coca Cola
BARCODE = "6130000112233"


# ─── helpers ────────────────────────────────────────────────────────────────


def _line(**over) -> LineItem:
    data = dict(
        kind="product",
        name="Cola",
        unit_label="piece",
        qty="2",
        unit_price="100.00 DA",
        line_total="200.00 DA",
    )
    data.update(over)
    return LineItem(**data)


def _doc(lines: list[LineItem], *, locale: str = "en") -> DocumentData:
    return DocumentData(
        store=StoreBlock(name="Store Alpha"),
        header=HeaderBlock(
            document_number="INV-000123",
            document_title="Invoice",
            occurred_at="2026-01-05 10:30",
            status_label=None,
        ),
        customer=None,
        supplier=None,
        cashier_name="Admin",
        lines=lines,
        totals=TotalsBlock(subtotal="200.00 DA", total="200.00 DA"),
        meta=MetaBlock(locale=locale, generated_at="2026-01-05 10:30"),
    )


def _items(data: DocumentData) -> Table:
    table = invoice_80mm._items_table(data)
    assert table is not None, "the items table must exist for a non-empty document"
    return table


def _texts(table: Table, row: int) -> list[str]:
    """Cell text of one row, read BEFORE any wrap() (wrap rewrites the cells)."""
    return [
        cell.text if isinstance(cell, Paragraph) else str(cell)
        for cell in table._cellvalues[row]
    ]


def _span_rows(table: Table) -> list[int]:
    return sorted({cmd[1][1] for cmd in table._spanCmds})


def _separator_rows(table: Table) -> list[int]:
    return sorted({cmd[2][1] for cmd in table._linecmds if cmd[0] == "LINEBELOW"})


def _expected(data: DocumentData) -> tuple[list[int], list[int], list[int]]:
    """(spanned rows, value rows, separator rows) of the normalized layout."""
    spans: list[int] = []
    values: list[int] = []
    separators: list[int] = []
    row = 0
    for line in data.lines:
        spans.append(row)  # name row
        row += 1
        values.append(row)  # the only real 3-cell row
        row += 1
        if line.sku or line.barcode or line.base_qty:
            spans.append(row)
            row += 1
        if line.line_discount:
            spans.append(row)
            row += 1
        separators.append(row - 1)
    return spans, values, separators


def _blocks(raw: bytes) -> list[str]:
    """Drawn text blocks (content-stream order) via the G7 spike extractor."""
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


def _normalize(text: str) -> str:
    """Paragraph collapses runs of spaces, so compare on single spaces."""
    return " ".join(text.split())


def _bare(money: str) -> str:
    """Item-table amounts print without the currency suffix."""
    return money[: -len(" DA")] if money.endswith(" DA") else money


def _expected_item_blocks(data: DocumentData) -> list[str]:
    """Every string the redesigned receipt item table puts on the paper.

    The sale receipt is a four-column table (Désignation / Prix U / Qté /
    Montant): one row per line, bare amounts, and the optional meta and
    discount lines underneath.  Return/purchase 80mm documents still use
    the legacy name-row + value-row layout in ``invoice_80mm``.
    """
    locale = data.meta.locale
    out: list[str] = []
    for line in data.lines:
        name = f"- {line.name}" if line.kind == "pack_component" else line.name
        out.append(name)
        out.append(line.qty)
        if line.show_money:
            out.append(_bare(line.unit_price))
            out.append(_bare(line.line_total))
        if line.base_qty:
            out.append(f"{label('base', locale)}: {line.base_qty} {line.unit_label}")
        if line.line_discount:
            out.append(f"{label('discount', locale)}: {line.line_discount}")
    return out


def _varied_lines() -> list[LineItem]:
    """Three lines: SKU only, barcode only, base qty + discount."""
    return [
        _line(sku="SKU1"),
        _line(name="Eau", sku=None, barcode=BARCODE),
        _line(name="Lait", sku=None, barcode=None, base_qty="12", line_discount="10.00 DA"),
    ]


def _payload_lines() -> list:
    return [
        _sale_line(
            product_name="Cola",
            product_sku="MILK-001",
            unit_price=Decimal("160.000"),
            line_total=Decimal("320.000"),
        ),
        _sale_line(
            product_name=AR_NAME,
            product_sku=None,
            product_barcode=BARCODE,
            quantity=Decimal("1.5"),
            unit_price=Decimal("50.000"),
            line_total=Decimal("50.000"),
            line_discount=Decimal("10.000"),
        ),
        _sale_line(
            product_name="Milk",
            product_sku=None,
            product_barcode=None,
            selling_unit_name="Box",
            selling_unit_multiplier="24",
            quantity=Decimal("1"),
            unit_price=Decimal("75.000"),
            line_total=Decimal("950.000"),
        ),
    ]


# ─── 1. row structure ───────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_value_rows_are_three_real_cells_and_never_spanned(locale: str) -> None:
    data = _doc(_varied_lines(), locale=locale)
    table = _items(data)
    spans, values, _ = _expected(data)

    assert table._ncols == 3
    assert table._nrows == 10  # 3 + 3 + 4 rows for the three fixture lines
    assert _span_rows(table) == spans
    assert not set(values) & set(spans)
    for row in values:
        texts = _texts(table, row)
        assert len(texts) == 3
        assert all(texts), f"value row {row} must keep all three fields"


def test_name_row_spans_the_full_table_width() -> None:
    table = _items(_doc([_line()], locale="en"))
    assert table._spanCmds == [("SPAN", (0, 0), (-1, 0))]
    assert _texts(table, 0) == ["Cola", "", ""]
    assert _texts(table, 1) == ["2 × piece", "100.00 DA", "200.00 DA"]


def test_optional_rows_never_shift_the_value_columns() -> None:
    bare = _items(_doc([_line(sku=None, barcode=None, base_qty=None)], locale="en"))
    full = _items(_doc([_line(sku="SKU1", base_qty="12", line_discount="10.00 DA")], locale="en"))
    expected = ["2 × piece", "100.00 DA", "200.00 DA"]

    assert _texts(bare, 1) == expected
    assert _texts(full, 1) == expected
    assert bare._nrows == 2  # name + value only
    assert full._nrows == 4  # name + value + meta + discount


def test_separator_only_under_item_groups() -> None:
    data = _doc(_varied_lines(), locale="en")
    table = _items(data)
    spans, values, separators = _expected(data)
    name_rows = {0, 3, 6}

    assert separators == [2, 5, 9]  # last row of every group, once per line
    assert _separator_rows(table) == separators
    assert len(separators) == len(data.lines)
    assert separators == sorted(separators)
    # never drawn on the name row nor inside an item's own value row
    assert not name_rows & set(separators)
    assert not set(values) & set(separators)
    assert spans == [0, 2, 3, 5, 6, 8, 9]


# ─── 2. optional rows ───────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_meta_row_shows_localized_sku_label(locale: str) -> None:
    table = _items(_doc([_line(sku="ABC")], locale=locale))
    expected = shape_text(f"{label('col_sku', locale)}: ABC")
    assert table._nrows == 3
    assert _texts(table, 2) == [expected, "", ""]


def test_meta_row_falls_back_to_barcode_without_sku() -> None:
    table = _items(_doc([_line(sku=None, barcode=BARCODE)], locale="en"))
    assert table._nrows == 3
    assert _texts(table, 2)[0] == f"Barcode: {BARCODE}"


def test_sku_wins_over_barcode_when_both_are_present() -> None:
    table = _items(_doc([_line(sku="SKU1", barcode=BARCODE)], locale="en"))
    text = _texts(table, 2)[0]
    assert "SKU1" in text
    assert BARCODE not in text


def test_base_quantity_joins_the_meta_row() -> None:
    table = _items(_doc([_line(sku="SKU1", base_qty="24")], locale="en"))
    assert table._nrows == 3
    # Paragraph collapses the template's run of spaces to one (as printed).
    assert _texts(table, 2)[0] == "SKU: SKU1 Base: 24 piece"


def test_discount_row_only_when_the_line_is_discounted() -> None:
    plain = _items(_doc([_line()], locale="en"))
    cut = _items(_doc([_line(line_discount="10.00 DA")], locale="en"))
    assert plain._nrows == 2
    assert cut._nrows == 3
    assert _texts(cut, 2) == ["Discount: 10.00 DA", "", ""]


def test_pack_component_marker_keeps_the_three_columns() -> None:
    line = _line(
        kind="pack_component",
        name="Milk",
        show_money=False,
        sku=None,
        barcode=None,
        base_qty=None,
    )
    table = _items(_doc([line], locale="en"))
    assert table._nrows == 2
    assert _texts(table, 0) == ["└ Milk", "", ""]
    assert _texts(table, 1) == ["2 × piece", "", ""]
    assert _span_rows(table) == [0]


# ─── 3. geometry ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_value_cells_fit_their_columns_without_wrapping(locale: str) -> None:
    lines = [
        _line(qty="999.999", unit_price="999999.99 DA", line_total="999999.99 DA"),
        _line(
            name="Eau",
            qty="1.234",
            unit_label="milliliter",
            unit_price="1600.00 DA",
            line_total="1600.00 DA",
        ),
    ]
    data = _doc(lines, locale=locale)
    table = _items(data)
    _, values, _ = _expected(data)
    widths = invoice_80mm.COL_WIDTHS if not data.rtl else list(reversed(invoice_80mm.COL_WIDTHS))
    usable = [w - 2 * invoice_80mm.CELL_PAD for w in widths]

    for row in values:
        for col, text in enumerate(_texts(table, row)):
            width = stringWidth(shape_text(text), FONT_REGULAR, 8.5)
            assert width <= usable[col] + 0.01, f"{locale} {text!r} wraps in column {col}"


# ─── 4. grouped thousands vs the money column ──────────────────────────────
#
# `format_money` space-groups integer digits, which widens an amount by
# ~2pt per thousands group.  `1 000 000.00 DA` measured 65.4pt at the 8.5pt
# body size — past the 63.4pt usable money column — so a total that fit
# *ungrouped* (`1000000.00 DA`, 61.4pt) wrapped once grouping landed.  These
# tests drive the REAL formatting path (`build_sale_document` →
# `format_money` → the 80mm template) and pin that every money cell stays on
# one readable line for en/fr/ar.


def _grouped_large_sale():
    """A realistic wholesale-scale sale: one amount per grouping boundary."""
    return _sale_payload(
        subtotal=Decimal("14345678.89"),
        discount=Decimal("0.000"),
        total=Decimal("12345678.90"),
        paid=Decimal("12345678.90"),
        change=Decimal("0.000"),
        debt=Decimal("0.000"),
        lines=[
            _sale_line(
                product_name="Cola",
                unit_price=Decimal("999999.99"),
                quantity=Decimal("1"),
                line_total=Decimal("999999.99"),
            ),
            _sale_line(
                product_name="Water",
                unit_price=Decimal("1000000.00"),
                quantity=Decimal("1"),
                line_total=Decimal("1000000.00"),
            ),
            _sale_line(
                product_name="Milk",
                unit_price=Decimal("12345678.90"),
                quantity=Decimal("1"),
                line_total=Decimal("12345678.90"),
            ),
        ],
    )


def _assert_single_line_money_cell(cell: Paragraph, usable: float, where: str) -> None:
    """The cell's text, at its ACTUAL font size, fits [usable] on one line."""
    width = stringWidth(shape_text(cell.text), FONT_REGULAR, cell.style.fontSize)
    assert width <= usable + 0.01, (
        f"{where} {cell.text!r} wraps ({width:.2f} > {usable:.2f})"
    )
    assert cell.style.fontSize >= 7.0, (
        f"{where} {cell.text!r} shrunk below the readable 7pt floor"
    )


@pytest.mark.parametrize("locale", LOCALES)
def test_grouped_large_amounts_stay_on_one_line_in_the_items_table(locale: str) -> None:
    data = build_sale_document(_grouped_large_sale(), locale=locale)

    # The real path emitted space-grouped amounts (not hand-written fixtures).
    assert [line.line_total for line in data.lines] == [
        "999 999.99 DA",
        "1 000 000.00 DA",
        "12 345 678.90 DA",
    ]
    assert data.totals is not None
    assert data.totals.subtotal == "14 345 678.89 DA"
    assert data.totals.total == "12 345 678.90 DA"
    assert data.totals.paid == "12 345 678.90 DA"

    table = _items(data)
    widths = invoice_80mm.COL_WIDTHS if not data.rtl else list(reversed(invoice_80mm.COL_WIDTHS))
    usable = [w - 2 * invoice_80mm.CELL_PAD for w in widths]
    # RTL reverses the row AND the column widths: the two money cells still
    # live in the 33% columns, just at different indices.
    money_cols = (0, 1) if data.rtl else (1, 2)

    _, values, _ = _expected(data)
    for row in values:
        cells = table._cellvalues[row]
        texts = _texts(table, row)
        # The value row never collapses and never drops a field.
        assert len(texts) == 3 and all(texts), f"{locale} row {row}: {texts}"
        for col in money_cols:
            cell = cells[col]
            assert isinstance(cell, Paragraph)
            _assert_single_line_money_cell(cell, usable[col], f"{locale} r{row}c{col}")


@pytest.mark.parametrize("locale", LOCALES)
def test_grouped_large_totals_stay_on_one_line_in_the_totals_block(locale: str) -> None:
    data = build_sale_document(_grouped_large_sale(), locale=locale)
    totals = invoice_80mm._totals_table(data)
    assert totals is not None

    col_widths = [
        invoice_80mm.CONTENT_WIDTH * 0.62,
        invoice_80mm.CONTENT_WIDTH * 0.38,
    ]
    wanted = {"14 345 678.89 DA", "12 345 678.90 DA"}
    seen: set[str] = set()
    for row_index, row in enumerate(totals._cellvalues):
        for col, cell in enumerate(row):
            if not isinstance(cell, Paragraph) or cell.text not in wanted:
                continue
            seen.add(cell.text)
            # Reportlab default 6pt padding per side (only TOP/BOTTOM are overridden).
            _assert_single_line_money_cell(
                cell, col_widths[col] - 12.0, f"{locale} totals r{row_index}c{col}"
            )
    assert seen == wanted


@pytest.mark.parametrize("locale", LOCALES)
def test_rendered_receipt_with_grouped_large_amounts_is_a_valid_pdf(locale: str) -> None:
    """End-to-end: real payload → format_money → 80mm canvas, no crash."""
    data = build_sale_document(_grouped_large_sale(), locale=locale)
    pdf = render_invoice(data, "80mm", compress=False)
    assert pdf.startswith(b"%PDF")
    assert len(pdf) > 1000


def test_rtl_and_ltr_share_the_same_row_structure() -> None:
    lines = _varied_lines()
    ltr = _items(_doc(lines, locale="en"))
    rtl = _items(_doc(lines, locale="ar"))

    assert ltr._nrows == rtl._nrows
    assert _span_rows(ltr) == _span_rows(rtl)
    assert _separator_rows(ltr) == _separator_rows(rtl)

    _, values, _ = _expected(_doc(lines, locale="en"))
    for row in values:
        assert _texts(rtl, row) == _texts(ltr, row)[::-1]


def test_a4_meta_rows_span_themselves_and_never_the_item_rows() -> None:
    """Same defect class as the 80mm bug, on the A4 template.

    ``_span_targets`` used to add a cumulative offset on top of data-row
    indices that already included the meta rows appended before them, so from
    the second base-quantity line on the span pointed at an *item* row (and
    eventually past the table) — collapsing that item row to a single cell.
    """
    payload = _sale_payload(
        lines=[
            _sale_line(product_name="A", selling_unit_name="Box", selling_unit_multiplier="10"),
            _sale_line(product_name="B", selling_unit_name="Box", selling_unit_multiplier="12"),
            _sale_line(product_name="C", selling_unit_name="Case", selling_unit_multiplier="6"),
        ]
    )
    data = build_sale_document(payload, locale="en")
    table = next(
        f
        for f in a4_flowables(data)
        # 7 cells: a customer invoice has no SKU column (§15.7 A1)
        if isinstance(f, Table) and len(f._cellvalues[0]) == 7
    )

    def is_paragraph_row(row: list) -> bool:
        return all(isinstance(cell, Paragraph) for cell in row)

    full_rows = [index for index, row in enumerate(table._cellvalues) if is_paragraph_row(row)]
    meta_rows = [index for index, row in enumerate(table._cellvalues) if not is_paragraph_row(row)]

    assert full_rows == [0, 1, 3, 5]  # header + the three item rows
    assert meta_rows == [2, 4, 6]
    assert _span_rows(table) == meta_rows  # spans only the meta rows
    assert not set(_span_rows(table)) & set(full_rows)
    assert table._nrows == 7
    assert all(_texts(table, row)[1] for row in (1, 3, 5))  # product name kept
    assert table._cellvalues[2][0].text.startswith("Base:")


# ─── 4. rendered PDF ────────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_rendered_pdf_shows_every_field_for_every_line(locale: str) -> None:
    data = build_sale_document(_sale_payload(lines=_payload_lines()), locale=locale)
    drawn = {_normalize(block) for block in _blocks(render_invoice(data, "80mm"))}

    assert len(data.lines) == 3
    for expected in _expected_item_blocks(data):
        assert _normalize(shape_text(expected)) in drawn, f"{locale}: missing {expected!r}"


@pytest.mark.parametrize("locale", LOCALES)
def test_rendered_pdf_keeps_the_four_column_order(locale: str) -> None:
    """Désignation → Prix U → Qté → Montant, mirrored for Arabic."""
    data = build_sale_document(_sale_payload(lines=[_payload_lines()[0]]), locale=locale)
    blocks = _blocks(render_invoice(data, "80mm"))
    item = data.lines[0]

    assert shape_text("Cola") in blocks
    index = blocks.index(shape_text("Cola"))
    name, price, qty, total = (
        shape_text("Cola"),
        _bare(item.unit_price),
        item.qty,
        _bare(item.line_total),
    )
    if locale == "ar":
        # RTL draws the mirrored row first, the designation cell last
        assert blocks[index - 3 : index] == [total, qty, price]
    else:
        assert blocks[index + 1 : index + 4] == [price, qty, total]
    assert blocks.count(name) == 1

    # §15.7 A1/A2 — the line's identifiers never reach the customer paper.
    drawn = " | ".join(blocks)
    assert "MILK-001" not in drawn
    assert BARCODE not in drawn
    assert f"{label('col_sku', locale)}:" not in drawn
    assert f"{label('barcode', locale)}:" not in drawn


def test_arabic_product_name_is_shaped_exactly_once() -> None:
    payload = _sale_payload(
        lines=[_sale_line(product_name=AR_NAME, product_sku=None, product_barcode=BARCODE)]
    )
    once = shape_text(AR_NAME)
    twice = shape_text(once)
    assert twice != once, "the fixture must be non-idempotent for this to prove anything"

    for locale in LOCALES:
        blocks = _blocks(render_invoice(build_sale_document(payload, locale=locale), "80mm"))
        assert once in blocks, locale
        assert twice not in blocks, f"{locale}: the product name was shaped twice"


def test_normalization_is_locale_and_add_path_independent() -> None:
    """Catalog add and barcode add differ only in which identifier is set.

    Both shapes must normalize to the same three-column value row and the
    same ``LineItem`` snapshot whatever the document locale is — no field of
    the item depends on how the line got into the cart.
    """
    payload = _sale_payload(
        lines=[
            _sale_line(product_name="Cola", product_sku="SKU1"),
            _sale_line(product_name="Eau", product_sku=None, product_barcode=BARCODE),
        ]
    )

    def snapshot(data: DocumentData) -> list[tuple]:
        return [
            (
                item.kind,
                item.name,
                item.qty,
                item.unit_label,
                item.unit_price,
                item.line_total,
                item.sku,
                item.barcode,
                item.base_qty,
                item.line_discount,
                item.show_money,
            )
            for item in data.lines
        ]

    en_doc = build_sale_document(payload, locale="en")
    baseline = snapshot(en_doc)
    for locale in LOCALES:
        assert snapshot(build_sale_document(payload, locale=locale)) == baseline

    # §15.7 A1/A2 — identifiers are stripped from the customer document for
    # EVERY locale, so the two add paths cannot produce different rows.
    assert all(item.sku is None and item.barcode is None for item in en_doc.lines)

    table = _items(en_doc)
    assert table._nrows == 4  # (name + value) for each of the two lines
    assert _texts(table, 1) == _texts(table, 3) == ["2 × piece", "100.00 DA", "200.00 DA"]


# ─── 5. page budget ─────────────────────────────────────────────────────────


def test_estimate_height_budgets_optional_item_rows() -> None:
    def height(lines: list[LineItem]) -> float:
        return invoice_80mm.estimate_height(_doc(lines))

    bare = [_line(sku=None, barcode=None, base_qty=None) for _ in range(10)]
    with_meta = [_line(sku="SKU1") for _ in range(10)]
    with_discount = [
        _line(sku=None, barcode=None, base_qty=None, line_discount="5.00 DA")
        for _ in range(10)
    ]

    # 10 lines already clear the 140mm floor, so the deltas are the real budgets.
    assert height(bare) > 140 * mm
    assert height(with_meta) - height(bare) == pytest.approx(10 * 4.4 * mm)
    assert height(with_discount) - height(bare) == pytest.approx(10 * 4.4 * mm)


def test_estimate_height_keeps_the_140mm_floor_for_an_empty_items_table() -> None:
    assert invoice_80mm.estimate_height(_doc([])) == pytest.approx(140 * mm)
