"""Returns API endpoints (Phase 12).

- POST   /api/v1/returns                 — Post a return (linked or
                                           independent), idempotent
- GET    /api/v1/returns                 — Return history (filters)
- GET    /api/v1/returns/{return_id}     — Return detail / reprint

Permissions: pos_return only (GATE 15 — no new scopes are introduced, and
voiding a sale is pos_void, its own existing scope).

Money crosses the wire as decimal strings (schema Decimal fields) and the
client never sends a refund amount: the server values every line from the
persisted sale economics, so a client cannot choose its own money (§12).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Header, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.returns import (
    ReturnCreateRequest,
    ReturnCreateResponse,
    ReturnListResponse,
    ReturnResponse,
)
from app.services.returns import ReturnService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ReturnService:
    return ReturnService(db)


@router.post(
    "",
    response_model=ReturnCreateResponse,
    status_code=201,
    summary="Post a return",
    tags=["returns"],
)
def create_return(
    request: ReturnCreateRequest,
    user: User = Depends(require_permission(PermissionScope.POS_RETURN)),
    service: ReturnService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> ReturnCreateResponse:
    """Post a return document atomically (stock + movements + debt + audit).

    ``sale_id`` set → linked return (refunds come from the sale's own
    persisted economics, capped per source line); ``sale_id`` absent →
    independent return (refund at the current price, no cap to apply).

    Idempotency: ``client_request_id`` is required; a repeat with the same
    payload returns the original document with ``idempotent_replay=true``,
    a repeat with a different payload is 409 IDEMPOTENCY_CONFLICT.
    """
    return service.post(request, user=user, device_id=x_device_id)


@router.get(
    "",
    response_model=ReturnListResponse,
    summary="List returns",
    tags=["returns"],
)
def list_returns(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    sale_id: uuid.UUID | None = Query(None),
    invoice_number: str | None = Query(None, max_length=100),
    from_: datetime | None = Query(None, alias="from"),
    to: datetime | None = Query(None),
    reason: str | None = Query(None, max_length=50),
    user: User = Depends(require_permission(PermissionScope.POS_RETURN)),
    service: ReturnService = Depends(_get_service),
) -> ReturnListResponse:
    """Paginated history with the §22 filters (all optional)."""
    return service.list(
        page=page,
        page_size=page_size,
        sale_id=sale_id,
        invoice_number=invoice_number,
        date_from=from_,
        date_to=to,
        reason=reason,
    )


@router.get(
    "/{return_id}",
    response_model=ReturnResponse,
    summary="Get return by id",
    tags=["returns"],
)
def get_return(
    return_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_RETURN)),
    service: ReturnService = Depends(_get_service),
) -> ReturnResponse:
    return service.get(return_id)
