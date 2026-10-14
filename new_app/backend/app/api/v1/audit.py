"""Audit trail read API (slice A).

Endpoints (ALL read-only — this surface can never mutate state):

- GET /api/v1/audit          filtered, time-descending page of events
- GET /api/v1/audit/summary  aggregate counts for the same filters
- GET /api/v1/audit/{id}     one event with parsed snapshots + diff

Every route requires the ``audit_view`` permission scope (reserved until
now; admin has it via ``list(PermissionScope)``, manager/cashier do not).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.core.exceptions import NotFoundError
from app.db.session import get_db
from app.models.audit import AuditLog
from app.models.enums import PermissionScope
from app.schemas.audit import (
    AuditEventListResponse,
    AuditEventResponse,
    AuditSummaryResponse,
)
from app.services.audit import AuditService, build_diff, loads_json

router = APIRouter()

UNKNOWN_OUTCOME = "unknown"
DELETED_ACTOR_LABEL = "deleted user"


def _get_service(db: Session = Depends(get_db)) -> AuditService:
    return AuditService(db)


def _serialize(row: AuditLog) -> AuditEventResponse:
    """Map one ORM row to the API contract.

    * ``recorded_at`` is the mixin's ``created_at`` (no duplicate column);
    * NULL outcome (legacy row) is surfaced as ``unknown`` — never as
      an invented "success";
    * ``actor_name`` falls back to the joined user, then to a
      ``deleted user`` marker when the FK was SET NULL;
    * ``diff`` is computed on read from the stored snapshots.
    """
    before = loads_json(row.before_state)
    after = loads_json(row.after_state)

    actor_name = row.actor_name
    if actor_name is None and row.user is not None:
        actor_name = row.user.full_name
    if actor_name is None and row.user_id is not None:
        actor_name = DELETED_ACTOR_LABEL

    return AuditEventResponse(
        id=row.id,
        occurred_at=row.action_at,
        recorded_at=row.created_at,
        outcome=row.outcome or UNKNOWN_OUTCOME,
        module=row.module,
        action=row.action,
        actor_id=row.user_id,
        actor_name=actor_name,
        device_id=row.device_id,
        device_name=row.device_name,
        device_verified=row.device_verified,
        session_id=row.session_id,
        request_id=row.request_id,
        ip_address=row.ip_address,
        entity_type=row.entity_type,
        entity_id=row.entity_id,
        entity_ref=row.entity_ref,
        reason=row.reason,
        details=row.details,
        before=before,
        after=after,
        diff=build_diff(before, after) if (before is not None or after is not None) else None,
        metadata=loads_json(row.metadata_json),
    )


def _tz_naive_as_utc(value: datetime | None) -> datetime | None:
    """Accept offset-less ISO datetimes as UTC (query-param convenience)."""
    if value is not None and value.tzinfo is None:
        from datetime import timezone

        return value.replace(tzinfo=timezone.utc)
    return value


@router.get(
    "",
    response_model=AuditEventListResponse,
    summary="List audit events",
    tags=["audit"],
)
def list_audit_events(
    request: Request,
    date_from: Annotated[datetime | None, Query(description="Inclusive lower bound on occurred_at")] = None,
    date_to: Annotated[datetime | None, Query(description="Inclusive upper bound on occurred_at")] = None,
    user_id: Annotated[uuid.UUID | None, Query()] = None,
    device_id: Annotated[str | None, Query(max_length=100)] = None,
    module: Annotated[str | None, Query(max_length=30)] = None,
    action: Annotated[str | None, Query(max_length=30)] = None,
    outcome: Annotated[str | None, Query(max_length=10)] = None,
    entity_type: Annotated[str | None, Query(max_length=50)] = None,
    entity_id: Annotated[uuid.UUID | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200, description="Free text: details, reason, entity_ref, actor")] = None,
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)] = DEFAULT_PAGE_SIZE,
    user=Depends(require_permission(PermissionScope.AUDIT_VIEW)),
    service: AuditService = Depends(_get_service),
) -> AuditEventListResponse:
    """Filtered audit trail page, newest first."""
    rows, total = service.list_events(
        date_from=_tz_naive_as_utc(date_from),
        date_to=_tz_naive_as_utc(date_to),
        user_id=user_id,
        device_id=device_id,
        module=module,
        action=action,
        outcome=outcome,
        entity_type=entity_type,
        entity_id=entity_id,
        q=q,
        page=page,
        page_size=page_size,
    )
    pages = (total + page_size - 1) // page_size if page_size else 0
    return AuditEventListResponse(
        items=[_serialize(row) for row in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )


@router.get(
    "/summary",
    response_model=AuditSummaryResponse,
    summary="Audit event counts for the filtered window",
    tags=["audit"],
)
def audit_summary(
    request: Request,
    date_from: Annotated[datetime | None, Query()] = None,
    date_to: Annotated[datetime | None, Query()] = None,
    user_id: Annotated[uuid.UUID | None, Query()] = None,
    device_id: Annotated[str | None, Query(max_length=100)] = None,
    module: Annotated[str | None, Query(max_length=30)] = None,
    action: Annotated[str | None, Query(max_length=30)] = None,
    outcome: Annotated[str | None, Query(max_length=10)] = None,
    entity_type: Annotated[str | None, Query(max_length=50)] = None,
    entity_id: Annotated[uuid.UUID | None, Query()] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
    user=Depends(require_permission(PermissionScope.AUDIT_VIEW)),
    service: AuditService = Depends(_get_service),
) -> AuditSummaryResponse:
    """Aggregate counts (total / outcomes / by action / by module)."""
    data = service.summary(
        date_from=_tz_naive_as_utc(date_from),
        date_to=_tz_naive_as_utc(date_to),
        user_id=user_id,
        device_id=device_id,
        module=module,
        action=action,
        outcome=outcome,
        entity_type=entity_type,
        entity_id=entity_id,
        q=q,
    )
    return AuditSummaryResponse(**data)


@router.get(
    "/{event_id}",
    response_model=AuditEventResponse,
    summary="Audit event detail",
    tags=["audit"],
)
def get_audit_event(
    event_id: uuid.UUID,
    request: Request,
    user=Depends(require_permission(PermissionScope.AUDIT_VIEW)),
    service: AuditService = Depends(_get_service),
) -> AuditEventResponse:
    """One event with parsed before/after snapshots and computed diff."""
    row = service.get_event(event_id)
    if row is None:
        raise NotFoundError(
            message="Audit event not found",
            details={"event_id": str(event_id)},
        )
    return _serialize(row)
