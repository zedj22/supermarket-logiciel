"""API system info endpoint -- Phase 3 foundation demonstration.

This endpoint demonstrates the full Phase 3 architecture:
Router → Schema → Service → Repository → Database

It is intentionally non-business to serve as a reference implementation
that is easy to test, understand, and extend. It will be removed or
repurposed once real business modules exist.

Returns basic system information (name, version, environment, database
status). Phase L1-B adds an informational ``license`` field carrying the
Free Trial clock (trial/expired/unavailable) — read-only, never a
licensing decision and never a reason to fail the request.
"""

from datetime import datetime, timezone
from typing import Literal

import structlog
from fastapi import APIRouter, Depends
from pydantic import Field
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.constants import APP_VERSION
from app.core.server_identity import get_server_id
from app.db.session import get_db
from app.licensing.state_store import StateStoreError
from app.licensing.trial import TrialManager
from app.schemas.common import StrictBaseModel
from app.schemas.device import PROTOCOL_VERSION

logger = structlog.get_logger(__name__)

router = APIRouter()


# ---------------------------------------------------------------------------
# Response schema
# ---------------------------------------------------------------------------


class LicenseInfo(StrictBaseModel):
    """Informational licensing/trial snapshot (Phase L1-B).

    Built exclusively from the existing `TrialManager.status()` — never
    `ensure_started()` — so reading it can neither create nor restart a
    trial, and it reports a controlled ``unknown``/``unavailable`` when
    the state is missing or cannot be verified (same fail-closed
    exception family as the license guard, minus the HTTP error: this
    field is informational and the endpoint must keep answering, since
    discovery probes rely on it).

    Deliberately limited to the trial clock: no hardware identifiers,
    no fingerprint, no HMAC/DPAPI material, no state-file contents and
    no filesystem paths ever appear here (§13.1).
    """

    mode: Literal["trial", "trial_expired", "unknown"] = "unknown"
    status: Literal["active", "expired", "unavailable"] = "unavailable"
    trial_active: bool = False
    trial_expired: bool = False
    first_launch_at: str | None = None
    expires_at: str | None = None
    observed_at: str | None = None
    remaining_seconds: int = Field(default=0, ge=0)
    trial_days: int = Field(default_factory=lambda: settings.TRIAL_DAYS, ge=1)


class SystemInfoResponse(StrictBaseModel):
    """System information response.

    Phase 16 (§8.2) adds TWO additive fields — nothing existing changed:

    ``protocol``  the discovery/contract protocol version this server
                  speaks. A client refuses an offer whose protocol does
                  not match its own.
    ``server_id`` a stable UUIDv4 identity (never an IP address) so a
                  paired device can tell "my store's server" from any
                  other box answering the same port. It is public
                  metadata, not a credential, and it survives DHCP/IP
                  changes.

    Phase L1-B adds one more additive, defaulted field:

    ``license``   the Free Trial clock (see `LicenseInfo`). Optional for
                  clients: existing parsers that ignore unknown keys are
                  unaffected, and constructing this model without the
                  field still yields a valid "unavailable" snapshot.
    """

    name: str
    version: str
    environment: str
    database_status: str
    timestamp: str
    protocol: int = 1
    server_id: str = ""
    license: LicenseInfo = Field(default_factory=LicenseInfo)


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


def _license_info() -> LicenseInfo:
    """Current trial snapshot for the informational ``license`` field.

    Reads `TrialManager.status()` only — never `ensure_started()` — so a
    GET of ``/system/info`` can never create or restart a trial.  A
    missing state and an unverifiable state both answer the same
    controlled ``unknown``/``unavailable`` payload with null timestamps:
    the guard's exception family (``StateStoreError``/``OSError``/
    ``ValueError``) is caught here instead of raised, because this field
    is informational and discovery probes must keep succeeding — but the
    semantics stay fail-closed, never "active" when the state cannot be
    trusted, and no internal detail reaches the response.
    """
    try:
        status = TrialManager.from_settings().status()
    except (StateStoreError, OSError, ValueError):
        logger.warning("system_info_license_state_unavailable")
        return LicenseInfo(trial_days=settings.TRIAL_DAYS)
    if status is None:
        return LicenseInfo(trial_days=settings.TRIAL_DAYS)
    return LicenseInfo(
        mode=status.mode,
        status="active" if status.active else "expired",
        trial_active=status.active,
        trial_expired=status.expired,
        first_launch_at=status.first_launch_at.isoformat(),
        expires_at=status.expires_at.isoformat(),
        observed_at=status.observed_at.isoformat(),
        remaining_seconds=max(0, int(status.remaining.total_seconds())),
        trial_days=status.trial_days,
    )


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
        protocol=PROTOCOL_VERSION,
        server_id=get_server_id(),
        license=_license_info(),
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
        SystemInfoResponse with application name, version, database
        status and the informational ``license`` trial snapshot (Phase
        L1-B; never a licensing decision, never a failed request).
    """
    return get_system_info(db)
