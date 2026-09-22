"""Health check endpoints.

Provides liveness and readiness probes. Does NOT expose
secrets, passwords, internal paths, or stack traces.
"""

from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.constants import APP_VERSION
from app.db.session import get_db

logger = structlog.get_logger(__name__)

router = APIRouter()


class HealthResponse(BaseModel):
    """Response model for the health endpoint."""

    status: str
    version: str
    environment: str
    database: str
    timestamp: str


class LivenessResponse(BaseModel):
    """Simple liveness check — is the process running?"""

    status: str


class ReadinessResponse(BaseModel):
    """Readiness check — can the application serve requests?"""

    status: str
    database: str


@router.get("/health", response_model=HealthResponse)
async def health_check(db: Session = Depends(get_db)) -> HealthResponse:
    """Full health check: application + database connectivity.

    Returns:
        HealthResponse with status, version, environment, and database status.
    """
    db_status = "connected"
    try:
        db.execute(text("SELECT 1"))
    except Exception as exc:
        logger.error("health_check_db_failed", error=str(exc))
        db_status = "disconnected"

    return HealthResponse(
        status="healthy" if db_status == "connected" else "degraded",
        version=APP_VERSION,
        environment=settings.APP_ENV,
        database=db_status,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )


@router.get("/health/live", response_model=LivenessResponse)
async def liveness() -> LivenessResponse:
    """Liveness probe — indicates the process is running.

    Returns:
        LivenessResponse with status.
    """
    return LivenessResponse(status="alive")


@router.get("/health/ready", response_model=ReadinessResponse)
async def readiness(db: Session = Depends(get_db)) -> ReadinessResponse:
    """Readiness probe — indicates the application can serve requests.

    Checks database connectivity. Returns unhealthy if database is down.

    Returns:
        ReadinessResponse with status and database status.
    """
    db_status = "connected"
    try:
        db.execute(text("SELECT 1"))
    except Exception as exc:
        logger.error("readiness_check_db_failed", error=str(exc))
        db_status = "disconnected"

    status = "ready" if db_status == "connected" else "not_ready"

    return ReadinessResponse(
        status=status,
        database=db_status,
    )
