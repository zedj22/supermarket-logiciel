"""XLSX report writer (Phase 15 §5, §10, §17.4).

Consumes an `ExportSpec` (already-localized headers, raw cells, column
kinds) and emits a styled workbook: row 1 merged `<store> — <title>`,
row 2 meta + ISO generated_at, row 4 header (frozen), autofilter on
row-level reports, widths 10–60, Excel number formats from column kinds
(money `0.000`, percent `0.00"%"`), RTL sheet view for Arabic, landscape
print setup with repeating header row, and formula-injection guarding of
**every** string cell (headers/title/meta included). Write-only mode
above ~5 000 rows.
"""

from __future__ import annotations

import io
import re
from datetime import datetime

from openpyxl import Workbook
from openpyxl.cell import WriteOnlyCell
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.properties import PageSetupProperties
from openpyxl.worksheet.worksheet import Worksheet

from app.exporting.contract import ROW_LEVEL_REPORTS, ExportSpec

WRITE_ONLY_THRESHOLD = 5000
SAFE_CHARS = re.compile(r"[\\/*?:\[\]]")
NUMERIC = re.compile(r"^-?\d+$")
NUMERIC_DEC = re.compile(r"^-?\d+\.\d+$")
LEADING_FORMULA = re.compile(r"^[=+\-@\t\r]")

MONEY_FORMAT = "0.000"
PERCENT_FORMAT = '0.00"%"'

_TITLE_FILL = PatternFill("solid", fgColor="DDEBF7")
_HEADER_FILL = PatternFill("solid", fgColor="EEEEEE")
_THIN = Side(style="thin", color="BFBFBF")
_BORDER = Border(left=_THIN, right=_THIN, top=_THIN, bottom=_THIN)


def _typed(value: str):
    """Raw cell → Excel type. Numeric strings become numbers (safe by type);
    any other string matching `^[=+\\-@\\t\\r]` is neutralized (§17.4)."""
    if value == "":
        return None
    if NUMERIC.match(value):
        try:
            return int(value)
        except ValueError:
            return value
    if NUMERIC_DEC.match(value):
        try:
            return float(value)
        except ValueError:
            return value
    if LEADING_FORMULA.match(value):
        return "'" + value
    return value


def _guard(value):
    """Belt-and-braces guard for non-data strings (headers, title, meta)."""
    if isinstance(value, str) and LEADING_FORMULA.match(value):
        return "'" + value
    return value


def _number_format(kind: str) -> str | None:
    if kind == "money":
        return MONEY_FORMAT
    if kind == "percent":
        return PERCENT_FORMAT
    return None


def _sheet_title(title: str) -> str:
    name = SAFE_CHARS.sub("_", title).strip("'") or "report"
    return name[:31]


def _merge_width(widths: list[int], index: int, longest: int) -> list[int]:
    while len(widths) <= index:
        widths.append(10)
    widths[index] = max(widths[index], min(60, max(10, longest + 2)))
    return widths


def _column_widths(spec: ExportSpec) -> list[int]:
    widths: list[int] = []
    for block in spec.blocks:
        for index, header in enumerate(block.headers):
            longest = len(header)
            for row in block.rows:
                if index < len(row):
                    longest = max(longest, len(row[index]))
            if block.totals and index < len(block.totals):
                longest = max(longest, len(block.totals[index]))
            widths = _merge_width(widths, index, longest)
    return widths


def _style_normal(ws: Worksheet, last_col: int, header_row: int) -> None:
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=max(1, last_col))
    ws.merge_cells(start_row=2, start_column=1, end_row=2, end_column=max(1, last_col))
    ws.cell(row=1, column=1).font = Font(bold=True, size=14)
    ws.cell(row=1, column=1).fill = _TITLE_FILL
    ws.cell(row=1, column=1).alignment = Alignment(horizontal="center")
    ws.cell(row=2, column=1).font = Font(size=9, italic=True)
    for cell in ws[header_row]:
        if cell.column > last_col:
            break
        cell.font = Font(bold=True)
        cell.fill = _HEADER_FILL
        cell.border = _BORDER
        cell.alignment = Alignment(horizontal="center", wrap_text=True, vertical="center")
    for row in ws.iter_rows(min_row=header_row + 1, max_row=ws.max_row, max_col=last_col):
        for cell in row:
            cell.border = _BORDER


def _write_row_normal(
    ws: Worksheet, row_index: int, values: list[str], kinds: list[str]
) -> None:
    for col, text in enumerate(values, start=1):
        typed = _typed(text)
        cell = ws.cell(row=row_index, column=col, value=typed)
        kind = kinds[col - 1] if col - 1 < len(kinds) else "text"
        if isinstance(typed, (int, float)):
            fmt = _number_format(kind)
            if fmt:
                cell.number_format = fmt


def _write_row_write_only(ws, values: list[str], kinds: list[str]) -> None:
    out = []
    for col, text in enumerate(values, start=1):
        typed = _typed(text)
        cell = WriteOnlyCell(ws, value=typed)
        kind = kinds[col - 1] if col - 1 < len(kinds) else "text"
        if isinstance(typed, (int, float)):
            fmt = _number_format(kind)
            if fmt:
                cell.number_format = fmt
        out.append(cell)
    ws.append(out)


def render_xlsx(spec: ExportSpec, *, generated_at: datetime | None = None) -> bytes:
    """Build the workbook bytes for `spec`."""
    iso_stamp = (generated_at or datetime.utcnow()).isoformat(timespec="seconds")
    total_cols = max((len(b.headers) for b in spec.blocks), default=1)
    rows_total = sum(len(b.rows) + (1 if b.totals else 0) for b in spec.blocks)
    write_only = rows_total > WRITE_ONLY_THRESHOLD
    title_text = f"{spec.store_name} — {spec.title}"
    meta_text = " | ".join([*spec.meta_lines, f"generated_at: {iso_stamp}"])

    if write_only:
        wb = Workbook(write_only=True)
        ws = wb.create_sheet(title=_sheet_title(spec.title))
        # sheetViews are flushed on the first append — freeze/RTL first.
        ws.freeze_panes = "A5"
        if spec.locale == "ar":
            ws.sheet_view.rightToLeft = True
        title_cell = WriteOnlyCell(ws, value=_guard(title_text))
        title_cell.font = Font(bold=True, size=14)
        ws.append([title_cell])
        ws.append([_guard(meta_text)])
        ws.append([])
        header_row = 4
        first_block = True
        for block in spec.blocks:
            if not first_block:
                ws.append([])
            header_cells = []
            for text in block.headers:
                c = WriteOnlyCell(ws, value=_guard(text))
                c.font = Font(bold=True)
                header_cells.append(c)
            ws.append(header_cells)
            for row in block.rows:
                _write_row_write_only(ws, row, block.kinds)
            if block.totals:
                _write_row_write_only(ws, block.totals, block.kinds)
            first_block = False
        ws.print_title_rows = "4:4"
        if spec.report in ROW_LEVEL_REPORTS:
            # Same §10.1 autofilter as the normal path (one block for
            # row-level reports; rows_total includes its totals row).
            ws.auto_filter.ref = (
                f"A4:{get_column_letter(total_cols)}{4 + rows_total}"
            )
    else:
        wb = Workbook()
        ws = wb.active
        ws.title = _sheet_title(spec.title)
        ws.cell(row=1, column=1, value=_guard(title_text))
        ws.cell(row=2, column=1, value=_guard(meta_text))
        row_index = 4
        header_row = 4
        first_block = True
        first_block_end = 4
        for block in spec.blocks:
            if not first_block:
                row_index += 1
            for col, text in enumerate(block.headers, start=1):
                ws.cell(row=row_index, column=col, value=_guard(text))
            if first_block:
                header_row = row_index
            row_index += 1
            for row in block.rows:
                _write_row_normal(ws, row_index, row, block.kinds)
                row_index += 1
            if first_block:
                first_block_end = row_index - 1
            if block.totals:
                _write_row_normal(ws, row_index, block.totals, block.kinds)
                row_index += 1
            first_block = False

        widths = _column_widths(spec)
        for index, width in enumerate(widths, start=1):
            ws.column_dimensions[get_column_letter(index)].width = width
        _style_normal(ws, total_cols, header_row)
        ws.freeze_panes = ws.cell(row=header_row + 1, column=1)
        if spec.report in ROW_LEVEL_REPORTS:
            # Autofilter only on row-level reports (§10.1), first block only.
            ws.auto_filter.ref = (
                f"A{header_row}:{get_column_letter(total_cols)}{first_block_end}"
            )
        if spec.locale == "ar":
            ws.sheet_view.rightToLeft = True
        # Print setup surface is missing on write-only worksheets.
        ws.sheet_properties.pageSetUpPr = PageSetupProperties(fitToPage=True)
        ws.page_setup.orientation = "landscape" if spec.landscape else "portrait"
        ws.page_setup.fitToWidth = 1
        ws.page_setup.fitToHeight = 0
        ws.print_title_rows = f"{header_row}:{header_row}"

    buffer = io.BytesIO()
    wb.save(buffer)
    return buffer.getvalue()
