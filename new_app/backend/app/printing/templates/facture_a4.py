"""A4 facturation document template (Phase 7 — factura_simple parity).

Geometry: the shared A4 profile (portrait, margins 15/15/18/18mm, body
180mm) so page numbering, footer and font registration in ``render.py``
are reused untouched. Story: company + bordered title box → client box →
items table (repeating header row) → totals block → amount in words /
payment method / notes → signature rule.

Every value arrives pre-formatted and flag-gated in ``FactureData``
(``show_discount`` / ``show_tva`` drop a column, ``show_timbre`` /
``show_amount_words`` / ``show_payment_method`` drop a row) — the
template holds ZERO business logic. ``locale=ar`` mirrors the sides and
reverses the table columns, exactly like ``invoice_a4``.
"""

from __future__ import annotations

from reportlab.lib.units import mm
from reportlab.platypus import Flowable, KeepTogether, Paragraph, Spacer, Table, TableStyle

from app.printing.facture_data import FactureData, FactureLineRow
from app.printing.labels import label
from app.printing.styles import paragraph_style
from app.printing.text import shape_text

CONTENT_WIDTH = 180 * mm
HAIRLINE = 0.6
#: mm widths of every item column; the two gated ones are only appended
#: when their ``show_*`` flag is on, Désignation absorbs what is left.
COL_QTY_MM = 16.0
COL_UNIT_PRICE_MM = 24.0
COL_DISCOUNT_MM = 18.0
COL_TVA_MM = 16.0
COL_TOTAL_MM = 28.0
COL_INDEX_MM = 8.0


def _p(
    text: str,
    size: float,
    rtl: bool,
    *,
    bold: bool = False,
    align: str | None = None,
) -> Paragraph:
    """One shaped Paragraph (same rule as ``invoice_a4._p``)."""
    style = paragraph_style(
        f"fa4-{size}-{bold}-{align}-{rtl}",
        size=size,
        leading=size * 1.3,
        rtl=rtl,
        bold=bold,
        align=align,
    )
    return Paragraph(shape_text(text), style)


def _box_cell(flowables: list[Flowable]) -> list[Flowable]:
    """A single table cell holding a column of flowables (reportlab list cell)."""
    return flowables


def _title_box(data: FactureData) -> list[Flowable]:
    """Bordered title box: localized title + stored number + stored date."""
    rtl = data.rtl
    locale = data.locale
    return [
        _p(data.title, 15, rtl, bold=True),
        _p(f"N° : {data.number}", 10, rtl),
        _p(f"{label('date', locale)} : {data.document_date}", 10, rtl),
    ]


def _company_column(data: FactureData) -> list[Flowable]:
    rtl = data.rtl
    column = [_p(data.company.name, 16, rtl, bold=True)]
    column.extend(_p(line, 9, rtl) for line in data.company.lines)
    return column


def _header_row(data: FactureData) -> Flowable:
    """Seller identity on the reading start edge, title box opposite (legacy row)."""
    company = _box_cell(_company_column(data))
    box = _box_cell(_title_box(data))
    box_style = TableStyle(
        [
            ("BOX", (0, 0), (-1, -1), 0.7, "grey"),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ("RIGHTPADDING", (0, 0), (-1, -1), 6),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ]
    )
    if data.rtl:
        row = [[_wrap_box(box, box_style), company]]
        widths = [CONTENT_WIDTH * 0.40, CONTENT_WIDTH * 0.60]
    else:
        row = [[company, _wrap_box(box, box_style)]]
        widths = [CONTENT_WIDTH * 0.60, CONTENT_WIDTH * 0.40]
    table = Table(row, colWidths=widths)
    table.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP")]))
    return table


def _wrap_box(flowables: list[Flowable], style: TableStyle) -> Flowable:
    """Wrap a list of flowables in a bordered one-cell table."""
    table = Table([[flowables]])
    table.setStyle(style)
    return table


def _client_box(data: FactureData) -> Flowable | None:
    client = data.client
    if client is None:
        return None
    rtl = data.rtl
    body: list[Flowable] = []
    if client.heading:
        body.append(_p(client.heading, 8, rtl))
    body.append(_p(client.name, 12, rtl, bold=True))
    body.extend(_p(line, 9, rtl) for line in client.lines)
    table = Table([[_box_cell(body)]], colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.7, "grey"),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    return table


def _header_keys(data: FactureData) -> list[str]:
    """Item header keys in column order (gated columns simply missing)."""
    keys = ["col_description", "col_qty", "col_unit_price_ht"]
    if data.show_discount:
        keys.append("col_remise_pct")
    if data.show_tva:
        keys.append("col_tva_rate")
    keys.append("col_ht")
    return keys


def _col_widths(data: FactureData) -> list[float]:
    """pt widths in column order: #, flexible Désignation, then the rest."""
    fixed = [COL_QTY_MM, COL_UNIT_PRICE_MM]
    if data.show_discount:
        fixed.append(COL_DISCOUNT_MM)
    if data.show_tva:
        fixed.append(COL_TVA_MM)
    fixed.append(COL_TOTAL_MM)
    designation = CONTENT_WIDTH - (COL_INDEX_MM + sum(fixed)) * mm
    return [COL_INDEX_MM * mm, designation, *(w * mm for w in fixed)]


def _row_cells(row: FactureLineRow, data: FactureData) -> list[Paragraph]:
    rtl = data.rtl
    number_align = "left" if rtl else "right"
    cells = [
        _p(row.index, 9.5, rtl, align="center"),
        _p(row.description, 9.5, rtl),
        _p(row.qty, 9.5, rtl, align="center"),
        _p(row.unit_price, 9.5, rtl, align=number_align),
    ]
    if data.show_discount:
        cells.append(_p(row.discount or "", 9.5, rtl, align=number_align))
    if data.show_tva:
        cells.append(_p(row.tva_rate or "", 9.5, rtl, align=number_align))
    cells.append(_p(row.total_ht, 9.5, rtl, align=number_align))
    return cells


def _items_table(data: FactureData) -> Flowable | None:
    if not data.lines:
        return None
    rtl = data.rtl
    locale = data.locale

    header = [_p("#", 9, rtl, bold=True, align="center")]
    header += [
        _p(label(key, locale), 9, rtl, bold=True, align="center")
        for key in _header_keys(data)
    ]
    body: list[list[Paragraph]] = [header if not rtl else list(reversed(header))]
    for row in data.lines:
        cells = _row_cells(row, data)
        body.append(cells if not rtl else list(reversed(cells)))

    widths = _col_widths(data)
    if rtl:
        widths = list(reversed(widths))
    table = Table(body, colWidths=widths, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("BACKGROUND", (0, 0), (-1, 0), "#eeeeee"),
                ("GRID", (0, 0), (-1, -1), HAIRLINE, "grey"),
                ("BOX", (0, 0), (-1, -1), 0.9, "black"),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ("LEFTPADDING", (0, 0), (-1, -1), 3),
                ("RIGHTPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    return table


def _totals_block(data: FactureData) -> Flowable:
    """Totals stack: HT → TVA? → TTC → timbre? → Net à payer (bold, boxed)."""
    rtl = data.rtl
    locale = data.locale
    totals = data.totals
    pairs: list[tuple[str, str]] = [(label("col_ht", locale), totals.total_ht)]
    if data.show_tva:
        pairs.append((label("col_total_tva", locale), totals.total_tva or ""))
    pairs.append((label("col_ttc", locale), totals.total_ttc))
    if totals.timbre is not None:
        pairs.append((label("col_timbre", locale), totals.timbre))
    pairs.append((label("col_net_a_payer", locale), totals.net_a_payer))

    body: list[list[Paragraph]] = []
    net_index = len(pairs) - 1
    for index, (lab, value) in enumerate(pairs):
        bold = index == net_index
        lab_cell = _p(lab, 10, rtl, bold=bold)
        value_cell = _p(
            value, 10, rtl, bold=bold, align="right" if not rtl else "left"
        )
        body.append([lab_cell, value_cell] if not rtl else [value_cell, lab_cell])

    table = Table(body, colWidths=[55 * mm, 45 * mm])
    table.hAlign = "LEFT" if rtl else "RIGHT"
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ("GRID", (0, 0), (-1, -1), HAIRLINE, "grey"),
                ("BOX", (0, net_index), (-1, net_index), 1.1, "black"),
            ]
        )
    )
    return table


def _signature(data: FactureData) -> Flowable:
    """Legacy signature block: label, gap, then a rule the client signs on."""
    rtl = data.rtl
    table = Table(
        [[_p(label("signature", data.locale), 9, rtl, bold=True)], [Spacer(1, 10 * mm)]],
        colWidths=[60 * mm],
    )
    table.setStyle(
        TableStyle(
            [
                ("LINEABOVE", (0, 1), (-1, 1), 0.6, "grey"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    table.hAlign = "LEFT" if rtl else "RIGHT"
    return table


def build_flowables(data: FactureData) -> list[Flowable]:
    """A4 facturation story (legacy ``buildInvoicePdf`` section order)."""
    rtl = data.rtl
    locale = data.locale
    story: list[Flowable] = []

    story.append(_header_row(data))
    story.append(Spacer(1, 5 * mm))

    client = _client_box(data)
    if client is not None:
        story.append(client)
        story.append(Spacer(1, 5 * mm))

    items = _items_table(data)
    if items is not None:
        story.append(items)
        story.append(Spacer(1, 5 * mm))

    story.append(_totals_block(data))
    story.append(Spacer(1, 4 * mm))

    if data.amount_in_words:
        story.append(_p(data.amount_in_words, 10, rtl, bold=True))
        story.append(Spacer(1, 2 * mm))
    if data.payment_method:
        story.append(
            _p(f"{label('payment_method', locale)} : {data.payment_method}", 9, rtl)
        )
    if data.notes:
        story.append(Spacer(1, 2 * mm))
        story.append(_p(f"{label('note', locale)} : {data.notes}", 9, rtl))

    story.append(KeepTogether(_signature(data)))
    return story
