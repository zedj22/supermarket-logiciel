"""Expense application service (Phase 13).

Four operations (decision record §6):
- ``create``  POST /expenses            — idempotent (GATE 10)
- ``list``    GET  /expenses            — filtered, paginated (GATE 12)
- ``summary`` GET  /expenses/summary    — count/total/drawer/external
- ``cancel``  POST /expenses/{id}/cancel — posted → cancelled (GATE 1)

Hard rules (Phase 0 #3/#4, decision record §4/§8/§9/§13):
- Decimal only, ``0 < amount <= MONEY_MAX`` (legacy DOUBLE defect L1/L2),
- the row is NEVER deleted: corrections are cancel + re-create,
- ``expense_date`` is server-assigned and immutable (no backdating),
- ``user_id`` comes from the authenticated caller, never the body,
- ``paid_from_drawer`` is a classification flag only — no cash ledger is
  touched (GATE 5).
"""

from __future__ import annotations

import math
import uuid
from datetime import date, datetime, timezone

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError, NotFoundError, ValidationError
from app.domain.unit_conversions import to_decimal
from app.models.audit import AuditLog
from app.models.enums import AuditAction, ExpenseStatus
from app.models.expense import Expense
from app.repositories.expense import DEFAULT_STATUS, ExpenseRepository
from app.schemas.common import PaginatedResponse
from app.schemas.expense import (
    ExpenseCancelRequest,
    ExpenseCreateRequest,
    ExpenseResponse,
    ExpenseSummaryResponse,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

VALID_STATUSES = frozenset(
    {ExpenseStatus.POSTED.value, ExpenseStatus.CANCELLED.value, "all"}
)


def _normalize_title(title: str | None) -> str | None:
    """B1 (Fix Round 2): the title is optional.

    ``None`` and blank / whitespace-only values normalize to ``NULL``;
    a supplied title is trimmed. Mirrors
    ``ExpenseCreateRequest._blank_title_is_none`` so the persisted row
    and the idempotency signature always agree. No default title is
    ever invented.
    """
    if title is None:
        return None
    stripped = title.strip()
    return stripped or None


class ExpenseService(BaseService):
    """Application service for expenses."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ExpenseRepository(db)

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        q: str | None = None,
        category: str | None = None,
        paid_from_drawer: bool | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        status: str | None = DEFAULT_STATUS,
    ) -> PaginatedResponse[ExpenseResponse]:
        """Paginated, filtered expense list (default status = posted)."""
        self._validate_filters(date_from, date_to, status)
        rows, total = self.repo.search(
            page=page,
            page_size=page_size,
            q=q,
            category=category,
            paid_from_drawer=paid_from_drawer,
            date_from=date_from,
            date_to=date_to,
            status=status,
        )
        pages = max(1, math.ceil(total / page_size)) if total else 1
        return PaginatedResponse[ExpenseResponse](
            items=[to_response(row) for row in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=pages,
        )

    def summary(
        self,
        *,
        q: str | None = None,
        category: str | None = None,
        paid_from_drawer: bool | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        status: str | None = DEFAULT_STATUS,
    ) -> ExpenseSummaryResponse:
        """Legacy list metrics (W2): count / total / drawer / external."""
        self._validate_filters(date_from, date_to, status)
        count, total, drawer, external = self.repo.summary(
            q=q,
            category=category,
            paid_from_drawer=paid_from_drawer,
            date_from=date_from,
            date_to=date_to,
            status=status,
        )
        return ExpenseSummaryResponse(
            count=count,
            total_amount=to_decimal(total),
            drawer_amount=to_decimal(drawer),
            external_amount=to_decimal(external),
        )

    # ------------------------------------------------------------------
    # Create (idempotent)
    # ------------------------------------------------------------------

    def create(
        self,
        request: ExpenseCreateRequest,
        *,
        user=None,
        device_id: str | None = None,
    ) -> ExpenseResponse:
        """Record one expense atomically.

        Idempotency (GATE 10): ``client_request_id`` is required; a repeat
        with the same key AND payload returns the original row with
        ``idempotent_replay=true``, a repeat with a different payload is
        409 IDEMPOTENCY_CONFLICT, and a unique-key race rolls back and
        re-fetches the winner (Phase 8/9 pattern).
        """
        actor_id = user.id if user is not None else None
        key = request.client_request_id

        existing = self.repo.find_by_client_request_id(key)
        if existing is not None:
            self._assert_same_payload(existing, request)
            logger.info(
                "expense_idempotent_replay",
                client_request_id=key,
                expense_id=str(existing.id),
            )
            return to_response(existing, idempotent_replay=True)

        try:
            created_id = self._insert(
                request, actor_id=actor_id, device_id=device_id
            )
        except ConflictError:
            # Unique client_request_id race: another request won between
            # the fast-path check and our insert — return theirs.
            winner = self.repo.find_by_client_request_id(key)
            if winner is not None:
                self._assert_same_payload(winner, request)
                logger.info(
                    "expense_idempotent_race_replay",
                    client_request_id=key,
                    expense_id=str(winner.id),
                )
                return to_response(winner, idempotent_replay=True)
            raise

        saved = self.repo.get_by_id(created_id)
        if saved is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Expense committed but could not be re-read",
                details={"expense_id": str(created_id)},
            )
        logger.info(
            "expense_created",
            expense_id=str(saved.id),
            category=saved.category,
            amount=str(to_decimal(saved.amount)),
            paid_from_drawer=saved.paid_from_drawer,
            status=saved.status,
        )
        return to_response(saved, idempotent_replay=False)

    def _insert(
        self,
        request: ExpenseCreateRequest,
        *,
        actor_id: uuid.UUID | None,
        device_id: str | None,
    ) -> uuid.UUID:
        with self.transaction():
            expense = Expense(
                title=_normalize_title(request.title),
                category=request.category,
                amount=request.amount,
                paid_from_drawer=request.paid_from_drawer,
                note=request.note,
                client_request_id=request.client_request_id,
                device_id=device_id,
                user_id=actor_id,
                status=ExpenseStatus.POSTED.value,
            )
            self.repo.create(expense)
            title_text = expense.title or "untitled"
            self._audit(
                AuditAction.CREATE,
                entity_id=expense.id,
                actor_id=actor_id,
                details=(
                    f"created expense '{title_text}' "
                    f"[{expense.category}] {to_decimal(expense.amount)} "
                    f"{'drawer' if expense.paid_from_drawer else 'external'}"
                ),
            )
            return expense.id

    # ------------------------------------------------------------------
    # Cancel
    # ------------------------------------------------------------------

    def cancel(
        self,
        expense_id: uuid.UUID,
        request: ExpenseCancelRequest,
        *,
        user=None,
    ) -> ExpenseResponse:
        """posted → cancelled. Terminal, reason mandatory, row retained.

        The status guard runs as one UPDATE (GATE 11): a concurrent second
        cancellation loses the race and gets 409 EXPENSE_ALREADY_CANCELLED.
        """
        actor_id = user.id if user is not None else None

        expense = self.repo.get_by_id(expense_id)
        if expense is None:
            raise NotFoundError(
                message="Expense not found",
                code="EXPENSE_NOT_FOUND",
                details={"expense_id": str(expense_id)},
            )
        if expense.status != ExpenseStatus.POSTED.value:
            raise self._already_cancelled(expense_id, expense.status)

        with self.transaction():
            updated = self.repo.cancel(
                expense_id,
                reason=request.reason,
                cancelled_by=actor_id,
                cancelled_at=datetime.now(timezone.utc),
            )
            if not updated:
                raise self._already_cancelled(expense_id, None)
            self._audit(
                AuditAction.VOID,
                entity_id=expense_id,
                actor_id=actor_id,
                details=f"cancelled expense: {request.reason}",
            )

        # The Core UPDATE bypassed the identity map — refresh the row.
        self.db.expire_all()
        cancelled = self.repo.get_by_id(expense_id)
        if cancelled is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Expense cancelled but could not be re-read",
                details={"expense_id": str(expense_id)},
            )
        logger.info(
            "expense_cancelled",
            expense_id=str(cancelled.id),
            actor_id=str(actor_id) if actor_id else None,
            reason=request.reason,
        )
        return to_response(cancelled)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _already_cancelled(
        expense_id: uuid.UUID, status: str | None
    ) -> ConflictError:
        details: dict = {"expense_id": str(expense_id)}
        if status is not None:
            details["status"] = status
        return ConflictError(
            message="Expense is already cancelled",
            code="EXPENSE_ALREADY_CANCELLED",
            details=details,
        )

    @staticmethod
    def _validate_filters(
        date_from: date | None,
        date_to: date | None,
        status: str | None,
    ) -> None:
        if status is not None and status not in VALID_STATUSES:
            raise ValidationError(
                message="status must be one of: posted, cancelled, all",
                details={"status": status},
            )
        if date_from is not None and date_to is not None and date_from > date_to:
            raise ValidationError(
                message="date_from must not be after date_to",
                details={
                    "date_from": date_from.isoformat(),
                    "date_to": date_to.isoformat(),
                },
            )

    @staticmethod
    def _money_key(value) -> str:
        """Canonical money text for idempotency comparison.

        The request carries ``Decimal('100')`` while the persisted
        ``NUMERIC(18,3)`` value comes back as ``Decimal('100.000')``;
        normalizing the exponent makes the comparison numeric (Phase 12
        `_qty_key` precedent).
        """
        return format(to_decimal(value).normalize(), "f")

    @classmethod
    def _request_signature(cls, request: ExpenseCreateRequest) -> tuple:
        return (
            _normalize_title(request.title),
            request.category,
            cls._money_key(request.amount),
            bool(request.paid_from_drawer),
        )

    @classmethod
    def _document_signature(cls, expense: Expense) -> tuple:
        return (
            _normalize_title(expense.title),
            expense.category,
            cls._money_key(expense.amount),
            bool(expense.paid_from_drawer),
        )

    @classmethod
    def _assert_same_payload(
        cls, existing: Expense, request: ExpenseCreateRequest
    ) -> None:
        if cls._document_signature(existing) != cls._request_signature(request):
            raise ConflictError(
                message=(
                    "client_request_id was already used with a different "
                    "expense payload"
                ),
                code="IDEMPOTENCY_CONFLICT",
                details={
                    "client_request_id": request.client_request_id,
                    "expense_id": str(existing.id),
                },
            )

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction (§12)."""
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="expense",
                entity_id=entity_id,
                details=details,
            )
        )


def to_response(
    expense: Expense, *, idempotent_replay: bool = False
) -> ExpenseResponse:
    """Map an ORM expense to its API shape (money stays Decimal)."""
    return ExpenseResponse(
        id=expense.id,
        title=expense.title,
        category=expense.category,
        amount=to_decimal(expense.amount),
        paid_from_drawer=bool(expense.paid_from_drawer),
        note=expense.note,
        status=expense.status,
        user_id=expense.user_id,
        device_id=expense.device_id,
        client_request_id=expense.client_request_id,
        expense_date=expense.expense_date,
        cancelled_at=expense.cancelled_at,
        cancelled_by=expense.cancelled_by,
        cancel_reason=expense.cancel_reason,
        created_at=expense.created_at,
        updated_at=expense.updated_at,
        idempotent_replay=idempotent_replay,
    )
