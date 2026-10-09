"""Facturation documents API (Phase 5 — backend document workflow).

Endpoints (factura_simple ``/documents`` parity, adapted to SP route /
schema / pagination conventions):

- POST   /api/v1/factures           — create document (201; number
  allocated atomically inside the create transaction)
- POST   /api/v1/factures/preview   — dry-run calculation (no rows
  written, no number consumed; declared before ``/{document_id}``)
- GET    /api/v1/factures           — list (paginated; filters: doc_type,
  year, client_id, date range, number search ``q``)
- GET    /api/v1/factures/{id}      — detail (lines + Phase 1 totals +
  amount in words)
- PUT    /api/v1/factures/{id}      — partial update (immutable: id,
  doc_type, year, number, document_date)
- POST   /api/v1/factures/{id}/pdf  — render that document as A4 PDF
  bytes (Phase 7; declared after the ``/{document_id}`` routes)

There is deliberately NO DELETE endpoint — historical fiscal documents
are never deleted by the application — and no DOCX export.

RBAC: every endpoint requires an authenticated user
(``get_current_user``). NO new PermissionScope is invented here —
facturation permission scopes belong to the later permissions phase
(precedent: backups / print / settings endpoints authenticate without a
scope), and the PDF route follows the same authenticated-only contract
by design. Router-level rate-limit + device guards from ``api_router``
apply as on every other route.

The detail payload is built by ``build_document_response`` (service
layer) so the PDF prints exactly what ``GET /factures/{id}`` returns.
"""

from __future__ import annotations

import math
import uuid
from datetime import date

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.facturation import InvoiceDocument, InvoiceDocumentLine
from app.models.user import User
from app.schemas.export import ExportLocale
from app.schemas.facturation import (
    InvoiceDocumentCreateRequest,
    InvoiceDocumentListResponse,
    InvoiceDocumentPreviewResponse,
    InvoiceDocumentResponse,
    InvoiceDocumentSummaryResponse,
    InvoiceDocumentUpdateRequest,
    InvoiceLinePreviewResponse,
)
from app.services.facturation import (
    DocumentPreviewResult,
    InvoiceDocumentService,
    build_client_ref,
    build_document_response,
    build_line_fields,
    build_totals_response,
)
from app.services.print import PrintService

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


# ── Dependencies ────────────────────────────────────────────────────────


def _get_document_service(db: Session = Depends(get_db)) -> InvoiceDocumentService:
    return InvoiceDocumentService(db)


def _get_print_service(db: Session = Depends(get_db)) -> PrintService:
    return PrintService(db)


def _client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_preview_line(line: InvoiceDocumentLine, line_totals) -> InvoiceLinePreviewResponse:
    return InvoiceLinePreviewResponse(
        total_ht=line_totals.net_ht,
        total_tva=line_totals.tva,
        **build_line_fields(line),
    )


def _to_summary(document: InvoiceDocument) -> InvoiceDocumentSummaryResponse:
    """List row: identity + client reference, no lines / totals."""
    return InvoiceDocumentSummaryResponse(
        id=document.id,
        doc_type=document.doc_type,
        year=document.year,
        number=document.number,
        document_date=document.document_date,
        client_id=document.client_id,
        client=build_client_ref(document.client),
        payment_method=document.payment_method,
        notes=document.notes,
        created_at=document.created_at,
        updated_at=document.updated_at,
    )


def _to_preview(result: DocumentPreviewResult) -> InvoiceDocumentPreviewResponse:
    lines = [
        _to_preview_line(line, line_totals)
        for line, line_totals in zip(result.lines, result.calculation.line_totals)
    ]
    return InvoiceDocumentPreviewResponse(
        document_date=result.document_date,
        year=result.year,
        number=result.proposed_number,
        client_id=result.client.id,
        client=build_client_ref(result.client),
        lines=lines,
        totals=build_totals_response(result.calculation.totals),
        amount_in_words=result.calculation.amount_in_words,
    )


def _page(total: int, page: int, page_size: int) -> int:
    return max(1, math.ceil(total / page_size)) if page_size else 1


# ── Create / preview ────────────────────────────────────────────────────


@router.post(
    "",
    response_model=InvoiceDocumentResponse,
    status_code=201,
    summary="Create facturation document",
    tags=["factures"],
)
def create_document(
    request: InvoiceDocumentCreateRequest,
    user: User = Depends(get_current_user),
    service: InvoiceDocumentService = Depends(_get_document_service),
) -> InvoiceDocumentResponse:
    """Create a FAC / DEV / PRO / BC / BL with an allocated number.

    Client, products and lines are resolved and validated BEFORE the
    transaction; the counter increment + document + lines + audit row
    commit together (failed creation never consumes a number).
    """
    document = service.create(request, actor_id=user.id)
    return build_document_response(document)


@router.post(
    "/preview",
    response_model=InvoiceDocumentPreviewResponse,
    summary="Preview document calculation (no persistence)",
    tags=["factures"],
)
def preview_document(
    request: InvoiceDocumentCreateRequest,
    user: User = Depends(get_current_user),
    service: InvoiceDocumentService = Depends(_get_document_service),
) -> InvoiceDocumentPreviewResponse:
    """Dry-run: resolve client + products, validate, Phase 1 totals.

    Writes nothing and consumes no number (``number`` is a read-only
    proposal). Same inputs and validation as POST — the future UI shows
    exactly what a submit would produce or reject.
    """
    return _to_preview(service.preview(request))


# ── List ────────────────────────────────────────────────────────────────


@router.get(
    "",
    response_model=InvoiceDocumentListResponse,
    summary="List facturation documents",
    tags=["factures"],
)
def list_documents(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    doc_type: str | None = Query(None, max_length=20),
    year: int | None = Query(None, ge=1),
    client_id: uuid.UUID | None = Query(None),
    date_from: date | None = Query(None),
    date_to: date | None = Query(None),
    q: str | None = Query(None, max_length=50, description="number contains"),
    user: User = Depends(get_current_user),
    service: InvoiceDocumentService = Depends(_get_document_service),
) -> InvoiceDocumentListResponse:
    """Paginated document list — deterministic newest-first ordering.

    Every historical document stays listable (documents have no archive
    flag; an archived invoice client does not hide its documents).
    ``q`` substring-searches the formatted number (e.g. ``FAC-2026``).
    """
    rows, total = service.list(
        page=page,
        page_size=page_size,
        doc_type=doc_type,
        year=year,
        client_id=client_id,
        date_from=date_from,
        date_to=date_to,
        q=q,
    )
    return InvoiceDocumentListResponse(
        items=[_to_summary(document) for document in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=_page(total, page, page_size),
    )


# ── Detail / update ─────────────────────────────────────────────────────


@router.get(
    "/{document_id}",
    response_model=InvoiceDocumentResponse,
    summary="Get facturation document",
    tags=["factures"],
)
def get_document(
    document_id: uuid.UUID,
    user: User = Depends(get_current_user),
    service: InvoiceDocumentService = Depends(_get_document_service),
) -> InvoiceDocumentResponse:
    """Document detail: snapshot lines (position order) + Phase 1 totals
    + amount in words. Rendering happens on ``POST /{id}/pdf``."""
    return build_document_response(service.get(document_id))


@router.put(
    "/{document_id}",
    response_model=InvoiceDocumentResponse,
    summary="Update facturation document",
    tags=["factures"],
)
def update_document(
    document_id: uuid.UUID,
    request: InvoiceDocumentUpdateRequest,
    user: User = Depends(get_current_user),
    service: InvoiceDocumentService = Depends(_get_document_service),
) -> InvoiceDocumentResponse:
    """Partial update: only supplied fields change.

    Immutable (absent from the schema — cannot be expressed):
    id / doc_type / year / number / document_date. ``lines`` (when
    present) atomically replaces the whole line set; no change ever
    re-allocates a number. No DELETE exists.
    """
    document = service.update(document_id, request, actor_id=user.id)
    return build_document_response(document)


# ── PDF (Phase 7) ───────────────────────────────────────────────────────


@router.post(
    "/{document_id}/pdf",
    summary="Render facturation document as PDF",
    tags=["factures"],
    response_class=Response,
)
def print_document_pdf(
    document_id: uuid.UUID,
    request: Request,
    locale: ExportLocale = Query("ar"),
    user: User = Depends(get_current_user),
    service: PrintService = Depends(_get_print_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> Response:
    """A4 PDF bytes for one FAC / DEV / PRO / BC / BL (Phase 7).

    Authenticated-only like every other facturation route (facturation
    has no PermissionScope yet — same precedent as backups / print /
    settings), so a role-less guest may print a document it can read.
    ``locale`` is allowlisted to ar / fr / en: anything else is a 422
    VALIDATION_ERROR before any DB read or render. The printed date is
    the STORED ``document_date`` (never "today") and the amount in words
    stays the Phase 1 French sentence in every locale. The service writes
    exactly one ``print`` audit row per attempt (success or failure).
    """
    result = service.render_facturation(
        document_id,
        locale=locale,
        user_id=user.id,
        ip_address=_client_ip(request),
        device_id=x_device_id,
    )
    return Response(
        content=result.data,
        media_type=result.media_type,
        headers={"Content-Disposition": f'attachment; filename="{result.filename}"'},
    )
