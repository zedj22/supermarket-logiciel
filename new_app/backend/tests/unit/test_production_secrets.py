"""R2: per-install secret provisioning (``app.core.secrets``).

Contract under test:

* generated **once** per installation (restarts and upgrades never rotate
  the values and never invalidate active sessions);
* installer-provided secrets in ``<DATA_DIR>/config/.env`` win;
* anything untrustworthy (missing, truncated, malformed, placeholder)
  **fails closed** and the file is left byte-for-byte untouched;
* values are published through ``os.environ`` (process export wins) and
* never reach a log line;
* ``app.core.secrets`` stays importable *before* ``app.core.config``
  (no import of the settings module) and production settings still
  reject every repository/``.env.example`` placeholder.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

import pytest
import structlog

from app.core import logging as logging_module
from app.core.config import BACKEND_ROOT, Settings
from app.core.secrets import (
    REQUIRED_SECRET_KEYS,
    SecretsError,
    SecretsMissingError,
    ensure_production_secrets,
    load_production_secrets,
    parse_secrets_file,
    secrets_file_for,
)

PLACEHOLDERS = {
    "change-me-in-production",
    "jwt-change-me-in-production",
    "change-me-to-a-strong-random-value",
    "change-me-to-another-strong-random-value",
}


@pytest.fixture(autouse=True)
def _isolate_structlog():
    """Undo the global logger configuration these tests perform."""
    saved = structlog.get_config()
    root = logging.getLogger()
    saved_level = root.level
    root.setLevel(logging.INFO)
    yield
    logging_module._close_file_handler()
    root.setLevel(saved_level)
    structlog.configure(**saved)


def _data_dir(tmp_path: Path, *, with_dotenv: bool = True, secrets: str = "") -> Path:
    data_dir = tmp_path / "ProgramData" / "SupermarketPro"
    (data_dir / "config").mkdir(parents=True)
    if with_dotenv:
        (data_dir / "config" / ".env").write_text(
            "APP_ENV=development\n"
            "DATABASE_URL=sqlite:///:memory:\n"
            "APP_SECRET_KEY=change-me-to-a-strong-random-value\n"
            "JWT_SECRET_KEY=change-me-to-another-strong-random-value\n",
            encoding="utf-8",
        )
    if secrets:
        secrets_file_for(data_dir).write_text(secrets, encoding="utf-8")
    return data_dir


# ---------------------------------------------------------------------------
# First run / restart / upgrade
# ---------------------------------------------------------------------------


def test_first_run_generates_a_strong_unique_secret_file(tmp_path):
    data_dir = _data_dir(tmp_path)
    secrets_file = secrets_file_for(data_dir)

    result = ensure_production_secrets(data_dir)

    assert result.created is True
    assert result.source == "generated"
    assert result.path == secrets_file
    assert secrets_file.is_file()
    for key in REQUIRED_SECRET_KEYS:
        value = result.data[key]
        assert len(value) == 64
        assert value.isascii()
        assert value not in PLACEHOLDERS
        assert value.isalnum() or all(
            ch.isalnum() or ch in "-_" for ch in value
        )
    # The file on disk matches the returned values.
    assert parse_secrets_file(secrets_file) == result.data
    # Header explains what the file is and that it must never be copied.
    text = secrets_file.read_text(encoding="utf-8")
    assert text.startswith("# Supermarket Pro - per-install secrets")
    assert "never commit" in text


def test_a_restart_never_rotates_secrets(tmp_path):
    """Same installation, second start: identical values, no rewrite."""
    data_dir = _data_dir(tmp_path)

    first = ensure_production_secrets(data_dir)
    before = secrets_file_for(data_dir).read_bytes()

    second = ensure_production_secrets(data_dir)
    after = secrets_file_for(data_dir).read_bytes()

    assert first.created is True
    assert second.created is False
    assert second.source == "file"
    assert second.data == first.data
    assert after == before  # not even a rewrite with identical content


def test_an_upgrade_never_overwrites_secrets(tmp_path):
    """A new installer-written .env must not rotate existing secrets."""
    data_dir = _data_dir(tmp_path)
    original = ensure_production_secrets(data_dir)
    secrets_path = secrets_file_for(data_dir)
    before = secrets_path.read_bytes()

    # Upgrade drops a fresh .env (fresh placeholders) next to secrets.env.
    (data_dir / "config" / ".env").write_text(
        "APP_ENV=development\n"
        "DATABASE_URL=sqlite:///:memory:\n"
        "APP_SECRET_KEY=change-me-in-production\n"
        "JWT_SECRET_KEY=jwt-change-me-in-production\n",
        encoding="utf-8",
    )
    after_run = ensure_production_secrets(data_dir)

    assert secrets_path.read_bytes() == before
    assert after_run.created is False
    assert after_run.data == original.data


def test_installer_provided_secrets_win_and_nothing_is_generated(tmp_path):
    """Real values in .env: the installer's secrets are kept as-is."""
    data_dir = tmp_path / "ProgramData" / "SupermarketPro"
    (data_dir / "config").mkdir(parents=True)
    installer_app = "installer-written-app-secret-value-0123456789"
    installer_jwt = "installer-written-jwt-secret-value-0123456789"
    (data_dir / "config" / ".env").write_text(
        "APP_ENV=development\n"
        "DATABASE_URL=sqlite:///:memory:\n"
        f"APP_SECRET_KEY={installer_app}\n"
        f"JWT_SECRET_KEY={installer_jwt}\n",
        encoding="utf-8",
    )

    result = ensure_production_secrets(data_dir)

    assert result.source == "dotenv"
    assert result.created is False
    assert not secrets_file_for(data_dir).exists()
    assert result.data == {}  # nothing generated, nothing to publish


# ---------------------------------------------------------------------------
# Fail closed
# ---------------------------------------------------------------------------


def test_load_only_fails_when_the_file_is_absent(tmp_path):
    data_dir = _data_dir(tmp_path)
    with pytest.raises(SecretsMissingError):
        load_production_secrets(data_dir)
    # Load-only must not create anything.
    assert not secrets_file_for(data_dir).exists()


@pytest.mark.parametrize(
    ("payload", "why"),
    [
        ("APP_SECRET_KEY=short\nJWT_SECRET_KEY=short\n", "too short"),
        (
            "APP_SECRET_KEY=change-me-in-production\n"
            "JWT_SECRET_KEY=jwt-change-me-in-production\n",
            "repository placeholder",
        ),
        (
            "APP_SECRET_KEY=change-me-to-a-strong-random-value\n"
            "JWT_SECRET_KEY=change-me-to-another-strong-random-value\n",
            ".env.example placeholder",
        ),
        (
            "APP_SECRET_KEY=" + "a" * 64 + "\n",
            "missing JWT key",
        ),
        (
            "APP_SECRET_KEY=has spaces and 100% unsafe value here ok?\n"
            "JWT_SECRET_KEY=" + "b" * 64 + "\n",
            "illegal characters",
        ),
        (
            "APP_SECRET_KEY=" + "c" * 64 + "\n"
            "APP_SECRET_KEY=" + "d" * 64 + "\n"
            "JWT_SECRET_KEY=" + "e" * 64 + "\n",
            "duplicate key",
        ),
        ("not a dotenv line at all\n", "malformed line"),
        ("\x00\x01\x02binary garbage\n", "binary garbage"),
    ],
)
def test_untrusted_secret_files_fail_closed_and_are_never_rewritten(
    tmp_path, payload, why
):
    data_dir = _data_dir(tmp_path)
    secrets_file = secrets_file_for(data_dir)
    secrets_file.write_bytes(payload.encode("utf-8", errors="surrogateescape"))
    before = secrets_file.read_bytes()

    with pytest.raises(SecretsError):
        ensure_production_secrets(data_dir)
    with pytest.raises(SecretsError):
        load_production_secrets(data_dir)

    assert secrets_file.read_bytes() == before, f"file changed: {why}"
    # The error names the key and the path, never a value.
    with pytest.raises(SecretsError) as excinfo:
        ensure_production_secrets(data_dir)
    message = str(excinfo.value)
    assert str(secrets_file) in message
    for value in ("c" * 64, "d" * 64, "e" * 64, "a" * 64, "b" * 64):
        assert value not in message


def test_a_missing_data_dir_is_refused(tmp_path, monkeypatch):
    monkeypatch.delenv("DATA_DIR", raising=False)
    with pytest.raises(SecretsError, match="DATA_DIR"):
        ensure_production_secrets()


def test_relative_data_dir_anchors_to_the_backend_root(tmp_path, monkeypatch):
    from app.core.secrets import resolve_data_dir

    monkeypatch.setenv("DATA_DIR", "runtime_data")
    monkeypatch.chdir(tmp_path)  # the CWD must not leak into the path
    assert resolve_data_dir() == BACKEND_ROOT / "runtime_data"


# ---------------------------------------------------------------------------
# Environment publication and log hygiene
# ---------------------------------------------------------------------------


def test_values_are_published_through_the_environment(tmp_path, monkeypatch):
    monkeypatch.delenv("APP_SECRET_KEY", raising=False)
    monkeypatch.delenv("JWT_SECRET_KEY", raising=False)
    data_dir = _data_dir(tmp_path)

    result = ensure_production_secrets(data_dir)

    assert os.environ["APP_SECRET_KEY"] == result.data["APP_SECRET_KEY"]
    assert os.environ["JWT_SECRET_KEY"] == result.data["JWT_SECRET_KEY"]


def test_an_explicitly_exported_secret_is_never_overwritten(
    tmp_path, monkeypatch
):
    exported = "explicitly-exported-secret-value-0123456789abcd"
    monkeypatch.setenv("APP_SECRET_KEY", exported)
    data_dir = _data_dir(tmp_path)

    result = ensure_production_secrets(data_dir)

    # Process environment wins over the generated value...
    assert os.environ["APP_SECRET_KEY"] == exported
    # ...and the generated file is still written for the next start.
    assert result.created is True
    assert parse_secrets_file(secrets_file_for(data_dir))[
        "APP_SECRET_KEY"
    ] != exported


def test_secrets_never_reach_the_log_file(tmp_path, monkeypatch):
    monkeypatch.delenv("APP_SECRET_KEY", raising=False)
    monkeypatch.delenv("JWT_SECRET_KEY", raising=False)
    data_dir = _data_dir(tmp_path)
    result = ensure_production_secrets(data_dir)
    app_secret = result.data["APP_SECRET_KEY"]
    jwt_secret = result.data["JWT_SECRET_KEY"]

    cfg = Settings(
        DATABASE_URL="sqlite:///:memory:",
        APP_SECRET_KEY=app_secret,
        JWT_SECRET_KEY=jwt_secret,
        LICENSE_STATE_DIR="",
        DATA_DIR=str(data_dir),
    )
    logging_module.setup_logging("INFO", cfg=cfg)

    logger = structlog.get_logger("secrets.probe")
    logger.info(
        "secrets_loaded",
        note=f"leaked={app_secret}",
        also=f"jwt={jwt_secret}",
        password="hunter2",
        activation_code="1234-5678",
    )
    for handler in logging.getLogger().handlers:
        handler.flush()

    log_file = Path(cfg.LOG_DIR) / cfg.LOG_FILE_NAME
    assert log_file.is_file()
    text = log_file.read_text(encoding="utf-8")

    assert app_secret not in text
    assert jwt_secret not in text
    assert "hunter2" not in text
    assert "1234-5678" not in text
    assert text.count("***") >= 4
    assert "secrets_loaded" in text


# ---------------------------------------------------------------------------
# Import order and placeholder rejection
# ---------------------------------------------------------------------------


def test_secrets_module_does_not_import_the_settings_module():
    """The launcher provisions secrets *before* Settings() exists."""
    import app.core.secrets as secrets_module

    source = Path(secrets_module.__file__).read_text(encoding="utf-8")
    assert "from app.core.config" not in source
    assert "import app.core.config" not in source
    assert "app.core.config" not in secrets_module.__dict__


def test_production_settings_refuse_every_known_placeholder():
    """R2 hardening: .env.example copy-paste values are rejected too."""
    for placeholder in sorted(PLACEHOLDERS):
        with pytest.raises(ValueError, match="placeholder"):
            Settings(
                APP_ENV="production",
                DATABASE_URL="sqlite:///:memory:",
                APP_SECRET_KEY=placeholder,
                JWT_SECRET_KEY="a-perfectly-fine-non-placeholder-secret",
                LICENSE_STATE_DIR="",
            )
        with pytest.raises(ValueError, match="placeholder"):
            Settings(
                APP_ENV="production",
                DATABASE_URL="sqlite:///:memory:",
                APP_SECRET_KEY="a-perfectly-fine-non-placeholder-secret",
                JWT_SECRET_KEY=placeholder,
                LICENSE_STATE_DIR="",
            )


def test_development_still_accepts_placeholders_with_a_warning():
    with pytest.warns(UserWarning, match="placeholder"):
        cfg = Settings(
            APP_ENV="development",
            DATABASE_URL="sqlite:///:memory:",
            APP_SECRET_KEY="change-me-in-production",
            JWT_SECRET_KEY="jwt-change-me-in-production",
            LICENSE_STATE_DIR="",
        )
    assert cfg.APP_ENV == "development"
