"""Inventory API endpoints (Phase 7).

Endpoints (static routes MUST precede /{product_id}):
- GET  /api/v1/inventory                     — List products with stock + valuation
- GET  /api/v1/inventory/movements           — Global movement journal
- GET  /api/v1/inventory/movements/{product_id} — Movements for one product
- POST /api/v1/inventory/adjust              — Stock adjustment (increase/decrease/set)
- GET  /api/v1/inventory/{product_id}        — Product stock detail + packaging + variants

Permissions: inventory_view (reads), inventory_adjust (mutations).
"""

from __future__ import annotations

import math
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.inventory import (
    InventoryAdjustRequest,
    InventoryListResponse,
    InventoryMovementListResponse,
    InventoryProductDetailResponse,
)
from app.services.inventory import InventoryService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> InventoryService:
    return InventoryService(db)


def _pages(total: int, page_size: int) -> int:
    return math.ceil(total / page_size) if total > 0 and page_size > 0 else 1


# ---------------------------------------------------------------------------
# Static routes BEFORE /{product_id}
# ---------------------------------------------------------------------------


@router.get(
    "",
    response_model=InventoryListResponse,
    summary="List inventory (stock + valuation)",
    tags=["inventory"],
)
def list_inventory(
    page: int = Query(1, ge=1, description="Page number (1-indexed)"),
    page_size: int = Query(
        DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE, description="Items per page"
    ),
    search: str | None = Query(
        None, max_length=200, description="Name or barcode substring"
    ),
    status: str = Query(
        "active",
        pattern="^(active|archived|all)$",
        description="Archive filter",
    ),
    low_stock: bool = Query(
        False, description="Only products at/below low-stock threshold"
    ),
    sort_by: str = Query(
        "name",
        pattern="^(name|quantity|avg_cost|price|updated_at)$",
        description="Sort field",
    ),
    sort_order: str = Query("asc", pattern="^(asc|desc)$", description="Sort direction"),
    user: User = Depends(require_permission(PermissionScope.INVENTORY_VIEW)),
    service: InventoryService = Depends(_get_service),
) -> InventoryListResponse:
    """Paginated inventory list with stock value (quantity × avg_cost)."""
    return service.list_inventory(
        page=page,
        page_size=page_size,
        search=search,
        status=status,
        low_stock_only=low_stock,
        sort_by=sort_by,
        sort_order=sort_order,
    )


@router.get(
    "/movements",
    response_model=InventoryMovementListResponse,
    summary="List stock movements (global journal)",
    tags=["inventory"],
)
def list_movements(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    product_id: uuid.UUID | None = Query(None, description="Filter by product"),
    variant_id: uuid.UUID | None = Query(None, description="Filter by variant"),
    movement_type: str | None = Query(
        None,
        max_length=30,
        description="Filter by movement type (sale, adjustment, package_receive, …)",
    ),
    search: str | None = Query(None, max_length=200, description="Reason/unit substring"),
    sort_by: str = Query(
        "movement_date",
        pattern="^(movement_date|created_at|quantity_change|movement_type)$",
    ),
    sort_order: str = Query("desc", pattern="^(asc|desc)$"),
    user: User = Depends(require_permission(PermissionScope.INVENTORY_VIEW)),
    service: InventoryService = Depends(_get_service),
) -> InventoryMovementListResponse:
    """Paginated stock movement journal (immutable)."""
    return service.list_movements(
        page=page,
        page_size=page_size,
        product_id=product_id,
        variant_id=variant_id,
        movement_type=movement_type,
        search=search,
        sort_by=sort_by,
        sort_order=sort_order,
    )


@router.get(
    "/movements/{product_id}",
    response_model=InventoryMovementListResponse,
    summary="List stock movements for one product",
    tags=["inventory"],
)
def list_product_movements(
    product_id: uuid.UUID,
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    movement_type: str | None = Query(None, max_length=30),
    user: User = Depends(require_permission(PermissionScope.INVENTORY_VIEW)),
    service: InventoryService = Depends(_get_service),
) -> InventoryMovementListResponse:
    """Movement history for a single product."""
    return service.list_movements_for_product(
        product_id,
        page=page,
        page_size=page_size,
        movement_type=movement_type,
    )


@router.post(
    "/adjust",
    response_model=InventoryProductDetailResponse,
    summary="Adjust stock (increase / decrease / set)",
    tags=["inventory"],
)
def adjust_stock(
    request: InventoryAdjustRequest,
    user: User = Depends(require_permission(PermissionScope.INVENTORY_ADJUST)),
    service: InventoryService = Depends(_get_service),
) -> InventoryProductDetailResponse:
    """Authoritative stock mutation. Updates product.avg_cost (PMP) on receipts
    with unit_cost. Always writes an ADJUSTMENT movement (immutable journal).
    """
    return service.adjust(request, user=user)


# ---------------------------------------------------------------------------
# Dynamic route AFTER static routes
# ---------------------------------------------------------------------------


@router.get(
    "/{product_id}",
    response_model=InventoryProductDetailResponse,
    summary="Product stock detail",
    tags=["inventory"],
)
def get_product_stock(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.INVENTORY_VIEW)),
    service: InventoryService = Depends(_get_service),
) -> InventoryProductDetailResponse:
    """Stock + PMP + valuation + packaging state + variants + recent movements."""
    return service.get_product_detail(product_id)
