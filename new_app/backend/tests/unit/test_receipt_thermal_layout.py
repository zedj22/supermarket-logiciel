"""80mm thermal receipt redesign — layout, money, payments and barcode.

Pins the customer SALE receipt contract introduced by the redesign:

* four aligned columns (Désignation / Prix U / Qté / Montant), bold
  headings, thin separators, mirrored for Arabic;
* one compact row per sale line, with packs and their components, selling
  units, fractional quantities and long names;
* an items summary (distinct articles, total pieces) and the sale's own
  gross subtotal — never re-derived from rounded display text;
* ONE combined discount amount (line + invoice), once;
* the cashier who took the money;
* a payment box showing the sale's real received / total / change, with no
  cash change on a non-cash sale;
* a closing message that comes from Settings (`invoice_footer`) when one is
  configured, and the built-in default block otherwise — no barcode and no
  invoice reference in the footer;
* one separator after the last item row, never one per product;
* 80mm page geometry, and A4 / internal documents left byte-identical.
"""

from __future__ import annotations

import re
import sys
import uuid
from decimal import Decimal
from pathlib import Path

import pytest
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from reportlab.lib.units import mm
from reportlab.platypus import Paragraph, Table

from app.printing.document_data import (
    DocumentData,
    build_return_document,
    build_sale_document,
)
from app.printing.fonts import FONT_REGULAR, register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.templates import invoice_80mm, receipt_80mm
from app.printing.templates.invoice_a4 import build_flowables as a4_flowables
from app.printing.text import format_money, format_qty, shape_text
from app.schemas.returns import ReturnLineResponse, ReturnResponse
from app.schemas.sale import SalePaymentResponse
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
D = Decimal
LONG_NAME = "Chocolat noir extra fin 70% cacao origine Côte d'Ivoire 200 g"


# ─── helpers ────────────────────────────────────────────────────────────────


def _blocks(raw: bytes) -> list[str]:
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


def _normalize(text: str) -> str:
    return " ".join(text.split())


def _drawn(data: DocumentData, paper: str = "80mm") -> str:
    return " | ".join(_normalize(block) for block in _blocks(render_invoice(data, paper)))


def _bare(money: str) -> str:
    return money[: -len(" DA")] if money.endswith(" DA") else money


def _texts(table: Table, row: int) -> list[str]:
    return [
        cell.text if isinstance(cell, Paragraph) else str(cell)
        for cell in table._cellvalues[row]
    ]


def _tables(story: list) -> list[Table]:  # noqa: ANN001 - flowable story
    return [f for f in story if isinstance(f, Table)]


def _items(data: DocumentData) -> Table:
    table = receipt_80mm._items_table(data)
    assert table is not None
    return table


def _sale(**over):
    defaults = dict(
        invoice_number="INV-2026-000123",
        cashier_name="Amina",
        lines=[_sale_line(product_name="Cola", quantity=D("2"), line_total=D("320.000"))],
    )
    defaults.update(over)
    return _sale_payload(**defaults)


def _doc(locale: str = "en", **over) -> DocumentData:
    return build_sale_document(_sale(**over), locale=locale)


def _page_count(raw: bytes) -> int:
    return len(re.findall(rb"/Type\s*/Page[^s]", raw))


def _media_box(raw: bytes) -> tuple[float, float]:
    box = raw.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(box[2]), float(box[3])


# ─── 1. the four columns ────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_items_table_has_the_four_reference_columns(locale: str) -> None:
    data = _doc(locale)
    table = _items(data)
    rtl = locale == "ar"

    assert table._ncols == 4
    expected = [
        shape_text(label("col_description", locale)),
        shape_text(label("col_price_unit", locale)),
        shape_text(label("col_qty", locale)),
        shape_text(label("col_amount", locale)),
    ]
    assert _texts(table, 0) == (list(reversed(expected)) if rtl else expected)
    # bold headings over a thin rule
    assert all(cell.style.fontSize == receipt_80mm.HEADING for cell in table._cellvalues[0])
    assert all(cell.style.fontName.lower().endswith("bold") for cell in table._cellvalues[0])
    rules = [cmd[:5] for cmd in table._linecmds if cmd[0] == "LINEBELOW"]
    assert ("LINEBELOW", (0, 0), (-1, 0), receipt_80mm.HEADER_RULE, "black") in rules


@pytest.mark.parametrize("locale", LOCALES)
def test_numeric_cells_align_right_and_the_name_aligns_to_the_reading_edge(
    locale: str,
) -> None:
    data = _doc(locale)
    row = _texts(_items(data), 1)
    cells = _items(data)._cellvalues[1]
    rtl = locale == "ar"

    # logical order after the (possibly mirrored) row
    name_index = 3 if rtl else 0
    value_indexes = (0, 1, 2) if rtl else (1, 2, 3)
    assert row[name_index] == shape_text("Cola")
    assert cells[name_index].style.alignment == (TA_RIGHT if rtl else TA_LEFT)
    for index in value_indexes:
        assert cells[index].style.alignment == (TA_LEFT if rtl else TA_RIGHT)


def test_item_row_prints_price_quantity_and_amount_without_currency_noise() -> None:
    data = _doc(
        "fr",
        lines=[_sale_line(product_name="Cola", quantity=D("2"), line_total=D("320.000"))],
    )
    row = _texts(_items(data), 1)
    assert row == ["Cola", "100.00", "2", "320.00"]


# ─── 2. content shapes ──────────────────────────────────────────────────────


def test_long_product_name_stays_inside_the_designation_column() -> None:
    data = _doc("fr", lines=[_sale_line(product_name=LONG_NAME)])
    table = _items(data)
    name_cell = table._cellvalues[1][0]
    width, _height = name_cell.wrap(receipt_80mm.COL_DESIGNATION - 2 * receipt_80mm.PAD, 400)
    assert width <= receipt_80mm.COL_DESIGNATION - 2 * receipt_80mm.PAD + 0.01
    # the other three columns are untouched by the wrap
    assert _texts(table, 1)[1:] == ["100.00", "2", "200.00"]
    assert table._argW[0] == pytest.approx(receipt_80mm.COL_DESIGNATION)


def test_multiple_products_get_one_row_each_and_a_single_closing_separator() -> None:
    data = _doc(
        "en",
        lines=[
            _sale_line(product_name="Cola", line_total=D("200.000")),
            _sale_line(product_name="Eau", line_total=D("150.000")),
            _sale_line(product_name="Lait", line_total=D("250.000")),
        ],
    )
    table = _items(data)
    assert table._nrows == 1 + 3
    assert [row[0] for row in (_texts(table, i) for i in (1, 2, 3))] == [
        "Cola",
        "Eau",
        "Lait",
    ]
    separators = [cmd for cmd in table._linecmds if cmd[0] == "LINEBELOW"][1:]
    # One rule after the LAST row only; products run continuously.
    assert len(separators) == 1
    assert separators[0][1] == (0, 3)
    first = [cmd for cmd in table._linecmds if cmd[0] == "LINEBELOW"][0]
    assert first[1] == (0, 0), "the heading keeps its own separator"


def test_pack_lines_keep_the_pack_name_and_its_components() -> None:
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
            _sale_line(pack_id=pack_id, product_name="Lait 1L", quantity=D("2"), line_total=D("0.000")),
        ],
    )
    table = _items(data)
    assert data.lines[0].kind == "pack_summary"
    assert data.lines[1].kind == "pack_component"
    assert label("pack_marker", "fr") in data.lines[0].name
    assert _texts(table, 1)[0].endswith(label("pack_marker", "fr"))
    # "pack" is not a piece word, so it gets its own unit line
    assert _texts(table, 2)[0] == "pack"
    # the component is marked and carries no money of its own
    assert _texts(table, 3)[0] == "- Lait 1L"
    assert _texts(table, 3)[1:] == ["", "2", ""]
    drawn = _drawn(data)
    assert "Pack Rentr" in drawn and "- Lait 1L" in drawn


def test_fractional_quantity_and_selling_unit_are_printed() -> None:
    data = _doc(
        "fr",
        lines=[
            _sale_line(
                product_name="Farine",
                selling_unit_name="Carton",
                selling_unit_multiplier=D("6"),
                quantity=D("1.5"),
                line_total=D("450.000"),
            )
        ],
    )
    line = data.lines[0]
    assert line.qty == format_qty(D("1.5"))
    assert line.base_qty == format_qty(D("9"))
    table = _items(data)
    assert _texts(table, 1)[2] == line.qty
    assert _texts(table, 2)[0] == f"{label('base', 'fr')}: 9 Carton"


# ─── 3. summary, discount, totals ───────────────────────────────────────────


def test_pack_components_count_as_physical_pieces_not_as_one_pack() -> None:
    pack_id = uuid.uuid4()
    data = _doc(
        "fr",
        lines=[
            _sale_line(product_name="asa", quantity=D("1"), line_total=D("100.000")),
            _sale_line(product_name="dek", quantity=D("1"), line_total=D("200.000")),
            _sale_line(
                product_id=None,
                pack_id=pack_id,
                product_name="Pack Famille",
                product_unit="pack",
                quantity=D("1"),
                unit_price=D("400.000"),
                line_total=D("400.000"),
            ),
            *[
                _sale_line(
                    pack_id=pack_id,
                    product_name=f"Composant {i}",
                    quantity=D("1"),
                    line_total=D("0.000"),
                )
                for i in range(4)
            ],
        ],
    )
    summary = data.receipt
    assert summary is not None
    assert summary.article_count == 3  # asa + dek + the pack itself
    assert summary.total_qty == "6"  # 1 + 1 + four pack components
    drawn = _drawn(data)
    assert f"3 {label('receipt_articles', 'fr')}" in drawn
    assert f"6 {label('receipt_units_pcs', 'fr')}" in drawn


def test_multiple_packs_and_component_quantities_are_counted_exactly() -> None:
    pack_id = uuid.uuid4()
    other_pack_id = uuid.uuid4()
    data = _doc(
        "en",
        lines=[
            _sale_line(
                product_id=None,
                pack_id=pack_id,
                product_name="Pack A",
                product_unit="pack",
                quantity=D("2"),
                unit_price=D("300.000"),
                line_total=D("600.000"),
            ),
            _sale_line(pack_id=pack_id, product_name="A1", quantity=D("4"), line_total=D("0")),
            _sale_line(pack_id=pack_id, product_name="A2", quantity=D("2"), line_total=D("0")),
            _sale_line(
                product_id=None,
                pack_id=other_pack_id,
                product_name="Pack B",
                product_unit="pack",
                quantity=D("1"),
                unit_price=D("150.000"),
                line_total=D("150.000"),
            ),
            _sale_line(pack_id=other_pack_id, product_name="B1", quantity=D("3"), line_total=D("0")),
            _sale_line(product_name="Loose", quantity=D("2"), line_total=D("50.000")),
            _sale_line(
                product_name="Flour",
                selling_unit_name="Carton",
                selling_unit_multiplier=D("6"),
                quantity=D("1.5"),
                line_total=D("90.000"),
            ),
        ],
    )
    summary = data.receipt
    assert summary is not None
    # 4 + 2 + 3 component pieces + 2 loose + (1.5 × 6) = 20
    assert summary.total_qty == "20"


def test_summary_counts_distinct_articles_and_pieces() -> None:
    data = _doc(
        "fr",
        lines=[
            _sale_line(product_name="Cola", quantity=D("2"), line_total=D("320.000")),
            _sale_line(product_name="Eau", quantity=D("1.5"), line_total=D("60.000")),
            _sale_line(product_name="Farine", quantity=D("1"), line_total=D("450.000")),
        ],
    )
    summary = data.receipt
    assert summary is not None
    assert summary.article_count == 3
    assert summary.total_qty == format_qty(D("4.5"))
    drawn = _drawn(data)
    assert f"3 {label('receipt_articles', 'fr')}" in drawn
    assert f"4.5 {label('receipt_units_pcs', 'fr')}" in drawn


def test_line_and_invoice_discounts_are_added_exactly_once() -> None:
    data = _doc(
        "fr",
        subtotal=D("500.000"),
        discount=D("20.000"),
        total=D("470.000"),
        paid=D("470.000"),
        change=D("0.000"),
        lines=[_sale_line(line_discount=D("10.000"), line_total=D("490.000"))],
    )
    assert data.receipt is not None
    # Σ line discounts (10) + invoice discount (20), formatted once
    assert data.receipt.total_discount == format_money(D("30.000"))
    assert data.totals is not None and data.totals.subtotal == format_money(D("500.000"))
    drawn = _drawn(data)
    assert f"{label('discount', 'fr')} :" in drawn
    assert "30.00 DA" in drawn


def test_gross_subtotal_and_final_payable_total_are_both_real() -> None:
    data = _doc(
        "en",
        subtotal=D("1070.000"),
        discount=D("180.000"),
        total=D("890.000"),
        paid=D("2000.000"),
        change=D("1110.000"),
        lines=[_sale_line(line_discount=D("0.000"), line_total=D("1070.000"))],
    )
    assert data.receipt is not None
    assert data.receipt.total_discount == format_money(D("180.000"))
    drawn = _drawn(data)
    assert format_money(D("1070.000")) in drawn  # gross subtotal
    assert format_money(D("890.000")) in drawn  # amount payable
    assert data.totals is not None
    assert data.totals.total == format_money(D("890.000"))


# ─── 4. cashier ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_cashier_of_the_sale_is_named(locale: str) -> None:
    data = _doc(locale, cashier_name="Amina")
    assert data.receipt is not None and data.receipt.cashier == "Amina"
    assert _normalize(
        shape_text(f"{label('receipt_cashier_by', locale)} : Amina")
    ) in _drawn(data)


# ─── 5. payment box ─────────────────────────────────────────────────────────


def _payment_rows(data: DocumentData) -> list[list[str]]:
    box = [t for t in _tables(receipt_80mm.build_flowables(data)) if len(t._cellvalues) >= 2][-1]
    return [[cell.text for cell in row] for row in box._cellvalues]


def test_cash_tender_over_the_total_prints_received_total_and_change() -> None:
    # 7 000 tendered against a 6 500 payable → Reçu / Total / Rendu.
    data = _doc(
        "fr",
        total=D("6500.000"),
        paid=D("7000.000"),
        change=D("500.000"),
        payments=[
            SalePaymentResponse(id=uuid.uuid4(), method="cash", amount=D("7000.000"))
        ],
    )
    rows = _payment_rows(data)
    assert rows[0][1] == format_money(D("7000.000"))
    assert rows[1][1] == format_money(D("6500.000"))
    assert rows[2][1] == format_money(D("500.000"))


def test_cash_sale_shows_received_total_and_change() -> None:
    data = _doc(
        "fr",
        paid=D("2000.000"),
        change=D("865.000"),
        total=D("1135.000"),
        payments=[
            SalePaymentResponse(id=uuid.uuid4(), method="cash", amount=D("2000.000"))
        ],
    )
    rows = _payment_rows(data)
    assert [row[0] for row in rows] == [
        label("receipt_received", "fr"),
        label("total", "fr"),
        label("change", "fr"),
    ]
    assert rows[0][1] == format_money(D("2000.000"))
    assert rows[1][1] == format_money(D("1135.000"))
    assert rows[2][1] == format_money(D("865.000"))


def test_card_sale_never_prints_cash_change() -> None:
    data = _doc(
        "fr",
        payment_method="card",
        payments=[
            SalePaymentResponse(id=uuid.uuid4(), method="card", amount=D("1135.000"))
        ],
        paid=D("1135.000"),
        change=D("0.000"),
        total=D("1135.000"),
    )
    assert data.receipt is not None and data.receipt.cash_payment is False
    rows = _payment_rows(data)
    assert [row[0] for row in rows] == [
        label("receipt_received", "fr"),
        label("total", "fr"),
    ]
    assert label("change", "fr") not in _drawn(data)


def test_mixed_payment_keeps_every_method_and_the_cash_change() -> None:
    data = _doc(
        "fr",
        payment_method="partial",
        payments=[
            SalePaymentResponse(id=uuid.uuid4(), method="cash", amount=D("600.000")),
            SalePaymentResponse(id=uuid.uuid4(), method="card", amount=D("300.000")),
        ],
        paid=D("900.000"),
        change=D("10.000"),
        total=D("890.000"),
    )
    assert data.receipt is not None and data.receipt.cash_payment is True
    assert [p.method_label for p in data.payments] == [
        label("label_cash", "fr"),
        label("label_card", "fr"),
    ]
    rows = _payment_rows(data)
    assert rows[-1] == [label("change", "fr"), format_money(D("10.000"))]


# ─── 6. footer + barcode ────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_default_footer_is_printed_when_no_message_is_configured(locale: str) -> None:
    data = _doc(locale)
    assert data.store.footer is None
    drawn = _drawn(data)
    for key in ("receipt_thanks_ar", "receipt_thanks_fr", "receipt_keep_ticket"):
        assert _normalize(shape_text(label(key, locale))) in drawn, key


def test_configured_settings_footer_replaces_the_hardcoded_thanks() -> None:
    data = _doc("fr")
    data.store.footer = "Merci et à bientôt !"
    drawn = _drawn(data)
    assert "Merci et à bientôt !" in drawn
    # The hardcoded thank-you wording is NOT printed alongside it.
    assert _normalize(shape_text(label("receipt_thanks_fr", "fr"))) not in drawn
    assert _normalize(shape_text(label("receipt_thanks_ar", "fr"))) not in drawn
    # The legal retention notice is not a thank-you message — it stays.
    assert _normalize(shape_text(label("receipt_keep_ticket", "fr"))) in drawn
    # …and the configured text is printed exactly once (no duplicate at the end).
    assert _normalize(drawn).count("Merci et à bientôt !") == 1


def test_configured_arabic_footer_is_shaped_correctly() -> None:
    data = _doc("ar")
    data.store.footer = "شكرًا لزيارتكم"
    drawn = _drawn(data)
    assert shape_text("شكرًا لزيارتكم") in drawn
    assert _normalize(shape_text(label("receipt_thanks_fr", "ar"))) not in drawn


def test_receipt_footer_has_no_barcode_or_invoice_reference() -> None:
    data = _doc("fr")
    reference = data.header.document_number
    story = receipt_80mm.build_flowables(data)
    assert not any(type(f).__module__.startswith("reportlab.graphics.barcode") for f in story)
    drawn = _drawn(data)
    assert reference not in drawn, "the invoice reference belongs to no footer on this receipt"


# ─── 7. geometry + neighbours untouched ─────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_receipt_is_one_80mm_page(locale: str) -> None:
    raw = render_invoice(_doc(locale), "80mm")
    width, height = _media_box(raw)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)
    assert 140 * mm <= height <= 400 * mm
    assert _page_count(raw) == 1


def test_a4_output_is_byte_identical_with_or_without_the_receipt_block() -> None:
    data = _doc("fr")
    without = DocumentData(
        store=data.store,
        header=data.header,
        customer=data.customer,
        supplier=data.supplier,
        cashier_name=data.cashier_name,
        lines=data.lines,
        totals=data.totals,
        payments=data.payments,
        meta=data.meta,
        customer_facing=data.customer_facing,
    )
    assert without.receipt is None
    with_block = render_invoice(data, "A4")
    without_block = render_invoice(without, "A4")
    # The bytes carry a render timestamp, so compare the drawn document.
    assert _blocks(with_block) == _blocks(without_block)
    assert _media_box(with_block) == _media_box(without_block)

    story = a4_flowables(data)
    texts = " | ".join(
        cell.text
        for table in _tables(story)
        for row in table._cellvalues
        for cell in row
        if isinstance(cell, Paragraph)
    )
    assert label("receipt_cashier_by", "fr") not in texts
    assert not any(
        type(item).__module__.startswith("reportlab.graphics.barcode")
        for item in story
    )


def test_internal_return_receipt_keeps_the_legacy_layout() -> None:
    ret = ReturnResponse(
        id=uuid.uuid4(),
        return_number="RET-0001",
        sale_id=uuid.uuid4(),
        invoice_number="INV-000123",
        customer_id=None,
        user_id=uuid.uuid4(),
        reason="damaged",
        subtotal=D("100.000"),
        discount=D("0.000"),
        total=D("100.000"),
        device_id="POS-1",
        return_date=__import__("datetime").datetime(2026, 1, 7, 9, 0),
        lines=[
            ReturnLineResponse(
                id=uuid.uuid4(),
                product_id=uuid.uuid4(),
                product_name="Cola",
                product_sku="SKU9",
                product_unit="piece",
                unit_price=D("100.000"),
                unit_cost=D("60.000"),
                quantity=D("1"),
                line_discount=D("0.000"),
                line_total=D("100.000"),
            )
        ],
    )
    data = build_return_document(ret, locale="fr")
    assert data.receipt is None
    drawn = _drawn(data)
    # legacy name-row + `qty × unit` value row, no barcode reference block
    assert "1 × piece" in drawn
    assert data.header.source_invoice is not None
    assert data.header.source_invoice in drawn
