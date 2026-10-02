"""Generic report table → PDF story (Phase 15 §9.1).

Consumes already-localized, already-formatted strings (the export
contract produces them). Owns presentation only: store/title/meta
header, one or more tables (financial is sectioned), totals rows and
the empty-state message. Page numbering ("store · page N of M") is
applied by `render.py` via NumberedCanvas.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.platypus import Flowable, Paragraph, Spacer, Table, TableStyle

from app.printing.styles import paragraph_style
from app.printing.text import shape_text

HAIRLINE = 0.6


@dataclass
class ReportTableBlock:
    headers: list[str]
    rows: list[list[str]]
    totals: list[str] | None = None


@dataclass
class ReportTableInput:
    title: str
    store_name: str
    meta_lines: list[str]
    blocks: list[ReportTableBlock] = field(default_factory=list)
    landscape: bool = False
    rtl: bool = False
    locale: str = "en"
    generated_at: str = ""
    empty_message: str = ""


def _p(text: str, size: float, rtl: bool, *, bold: bool = False, align: str = "left") -> Paragraph:
    style = paragraph_style(
        f"rrep-{size}-{bold}-{align}-{rtl}",
        size=size,
        leading=size * 1.25,
        rtl=rtl,
        bold=bold,
        align=align,
    )
    return Paragraph(shape_text(text), style)


def _column_widths(headers: list[str], rows: list[list[str]], total_width: float) -> list[float]:
    """Proportional widths from content length, clamped 8 %–35 % each."""
    columns = len(headers)
    if columns == 0:
        return []
    lengths = []
    for index in range(columns):
        longest = len(headers[index])
        for row in rows:
            if index < len(row):
                longest = max(longest, len(row[index]))
        lengths.append(max(1, longest))
    raw = [total_width * length / sum(lengths) for length in lengths]
    lo, hi = total_width * 0.08, total_width * 0.35
    clamped = [max(lo, min(hi, value)) for value in raw]
    scale = total_width / sum(clamped)
    return [value * scale for value in clamped]


def _block_table(block: ReportTableBlock, *, rtl: bool, content_width: float) -> Table:
    header = [_p(text, 9, rtl, bold=True, align="center") for text in block.headers]
    body = [header if not rtl else list(reversed(header))]
    for row in block.rows:
        cells = [_p(str(cell), 8.5, rtl) for cell in row]
        body.append(cells if not rtl else list(reversed(cells)))
    totals_index = None
    if block.totals is not None:
        cells = [_p(str(cell), 9, rtl, bold=True) for cell in block.totals]
        body.append(cells if not rtl else list(reversed(cells)))
        totals_index = len(body) - 1

    widths = _column_widths(block.headers, block.rows, content_width)
    if rtl:
        widths = list(reversed(widths))
    table = Table(body, colWidths=widths, repeatRows=1)

    style = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eeeeee")),
        ("GRID", (0, 0), (-1, -1), HAIRLINE, colors.grey),
        ("BOX", (0, 0), (-1, -1), 0.9, colors.black),
        ("TOPPADDING", (0, 0), (-1, -1), 2),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
        ("LEFTPADDING", (0, 0), (-1, -1), 3),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3),
    ]
    if totals_index is not None:
        style.append(("LINEABOVE", (0, totals_index), (-1, totals_index), 1.0, colors.black))
    table.setStyle(TableStyle(style))
    return table


def build_flowables(inp: ReportTableInput) -> list[Flowable]:
    """Report story: store → title → meta → tables (or empty message)."""
    rtl = inp.rtl
    content_width = 267 * mm if inp.landscape else 180 * mm
    story: list[Flowable] = []

    story.append(_p(inp.store_name, 10, rtl, bold=True, align="center"))
    story.append(_p(inp.title, 14, rtl, bold=True, align="center"))
    story.append(Spacer(1, 2 * mm))
    for line in inp.meta_lines:
        story.append(_p(line, 9, rtl))
    if inp.generated_at:
        story.append(_p(inp.generated_at, 9, rtl))
    story.append(Spacer(1, 3 * mm))

    has_rows = any(block.rows for block in inp.blocks)
    has_totals = any(block.totals is not None for block in inp.blocks)
    if not has_rows and not has_totals:
        if inp.empty_message:
            story.append(_p(inp.empty_message, 11, rtl, align="center"))
        return story

    for index, block in enumerate(inp.blocks):
        if not block.headers:
            continue
        if index > 0:
            story.append(Spacer(1, 4 * mm))
        if not block.rows and block.totals is None:
            continue
        story.append(_block_table(block, rtl=rtl, content_width=content_width))

    return story
