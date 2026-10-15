"""Storage & data usage response schemas (read-only measurement).

The contract is deliberately path-free: categories are stable ``key``
strings the client localizes itself, and neither absolute paths,
hostnames nor connection details ever appear in the payload.
"""

from __future__ import annotations

from app.schemas.common import StrictBaseModel

# Category keys — the client maps each to a localized label.
DATABASE = "database"
APPLICATION = "application"
BACKUPS = "backups"
DATA = "data"
CACHE_TEMP = "cache_temp"
LOGS = "logs"

# Server-side category order as returned by GET /api/v1/storage.
SERVER_CATEGORY_KEYS = (DATABASE, APPLICATION, BACKUPS, DATA, CACHE_TEMP, LOGS)

# Reason codes for unavailable categories.
REASON_MISSING = "missing"          # the location does not exist
REASON_IN_MEMORY = "in_memory"      # SQLite memory database: no file on disk
REASON_PERMISSION = "permission"    # database refused the size query
REASON_TIMEOUT = "timeout"          # measurement budget exceeded
REASON_ERROR = "error"              # unexpected OS/IO failure
REASON_NOT_STORED = "not_stored"    # by design nothing is kept as files


class StorageCategory(StrictBaseModel):
    """One measured storage category.

    ``bytes`` is only set when ``available`` is true; otherwise ``reason``
    explains why the number is missing.  ``reason="not_stored"`` marks a
    category that is *not applicable* (nothing is ever written there) and
    does not make the overall measurement incomplete.
    """

    key: str
    available: bool
    bytes: int | None = None
    reason: str | None = None


class StorageDisk(StrictBaseModel):
    """Capacity of the volume holding the measured server location."""

    available: bool = True
    total_bytes: int | None = None
    free_bytes: int | None = None
    reason: str | None = None


class StorageUsageResponse(StrictBaseModel):
    """Server-side storage report.

    ``scope`` is always ``"server"`` so a LAN client can tell this data
    apart from its own local measurements.  ``total_bytes`` sums only the
    available categories (the partition is disjoint, so nothing is counted
    twice); ``complete`` is false when any measurable category is missing.
    """

    scope: str = "server"
    measured_at: str
    categories: list[StorageCategory]
    disk: StorageDisk
    complete: bool
    total_bytes: int
