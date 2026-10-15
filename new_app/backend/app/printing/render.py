"""PDF render entry points (Phase 15 §4.4, §7.6, §9.1, §16).

Single place that owns page geometry, font registration, continuation
headers (80mm) and `store · page N of M` footers (A4 sales invoices /
reports — facturation PDFs opt out, their footer stays blank). Returns
PDF bytes; any unexpected failure is mapped to `PRINT_RENDER_FAILED` /
`EXPORT_RENDER_FAILED` by the calling service. `compress=False` is a
test profile for byte-level Arabic assertions (§19.1).
"""

from __future__ import annotations

import io
from typing import Literal

from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas
from reportlab.platypus import BaseDocTemplate, Frame, PageTemplate, SimpleDocTemplate

from app.printing.document_data import DocumentData
from app.printing.facture_data import FactureData
from app.printing.fonts import register_fonts
from app.printing.labels import is_rtl, label
from app.printing.templates import facture_a4, invoice_80mm, invoice_a4, report_table
from app.printing.templates.report_table import ReportTableInput
from app.printing.text import shape_text

Paper = Literal["80mm", "A4"]

MARGIN_LR_80 = 4 * mm
MARGIN_TB_80 = 5 * mm
MARGIN_LR_A4 = 15 * mm
MARGIN_TB_A4 = 18 * mm
MARGIN_LR_REPORT = 15 * mm
MARGIN_TB_REPORT = 15 * mm


class NumberedCanvas(canvas.Canvas):
    """Canvas that stamps `store · page N of M` on every finished page.

    ``draw_footer=False`` keeps the same page-stamping machinery but
    draws nothing: the bottom footer area stays blank. Facturation A4
    invoices (``render_facture``) opt out via that flag; A4 sales
    invoices and report PDFs keep the default (``True``).
    """

    def __init__(self, *args, **kwargs):
        self._page_label = kwargs.pop("page_label", "Page")
        self._page_rtl = kwargs.pop("page_rtl", False)
        self._footer_prefix = kwargs.pop("footer_prefix", "")
        self._footer_enabled = kwargs.pop("draw_footer", True)
        super().__init__(*args, **kwargs)
        self._saved_page_states: list[dict] = []

    def showPage(self) -> None:  # noqa: N802 - reportlab API
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self) -> None:  # noqa: N802 - reportlab API
        total = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            if self._footer_enabled:
                self._draw_footer(total)
            super().showPage()
        canvas.Canvas.save(self)

    def _draw_footer(self, total: int) -> None:
        parts = []
        if self._footer_prefix:
            parts.append(self._footer_prefix)
        parts.append(f"{self._page_label} {self._pageNumber} / {total}")
        shaped = shape_text("  ·  ".join(parts))
        self.setFont("IBMPlexSansArabic", 8)
        width = self.stringWidth(shaped, "IBMPlexSansArabic", 8)
        x = (self._pagesize[0] - width) / 2
        self.drawString(x, 8, shaped)


def _draw_continuation_header(c: canvas.Canvas, doc, data: DocumentData) -> None:
    """Repeat store identity + document title on 80mm continuation pages."""
    if doc.page <= 1:
        return
    right = c._pagesize[0] - MARGIN_LR_80
    top = c._pagesize[1] - 6
    c.setFont("IBMPlexSansArabic-Bold", 11)
    store = shape_text(data.store.name)
    store_width = c.stringWidth(store, "IBMPlexSansArabic-Bold", 11)
    x = right - store_width if data.rtl else MARGIN_LR_80
    c.drawString(x, top, store)
    c.setFont("IBMPlexSansArabic", 8)
    title = shape_text(data.header.document_title)
    title_width = c.stringWidth(title, "IBMPlexSansArabic", 8)
    x = right - title_width if data.rtl else MARGIN_LR_80
    c.drawString(x, top - 12, title)


def render_invoice(data: DocumentData, paper: Paper, *, compress: bool = True) -> bytes:
    """Render sale/return/purchase document bytes for the given paper."""
    register_fonts()
    buffer = io.BytesIO()
    locale = data.meta.locale  # meta is always set by builders

    if paper == "80mm":
        story = invoice_80mm.build_flowables(data)
        height = invoice_80mm.estimate_height(data)
        doc = SimpleDocTemplate(
            buffer,
            pagesize=(80 * mm, height),
            leftMargin=MARGIN_LR_80,
            rightMargin=MARGIN_LR_80,
            topMargin=MARGIN_TB_80,
            bottomMargin=MARGIN_TB_80,
            title=f"{data.header.document_number} - {data.store.name}",
            author="Supermarket POS",
        )
        doc.pageCompression = 1 if compress else 0
        doc.build(
            story,
            onFirstPage=lambda c, d: None,
            onLaterPages=lambda c, d: _draw_continuation_header(c, d, data),
        )
        return buffer.getvalue()

    story = invoice_a4.build_flowables(data)
    doc = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=MARGIN_LR_A4,
        rightMargin=MARGIN_LR_A4,
        topMargin=MARGIN_TB_A4,
        bottomMargin=MARGIN_TB_A4,
        title=f"{data.header.document_number} - {data.store.name}",
        author="Supermarket POS",
    )
    doc.pageCompression = 1 if compress else 0
    doc.build(
        story,
        canvasmaker=lambda *args, **kwargs: NumberedCanvas(
            *args,
            page_label=label("page", locale),
            page_rtl=is_rtl(locale),
            footer_prefix=data.store.name,
            **kwargs,
        ),
    )
    return buffer.getvalue()


def render_facture(data: FactureData, *, compress: bool = True) -> bytes:
    """Render one facturation document (FAC/DEV/PRO/BC/BL) as A4 bytes.

    Fiscal documents are A4-only (legacy ``pdf_invoice.dart`` and the
    Algeria paper format) — there is deliberately no 80 mm path. The
    footer/page-number stamp is disabled for this path (``draw_footer=
    False``): the bottom footer area stays blank while the bottom-pinned
    ``Signature`` label and the header company block are unchanged. The
    ``compress`` flag is the same test profile ``render_invoice`` /
    ``render_report_pdf`` expose: uncompressed streams let tests assert
    the drawn text byte-for-byte.
    """
    register_fonts()
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        leftMargin=MARGIN_LR_A4,
        rightMargin=MARGIN_LR_A4,
        topMargin=MARGIN_TB_A4,
        bottomMargin=MARGIN_TB_A4,
        title=f"{data.number} - {data.company.name}",
        author="Supermarket POS",
    )
    doc.pageCompression = 1 if compress else 0
    doc.build(
        facture_a4.build_flowables(data),
        canvasmaker=lambda *args, **kwargs: NumberedCanvas(
            *args,
            # Final layout cleanup: no footer at all — neither the
            # company-name prefix nor the `Page N / M` stamp (the
            # seller identity stays in the page header block).
            draw_footer=False,
            **kwargs,
        ),
    )
    return buffer.getvalue()


def render_report_pdf(inp: ReportTableInput, *, compress: bool = True) -> bytes:
    """Render a report (portrait/landscape) with `store · page N of M`."""
    register_fonts()
    buffer = io.BytesIO()
    pagesize = landscape(A4) if inp.landscape else A4
    story = report_table.build_flowables(inp)
    doc = BaseDocTemplate(
        buffer,
        pagesize=pagesize,
        leftMargin=MARGIN_LR_REPORT,
        rightMargin=MARGIN_LR_REPORT,
        topMargin=MARGIN_TB_REPORT,
        bottomMargin=MARGIN_TB_REPORT,
        title=inp.title,
        author="Supermarket POS",
    )
    doc.pageCompression = 1 if compress else 0
    frame = Frame(
        doc.leftMargin,
        doc.bottomMargin,
        doc.width,
        doc.height,
        id="report",
        leftPadding=0,
        rightPadding=0,
        topPadding=0,
        bottomPadding=0,
    )
    doc.addPageTemplates([PageTemplate(id="report", frames=[frame])])
    doc.build(
        story,
        canvasmaker=lambda *args, **kwargs: NumberedCanvas(
            *args,
            page_label=label("page", inp.locale),
            page_rtl=inp.rtl,
            footer_prefix=inp.store_name,
            **kwargs,
        ),
    )
    return buffer.getvalue()
