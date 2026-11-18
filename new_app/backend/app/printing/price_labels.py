"""Product price / barcode label rendering (barcode-label subphase).

Two sheet models:

* **A4 / 80 mm grid** — a physical grid of adhesive labels: `columns`
  labels across, `rows` down, auto-fitted unless pinned.
* **Adhesive roll** (`paper="roll"`) — ONE PDF PAGE PER PHYSICAL LABEL,
  each page exactly the media width × the label height. A label printer
  feeds one label per page, so the page IS the label: a four-label job is
  a four-page document. (The earlier model stacked the whole job into a
  single page as tall as N labels; a 45×35 mm label printer then printed
  page one — one label — and cropped the rest.)

Every label is centred horizontally and vertically inside its printable
area: store identity on top, product name (up to two lines), the
EFFECTIVE price (promotion price when an active promotion applies,
retail otherwise — resolved by the caller), then the product's own
Code128 barcode printed VERBATIM with its human-readable value beneath.
A product without a barcode simply gets no barcode block — a barcode is
never invented. A promotional label keeps the untouched retail struck
through above the effective price, with the promotion's declared percent
(`20% OFF`) on that same small line; every block is measured before it is
drawn, so nothing overlaps or clips at any schema-allowed label size.

Type sizes are expressed for the reference label (45×35 mm — the
Xprinter XP-365B stock, 1.77×1.38 in) and scale with the real label, so a
30×20 mm tag and a 60×40 mm shelf label both stay readable. The selected
dimensions always win: nothing here hardcodes one label size.

DB-free like the other builders (G19): `PrintService.render_labels`
resolves products, promotions and store identity, then calls
`render_price_labels`. Reuses the Phase 15 font registration,
`shape_text` Arabic pipeline and the shared `label()` / `format_money()`
helpers, so receipts and labels speak the same visual language.
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

# Inner padding inside one label (pt) — grows a little with the label but
# never enough to eat the printable width. 3 pt ≈ 1.06 mm.
_PAD_X = 3.0
_PAD_Y = 3.0

# Reference label the type scale is designed against: the XP-365B stock
# (45 mm × 35 mm ≈ 1.77 in × 1.38 in). Every size below is multiplied by
# the label's own scale factor (`_scale_for`).
_REF_WIDTH = 45.0 * mm
_REF_HEIGHT = 35.0 * mm
_SCALE_MIN = 0.45
_SCALE_MAX = 1.5

# Type ramp at scale 1.0 (pt). Store + name are bold and noticeably
# larger than the old 5 pt / 7.2 pt presentation.
_STORE_SIZE = 8.2
_NAME_SIZE = 10.6
_PRICE_SIZE = 14.0
_RETAIL_SIZE = 6.6
_BADGE_SIZE = 6.4
_DIGITS_SIZE = 7.6
_LINE_RATIO = 1.18       # line height / font size for the name block
_ASCENT_RATIO = 0.86     # block top -> first baseline
_GAP = 2.8               # vertical gap between blocks (× scale)

# Barcode block: bars never taller than 26 pt, never shorter than 9 pt.
_BARS_MIN = 9.0
_BARS_MAX = 26.0
_BARS_RATIO = 0.26
# Code128 quiet zone: the symbology asks for 10 modules (~2.5–5 mm).
# ReportLab's own `quiet=1` reserves a fixed 0.25 in (6.35 mm) on EACH
# side, which both wastes width and shifts the bars off the label centre
# — so it is disabled and the zone is budgeted here instead.
_QUIET = 5.0 * mm
# Top inset (paper="roll") never eats more than this share of the label.
_TOP_INSET_RATIO = 0.35

_COLOR_NAME = (0.0, 0.0, 0.0)
_COLOR_MUTED = (0.18, 0.18, 0.18)
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
    # `paper="roll"`: vertical inset inside the (label-sized) page — the
    # configured top margin, clamped. It never changes the page height,
    # because the page already IS the physical label.
    top_inset: float = 0.0

    @property
    def per_page(self) -> int:
        return self.cols * self.rows


def _fit(extent: float, margin: float, size: float, gap: float) -> int:
    """How many items of `size` fit in `extent` between two margins."""
    usable = extent - 2 * margin
    if size <= 0:
        return 1
    return max(1, int((usable + gap) // (size + gap)))


def compute_sheet(layout, paper: str, label_count: int = 1) -> LabelSheet:  # noqa: ANN001
    """Resolve auto cols/rows against the chosen paper (schema already
    validated every explicit value, so the auto-fit is always >= 1).

    `label_count` is accepted for call-site compatibility and no longer
    influences geometry: on an adhesive roll every label gets its own page
    (see the module docstring), so the page is always one label tall and
    the document has exactly `label_count` pages.
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
        # Adhesive roll labels: ONE LABEL PER PAGE, one label across the
        # media. The page is the physical label — never taller — so the
        # printer advances exactly one label per page. The pitch between
        # labels belongs to the printer's stock definition (die-cut gap),
        # not to the PDF page height; `gap_y_mm` therefore no longer
        # stretches the document.
        media_w = layout.roll_width_mm * mm
        left = layout.margin_left_mm * mm
        if layout.margin_left_mm == 0 and layout.margin_right_mm == 0:
            # No liner offsets configured: centre the label in the media
            # instead of hugging the left edge (the page is the media, so
            # this is what keeps a 40 mm label centred on 58 mm stock).
            left = max(0.0, (media_w - label_w) / 2)
        return LabelSheet(
            page_width=media_w,
            page_height=label_h,
            cols=1,
            rows=1,
            label_w=label_w,
            label_h=label_h,
            gap_x=gap_x,
            gap_y=gap_y,
            margin_x=left,
            margin_y=0.0,
            top_inset=min(
                layout.margin_top_mm * mm, label_h * _TOP_INSET_RATIO
            ),
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


def _fit_size(
    text: str,
    font: str,
    size: float,
    max_w: float,
    *,
    floor: float = 4.0,
) -> float:
    """Largest font size at or below `size` whose single line fits `max_w`."""
    cur = size
    while cur > floor and _measure(text, font, cur) > max_w:
        cur *= 0.94
    return cur


def _wrap_fitted(
    text: str,
    font: str,
    size: float,
    max_w: float,
    max_lines: int,
    *,
    floor: float = 4.0,
) -> tuple[float, list[str]]:
    """Wrap at the largest size that needs no ellipsis (or at the floor).

    Long names get a smaller font before they get a `…`: a clean two-line
    name reads better than a bold truncated one, and the barcode below is
    never pushed out of the label.
    """
    cur = size
    lines = _wrap(text, font, cur, max_w, max_lines)
    while cur > floor and (
        len(lines) > max_lines or any(line.endswith("\u2026") for line in lines)
    ):
        cur *= 0.94
        lines = _wrap(text, font, cur, max_w, max_lines)
    return cur, lines


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


def _scale_for(w: float, h: float) -> float:
    """Type scale for this label (1.0 at the 45×35 mm reference)."""
    return max(_SCALE_MIN, min(_SCALE_MAX, min(h / _REF_HEIGHT, w / _REF_WIDTH)))


def _draw_centered(
    c: canvas.Canvas,
    text: str,
    font: str,
    size: float,
    x: float,
    w: float,
    baseline: float,
) -> tuple[float, float, float]:
    """Draw `text` centred in `[x, x + w]`; returns (x, y, width)."""
    shaped = shape_text(text)
    tw = c.stringWidth(shaped, font, size)
    tx = x + max(0.0, (w - tw) / 2)
    c.setFont(font, size)
    c.drawString(tx, baseline, shaped)
    return tx, baseline, tw


def _barcode_scale(barcode: str, width: float, bars_h: float) -> tuple[float, object]:
    """Uniform bar scale that fits `width`; returns (scale, probe).

    Both the bar width and the total width come from one factor, so the
    encoded bar ratios never change — only the physical module width.
    Callers already removed the quiet zones, so no bar touches the edge.
    """
    probe = Code128(
        barcode, barWidth=1.0, barHeight=bars_h, humanReadable=0, quiet=0
    )
    return (max(0.1, width / probe.width) if probe.width else 1.0), probe


def _draw_label(
    c: canvas.Canvas,
    data: PriceLabel,
    x: float,
    y: float,
    w: float,
    h: float,
    locale: str,
    rtl: bool,
    top_inset: float = 0.0,
) -> None:
    pad_x = max(_PAD_X, min(4.5, w * 0.03))
    pad_y = max(_PAD_Y, min(4.5, h * 0.035))
    inner_x0 = x + pad_x
    inner_w = max(10.0, w - 2 * pad_x)
    bottom = y + pad_y
    top = y + h - pad_y - top_inset
    usable = max(12.0, top - bottom)

    scale = _scale_for(w, h)
    retail_on = bool(data.promo and data.retail != data.price)
    has_barcode = bool(data.barcode)
    bars_h = min(_BARS_MAX, max(_BARS_MIN, h * _BARS_RATIO)) if has_barcode else 0.0

    # Gaps inside the stack, in units of `_GAP`: store->name, name->price
    # (0.45 when a struck retail line sits on top of the price), price->
    # barcode. One list so the budget and the drawing cannot drift apart.
    def gaps_for(store: bool) -> float:
        units = 1.0
        if store:
            units += 1.0
        if retail_on:
            units += 0.45
        if has_barcode:
            units += 1.0
        return units

    # ---- choose the richest content that still fits ---------------------
    # Every block is linear in the scale factor except the fixed bar
    # height, so the largest fitting scale is solved directly rather than
    # guessed: shrinking the type is preferred over dropping the store
    # line, and dropping the store line is preferred over losing the
    # second name line.
    def solve(store: bool, lines: int) -> float:
        per_unit = (
            (1.25 * _STORE_SIZE if store else 0.0)
            + lines * _LINE_RATIO * _NAME_SIZE
            + _PRICE_SIZE * 1.22
            + (_RETAIL_SIZE * 1.05 if retail_on else 0.0)
            + (_DIGITS_SIZE * 1.3 if has_barcode else 0.0)
            + _GAP * gaps_for(store)
        )
        if per_unit <= 0:
            return scale
        return (usable - bars_h) / per_unit

    chosen: tuple[bool, int, float] | None = None
    for store, lines in ((True, 2), (True, 1), (False, 2), (False, 1)):
        s = min(scale, solve(store, lines))
        if s < _SCALE_MIN:
            continue
        # A store line that has to shrink under 5 pt is noise, not
        # identity — drop it before stealing size from the name.
        if store and _STORE_SIZE * s < 5.0:
            continue
        if _NAME_SIZE * s < 6.0 and lines > 1:
            continue
        chosen = (store, lines, s)
        break
    if chosen is None:
        chosen = (False, 1, max(_SCALE_MIN * 0.8, min(scale, solve(False, 1))))
    show_store, max_lines, s = chosen

    store_size = _STORE_SIZE * s
    name_size = _NAME_SIZE * s
    price_size = _PRICE_SIZE * s
    retail_size = _RETAIL_SIZE * s
    badge_size = _BADGE_SIZE * s
    digits_size = _DIGITS_SIZE * s
    gap = _GAP * s

    # Long names shrink before they ellipsize (two lines preferred) —
    # but never below 72% of the chosen size: a 4 pt "complete" name is
    # worse than a readable name with a trailing ellipsis.
    name_size, name_lines = _wrap_fitted(
        data.name,
        FONT_BOLD,
        name_size,
        inner_w,
        max_lines,
        floor=max(4.0, name_size * 0.72),
    )
    name_line_h = name_size * _LINE_RATIO

    price_text = _price_text(data, locale)
    price_size = _fit_size(price_text, FONT_BOLD, price_size, inner_w, floor=5.0)
    price_line_h = price_size * 1.22

    store_text = data.store_name if show_store else ""
    if show_store:
        store_size = _fit_size(
            store_text, FONT_BOLD, store_size, inner_w, floor=4.0
        )
        store_text = _ellipsize(store_text, FONT_BOLD, store_size, inner_w)
    store_h = store_size * 1.25 if show_store else 0.0

    retail_h = retail_size * 1.05 if retail_on else 0.0
    digits_h = digits_size * 1.3 if has_barcode else 0.0

    needed = (
        store_h
        + len(name_lines) * name_line_h
        + retail_h
        + price_line_h
        + digits_h
        + bars_h
        + gaps_for(show_store) * gap
    )
    extra = max(0.0, usable - needed)
    gap_units = max(1.0, gaps_for(show_store))
    gap += extra * 0.5 / gap_units
    cursor = top - extra * 0.25  # the remaining half centres the stack

    c.saveState()

    # 1) Store identity — bold, muted, centred on the top line.
    if show_store:
        c.setFillColorRGB(*_COLOR_MUTED)
        _draw_centered(
            c,
            store_text,
            FONT_BOLD,
            store_size,
            inner_x0,
            inner_w,
            cursor - store_size * _ASCENT_RATIO,
        )
        cursor -= store_h + gap

    # 2) Product name — bold, centred, up to two wrapped lines.
    if name_lines:
        c.setFillColorRGB(*_COLOR_NAME)
        for index, line in enumerate(name_lines):
            _draw_centered(
                c,
                line,
                FONT_BOLD,
                name_size,
                inner_x0,
                inner_w,
                cursor - name_size * _ASCENT_RATIO - index * name_line_h,
            )
        cursor -= len(name_lines) * name_line_h + gap

    # 3) Struck retail + declared badge on one small line, then the price.
    if retail_on:
        retail_shaped = shape_text(format_money(data.retail))
        rw = c.stringWidth(retail_shaped, FONT_REGULAR, retail_size)
        badge_shaped = (
            shape_text(_badge_text(data.discount_percent, locale))
            if data.discount_percent
            else ""
        )
        bw = (
            c.stringWidth(badge_shaped, FONT_BOLD, badge_size)
            if badge_shaped
            else 0.0
        )
        mid_gap = 6.0 * s if bw else 0.0
        total = rw + mid_gap + bw
        rx = inner_x0 + max(0.0, (inner_w - total) / 2)
        baseline = cursor - retail_size * _ASCENT_RATIO
        c.setFillColorRGB(*_COLOR_MUTED)
        c.setFont(FONT_REGULAR, retail_size)
        c.drawString(rx, baseline, retail_shaped)
        strike_y = baseline + retail_size * 0.32
        c.setStrokeColorRGB(*_COLOR_MUTED)
        c.setLineWidth(max(0.4, 0.6 * s))
        c.line(rx, strike_y, rx + rw, strike_y)
        if badge_shaped:
            c.setFillColorRGB(*_COLOR_PROMO)
            c.setFont(FONT_BOLD, badge_size)
            c.drawString(rx + rw + mid_gap, baseline, badge_shaped)
        cursor -= retail_h + gap * 0.45

    c.setFillColorRGB(*(_COLOR_PROMO if data.promo else _COLOR_NAME))
    _draw_centered(
        c,
        price_text,
        FONT_BOLD,
        price_size,
        inner_x0,
        inner_w,
        cursor - price_size * _ASCENT_RATIO,
    )
    cursor -= price_line_h
    if has_barcode:
        cursor -= gap

    # 4) Barcode + human-readable value, centred, quiet zones preserved.
    #    The block is bottom-anchored inside the space the budget left:
    #    digits occupy the lowest `digits_h`, the bars sit directly above.
    if has_barcode and data.barcode:
        cursor -= bars_h + digits_h
        quiet = min(_QUIET, inner_w * 0.10)
        bx = inner_x0 + quiet
        avail = max(8.0, inner_w - 2 * quiet)
        bar_scale, _probe = _barcode_scale(data.barcode, avail, bars_h)
        bars = Code128(
            data.barcode,
            barWidth=bar_scale,
            barHeight=bars_h,
            humanReadable=0,
            quiet=0,
        )
        c.setFillColorRGB(*_COLOR_BARCODE)
        bars.drawOn(c, bx + max(0.0, (avail - bars.width) / 2), cursor + digits_h)

        digits = shape_text(data.barcode)  # ASCII passthrough — stays LTR (§17 A8)
        digits_size = _fit_size(digits, FONT_REGULAR, digits_size, inner_w, floor=4.0)
        _draw_centered(
            c,
            data.barcode,
            FONT_REGULAR,
            digits_size,
            inner_x0,
            inner_w,
            cursor + (digits_h - digits_size) / 2,
        )

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

    For `paper="roll"` every label is its own page (media width × label
    height), so a four-label job is a four-page document and the printer
    feeds four labels. A4 / 80 mm keep their grid and paginate by
    `sheet.per_page`.
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
            top_inset=sheet.top_inset,
        )
    c.save()
    return buffer.getvalue()
