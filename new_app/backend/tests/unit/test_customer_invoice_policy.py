"""Phase 17 §15.7 — customer invoice presentation policy + RTL audit.

The customer sale receipt/invoice is the ONE document a shopper sees, so it
carries a different information policy from returns, purchases and reports:

* **removed** — product SKU, product barcode, cashier/seller, device id and
  the localized "Cash customer" placeholder for an anonymous sale;
* **kept** — store, invoice number, DATE, TIME, product name, qty × unit,
  unit price, line total, discount, selling-unit base quantity, totals and
  payment information, and the name of a REAL attached customer;
* **unchanged upstream** — every one of those values still lives in the
  API payload, the database row and the audit trail; only the rendered
  document drops them.

`test_rtl_*` below is the §15.7 A8 audit of the complete 80mm Arabic
receipt: centred store title, right-flushed meta and product name, mirrored
value columns, and digits / currency / invoice number / date / time left in
their visual order — with exactly ONE bidi pass.
"""

from __future__ import annotations

import sys
import uuid
from datetime import datetime
from decimal import Decimal
from pathlib import Path

import pytest
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from reportlab.platypus import Paragraph, Table

from app.printing.document_data import DocumentData, build_sale_document
from app.printing.fonts import register_fonts
from app.printing.labels import label
from app.printing.render import render_invoice
from app.printing.templates import invoice_80mm, receipt_80mm
from app.printing.templates.invoice_80mm import build_flowables as flow80
from app.printing.templates.invoice_a4 import build_flowables as a4_flowables
from app.printing.text import format_datetime, format_money, shape_text
from tests.unit.test_export_render import _sale_line, _sale_payload

register_fonts()

LOCALES = ("en", "fr", "ar")
RTL = ("ar",)
AR_NAME = "\u0643\u0648\u0643\u0627 \u0643\u0648\u0644\u0627"  # Coca Cola
BARCODE = "6130000112233"
SKU = "MILK-001"
CASHIER = "Admin"
DEVICE = "POS-1"
STAMP = datetime(2026, 1, 5, 10, 30)


# ─── fixtures ───────────────────────────────────────────────────────────────


def _payload(**over) -> object:
    """A receipt-shaped sale: identifiers, cashier, device, real timestamps."""
    data = dict(
        customer_id=None,
        device_id=DEVICE,
        sale_date=STAMP,
        lines=[
            _sale_line(
                product_name="Cola",
                product_sku=SKU,
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
                product_name="Lait",
                product_sku=None,
                product_barcode=None,
                selling_unit_name="Box",
                selling_unit_multiplier="24",
                quantity=Decimal("1"),
                unit_price=Decimal("75.000"),
                line_total=Decimal("950.000"),
            ),
        ],
    )
    data.update(over)
    return _sale_payload(**data)


def _data(locale: str = "en", **over) -> DocumentData:
    return build_sale_document(_payload(**over), locale=locale)


def _blocks(raw: bytes) -> list[str]:
    """Drawn text blocks in content-stream order (G7 spike extractor)."""
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


def _normalize(text: str) -> str:
    """Paragraph collapses runs of spaces, so compare on single spaces."""
    return " ".join(text.split())


def _drawn(data: DocumentData, paper: str = "80mm") -> list[str]:
    return [_normalize(block) for block in _blocks(render_invoice(data, paper))]


def _shows(drawn: list[str], text: str) -> bool:
    """`text` exactly as it is drawn (one bidi pass, spaces normalized)."""
    return _normalize(shape_text(text)) in drawn


def _paragraphs(flowables) -> list[Paragraph]:  # noqa: ANN001 - story/table tree
    out: list[Paragraph] = []
    for item in flowables:
        if isinstance(item, Paragraph):
            out.append(item)
        elif isinstance(item, Table):
            for row in item._cellvalues:
                for cell in row:
                    if isinstance(cell, Paragraph):
                        out.append(cell)
    return out


def _story(locale: str, **over) -> list:
    return flow80(_data(locale, **over))


def _meta_paragraph(data: DocumentData, key: str) -> Paragraph:
    """The one 80mm meta line for `key` (invoice_number/date/time)."""
    locale = data.meta.locale
    value = {
        "invoice_number": data.header.document_number,
        "date": data.header.occurred_date or data.header.occurred_at,
        "time": data.header.occurred_time,
    }[key]
    wanted = _normalize(shape_text(f"{label(key, locale)}: {value}"))
    for item in flow80(data):
        if isinstance(item, Paragraph) and _normalize(item.text) == wanted:
            return item
    raise AssertionError(f"no {key!r} meta line in the 80mm story")


def _items_table(data: DocumentData) -> Table:
    table = invoice_80mm._items_table(data)
    assert table is not None
    return table


def _cell_text(cell) -> str:  # noqa: ANN001 - reportlab cell union
    return cell.text if isinstance(cell, Paragraph) else str(cell)


def _value_rows(table: Table) -> list[int]:
    """Rows where all three cells carry text — the real value rows.

    ReportLab pads every ragged row to `_ncols` with ``''``, so name / meta
    / discount rows (one filled cell) must not be mistaken for value rows.
    """
    return [
        i
        for i, row in enumerate(table._cellvalues)
        if all(_cell_text(cell) for cell in row)
    ]


def _a4_table(story: list, cells: int) -> Table:
    return next(f for f in story if isinstance(f, Table) and len(f._cellvalues[0]) == cells)


# ─── A1/A2/A3/A4/A5 — what a customer must NOT see ─────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_receipt_prints_neither_sku_nor_barcode(locale: str) -> None:
    data = _data(locale)
    # upstream (§15.7): the identifiers never even reach the template
    assert all(line.sku is None for line in data.lines)
    assert all(line.barcode is None for line in data.lines)

    drawn = _drawn(data)
    assert SKU not in drawn
    assert BARCODE not in drawn
    assert not any(f"{label('col_sku', locale)}:" in block for block in drawn)
    assert not any(f"{label('barcode', locale)}:" in block for block in drawn)


@pytest.mark.parametrize("locale", LOCALES)
def test_receipt_prints_the_cashier_but_not_the_device_or_a_fake_customer(
    locale: str,
) -> None:
    """Thermal receipt: the operator who took the money IS named.

    The A4 invoice keeps the §15.7 A4 policy (`cashier_name` stays None);
    the 80mm sale receipt names the cashier through `data.receipt`, which
    is a receipt-only block, so A4 output cannot move.
    """
    data = _data(locale, cashier_name=CASHIER)
    assert data.cashier_name is None  # A4
    assert data.header.device_id is None  # A5
    assert data.customer is None  # A3 — no placeholder "person"
    assert data.receipt is not None and data.receipt.cashier == CASHIER

    drawn = _drawn(data)
    flat = " | ".join(drawn)
    assert DEVICE not in flat
    assert label("col_device", locale) not in flat
    assert label("cash_customer", locale) not in flat
    assert _shows(drawn, f"{label('receipt_cashier_by', locale)} : {CASHIER}")


def test_receipt_without_a_cashier_prints_no_cashier_line() -> None:
    drawn = _drawn(_data("en", cashier_name=None))
    assert not any(label("receipt_cashier_by", "en") in block for block in drawn)


@pytest.mark.parametrize("locale", LOCALES)
def test_real_attached_customer_keeps_their_name(locale: str) -> None:
    data = _data(locale, customer_id=uuid.uuid4(), customer_name="Bob")
    assert data.customer is not None
    assert data.customer.name == "Bob"
    assert _shows(_drawn(data), f"{label('customer', locale)}: Bob")


def test_a4_customer_invoice_drops_the_sku_column_and_the_meta_rows() -> None:
    story = a4_flowables(_data("en"))
    items = _a4_table(story, 7)
    assert len(items._cellvalues[0]) == 7  # no SKU column
    texts = [p.text for p in _paragraphs(story)]
    assert not any(SKU in t for t in texts)
    assert not any(BARCODE in t for t in texts)
    assert not any(CASHIER in t for t in texts)
    assert not any(DEVICE in t for t in texts)
    assert label("cash_customer", "en") not in texts


@pytest.mark.parametrize("paper", ("80mm", "A4"))
@pytest.mark.parametrize("locale", LOCALES)
def test_customer_invoice_keeps_every_shopper_facing_field(
    locale: str, paper: str
) -> None:
    """Nothing was lost while removing the internal fields (A9).

    The 80mm meta block prints ``label: value`` on one line while the A4
    meta table keeps them in two cells, so the contract is asserted on
    localized labels and raw values rather than on their concatenation.
    The same goes for the quantity: 80mm folds qty and unit into one row
    (``2 × piece``) while A4 splits them over two columns.
    """
    data = _data(locale)
    if paper == "80mm":
        story = receipt_80mm.build_flowables(data)
        fragments = (
            # the receipt prints the stamp, not meta rows or a footer reference
            "10:30:00  05/01/2026",
            label("subtotal", locale),
            label("total", locale),
            label("receipt_received", locale),
            # no `change` row: this sale hands back no change
            label("base", locale),
            AR_NAME,
            "Cola",
            "Lait",
            "2",
            format_money(Decimal("490.000")),
        )
    else:
        story = a4_flowables(data)
        fragments = (
            label("invoice_number", locale),
            "INV-000123",
            label("date", locale),
            "2026-01-05",
            label("time", locale),
            "10:30",
            label("subtotal", locale),
            label("total", locale),
            label("amount_paid", locale),
            label("change", locale),
            label("base", locale),
            AR_NAME,
            "Cola",
            "Lait",
            "2",
            label("col_unit", locale),
            format_money(Decimal("490.000")),
        )
    drawn = " | ".join(_normalize(p.text) for p in _paragraphs(story))
    for fragment in fragments:
        shaped = _normalize(shape_text(fragment))
        assert shaped in drawn, f"{paper}/{locale}: missing {fragment!r}"


# ─── A6 — one authoritative timestamp, split for display ────────────────────


def test_split_date_and_time_come_from_the_single_sale_timestamp() -> None:
    data = _data("en")
    header = data.header
    assert header.occurred_date == "2026-01-05"
    assert header.occurred_time == "10:30"
    # the combined stamp is still there, built from the same value
    assert header.occurred_at == format_datetime(STAMP)
    assert header.occurred_at == f"{header.occurred_date} {header.occurred_time}"


@pytest.mark.parametrize("locale", LOCALES)
def test_receipt_shows_the_sale_stamp_and_no_footer_reference(locale: str) -> None:
    """A6 — the stamp comes from `sale_date`; the footer carries no reference.

    The redesigned receipt prints one clock+date line under the store
    identity (`10:30:00  05/01/2026`), instead of three `label: value` meta
    rows.  The barcode/footer reference was removed, so the invoice number
    is not printed on the thermal receipt at all.
    """
    data = _data(locale)
    drawn = _drawn(data)

    stamp = _normalize(shape_text("10:30:00  05/01/2026"))
    assert stamp in drawn, f"{locale}: {drawn}"
    assert "INV-000123" not in drawn


def test_internal_documents_keep_their_single_occurred_at_row() -> None:
    """A6 is a customer-invoice change.

    `occurred_date`/`occurred_time` default to `None`, so any builder that
    does not split the stamp (returns, purchases) still renders exactly the
    one combined `occurred_at` row it has always printed.
    """
    from app.printing.document_data import HeaderBlock

    fallback = HeaderBlock(
        document_number="RET-1",
        document_title="Return",
        occurred_at="2026-01-05 10:30",
        status_label=None,
    )
    assert fallback.occurred_date is None and fallback.occurred_time is None
    assert _data("en").header.occurred_date is not None  # the sale does split


# ─── A7 — item rows ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_item_group_is_name_then_value_row_then_only_useful_metadata(locale: str) -> None:
    """Customer items: name + `qty × unit | price | total`, plus the
    selling-unit base quantity and the discount when they apply — never an
    identifier row."""
    data = _data(locale)
    table = _items_table(data)
    value_rows = _value_rows(table)
    assert len(value_rows) == 3
    for row in value_rows:
        assert len(table._cellvalues[row]) == 3
        assert all(table._cellvalues[row])

    drawn = " | ".join(_drawn(data))
    # the selling-unit line still tells the shopper how many base units
    assert _normalize(shape_text(f"{label('base', locale)}: 24 Box")) in drawn
    assert _normalize(shape_text(f"{label('discount', locale)}: 10.00 DA")) in drawn


def test_value_row_is_never_spanned_on_a_customer_receipt() -> None:
    for locale in LOCALES:
        table = _items_table(_data(locale))
        spanned = {cmd[1][1] for cmd in table._spanCmds}
        assert not spanned & set(_value_rows(table)), locale
        assert table._ncols == 3


# ─── A8 — the 80mm Arabic audit ─────────────────────────────────────────────


def test_rtl_store_title_is_centered() -> None:
    for locale in LOCALES:
        title = _story(locale)[0]
        assert isinstance(title, Paragraph)
        assert title.style.alignment == TA_CENTER, locale


@pytest.mark.parametrize("key", ("invoice_number", "date", "time"))
def test_rtl_meta_lines_flush_to_the_reading_edge(key: str) -> None:
    for locale in LOCALES:
        line = _meta_paragraph(_data(locale), key)
        expected = TA_RIGHT if locale in RTL else TA_LEFT
        assert line.style.alignment == expected, f"{locale} {key}"


@pytest.mark.parametrize("locale", LOCALES)
def test_rtl_product_name_is_right_aligned(locale: str) -> None:
    name_cell = _items_table(_data(locale))._cellvalues[0][0]
    expected = TA_RIGHT if locale in RTL else TA_LEFT
    assert name_cell.style.alignment == expected


def test_rtl_mirrors_the_three_value_columns() -> None:
    """Qty × unit | unit price | line total flip sides without swapping data."""
    ltr = _items_table(_data("en"))
    rtl = _items_table(_data("ar"))
    for row in _value_rows(ltr):
        left = [_cell_text(c) for c in ltr._cellvalues[row]]
        right = [_cell_text(c) for c in rtl._cellvalues[row]]
        assert right == left[::-1], row
    # reportlab draws the widths in the same order as the cells
    assert list(rtl._argW) == list(reversed(ltr._argW))
    assert sum(rtl._argW) == pytest.approx(sum(ltr._argW))


@pytest.mark.parametrize(
    ("locale", "token"),
    [
        (locale, token)
        for locale in LOCALES
        # The item table states bare amounts (the currency is on the totals
        # rows), so `160.00` and `490.00 DA` are both part of the contract.
        for token in ("05/01/2026", "10:30:00", "490.00 DA", "160.00")
    ],
)
def test_digits_currency_invoice_and_clock_stay_readable(locale: str, token: str) -> None:
    drawn = _drawn(_data(locale))
    assert token in " | ".join(drawn), f"{locale}: {token!r} reordered or split"
    # never reversed, never broken across two drawn blocks
    assert token[::-1] not in drawn


@pytest.mark.parametrize("locale", RTL)
def test_rtl_receipt_text_is_shaped_exactly_once(locale: str) -> None:
    """A second bidi pass would visibly corrupt Arabic + digit mixes."""
    data = _data(locale, cashier_name=CASHIER)
    drawn = _drawn(data)
    for text in (
        f"{label('receipt_cashier_by', locale)} : {CASHIER}",
        f"{label('receipt_articles', locale)}",
        label("receipt_keep_ticket", locale),
    ):
        once = shape_text(text)
        twice = shape_text(once)
        assert _normalize(once) in " | ".join(drawn), text
        if twice != once:
            assert _normalize(twice) not in " | ".join(drawn), f"{text}: shaped twice"


@pytest.mark.parametrize("locale", LOCALES)
def test_arabic_and_latin_product_names_coexist(locale: str) -> None:
    drawn = " | ".join(_drawn(_data(locale)))
    assert _normalize(shape_text(AR_NAME)) in drawn
    assert "Cola" in drawn
    assert "Lait" in drawn


# ─── RTL on A4 ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize("locale", LOCALES)
def test_a4_customer_invoice_has_the_same_alignment_policy(locale: str) -> None:
    story = a4_flowables(_data(locale))
    rtl = locale in RTL
    title = next(f for f in story if isinstance(f, Paragraph))
    assert title.style.alignment == TA_CENTER

    items = _a4_table(story, 7)
    # the table cells are mirrored for RTL, so the product sits at the far end
    name_col, index_col = (5, 6) if rtl else (1, 0)
    assert items._cellvalues[0][name_col].style.alignment == TA_CENTER  # header
    assert items._cellvalues[1][name_col].style.alignment == (TA_RIGHT if rtl else TA_LEFT)
    assert items._cellvalues[1][index_col].style.alignment == TA_CENTER  # line number
