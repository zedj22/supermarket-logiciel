"""Packs / bundles API endpoints (Phase 10).

Endpoints:
- GET    /api/v1/packs                      — List packs (paginated, search, filter)
- POST   /api/v1/packs                      — Create pack
- GET    /api/v1/packs/{id}                 — Get pack detail with components
- PUT    /api/v1/packs/{id}                 — Update pack (partial)
- DELETE /api/v1/packs/{id}                 — Archive pack (soft-delete)
- GET    /api/v1/packs/{id}/availability    — Read-only component stock check

Authorization reuses the Phase 4 product scopes — no new PermissionScope
values were invented for packs (GATE 11, PHASE_10_PACKS_ANALYSIS.md).
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.pack import (
    PackAvailabilityResponse,
    PackCreateRequest,
    PackDetailResponse,
    PackListResponse,
    PackUpdateRequest,
)
from app.services.pack import PackService

router = APIRouter()


def _get_pack_service(db: Session = Depends(get_db)) -> PackService:
    return PackService(db)


def _pages(total: int, page_size: int) -> int:
    return math.ceil(total / page_size) if total > 0 and page_size > 0 else 1


# ---------------------------------------------------------------------------
# List / create
# ---------------------------------------------------------------------------


@router.get(
    "",
    response_model=PackListResponse,
    summary="List packs",
    tags=["packs"],
)
def list_packs(
    page: int = Query(1, ge=1, description="Page number (1-indexed)"),
    page_size: int = Query(
        DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE, description="Items per page"
    ),
    search: str | None = Query(
        None, max_length=200, description="Match pack name or barcode"
    ),
    status: str = Query(
        "active",
        pattern="^(active|archived|all)$",
        description="active (default) | archived | all",
    ),
    _: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: PackService = Depends(_get_pack_service),
) -> PackListResponse:
    """Paginated pack list with ``components_count`` and ``sum_of_parts``.

    ``sum_of_parts`` is informational only (GATE 3) — never used for
    pricing, totals or stock.
    """
    rows, total = service.list(
        page=page, page_size=page_size, search=search, status=status
    )
    return service.to_list_response(
        rows, total=total, page=page, page_size=page_size
    )


@router.post(
    "",
    response_model=PackDetailResponse,
    status_code=201,
    summary="Create pack",
    tags=["packs"],
)
def create_pack(
    request: PackCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: PackService = Depends(_get_pack_service),
) -> PackDetailResponse:
    """Create a pack with its component set.

    Components target base products only (GATE 1); a duplicate product
    yields 422 ``PACK_COMPONENT_DUPLICATE``.
    """
    pack = service.create(request, actor_id=user.id)
    return PackService.to_detail_response(pack)


# ---------------------------------------------------------------------------
# Detail / update / archive  (routes below /{pack_id} must not collide)
# ---------------------------------------------------------------------------


@router.get(
    "/{pack_id}",
    response_model=PackDetailResponse,
    summary="Get pack",
    tags=["packs"],
)
def get_pack(
    pack_id: uuid.UUID,
    _: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: PackService = Depends(_get_pack_service),
) -> PackDetailResponse:
    """Pack detail: list fields plus the resolved component rows."""
    return PackService.to_detail_response(service.get(pack_id))


@router.put(
    "/{pack_id}",
    response_model=PackDetailResponse,
    summary="Update pack",
    tags=["packs"],
)
def update_pack(
    pack_id: uuid.UUID,
    request: PackUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_UPDATE)),
    service: PackService = Depends(_get_pack_service),
) -> PackDetailResponse:
    """Partial update — only fields present in the body change.

    ``components``, when present, replaces the whole component set.
    Editing a pack never rewrites historical sales (GATE 7): invoices
    read their own snapshots.
    """
    pack = service.update(pack_id, request, actor_id=user.id)
    return PackService.to_detail_response(pack)


@router.delete(
    "/{pack_id}",
    response_model=PackDetailResponse,
    summary="Archive pack",
    tags=["packs"],
)
def archive_pack(
    pack_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_ARCHIVE)),
    service: PackService = Depends(_get_pack_service),
) -> PackDetailResponse:
    """Soft-archive a pack (GATE 8): ``archived_at`` set, ``is_active=false``.

    Archived packs disappear from the default list and the POS picker and
    are rejected at checkout with 422 ``PACK_INACTIVE``. A hard delete is
    never attempted — ``sale_lines.pack_id`` is RESTRICT.
    """
    pack = service.archive(pack_id, actor_id=user.id)
    return PackService.to_detail_response(pack)


@router.get(
    "/{pack_id}/availability",
    response_model=PackAvailabilityResponse,
    summary="Pack component availability",
    tags=["packs"],
)
def pack_availability(
    pack_id: uuid.UUID,
    quantity: Decimal = Query(
        Decimal("1"),
        gt=0,
        description="Number of packs the caller wants to sell",
    ),
    _: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: PackService = Depends(_get_pack_service),
) -> PackAvailabilityResponse:
    """Read-only component stock position for a pack quantity.

    Never reserves or mutates stock — it is a pre-flight check for the
    POS picker and the pack management screen.
    """
    return service.availability(pack_id, quantity)
