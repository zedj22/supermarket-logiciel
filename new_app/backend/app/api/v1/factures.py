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

There is deliberately NO DELETE endpoint — historical fiscal documents
are never deleted by the application — and no PDF/DOCX/print route.

RBAC: every endpoint requires an authenticated user
(``get_current_user``). NO new PermissionScope is invented here —
facturation permission scopes belong to the later permissions phase
(precedent: backups / print / settings endpoints authenticate without a
scope). Router-level rate-limit + device guards from ``api_router``
apply as on every other route.
"""

from __future__ import annotations

import math
import uuid
from datetime import date

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.domain.unit_conversions import to_decimal
from app.models.facturation import InvoiceClient, InvoiceDocument, InvoiceDocumentLine
from app.models.user import User
from app.schemas.facturation import (
    InvoiceClientRefResponse,
    InvoiceDocumentCreateRequest,
    InvoiceDocumentListResponse,
    InvoiceDocumentPreviewResponse,
    InvoiceDocumentResponse,
    InvoiceDocumentSummaryResponse,
    InvoiceDocumentTotalsResponse,
    InvoiceDocumentUpdateRequest,
    InvoiceLinePreviewResponse,
    InvoiceLineResponse,
)
from app.services.facturation import (
    DocumentPreviewResult,
    InvoiceDocumentService,
    calculate_document_result,
)

router = APIRouter()

DEFAULT_PAGE_SIZE = 20


# ── Dependencies ────────────────────────────────────────────────────────


def _get_document_service(db: Session = Depends(get_db)) -> InvoiceDocumentService:
    return InvoiceDocumentService(db)


# ── Mappers ─────────────────────────────────────────────────────────────


def _to_client_ref(client: InvoiceClient | None) -> InvoiceClientRefResponse | None:
    if client is None:
        return None
    return InvoiceClientRefResponse(
        id=client.id,
        name=client.name,
        address=client.address,
        wilaya=client.wilaya,
        phone=client.phone,
        nif=client.nif,
        rc=client.rc,
        ai=client.ai,
        nis=client.nis,
        is_archived=client.archived_at is not None,
        created_at=client.created_at,
        updated_at=client.updated_at,
    )


def _to_totals(totals) -> InvoiceDocumentTotalsResponse:
    """Phase 1 ``DocumentTotals`` → response (centime Decimals as-is)."""
    return InvoiceDocumentTotalsResponse(
        total_ht=totals.total_ht,
        total_tva=totals.total_tva,
        total_ttc=totals.total_ttc,
        timbre=totals.timbre,
        net_a_payer=totals.net_a_payer,
    )


def _line_fields(line: InvoiceDocumentLine) -> dict:
    return {
        "product_id": line.product_id,
        "description": line.description,
        "quantity": to_decimal(line.quantity),
        "unit_price_ht": to_decimal(line.unit_price_ht),
        "tva_rate": to_decimal(line.tva_rate),
        "discount_pct": to_decimal(line.discount_pct),
        "position": line.position,
    }


def _to_line_response(line: InvoiceDocumentLine, line_totals) -> InvoiceLineResponse:
    return InvoiceLineResponse(
        id=line.id,
        total_ht=line_totals.net_ht,
        total_tva=line_totals.tva,
        **_line_fields(line),
    )


def _to_preview_line(line: InvoiceDocumentLine, line_totals) -> InvoiceLinePreviewResponse:
    return InvoiceLinePreviewResponse(
        total_ht=line_totals.net_ht,
        total_tva=line_totals.tva,
        **_line_fields(line),
    )


def _to_detail(document: InvoiceDocument) -> InvoiceDocumentResponse:
    """Full document + the shared Phase 1 calculation (single path)."""
    calculation = calculate_document_result(
        document.doc_type,
        document.payment_method,
        document.show_timbre,
        document.lines,
    )
    ordered = sorted(document.lines, key=lambda line: line.position)
    lines = [
        _to_line_response(line, line_totals)
        for line, line_totals in zip(ordered, calculation.line_totals)
    ]
    return InvoiceDocumentResponse(
        id=document.id,
        doc_type=document.doc_type,
        year=document.year,
        number=document.number,
        document_date=document.document_date,
        client_id=document.client_id,
        client=_to_client_ref(document.client),
        payment_method=document.payment_method,
        notes=document.notes,
        show_discount=document.show_discount,
        show_tva=document.show_tva,
        show_timbre=document.show_timbre,
        show_payment_method=document.show_payment_method,
        show_amount_words=document.show_amount_words,
        lines=lines,
        totals=_to_totals(calculation.totals),
        amount_in_words=calculation.amount_in_words,
        created_at=document.created_at,
        updated_at=document.updated_at,
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
        client=_to_client_ref(document.client),
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
        client=_to_client_ref(result.client),
        lines=lines,
        totals=_to_totals(result.calculation.totals),
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
    return _to_detail(document)


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
    + amount in words. Never renders PDF here."""
    return _to_detail(service.get(document_id))


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
    return _to_detail(document)
