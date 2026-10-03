"""Supermarket Pro Backend Application."""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import api_router
from app.core.config import settings
from app.core.exceptions import register_exception_handlers
from app.core.logging import setup_logging
from app.core.middleware import RequestIDMiddleware
from app.discovery.responder import start_discovery, stop_discovery


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: startup and shutdown events.

    Phase 16: when ``DISCOVERY_ENABLED=1`` the UDP discovery responder is
    started here and stopped on shutdown. It binds ONE datagram port and
    is a convenience only — a bind failure never prevents the API from
    serving. With the flag off (default) nothing is bound at all.
    """
    setup_logging(settings.LOG_LEVEL)
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
