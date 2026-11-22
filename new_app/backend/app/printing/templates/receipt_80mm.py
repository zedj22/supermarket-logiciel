"""80mm thermal sale receipt — minimalist cash-register layout.

This is the customer SALE receipt only.  It is selected by
``DocumentData.receipt is not None`` (set exclusively by
``build_sale_document``), so the A4 invoice, the report PDFs and the
internal return/purchase documents keep ``invoice_80mm``/``invoice_a4``
byte-for-byte.  All values arrive pre-formatted on ``DocumentData``; this
module owns geometry and typography only.

Layout (top → bottom), on 80mm paper with 4mm side margins:

    15:40:17  19/11/2026                    sale timestamp (sale_date)
    ------------------------------ hairline
    Désignation   Prix U   Qté   Montant    bold headings
    ------------------------------ hairline
    Coca Cola       160.00     2   320.00   one row per line
    └ Milk (pack component)                 muted, no money
      Base: 24 piece                        optional, 6.5pt
      Remise : 10.00 DA                     optional, 6.5pt
    ------------------------------ one hairline after the last row
    3 Articles
    32 pcs
    ------------------------------ hairline
    Sous-total                   1 070.00 DA
    Remise :                        180.00 DA
    Encaissé par : Admin

    ┌──────────────────────────────┐
    │ Reçu                  2 000.00 DA │
    │ Total                   890.00 DA │
    │ Rendu                 1 110.00 DA │
    └──────────────────────────────┘

    <configured invoice footer>             Settings → receipt footer
    Veuillez conserver votre Ticket de Caisse

The item table never mirrors its *meaning*: the four columns are the same
logical fields in every locale; for Arabic the column order and widths are
reversed so the designation reads from the right edge, exactly like the
existing A4/legacy 80mm tables.  Numeric cells use tabular, right-aligned
shaped text with no currency suffix (the currency is stated once, on the
totals rows), which is what keeps four columns readable at 7.5pt on
thermal paper.
"""

from __future__ import annotations

from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import Flowable, Paragraph, Spacer, Table, TableStyle

from app.printing.document_data import DocumentData, ReceiptSummary, TotalsBlock
from app.printing.fonts import FONT_REGULAR
from app.printing.labels import CURRENCY, LOCALES, RECEIPT_COLUMNS, label
from app.printing.styles import paragraph_style
from app.printing.text import shape_text

#: 80mm page − 4mm margins − reportlab's 6pt frame padding per side.  Using
#: the raw 72mm made every table 12pt wider than the frame, so reportlab
#: centred it into a negative offset and the tables bled into the margins
#: while the plain paragraphs did not (a visible indent on the cashier line).
CONTENT_WIDTH = 72 * mm - 12.0
#: Item table columns (logical LTR order).  The designation column takes
#: whatever the three numeric columns leave: money cells only hold a plain
#: amount (no `DA` suffix), so 38pt fits `9 999.99` at the body size.
#: The bigger type needs a few more points than the old columns held.
#: Sized from the WIDEST heading in any locale at the new size — Arabic
#: `سعر الوحدة` and English `Unit price` both measure 39.1pt — so no column
#: heading wraps onto a second line (`Montant` 33.2pt sets the amount floor,
#: `9 999.99` at 34.9pt still fits the money column). The designation gives
#: up 5pt (it wraps by design) and the quantity column keeps its width.
#: The sum is still exactly CONTENT_WIDTH — four columns, same 80mm page.
COL_DESIGNATION = 83.0
COL_PRICE = 43.0
COL_QTY = 26.0
COL_AMOUNT = CONTENT_WIDTH - COL_DESIGNATION - COL_PRICE - COL_QTY

#: Type scale — the readability pass raised every rung by ~10–15% on the
#: same 80mm geometry.  The four columns did not move: only the type grew,
#: so the layout, separators and hierarchy are the ones the operator knows.
BODY = 8.5  # was 7.5 (+13%) — items, quantities, totals, cashier
HEADING = 8.5  # was 7.5 — column headings, bold as before
META = 7.3  # was 6.5 (+12%) — pack/base/discount detail lines
#: Store identity: raised only slightly (+8%) so it stays the loudest line
#: on the paper and never competes with the total in the payment box.
STORE_NAME = 13
STORE_CONTACT = 7.8  # was 7 — phone / address
STAMP = 8.8  # was 8 — sale timestamp
FOOTER = 8.8  # was 8 — configured invoice footer / default thanks block
FOOTER_SECONDARY = 8.5  # was 7.5 — French thanks line of the default block
NOTICE = 7.8  # was 7 — retention notice
PAD = 1.6
HAIRLINE = 0.4
HEADER_RULE = 0.8
#: Shrink floor for a numeric cell that would otherwise wrap mid-amount.
#: Deliberately UNCHANGED at 6pt: the body grew, but the last resort for a
#: millions-scale amount must not become easier to trigger than before —
#: a normal price never reaches it, and an extreme one wraps exactly as it
#: always did.
_NUM_SIZE_MIN = 6.0
#: Product units are stored in English, so "piece" is matched against every
#: localized spelling — that meta line is noise, not information.
_PIECE_WORDS = {"piece", "pieces", "pcs"} | {
    label("unit_piece", locale).lower() for locale in LOCALES
}


def _p(
    text: str,
    size: float,
    *,
    rtl: bool,
    bold: bool = False,
    align: str | None = None,
) -> Paragraph:
    """One shaped Paragraph; `align=None` follows the script (§15.7 A8)."""
    style = paragraph_style(
        f"r80r-{size}-{bold}-{align}-{rtl}",
        size=size,
        leading=size * 1.18,
        rtl=rtl,
        bold=bold,
        align=align,
    )
    return Paragraph(shape_text(text), style)


def _number(text: str | None) -> str:
    """Amount without the currency suffix — the totals rows carry `DA`."""
    if not text:
        return ""
    suffix = f" {CURRENCY}"
    return text[: -len(suffix)] if text.endswith(suffix) else text


def _fitted(
    text: str,
    usable: float,
    *,
    rtl: bool,
    bold: bool = False,
    align: str,
    size: float = BODY,
) -> Paragraph:
    """Numeric cell that shrinks (never below 6pt) instead of wrapping."""
    shaped = shape_text(text)
    while size > _NUM_SIZE_MIN and stringWidth(shaped, FONT_REGULAR, size) > usable:
        size -= 0.25
    return _p(text, size, rtl=rtl, bold=bold, align=align)


def _items_table(data: DocumentData) -> Flowable | None:
    if not data.lines:
        return None
    locale = data.meta.locale  # meta is always set by builders
    rtl = data.rtl
    # Mirrored layout: Arabic reads designation → price → qty → amount from
    # the right edge, so each row and the column widths are reversed.
    edge = "right" if rtl else "left"
    outer = "left" if rtl else "right"
    widths = [COL_DESIGNATION, COL_PRICE, COL_QTY, COL_AMOUNT]
    if rtl:
        widths.reverse()
    money_usable = COL_AMOUNT - 2 * PAD
    qty_usable = COL_QTY - 2 * PAD

    def row(cells: list[Paragraph]) -> list[Paragraph]:
        return list(reversed(cells)) if rtl else cells

    header = row(
        [
            _p(label(RECEIPT_COLUMNS[0], locale), HEADING, rtl=rtl, bold=True, align=edge),
            _p(label(RECEIPT_COLUMNS[1], locale), HEADING, rtl=rtl, bold=True, align=outer),
            _p(label(RECEIPT_COLUMNS[2], locale), HEADING, rtl=rtl, bold=True, align=outer),
            _p(label(RECEIPT_COLUMNS[3], locale), HEADING, rtl=rtl, bold=True, align=outer),
        ]
    )
    body: list[list[Paragraph]] = [header]
    span_rows: list[int] = []

    for line in data.lines:
        name = line.name
        if line.kind == "pack_component":
            # ASCII marker: the bundled IBM Plex Arabic font has no `└`
            # glyph, which printed as a blank box position (.notdef).
            name = f"- {name}"
        body.append(
            row(
                [
                    _p(name, BODY, rtl=rtl, align=edge),
                    _fitted(
                        _number(line.unit_price) if line.show_money else "",
                        money_usable,
                        rtl=rtl,
                        align=outer,
                    ),
                    _fitted(line.qty, qty_usable, rtl=rtl, align=outer),
                    _fitted(
                        _number(line.line_total) if line.show_money else "",
                        money_usable,
                        rtl=rtl,
                        align=outer,
                    ),
                ]
            )
        )
        last = len(body) - 1

        meta_bits: list[str] = []
        if line.base_qty:
            meta_bits.append(f"{label('base', locale)}: {line.base_qty} {line.unit_label}")
        elif line.unit_label and line.unit_label.lower() not in _PIECE_WORDS:
            # A selling unit (Box, kg, …) always names itself; a plain
            # piece row stays one compact line.
            meta_bits.append(line.unit_label)
        if meta_bits:
            body.append([_p("   ".join(meta_bits), META, rtl=rtl, align=edge)])
            span_rows.append(len(body) - 1)
            last = len(body) - 1

        if line.line_discount:
            body.append(
                [
                    _p(
                        f"{label('discount', locale)}: {line.line_discount}",
                        META,
                        rtl=rtl,
                        align=edge,
                    )
                ]
            )
            span_rows.append(len(body) - 1)
            last = len(body) - 1

    table = Table(body, colWidths=widths)
    style: list[tuple] = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 1.3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 1.3),
        ("LEFTPADDING", (0, 0), (-1, -1), PAD),
        ("RIGHTPADDING", (0, 0), (-1, -1), PAD),
        # thin separator below the headings
        ("LINEBELOW", (0, 0), (-1, 0), HEADER_RULE, "black"),
    ]
    style += [("SPAN", (0, idx), (-1, idx)) for idx in span_rows]
    # Exactly ONE rule, after the final product/component row: products run
    # continuously, with no per-item separator.
    style.append(("LINEBELOW", (0, last), (-1, last), HAIRLINE, "black"))
    table.setStyle(TableStyle(style))
    return table


def _summary_table(data: DocumentData) -> Flowable | None:
    """Articles → total quantity → gross subtotal (actual `sale.subtotal`)."""
    summary: ReceiptSummary | None = data.receipt
    totals: TotalsBlock | None = data.totals
    if summary is None or totals is None:
        return None
    locale = data.meta.locale  # meta is always set by builders
    rtl = data.rtl
    edge = "right" if rtl else "left"
    outer = "left" if rtl else "right"

    body: list[list[Paragraph]] = []
    spans: list[int] = []
    if summary.article_count:
        body.append(
            [_p(f"{summary.article_count} {label('receipt_articles', locale)}", BODY, rtl=rtl, align=edge)]
        )
        spans.append(len(body) - 1)
    if summary.total_qty:
        unit = summary.qty_unit or label("receipt_units_pcs", locale)
        body.append([_p(f"{summary.total_qty} {unit}", BODY, rtl=rtl, align=edge)])
        spans.append(len(body) - 1)

    body.append(
        [
            _p(label("subtotal", locale), BODY, rtl=rtl, bold=True, align=edge),
            _fitted(
                totals.subtotal,
                CONTENT_WIDTH * 0.42 - 2 * PAD,
                rtl=rtl,
                bold=True,
                align=outer,
            ),
        ]
    )
    total_row = len(body) - 1

    table = Table(body, colWidths=[CONTENT_WIDTH * 0.58, CONTENT_WIDTH * 0.42])
    style: list[tuple] = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 1.2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2),
        ("LEFTPADDING", (0, 0), (-1, -1), PAD),
        ("RIGHTPADDING", (0, 0), (-1, -1), PAD),
    ]
    style += [("SPAN", (0, idx), (-1, idx)) for idx in spans]
    style += [
        ("LINEABOVE", (0, total_row), (-1, total_row), HAIRLINE, "black"),
    ]
    table.setStyle(TableStyle(style))
    return table


def _discount_line(data: DocumentData) -> Flowable | None:
    summary = data.receipt
    if summary is None or not summary.total_discount:
        return None
    locale = data.meta.locale
    rtl = data.rtl
    edge = "right" if rtl else "left"
    outer = "left" if rtl else "right"
    body = [
        [
            _p(f"{label('discount', locale)} :", BODY, rtl=rtl, align=edge),
            _fitted(
                summary.total_discount,
                CONTENT_WIDTH * 0.42 - 2 * PAD,
                rtl=rtl,
                align=outer,
            ),
        ]
    ]
    if rtl:
        body = [list(reversed(body[0]))]
    table = Table(body, colWidths=[CONTENT_WIDTH * 0.58, CONTENT_WIDTH * 0.42])
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("TOPPADDING", (0, 0), (-1, -1), 1.2),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2),
                ("LEFTPADDING", (0, 0), (-1, -1), PAD),
                ("RIGHTPADDING", (0, 0), (-1, -1), PAD),
            ]
        )
    )
    return table


def _payment_box(data: DocumentData) -> Flowable | None:
    """Reçu / Total / Rendu in a thin rounded box.

    `Reçu` is ``totals.paid`` and `Total` is ``totals.total`` — the sale's
    own accounting values.  `Rendu` is printed only when the sale actually
    took cash AND a change exists, so a card, credit or mixed-card sale
    never shows a cash change it did not give.
    """
    totals: TotalsBlock | None = data.totals
    summary: ReceiptSummary | None = data.receipt
    if totals is None or summary is None:
        return None
    locale = data.meta.locale
    rtl = data.rtl
    edge = "right" if rtl else "left"
    outer = "left" if rtl else "right"
    usable = CONTENT_WIDTH * 0.45 - 2 * PAD

    rows: list[tuple[str, str, bool]] = []
    # `totals.paid` is the sale's own `paid` value: the cash the customer
    # actually tendered (the server derives `change` from it).  A zero
    # amount (credit sale) prints no received row at all.
    if totals.paid and _number(totals.paid).strip("0 .,"):
        rows.append((label("receipt_received", locale), totals.paid, False))
    rows.append((label("total", locale), totals.total, True))
    if summary.cash_payment and totals.change and _number(totals.change).strip("0 .,") != "":
        rows.append((label("change", locale), totals.change, False))

    body: list[list[Paragraph]] = []
    for name, value, bold in rows:
        cells = [
            _p(name, BODY, rtl=rtl, bold=bold, align=edge),
            _fitted(value, usable, rtl=rtl, bold=bold, align=outer),
        ]
        body.append(list(reversed(cells)) if rtl else cells)

    table = Table(body, colWidths=[CONTENT_WIDTH * 0.55, CONTENT_WIDTH * 0.45])
    table.hAlign = "CENTER"
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("BOX", (0, 0), (-1, -1), 0.8, "black"),
                ("ROUNDEDCORNERS", [2.5, 2.5, 2.5, 2.5]),
                ("TOPPADDING", (0, 0), (-1, -1), 2.4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.4),
                ("LEFTPADDING", (0, 0), (-1, -1), 3.0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 3.0),
            ]
        )
    )
    return table


def _void_banner(data: DocumentData) -> Flowable | None:
    if not data.header.is_void:
        return None
    locale = data.meta.locale
    rtl = data.rtl
    parts = [label("status_void", locale)]
    if data.header.void_reason:
        parts.append(f"{label('col_void_reason', locale)}: {data.header.void_reason}")
    cell = _p(" | ".join(parts), BODY, rtl=rtl, bold=True, align="center")
    table = Table([[cell]], colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 1.0, "black"),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
            ]
        )
    )
    return table


def build_flowables(data: DocumentData) -> list[Flowable]:
    """Receipt story: identity → stamp → items → summary → payment → footer."""
    locale = data.meta.locale  # meta is always set by builders
    rtl = data.rtl
    summary = data.receipt
    story: list[Flowable] = []

    story.append(
        _p(data.store.name, STORE_NAME, rtl=rtl, bold=True, align="center")
    )
    if data.store.phone:
        story.append(_p(data.store.phone, STORE_CONTACT, rtl=rtl, align="center"))
    if data.store.address:
        story.append(
            _p(data.store.address, STORE_CONTACT, rtl=rtl, align="center")
        )
    story.append(Spacer(1, 1.2 * mm))

    if summary is not None and summary.stamp:
        story.append(_p(summary.stamp, STAMP, rtl=rtl, align="center"))
    if data.customer is not None and data.customer.name:
        story.append(
            _p(
                f"{label(data.customer.label_key, locale)}: {data.customer.name}",
                STORE_CONTACT,
                rtl=rtl,
            )
        )

    banner = _void_banner(data)
    if banner is not None:
        story.append(Spacer(1, 1.5 * mm))
        story.append(banner)

    story.append(Spacer(1, 2 * mm))
    items = _items_table(data)
    if items is not None:
        story.append(items)

    story.append(Spacer(1, 2 * mm))
    totals = _summary_table(data)
    if totals is not None:
        story.append(totals)

    discount = _discount_line(data)
    if discount is not None:
        story.append(discount)

    if summary is not None and summary.cashier:
        story.append(Spacer(1, 0.8 * mm))
        story.append(
            _p(
                f"{label('receipt_cashier_by', locale)} : {summary.cashier}",
                BODY,
                rtl=rtl,
            )
        )

    box = _payment_box(data)
    if box is not None:
        story.append(Spacer(1, 2.5 * mm))
        story.append(box)

    if data.meta.note:
        story.append(Spacer(1, 1.5 * mm))
        story.append(_p(f"{label('note', locale)}: {data.meta.note}", META, rtl=rtl))

    story.append(Spacer(1, 3 * mm))
    if data.store.footer:
        # The closing message is the text configured in Settings
        # (`invoice_footer`) — the receipt never substitutes its own
        # thank-you wording for a configured one.
        story.append(_p(data.store.footer, FOOTER, rtl=rtl, align="center"))
    else:
        # No configured message → the built-in default block, unchanged.
        story.append(
            _p(label("receipt_thanks_ar", locale), FOOTER, rtl=True, align="center")
        )
        story.append(Spacer(1, 0.8 * mm))
        story.append(
            _p(
                label("receipt_thanks_fr", locale),
                FOOTER_SECONDARY,
                rtl=rtl,
                align="center",
            )
        )
    story.append(Spacer(1, 0.8 * mm))
    story.append(
        _p(label("receipt_keep_ticket", locale), NOTICE, rtl=rtl, align="center")
    )
    return story


def estimate_height(data: DocumentData) -> float:
    """Content-driven roll segment (min 140mm, max 400mm) for this layout.

    MEASURED from the real story instead of budgeted from constants: the
    closing block sits at the very end, and a constant estimate that came
    up a few points short pushed it onto a second 80mm page (a receipt must
    never hand the till a blank tail page).
    """
    total = float(sum(5 * mm for _ in (0, 1)))  # top + bottom margin
    for flowable in build_flowables(data):
        _width, height = flowable.wrap(CONTENT_WIDTH, 400 * mm)
        total += height
    # `SimpleDocTemplate` builds its frame with reportlab's default 6pt
    # padding on both edges — budget it plus a hairline of slack.
    total += 4.5 * mm
    return max(140.0, min(400.0, total / mm)) * mm
