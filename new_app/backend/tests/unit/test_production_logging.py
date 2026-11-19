"""R2: production file logging (``app.core.logging``).

Contract under test:

* the rotating file sink is created under ``<DATA_DIR>/logs`` (auto-on
  when ``DATA_DIR`` is set) and development stays stdout-only;
* every line carries ``%(asctime)s %(levelname)s %(name)s``;
* size based rotation keeps exactly ``LOG_BACKUP_COUNT`` backups;
* sensitive *keys* are masked and the configured secret *values* are
  scrubbed from every line, including records that never pass through
  structlog (third-party libraries);
* an unusable log directory never blocks startup;
* repeated ``setup_logging`` calls replace the handler instead of
  stacking them.
"""

from __future__ import annotations

import io
import logging
import re
from pathlib import Path

import pytest
import structlog

from app.core import logging as logging_module
from app.core.config import BACKEND_ROOT, Settings

APP_SECRET = "prod-app-secret-value-0123456789abcdefghijklmnop"
JWT_SECRET = "prod-jwt-secret-value-0123456789abcdefghij"

#: The exact per-line prefix R2 promises (timestamp, severity, logger).
_LINE_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} (INFO|WARNING|ERROR|DEBUG|CRITICAL) \S+ "
)


@pytest.fixture(autouse=True)
def _isolate_logging():
    saved = structlog.get_config()
    root = logging.getLogger()
    saved_level = root.level
    root.setLevel(logging.INFO)
    yield
    logging_module._close_file_handler()
    root.setLevel(saved_level)
    structlog.configure(**saved)


def _settings(tmp_path: Path, **overrides) -> Settings:
    """Production-shaped settings pointing at a throwaway data root."""
    base: dict = {
        "DATABASE_URL": "sqlite:///:memory:",
        "APP_SECRET_KEY": APP_SECRET,
        "JWT_SECRET_KEY": JWT_SECRET,
        "LICENSE_STATE_DIR": "",
        "DATA_DIR": str(tmp_path / "ProgramData" / "SupermarketPro"),
    }
    base.update(overrides)
    return Settings(**base)


def _flush() -> None:
    for handler in logging.getLogger().handlers:
        handler.flush()


def _log_file(cfg: Settings) -> Path:
    return Path(cfg.LOG_DIR) / cfg.LOG_FILE_NAME


# ---------------------------------------------------------------------------
# Enablement + location
# ---------------------------------------------------------------------------


def test_file_logging_is_auto_enabled_with_data_dir():
    cfg = Settings(
        DATABASE_URL="sqlite:///:memory:",
        APP_SECRET_KEY=APP_SECRET,
        JWT_SECRET_KEY=JWT_SECRET,
        LICENSE_STATE_DIR="",
        DATA_DIR=r"C:\ProgramData\SupermarketPro",
    )
    assert logging_module.file_logging_enabled(cfg) is True
    assert cfg.LOG_DIR == str(Path(r"C:\ProgramData\SupermarketPro") / "logs")


def test_file_logging_is_off_in_development():
    cfg = Settings(
        DATABASE_URL="sqlite:///:memory:",
        APP_SECRET_KEY=APP_SECRET,
        JWT_SECRET_KEY=JWT_SECRET,
        LICENSE_STATE_DIR="",
        DATA_DIR="",
    )
    assert logging_module.file_logging_enabled(cfg) is False
    # LOG_DIR still resolves (backend root / logs) but nothing is opened.
    assert cfg.LOG_DIR == str(BACKEND_ROOT / "logs")


@pytest.mark.parametrize("flag,expected", [
    ("1", True),
    ("true", True),
    ("YES", True),
    ("on", True),
    ("0", False),
    ("false", False),
    ("NO", False),
    ("off", False),
    ("", None),
])
def test_log_file_enabled_flag_normalisation(flag, expected):
    cfg = Settings(
        DATABASE_URL="sqlite:///:memory:",
        APP_SECRET_KEY=APP_SECRET,
        JWT_SECRET_KEY=JWT_SECRET,
        LICENSE_STATE_DIR="",
        DATA_DIR=str(Path(r"C:\ProgramData\SupermarketPro")),
        LOG_FILE_ENABLED=flag,
    )
    if expected is None:  # auto
        assert logging_module.file_logging_enabled(cfg) is True
    else:
        assert logging_module.file_logging_enabled(cfg) is expected
    # The validator normalises the raw value to lowercase.
    assert cfg.LOG_FILE_ENABLED == flag.strip().lower()


def test_development_keeps_stdout_only(tmp_path):
    cfg = _settings(tmp_path, DATA_DIR="")
    logging_module.setup_logging("INFO", cfg=cfg)
    assert logging_module._file_handler is None
    assert not any(
        isinstance(h, logging.handlers.RotatingFileHandler)
        for h in logging.getLogger().handlers
    )


# ---------------------------------------------------------------------------
# Creation, format, rotation
# ---------------------------------------------------------------------------


def test_setup_logging_creates_the_log_file(tmp_path):
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)

    assert logging_module._file_handler is not None
    assert logging_module._file_handler.baseFilename == str(_log_file(cfg))
    assert _log_file(cfg).parent.is_dir()


def test_every_line_carries_timestamp_severity_and_logger(tmp_path):
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)

    structlog.get_logger("app.probe").info("format_probe", value=1)
    logging.getLogger("thirdparty.library").warning("foreign warning line")
    _flush()

    lines = [
        line
        for line in _log_file(cfg).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert lines, "log file must not be empty"
    for line in lines:
        assert _LINE_RE.match(line), f"unexpected line format: {line!r}"
    joined = "\n".join(lines)
    assert "format_probe" in joined
    assert "foreign warning line" in joined
    assert " app.probe " in joined


def test_rotation_keeps_exactly_the_configured_backups(tmp_path):
    cfg = _settings(
        tmp_path,
        LOG_MAX_BYTES=1024,
        LOG_BACKUP_COUNT=2,
        LOG_FILE_NAME="rotate.log",
    )
    logging_module.setup_logging("INFO", cfg=cfg)
    logger = structlog.get_logger("rotate.probe")
    for index in range(400):
        logger.info("rotation_probe", index=index, padding="x" * 120)
    _flush()

    log_dir = Path(cfg.LOG_DIR)
    rotated = sorted(p.name for p in log_dir.glob("rotate.log.*"))
    assert rotated, "rotation must have happened"
    assert rotated == ["rotate.log.1", "rotate.log.2"], rotated
    assert (log_dir / "rotate.log").is_file()
    # Retained volume stays bounded: base + backups.
    total = sum(p.stat().st_size for p in log_dir.glob("rotate.log*"))
    assert total <= 3 * 1024 + 4096


def test_setup_logging_is_idempotent(tmp_path):
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)
    first = logging_module._file_handler
    logging_module.setup_logging("INFO", cfg=cfg)
    second = logging_module._file_handler

    assert first is not second  # the handler is replaced, not shared
    file_handlers = [
        h
        for h in logging.getLogger().handlers
        if isinstance(h, logging.handlers.RotatingFileHandler)
    ]
    assert len(file_handlers) == 1  # never stacked


def test_unusable_log_directory_never_blocks_startup(tmp_path, capsys):
    blocker = tmp_path / "logs-are-a-file"
    blocker.write_text("not a directory", encoding="utf-8")
    cfg = _settings(tmp_path, LOG_DIR=str(blocker))

    logging_module.setup_logging("INFO", cfg=cfg)  # must not raise

    assert logging_module._file_handler is None
    captured = capsys.readouterr()
    assert "cannot create log directory" in captured.err


def test_log_file_name_must_be_a_bare_name(tmp_path):
    with pytest.raises(ValueError, match="LOG_FILE_NAME"):
        _settings(tmp_path, LOG_FILE_NAME="..\\escape\\backend.log")
    with pytest.raises(ValueError, match="LOG_MAX_BYTES"):
        _settings(tmp_path, LOG_MAX_BYTES=10)
    with pytest.raises(ValueError, match="LOG_BACKUP_COUNT"):
        _settings(tmp_path, LOG_BACKUP_COUNT=-1)
    with pytest.raises(ValueError, match="LOG_FILE_ENABLED"):
        _settings(tmp_path, LOG_FILE_ENABLED="maybe")


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------


def test_sensitive_keys_are_masked_before_rendering(tmp_path):
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)

    structlog.get_logger("redaction.probe").info(
        "key_masking",
        password="hunter2",
        api_key="sk-live-123",
        activation_code="9999-1111",
        machine_id="HW-42",
        private_key="-----BEGIN",
        bearer_token="abc.def.ghi",
        plain="visible-value",
    )
    _flush()

    text = _log_file(cfg).read_text(encoding="utf-8")
    for leaked in (
        "hunter2",
        "sk-live-123",
        "9999-1111",
        "HW-42",
        "-----BEGIN",
        "abc.def.ghi",
    ):
        assert leaked not in text, f"leaked {leaked}"
    assert "key_masking" in text
    assert "visible-value" in text
    assert text.count("***") >= 6


def test_configured_secret_values_are_scrubbed_from_free_text(tmp_path):
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)

    # Free-text leakage: the value is interpolated into the message.
    structlog.get_logger("redaction.probe").info(
        "value_scrubbing",
        note=f"session signed with {APP_SECRET} and {JWT_SECRET}",
    )
    # A non-structlog record must be scrubbed by the handler filter.
    logging.getLogger("sqlalchemy.engine").warning(
        "connect failed using password %s", APP_SECRET
    )
    _flush()

    text = _log_file(cfg).read_text(encoding="utf-8")
    assert APP_SECRET not in text
    assert JWT_SECRET not in text
    assert "value_scrubbing" in text
    assert "connect failed" in text
    assert "***" in text


def test_structlog_output_is_scrubbed_before_any_handler_sees_it(tmp_path):
    """The renderer must scrub the line, not just the file sink."""
    cfg = _settings(tmp_path)
    logging_module.setup_logging("INFO", cfg=cfg)

    buffer = io.StringIO()
    capture = logging.StreamHandler(buffer)
    capture.setFormatter(logging.Formatter("%(message)s"))
    root = logging.getLogger()
    root.addHandler(capture)
    try:
        structlog.get_logger("stdout.probe").info(
            "free_text", note=f"session signed with {APP_SECRET}"
        )
        capture.flush()
    finally:
        root.removeHandler(capture)

    captured = buffer.getvalue()
    assert "free_text" in captured
    assert APP_SECRET not in captured


def test_database_password_in_the_url_is_scrubbed(tmp_path):
    cfg = _settings(
        tmp_path,
        DATABASE_URL="postgresql://supermarket:db-password-123@localhost/supermarket",
    )
    logging_module.setup_logging("INFO", cfg=cfg)

    structlog.get_logger("redaction.probe").info(
        "url_probe", url=cfg.DATABASE_URL
    )
    logging.getLogger("sqlalchemy.engine").warning(
        "connecting to %s", cfg.DATABASE_URL
    )
    _flush()

    text = _log_file(cfg).read_text(encoding="utf-8")
    assert "db-password-123" not in text
