"""Real ``pg_dump`` / ``psql`` round trip (Phase 17 §17.2).

Skipped when PostgreSQL client tools or the test database are missing, so
the suite still runs on a machine without them — the *behaviour* of the
service is covered by the unit tests, which inject a fake runner.  What
only a real run can prove lives here:

* the dump is a genuine ``pg_dump`` plain script including the probe table
  and ``DROP TABLE``/``CREATE TABLE`` from ``--clean --if-exists``
* ``psql --single-transaction`` restores it and the data comes back
* a *corrupt* script is rejected **and leaves the database untouched**
  (that is what ``--single-transaction`` buys us)

Never touches ``supermarket_pro`` — only ``supermarket_pro_test``.
"""

from __future__ import annotations

import subprocess

import pytest

from app.core.db_dump import (
    DbParams,
    DumpRunner,
    find_pg_tool,
    require_pg_tool,
)
from app.core.exceptions import ServiceUnavailableError
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

PROBE_TABLE = "phase17_dump_probe"

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
def probe():
    """A table that exists in the dump, so we can prove what was restored."""
    import psycopg2

    conn = psycopg2.connect(PG_TEST_URL)
    conn.autocommit = False
    with conn.cursor() as cur:
        cur.execute(f"DROP TABLE IF EXISTS {PROBE_TABLE}")
        cur.execute(f"CREATE TABLE {PROBE_TABLE} (v text)")
        cur.execute(f"INSERT INTO {PROBE_TABLE} VALUES ('ok')")
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


def test_tools_are_discoverable(params):
    assert find_pg_tool("pg_dump") is not None
    assert require_pg_tool("psql").name.lower().startswith("psql")


def test_pg_dump_version_is_reportable(runner):
    output = runner.version()
    assert "pg_dump" in output


def test_dump_contains_the_schema_and_is_self_restoring(runner, probe, tmp_path):
    destination = tmp_path / "dump.sql"
    runner.dump(destination)

    assert destination.is_file()
    assert destination.stat().st_size > 0
    assert not destination.with_suffix(".sql.partial").exists()

    text = destination.read_text(encoding="utf-8", errors="replace")
    assert PROBE_TABLE in text
    assert "DROP TABLE" in text
    assert "CREATE TABLE" in text
    assert "--clean" not in text  # flags are not echoed into the dump


def test_restore_round_trip(runner, probe, tmp_path):
    destination = tmp_path / "dump.sql"
    runner.dump(destination)
    assert _read_probe() == ["ok"]

    runner.restore(destination)
    assert _read_probe() == ["ok"]


def test_corrupt_restore_leaves_the_database_untouched(runner, probe, tmp_path):
    broken = tmp_path / "broken.sql"
    broken.write_text(
        f"CREATE TABLE {PROBE_TABLE} (this is not sql;\n",
        encoding="utf-8",
    )

    with pytest.raises(ServiceUnavailableError):
        runner.restore(broken)

    # --single-transaction ⇒ the whole script was rolled back
    assert _read_probe() == ["ok"]


def test_password_is_only_in_the_environment(params, tmp_path):
    """The password rides in ``PG*`` env vars, never in argv or logs."""
    assert params.tool_env()["PGPASSWORD"] == params.password
    assert params.password not in params.safe_repr()

    destination = tmp_path / "dump.sql"
    DumpRunner(params, timeout=120).dump(destination)
    assert destination.is_file()


def test_missing_override_falls_back_instead_of_failing(tmp_path):
    """A stale PG_DUMP_PATH is a warning, not a hard outage."""
    assert find_pg_tool("pg_dump", str(tmp_path / "nope.exe")) is not None


def test_non_postgres_url_is_rejected():
    with pytest.raises(ValueError):
        DbParams.from_url("sqlite:///:memory:")


def test_pg_dump_binary_runs():
    tool = find_pg_tool("pg_dump")
    assert tool is not None
    assert tool.is_file()
    completed = subprocess.run(
        [str(tool), "--version"], capture_output=True, text=True, check=False
    )
    assert completed.returncode == 0
    assert "pg_dump" in completed.stdout
