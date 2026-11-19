"""Supermarket Pro Backend Application."""

from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.core.config import (
    DataDirectoryError,
    ensure_data_dirs,
    legacy_data_locations,
    settings,
)
from app.core.exceptions import register_exception_handlers
from app.core.logging import setup_logging
from app.core.middleware import RequestIDMiddleware
from app.discovery.responder import start_discovery, stop_discovery
from app.licensing.trial import TrialManager

logger = structlog.get_logger(__name__)


def start_trial() -> bool:
    """Start (or re-attach to) this installation's Free Trial — Phase L1.

    Decision D5: the trial starts on the **first backend start** that finds
    no ``trial.state``; every later start re-attaches to the same state, so
    a restart never resets the 10-day clock.  Called from the lifespan and,
    like the discovery responder, it must never prevent the API from
    serving: any failure is logged and the request path then fails closed
    at the license guard instead.
    """
    try:
        status = TrialManager.from_settings().ensure_started()
    except Exception as exc:  # a state-file failure must never block startup
        logger.warning("trial_state_init_failed", error=str(exc))
        return False
    logger.info(
        "trial_state_ready",
        install_id=status.install_id,
        mode=status.mode,
        expires_at=status.expires_at.isoformat(),
    )
    return True


def _warn_if_production_enforcement_is_off() -> None:
    """Never let a production install disable licensing *silently* (R4 §3).

    `Settings` already defaults an omitted ``LICENSE_ENFORCEMENT`` to
    ``trial`` under ``APP_ENV=production``, so this only fires when the
    operator wrote ``off`` on purpose (or a stale configuration carried
    it over).  That choice stays legal — QA, a data-migration window, an
    owner who has not started billing yet — but it must be visible in the
    log instead of passing unnoticed.  Development never warns.
    """
    if settings.APP_ENV == "production" and settings.LICENSE_ENFORCEMENT == "off":
        logger.warning(
            "license_enforcement_disabled_in_production",
            enforcement="off",
            hint=(
                "set LICENSE_ENFORCEMENT=trial (Free Trial) or on (Lifetime or "
                "Free Trial) in <DATA_DIR>/config/.env"
            ),
        )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: startup and shutdown events.

    Phase 16: when ``DISCOVERY_ENABLED=1`` the UDP discovery responder is
    started here and stopped on shutdown. It binds ONE datagram port and
    is a convenience only — a bind failure never prevents the API from
    serving. With the flag off (default) nothing is bound at all.

    Phase L1: the Free Trial is initialized here on the first backend
    start (D5).  A state-file failure never blocks startup either.

    R1 (Windows production data paths): when ``DATA_DIR`` is configured
    the writable data layout is validated **before** anything writes —
    an inaccessible data root aborts startup with ``DataDirectoryError``
    (fail fast, audit B7) — and any pre-R1 data still sitting inside the
    install tree is reported as a migration hint.  It is never moved
    automatically.  Development (no ``DATA_DIR``) does neither.
    """
    setup_logging(settings.LOG_LEVEL)
    try:
        ensure_data_dirs()
    except DataDirectoryError:
        logger.critical(
            "data_dir_unavailable",
            data_dir=settings.DATA_DIR,
            error_hint="set DATA_DIR to a writable directory outside Program Files",
        )
        raise
    for legacy in legacy_data_locations():
        logger.warning(
            "legacy_data_not_migrated",
            path=str(legacy),
            data_dir=settings.DATA_DIR,
            hint="copy manually to the DATA_DIR layout (docs/R1_DATA_PATHS.md)",
        )
    start_trial()
    _warn_if_production_enforcement_is_off()
    discovery_started = start_discovery()
    try:
        yield
    finally:
        if discovery_started:
            stop_discovery()


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(
        title="Supermarket Pro API",
        description=(
            "Local-first supermarket POS and management system.\n\n"
            "API version: v1\n"
            "Features: Inventory management, POS, sales, purchases, "
            "customer/supplier management, debt tracking, and reporting."
        ),
        version=settings.VERSION,
        docs_url="/docs" if settings.APP_ENV != "production" else None,
        redoc_url="/redoc" if settings.APP_ENV != "production" else None,
        lifespan=lifespan,
        openapi_tags=[
            {"name": "health", "description": "Liveness and readiness probes"},
            {"name": "system", "description": "System information endpoints"},
        ],
    )

    # Middleware (order matters: first added = outermost)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(RequestIDMiddleware)

    # Exception handlers
    register_exception_handlers(app)

    # Routes
    app.include_router(api_router, prefix="/api/v1")

    return app


app = create_app()
