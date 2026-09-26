"""Minimal customers API for POS (Phase 8 Step 3).

Endpoints:
- GET /api/v1/customers/search?q=  — name/phone search (pos picker)
- GET /api/v1/customers            — list (minimal)

Full customer CRUD is Phase 9. This module only exposes the read
surface required for partial/credit sales in the POS.
"""

from __future__ import annotations

import math

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.party import Customer
from app.models.user import User
from app.schemas.party import CustomerListResponse, CustomerResponse

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


def _to_response(customer: Customer) -> CustomerResponse:
    return CustomerResponse(
        id=customer.id,
        name=customer.name,
        phone=customer.phone,
        address=customer.address,
        balance=float(customer.balance or 0),
        debt_ceiling=float(customer.debt_ceiling or 0),
        is_archived=customer.archived_at is not None,
        created_at=customer.created_at,
        updated_at=customer.updated_at,
    )


def _search_stmt(q: str | None, include_archived: bool):
    stmt = select(Customer)
    if not include_archived:
        stmt = stmt.where(Customer.archived_at.is_(None))
    if q:
        pattern = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                Customer.name.ilike(pattern),
                Customer.phone.ilike(pattern),
            )
        )
    return stmt


@router.get(
    "/search",
    response_model=CustomerListResponse,
    summary="Search customers (POS picker)",
    tags=["customers"],
)
def search_customers(
    q: str | None = Query(None, max_length=200),
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    include_archived: bool = Query(False),
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    db: Session = Depends(get_db),
) -> CustomerListResponse:
    """Minimal name/phone search used by the POS customer picker.

    Phase 9 will add full customer management UI and mutations.
    """
    stmt = _search_stmt(q, include_archived)
    total = db.scalar(
        select(func.count()).select_from(stmt.subquery())
    ) or 0
    pages = max(1, math.ceil(total / page_size)) if page_size else 1
    rows = (
        db.execute(
            stmt.order_by(Customer.name).offset((page - 1) * page_size).limit(page_size)
        )
        .scalars()
        .all()
    )
    return CustomerListResponse(
        items=[_to_response(c) for c in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )


@router.get(
    "",
    response_model=CustomerListResponse,
    summary="List customers",
    tags=["customers"],
)
def list_customers(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    include_archived: bool = Query(False),
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    db: Session = Depends(get_db),
) -> CustomerListResponse:
    stmt = _search_stmt(None, include_archived)
    total = db.scalar(
        select(func.count()).select_from(stmt.subquery())
    ) or 0
    pages = max(1, math.ceil(total / page_size)) if page_size else 1
    rows = (
        db.execute(
            stmt.order_by(Customer.name).offset((page - 1) * page_size).limit(page_size)
        )
        .scalars()
        .all()
    )
    return CustomerListResponse(
        items=[_to_response(c) for c in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )
