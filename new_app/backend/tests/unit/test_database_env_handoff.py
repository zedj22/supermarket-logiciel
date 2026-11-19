"""R5: the R4 §5 handoff — ``database.env`` becomes ``DATABASE_URL``.

R3's provisioning pass writes the application-role password to
``<DATA_DIR>/config/database.env``.  The production launcher must read
it with ``load_database_password()`` and publish the assembled
``DATABASE_URL`` into the process environment **before**
``app.core.config`` is imported, so pydantic-settings' normal
env-over-dotenv precedence picks it up.

Pinned behaviour:

* the password from ``database.env`` replaces whatever credential is
  written in the ``.env`` URL, percent-encoded;
* an already-exported ``DATABASE_URL`` is never overwritten;
* a missing ``database.env`` changes nothing (``.env`` keeps working);
* neither the password nor the assembled URL reaches stdout, stderr or
  the ``--check`` report;
* a malformed ``database.env`` fails closed with exit 3, file untouched;
* ``PG_ADMIN_URL`` is never read by the launcher.
"""

from __future__ import annotations

import os
from pathlib import Path

import run_production
from app.core.secrets import database_env_file, ensure_database_password, load_database_password
from tests.unit.test_production_launcher import _report, _run

#: An installer-shaped production ``.env`` whose credential is stale on
#: purpose: ``database.env`` must win over it.
STALE_URL = "postgresql://app_user:stale-pw-0001@127.0.0.1:5432/supermarket_pro"


def _layout(tmp_path: Path, database_url: str) -> Path:
    """Minimal production layout: ``<DATA_DIR>/config/.env`` only."""
    data_dir = tmp_path / "ProgramData" / "SupermarketPro"
    (data_dir / "config").mkdir(parents=True)
    (data_dir / "config" / ".env").write_text(
        "APP_ENV=development\n"
        f"DATABASE_URL={database_url}\n"
        "APP_SECRET_KEY=change-me-to-a-strong-random-value\n"
        "JWT_SECRET_KEY=change-me-to-another-strong-random-value\n"
        "HOST=127.0.0.1\n"
        "PORT=8123\n"
        "LOG_LEVEL=INFO\n",
        encoding="utf-8",
    )
    return data_dir


# ---------------------------------------------------------------------------
# In-process: assembling and publishing the URL
# ---------------------------------------------------------------------------


def test_database_env_password_is_published_over_the_stale_dotenv_credential(
    tmp_path, monkeypatch
):
    data_dir = _layout(tmp_path, STALE_URL)
    ensure_database_password(data_dir, external="r4-r5-handoff-pw-0001")
    env_file = data_dir / "config" / ".env"
    monkeypatch.delenv("DATABASE_URL", raising=False)

    source = run_production._publish_database_url(
        env_file, load_database_password(data_dir)
    )

    assert source == "database_env"
    assert os.environ["DATABASE_URL"] == (
        "postgresql://app_user:r4-r5-handoff-pw-0001@127.0.0.1:5432/supermarket_pro"
    )
    assert "stale-pw-0001" not in os.environ["DATABASE_URL"]


def test_an_exported_database_url_is_never_overwritten(tmp_path, monkeypatch):
    """Env-over-dotenv: an explicit export outranks ``database.env``."""
    data_dir = _layout(tmp_path, STALE_URL)
    ensure_database_password(data_dir, external="r4-r5-handoff-pw-0002")
    exported = "postgresql://exported:exported-pw-0001@127.0.0.1:1111/exported_db"
    monkeypatch.setenv("DATABASE_URL", exported)

    source = run_production._publish_database_url(
        data_dir / "config" / ".env", load_database_password(data_dir)
    )

    assert source == "process_env"
    assert os.environ["DATABASE_URL"] == exported


def test_without_database_env_the_dotenv_value_stands(tmp_path, monkeypatch):
    data_dir = _layout(tmp_path, STALE_URL)
    monkeypatch.delenv("DATABASE_URL", raising=False)

    source = run_production._publish_database_url(
        data_dir / "config" / ".env", load_database_password(data_dir)
    )

    assert source == "dotenv"
    assert "DATABASE_URL" not in os.environ


def test_a_non_postgres_base_url_is_left_alone(tmp_path, monkeypatch):
    """A SQLite URL (the test suite's shape) is never rebuilt."""
    data_dir = _layout(tmp_path, "sqlite:///:memory:")
    ensure_database_password(data_dir, external="r4-r5-handoff-pw-0003")
    monkeypatch.delenv("DATABASE_URL", raising=False)

    source = run_production._publish_database_url(
        data_dir / "config" / ".env", load_database_password(data_dir)
    )

    assert source == "unusable"
    assert "DATABASE_URL" not in os.environ


def test_the_password_is_percent_encoded_into_the_url(tmp_path, monkeypatch):
    password = "p@ss:w/rd#1x"
    data_dir = _layout(tmp_path, STALE_URL)
    ensure_database_password(data_dir, external=password)
    monkeypatch.delenv("DATABASE_URL", raising=False)

    run_production._publish_database_url(
        data_dir / "config" / ".env", load_database_password(data_dir)
    )

    assert os.environ["DATABASE_URL"] == (
        "postgresql://app_user:p%40ss%3Aw%2Frd%231x@127.0.0.1:5432/supermarket_pro"
    )


def test_the_assembled_url_never_lands_in_the_report(tmp_path):
    """``--check`` prints the *source*, never the URL or its password."""
    data_dir = _layout(tmp_path, STALE_URL)
    ensure_database_password(data_dir, external="r4-r5-handoff-pw-0004")

    proc = _run(data_dir, "--check", cwd=tmp_path)
    report = _report(proc)

    assert report["database_url_source"] == "database_env"
    assert Path(report["database_env_file"]) == database_env_file(data_dir)
    combined = proc.stdout + proc.stderr
    assert "r4-r5-handoff-pw-0004" not in combined
    assert "stale-pw-0001" not in combined
    assert "DATABASE_URL=" not in combined


def test_check_without_database_env_reports_the_dotenv_source(tmp_path):
    data_dir = _layout(tmp_path, STALE_URL)

    report = _report(_run(data_dir, "--check", cwd=tmp_path))

    assert report["database_url_source"] == "dotenv"
    assert Path(report["database_env_file"]) == database_env_file(data_dir)


def test_a_corrupted_database_env_fails_closed_and_is_left_untouched(tmp_path):
    data_dir = _layout(tmp_path, STALE_URL)
    path = database_env_file(data_dir)
    garbage = "DATABASE_PASSWORD=short\n"
    path.write_text(garbage, encoding="utf-8")

    proc = _run(data_dir, "--check", cwd=tmp_path)

    assert proc.returncode == run_production.EXIT_SECRETS_FAILED
    assert "database.env" in proc.stderr
    assert path.read_text(encoding="utf-8") == garbage
    assert "short" not in proc.stderr


def test_the_launcher_source_never_reads_pg_admin_url():
    """R4 §5: ``PG_ADMIN_URL`` belongs to the provisioning pass only."""
    source = Path(run_production.__file__).read_text(encoding="utf-8")

    assert 'environ.get("PG_ADMIN_URL")' not in source
    assert "environ['PG_ADMIN_URL']" not in source
    assert 'environ["PG_ADMIN_URL"]' not in source
