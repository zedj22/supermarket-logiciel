"""Download filename sanitization (Phase 15 §17.2).

Every server-generated download name (report export, print render) passes
through here before it reaches a ``Content-Disposition`` header:

- path separators and header-unsafe characters stripped (a filename must
  never address a directory or inject header syntax);
- forced to ASCII (the Phase 14 CSV rule — avoids broken names on the
  Windows printer/Explorer side);
- Windows reserved device names (CON, PRN, COM1, …) neutralised;
- bounded length, extension preserved when truncating.
"""

from __future__ import annotations

import re

_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
_RESERVED = frozenset(
    {"CON", "PRN", "AUX", "NUL"}
    | {f"COM{i}" for i in range(1, 10)}
    | {f"LPT{i}" for i in range(1, 10)}
)
DEFAULT_MAX_LENGTH = 120


def sanitize_filename(name: str, *, max_length: int = DEFAULT_MAX_LENGTH) -> str:
    """Return a safe, ASCII, bounded filename derived from ``name``."""
    out = _UNSAFE.sub("", name)
    out = out.encode("ascii", "ignore").decode("ascii").strip(" .")
    if not out:
        return "export"

    stem, dot, ext = out.rpartition(".")
    if not dot or len(ext) > 10:
        # No extension (or the tail after the dot is content, not one).
        stem, ext = out, ""
    if stem.upper() in _RESERVED:
        stem = f"_{stem}"

    if len(f"{stem}.{ext}" if ext else stem) > max_length:
        if ext:
            keep = max(1, max_length - len(ext) - 1)
            return f"{stem[:keep]}.{ext}"
        return stem[:max_length]
    return f"{stem}.{ext}" if ext else stem
