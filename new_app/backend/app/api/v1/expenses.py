"""Expenses API endpoints (Phase 13).

- POST /api/v1/expenses             — record one expense (idempotent)
- GET  /api/v1/expenses             — filtered, paginated list
- GET  /api/v1/expenses/summary     — count / total / drawer / external
- POST /api/v1/expenses/{id}/cancel — posted → cancelled, reason mandatory

Permissions (GATE 7/8/9, §11 role matrix): admin, manager and cashier all
hold expense_view / expense_create / expense_cancel; the checks stay on
every handler so a narrower role can be seeded later without touching
this module.

The server assigns id / expense_date / user_id / status — never accepted
from the body (B6/B7), and ``X-Device-ID`` carries the device attribution
(Phase 12 convention, D5/D7 deviation from legacy).
"""

from __future__ import annotations

import uuid
from datetime import date

from fastapi import APIRouter, Depends, Header, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.common import PaginatedResponse
from app.schemas.expense import (
    ExpenseCancelRequest,
    ExpenseCreateRequest,
    ExpenseResponse,
    ExpenseSummaryResponse,
)
from app.services.expenses import ExpenseService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ExpenseService:
    return ExpenseService(db)


@router.post(
    "",
    response_model=ExpenseResponse,
    status_code=201,
    summary="Record an expense",
    tags=["expenses"],
)
def create_expense(
    request: ExpenseCreateRequest,
    user: User = Depends(require_permission(PermissionScope.EXPENSE_CREATE)),
    service: ExpenseService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> ExpenseResponse:
    """Record one money-out atomically (row + CREATE audit).

    Idempotency: ``client_request_id`` is required; the same key with the
    same payload returns the original row with ``idempotent_replay=true``,
    a different payload is 409 IDEMPOTENCY_CONFLICT. ``expense_date`` is
    server-assigned — backdating is not supported (B7).
    """
    return service.create(request, user=user, device_id=x_device_id)


@router.get(
    "",
    response_model=PaginatedResponse[ExpenseResponse],
    summary="List expenses",
    tags=["expenses"],
)
def list_expenses(
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=100),
    q: str | None = Query(None, max_length=200),
    category: str | None = Query(None, max_length=30),
    paid_from_drawer: bool | None = Query(None),
    date_from: date | None = Query(None),
    date_to: date | None = Query(None),
    status: str = Query("posted", pattern="^(posted|cancelled|all)$"),
    user: User = Depends(require_permission(PermissionScope.EXPENSE_VIEW)),
    service: ExpenseService = Depends(_get_service),
) -> PaginatedResponse[ExpenseResponse]:
    """Filtered list, newest first. Cancelled rows are hidden by default."""
    return service.list(
        page=page,
        page_size=page_size,
        q=q,
        category=category,
        paid_from_drawer=paid_from_drawer,
        date_from=date_from,
        date_to=date_to,
        status=status,
    )


@router.get(
    "/summary",
    response_model=ExpenseSummaryResponse,
    summary="Expense summary totals",
    tags=["expenses"],
)
def expense_summary(
    q: str | None = Query(None, max_length=200),
    category: str | None = Query(None, max_length=30),
    paid_from_drawer: bool | None = Query(None),
    date_from: date | None = Query(None),
    date_to: date | None = Query(None),
    status: str = Query("posted", pattern="^(posted|cancelled|all)$"),
    user: User = Depends(require_permission(PermissionScope.EXPENSE_VIEW)),
    service: ExpenseService = Depends(_get_service),
) -> ExpenseSummaryResponse:
    """count / total / drawer / external over the same filters (W2).

    ``drawer_amount + external_amount == total_amount``; cancelled rows are
    excluded unless ``status`` says otherwise (B11).
    """
    return service.summary(
        q=q,
        category=category,
        paid_from_drawer=paid_from_drawer,
        date_from=date_from,
        date_to=date_to,
        status=status,
    )


@router.post(
    "/{expense_id}/cancel",
    response_model=ExpenseResponse,
    summary="Cancel an expense",
    tags=["expenses"],
)
def cancel_expense(
    expense_id: uuid.UUID,
    request: ExpenseCancelRequest,
    user: User = Depends(require_permission(PermissionScope.EXPENSE_CANCEL)),
    service: ExpenseService = Depends(_get_service),
) -> ExpenseResponse:
    """posted → cancelled with a mandatory reason (B10).

    The row is retained (never deleted) and VOID-audited; the status guard
    makes a second cancellation 409 EXPENSE_ALREADY_CANCELLED (GATE 11).
    """
    return service.cancel(expense_id, request, user=user)
