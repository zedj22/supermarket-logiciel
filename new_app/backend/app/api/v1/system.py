"""API system info endpoint -- Phase 3 foundation demonstration.

This endpoint demonstrates the full Phase 3 architecture:
Router → Schema → Service → Repository → Database

It is intentionally non-business to serve as a reference implementation
that is easy to test, understand, and extend. It will be removed or
repurposed once real business modules exist.

Returns basic system information (name, version, environment, database status).
"""

from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.constants import APP_VERSION
from app.db.session import get_db
from app.schemas.common import StrictBaseModel

logger = structlog.get_logger(__name__)

router = APIRouter()


# ---------------------------------------------------------------------------
# Response schema
# ---------------------------------------------------------------------------


class SystemInfoResponse(StrictBaseModel):
    """System information response."""

    name: str
    version: str
    environment: str
    database_status: str
    timestamp: str


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


def get_system_info(db: Session) -> SystemInfoResponse:
    """Fetch system information.

    Demonstrates the service layer pattern: business logic
    that reads from the database and returns a Pydantic schema.
    """
    db_status = "connected"
    try:
        db.execute(text("SELECT 1"))
    except Exception as exc:
        logger.error("system_info_db_check_failed", error=str(exc))
        db_status = "disconnected"

    return SystemInfoResponse(
        name=settings.STORE_NAME,
        version=APP_VERSION,
        environment=settings.APP_ENV,
        database_status=db_status,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------


@router.get("/system/info", response_model=SystemInfoResponse, tags=["system"])
async def system_info(db: Session = Depends(get_db)) -> SystemInfoResponse:
    """Return basic system information.

    This endpoint demonstrates the full request flow:
    - FastAPI router handles HTTP
    - Dependency injection provides the database session
    - Service function performs the logic
    - Pydantic schema defines the response contract

    Returns:
        SystemInfoResponse with application name, version, and database status.
    """
    return get_system_info(db)
