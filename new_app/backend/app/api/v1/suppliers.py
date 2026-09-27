"""Suppliers API (Phase 11).

Endpoints:
- GET    /api/v1/suppliers                 — list (paginated, q search)
- POST   /api/v1/suppliers                 — create supplier
- GET    /api/v1/suppliers/{id}            — supplier detail
- PUT    /api/v1/suppliers/{id}            — partial update
- DELETE /api/v1/suppliers/{id}            — soft archive (409 when balance != 0)
- GET    /api/v1/suppliers/{id}/ledger     — paginated payables history
- POST   /api/v1/suppliers/{id}/payments   — record supplier payment (atomic)

RBAC: reads/ledger require SUPPLIER_VIEW; mutations and payments
require SUPPLIER_MANAGE (decision record §19 — no new scopes invented).
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.enums import PermissionScope
from app.models.party import Supplier
from app.models.supplier_ledger import SupplierLedgerEntry
from app.models.user import User
from app.schemas.party import (
    SupplierCreateRequest,
    SupplierLedgerEntryResponse,
    SupplierLedgerResponse,
    SupplierListResponse,
    SupplierPaymentRequest,
    SupplierPaymentResponse,
    SupplierResponse,
    SupplierUpdateRequest,
)
from app.services.supplier_ledger import SupplierLedgerService
from app.services.suppliers import SupplierService

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


# ── Dependencies ────────────────────────────────────────────────────────


def _get_service(db: Session = Depends(get_db)) -> SupplierService:
    return SupplierService(db)


def _get_ledger_service(db: Session = Depends(get_db)) -> SupplierLedgerService:
    return SupplierLedgerService(db)


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_response(supplier: Supplier) -> SupplierResponse:
    return SupplierResponse(
        id=supplier.id,
        name=supplier.name,
        phone=supplier.phone,
        address=supplier.address,
        email=supplier.email,
        contact_person=supplier.contact_person,
        notes=supplier.notes,
        balance=quantize_money(to_decimal(supplier.balance)),
        is_archived=supplier.archived_at is not None,
        created_at=supplier.created_at,
        updated_at=supplier.updated_at,
    )


def _to_ledger_response(
    entry: SupplierLedgerEntry, *, balance_after: Decimal | None = None
) -> SupplierLedgerEntryResponse:
    return SupplierLedgerEntryResponse(
        id=entry.id,
        supplier_id=entry.supplier_id,
        entry_type=entry.entry_type,
        amount=quantize_money(to_decimal(entry.amount)),
        note=entry.note,
        reference_purchase_id=entry.reference_purchase_id,
        invoice_number=(
            entry.reference_purchase.invoice_number
            if entry.reference_purchase is not None
            else None
        ),
        user_id=entry.user_id,
        user_name=entry.user.full_name if entry.user is not None else None,
        entry_date=entry.entry_date,
        created_at=entry.created_at,
        balance_after=balance_after,
    )


def _page(total: int, page: int, page_size: int) -> int:
    return max(1, math.ceil(total / page_size)) if page_size else 1


# ── CRUD ────────────────────────────────────────────────────────────────


@router.get(
    "",
    response_model=SupplierListResponse,
    summary="List suppliers",
    tags=["suppliers"],
)
def list_suppliers(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    q: str | None = Query(None, max_length=200),
    include_archived: bool = Query(False),
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_VIEW)),
    service: SupplierService = Depends(_get_service),
) -> SupplierListResponse:
    """Paginated supplier list; ``q`` matches name/phone (purchase picker)."""
    rows, total = service.list(
        page=page,
        page_size=page_size,
        q=q,
        include_archived=include_archived,
    )
    return SupplierListResponse(
        items=[_to_response(s) for s in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


@router.post(
    "",
    response_model=SupplierResponse,
    status_code=201,
    summary="Create supplier",
    tags=["suppliers"],
)
def create_supplier(
    request: SupplierCreateRequest,
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_MANAGE)),
    service: SupplierService = Depends(_get_service),
) -> SupplierResponse:
    """Create a supplier. Balance always starts at 0 (server-side)."""
    return _to_response(service.create(request, actor_id=user.id))


@router.get(
    "/{supplier_id}",
    response_model=SupplierResponse,
    summary="Get supplier",
    tags=["suppliers"],
)
def get_supplier(
    supplier_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_VIEW)),
    service: SupplierService = Depends(_get_service),
) -> SupplierResponse:
    """Supplier detail (balance is the cached ledger projection)."""
    return _to_response(service.get(supplier_id))


@router.put(
    "/{supplier_id}",
    response_model=SupplierResponse,
    summary="Update supplier",
    tags=["suppliers"],
)
def update_supplier(
    supplier_id: uuid.UUID,
    request: SupplierUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_MANAGE)),
    service: SupplierService = Depends(_get_service),
) -> SupplierResponse:
    """Partial update — only fields present in the body change.

    ``balance`` is never writable here; it only moves with ledger
    entries (purchase receipt, cancellation, or payment).
    """
    return _to_response(
        service.update(supplier_id, request, actor_id=user.id)
    )


@router.delete(
    "/{supplier_id}",
    response_model=SupplierResponse,
    summary="Archive supplier",
    tags=["suppliers"],
)
def archive_supplier(
    supplier_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_MANAGE)),
    service: SupplierService = Depends(_get_service),
) -> SupplierResponse:
    """Soft-archive a supplier. 409 when an outstanding balance remains."""
    return _to_response(service.archive(supplier_id, actor_id=user.id))


# ── Payables ledger + payments (Phase 11) ───────────────────────────────


@router.get(
    "/{supplier_id}/ledger",
    response_model=SupplierLedgerResponse,
    summary="Supplier payables history",
    tags=["suppliers"],
)
def supplier_ledger(
    supplier_id: uuid.UUID,
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_VIEW)),
    service: SupplierLedgerService = Depends(_get_ledger_service),
) -> SupplierLedgerResponse:
    """Append-only payables ledger for one supplier, newest first.

    ``balance_after`` is the running balance computed from the ledger
    (never stored).
    """
    rows, total = service.history(supplier_id, page=page, page_size=page_size)
    balances = service.balance_after_map(supplier_id)
    return SupplierLedgerResponse(
        items=[
            _to_ledger_response(
                e, balance_after=balances.get(e.id)
            )
            for e in rows
        ],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


@router.post(
    "/{supplier_id}/payments",
    response_model=SupplierPaymentResponse,
    summary="Record supplier payment",
    tags=["suppliers"],
)
def pay_supplier(
    supplier_id: uuid.UUID,
    request: SupplierPaymentRequest,
    user: User = Depends(require_permission(PermissionScope.SUPPLIER_MANAGE)),
    service: SupplierLedgerService = Depends(_get_ledger_service),
) -> SupplierPaymentResponse:
    """Record a supplier payment atomically (ledger entry + balance).

    Never accepts a payment above the outstanding balance (no negative
    balance / advance semantics — legacy-verified rule).
    """
    return service.pay(supplier_id, request, actor_id=user.id)
