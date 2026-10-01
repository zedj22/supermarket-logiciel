"""Dashboard endpoint (Phase 14, §7).

One request returns every KPI: today's income (reusing the §5.1–§5.3 report
formulas), the stock/customer/AR snapshots, the latest sales of the selected
period and its top products.  ``alerts`` are deferred (GATE 27).
"""

from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.report import DashboardResponse
from app.services.report import ReportService

dashboard_router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ReportService:
    return ReportService(db)


@dashboard_router.get(
    "",
    response_model=DashboardResponse,
    summary="Dashboard KPIs",
    tags=["dashboard"],
)
def dashboard(
    date_from: date | None = Query(None),
    date_to: date | None = Query(None),
    user: User = Depends(require_permission(PermissionScope.REPORT_FINANCIAL)),
    service: ReportService = Depends(_get_service),
) -> DashboardResponse:
    """§7 KPIs; the optional period only shapes ``recent_sales``/``top_products``.

    Both dates default to the current UTC day so a bare ``GET /dashboard``
    stays a single, cheap round trip.
    """
    return service.dashboard(date_from=date_from, date_to=date_to)
