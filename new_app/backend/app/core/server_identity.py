"""Stable server identity for Phase 16 (§8.2).

``server_id`` is a UUIDv4 that survives IP/DHCP changes so a paired client
can tell "the store server I paired with" from "some other box answering
port 8000".  It is deliberately NOT an IP address, NOT a hostname and NOT
a settings-table row (no settings table exists until Phase 17).

Resolution order:
1. ``SERVER_ID`` environment setting (packaging/tests may pin it),
2. the backend-local file ``SERVER_ID_FILE`` (``data/server_id``),
3. a freshly generated UUID, persisted to that file on first start.

``server_id`` is public (it is returned by ``GET /api/v1/system/info`` and
by the UDP discovery offer) — it is an *identity*, never a credential.
The file is created at most once and read-only afterwards.
"""

from __future__ import annotations

import threading
import uuid
from pathlib import Path

from app.core.config import settings

_lock = threading.Lock()
_cached: str | None = None


def _read_file(path: Path) -> str | None:
    try:
        if path.is_file():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
    except OSError:  # pragma: no cover - unreadable data directory
        return None
    return None


def _write_file(path: Path, value: str) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
        return True
    except OSError:  # pragma: no cover - read-only install location
        return False


def get_server_id(*, refresh: bool = False) -> str:
    """Return this server's stable identity, generating it on first use."""
    global _cached

    override = (settings.SERVER_ID or "").strip()
    if override:
        return override

    with _lock:
        if _cached is not None and not refresh:
            return _cached

        path = Path(settings.SERVER_ID_FILE)
        existing = _read_file(path)
        if existing is not None:
            _cached = existing
            return _cached

        candidate = str(uuid.uuid4())
        _write_file(path, candidate)
        _cached = candidate
        return _cached


def reset_server_id_cache() -> None:
    """Testing seam: forget the cached identity (never deletes the file)."""
    global _cached
    with _lock:
        _cached = None
