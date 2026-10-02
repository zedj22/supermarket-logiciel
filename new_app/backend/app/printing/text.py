"""Text pipeline for document rendering (Phase 15 §15.1, §15.4, §17.3).

`shape_text()` is the single entry point: sanitize → reshape+bidi ONLY when
the string contains Arabic (pure numbers/Latin pass through untouched —
fixes the legacy over-application defect §2.4 C3). Never bidi a formatted
money/qty cell.
"""

from __future__ import annotations

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


def shape_text(text: str) -> str:
    """Sanitize, then reshape + bidi only when Arabic is present."""
    text = sanitize_text(text)
    if not contains_arabic(text):
        return text
    return get_display(arabic_reshaper.reshape(text))


def _dec(value: Decimal | float | int | str) -> Decimal:
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def format_money(value: Decimal | float | int | str) -> str:
    """Display money: 2 decimals + localized `DA` suffix (§15.4)."""
    return f"{_dec(value):.2f} {CURRENCY}"


def format_qty(value: Decimal | float | int | str) -> str:
    """Display quantity: up to 3 decimals, trailing zeros stripped."""
    d = _dec(value)
    text = f"{d:.3f}".rstrip("0").rstrip(".")
    return text or "0"


def format_amount(value: Decimal | float | int | str) -> str:
    """Report value on documents: 3 decimals, trailing zeros stripped."""
    return format_qty(value)


def format_percent(value: Decimal | float | int | str) -> str:
    return f"{_dec(value):.2f}%"


def format_datetime(value) -> str:  # noqa: ANN001 - datetime-like
    """Locale-neutral display of the same UTC value (§15.4): `YYYY-MM-DD HH:MM`."""
    return value.strftime("%Y-%m-%d %H:%M")


def format_date(value) -> str:  # noqa: ANN001 - date-like
    return value.strftime("%Y-%m-%d")
