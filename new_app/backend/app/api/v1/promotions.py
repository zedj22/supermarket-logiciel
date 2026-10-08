"""Promotions API endpoints (Phase 18).

- POST /api/v1/promotions             — create ONE promotion over MANY
  products in a single transactional request (bulk apply, idempotent)
- GET  /api/v1/promotions             — filtered, paginated list
- GET  /api/v1/promotions/{id}        — one promotion
- PUT  /api/v1/promotions/{id}        — partial update (membership replace)
- POST /api/v1/promotions/{id}/toggle — active ⇄ inactive

Permissions: promotion_view / promotion_create / promotion_update (admin +
manager seeded; the POS never calls these endpoints — promotion prices
ride on the product responses under product_view).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.common import PaginatedResponse
from app.schemas.promotion import (
    PromotionCreateRequest,
    PromotionResponse,
    PromotionUpdateRequest,
)
from app.services.promotions import PromotionService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> PromotionService:
    return PromotionService(db)


@router.post(
    "",
    response_model=PromotionResponse,
    status_code=201,
    summary="Create a promotion (bulk apply)",
    tags=["promotions"],
)
def create_promotion(
    request: PromotionCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PROMOTION_CREATE)),
    service: PromotionService = Depends(_get_service),
) -> PromotionResponse:
    """Create one promotion over many products — ALL OR NOTHING.

    ``client_request_id`` is required (idempotent replay / 409 on a
    different payload). The membership rows are written in the same
    transaction as the promotion: a validation or overlap failure rolls
    the whole request back — no partial state, no per-product loops.
    """
    return service.create(request, user=user)


@router.get(
    "",
    response_model=PaginatedResponse[PromotionResponse],
    summary="List promotions",
    tags=["promotions"],
)
def list_promotions(
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=100),
    q: str | None = Query(None, max_length=200),
    is_active: bool | None = Query(
        None, description="Filter by active flag (omit for all)"
    ),
    user: User = Depends(require_permission(PermissionScope.PROMOTION_VIEW)),
    service: PromotionService = Depends(_get_service),
) -> PaginatedResponse[PromotionResponse]:
    """Paginated list, newest first."""
    return service.list(page=page, page_size=page_size, q=q, is_active=is_active)


@router.get(
    "/{promotion_id}",
    response_model=PromotionResponse,
    summary="Get a promotion",
    tags=["promotions"],
)
def get_promotion(
    promotion_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PROMOTION_VIEW)),
    service: PromotionService = Depends(_get_service),
) -> PromotionResponse:
    return service.get(promotion_id)


@router.put(
    "/{promotion_id}",
    response_model=PromotionResponse,
    summary="Update a promotion",
    tags=["promotions"],
)
def update_promotion(
    promotion_id: uuid.UUID,
    request: PromotionUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PROMOTION_UPDATE)),
    service: PromotionService = Depends(_get_service),
) -> PromotionResponse:
    """Partial update — unset fields are preserved; ``product_ids``
    replaces the membership set in one transaction."""
    return service.update(promotion_id, request, user=user)


@router.post(
    "/{promotion_id}/toggle",
    response_model=PromotionResponse,
    summary="Toggle promotion active flag",
    tags=["promotions"],
)
def toggle_promotion(
    promotion_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PROMOTION_UPDATE)),
    service: PromotionService = Depends(_get_service),
) -> PromotionResponse:
    """active ⇄ inactive. Activating re-checks the one-active-promotion-
    per-product rule under row locks; deactivating restores retail on the
    next price resolution without touching ``products.price``."""
    return service.toggle(promotion_id, user=user)
