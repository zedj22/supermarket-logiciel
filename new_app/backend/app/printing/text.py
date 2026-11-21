"""Text pipeline for document rendering (Phase 15 §15.1, §15.4, §17.3).

`shape_text()` is the single entry point: sanitize → reshape+bidi ONLY when
the string contains Arabic (pure numbers/Latin pass through untouched —
fixes the legacy over-application defect §2.4 C3). Never bidi a formatted
money/qty cell.

Every Arabic string is additionally shielded with an invisible LTR mark in
front of each ASCII digit run, so bidi rule W2 cannot turn a European
number that FOLLOWS Arabic text into an Arabic number (see
`_isolate_european_numbers`). Without it `التاريخ: 2026-01-05` printed as
`05-01-2026 :التاريخ` and `الخصم: 10.00 DA` printed as `DA 10.00 :الخصم`,
both of which break the digit-order promises of §17 A8.
"""

from __future__ import annotations

import re
from decimal import Decimal

import arabic_reshaper
from bidi.algorithm import get_display

from app.printing.labels import CURRENCY

ARABIC_RANGES = (
    (0x0600, 0x06FF),
    (0x0750, 0x077F),
    (0x08A0, 0x08FF),
    (0xFB50, 0xFDFF),
    (0xFE70, 0xFEFF),
)

# Left-to-right mark. Injected ONLY between `sanitize_text()` (which strips
# it from untrusted input) and `get_display()`, then removed again so it
# never reaches the page or a width calculation.
_LRM = "\u200e"
_ASCII_DIGITS = frozenset("0123456789")


def contains_arabic(text: str) -> bool:
    return any(lo <= ord(ch) <= hi for ch in text for lo, hi in ARABIC_RANGES)


def sanitize_text(text: str) -> str:
    """Strip control chars and bidi-override marks (§17.3)."""
    out: list[str] = []
    for ch in text:
        o = ord(ch)
        if 0x202A <= o <= 0x202E or 0x2066 <= o <= 0x2069 or o in (0x200E, 0x200F):
            continue
        if o < 0x20 and ch not in "\t\n":
            continue
        out.append(ch)
    return "".join(out)


def _isolate_european_numbers(text: str) -> str:
    """Put an invisible LTR mark in front of every ASCII digit run.

    Arabic is a strong RTL character, so bidi rule W2 reclassifies a
    following European number as an Arabic number; the reordering then
    scrambles it (`2026-01-05` → `05-01-2026`, `10.00 DA` → `DA 10.00`).
    An LRM resets "last strong type" to L for the run behind it, which
    keeps the number LTR. The mark itself is deleted again by
    `shape_text()`, so it participates in the bidi pass only and draws no
    glyph.
    """
    out: list[str] = []
    previous = ""
    for character in text:
        if character in _ASCII_DIGITS and previous not in _ASCII_DIGITS:
            out.append(_LRM)
        out.append(character)
        previous = character
    return "".join(out)


def shape_text(text: str) -> str:
    """Sanitize, then reshape + bidi only when Arabic is present."""
    text = sanitize_text(text)
    if not contains_arabic(text):
        return text
    shaped = arabic_reshaper.reshape(_isolate_european_numbers(text))
    return get_display(shaped).replace(_LRM, "")


def _dec(value: Decimal | float | int | str) -> Decimal:
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _group_digits(int_part: str) -> str:
    """Insert a regular space between every group of three digits (right to left)."""
    return re.sub(r"(?<=\d)(?=(\d{3})+(?!\d))", " ", int_part)


def group_thousands(text: str) -> str:
    """Space-group the integer part of a plain decimal string; pass through anything else."""
    negative = text.startswith("-")
    unsigned = text[1:] if negative else text
    if not unsigned or not unsigned.replace(".", "", 1).isdigit() or unsigned.count(".") > 1:
        return text
    int_part, _, fraction = unsigned.partition(".")
    fraction = f".{fraction}" if "." in unsigned else ""
    return f"{'-' if negative else ''}{_group_digits(int_part)}{fraction}"


def format_money(value: Decimal | float | int | str) -> str:
    """Display money: space-grouped thousands, 2 decimals + localized `DA` suffix (§15.4)."""
    return f"{group_thousands(f'{_dec(value):.2f}')} {CURRENCY}"


def format_qty(value: Decimal | float | int | str) -> str:
    """Display quantity: space-grouped thousands, up to 3 decimals, trailing zeros stripped."""
    d = _dec(value)
    text = f"{d:.3f}".rstrip("0").rstrip(".")
    return group_thousands(text or "0")


def format_amount(value: Decimal | float | int | str) -> str:
    """Report value on documents: 3 decimals, trailing zeros stripped, grouped."""
    return format_qty(value)


def format_percent(value: Decimal | float | int | str) -> str:
    return f"{_dec(value):.2f}%"


def format_datetime(value) -> str:  # noqa: ANN001 - datetime-like
    """Locale-neutral display of the same UTC value (§15.4): `YYYY-MM-DD HH:MM`."""
    return value.strftime("%Y-%m-%d %H:%M")


def format_date(value) -> str:  # noqa: ANN001 - date-like
    return value.strftime("%Y-%m-%d")


def format_time(value) -> str:  # noqa: ANN001 - datetime-like
    """Clock part of `format_datetime` — same timezone, same source value."""
    return value.strftime("%H:%M")


def format_receipt_stamp(value) -> str:  # noqa: ANN001 - datetime-like
    """Thermal-receipt stamp: seconds + clock, then the day-first date.

    `15:40:17  19/11/2026` — one string so the receipt header cannot drift
    between the two halves.  Same authoritative `sale.sale_date` as every
    other stamp (never the printing time).
    """
    return f"{value.strftime('%H:%M:%S')}  {value.strftime('%d/%m/%Y')}"
