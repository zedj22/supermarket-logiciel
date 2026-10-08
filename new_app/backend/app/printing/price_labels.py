"""Product price / barcode label rendering (barcode-label subphase).

A physical grid of adhesive labels on an A4 sheet, an 80 mm roll
segment or an adhesive roll (`paper="roll"`: one label across the
media, stacked top-down with the configured gap, the document exactly
as tall as the job): store identity, product name, the EFFECTIVE price
(promotion price when an active promotion applies, retail otherwise —
resolved by the caller) and the product's own Code128 barcode printed
VERBATIM with its human-readable value underneath. A product without a
barcode simply gets no barcode block — a barcode is never invented.

Retail hierarchy per label (top -> bottom): tiny store line, product
name (max 2 lines, ellipsized), price block, barcode. A promotional
label stacks the untouched retail price struck through ABOVE the
dominant promo price, with the promotion's declared percent shown as a
small `20% OFF` badge on the free end of the price line; every gap is
budgeted from the label height so nothing ever overlaps or clips.

DB-free like the other builders (G19): `PrintService.render_labels`
resolves products, promotions and store identity, then calls
`render_price_labels`. Reuses the Phase 15 font registration, `shape_text`
Arabic pipeline and the shared `label()` / `format_money()` helpers, so
receipts and labels speak the same visual language.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from decimal import Decimal

from reportlab.graphics.barcode.code128 import Code128
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen import canvas

from app.printing.fonts import FONT_BOLD, FONT_REGULAR, register_fonts
from app.printing.labels import is_rtl, label
from app.printing.text import format_money, shape_text
from app.schemas.export import (
    A4_HEIGHT_MM,
    A4_WIDTH_MM,
    ROLL_DEFAULT_HEIGHT_MM,
    ROLL_WIDTH_MM,
)

# Inner padding inside one label (pt).
_PAD = 3.0

# Vertical budget helpers (pt, scaled by label height where noted).
_STORE_SIZE = 5.0
_STORE_H = 7.0
_NAME_SIZE = 7.2
_NAME_LINE = 8.8
_NAME_BASE = 2.0  # name-zone bottom -> lowest baseline (descender room)
_NAME_TOP = 6.0  # top baseline -> glyph-top reserve
_RETAIL_SIZE = 6.5
_RETAIL_BASE = 3.0  # price-zone top -> struck-retail baseline
_RETAIL_TO_NAME = 8.0  # struck-retail baseline -> name-zone bottom
_PRICE_MIN = 9.0
_PRICE_MAX = 15.0
_PRICE_RATIO = 0.15
_PRICE_GAP = 3.5  # barcode top -> price baseline (descender clearance)
_PRICE_TOP = 2.0  # price baseline -> price-zone top
_BADGE_SIZE = 6.0
_DIGITS_SIZE = 6.5
_DIGITS_H = 8.0

_COLOR_NAME = (0.0, 0.0, 0.0)
_COLOR_MUTED = (0.45, 0.45, 0.45)
_COLOR_PROMO = (0.72, 0.09, 0.09)
_COLOR_BARCODE = (0.0, 0.0, 0.0)

_UNITS_WITH_SUFFIX = (
    "box",
    "carton",
    "kg",
    "gram",
    "liter",
    "milliliter",
    "meter",
    "pack",
)


@dataclass(frozen=True)
class _VProfile:
    """Vertical gap profile for one budget stage.

    `normal` is the presentation profile; `tight` is the last-resort
    profile (shorter bars, denser gaps) that keeps the struck retail
    price visible on the schema-minimum label where `normal` cannot
    fit it vertically.
    """

    price_gap: float
    price_top: float
    retail_base: float
    retail_to_name: float
    name_base: float
    name_top: float
    bars_cap: float | None = None

    def bars(self, full: float) -> float:
        return full if self.bars_cap is None else min(full, self.bars_cap)


_NORMAL_PROFILE = _VProfile(
    price_gap=_PRICE_GAP,
    price_top=_PRICE_TOP,
    retail_base=_RETAIL_BASE,
    retail_to_name=_RETAIL_TO_NAME,
    name_base=_NAME_BASE,
    name_top=_NAME_TOP,
)
_TIGHT_PROFILE = _VProfile(
    price_gap=2.5,
    price_top=1.5,
    retail_base=2.5,
    retail_to_name=7.0,
    name_base=1.5,
    name_top=5.0,
    bars_cap=11.0,
)


def _needed(
    profile: _VProfile,
    price_size: float,
    bars_h: float,
    *,
    store: bool,
    name_lines: int,
    stacked: bool,
) -> float:
    """Height reserved by one stage, measured bottom -> top (pt)."""
    barcode_block = (profile.bars(bars_h) + _DIGITS_H) if bars_h else 0.0
    price_zone = profile.price_gap + price_size + profile.price_top
    retail_zone = (
        profile.retail_base + profile.retail_to_name if stacked else 0.0
    )
    name_zone = (
        profile.name_base + (name_lines - 1) * _NAME_LINE + profile.name_top
    )
    return (
        barcode_block
        + price_zone
        + retail_zone
        + name_zone
        + ((_STORE_H + 1) if store else 0)
    )


@dataclass(frozen=True)
class PriceLabel:
    """One resolved label row (effective price already computed).

    `discount_percent` is PRESENTATION data only: the percentage a
    percentage promotion already declares (rendered as a small
    `20% OFF` badge) — never a computed discount.
    """

    name: str
    barcode: str | None
    retail: Decimal
    price: Decimal
    promo: bool
    unit: str
    store_name: str
    discount_percent: str | None = None


@dataclass(frozen=True)
class LabelSheet:
    """Computed grid geometry, all values in points."""

    page_width: float
    page_height: float
    cols: int
    rows: int
    label_w: float
    label_h: float
    gap_x: float
    gap_y: float
    margin_x: float
    margin_y: float

    @property
    def per_page(self) -> int:
        return self.cols * self.rows


def _fit(extent: float, margin: float, size: float, gap: float) -> int:
    """How many items of `size` fit in `extent` between two margins."""
    usable = extent - 2 * margin
    if size <= 0:
        return 1
    return max(1, int((usable + gap) // (size + gap)))


def compute_sheet(layout, paper: str, label_count: int = 1) -> LabelSheet:  # noqa: ANN001 - LabelLayout
    """Resolve auto cols/rows against the chosen paper (schema already
    validated every explicit value, so the auto-fit is always >= 1).

    `label_count` is only consulted for the adhesive roll paper: the
    roll document is exactly one label across and as tall as the job
    (labels + gaps + top margin), with no fixed page boundaries.
    """
    label_w = layout.label_width_mm * mm
    label_h = layout.label_height_mm * mm
    gap_x = layout.gap_x_mm * mm
    gap_y = layout.gap_y_mm * mm
    margin_x = layout.margin_x_mm * mm
    margin_y = layout.margin_y_mm * mm

    if paper == "A4":
        page_w = A4_WIDTH_MM * mm
        page_h = A4_HEIGHT_MM * mm
    elif paper == "roll":
        # Adhesive roll labels: ONE label across the media, stacked
        # top-down with the configured vertical gap. The page IS the
        # roll content — width = media width, height = top margin +
        # every label + every gap (schema validated margins + label
        # fit the width). columns/rows never apply here.
        rows = max(1, label_count)
        return LabelSheet(
            page_width=layout.roll_width_mm * mm,
            page_height=(
                layout.margin_top_mm * mm
                + rows * label_h
                + max(0, rows - 1) * gap_y
            ),
            cols=1,
            rows=rows,
            label_w=label_w,
            label_h=label_h,
            gap_x=gap_x,
            gap_y=gap_y,
            margin_x=layout.margin_left_mm * mm,
            margin_y=layout.margin_top_mm * mm,
        )
    else:
        # 80 mm roll: width is the media, height is either pinned by the
        # requested row count (page breaks every `rows`) or defaults to
        # an A4-length segment so labels paginate predictably.
        page_w = ROLL_WIDTH_MM * mm
        if layout.rows is not None:
            page_h = (
                2 * margin_y
                + layout.rows * label_h
                + (layout.rows - 1) * gap_y
            )
        else:
            page_h = ROLL_DEFAULT_HEIGHT_MM * mm

    cols = (
        layout.columns
        if layout.columns is not None
        else _fit(page_w, margin_x, label_w, gap_x)
    )
    rows = (
        layout.rows
        if layout.rows is not None
        else _fit(page_h, margin_y, label_h, gap_y)
    )
    return LabelSheet(
        page_width=page_w,
        page_height=page_h,
        cols=cols,
        rows=rows,
        label_w=label_w,
        label_h=label_h,
        gap_x=gap_x,
        gap_y=gap_y,
        margin_x=margin_x,
        margin_y=margin_y,
    )


# ---------------------------------------------------------------------------
# Text helpers (logical-space ellipsis + wrap, shape AFTER truncation)
# ---------------------------------------------------------------------------


def _width(text: str, font: str, size: float) -> float:
    return stringWidth(text, font, size)


def _measure(text: str, font: str, size: float) -> float:
    """Width of the SHAPED text (Arabic reshaping changes glyph widths)."""
    return _width(shape_text(text), font, size)


def _ellipsize(text: str, font: str, size: float, max_w: float) -> str:
    """Truncate the LOGICAL text so its shaped width fits `max_w`.

    Truncating before `shape_text` keeps RTL ellipsis placement correct
    (the mark lands at the logical end = visual start of the remainder).
    """
    if max_w <= 0:
        return ""
    if _measure(text, font, size) <= max_w:
        return text
    lo, hi = 0, len(text)
    best = "\u2026"
    while lo <= hi:
        mid = (lo + hi) // 2
        candidate = text[:mid].rstrip() + "\u2026"
        if _measure(candidate, font, size) <= max_w:
            best = candidate
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def _wrap(text: str, font: str, size: float, max_w: float, max_lines: int) -> list[str]:
    """Greedy word wrap on the logical text; last line ellipsized."""
    words = text.split()
    if not words:
        return []
    lines: list[str] = []
    current = ""
    overflow = False
    for word in words:
        candidate = f"{current} {word}".strip()
        if not current or _measure(candidate, font, size) <= max_w:
            current = candidate
        else:
            lines.append(current)
            current = word
            if len(lines) >= max_lines:
                overflow = True
                break
    if not overflow and current:
        lines.append(current)
    elif overflow and current:
        # leftover word dropped — mark the previous line as truncated
        lines[-1] = lines[-1] + "\u2026"
    lines = lines[:max_lines]
    return [_ellipsize(line, font, size, max_w) for line in lines]


# ---------------------------------------------------------------------------
# Label body
# ---------------------------------------------------------------------------


def _price_text(data: PriceLabel, locale: str) -> str:
    text = format_money(data.price)
    if data.unit and data.unit != "piece" and data.unit in _UNITS_WITH_SUFFIX:
        unit = label(f"unit_{data.unit}", locale)
        text = f"{text} / {unit}"
    return text


def _badge_text(percent: str, locale: str) -> str:
    """`20% OFF` (LTR) / `خصم 20%` (RTL) from the declared percent."""
    word = label("label_off", locale)
    return f"{word} {percent}%" if is_rtl(locale) else f"{percent}% {word}"


def _draw_barcode_block(
    c: canvas.Canvas,
    barcode: str,
    x: float,
    y: float,
    width: float,
    bars_h: float,
) -> float:
    """Draw Code128 bars scaled to `width`; returns total block height."""
    probe = Code128(barcode, barWidth=1.0, barHeight=bars_h, humanReadable=0)
    scale = max(0.1, width / probe.width) if probe.width else 1.0
    bars = Code128(barcode, barWidth=scale, barHeight=bars_h, humanReadable=0)
    actual = bars.width
    bx = x + max(0.0, (width - actual) / 2)
    c.setFillColorRGB(*_COLOR_BARCODE)
    bars.drawOn(c, bx, y + _DIGITS_H)

    digits = shape_text(barcode)  # ASCII passthrough — stays LTR (§17 A8)
    c.setFont(FONT_REGULAR, _DIGITS_SIZE)
    dw = c.stringWidth(digits, FONT_REGULAR, _DIGITS_SIZE)
    c.drawString(x + max(0.0, (width - dw) / 2), y, digits)
    return bars_h + _DIGITS_H


def _draw_label(
    c: canvas.Canvas,
    data: PriceLabel,
    x: float,
    y: float,
    w: float,
    h: float,
    locale: str,
    rtl: bool,
) -> None:
    inner_x0 = x + _PAD
    inner_x1 = x + w - _PAD
    inner_w = w - 2 * _PAD
    bottom = y + _PAD
    top = y + h - _PAD
    usable = top - bottom

    price_size = min(_PRICE_MAX, max(_PRICE_MIN, h * _PRICE_RATIO))
    bars_full = min(22.0, max(11.0, h * 0.30)) if data.barcode else 0.0

    retail_on = data.promo and data.retail != data.price
    price_text = _price_text(data, locale)
    price_w = _measure(price_text, FONT_BOLD, price_size)
    retail_w = _measure(
        format_money(data.retail), FONT_REGULAR, _RETAIL_SIZE
    )
    inline_ok = price_w + 4 + retail_w <= inner_w

    wrapped = _wrap(data.name, FONT_BOLD, _NAME_SIZE, inner_w, 2)
    n_max = max(1, len(wrapped))

    # Stage ladder: normal+stacked promo block (preferred presentation)
    # -> normal+inline retail (mid heights) -> tight profile with
    # shorter bars (keeps the struck retail visible even on the
    # schema-minimum label). Within a stage the store line is
    # sacrificed first, then the second name line (name outranks
    # store). Picking the FIRST fitting stage guarantees no overlap
    # at any schema-allowed size.
    if retail_on:
        modes: list[tuple[_VProfile, bool]] = [
            (_NORMAL_PROFILE, True),
            (_NORMAL_PROFILE, False),
            (_TIGHT_PROFILE, True),
        ]
    else:
        modes = [(_NORMAL_PROFILE, False)]

    line_stages = [(True, n_max), (False, n_max)]
    if n_max > 1:
        line_stages.append((False, n_max - 1))

    chosen: tuple[_VProfile, bool, bool, int] | None = None
    for profile, stacked in modes:
        if not stacked and retail_on and not inline_ok:
            continue
        for store_flag, lines in line_stages:
            if (
                _needed(
                    profile,
                    price_size,
                    bars_full,
                    store=store_flag,
                    name_lines=lines,
                    stacked=stacked,
                )
                <= usable
            ):
                chosen = (profile, stacked, store_flag, lines)
                break
        if chosen is not None:
            break
    if chosen is None:  # pragma: no cover - ladder covers schema minimums
        chosen = (_TIGHT_PROFILE, retail_on, False, 1)
    profile, stacked, show_store, name_lines = chosen

    name_lines_drawn = _wrap(
        data.name, FONT_BOLD, _NAME_SIZE, inner_w, name_lines
    )

    if data.barcode:
        # Barcode pinned to the bottom; price + name stack above it.
        cursor = bottom
    else:
        # No barcode: flow top-down from the store line instead of
        # hugging the bottom edge (the ladder already guaranteed the
        # block fits, so this never drops below `bottom`).
        block = (
            profile.price_gap
            + price_size
            + profile.price_top
            + (profile.retail_base + profile.retail_to_name if stacked else 0.0)
            + profile.name_base
            + max(0, len(name_lines_drawn) - 1) * _NAME_LINE
            + profile.name_top
        )
        below_store = (_STORE_H + 1) if show_store else 0
        cursor = max(bottom, top - below_store - block)

    c.saveState()

    # Store identity — tiny, muted, at the very top (lowest priority:
    # first to go when the budget tightens).
    if show_store:
        store = _ellipsize(data.store_name, FONT_REGULAR, _STORE_SIZE, inner_w)
        shaped = shape_text(store)
        sx = inner_x1 - c.stringWidth(shaped, FONT_REGULAR, _STORE_SIZE) if rtl else inner_x0
        c.setFillColorRGB(*_COLOR_MUTED)
        c.setFont(FONT_REGULAR, _STORE_SIZE)
        c.drawString(sx, top - _STORE_SIZE, shaped)

    # Barcode block pinned to the bottom (bars above, digits below).
    if data.barcode:
        bars_h = profile.bars(bars_full)
        _draw_barcode_block(c, data.barcode, inner_x0, cursor, inner_w, bars_h)
        cursor += bars_h + _DIGITS_H

    # Price line above the barcode — the strongest element: bold, at
    # the largest size, red only when a promotion applies.
    price_shaped = shape_text(price_text)
    pw = c.stringWidth(price_shaped, FONT_BOLD, price_size)
    px = inner_x1 - pw if rtl else inner_x0
    c.setFillColorRGB(*(_COLOR_PROMO if data.promo else _COLOR_NAME))
    c.setFont(FONT_BOLD, price_size)
    price_y = cursor + profile.price_gap
    c.drawString(px, price_y, price_shaped)
    cursor = price_y + price_size + profile.price_top

    # Declared percent badge on the free end of the price line — only
    # when the struck retail owns the line above it (never crowds the
    # price or the inline retail).
    if data.discount_percent and stacked:
        badge_shaped = shape_text(_badge_text(data.discount_percent, locale))
        bw = c.stringWidth(badge_shaped, FONT_BOLD, _BADGE_SIZE)
        if rtl:
            bx = px - 4 - bw
            fits = bx >= inner_x0
        else:
            bx = px + pw + 4
            fits = bx + bw <= inner_x1
        if fits:
            c.setFillColorRGB(*_COLOR_PROMO)
            c.setFont(FONT_BOLD, _BADGE_SIZE)
            c.drawString(bx, price_y, badge_shaped)

    # The untouched retail price, struck through. Stacked above the
    # promo price when the budget allows (spec presentation), beside
    # it on tighter mid-size labels.
    if retail_on:
        retail_shaped = shape_text(format_money(data.retail))
        rw = c.stringWidth(retail_shaped, FONT_REGULAR, _RETAIL_SIZE)
        if stacked:
            retail_y = cursor + profile.retail_base
            rx = inner_x1 - rw if rtl else inner_x0
            c.setFillColorRGB(*_COLOR_MUTED)
            c.setFont(FONT_REGULAR, _RETAIL_SIZE)
            c.drawString(rx, retail_y, retail_shaped)
            mid = retail_y + _RETAIL_SIZE * 0.35
            c.setStrokeColorRGB(*_COLOR_MUTED)
            c.setLineWidth(0.6)
            c.line(rx, mid, rx + rw, mid)
            cursor = retail_y + profile.retail_to_name
        else:
            rx = inner_x0 if rtl else inner_x1 - rw
            if (rtl and px - rx >= rw + 4) or (not rtl and rx - px >= pw + 4):
                c.setFillColorRGB(*_COLOR_MUTED)
                c.setFont(FONT_REGULAR, _RETAIL_SIZE)
                c.drawString(rx, price_y + 1, retail_shaped)
                mid = price_y + 1 + _RETAIL_SIZE / 2 - 1
                c.setStrokeColorRGB(*_COLOR_MUTED)
                c.setLineWidth(0.6)
                c.line(rx, mid, rx + rw, mid)

    # Product name above the price — start-aligned (RTL: end-aligned),
    # at most two lines, last line ellipsized before shaping.
    if name_lines_drawn:
        n = len(name_lines_drawn)
        lowest = cursor + profile.name_base
        c.setFillColorRGB(*_COLOR_NAME)
        c.setFont(FONT_BOLD, _NAME_SIZE)
        for idx, line in enumerate(name_lines_drawn):
            shaped = shape_text(line)
            nx = (
                inner_x1 - c.stringWidth(shaped, FONT_BOLD, _NAME_SIZE)
                if rtl
                else inner_x0
            )
            c.drawString(nx, lowest + (n - 1 - idx) * _NAME_LINE, shaped)

    c.restoreState()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def render_price_labels(
    labels: list[PriceLabel],
    layout,  # noqa: ANN001 - LabelLayout
    paper: str,
    locale: str,
    *,
    compress: bool = True,
) -> bytes:
    """Render one PDF with `labels` laid out on the computed grid.

    For `paper="roll"` the grid is a single vertical column and the
    page is exactly the roll content (one physical label per entry,
    gaps between — no A4 pagination).
    """
    register_fonts()
    sheet = compute_sheet(layout, paper, label_count=len(labels))
    rtl = is_rtl(locale)
    buffer = io.BytesIO()
    c = canvas.Canvas(
        buffer,
        pagesize=(sheet.page_width, sheet.page_height),
    )
    c.setTitle("Product labels")
    c.setAuthor("Supermarket POS")
    c.setPageCompression(1 if compress else 0)

    per_page = sheet.per_page
    for index, data in enumerate(labels):
        position = index % per_page
        if index > 0 and position == 0:
            c.showPage()
        col = position % sheet.cols
        row = position // sheet.cols
        x = sheet.margin_x + col * (sheet.label_w + sheet.gap_x)
        y_top = (
            sheet.page_height
            - sheet.margin_y
            - row * (sheet.label_h + sheet.gap_y)
        )
        _draw_label(
            c,
            data,
            x,
            y_top - sheet.label_h,
            sheet.label_w,
            sheet.label_h,
            locale,
            rtl,
        )
    c.save()
    return buffer.getvalue()
