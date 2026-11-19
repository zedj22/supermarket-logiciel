"""R1: Windows production data paths & runtime architecture.

Covers the release-audit blockers B4 (CWD-relative ``.env``) and B7
(writable state inside the install tree):

* absolute, CWD-independent configuration resolution (``.env`` included)
* the production ``DATA_DIR`` layout: config / license / data / backups / logs
* development defaults unchanged from the pre-R1 behaviour
* StateStore / TrialManager path stability across restarts and CWD changes
* backup path resolution (default, relative override, explicit override)
* missing vs inaccessible production data directories (create vs fail fast)
* existing-install compatibility: legacy in-tree data is reported as a
  migration hint and is never moved, copied or deleted automatically

The full path architecture: docs/R1_DATA_PATHS.md.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import app.core.server_identity as server_identity
import app.services.storage as storage_module
from app.core.config import (
    BACKEND_ROOT,
    DATA_SUBDIRS,
    DataDirectoryError,
    Settings,
    ensure_data_dirs,
    legacy_data_locations,
    resolve_env_file,
    settings,
)
from app.licensing.state_store import StateStore
from app.licensing.trial import TrialManager
from app.services.backup import BackupService


def _settings(**overrides) -> Settings:
    """A Settings instance with explicit non-placeholder secrets.

    ``LICENSE_STATE_DIR=""`` mimics an unset production value: the test
    suite exports a process-level LICENSE_STATE_DIR (conftest isolation),
    and init kwargs outrank the process environment — without this the
    conftest path would shadow the DATA_DIR resolution under test.
    """
    base: dict = {
        "DATABASE_URL": "sqlite:///:memory:",
        "APP_SECRET_KEY": "not-a-placeholder",
        "JWT_SECRET_KEY": "not-a-placeholder",
        "LICENSE_STATE_DIR": "",
    }
    base.update(overrides)
    return Settings(**base)


def _data_dir(tmp_path: Path) -> Path:
    return tmp_path / "ProgramData" / "SupermarketPro"


# ---------------------------------------------------------------------------
# Absolute configuration path resolution (.env)
# ---------------------------------------------------------------------------


def test_settings_class_env_file_is_absolute(monkeypatch):
    monkeypatch.delenv("DATA_DIR", raising=False)
    env_file = Settings.model_config["env_file"]
    assert isinstance(env_file, str)
    assert Path(env_file).is_absolute()
    assert Path(env_file) == BACKEND_ROOT / ".env"


def test_env_file_resolution_is_anchored_to_the_backend_root(monkeypatch):
    monkeypatch.delenv("DATA_DIR", raising=False)
    assert resolve_env_file() == str(BACKEND_ROOT / ".env")


def test_env_file_resolution_ignores_the_process_cwd(monkeypatch, tmp_path):
    """A decoy .env in the CWD must never become *the* config file."""
    (tmp_path / ".env").write_text(
        "DATABASE_URL=postgresql://decoy\n", encoding="utf-8"
    )
    before = resolve_env_file()
    monkeypatch.chdir(tmp_path)
    assert resolve_env_file() == before


def test_env_file_uses_the_config_subdir_when_data_dir_is_in_the_process_env(
    monkeypatch, tmp_path
):
    monkeypatch.setenv("DATA_DIR", str(_data_dir(tmp_path)))
    assert Path(resolve_env_file()) == _data_dir(tmp_path) / "config" / ".env"


def test_env_file_resolves_a_relative_process_data_dir_against_the_backend_root(
    monkeypatch, tmp_path
):
    monkeypatch.setenv("DATA_DIR", "runtime_data")
    monkeypatch.chdir(tmp_path)  # CWD must not leak into the resolution
    assert Path(resolve_env_file()) == BACKEND_ROOT / "runtime_data" / "config" / ".env"


@pytest.mark.skipif(
    not (BACKEND_ROOT / ".env").is_file(),
    reason="no backend .env in this checkout",
)
def test_settings_never_load_a_dotenv_from_the_cwd(monkeypatch, tmp_path):
    """Functional CWD-independence: the decoy file in the CWD is ignored."""
    (tmp_path / ".env").write_text(
        "DATABASE_URL=postgresql://decoy:decoy@localhost:9999/decoy\n",
        encoding="utf-8",
    )
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.chdir(tmp_path)
    loaded = Settings()
    assert "decoy" not in loaded.DATABASE_URL
    assert loaded.DATABASE_URL  # the real, backend-anchored .env supplied it


# ---------------------------------------------------------------------------
# Production data directory resolution
# ---------------------------------------------------------------------------


def test_production_data_dir_resolves_every_writable_path(tmp_path):
    data_dir = _data_dir(tmp_path)
    s = _settings(DATA_DIR=str(data_dir))

    assert Path(s.DATA_DIR) == data_dir
    assert Path(s.LICENSE_STATE_DIR) == data_dir / "license"
    assert Path(s.SERVER_ID_FILE) == data_dir / "data" / "server_id"
    assert Path(s.LOG_DIR) == data_dir / "logs"

    # Audit B7: with DATA_DIR configured nothing writable points into the
    # install tree, so the backend runs without write permission on it.
    for resolved in (s.LICENSE_STATE_DIR, s.SERVER_ID_FILE, s.LOG_DIR):
        assert not Path(resolved).is_relative_to(BACKEND_ROOT)


def test_relative_data_dir_resolves_against_the_backend_root_never_the_cwd(
    monkeypatch, tmp_path
):
    monkeypatch.chdir(tmp_path)
    s = _settings(DATA_DIR="runtime_data")
    assert Path(s.DATA_DIR) == BACKEND_ROOT / "runtime_data"


def test_production_explicit_overrides_still_win_and_stay_absolute(tmp_path):
    data_dir = _data_dir(tmp_path)
    s = _settings(
        DATA_DIR=str(data_dir),
        LICENSE_STATE_DIR=str(tmp_path / "elsewhere" / "lic"),
        SERVER_ID_FILE=str(tmp_path / "elsewhere" / "sid"),
        LOG_DIR=str(tmp_path / "elsewhere" / "logs"),
    )
    assert Path(s.LICENSE_STATE_DIR) == tmp_path / "elsewhere" / "lic"
    assert Path(s.SERVER_ID_FILE) == tmp_path / "elsewhere" / "sid"
    assert Path(s.LOG_DIR) == tmp_path / "elsewhere" / "logs"


def test_relative_overrides_resolve_against_the_data_root(tmp_path):
    data_dir = _data_dir(tmp_path)
    s = _settings(
        DATA_DIR=str(data_dir),
        LICENSE_STATE_DIR="state/license",
        SERVER_ID_FILE="state/server_id",
    )
    assert Path(s.LICENSE_STATE_DIR) == data_dir / "state" / "license"
    assert Path(s.SERVER_ID_FILE) == data_dir / "state" / "server_id"


# ---------------------------------------------------------------------------
# Development compatibility (pre-R1 behaviour preserved bit-for-bit)
# ---------------------------------------------------------------------------


def test_development_defaults_are_unchanged(monkeypatch, tmp_path):
    monkeypatch.delenv("DATA_DIR", raising=False)
    monkeypatch.chdir(tmp_path)  # even from a foreign CWD

    s = _settings(DATA_DIR="", LICENSE_STATE_DIR="", SERVER_ID_FILE="", LOG_DIR="")

    assert s.DATA_DIR == ""
    assert Path(s.LICENSE_STATE_DIR) == BACKEND_ROOT / "data" / "license"
    assert Path(s.SERVER_ID_FILE) == BACKEND_ROOT / "data" / "server_id"
    assert Path(s.LOG_DIR) == BACKEND_ROOT / "logs"
    assert resolve_env_file() == str(BACKEND_ROOT / ".env")


def test_development_backup_default_is_the_backend_backups_dir(
    monkeypatch, tmp_path
):
    monkeypatch.delenv("DATA_DIR", raising=False)
    monkeypatch.setattr(settings, "DATA_DIR", "")
    monkeypatch.setattr(settings, "BACKUP_DIR", "  ")
    assert BackupService(None).directory == BACKEND_ROOT / "backups"


# ---------------------------------------------------------------------------
# Backup path resolution
# ---------------------------------------------------------------------------


def test_backup_dir_defaults_to_the_data_root_in_production(
    monkeypatch, tmp_path
):
    data_dir = _data_dir(tmp_path)
    monkeypatch.setattr(settings, "DATA_DIR", str(data_dir))
    monkeypatch.setattr(settings, "BACKUP_DIR", "  ")

    assert BackupService(None).directory == data_dir / "backups"
    assert storage_module.resolve_backup_dir() == data_dir / "backups"


def test_relative_backup_dir_resolves_against_the_data_root(
    monkeypatch, tmp_path
):
    data_dir = _data_dir(tmp_path)
    monkeypatch.setattr(settings, "DATA_DIR", str(data_dir))
    monkeypatch.setattr(settings, "BACKUP_DIR", "special_backups")

    assert BackupService(None).directory == data_dir / "special_backups"
    assert storage_module.resolve_backup_dir() == data_dir / "special_backups"


def test_explicit_absolute_backup_dir_wins(monkeypatch, tmp_path):
    offsite = tmp_path / "offsite"
    monkeypatch.setattr(settings, "DATA_DIR", str(_data_dir(tmp_path)))
    monkeypatch.setattr(settings, "BACKUP_DIR", str(offsite))

    assert BackupService(None).directory == offsite
    assert storage_module.resolve_backup_dir() == offsite


# ---------------------------------------------------------------------------
# StateStore / TrialManager path stability (CWD + restart)
# ---------------------------------------------------------------------------


def test_statestore_paths_are_stable_across_cwd_changes(tmp_path, monkeypatch):
    data_dir = _data_dir(tmp_path)
    s = _settings(DATA_DIR=str(data_dir))
    state_dir = Path(s.LICENSE_STATE_DIR)
    assert state_dir == data_dir / "license"

    store = StateStore(state_dir, use_dpapi=False)
    store.write("trial", {"install_id": "unit-test", "v": 1})

    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)

    # Same absolute root: a fresh store (restart) sees the same state.
    again = StateStore(state_dir, use_dpapi=False)
    assert again.read("trial") == {"install_id": "unit-test", "v": 1}
    assert Path(s.LICENSE_STATE_DIR) == state_dir  # settings are absolute


def test_trial_state_survives_restart_and_cwd_change(tmp_path, monkeypatch):
    data_dir = _data_dir(tmp_path)
    s = _settings(DATA_DIR=str(data_dir))
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", s.LICENSE_STATE_DIR)

    first = TrialManager.from_settings().ensure_started()

    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)

    second = TrialManager.from_settings().ensure_started()
    assert second.install_id == first.install_id
    assert second.expires_at == first.expires_at
    assert Path(settings.LICENSE_STATE_DIR) == data_dir / "license"


def test_server_id_file_is_absolute_and_cwd_independent(tmp_path, monkeypatch):
    target = tmp_path / "runtime" / "data" / "server_id"
    monkeypatch.setattr(settings, "SERVER_ID", "")
    monkeypatch.setattr(settings, "SERVER_ID_FILE", str(target))
    try:
        server_identity.reset_server_id_cache()
        first = server_identity.get_server_id()

        elsewhere = tmp_path / "elsewhere"
        elsewhere.mkdir()
        monkeypatch.chdir(elsewhere)
        server_identity.reset_server_id_cache()

        assert server_identity.get_server_id() == first
        assert target.is_file()
    finally:
        # Never leak this test's cached identity into other suites.
        server_identity.reset_server_id_cache()


# ---------------------------------------------------------------------------
# Missing / inaccessible production data directories
# ---------------------------------------------------------------------------


def test_missing_production_data_root_is_created_with_the_documented_layout(
    tmp_path,
):
    data_dir = _data_dir(tmp_path)
    assert not data_dir.exists()

    s = _settings(DATA_DIR=str(data_dir))
    created = ensure_data_dirs(s)

    assert [path.name for path in created] == list(DATA_SUBDIRS)
    for name in DATA_SUBDIRS:
        assert (data_dir / name).is_dir()
    # Idempotent: a second startup creates nothing new.
    assert ensure_data_dirs(s) == []


def test_ensure_data_dirs_is_a_noop_in_development(monkeypatch):
    monkeypatch.delenv("DATA_DIR", raising=False)
    assert ensure_data_dirs(_settings(DATA_DIR="")) == []


def test_inaccessible_production_data_root_fails_fast_not_silently(tmp_path):
    blocker = tmp_path / "not_a_directory"
    blocker.write_bytes(b"x")  # a file where a directory must go
    s = _settings(DATA_DIR=str(blocker / "SupermarketPro"))

    with pytest.raises(DataDirectoryError) as excinfo:
        ensure_data_dirs(s)
    assert "DATA_DIR" in str(excinfo.value)


# ---------------------------------------------------------------------------
# Startup wiring (the lifespan actually runs the validation)
# ---------------------------------------------------------------------------


def test_lifespan_creates_the_production_data_root_before_any_state_write(
    monkeypatch, tmp_path
):
    """Entering the app with DATA_DIR set builds the documented layout."""
    from fastapi.testclient import TestClient

    from app.main import app

    data_dir = _data_dir(tmp_path)
    assert not data_dir.exists()
    monkeypatch.setattr(settings, "DATA_DIR", str(data_dir))
    monkeypatch.setattr(settings, "LICENSE_STATE_DIR", str(data_dir / "license"))

    with TestClient(app):  # entering the context = lifespan startup
        pass

    for name in DATA_SUBDIRS:
        assert (data_dir / name).is_dir()
    # The trial state went to the production location, not the install tree.
    assert (data_dir / "license" / "trial.state").is_file()


def test_lifespan_startup_fails_loudly_on_an_inaccessible_data_root(
    monkeypatch, tmp_path
):
    from fastapi.testclient import TestClient

    from app.main import app

    blocker = tmp_path / "not_a_directory"
    blocker.write_bytes(b"x")
    monkeypatch.setattr(
        settings, "DATA_DIR", str(blocker / "SupermarketPro")
    )

    with pytest.raises(DataDirectoryError):
        with TestClient(app):
            pass  # pragma: no cover - startup must abort before serving


# ---------------------------------------------------------------------------
# Existing installation compatibility (legacy data: reported, never moved)
# ---------------------------------------------------------------------------


def test_legacy_install_data_is_reported_but_never_moved(tmp_path):
    legacy = tmp_path / "old_backend"
    legacy_license = legacy / "data" / "license"
    legacy_license.mkdir(parents=True)
    (legacy_license / "trial.state").write_text("{}", encoding="utf-8")
    (legacy / "backups").mkdir()
    (legacy / "backups" / "0001.sql").write_text("SELECT 1;", encoding="utf-8")
    (legacy / "data" / "server_id").write_text("00000000-0000-0000-0000-000000000000", encoding="utf-8")

    data_dir = _data_dir(tmp_path)
    s = _settings(DATA_DIR=str(data_dir))
    ensure_data_dirs(s)

    found = legacy_data_locations(s, backend_root=legacy)
    assert set(found) == {
        legacy_license,
        legacy / "data" / "server_id",
        legacy / "backups",
    }

    # Nothing was moved, copied or deleted automatically.
    assert (legacy_license / "trial.state").is_file()
    assert (legacy / "data" / "server_id").is_file()
    assert (legacy / "backups" / "0001.sql").is_file()
    assert list((data_dir / "license").iterdir()) == []
    assert list((data_dir / "backups").iterdir()) == []


def test_development_reports_no_legacy_migration_hint(monkeypatch):
    # In development the in-tree locations *are* the live data.
    monkeypatch.delenv("DATA_DIR", raising=False)
    assert legacy_data_locations(_settings(DATA_DIR="")) == []
