"""80mm thermal receipt template (Phase 15 §7).

Geometry: 80mm page width, margins 4/4/5/5mm, body 9pt, meta 7.5pt,
title 14pt bold. Columns share 40/18/20/22 % of the 72mm content width.
Mirrors for `locale=ar` (visual RTL). Zero business logic — everything
is pre-derived on `DocumentData`.
"""

from __future__ import annotations

from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Paragraph, Spacer, Table, TableStyle

from app.printing.document_data import DocumentData, TotalsBlock
from app.printing.labels import label
from app.printing.styles import paragraph_style
from app.printing.text import shape_text

CONTENT_WIDTH = 72 * mm
COL_WIDTHS = [0.40 * CONTENT_WIDTH, 0.18 * CONTENT_WIDTH, 0.20 * CONTENT_WIDTH, 0.22 * CONTENT_WIDTH]
HAIRLINE = 0.6


def _p(text: str, size: float, rtl: bool, *, bold: bool = False, align: str = "left") -> Paragraph:
    style = paragraph_style(
        f"r80-{size}-{bold}-{align}-{rtl}",
        size=size,
        leading=size * 1.2,
        rtl=rtl,
        bold=bold,
        align=align,
    )
    return Paragraph(shape_text(text), style)


def _label_value_rows(data: DocumentData, rows: list[tuple[str, str | None]]) -> list[list[str]]:
    """Filter out None rows; keep (label, value) pairs as drawn."""
    return [(lab, val) for lab, val in rows if val is not None]


def _totals_table(data: DocumentData) -> Flowable | None:
    t: TotalsBlock | None = data.totals
    if t is None:
        return None
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    pairs = _label_value_rows(
        data,
        [
            (label("subtotal", locale), t.subtotal),
            (label("col_line_discounts", locale), t.line_discounts_sum),
            (label("col_invoice_discount", locale), t.invoice_discount),
            (label("total", locale), t.total),
            (label("amount_paid", locale), t.paid),
            (label("change", locale), t.change),
            (label("debt", locale), t.debt),
            (label("payment_method", locale), t.payment_method),
        ],
    )
    total_index = next(i for i, (lab, _) in enumerate(pairs) if lab == label("total", locale))

    body: list[list[Paragraph]] = []
    for lab, val in pairs:
        label_cell = _p(lab, 8.5, rtl, bold=(lab == label("total", locale)))
        value_cell = _p(val or "", 8.5, rtl, bold=(lab == label("total", locale)), align="left")
        body.append([value_cell, label_cell] if rtl else [label_cell, value_cell])

    extra_styles: list[tuple] = []
    if len(data.payments) > 1:
        for payment in data.payments:
            cells = [
                _p(payment.amount, 8.5, rtl, align="left"),
                _p(payment.method_label, 8.5, rtl),
            ]
            body.append(cells if rtl else [cells[1], cells[0]])

    table = Table(body, colWidths=[CONTENT_WIDTH * 0.62, CONTENT_WIDTH * 0.38])
    style = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 1.2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2),
        ("BOX", (0, total_index), (-1, total_index), 1.0, "black"),
    ]
    table.setStyle(TableStyle(style + extra_styles))
    return table


def _items_table(data: DocumentData) -> Flowable | None:
    if not data.lines:
        return None
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders

    body: list[list[Paragraph]] = []
    span_rows: list[int] = []
    for line in data.lines:
        name = shape_text(line.name)
        if line.kind == "pack_component":
            name = f"└ {name}"
        name_cell = _p(name, 9, rtl)
        qty_cell = _p(f"{line.qty} × {line.unit_label}", 8.5, rtl, align="center")
        price_cell = _p(line.unit_price, 8.5, rtl, align="left") if line.show_money else _p("", 8.5, rtl)
        total_cell = _p(line.line_total, 8.5, rtl, align="left") if line.show_money else _p("", 8.5, rtl)
        row = [name_cell, qty_cell, price_cell, total_cell]
        body.append(row if not rtl else list(reversed(row)))

        meta_bits = []
        if line.sku:
            meta_bits.append(line.sku)
        if line.base_qty:
            meta_bits.append(
                f"{label('base', locale)}: {line.base_qty} {line.unit_label}"
            )
        if meta_bits:
            span_rows.append(len(body) - 1)
            body.append([_p("   ".join(meta_bits), 7.5, rtl)])
            span_rows.append(len(body) - 1)

        if line.line_discount:
            body.append([_p(f"{label('discount', locale)}: {line.line_discount}", 7.5, rtl)])
            span_rows.append(len(body) - 1)

    widths = COL_WIDTHS if not rtl else list(reversed(COL_WIDTHS))
    table = Table(body, colWidths=widths, repeatRows=0)

    span_styles: list[tuple] = []
    seen: set[int] = set()
    for idx in span_rows:
        if idx in seen:
            continue
        seen.add(idx)
        span_styles.append(("SPAN", (0, idx), (-1, idx)))
    style = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 1.5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
        ("LINEBELOW", (0, 0), (-1, -1), HAIRLINE, "grey"),
    ]
    table.setStyle(TableStyle(style + span_styles))
    return table


def _void_banner(data: DocumentData) -> Flowable | None:
    h = data.header
    if not h.is_void:
        return None
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    parts = [label("status_void", locale)]
    if h.void_reason:
        parts.append(f"{label('col_void_reason', locale)}: {h.void_reason}")
    if h.voided_at:
        parts.append(h.voided_at)
    cell = _p(" | ".join(parts), 9, rtl, bold=True, align="center")
    table = Table([[cell]], colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 1.2, "black"),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    return table


def build_flowables(data: DocumentData) -> list[Flowable]:
    """Receipt story: identity → meta → customer → items → totals → footer."""
    rtl = data.rtl
    locale = data.meta.locale  # meta is always set by builders
    story: list[Flowable] = []

    story.append(_p(data.store.name, 14, rtl, bold=True, align="center"))
    if data.store.phone:
        story.append(_p(data.store.phone, 8, rtl, align="center"))
    if data.store.address:
        story.append(_p(data.store.address, 8, rtl, align="center"))
    story.append(_p(data.header.document_title, 10, rtl, align="center"))
    story.append(Spacer(1, 2 * mm))

    meta_lines = [
        f"{label('invoice_number', locale)}: {data.header.document_number}",
        f"{label('date', locale)}: {data.header.occurred_at}",
    ]
    if data.header.source_invoice:
        meta_lines.append(
            f"{label('col_invoice', locale)}: {data.header.source_invoice}"
        )
    if data.header.supplier_name:
        meta_lines.append(f"{label('supplier', locale)}: {data.header.supplier_name}")
    if data.header.device_id:
        meta_lines.append(f"{label('col_device', locale)}: {data.header.device_id}")
    if data.cashier_name:
        meta_lines.append(f"{label('cashier', locale)}: {data.cashier_name}")
    if data.header.status_label and not data.header.is_void:
        meta_lines.append(f"{label('status', locale)}: {data.header.status_label}")
    for text in meta_lines:
        story.append(_p(text, 7.5, rtl))

    banner = _void_banner(data)
    if banner is not None:
        story.append(Spacer(1, 1.5 * mm))
        story.append(banner)

    if data.customer is not None and data.customer.name:
        story.append(Spacer(1, 1.5 * mm))
        story.append(
            _p(
                f"{label(data.customer.label_key, locale)}: {data.customer.name}",
                7.5,
                rtl,
            )
        )

    story.append(Spacer(1, 2 * mm))
    items = _items_table(data)
    if items is not None:
        story.append(items)

    story.append(Spacer(1, 2 * mm))
    totals = _totals_table(data)
    if totals is not None:
        story.append(totals)

    if data.meta.note:
        story.append(Spacer(1, 1.5 * mm))
        story.append(_p(f"{label('note', locale)}: {data.meta.note}", 7.5, rtl))

    story.append(Spacer(1, 2 * mm))
    story.append(_p(data.store.name, 8, rtl, align="center"))
    if data.store.footer:
        story.append(Spacer(1, 1.5 * mm))
        story.append(_p(data.store.footer, 7.5, rtl, align="center"))
    return story


def estimate_height(data: DocumentData) -> float:
    """Content-driven page height: min 140mm, max 400mm segment (7.6)."""
    # Receipt identity (17.6): the contact lines sit under the store name
    # and the configured footer sits under the totals — ~4mm each, so they
    # are budgeted rather than left to eat the roll segment.
    identity_mm = 4.0 * sum(
        1 for v in (data.store.phone, data.store.address) if v
    )
    footer_text_mm = 4.0 if data.store.footer else 0.0
    header_mm = 45.0 + identity_mm
    footer_mm = 25.0 + footer_text_mm
    rows_mm = 0.0

    for line in data.lines:
        rows_mm += 7.0
        if line.sku or line.base_qty:
            rows_mm += 4.0
        if line.line_discount:
            rows_mm += 4.0
    totals_rows = 4
    if data.totals is not None:
        totals_rows += sum(
            1
            for v in (
                data.totals.line_discounts_sum,
                data.totals.invoice_discount,
                data.totals.paid,
                data.totals.change,
                data.totals.debt,
                data.totals.payment_method,
            )
            if v
        )
    totals_mm = 4.0 * totals_rows
    void_mm = 8.0 if data.header.is_void else 0.0
    total = header_mm + rows_mm + totals_mm + footer_mm + void_mm
    return max(140.0, min(400.0, total)) * mm
