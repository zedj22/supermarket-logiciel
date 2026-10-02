"""Shared paragraph/cell styles (Phase 15 §4.4, §7.1, §8.1).

Styles are built from a few primitives so RTL (Arabic) always gets
`wordWrap='RTL'` + right/center alignment (legacy defect: invoice styles
omitted it — do not preserve that bug).
"""

from __future__ import annotations

from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
from reportlab.lib.styles import ParagraphStyle

from app.printing.fonts import FONT_BOLD, FONT_REGULAR
from app.printing.labels import is_rtl

_ALIGN = {"left": TA_LEFT, "right": TA_RIGHT, "center": TA_CENTER}


def paragraph_style(
    name: str,
    *,
    size: float,
    leading: float | None = None,
    rtl: bool,
    bold: bool = False,
    align: str | None = None,
    space_after: float = 0,
) -> ParagraphStyle:
    """A ParagraphStyle with the RTL wrap rule applied for Arabic."""
    if align is None:
        align = "right" if rtl else "left"
    return ParagraphStyle(
        name,
        fontName=FONT_BOLD if bold else FONT_REGULAR,
        fontSize=size,
        leading=leading if leading is not None else size * 1.25,
        alignment=_ALIGN[align],
        wordWrap="RTL" if rtl else "CJK",
        spaceAfter=space_after,
    )


def style_for(locale: str, key: str, size: float, **kwargs) -> ParagraphStyle:
    """Named styles per locale: `key` ∈ {title, section, body, meta, ...}."""
    rtl = is_rtl(locale)
    factories = {
        "title": dict(size=size, bold=True, align="center"),
        "section": dict(size=size, bold=True, align="center" if rtl else "left"),
        "body": dict(size=size),
        "meta": dict(size=size),
        "right": dict(size=size, align="right" if not rtl else "right"),
        "center": dict(size=size, align="center"),
        "cell": dict(size=size),
        "cell_bold": dict(size=size, bold=True),
    }
    base = dict(factories.get(key, {}))
    base.update(kwargs)
    return paragraph_style(f"{locale}-{key}-{size}", rtl=rtl, **base)
