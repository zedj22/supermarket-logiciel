"""POS / sales API endpoints (Phase 8).

Core:
- POST   /api/v1/sales                         — Create sale (atomic checkout)
- GET    /api/v1/sales                         — Minimal sale history (pos_sale)
- GET    /api/v1/sales/{sale_id}               — Sale detail / reprint
- GET    /api/v1/sales/by-invoice/{invoice}    — Reprint by invoice number

POS helpers:
- POST   /api/v1/pos/cart/validate             — Stateless cart revalidation
- POST   /api/v1/pos/holds                     — Save hold snapshot
- GET    /api/v1/pos/holds                     — List holds
- GET    /api/v1/pos/holds/{hold_id}           — Hold detail
- DELETE /api/v1/pos/holds/{hold_id}           — Delete hold
- POST   /api/v1/pos/holds/{hold_id}/restore   — Restore + revalidate (no stock reserve)
- GET    /api/v1/pos/favorites                 — List manual favorites
- POST   /api/v1/pos/favorites/{product_id}    — Pin favorite
- DELETE /api/v1/pos/favorites/{product_id}    — Unpin favorite

Permissions: pos_sale (checkout + history), pos_credit_sale (debt),
pos_discount (discounts), product_view (favorites).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Header, Query, Response
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.sale import (
    CartValidateRequest,
    CartValidateResponse,
    CreateSaleRequest,
    FavoriteListResponse,
    FavoriteToggleResponse,
    HoldCreateRequest,
    HoldListResponse,
    HoldRestoreResponse,
    HoldResponse,
    SaleCreateResponse,
    SaleListResponse,
    SaleResponse,
)
from app.services.sale import SaleService

sales_router = APIRouter()
pos_router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> SaleService:
    return SaleService(db)


# ---------------------------------------------------------------------------
# Sales (core checkout + minimal history)
# ---------------------------------------------------------------------------


@sales_router.post(
    "",
    response_model=SaleCreateResponse,
    status_code=201,
    summary="Create sale (atomic POS checkout)",
    tags=["sales"],
)
def create_sale(
    request: CreateSaleRequest,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> SaleCreateResponse:
    """Atomic checkout: sale + lines + stock + movements + payments + debt.

    Idempotency: `client_request_id` is required; a repeat returns the
    original sale with `idempotent_replay=true` and never a second sale.
    """
    require_credit = request.payment_method in ("partial", "credit")
    return service.create_sale(
        request,
        user=user,
        device_id=x_device_id,
        require_pos_discount=True,  # enforced only when a discount > 0
        require_pos_credit=require_credit,
    )


@sales_router.get(
    "",
    response_model=SaleListResponse,
    summary="List sales (minimal POS history)",
    tags=["sales"],
)
def list_sales(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> SaleListResponse:
    """Minimal history for POS reprint. Full reporting is a later phase."""
    result = service.list_sales(page=page, page_size=page_size)
    return SaleListResponse(**result)


@sales_router.get(
    "/by-invoice/{invoice_number}",
    response_model=SaleResponse,
    summary="Get sale by invoice number",
    tags=["sales"],
)
def get_sale_by_invoice(
    invoice_number: str,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> SaleResponse:
    return service.get_sale_by_invoice(invoice_number)


@sales_router.get(
    "/{sale_id}",
    response_model=SaleResponse,
    summary="Get sale by id",
    tags=["sales"],
)
def get_sale(
    sale_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> SaleResponse:
    return service.get_sale(sale_id)


# ---------------------------------------------------------------------------
# POS cart / holds / favorites
# ---------------------------------------------------------------------------


@pos_router.post(
    "/cart/validate",
    response_model=CartValidateResponse,
    summary="Validate cart lines (stateless)",
    tags=["pos"],
)
def validate_cart(
    request: CartValidateRequest,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> CartValidateResponse:
    """Re-check stock/prices for cart lines without mutating anything."""
    return service.validate_cart(request)


@pos_router.post(
    "/holds",
    response_model=HoldResponse,
    status_code=201,
    summary="Create hold (cart snapshot)",
    tags=["pos"],
)
def create_hold(
    request: HoldCreateRequest,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> HoldResponse:
    """Snapshot only — holds do NOT reserve stock."""
    return service.create_hold(request, user=user)


@pos_router.get(
    "/holds",
    response_model=HoldListResponse,
    summary="List holds",
    tags=["pos"],
)
def list_holds(
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> HoldListResponse:
    return service.list_holds(user=user, device_id=device_id)


@pos_router.get(
    "/holds/{hold_id}",
    response_model=HoldResponse,
    summary="Get hold",
    tags=["pos"],
)
def get_hold(
    hold_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> HoldResponse:
    return service.get_hold(hold_id)


@pos_router.post(
    "/holds/{hold_id}/restore",
    response_model=HoldRestoreResponse,
    summary="Restore hold + revalidate stock",
    tags=["pos"],
)
def restore_hold(
    hold_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> HoldRestoreResponse:
    """Returns snapshot and revalidates current stock/prices. No reservation."""
    return service.restore_hold(hold_id)


@pos_router.delete(
    "/holds/{hold_id}",
    response_class=Response,
    status_code=204,
    summary="Delete hold",
    tags=["pos"],
)
def delete_hold(
    hold_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> Response:
    service.delete_hold(hold_id)
    return Response(status_code=204)


@pos_router.get(
    "/favorites",
    response_model=FavoriteListResponse,
    summary="List POS favorites",
    tags=["pos"],
)
def list_favorites(
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> FavoriteListResponse:
    return service.list_favorites(user=user)


@pos_router.post(
    "/favorites/{product_id}",
    response_model=FavoriteToggleResponse,
    summary="Add product to favorites",
    tags=["pos"],
)
def add_favorite(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> FavoriteToggleResponse:
    return service.add_favorite(product_id, user=user)


@pos_router.delete(
    "/favorites/{product_id}",
    response_model=FavoriteToggleResponse,
    summary="Remove product from favorites",
    tags=["pos"],
)
def remove_favorite(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.POS_SALE)),
    service: SaleService = Depends(_get_service),
) -> FavoriteToggleResponse:
    return service.remove_favorite(product_id, user=user)
