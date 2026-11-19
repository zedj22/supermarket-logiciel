"""R4 §5 — the two runtime secret files stay separate.

``<DATA_DIR>/config/secrets.env`` holds the application secrets the
backend needs on **every** start (R2).  ``<DATA_DIR>/config/database.env``
holds the PostgreSQL application-role password (R3).  They are written by
different functions, read by different code, and never exchange a value.

The exact consumption point for ``database.env`` is the R5 handoff
(documented in ``docs/R4_PRODUCTION_LICENSING.md`` §5): this round only
proves the boundary, not the wiring - the launcher deliberately does not
read the file yet.
"""

from __future__ import annotations

import os
from pathlib import Path

from app.core.secrets import (
    DATABASE_SECRET_KEYS,
    REQUIRED_SECRET_KEYS,
    database_env_file,
    ensure_database_password,
    ensure_production_secrets,
    secrets_file_for,
)

BACKEND_ROOT = Path(__file__).resolve().parents[2]


def active_keys(path: Path) -> dict[str, str]:
    """``KEY=VALUE`` pairs of a runtime secret file, comments ignored."""
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        name, _, value = stripped.partition("=")
        values[name] = value
    return values


def test_the_two_files_are_distinct_paths(tmp_path: Path) -> None:
    secrets = ensure_production_secrets(tmp_path)
    database = ensure_database_password(tmp_path, external="r4-handoff-pw-0001")

    assert secrets.path == secrets_file_for(tmp_path)
    assert database.path == database_env_file(tmp_path)
    assert secrets.path != database.path
    assert secrets.path.parent == database.path.parent


def test_secrets_env_never_carries_the_database_password(tmp_path: Path) -> None:
    secrets = ensure_production_secrets(tmp_path)
    ensure_database_password(tmp_path, external="r4-handoff-pw-0002")

    values = active_keys(secrets.path)

    assert set(values) == set(REQUIRED_SECRET_KEYS)
    for key in DATABASE_SECRET_KEYS:
        assert key not in values


def test_database_env_never_carries_the_application_secrets(tmp_path: Path) -> None:
    ensure_production_secrets(tmp_path)
    database = ensure_database_password(tmp_path, external="r4-handoff-pw-0003")

    values = active_keys(database.path)

    assert set(values) == set(DATABASE_SECRET_KEYS)
    for key in REQUIRED_SECRET_KEYS:
        assert key not in values
    assert values["DATABASE_PASSWORD"] == "r4-handoff-pw-0003"


def test_generating_one_file_never_rewrites_the_other(tmp_path: Path) -> None:
    secrets = ensure_production_secrets(tmp_path)
    ensure_database_password(tmp_path, external="r4-handoff-pw-0004")
    secrets_before = secrets.path.read_bytes()

    ensure_database_password(tmp_path, external="r4-handoff-pw-0005")

    assert secrets.path.read_bytes() == secrets_before


def test_the_settings_layer_never_reads_database_env() -> None:
    """``database.env`` is handed over in R5, never through ``Settings``."""
    config_source = (BACKEND_ROOT / "app" / "core" / "config.py").read_text(
        encoding="utf-8"
    )

    assert "database.env" not in config_source
    assert "DATABASE_PASSWORD" not in config_source


def test_the_database_password_stays_out_of_the_process_environment(
    tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.delenv("DATABASE_PASSWORD", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)

    ensure_database_password(tmp_path, external="r4-handoff-pw-0006")

    assert "DATABASE_PASSWORD" not in os.environ
    assert "DATABASE_URL" not in os.environ
