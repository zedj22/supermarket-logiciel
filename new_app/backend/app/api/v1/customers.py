"""Customers API (Phase 8 search + Phase 9 management + Phase E loyalty).

Endpoints:
- GET    /api/v1/customers/search        — name/phone search (POS picker)
- GET    /api/v1/customers               — list (paginated)
- POST   /api/v1/customers               — create customer
- GET    /api/v1/customers/{id}          — customer detail
- PUT    /api/v1/customers/{id}          — partial update
- DELETE /api/v1/customers/{id}          — archive (soft delete)
- GET    /api/v1/customers/{id}/debts    — paginated debt history
- POST   /api/v1/customers/{id}/pay      — record debt payment (atomic)
- GET    /api/v1/customers/{id}/loyalty  — loyalty balances (read-only)
- GET    /api/v1/customers/{id}/loyalty/history — ledger, paginated
- POST   /api/v1/customers/{id}/loyalty/adjustment — admin correction

RBAC: reading/listing/history requires CUSTOMER_VIEW; mutations and
payment recording require CUSTOMER_MANAGE (no new permission scopes are
invented — both scopes already exist and are seeded in Phase 2).  The
loyalty READS reuse CUSTOMER_VIEW (they expose money the POS already
needs for the same role); the balance ADJUSTMENT requires
SETTINGS_MANAGE — it moves financial balances and CUSTOMER_MANAGE is
held by cashiers for debt payments, so minting/burning points stays an
admin-only operation (recorded as a Phase E decision).

The POS customer search contract from Phase 8 is unchanged.
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
from app.domain.loyalty import available_rewards, remaining_points
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.debt import DebtLedgerEntry
from app.models.enums import PermissionScope
from app.models.party import Customer
from app.models.user import User
from app.schemas.loyalty import (
    LoyaltyAdjustmentRequest,
    LoyaltyAdjustmentResponse,
    LoyaltyBalanceResponse,
    LoyaltyHistoryResponse,
    LoyaltyLedgerEntryResponse,
)
from app.schemas.party import (
    CustomerCreateRequest,
    CustomerListResponse,
    CustomerResponse,
    CustomerUpdateRequest,
    DebtEntryResponse,
    DebtHistoryResponse,
    DebtPaymentRequest,
    DebtPaymentResponse,
)
from app.services.customers import CustomerService
from app.services.debt import DebtService
from app.services.loyalty import LoyaltyEngine

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


# ── Dependencies ────────────────────────────────────────────────────────


def _get_customer_service(db: Session = Depends(get_db)) -> CustomerService:
    return CustomerService(db)


def _get_debt_service(db: Session = Depends(get_db)) -> DebtService:
    return DebtService(db)


def _get_loyalty_engine(db: Session = Depends(get_db)) -> LoyaltyEngine:
    return LoyaltyEngine(db)


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_response(customer: Customer) -> CustomerResponse:
    return CustomerResponse(
        id=customer.id,
        name=customer.name,
        phone=customer.phone,
        address=customer.address,
        balance=quantize_money(to_decimal(customer.balance)),
        debt_ceiling=quantize_money(to_decimal(customer.debt_ceiling)),
        is_archived=customer.archived_at is not None,
        created_at=customer.created_at,
        updated_at=customer.updated_at,
    )


def _to_debt_response(
    entry: DebtLedgerEntry, *, balance_after: Decimal | None = None
) -> DebtEntryResponse:
    return DebtEntryResponse(
        id=entry.id,
        customer_id=entry.customer_id,
        entry_type=entry.entry_type,
        amount=quantize_money(to_decimal(entry.amount)),
        note=entry.note,
        reference_sale_id=entry.reference_sale_id,
        invoice_number=(
            entry.reference_sale.invoice_number
            if entry.reference_sale is not None
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


def _to_loyalty_entry_response(entry) -> LoyaltyLedgerEntryResponse:
    """Ledger row → API response (balances come from the row itself).

    ``source_event_key`` and ``created_by`` stay server-side; the POS
    shows customers what moved and when, not internal posting keys.
    """
    return LoyaltyLedgerEntryResponse(
        id=entry.id,
        event_type=entry.event_type,
        points_delta=to_decimal(entry.points_delta),
        cashback_delta=to_decimal(entry.cashback_delta),
        balance_after_points=to_decimal(entry.balance_after_points),
        balance_after_cashback=to_decimal(entry.balance_after_cashback),
        note=entry.note,
        sale_id=entry.sale_id,
        invoice_number=(
            entry.sale.invoice_number if entry.sale is not None else None
        ),
        return_id=entry.return_id,
        created_at=entry.created_at,
    )


# ── Reads (POS picker contract unchanged) ───────────────────────────────


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
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerListResponse:
    """Name/phone search used by the POS customer picker."""
    rows, total = service.list(
        page=page,
        page_size=page_size,
        q=q,
        include_archived=include_archived,
    )
    return CustomerListResponse(
        items=[_to_response(c) for c in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
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
    has_debt: bool = Query(False),
    q: str | None = Query(None, max_length=200),
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerListResponse:
    rows, total = service.list(
        page=page,
        page_size=page_size,
        q=q,
        include_archived=include_archived,
        has_debt=has_debt,
    )
    return CustomerListResponse(
        items=[_to_response(c) for c in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


# ── Management (Phase 9) ────────────────────────────────────────────────


@router.post(
    "",
    response_model=CustomerResponse,
    status_code=201,
    summary="Create customer",
    tags=["customers"],
)
def create_customer(
    request: CustomerCreateRequest,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_MANAGE)),
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerResponse:
    """Create a customer. Balance always starts at 0 (server-side)."""
    customer = service.create(request, actor_id=user.id)
    return _to_response(customer)


@router.get(
    "/{customer_id}",
    response_model=CustomerResponse,
    summary="Get customer",
    tags=["customers"],
)
def get_customer(
    customer_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerResponse:
    """Customer detail (balance is the cached ledger projection)."""
    return _to_response(service.get(customer_id))


@router.put(
    "/{customer_id}",
    response_model=CustomerResponse,
    summary="Update customer",
    tags=["customers"],
)
def update_customer(
    customer_id: uuid.UUID,
    request: CustomerUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_MANAGE)),
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerResponse:
    """Partial update — only fields present in the body change.

    ``balance`` is never writable here; it only moves with ledger
    entries (credit sale or debt payment).
    """
    customer = service.update(customer_id, request, actor_id=user.id)
    return _to_response(customer)


@router.delete(
    "/{customer_id}",
    response_model=CustomerResponse,
    summary="Archive customer",
    tags=["customers"],
)
def archive_customer(
    customer_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_MANAGE)),
    service: CustomerService = Depends(_get_customer_service),
) -> CustomerResponse:
    """Soft-archive a customer. 409 when an outstanding balance remains."""
    customer = service.archive(customer_id, actor_id=user.id)
    return _to_response(customer)


# ── Debts (Phase 9) ─────────────────────────────────────────────────────


@router.get(
    "/{customer_id}/debts",
    response_model=DebtHistoryResponse,
    summary="Customer debt history",
    tags=["customers"],
)
def customer_debt_history(
    customer_id: uuid.UUID,
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: DebtService = Depends(_get_debt_service),
) -> DebtHistoryResponse:
    """Append-only debt ledger for one customer, newest first."""
    rows, total = service.history(
        customer_id, page=page, page_size=page_size
    )
    balances = service.balance_after_map(customer_id)
    return DebtHistoryResponse(
        items=[
            _to_debt_response(e, balance_after=balances.get(e.id))
            for e in rows
        ],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


@router.post(
    "/{customer_id}/pay",
    response_model=DebtPaymentResponse,
    summary="Record debt payment",
    tags=["customers"],
)
def pay_customer_debt(
    customer_id: uuid.UUID,
    request: DebtPaymentRequest,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_MANAGE)),
    service: DebtService = Depends(_get_debt_service),
) -> DebtPaymentResponse:
    """Record a debt payment atomically (ledger entry + balance).

    Never accepts a payment above the outstanding balance (no negative
    balance / advance semantics — legacy-verified rule).
    """
    return service.pay(customer_id, request, actor_id=user.id)


# ── Loyalty (Phase E) ───────────────────────────────────────────────────


@router.get(
    "/{customer_id}/loyalty",
    response_model=LoyaltyBalanceResponse,
    summary="Customer loyalty balances",
    tags=["loyalty"],
)
def customer_loyalty_balance(
    customer_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: CustomerService = Depends(_get_customer_service),
    engine: LoyaltyEngine = Depends(_get_loyalty_engine),
) -> LoyaltyBalanceResponse:
    """Server-computed loyalty balances for one customer.

    Read-only: never creates the loyalty account row — a customer with
    no loyalty activity yet reports ``has_account=false`` and zeros.
    The reward view (``available_rewards`` / ``remaining_points``) is
    derived here — against the configured ``min_reward_points``
    milestone — so clients never reimplement the rule.
    """
    service.get(customer_id)  # 404 when the customer does not exist
    account = engine.account_balance(customer_id)
    points_balance = (
        to_decimal(account.points_balance)
        if account is not None
        else Decimal(0)
    )
    min_points = to_decimal(engine.settings_snapshot()["min_reward_points"])
    return LoyaltyBalanceResponse(
        customer_id=customer_id,
        has_account=account is not None,
        points_balance=points_balance,
        cashback_balance=(
            to_decimal(account.cashback_balance)
            if account is not None
            else Decimal(0)
        ),
        available_rewards=int(available_rewards(points_balance, min_points)),
        remaining_points=remaining_points(points_balance, min_points),
        min_reward_points=min_points,
    )


@router.get(
    "/{customer_id}/loyalty/history",
    response_model=LoyaltyHistoryResponse,
    summary="Customer loyalty history",
    tags=["loyalty"],
)
def customer_loyalty_history(
    customer_id: uuid.UUID,
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: CustomerService = Depends(_get_customer_service),
    engine: LoyaltyEngine = Depends(_get_loyalty_engine),
) -> LoyaltyHistoryResponse:
    """Append-only loyalty ledger for one customer, newest first."""
    service.get(customer_id)  # 404 when the customer does not exist
    rows, total = engine.history(
        customer_id, page=page, page_size=page_size
    )
    return LoyaltyHistoryResponse(
        items=[_to_loyalty_entry_response(e) for e in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


@router.post(
    "/{customer_id}/loyalty/adjustment",
    response_model=LoyaltyAdjustmentResponse,
    summary="Administrative loyalty balance adjustment",
    tags=["loyalty"],
)
def adjust_customer_loyalty(
    customer_id: uuid.UUID,
    request: LoyaltyAdjustmentRequest,
    user: User = Depends(
        require_permission(PermissionScope.SETTINGS_MANAGE)
    ),
    service: CustomerService = Depends(_get_customer_service),
    engine: LoyaltyEngine = Depends(_get_loyalty_engine),
) -> LoyaltyAdjustmentResponse:
    """Post one auditable adjustment entry (points and/or cashback).

    Mandatory ``reason`` (audit trail) and ``client_request_id`` (a
    retry replays the original entry instead of moving the balance
    twice; the same key with a different payload is a 409).  The engine
    refuses any result that would drive a balance negative — 422, never
    a clamp.  Ledger + audit row commit in the same transaction.
    """
    service.get(customer_id)  # 404 when the customer does not exist
    posted = engine.adjust(
        customer_id,
        points_delta=request.points_delta,
        cashback_delta=request.cashback_delta,
        reason=request.reason,
        client_request_id=request.client_request_id,
        actor_id=user.id,
    )
    account = engine.account_balance(customer_id)
    return LoyaltyAdjustmentResponse(
        id=posted.entry.id,
        customer_id=customer_id,
        points_delta=to_decimal(posted.entry.points_delta),
        cashback_delta=to_decimal(posted.entry.cashback_delta),
        points_balance=to_decimal(account.points_balance),
        cashback_balance=to_decimal(account.cashback_balance),
        idempotent_replay=posted.replayed,
        created_at=posted.entry.created_at,
    )
