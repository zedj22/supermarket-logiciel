"""Purchases API (Phase 11).

Endpoints:
- GET    /api/v1/purchases                 — list (q / status / supplier filters)
- POST   /api/v1/purchases                 — create (receive=true posts atomically)
- GET    /api/v1/purchases/{id}            — header + lines
- PUT    /api/v1/purchases/{id}            — partial edit (draft only)
- POST   /api/v1/purchases/{id}/receive    — draft -> received (atomic posting)
- POST   /api/v1/purchases/{id}/cancel     — received -> cancelled (reversal)
- DELETE /api/v1/purchases/{id}            — hard delete (draft only, 204)

RBAC (decision record §19): list/detail PURCHASE_VIEW; create/edit/
receive PURCHASE_CREATE; cancel/delete PURCHASE_DELETE (no new scopes).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.purchase import (
    PurchaseCreateRequest,
    PurchaseListResponse,
    PurchaseResponse,
    PurchaseUpdateRequest,
)
from app.services.purchases import PurchaseService, to_response

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


def _get_service(db: Session = Depends(get_db)) -> PurchaseService:
    return PurchaseService(db)


# ── Reads ───────────────────────────────────────────────────────────────


@router.get(
    "",
    response_model=PurchaseListResponse,
    summary="List purchases",
    tags=["purchases"],
)
def list_purchases(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    q: str | None = Query(None, max_length=200),
    status: str | None = Query(None, max_length=20),
    supplier_id: uuid.UUID | None = Query(None),
    user: User = Depends(require_permission(PermissionScope.PURCHASE_VIEW)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseListResponse:
    """Paginated purchase history; ``q`` matches invoice/supplier/note."""
    return service.list(
        page=page,
        page_size=page_size,
        q=q,
        status=status,
        supplier_id=supplier_id,
    )


@router.get(
    "/{purchase_id}",
    response_model=PurchaseResponse,
    summary="Get purchase",
    tags=["purchases"],
)
def get_purchase(
    purchase_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_VIEW)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseResponse:
    """Purchase detail: header + snapshot lines."""
    return to_response(service.get(purchase_id))


# ── Writes ──────────────────────────────────────────────────────────────


@router.post(
    "",
    response_model=PurchaseResponse,
    status_code=201,
    summary="Create purchase",
    tags=["purchases"],
)
def create_purchase(
    request: PurchaseCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_CREATE)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseResponse:
    """Create a purchase.

    ``receive=true`` (default) creates AND receives the document in ONE
    atomic transaction (stock + PMP + movements + payable + audit);
    ``receive=false`` saves an editable draft with no side effects.
    A repeated ``client_request_id`` returns the original document.
    """
    purchase, replay = service.create(request, actor_id=user.id)
    return to_response(purchase, idempotent_replay=replay)


@router.put(
    "/{purchase_id}",
    response_model=PurchaseResponse,
    summary="Update purchase draft",
    tags=["purchases"],
)
def update_purchase(
    purchase_id: uuid.UUID,
    request: PurchaseUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_CREATE)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseResponse:
    """Partial update of a DRAFT purchase; received/cancelled are immutable."""
    return to_response(
        service.update(purchase_id, request, actor_id=user.id)
    )


@router.post(
    "/{purchase_id}/receive",
    response_model=PurchaseResponse,
    summary="Receive purchase",
    tags=["purchases"],
)
def receive_purchase(
    purchase_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_CREATE)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseResponse:
    """draft -> received: stock, PMP, movements and payable post atomically.

    Idempotency is the FOR UPDATE state guard: a duplicate request
    returns 409 PURCHASE_ALREADY_RECEIVED (stock never doubles).
    """
    return to_response(service.receive(purchase_id, actor_id=user.id))


@router.post(
    "/{purchase_id}/cancel",
    response_model=PurchaseResponse,
    summary="Cancel purchase",
    tags=["purchases"],
)
def cancel_purchase(
    purchase_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_DELETE)),
    service: PurchaseService = Depends(_get_service),
) -> PurchaseResponse:
    """received -> cancelled: symmetric reversal (stock, packaging,
    payable capped at current balance). PMP is never recomputed."""
    return to_response(service.cancel(purchase_id, actor_id=user.id))


@router.delete(
    "/{purchase_id}",
    status_code=204,
    response_class=Response,
    summary="Delete purchase draft",
    tags=["purchases"],
)
def delete_purchase(
    purchase_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PURCHASE_DELETE)),
    service: PurchaseService = Depends(_get_service),
) -> Response:
    """Hard-delete a DRAFT (audited). Received documents are cancelled
    instead — append-only document rule (Phase 0 rule 4)."""
    service.delete(purchase_id, actor_id=user.id)
    return Response(status_code=204)
