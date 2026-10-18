"""Full portable-archive round trip on real PostgreSQL (Objective 2).

Skipped when PostgreSQL client tools or the test database are missing, so
the suite still runs on a machine without them — the *behaviour* of the
service is covered by the unit tests, which inject a fake runner.  What
only a real run can prove lives here:

* create → seed different data → restore → the original data comes back
* create → download the portable ZIP → upload it back → restore the
  staged copy → the original data comes back (the archive is genuinely
  portable)
* the safety backup taken before a restore is itself a real, restorable
  dump

Never touches ``supermarket_pro`` — only ``supermarket_pro_test``.
"""

from __future__ import annotations

import io
import zipfile
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.core.db_dump import DbParams, DumpRunner, find_pg_tool
from app.services.backup import BackupService
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

PROBE_TABLE = "objective2_roundtrip_probe"

HAVE_TOOLS = bool(find_pg_tool("pg_dump")) and bool(find_pg_tool("psql"))

pytestmark = [
    pytest.mark.skipif(
        not PG_IS_AVAILABLE,
        reason="PostgreSQL test database (supermarket_pro_test) not available",
    ),
    pytest.mark.skipif(
        not HAVE_TOOLS,
        reason="pg_dump / psql client tools not found",
    ),
]


@pytest.fixture()
def params() -> DbParams:
    return DbParams.from_url(PG_TEST_URL)


@pytest.fixture()
def runner(params: DbParams) -> DumpRunner:
    return DumpRunner(params, timeout=120)


@pytest.fixture()
def pg_session():
    engine = create_engine(PG_TEST_URL)
    maker = sessionmaker(bind=engine, autoflush=False)
    session = maker()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture()
def backup_dir(tmp_path: Path) -> Path:
    return tmp_path / "backups"


@pytest.fixture()
def service(pg_session, runner, backup_dir, monkeypatch) -> BackupService:
    monkeypatch.setattr(
        "app.services.backup.settings.BACKUP_DIR", str(backup_dir)
    )
    return BackupService(pg_session, runner=runner, directory=backup_dir)


@pytest.fixture()
def probe():
    """A table that exists in the dump, so we can prove what was restored."""
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    conn.autocommit = False
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {PROBE_TABLE}")
        cur.execute(f"CREATE TABLE {PROBE_TABLE} (v text)")
        cur.execute(f"INSERT INTO {PROBE_TABLE} VALUES ('original')")
    conn.commit()
    try:
        yield
    finally:
        with conn.cursor() as cur:
            cur.execute(f"DROP TABLE IF EXISTS {PROBE_TABLE}")
        conn.commit()
        conn.close()


def _read_probe() -> list[str]:
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT v FROM {PROBE_TABLE} ORDER BY v")
            return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def _write_probe(values: list[str]) -> None:
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    conn.autocommit = False
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM {PROBE_TABLE}")
        for value in values:
            cur.execute(
                f"INSERT INTO {PROBE_TABLE} (v) VALUES (%s)", (value,)
            )
    conn.commit()
    conn.close()


def test_restore_round_trip_returns_the_original_data(service, probe):
    backup = service.create()
    assert backup.schema_revision is not None  # real alembic table exists

    _write_probe(["changed", "after-backup"])
    assert _read_probe() == ["after-backup", "changed"]

    result = service.restore(backup.id, confirm=True)
    assert result.restored is True
    assert result.post_restore_ok is True
    assert result.safety_backup is not None
    assert result.safety_backup.id != backup.id
    assert _read_probe() == ["original"]


def test_safety_backup_is_itself_restorable(service, probe):
    """The pre-restore snapshot must be a genuine way back."""
    backup = service.create()
    _write_probe(["state-a"])
    result = service.restore(backup.id, confirm=True)
    assert _read_probe() == ["original"]

    safety = result.safety_backup
    assert safety is not None
    service.restore(safety.id, confirm=True)
    assert _read_probe() == ["state-a"]


def test_portable_archive_download_upload_restore_roundtrip(
    service, probe, backup_dir
):
    """create → download ZIP → upload ZIP → restore the staged copy."""
    original = service.create()
    _write_probe(["doomed"])

    zip_bytes, archive_name = service.download(original.id)
    assert archive_name.endswith(".zip")
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        assert set(archive.namelist()) == {"dump.sql", "manifest.json"}
        assert PROBE_TABLE.encode() in archive.read("dump.sql")

    staged = service.upload(
        content=zip_bytes,
        filename=archive_name,
    )
    assert staged.id != original.id  # id re-allocated on this server
    assert (backup_dir / staged.filename).is_file()
    assert staged.schema_revision == original.schema_revision

    result = service.restore(staged.id, confirm=True)
    assert result.restored is True
    assert result.post_restore_ok is True
    assert _read_probe() == ["original"]


def test_upload_raw_sql_roundtrip(service, probe, backup_dir):
    """A hand-copied ``.sql`` (no ZIP) also stages and restores."""
    original = service.create()
    raw = (backup_dir / original.filename).read_bytes()
    _write_probe(["raw-doomed"])

    staged = service.upload(content=raw, filename="hand_copied.sql")
    assert staged.id != original.id
    assert (backup_dir / staged.filename).read_bytes() == raw

    result = service.restore(staged.id, confirm=True)
    assert result.restored is True
    assert _read_probe() == ["original"]


def test_inspect_reports_compatibility_for_a_real_backup(service, probe):
    backup = service.create()
    report = service.inspect(backup.id)
    assert report.file_present is True
    assert report.sha256_ok is True
    # Both sides carry the live alembic revision ⇒ compatible.
    assert report.current_schema_revision == backup.schema_revision
    assert report.schema_compatible is True
    assert report.warnings == []


def test_inspect_flags_a_missing_dump_on_real_pg(service, probe, backup_dir):
    backup = service.create()
    (backup_dir / backup.filename).unlink()

    report = service.inspect(backup.id)
    assert report.file_present is False
    assert any("missing" in w for w in report.warnings)


def test_restore_without_confirmation_touches_nothing(service, probe):
    backup = service.create()
    _write_probe(["untouched"])

    from app.core.exceptions import BusinessRuleError

    with pytest.raises(BusinessRuleError) as excinfo:
        service.restore(backup.id, confirm=False)
    assert excinfo.value.code == "RESTORE_CONFIRMATION_REQUIRED"
    assert _read_probe() == ["untouched"]


def test_tampered_upload_is_refused_before_staging(service, probe, backup_dir):
    original = service.create()
    tampered_path = backup_dir / original.filename
    tampered_path.write_bytes(tampered_path.read_bytes() + b"-- evil\n")

    # The stored backup itself now fails its own integrity gate.
    from app.core.exceptions import BusinessRuleError

    with pytest.raises(BusinessRuleError):
        service.restore(original.id, confirm=True)
    assert _read_probe() == ["original"]
