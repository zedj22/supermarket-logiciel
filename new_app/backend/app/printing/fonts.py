"""Font registration — single source of truth (Phase 15 §15.2, G7).

Bundles the OFL-licensed IBM Plex Sans Arabic TTFs inside the backend
package. Registration fails typed (`MISSING_FONT`, HTTP 500) when a file is
absent or its checksum does not match the G7-verified value — never a
silent `Helvetica` fallback, never probing `C:/Windows/Fonts`.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

from app.core.exceptions import AppError

FONT_DIR = Path(__file__).resolve().parent / "fonts"

FONT_REGULAR = "IBMPlexSansArabic"
FONT_BOLD = "IBMPlexSansArabic-Bold"

REGULAR_TTF = FONT_DIR / "IBMPlexSansArabic-Regular.ttf"
BOLD_TTF = FONT_DIR / "IBMPlexSansArabic-Bold.ttf"
OFL_TXT = FONT_DIR / "OFL.txt"

# SHA-256 of the G7-verified files (scripts/g7_spike_out/g7_evidence.json).
EXPECTED_SHA256 = {
    REGULAR_TTF: "1118a402b5eabda347c416e49391bdc156836abfc0aca93ae9f1fbddfab2af28",
    BOLD_TTF: "863a038c6afe94ec626bc5bfb94ce37f26196c1f1d50289f4f7c88e339b0aa41",
}

_registered = False


def _fail(reason: str) -> None:
    raise AppError(
        message=f"Bundled document font unavailable: {reason}",
        details={"font_dir": str(FONT_DIR)},
        code="MISSING_FONT",
        status_code=500,
        message_key="missing_font",
    )


def register_fonts() -> None:
    """Idempotently register the bundled fonts (validates checksums)."""
    global _registered
    if _registered:
        return
    if not OFL_TXT.exists():
        _fail(f"missing {OFL_TXT.name} license file")
    for path, expected in EXPECTED_SHA256.items():
        if not path.exists():
            _fail(f"missing {path.name}")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            _fail(f"checksum mismatch for {path.name}")
    try:
        pdfmetrics.registerFont(TTFont(FONT_REGULAR, str(REGULAR_TTF)))
        pdfmetrics.registerFont(TTFont(FONT_BOLD, str(BOLD_TTF)))
    except Exception as exc:  # reportlab raises non-AppError on bad TTF
        _fail(str(exc))
    _registered = True
