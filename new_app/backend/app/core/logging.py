"""Structured logging configuration.

Uses structlog for structured, contextual logging. Never logs secrets,
PINs, passwords, or JWT tokens.

R2 (Windows production runtime) adds an operational file sink and two
redaction layers:

* **File sink** — when file logging is enabled (auto: ``DATA_DIR`` is
  set) a :class:`logging.handlers.RotatingFileHandler` is attached to the
  root logger and writes ``<LOG_DIR>/<LOG_FILE_NAME>`` with
  ``%(asctime)s %(levelname)s %(name)s %(message)s`` on every line, size
  based rotation and a fixed number of retained files.  Development with
  no ``DATA_DIR`` keeps the historical stdout-only behaviour.
* **Key masker** (structlog processor) — values of sensitive *keys*
  (password, secret, token, activation code, private key, hardware id…)
  become ``***`` before the event is ever rendered.
* **Value scrubber** (renderer wrapper + handler filter) — the *actual*
  configured secret values (``APP_SECRET_KEY``, ``JWT_SECRET_KEY``, the
  database password) are removed from every rendered line, whichever
  handler receives it.

Failure to open the log file never blocks startup: the sink is dropped
with a stderr warning and stdout logging continues.
"""

from __future__ import annotations

import logging
import logging.handlers
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import structlog

#: Replacement written in place of anything sensitive.
MASK = "***"

#: Log-file rotation defaults (mirrored by the Settings defaults; the
#: Settings object always wins when present).
_DEFAULT_MAX_BYTES = 5 * 1024 * 1024
_DEFAULT_BACKUP_COUNT = 10

_SENSITIVE_KEY_RE = re.compile(
    r"(pass(?:word|wd)?|secret|token|api[_-]?key|authorization|"
    r"activation[_-]?code|private[_-]?key|machine[_-]?id|fingerprint|"
    r"credential)",
    re.IGNORECASE,
)

#: Shortest value that is safe to scrub by literal replacement — a very
#: short string would otherwise mangle unrelated log text.
_MIN_SCRUB_LENGTH = 4

_file_handler: logging.handlers.RotatingFileHandler | None = None


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------


def _redact_text(text: str, values: list[str]) -> str:
    """Replace every occurrence of a known secret with ``***``."""
    for value in values:
        if value and len(value) >= _MIN_SCRUB_LENGTH and value in text:
            text = text.replace(value, MASK)
    return text


def _mask_sensitive_keys(
    _logger: Any, _method: str, event_dict: dict[str, Any]
) -> dict[str, Any]:
    """structlog processor: blank out values of sensitive *keys*."""
    if not isinstance(event_dict, dict):
        return event_dict
    for key in list(event_dict):
        if isinstance(key, str) and _SENSITIVE_KEY_RE.search(key):
            event_dict[key] = MASK
    return event_dict


def _database_password(database_url: str) -> str:
    """Password embedded in ``DATABASE_URL`` (empty when there is none)."""
    if not database_url or "://" not in database_url:
        return ""
    try:
        return urlparse(database_url).password or ""
    except (ValueError, TypeError):
        return ""


def sensitive_values(cfg: Any) -> list[str]:
    """Secret values that must never appear in a log line."""
    values: list[str] = []
    for name in ("APP_SECRET_KEY", "JWT_SECRET_KEY"):
        value = (getattr(cfg, name, "") or "").strip()
        if value:
            values.append(value)
    password = _database_password(getattr(cfg, "DATABASE_URL", "") or "")
    if password:
        values.append(password)
    return values


def _build_renderer(cfg: Any):
    """Console renderer on a TTY, JSON otherwise — as before R2 — wrapped
    so every rendered line is scrubbed of the configured secret values
    before any handler (file *or* stdout) sees it."""
    base = (
        structlog.dev.ConsoleRenderer()
        if sys.stderr.isatty()
        else structlog.processors.JSONRenderer()
    )
    values = sensitive_values(cfg)

    def render(_logger: Any, _method: str, event_dict: Any) -> Any:
        rendered = base(_logger, _method, event_dict)
        return _redact_text(rendered, values) if isinstance(rendered, str) else rendered

    return render


class _RedactingFilter(logging.Filter):
    """Handler-level belt and braces for records that never pass through
    structlog (uvicorn, SQLAlchemy, third-party libraries)."""

    def __init__(self, values: list[str]) -> None:
        super().__init__()
        self._values = [v for v in values if len(v) >= _MIN_SCRUB_LENGTH]

    def filter(self, record: logging.LogRecord) -> bool:
        if not self._values:
            return True
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - a broken record must not kill logging
            return True
        redacted = _redact_text(message, self._values)
        if redacted != message:
            record.msg = redacted
            record.args = ()
        return True


# ---------------------------------------------------------------------------
# File sink
# ---------------------------------------------------------------------------


def file_logging_enabled(cfg: Any) -> bool:
    """Is the rotating file sink active for this configuration?

    ``LOG_FILE_ENABLED`` empty → auto (on exactly when ``DATA_DIR`` is
    set, i.e. production); ``1/true/yes/on`` forces it on, ``0/false/no/
    off`` forces it off.
    """
    flag = (getattr(cfg, "LOG_FILE_ENABLED", "") or "").strip().lower()
    if flag in ("1", "true", "yes", "on"):
        return True
    if flag in ("0", "false", "no", "off"):
        return False
    return bool((getattr(cfg, "DATA_DIR", "") or "").strip())


def _close_file_handler() -> None:
    global _file_handler
    if _file_handler is not None:
        logging.getLogger().removeHandler(_file_handler)
        _file_handler.close()
        _file_handler = None


def _configure_file_sink(cfg: Any, numeric_level: int) -> None:
    """Attach (or replace, or remove) the rotating file handler."""
    global _file_handler
    _close_file_handler()

    if not file_logging_enabled(cfg):
        return

    log_dir_raw = (getattr(cfg, "LOG_DIR", "") or "").strip()
    if not log_dir_raw:
        return
    log_dir = Path(log_dir_raw)
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(
            f"warning: cannot create log directory {log_dir} "
            f"({exc.__class__.__name__}); logging to stdout only",
            file=sys.stderr,
        )
        return

    file_name = (getattr(cfg, "LOG_FILE_NAME", "") or "").strip() or "backend.log"
    path = log_dir / file_name
    try:
        handler: logging.handlers.RotatingFileHandler = logging.handlers.RotatingFileHandler(
            path,
            maxBytes=int(getattr(cfg, "LOG_MAX_BYTES", _DEFAULT_MAX_BYTES)),
            backupCount=int(getattr(cfg, "LOG_BACKUP_COUNT", _DEFAULT_BACKUP_COUNT)),
            encoding="utf-8",
        )
    except OSError as exc:
        print(
            f"warning: cannot open log file {path} "
            f"({exc.__class__.__name__}); logging to stdout only",
            file=sys.stderr,
        )
        return

    # Timestamp + severity on every line.  structlog output already
    # carries both inside its payload; the prefix keeps foreign records
    # (uvicorn access lines, tracebacks) equally searchable.
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    )
    handler.setLevel(numeric_level)
    handler.addFilter(_RedactingFilter(sensitive_values(cfg)))
    logging.getLogger().addHandler(handler)
    _file_handler = handler


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def setup_logging(log_level: str = "INFO", cfg: Any = None) -> None:
    """Configure structured logging for the application.

    Idempotent: repeated calls (one per lifespan start) rebuild the
    renderer and replace the file handler instead of stacking them.

    Args:
        log_level: The minimum log level (DEBUG, INFO, WARNING, ERROR, CRITICAL).
        cfg: Settings object to read paths/secrets from.  Defaults to the
            process-wide ``app.core.config.settings``.
    """
    from app.core.config import settings as _global_settings

    target = _global_settings if cfg is None else cfg
    numeric_level = getattr(logging, log_level.upper(), logging.INFO)

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.filter_by_level,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            structlog.stdlib.PositionalArgumentsFormatter(),
            _mask_sensitive_keys,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.UnicodeDecoder(),
            _build_renderer(target),
        ],
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=numeric_level,
    )

    _configure_file_sink(target, numeric_level)

    # Suppress noisy third-party loggers
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("sqlalchemy.engine").setLevel(
        logging.INFO if log_level.upper() == "DEBUG" else logging.WARNING
    )
