"""Loyalty API (Phase E).

Endpoints:
- GET    /api/v1/loyalty/settings      — read the loyalty rules
- PUT    /api/v1/loyalty/settings      — partial update of the rules
- POST   /api/v1/loyalty/preview       — authoritative checkout preview
- GET    /api/v1/loyalty/lookup        — find a customer by phone or QR

The customer-scoped endpoints live with the rest of the customer
sub-resources in ``app/api/v1/customers.py``:

- GET    /api/v1/customers/{id}/loyalty            — balances
- GET    /api/v1/customers/{id}/loyalty/history     — ledger, paginated
- POST   /api/v1/customers/{id}/loyalty/adjustment  — admin correction

RBAC (no new permission scopes are invented):
- reads (settings/preview/lookup/balance/history) follow their data:
  settings read = any **authenticated** user (the POS needs the rates on
  every role — same rule as ``GET /api/v1/settings``); everything else
  customer-scoped requires **CUSTOMER_VIEW**;
- settings write requires **SETTINGS_MANAGE** (admin only, exactly like
  the store settings PUT);
- the administrative balance adjustment also requires
  **SETTINGS_MANAGE**: it moves loyalty balances, and CUSTOMER_MANAGE is
  held by cashiers for debt payments — a cashier must never be able to
  mint points.

Every number in every response is computed server-side; requests carry
only cart inputs (customer, gross total, selected reward percent) and
the mandatory reason/key for adjustments — never a claimed balance or a
claimed discount.

Customer identification: QR payloads are the opaque ``KLICK:C:<uuid>``
form (no personal data inside the code); phone lookup compares digits
only without rewriting Algerian formats.  Both are resolved against the
database and the caller still needs CUSTOMER_VIEW.
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user, require_permission
from app.core.exceptions import NotFoundError, ValidationError
from app.db.session import get_db
from app.domain.loyalty import available_rewards, remaining_points
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.enums import PermissionScope
from app.models.party import Customer
from app.models.user import User
from app.schemas.loyalty import (
    LoyaltyPreviewRequest,
    LoyaltyPreviewResponse,
    LoyaltySettingsResponse,
    LoyaltySettingsUpdateRequest,
)
from app.schemas.party import CustomerListResponse, CustomerResponse
from app.services.customers import CustomerService
from app.services.loyalty import (
    LoyaltyEngine,
    LoyaltySettingsService,
    RewardDecision,
)

router = APIRouter()

#: QR payloads look like ``KLICK:C:<customer uuid>`` — an opaque handle
#: with NO personal information embedded (name/phone never travel in the
#: code; the server resolves it and still enforces CUSTOMER_VIEW).
QR_PREFIX = "KLICK:C:"

#: Phone lookups return at most this many rows for disambiguation.
LOOKUP_LIMIT = 20


def _get_settings_service(db: Session = Depends(get_db)) -> LoyaltySettingsService:
    return LoyaltySettingsService(db)


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_settings_response(row) -> LoyaltySettingsResponse:
    return LoyaltySettingsResponse(
        points_enabled=row.points_enabled,
        points_rate=to_decimal(row.points_rate),
        cashback_enabled=row.cashback_enabled,
        cashback_rate=to_decimal(row.cashback_rate),
        max_reward_discount_percent=to_decimal(
            row.max_reward_discount_percent
        ),
        earn_on_debt_settlement=row.earn_on_debt_settlement,
    )


def _to_customer_response(customer: Customer) -> CustomerResponse:
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


def _lookup_response(rows: list[Customer], total: int) -> CustomerListResponse:
    return CustomerListResponse(
        items=[_to_customer_response(c) for c in rows],
        total=total,
        page=1,
        page_size=LOOKUP_LIMIT,
        pages=max(1, math.ceil(total / LOOKUP_LIMIT)),
    )


# ── Settings (read = any authenticated, write = SETTINGS_MANAGE) ────────


@router.get(
    "/settings",
    response_model=LoyaltySettingsResponse,
    summary="Get loyalty settings",
    tags=["loyalty"],
)
def get_loyalty_settings(
    user: User = Depends(get_current_user),
    service: LoyaltySettingsService = Depends(_get_settings_service),
) -> LoyaltySettingsResponse:
    """Read the current loyalty rules. Read never writes a row."""
    return _to_settings_response(service.get())


@router.put(
    "/settings",
    response_model=LoyaltySettingsResponse,
    summary="Update loyalty settings",
    tags=["loyalty"],
)
def update_loyalty_settings(
    request: LoyaltySettingsUpdateRequest,
    user: User = Depends(
        require_permission(PermissionScope.SETTINGS_MANAGE)
    ),
    service: LoyaltySettingsService = Depends(_get_settings_service),
) -> LoyaltySettingsResponse:
    """Partial update — only the fields present in the body change.

    Persisted and audit-logged in one transaction inside the service.
    """
    row = service.update(request, actor_id=user.id)
    return _to_settings_response(row)


# ── Preview (CUSTOMER_VIEW) ─────────────────────────────────────────────


@router.post(
    "/preview",
    response_model=LoyaltyPreviewResponse,
    summary="Preview loyalty rewards for a cart",
    tags=["loyalty"],
)
def preview_loyalty(
    request: LoyaltyPreviewRequest,
    user: User = Depends(
        require_permission(PermissionScope.CUSTOMER_VIEW)
    ),
    db: Session = Depends(get_db),
) -> LoyaltyPreviewResponse:
    """Server-computed preview for the current cart and customer.

    Answers with the reward the server would actually accept (or 422
    with the structured reason when the selected percent is not
    allowed — disabled feature, no available reward, percent above the
    owner's cap), the resulting amount due, the reward milestone view
    of the balance, the owner's cap for the percent selector, and the
    rewards earned if the sale settles at that amount.  The client
    never does authoritative math — it renders these numbers.

    When points are disabled the reported cap collapses to 0 so a
    client builds an empty selector without a second settings read.

    Read-only: never creates the settings row or the loyalty account.
    """
    customer = CustomerService(db).get(request.customer_id)  # 404 if gone
    engine = LoyaltyEngine(db)
    settings = engine.settings_snapshot()

    account = engine.account_balance(customer.id)
    points_balance = (
        to_decimal(account.points_balance) if account is not None
        else Decimal(0)
    )
    cashback_balance = (
        to_decimal(account.cashback_balance) if account is not None
        else Decimal(0)
    )

    gross_total = quantize_money(request.gross_total)
    if request.reward_percent > 0:
        decision = engine.preview_reward(
            customer_id=customer.id,
            reward_percent=request.reward_percent,
            gross_total=gross_total,
        )
    else:
        decision = RewardDecision(Decimal(0), Decimal(0), quantize_money(0))

    amount_due = quantize_money(gross_total - decision.discount)
    if amount_due < 0:  # pragma: no cover - caps prevent this
        amount_due = quantize_money(0)

    max_percent = (
        to_decimal(settings["max_reward_discount_percent"])
        if settings["points_enabled"]
        else Decimal(0)
    )

    earned = engine.calculate_earn(
        qualifying_amount=amount_due, settings=settings
    )

    return LoyaltyPreviewResponse(
        customer_id=customer.id,
        gross_total=gross_total,
        reward_percent=decision.percent,
        reward_discount=decision.discount,
        amount_due=amount_due,
        available_rewards=int(available_rewards(points_balance)),
        remaining_points=remaining_points(points_balance),
        max_reward_discount_percent=max_percent,
        points_balance=points_balance,
        cashback_balance=cashback_balance,
        points_earned=earned.points,
        cashback_earned=earned.cashback,
    )


# ── Customer lookup by phone or QR (CUSTOMER_VIEW) ─────────────────────


@router.get(
    "/lookup",
    response_model=CustomerListResponse,
    summary="Find a customer by phone number or loyalty QR code",
    tags=["loyalty"],
)
def lookup_customer(
    q: str = Query(..., min_length=1, max_length=200),
    user: User = Depends(
        require_permission(PermissionScope.CUSTOMER_VIEW)
    ),
    db: Session = Depends(get_db),
) -> CustomerListResponse:
    """Resolve a scanned/typed customer handle to a candidate list.

    * ``KLICK:C:<uuid>`` (case-insensitive prefix) — the opaque QR
      payload; resolves to exactly that customer or 404.  The code
      carries no personal data; the server still enforces
      CUSTOMER_VIEW before revealing who it is.
    * anything else with at least one digit — a phone number matched by
      digits only (formatting is ignored, number formats are NEVER
      rewritten).  Duplicate phone numbers come back as the full
      disambiguation list (up to 20, with the true total).
    """
    raw = q.strip()
    if not raw:
        raise ValidationError(
            message="lookup value is required",
            details={"q": q},
        )

    if raw[: len(QR_PREFIX)].upper() == QR_PREFIX:
        payload = raw[len(QR_PREFIX):].strip()
        try:
            customer_id = uuid.UUID(payload)
        except ValueError:
            raise ValidationError(
                message="invalid loyalty QR payload",
                code="LOYALTY_QR_INVALID",
                details={"q": raw},
            )
        customer = db.get(Customer, customer_id)
        if customer is None or customer.archived_at is not None:
            raise NotFoundError(
                message="customer not found for this QR code",
                code="LOYALTY_QR_NOT_FOUND",
                details={"customer_id": str(customer_id)},
            )
        return _lookup_response([customer], 1)

    digits = "".join(ch for ch in raw if ch.isdigit())
    if not digits:
        raise ValidationError(
            message="lookup requires a phone number or a KLICK:C: QR payload",
            code="LOYALTY_LOOKUP_INVALID",
            details={"q": raw},
        )
    rows, total = CustomerService(db).lookup_by_phone(
        digits, limit=LOOKUP_LIMIT
    )
    return _lookup_response(rows, total)
