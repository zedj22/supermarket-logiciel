"""Invoice (fiscal) clients API (Phase 8 — Flutter facturation UI).

Thin HTTP layer over the existing Phase 2 ``InvoiceClientService`` —
no business logic is duplicated here (validation, trimming, audit rows
and archive semantics all stay in the service):

- GET    /api/v1/invoice-clients         — list (paginated; q = name/phone)
- POST   /api/v1/invoice-clients         — create (201)
- GET    /api/v1/invoice-clients/{id}    — detail
- PUT    /api/v1/invoice-clients/{id}    — partial update
- DELETE /api/v1/invoice-clients/{id}    — soft archive (never a hard
  delete: FK RESTRICT keeps historical documents valid; DELETE-as-
  archive matches the suppliers / customers / products convention)

Invoice clients are the fiscal/document identity — a SEPARATE domain
from the POS ``Customer``: this router never touches the customers
table. Archived clients cannot receive NEW documents (422
``INVOICE_CLIENT_ARCHIVED`` from the factures create/preview routes)
but stay retrievable, stay visible with ``include_archived=true``, and
their historical documents remain intact.

RBAC: authenticated-only — the facturation precedent (no
PermissionScope; same as /factures, backups, print, settings).
"""

from __future__ import annotations

import math
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.facturation import InvoiceClient
from app.models.user import User
from app.schemas.invoice_clients import (
    InvoiceClientCreateRequest,
    InvoiceClientListResponse,
    InvoiceClientResponse,
    InvoiceClientUpdateRequest,
)
from app.services.facturation import InvoiceClientService, build_client_ref

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


# ── Dependencies ────────────────────────────────────────────────────────


def _get_service(db: Session = Depends(get_db)) -> InvoiceClientService:
    return InvoiceClientService(db)


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_response(client: InvoiceClient) -> InvoiceClientResponse:
    ref = build_client_ref(client)
    assert ref is not None  # client is always a real row here
    return ref


def _page(total: int, page: int, page_size: int) -> int:
    return max(1, math.ceil(total / page_size)) if page_size else 1


# ── CRUD ────────────────────────────────────────────────────────────────


@router.get(
    "",
    response_model=InvoiceClientListResponse,
    summary="List invoice clients",
    tags=["invoice-clients"],
)
def list_invoice_clients(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    q: str | None = Query(None, max_length=200),
    include_archived: bool = Query(False),
    user: User = Depends(get_current_user),
    service: InvoiceClientService = Depends(_get_service),
) -> InvoiceClientListResponse:
    """Paginated invoice-client list; ``q`` matches name/phone.

    Deterministic name ordering; archived rows hidden by default.
    """
    rows, total = service.list(
        page=page,
        page_size=page_size,
        q=q,
        include_archived=include_archived,
    )
    return InvoiceClientListResponse(
        items=[_to_response(client) for client in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


@router.post(
    "",
    response_model=InvoiceClientResponse,
    status_code=201,
    summary="Create invoice client",
    tags=["invoice-clients"],
)
def create_invoice_client(
    request: InvoiceClientCreateRequest,
    user: User = Depends(get_current_user),
    service: InvoiceClientService = Depends(_get_service),
) -> InvoiceClientResponse:
    """Create an invoice client (``name`` is the only required field)."""
    return _to_response(
        service.create(
            name=request.name,
            address=request.address,
            wilaya=request.wilaya,
            phone=request.phone,
            nif=request.nif,
            rc=request.rc,
            ai=request.ai,
            nis=request.nis,
            actor_id=user.id,
        )
    )


@router.get(
    "/{client_id}",
    response_model=InvoiceClientResponse,
    summary="Get invoice client",
    tags=["invoice-clients"],
)
def get_invoice_client(
    client_id: uuid.UUID,
    user: User = Depends(get_current_user),
    service: InvoiceClientService = Depends(_get_service),
) -> InvoiceClientResponse:
    """Invoice-client detail (archived rows included — history stays readable)."""
    return _to_response(service.get(client_id))


@router.put(
    "/{client_id}",
    response_model=InvoiceClientResponse,
    summary="Update invoice client",
    tags=["invoice-clients"],
)
def update_invoice_client(
    client_id: uuid.UUID,
    request: InvoiceClientUpdateRequest,
    user: User = Depends(get_current_user),
    service: InvoiceClientService = Depends(_get_service),
) -> InvoiceClientResponse:
    """Partial update — only fields present in the body change."""
    updates = request.model_dump(exclude_unset=True)
    return _to_response(service.update(client_id, **updates, actor_id=user.id))


@router.delete(
    "/{client_id}",
    response_model=InvoiceClientResponse,
    summary="Archive invoice client",
    tags=["invoice-clients"],
)
def archive_invoice_client(
    client_id: uuid.UUID,
    user: User = Depends(get_current_user),
    service: InvoiceClientService = Depends(_get_service),
) -> InvoiceClientResponse:
    """Soft-archive an invoice client (idempotent, never a hard delete).

    Allowed even while documents reference the client — historical
    documents keep their relationship; only NEW documents are refused.
    """
    return _to_response(service.archive(client_id, actor_id=user.id))
