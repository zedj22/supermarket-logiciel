"""Structured logging for Cloud Run (opt-in).

Cloud Run collects whatever the container writes to stdout/stderr.  Plain
uvicorn lines are fine for humans but awkward to query, so production sets
``LICENSE_API_LOG_JSON=1`` and the application's own events (written with
``structlog``) are emitted as one JSON object per line.

Access logs stay uvicorn's own format: Cloud Run already records method, path,
status and latency for every request, and that is the authoritative request log.

Only event names, reasons and identifiers are logged.  No token, activation
code, key material or secret value is ever passed to a logger — see the security
review in ``docs/security-review.md``.
"""

from __future__ import annotations

import logging
import os
import sys
from collections.abc import Mapping

__all__ = ["configure_logging", "logging_enabled"]

_TRUTHY = ("1", "true", "yes", "on")


def logging_enabled(environ: Mapping[str, str] | None = None) -> bool:
    env = os.environ if environ is None else environ
    return (env.get("LICENSE_API_LOG_JSON") or "").strip().lower() in _TRUTHY


def configure_logging(environ: Mapping[str, str] | None = None) -> bool:
    """Switch structlog to JSON on stdout.  Returns True when it did.

    Idempotent and cheap: the API factory calls it on every start, and a local
    run (variable unset) is left completely alone so the developer keeps the
    human-readable output.
    """
    if not logging_enabled(environ):
        return False
    try:
        import structlog
    except ImportError:  # pragma: no cover - deployment dependency
        return False

    structlog.configure(
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.JSONRenderer(sort_keys=True),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stdout),
        cache_logger_on_first_use=False,
    )
    return True
