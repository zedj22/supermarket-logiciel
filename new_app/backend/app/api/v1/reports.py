"""Reports API endpoints (Phase 14).

Eleven ``/api/v1/reports/*`` surfaces (§11 of the Phase 14 decision record
plus the Loyalty Phase F loyalty report) plus ``/api/v1/dashboard`` in
``dashboard.py``.  Every handler is guarded by the existing
``report_financial`` scope — no new permission was introduced.

Conventions: ``date_from``/``date_to`` are inclusive calendar dates resolved
to a UTC window server-side (§6), rows are paginated with the standard
``page``/``page_size`` pair and caps are enforced by the service so the error
envelope carries the documented ``REPORT_*`` codes.
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope, SaleStatus
from app.models.user import User
from app.schemas.report import (
    CategoryReportResponse,
    DailyReportResponse,
    FinancialReportResponse,
    HourlyReportResponse,
    LoyaltyReportResponse,
    PeakHoursReportResponse,
    ProductReportResponse,
    SalesDetailResponse,
    SlowMovingResponse,
    SupplierReportResponse,
    VoidedReportResponse,
)
from app.services.report import ReportService

reports_router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ReportService:
    return ReportService(db)


@reports_router.get(
    "/financial",
    response_model=FinancialReportResponse,
    summary="Financial / P&L report",
    tags=["reports"],
)
def financial_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> FinancialReportResponse:
    """§5.1–§5.5 blocks plus the §8 R15 device breakdown."""
    return service.financial(date_from=date_from, date_to=date_to, device_id=device_id)


@reports_router.get(
    "/sales",
    response_model=SalesDetailResponse,
    summary="Sales detail (report table + CSV row source)",
    tags=["reports"],
)
def sales_report(
    date_from: date,
    date_to: date,
    status: str = Query(SaleStatus.COMPLETED.value, pattern="^(completed|void|all)$"),
    payment_method: str | None = Query(None, pattern="^(cash|card|credit|partial)$"),
    user_id: uuid.UUID | None = None,
    device_id: str | None = Query(None, max_length=100),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> SalesDetailResponse:
    """§8 R9 — unlike ``GET /api/v1/sales`` this endpoint is filterable."""
    return service.sales(
        date_from=date_from,
        date_to=date_to,
        status=status,
        payment_method=payment_method,
        user_id=user_id,
        device_id=device_id,
        page=page,
        page_size=page_size,
    )


@reports_router.get(
    "/products",
    response_model=ProductReportResponse,
    summary="Product performance report",
    tags=["reports"],
)
def products_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    sort: str = Query("net_revenue"),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> ProductReportResponse:
    """§5.8 rows per item; ``sort`` ∈ net_revenue|qty_sold|gross_profit|return_qty|margin_pct."""
    return service.products(
        date_from=date_from,
        date_to=date_to,
        device_id=device_id,
        sort=sort,
        page=page,
        page_size=page_size,
    )


@reports_router.get(
    "/categories",
    response_model=CategoryReportResponse,
    summary="Category analysis report",
    tags=["reports"],
)
def categories_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> CategoryReportResponse:
    """§5.8 aggregated by category (NULL category → "uncategorized"), ≤500 rows."""
    return service.categories(date_from=date_from, date_to=date_to, device_id=device_id)


@reports_router.get(
    "/daily",
    response_model=DailyReportResponse,
    summary="Daily timeline",
    tags=["reports"],
)
def daily_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> DailyReportResponse:
    """§8 R4 — one row per UTC calendar day, ≤400 days."""
    return service.daily(date_from=date_from, date_to=date_to, device_id=device_id)


@reports_router.get(
    "/hourly",
    response_model=HourlyReportResponse,
    summary="Hourly timeline",
    tags=["reports"],
)
def hourly_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> HourlyReportResponse:
    """§8 R5 — one row per hour, ≤31 days."""
    return service.hourly(date_from=date_from, date_to=date_to, device_id=device_id)


@reports_router.get(
    "/peak-hours",
    response_model=PeakHoursReportResponse,
    summary="Peak hours",
    tags=["reports"],
)
def peak_hours_report(
    lookback_days: int = 30,
    device_id: str | None = Query(None, max_length=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> PeakHoursReportResponse:
    """§8 R6 — always exactly 24 rows; ``lookback_days`` ∈ 1..90."""
    return service.peak_hours(lookback_days=lookback_days, device_id=device_id)


@reports_router.get(
    "/slow-moving",
    response_model=SlowMovingResponse,
    summary="Slow-moving stock",
    tags=["reports"],
)
def slow_moving_report(
    days: int = 30,
    threshold: Decimal = Decimal("0"),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> SlowMovingResponse:
    """§8 R7 — active stock with no sale inside ``days`` (1..365)."""
    return service.slow_moving(
        days=days, threshold=threshold, page=page, page_size=page_size
    )


@reports_router.get(
    "/voided",
    response_model=VoidedReportResponse,
    summary="Voided invoices",
    tags=["reports"],
)
def voided_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> VoidedReportResponse:
    """§8 R8 — event report keyed by ``voided_at``, not ``sale_date`` (§5.9)."""
    return service.voided(
        date_from=date_from,
        date_to=date_to,
        device_id=device_id,
        page=page,
        page_size=page_size,
    )


@reports_router.get(
    "/suppliers",
    response_model=SupplierReportResponse,
    summary="Supplier payables / purchases",
    tags=["reports"],
)
def suppliers_report(
    date_from: date,
    date_to: date,
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> SupplierReportResponse:
    """§5.6 — period purchases/payments plus the current payable snapshot."""
    return service.suppliers(date_from=date_from, date_to=date_to)


@reports_router.get(
    "/loyalty",
    response_model=LoyaltyReportResponse,
    summary="Loyalty points and cashback activity",
    tags=["reports"],
)
def loyalty_report(
    date_from: date,
    date_to: date,
    device_id: str | None = Query(None, max_length=100),
    page: int = Query(1, ge=1),
    page_size: int = Query(100, ge=1, le=100),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> LoyaltyReportResponse:
    """Earned/redeemed rewards, return/void reversals with their shortfalls,
    the current outstanding balances, and the paginated ledger history."""
    return service.loyalty(
        date_from=date_from,
        date_to=date_to,
        device_id=device_id,
        page=page,
        page_size=page_size,
    )
