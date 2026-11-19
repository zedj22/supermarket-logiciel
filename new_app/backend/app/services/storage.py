"""Read-only server storage measurement for the Storage & Data Usage page.

Every number in this module is measured, never estimated:

* ``database``  — PostgreSQL's own ``pg_database_size()`` (or the SQLite
  file size for the dev/test engine); never derived from row counts.
* ``application`` / ``backups`` / ``data`` / ``cache_temp`` — a single
  partitioning walk of the backend tree, so a file always lands in
  exactly one bucket and nothing is double-counted.  Backup and data
  directories that live *outside* the backend root are measured by their
  own walks (still disjoint from the root walk).
* ``logs``      — reported as ``not_stored``: the backend logs to stdout
  only (``app/core/logging.py``), so no log files exist to measure.

Safety rules honoured here:

* the walk never follows symlinks (neither directory links nor file
  links) and de-duplicates by path and by inode/hardlink;
* measurement is bounded by a shared wall-clock ``deadline`` — on expiry
  the affected categories report ``timeout`` instead of a partial number;
* no path, hostname or connection detail ever leaves this module: the
  response carries category keys, byte counts and reason codes only;
* nothing is written, deleted or reconfigured — SELECT and stat only.
"""

from __future__ import annotations

import os
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path

import structlog
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import BACKEND_ROOT, settings
from app.schemas.storage import (
    APPLICATION,
    BACKUPS,
    CACHE_TEMP,
    DATA,
    DATABASE,
    LOGS,
    REASON_ERROR,
    REASON_IN_MEMORY,
    REASON_MISSING,
    REASON_NOT_STORED,
    REASON_PERMISSION,
    REASON_TIMEOUT,
    SERVER_CATEGORY_KEYS,
    StorageCategory,
    StorageDisk,
    StorageUsageResponse,
)

logger = structlog.get_logger(__name__)

# Directory names whose files are bucketed as cache/temporary instead of
# application files (``__pycache__`` appears at every level, including
# inside a virtualenv).
CACHE_DIR_NAMES = frozenset(
    {"__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".cache"}
)

# Shared wall-clock budget for all filesystem walks of one measurement.
TREE_BUDGET_SECONDS = 5.0

# Read-only by construction: a single size function, no arguments from
# the client, nothing to mutate.
PG_DATABASE_SIZE_SQL = "SELECT pg_database_size(current_database())"

_MUTATING_SQL = frozenset(
    {
        "insert",
        "update",
        "delete",
        "merge",
        "create",
        "drop",
        "alter",
        "truncate",
        "grant",
        "revoke",
        "copy",
        "call",
    }
)

_TREE_KEYS = (APPLICATION, BACKUPS, DATA, CACHE_TEMP)


# ---------------------------------------------------------------------------
# Path resolution (mirrors BackupService.directory / server_identity)
# ---------------------------------------------------------------------------


def _runtime_root() -> Path:
    """Writable data root: ``DATA_DIR`` (production) or the backend root
    (development) — R1; identical to ``BackupService._runtime_root``."""
    raw = (getattr(settings, "DATA_DIR", "") or "").strip()
    return Path(raw) if raw else Path(BACKEND_ROOT)


def resolve_backup_dir() -> Path:
    """Absolute backup directory — same rule as ``BackupService.directory``."""
    root = _runtime_root()
    raw = settings.BACKUP_DIR.strip()
    path = Path(raw) if raw else root / "backups"
    if not path.is_absolute():
        path = root / path
    return path


def resolve_data_dir() -> Path:
    """Directory holding the server-identity file.

    ``SERVER_ID_FILE`` is resolved to an absolute path by ``Settings``
    (R1), so the measured location is the one the application actually
    writes to regardless of the CWD.  A relative override (possible only
    via test fakes) resolves against the writable data root — never the
    process working directory.
    """
    path = Path(settings.SERVER_ID_FILE)
    if not path.is_absolute():
        path = _runtime_root() / path
    return path.parent


def _norm(path: Path | str) -> str:
    return os.path.normcase(os.path.abspath(str(path)))


def _is_under(path_norm: str, dir_norm: str) -> bool:
    if path_norm == dir_norm:
        return True
    return path_norm.startswith(dir_norm.rstrip(os.sep) + os.sep)


def _is_strict_subdir(path: Path, root: Path) -> bool:
    path_norm, root_norm = _norm(path), _norm(root)
    return _is_under(path_norm, root_norm) and path_norm != root_norm


def _is_root_or_ancestor(path: Path, root: Path) -> bool:
    """True when measuring ``path`` would swallow ``root`` (overlap risk)."""
    path_norm, root_norm = _norm(path), _norm(root)
    return _is_under(root_norm, path_norm)


# ---------------------------------------------------------------------------
# Filesystem measurement
# ---------------------------------------------------------------------------


def _walk_buckets(
    root: Path,
    *,
    backup_dir: Path | None,
    data_dir: Path | None,
    deadline: float,
) -> tuple[dict[str, int], set[str], set[tuple[int, int]]] | str:
    """Partition every regular file under ``root`` into size buckets.

    Returns ``(buckets, seen_paths, seen_inodes)`` on success or a reason
    code on failure.  ``backup_dir``/``data_dir`` are only passed when
    they are strict subdirectories of ``root`` so their files are routed
    from the same single walk (disjoint by construction).
    """
    buckets = {key: 0 for key in _TREE_KEYS}
    backup_norm = _norm(backup_dir) if backup_dir else None
    data_norm = _norm(data_dir) if data_dir else None
    seen_paths: set[str] = set()
    seen_inodes: set[tuple[int, int]] = set()
    errors: list[BaseException] = []

    def onerror(exc: OSError) -> None:
        errors.append(exc)

    root_str = str(root)
    for dirpath, dirnames, filenames in os.walk(
        root_str, topdown=True, onerror=onerror, followlinks=False
    ):
        if time.monotonic() >= deadline:  # >=: coarse clocks may repeat a tick
            return REASON_TIMEOUT
        # Never descend through a symlinked directory.
        dirnames[:] = [
            d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))
        ]
        rel_parts = set(Path(dirpath).relative_to(root_str).parts)
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):  # file links are skipped, not followed
                continue
            try:
                st = os.stat(full)
            except OSError as exc:
                errors.append(exc)
                continue
            path_norm = _norm(full)
            if path_norm in seen_paths:
                continue
            seen_paths.add(path_norm)
            if st.st_ino:
                inode_key = (st.st_dev, st.st_ino)
                if inode_key in seen_inodes:
                    continue
                seen_inodes.add(inode_key)
            if backup_norm and _is_under(path_norm, backup_norm):
                buckets[BACKUPS] += st.st_size
            elif data_norm and _is_under(path_norm, data_norm):
                buckets[DATA] += st.st_size
            elif rel_parts.intersection(CACHE_DIR_NAMES):
                buckets[CACHE_TEMP] += st.st_size
            else:
                buckets[APPLICATION] += st.st_size
    if errors:
        return REASON_ERROR
    return buckets, seen_paths, seen_inodes


def _walk_extra(path: Path, *, deadline: float) -> tuple[int | None, str | None]:
    """Sum a directory outside the backend root (its own bounded walk)."""
    if not path.exists():
        return None, REASON_MISSING
    if not path.is_dir():
        return None, REASON_ERROR
    total = 0
    errors: list[BaseException] = []
    seen_paths: set[str] = set()
    seen_inodes: set[tuple[int, int]] = set()
    try:
        for dirpath, dirnames, filenames in os.walk(
            str(path), topdown=True, onerror=errors.append, followlinks=False
        ):
            if time.monotonic() >= deadline:
                return None, REASON_TIMEOUT
            dirnames[:] = [
                d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))
            ]
            for name in filenames:
                full = os.path.join(dirpath, name)
                if os.path.islink(full):
                    continue
                try:
                    st = os.stat(full)
                except OSError as exc:
                    errors.append(exc)
                    continue
                path_norm = _norm(full)
                if path_norm in seen_paths:
                    continue
                seen_paths.add(path_norm)
                if st.st_ino:
                    inode_key = (st.st_dev, st.st_ino)
                    if inode_key in seen_inodes:
                        continue
                    seen_inodes.add(inode_key)
                total += st.st_size
    except OSError as exc:
        logger.warning(
            "storage_extra_walk_failed", error=type(exc).__name__
        )
        return None, REASON_ERROR
    if errors:
        return None, REASON_ERROR
    return total, None


def _category(key: str, value: int | None, reason: str | None) -> StorageCategory:
    if reason is not None:
        return StorageCategory(key=key, available=False, reason=reason)
    return StorageCategory(key=key, available=True, bytes=value or 0)


def measure_tree(
    root: Path,
    backup_dir: Path,
    data_dir: Path,
    *,
    deadline: float,
) -> dict[str, StorageCategory]:
    """Measure the server filesystem categories as one disjoint partition."""
    root = Path(root)
    backup_in_root = _is_strict_subdir(backup_dir, root)
    data_in_root = _is_strict_subdir(data_dir, root)

    if not root.is_dir():
        result = {key: _category(key, None, REASON_MISSING) for key in _TREE_KEYS}
    else:
        walked = _walk_buckets(
            root,
            backup_dir=backup_dir if backup_in_root else None,
            data_dir=data_dir if data_in_root else None,
            deadline=deadline,
        )
        if isinstance(walked, str):
            result = {key: _category(key, None, walked) for key in _TREE_KEYS}
            logger.warning("storage_tree_walk_failed", reason=walked)
        else:
            buckets, _seen_paths, _seen_inodes = walked
            result = {
                APPLICATION: _category(APPLICATION, buckets[APPLICATION], None),
                CACHE_TEMP: _category(CACHE_TEMP, buckets[CACHE_TEMP], None),
                BACKUPS: _category(BACKUPS, buckets[BACKUPS], None),
                DATA: _category(DATA, buckets[DATA], None),
            }

    # Directories outside the backend root get their own bounded walk.
    if not backup_in_root:
        result[BACKUPS] = _extra_category(
            BACKUPS, backup_dir, root, deadline=deadline
        )
    if not data_in_root:
        result[DATA] = _extra_category(DATA, data_dir, root, deadline=deadline)
    return result


def _extra_category(
    key: str, path: Path, root: Path, *, deadline: float
) -> StorageCategory:
    if _is_root_or_ancestor(path, root):
        # Overlapping the root would double-count; refuse rather than guess.
        return _category(key, None, REASON_ERROR)
    if not path.exists():
        return _category(key, None, REASON_MISSING)
    value, reason = _walk_extra(path, deadline=deadline)
    return _category(key, value, reason)


def measure_disk(root: Path) -> StorageDisk:
    """Capacity of the volume holding the backend root (read-only)."""
    try:
        usage = shutil.disk_usage(str(root))
    except FileNotFoundError:
        return StorageDisk(available=False, reason=REASON_MISSING)
    except OSError as exc:
        logger.warning("storage_disk_failed", error=type(exc).__name__)
        return StorageDisk(available=False, reason=REASON_ERROR)
    return StorageDisk(
        available=True, total_bytes=usage.total, free_bytes=usage.free
    )


# ---------------------------------------------------------------------------
# Database measurement
# ---------------------------------------------------------------------------


def measure_database(db: Session) -> StorageCategory:
    """Actual database size — PostgreSQL reports it, SQLite is the file.

    The query is a constant read-only SELECT; the client never influences
    it and no connection detail is ever echoed back.
    """
    try:
        bind = db.get_bind()
        url = bind.url
        dialect = (url.get_backend_name() or "").lower()
        if dialect.startswith("postgres"):
            size = db.execute(text(PG_DATABASE_SIZE_SQL)).scalar()
            if size is None:
                return _category(DATABASE, None, REASON_ERROR)
            return _category(DATABASE, int(size), None)
        if dialect == "sqlite":
            raw = (url.database or "").strip()
            if not raw or raw == ":memory:" or raw.startswith("file:"):
                return _category(DATABASE, None, REASON_IN_MEMORY)
            path = Path(raw)
            if not path.is_absolute():
                path = Path.cwd() / path
            if not path.is_file():
                return _category(DATABASE, None, REASON_MISSING)
            size = path.stat().st_size
            for suffix in ("-wal", "-shm"):
                sibling = Path(str(path) + suffix)
                if sibling.is_file():
                    size += sibling.stat().st_size
            return _category(DATABASE, size, None)
        return _category(DATABASE, None, REASON_ERROR)
    except Exception as exc:  # noqa: BLE001 - report, never break the page
        message = str(exc).lower()
        reason = (
            REASON_PERMISSION
            if "privilege" in message or "permission denied" in message
            else REASON_ERROR
        )
        logger.warning(
            "storage_database_measure_failed", error=type(exc).__name__
        )
        return _category(DATABASE, None, reason)


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------


def get_storage_usage(db: Session) -> StorageUsageResponse:
    """Build the full server-side report (one shared measurement budget)."""
    root = Path(BACKEND_ROOT)
    deadline = time.monotonic() + TREE_BUDGET_SECONDS

    tree = measure_tree(
        root, resolve_backup_dir(), resolve_data_dir(), deadline=deadline
    )
    categories = [measure_database(db)]
    for key in _TREE_KEYS:
        categories.append(tree[key])
    # Nothing is ever logged to disk: stdout only (app/core/logging.py).
    categories.append(
        StorageCategory(key=LOGS, available=False, reason=REASON_NOT_STORED)
    )
    disk = measure_disk(root)

    # ``not_stored`` is "nothing exists here by design", not a failed
    # measurement — it does not make the report incomplete.
    complete = all(
        category.available or category.reason == REASON_NOT_STORED
        for category in categories
    )
    total = sum(
        category.bytes or 0 for category in categories if category.available
    )
    assert [c.key for c in categories] == list(SERVER_CATEGORY_KEYS)
    return StorageUsageResponse(
        scope="server",
        measured_at=datetime.now(timezone.utc).isoformat(),
        categories=categories,
        disk=disk,
        complete=complete,
        total_bytes=total,
    )


def assert_read_only_sql(sql: str) -> None:
    """Guard used by tests: the size query must contain no DML/DDL verb."""
    lowered = sql.lower()
    assert "pg_database_size" in lowered
    for verb in _MUTATING_SQL:
        assert f" {verb} " not in f" {lowered} ", f"mutating verb: {verb}"
