"""A4 sale/return/purchase document template (Phase 15 §8).

Geometry: A4 portrait, margins 15/15/18/18mm, body 10.5pt.  Item table has
8 columns (return/purchase, incl. SKU) or 7 (customer sale invoice, §15.7 —
no SKU column) with a repeating header row; meta block is a boxed 2-column
table; totals sit in a ~100mm block on the opposite side of the page from
the title (mirrored for `locale=ar`).  Page numbering (N of M) is applied
by `render.py` via a NumberedCanvas.  Zero business logic.
"""

from __future__ import annotations

from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Paragraph, Spacer, Table, TableStyle

from app.printing.document_data import DocumentData, TotalsBlock
from app.printing.labels import label
from app.printing.styles import paragraph_style
from app.printing.text import shape_text

CONTENT_WIDTH = 180 * mm
#: Internal documents (return/purchase): 8 columns incl. the SKU column.
COL_WIDTHS = [6 * mm, 52 * mm, 24 * mm, 16 * mm, 14 * mm, 24 * mm, 20 * mm, 24 * mm]
#: Customer sale invoice (§15.7 A1) — no SKU column.  The 24mm it used to
#: occupy is redistributed so the row still spans the full 180mm body.
CUSTOMER_COL_WIDTHS = [6 * mm, 68 * mm, 18 * mm, 16 * mm, 24 * mm, 22 * mm, 26 * mm]
HAIRLINE = 0.6

_ITEM_HEADERS = ("#", "col_product", "col_sku", "col_unit", "col_qty",
                 "price", "discount", "col_total")


def _p(text: str, size: float, rtl: bool, *, bold: bool = False, align: str | None = None) -> Paragraph:
    """One shaped Paragraph.  `align=None` → right for Arabic, left for LTR
    (§15.7 A8); hard-coding ``"left"`` left every un-aligned Arabic block —
    product names, meta rows, totals labels — flush to the wrong margin."""
    style = paragraph_style(
        f"ra4-{size}-{bold}-{align}-{rtl}",
        size=size,
        leading=size * 1.3,
        rtl=rtl,
        bold=bold,
        align=align,
    )
    return Paragraph(shape_text(text), style)


def _items_table(data: DocumentData) -> Flowable | None:
    if not data.lines:
        return None
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    # §15.7 A1 — a customer receipt has no identifiers, so it has no SKU
    # column either: an empty header would advertise a field that is not
    # printed.  Returns/purchases keep theirs.
    include_sku = not data.customer_facing

    header = [
        _p(label(key, locale), 9, rtl, bold=True, align="center")
        for key in _ITEM_HEADERS
        if include_sku or key != "col_sku"
    ]
    body: list[list[Paragraph]] = [header if not rtl else list(reversed(header))]
    row_spans: list[int] = []

    for index, line in enumerate(data.lines, start=1):
        name = line.name
        if line.kind == "pack_component":
            name = f"└ {name}"
        cells = [
            _p(str(index), 9.5, rtl, align="center"),
            _p(name, 9.5, rtl),
        ]
        if include_sku:
            cells.append(_p(line.sku or "", 9, rtl))
        cells += [
            _p(line.unit_label, 9, rtl, align="center"),
            _p(line.qty, 9.5, rtl, align="center"),
            _p(line.unit_price if line.show_money else "", 9.5, rtl, align="left"),
            _p(line.line_discount or "" if line.show_money else "", 9.5, rtl, align="left"),
            _p(line.line_total if line.show_money else "", 9.5, rtl, align="left"),
        ]
        body.append(cells if not rtl else list(reversed(cells)))

        meta_bits = []
        if line.base_qty:
            meta_bits.append(f"{label('base', locale)}: {line.base_qty} {line.unit_label}")
        if meta_bits:
            row_index = len(body) - 1
            body.append([_p("   ".join(meta_bits), 8, rtl)])
            row_spans.append(row_index)

    col_widths = COL_WIDTHS if include_sku else CUSTOMER_COL_WIDTHS
    widths = col_widths if not rtl else list(reversed(col_widths))
    table = Table(body, colWidths=widths, repeatRows=1)
    spans = [
        ("SPAN", (0, idx), (-1, idx))
        for idx in _span_targets(row_spans)
    ]
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
            + spans
        )
    )
    return table


def _span_targets(row_spans: list[int]) -> list[int]:
    """Meta rows follow a data row; return their absolute indices.

    `row_spans` stores the data-row index captured immediately before the
    meta row was appended, so the meta row always sits at data index + 1 —
    including for the second and later meta rows, whose data index already
    accounts for the meta rows appended before them.  (A cumulative offset
    here used to span the wrong row: the third item row collapsed to one
    cell as soon as two lines carried a base quantity.)
    """
    return [data_index + 1 for data_index in row_spans]


def _meta_table(data: DocumentData) -> Flowable:
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    rows: list[tuple[str, str]] = [
        (
            label("invoice_number" if data.header.source_invoice is None else "return_number", locale),
            data.header.document_number,
        ),
        # A6 — Date then Time, both sliced from the one authoritative stamp.
        (label("date", locale), data.header.occurred_date or data.header.occurred_at),
    ]
    if data.header.occurred_time:
        rows.append((label("time", locale), data.header.occurred_time))
    if data.header.source_invoice:
        rows.append((label("col_invoice", locale), data.header.source_invoice))
    if data.header.supplier_name:
        rows.append((label("supplier", locale), data.header.supplier_name))
    if data.customer is not None and data.customer.name:
        rows.append((label(data.customer.label_key, locale), data.customer.name))
    if data.cashier_name:
        rows.append((label("cashier", locale), data.cashier_name))
    if data.totals is not None and data.totals.payment_method:
        rows.append((label("payment_method", locale), data.totals.payment_method))
    if data.header.device_id:
        rows.append((label("col_device", locale), data.header.device_id))
    if data.header.status_label:
        rows.append((label("status", locale), data.header.status_label))
    if data.header.is_void and data.header.void_reason:
        rows.append((label("col_void_reason", locale), data.header.void_reason))

    body: list[list[Paragraph]] = []
    for lab, val in rows:
        # Label defaults to the script's start edge; the value cell is pinned
        # left so an RTL row keeps both cells flush to their OUTER margins.
        label_cell = _p(lab, 9.5, rtl, bold=True)
        value_cell = _p(val, 9.5, rtl, align="left")
        body.append([label_cell, value_cell] if not rtl else [value_cell, label_cell])
    table = Table(body, colWidths=[CONTENT_WIDTH * 0.3, CONTENT_WIDTH * 0.7])
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("GRID", (0, 0), (-1, -1), HAIRLINE, "grey"),
                ("BOX", (0, 0), (-1, -1), 0.9, "black"),
                ("BACKGROUND", (0, 0), (0, -1), "#f7f7f7"),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
            ]
        )
    )
    return table


def _totals_block(data: DocumentData) -> Flowable | None:
    t: TotalsBlock | None = data.totals
    if t is None:
        return None
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    pairs: list[tuple[str, str | None]] = [
        (label("subtotal", locale), t.subtotal),
        (label("col_line_discounts", locale), t.line_discounts_sum),
        (label("col_invoice_discount", locale), t.invoice_discount),
        (label("total", locale), t.total),
        (label("amount_paid", locale), t.paid),
        (label("change", locale), t.change),
        (label("debt", locale), t.debt),
        (label("payment_method", locale), t.payment_method),
    ]
    pairs = [(lab, val) for lab, val in pairs if val is not None]
    total_index = next(i for i, (lab, _) in enumerate(pairs) if lab == label("total", locale))

    body: list[list[Paragraph]] = []
    for lab, val in pairs:
        bold = lab == label("total", locale)
        left = _p(lab, 10, rtl, bold=bold)
        right = _p(val or "", 10, rtl, bold=bold, align="right" if not rtl else "left")
        body.append([left, right] if not rtl else [right, left])

    for payment in data.payments:
        left = _p(payment.method_label, 9.5, rtl)
        right = _p(payment.amount, 9.5, rtl, align="right" if not rtl else "left")
        body.append([left, right] if not rtl else [right, left])

    table = Table(body, colWidths=[55 * mm, 45 * mm])
    table.hAlign = "LEFT" if rtl else "RIGHT"
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ("GRID", (0, 0), (-1, -1), HAIRLINE, "grey"),
                ("BOX", (0, total_index), (-1, total_index), 1.1, "black"),
            ]
        )
    )
    return table


def build_flowables(data: DocumentData) -> list[Flowable]:
    """A4 document story: title → meta → items → totals → notes."""
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    story: list[Flowable] = []

    story.append(_p(data.store.name, 18, rtl, bold=True, align="center"))
    if data.store.phone:
        story.append(_p(data.store.phone, 10, rtl, align="center"))
    if data.store.address:
        story.append(_p(data.store.address, 10, rtl, align="center"))
    story.append(_p(data.header.document_title, 13, rtl, align="center"))
    if data.header.is_void:
        banner_parts = [label("status_void", locale)]
        if data.header.voided_at:
            banner_parts.append(data.header.voided_at)
        story.append(_p(" | ".join(banner_parts), 11, rtl, bold=True, align="center"))
    story.append(Spacer(1, 4 * mm))

    story.append(_meta_table(data))
    story.append(Spacer(1, 4 * mm))

    items = _items_table(data)
    if items is not None:
        story.append(items)
        story.append(Spacer(1, 4 * mm))

    totals = _totals_block(data)
    if totals is not None:
        story.append(totals)

    if data.meta.note:
        story.append(Spacer(1, 3 * mm))
        story.append(_p(f"{label('note', locale)}: {data.meta.note}", 9.5, rtl))

    if data.store.footer:
        story.append(Spacer(1, 4 * mm))
        story.append(_p(data.store.footer, 9.5, rtl, align="center"))

    story.append(Spacer(1, 6 * mm))
    story.append(
        _p(f"{label('generated', locale)}: {data.meta.generated_at}", 8, rtl, align="center")
    )
    return story
