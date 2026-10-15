"""Storage & data usage — service-level measurement (read-only).

Covers:
- the backend tree partition: every file lands in exactly one bucket
  (application / backups / data / cache) and the buckets sum to the
  real total — nothing is double-counted
- backup directories outside the backend root are measured separately
- missing directories and a missing root report ``missing``
- a directory symlink is never followed or counted
- the shared deadline reports ``timeout`` instead of a partial number
- database size: PostgreSQL via ``pg_database_size`` (read-only, stubbed
  here; the real query is exercised in tests/integration), SQLite via
  the actual file size, ``:memory:`` → ``in_memory``
- disk capacity: available on an existing root, ``missing`` otherwise
- the payload never contains filesystem paths
"""

from __future__ import annotations

import json
import os
import shutil
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import app.services.storage as storage_module
from app.schemas.storage import (
    SERVER_CATEGORY_KEYS,
)
from app.services.storage import (
    PG_DATABASE_SIZE_SQL,
    assert_read_only_sql,
    get_storage_usage,
    measure_database,
    measure_disk,
    measure_tree,
    resolve_backup_dir,
    resolve_data_dir,
)


@pytest.fixture()
def backend_root(tmp_path: Path) -> Path:
    """A miniature backend tree with files in every bucket."""
    root = tmp_path / "backend"
    root.mkdir()
    (root / "app.py").write_bytes(b"a" * 10)
    (root / "backups").mkdir()
    (root / "backups" / "b1.sql").write_bytes(b"b" * 20)
    (root / "data").mkdir()
    (root / "data" / "server_id").write_bytes(b"c" * 5)
    (root / "__pycache__").mkdir()
    (root / "__pycache__" / "app.pyc").write_bytes(b"d" * 7)
    (root / ".venv" / "lib").mkdir(parents=True)
    (root / ".venv" / "lib" / "dep.py").write_bytes(b"e" * 11)
    (root / "sub" / "__pycache__").mkdir(parents=True)
    (root / "sub" / "__pycache__" / "x.pyc").write_bytes(b"f" * 3)
    return root


@pytest.fixture()
def storage_env(monkeypatch: pytest.MonkeyPatch, backend_root: Path) -> Path:
    """Point the service at the fake tree with default-style settings."""
    monkeypatch.setattr(storage_module, "BACKEND_ROOT", backend_root)
    monkeypatch.setattr(
        storage_module,
        "settings",
        SimpleNamespace(
            BACKUP_DIR="",
            SERVER_ID_FILE=str(backend_root / "data" / "server_id"),
        ),
    )
    return backend_root


def _measure(root: Path, backup: Path, data: Path, budget: float = 5.0):
    return measure_tree(
        root, backup, data, deadline=time.monotonic() + budget
    )


# ---------------------------------------------------------------------------
# Partitioning walk
# ---------------------------------------------------------------------------


def test_tree_partition_is_disjoint_and_adds_up(storage_env):
    tree = _measure(storage_env, storage_env / "backups", storage_env / "data")
    assert tree["application"].bytes == 10 + 11  # app.py + venv dependency
    assert tree["backups"].bytes == 20
    assert tree["data"].bytes == 5
    assert tree["cache_temp"].bytes == 7 + 3  # both __pycache__ levels
    # Every byte of the tree is claimed exactly once.
    total_on_disk = sum(
        f.stat().st_size for f in storage_env.rglob("*") if f.is_file()
    )
    measured = sum(c.bytes for c in tree.values() if c.available)
    assert measured == total_on_disk == 56


def test_backup_dir_outside_root_is_walked_separately(
    monkeypatch: pytest.MonkeyPatch, storage_env
):
    outside = storage_env.parent / "offsite_backups"
    outside.mkdir()
    (outside / "b2.sql").write_bytes(b"g" * 13)
    (outside / "b3.sql").write_bytes(b"h" * 17)
    monkeypatch.setattr(
        storage_module.settings, "BACKUP_DIR", str(outside)
    )

    tree = _measure(storage_env, resolve_backup_dir(), resolve_data_dir())
    assert tree["backups"].available
    assert tree["backups"].bytes == 30
    # The in-tree folder is no longer *the* backup dir, so its files fall
    # into the application bucket — never both.
    assert tree["application"].bytes == 10 + 11 + 20


def test_missing_backup_dir_reports_missing(
    monkeypatch: pytest.MonkeyPatch, backend_root, storage_env
):
    shutil.rmtree(backend_root / "backups")
    missing = backend_root.parent / "never_created"
    monkeypatch.setattr(
        storage_module.settings, "BACKUP_DIR", str(missing)
    )

    tree = _measure(storage_env, resolve_backup_dir(), resolve_data_dir())
    assert tree["backups"].available is False
    assert tree["backups"].reason == "missing"
    assert tree["application"].bytes == 21


def test_symlinked_directory_is_never_followed(storage_env):
    target_dir = storage_env.parent / "outside_target"
    target_dir.mkdir()
    (target_dir / "secret.bin").write_bytes(b"x" * 100)
    link_dir = storage_env / "linkdir"
    try:
        os.symlink(str(target_dir), str(link_dir), target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("directory symlinks unavailable on this host")

    tree = _measure(storage_env, storage_env / "backups", storage_env / "data")
    assert tree["application"].bytes == 21  # the 100-byte target is absent


def test_expired_deadline_reports_timeout_not_a_partial_number(storage_env):
    tree = measure_tree(
        storage_env,
        storage_env / "backups",
        storage_env / "data",
        deadline=time.monotonic(),  # already in the past
    )
    for key, category in tree.items():
        assert category.available is False, key
        assert category.reason == "timeout", key


def test_missing_root_reports_missing(tmp_path: Path):
    tree = _measure(tmp_path / "nope", tmp_path / "b", tmp_path / "d")
    for category in tree.values():
        assert category.available is False
        assert category.reason == "missing"


# ---------------------------------------------------------------------------
# Disk capacity
# ---------------------------------------------------------------------------


def test_disk_capacity_available_for_existing_root(storage_env):
    disk = measure_disk(storage_env)
    assert disk.available
    assert disk.total_bytes is not None and disk.total_bytes > 0
    assert disk.free_bytes is not None and 0 <= disk.free_bytes <= disk.total_bytes


def test_disk_capacity_missing_for_missing_path(tmp_path: Path):
    disk = measure_disk(tmp_path / "nope")
    assert disk.available is False
    assert disk.reason == "missing"


# ---------------------------------------------------------------------------
# Database size query behaviour
# ---------------------------------------------------------------------------


def _sqlite_session(url: str):
    kwargs: dict = {"check_same_thread": False}
    if ":memory:" in url:
        engine = create_engine(url, connect_args=kwargs, poolclass=StaticPool)
    else:
        engine = create_engine(url, connect_args=kwargs)
    return sessionmaker(bind=engine)()


def test_database_memory_sqlite_is_in_memory_not_estimated():
    session = _sqlite_session("sqlite:///:memory:")
    category = measure_database(session)
    assert category.available is False
    assert category.reason == "in_memory"


def test_database_file_sqlite_uses_the_actual_file_size(tmp_path: Path):
    db_file = tmp_path / "measure.sqlite3"
    session = _sqlite_session(f"sqlite:///{db_file.as_posix()}")
    # An actual write: a SELECT alone leaves the file at zero bytes.
    session.execute(text("CREATE TABLE t (x INTEGER)"))
    session.execute(text("INSERT INTO t VALUES (1)"))
    session.commit()
    session.close()

    # A second session against the same file — stat, not row estimates.
    session = _sqlite_session(f"sqlite:///{db_file.as_posix()}")
    category = measure_database(session)
    assert category.available
    assert category.bytes == db_file.stat().st_size
    assert category.bytes > 0


class _StubUrl:
    database = "supermarket_pro"

    @staticmethod
    def get_backend_name() -> str:
        return "postgresql"


class _StubBind:
    url = _StubUrl()


class _StubScalarResult:
    def scalar(self):
        return 424242


class _StubPgSession:
    def __init__(self):
        self.executed: list[str] = []

    @staticmethod
    def get_bind():
        return _StubBind()

    def execute(self, statement):
        self.executed.append(str(statement))
        return _StubScalarResult()


def test_database_postgres_uses_size_function_read_only():
    session = _StubPgSession()
    category = measure_database(session)
    assert category.available
    assert category.bytes == 424242
    assert len(session.executed) == 1
    assert_read_only_sql(session.executed[0])


class _FailingPgSession(_StubPgSession):
    def execute(self, statement):
        raise RuntimeError("permission denied for database postgres")


class _BrokenPgSession(_StubPgSession):
    def execute(self, statement):
        raise RuntimeError("connection lost")


def test_database_postgres_privilege_error_maps_to_permission_reason():
    category = measure_database(_FailingPgSession())
    assert category.available is False
    assert category.reason == "permission"


def test_database_postgres_failure_maps_to_error_reason():
    category = measure_database(_BrokenPgSession())
    assert category.available is False
    assert category.reason == "error"


def test_size_sql_is_a_read_only_select():
    assert_read_only_sql(PG_DATABASE_SIZE_SQL)
    with pytest.raises(AssertionError):
        assert_read_only_sql("DELETE FROM sales")


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------


def test_report_shape_categories_order_and_totals(storage_env):
    session = _sqlite_session("sqlite:///:memory:")
    report = get_storage_usage(session)

    assert report.scope == "server"
    assert [c.key for c in report.categories] == list(SERVER_CATEGORY_KEYS)
    assert report.measured_at  # ISO timestamp present
    # Database is in-memory in tests → report is honest, not complete.
    assert report.complete is False
    assert report.total_bytes == 21 + 20 + 5 + 10
    assert report.total_bytes == sum(
        c.bytes or 0 for c in report.categories if c.available
    )
    # ``not_stored`` never makes the report incomplete by itself.
    logs = next(c for c in report.categories if c.key == "logs")
    assert logs.available is False
    assert logs.reason == "not_stored"


def test_report_is_complete_with_a_file_database(
    storage_env, tmp_path: Path
):
    db_file = tmp_path / "complete.sqlite3"
    session = _sqlite_session(f"sqlite:///{db_file.as_posix()}")
    session.execute(text("CREATE TABLE t (x INTEGER)"))
    session.execute(text("INSERT INTO t VALUES (1)"))
    session.commit()
    session.close()
    session = _sqlite_session(f"sqlite:///{db_file.as_posix()}")
    report = get_storage_usage(session)
    assert report.complete is True
    assert report.total_bytes > 21 + 20 + 5 + 10  # includes the DB file


def test_payload_contains_no_paths_or_connection_details(storage_env):
    session = _sqlite_session("sqlite:///:memory:")
    report = get_storage_usage(session)
    payload = report.model_dump_json()

    assert str(storage_env) not in payload
    assert "server_id" not in payload  # a filename is a filesystem detail
    assert "\\" not in payload  # no Windows paths escaped into JSON
    assert "postgres" not in payload  # no connection/dialect details
    assert json.loads(payload)  # still valid JSON


def test_real_backend_tree_measures_successfully():
    """No monkeypatch: the walk must handle the actual backend tree."""
    started = time.monotonic()
    session = _sqlite_session("sqlite:///:memory:")
    report = get_storage_usage(session)
    elapsed = time.monotonic() - started

    application = next(
        c for c in report.categories if c.key == "application"
    )
    assert application.available
    assert (application.bytes or 0) > 0
    assert elapsed < storage_module.TREE_BUDGET_SECONDS + 5
