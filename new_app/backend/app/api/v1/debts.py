"""Debts API (Phase 9).

Endpoints:
- GET /api/v1/debts/summary — total outstanding debt + debtor count

History and payment recording live under the customer routes
(``/customers/{id}/debts``, ``/customers/{id}/pay``) per the Phase 0
API blueprint.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.api.dependencies import require_permission
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.party import DebtSummaryResponse
from app.services.debt import DebtService
from app.db.session import get_db
from sqlalchemy.orm import Session

router = APIRouter()


def _get_debt_service(db: Session = Depends(get_db)) -> DebtService:
    return DebtService(db)


@router.get(
    "/summary",
    response_model=DebtSummaryResponse,
    summary="Total outstanding debt",
    tags=["debts"],
)
def debt_summary(
    user: User = Depends(require_permission(PermissionScope.CUSTOMER_VIEW)),
    service: DebtService = Depends(_get_debt_service),
) -> DebtSummaryResponse:
    """Aggregate receivables across customers.

    Computed from ``customers.balance`` (the cached projection, which is
    reconciled against the append-only ledger by tests). Archived
    customers always carry balance 0, so they never inflate the total.
    """
    total, count = service.summary()
    return DebtSummaryResponse(total_debt=total, customers_with_debt=count)
