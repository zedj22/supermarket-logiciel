"""Zakat API endpoints.

Every surface is gated by the pre-existing ``report_financial`` scope
(admin + manager): zakat is a financial calculation aid, and the role
matrix already places financial reads there.  No new permission was
introduced (decision: reuse, never widen).

- GET  /api/v1/zakat/context   — seed the screen (imports + defaults)
- POST /api/v1/zakat/calculate — stateless preview
- POST /api/v1/zakat/pdf       — ad-hoc preview report (PDF bytes)
- GET  /api/v1/zakat           — saved calculation history
- POST /api/v1/zakat           — save one immutable snapshot
- GET  /api/v1/zakat/{id}      — one snapshot
- POST /api/v1/zakat/{id}/payment — record an actual payment
- GET  /api/v1/zakat/{id}/pdf  — snapshot report (PDF bytes)

Static paths (``context``, ``calculate``, ``pdf``) are declared before
``/{calculation_id}`` so they are never shadowed by the parameterized
routes.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.common import PaginatedResponse
from app.schemas.zakat import (
    ZakatCalculationCreateRequest,
    ZakatCalculationDetail,
    ZakatCalculationSummary,
    ZakatCalculateRequest,
    ZakatCalculateResponse,
    ZakatContext,
    ZakatPaymentCreateRequest,
)
from app.services.zakat import DEFAULT_LOCALE, LOCALES, ZakatService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ZakatService:
    return ZakatService(db)


def _locale(locale: str = Query(DEFAULT_LOCALE, pattern="^(ar|fr|en)$")) -> str:
    return locale if locale in LOCALES else DEFAULT_LOCALE


@router.get(
    "/context",
    response_model=ZakatContext,
    summary="Zakat screen context (imports + defaults)",
    tags=["zakat"],
)
def zakat_context(
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> ZakatContext:
    """Store identity, official nisab reference, imported stock totals,
    the customer debt ledger total (double-count guard) and supplier
    payables as deduction candidates.  Read-only."""
    return service.context()


@router.post(
    "/calculate",
    response_model=ZakatCalculateResponse,
    summary="Run one zakat calculation (preview, nothing is saved)",
    tags=["zakat"],
)
def zakat_calculate(
    request: ZakatCalculateRequest,
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> ZakatCalculateResponse:
    """Stateless preview.  The server is the only place the formula
    runs; the response marks incomplete inputs ``provisional``."""
    return service.calculate(request)


@router.post(
    "/pdf",
    response_class=Response,
    summary="Ad-hoc zakat report (PDF bytes, nothing is saved)",
    tags=["zakat"],
)
def zakat_preview_pdf(
    request: ZakatCalculateRequest,
    locale: str = Depends(_locale),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> Response:
    """Render the same report as the snapshot PDF for an unsaved
    calculation."""
    payload, filename = service.pdf_for_request(request, locale=locale)
    return Response(
        content=payload,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get(
    "",
    response_model=PaginatedResponse[ZakatCalculationSummary],
    summary="Saved zakat calculation history",
    tags=["zakat"],
)
def zakat_list(
    page: int = Query(1, ge=1),
    page_size: int = Query(40, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> PaginatedResponse[ZakatCalculationSummary]:
    """Newest first.  Snapshots are immutable."""
    return service.list(page=page, page_size=page_size)


@router.post(
    "",
    response_model=ZakatCalculationDetail,
    status_code=201,
    summary="Save one zakat calculation as an immutable snapshot",
    tags=["zakat"],
)
def zakat_save(
    request: ZakatCalculationCreateRequest,
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> ZakatCalculationDetail:
    """Idempotent on ``client_request_id`` (same key + payload replays,
    different payload is 409 IDEMPOTENCY_CONFLICT)."""
    return service.save(request, user=user)


@router.get(
    "/{calculation_id}",
    response_model=ZakatCalculationDetail,
    summary="One saved zakat calculation",
    tags=["zakat"],
)
def zakat_get(
    calculation_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> ZakatCalculationDetail:
    """Snapshot detail: stored result + the exact inputs + payments."""
    return service.get(calculation_id)


@router.post(
    "/{calculation_id}/payment",
    response_model=ZakatCalculationDetail,
    status_code=201,
    summary="Record one zakat payment against a saved calculation",
    tags=["zakat"],
)
def zakat_payment(
    calculation_id: uuid.UUID,
    request: ZakatPaymentCreateRequest,
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> ZakatCalculationDetail:
    """Append-only payment record; the snapshot numbers never change."""
    return service.record_payment(calculation_id, request, user=user)


@router.get(
    "/{calculation_id}/pdf",
    response_class=Response,
    summary="Saved zakat calculation report (PDF bytes)",
    tags=["zakat"],
)
def zakat_pdf(
    calculation_id: uuid.UUID,
    locale: str = Depends(_locale),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ZakatService = Depends(_get_service),
) -> Response:
    """Official-style report: assets, liabilities, result, warnings and
    the calculation disclaimer (localized ar/fr/en)."""
    payload, filename = service.pdf(calculation_id, locale=locale)
    return Response(
        content=payload,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
