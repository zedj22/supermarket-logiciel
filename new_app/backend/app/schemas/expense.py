"""Expense schemas (Phase 13).

Money fields are Decimal — never float (Phase 0 money rule; legacy used
DOUBLE — discrepancy D3). JSON serialization emits decimal strings and
Flutter parses money as strings.

Business rules encoded here (decision record §7):
- B1 title OPTIONAL (Fix Round 2): omitted / null / blank / whitespace →
  stored as NULL; a supplied title is trimmed, max 200, never defaulted
- B2 category required, ExpenseCategory code only
- B3 amount Decimal, > 0, <= MONEY_MAX
- B4 paid_from_drawer defaults true (legacy default 1)
- B5 note optional, <= 2000
- B10 cancel reason required, trimmed, 1..200, blank rejected

``client_request_id`` is REQUIRED on create (GATE 10) — the server
assigns id / expense_date / user_id / status, so none of them are ever
accepted from the client (B6/B7).
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field, field_validator

from app.schemas.common import StrictBaseModel

MONEY_MAX = Decimal("999999999999.999")


class ExpenseCreateRequest(StrictBaseModel):
    """POST /api/v1/expenses.

    ``client_request_id`` is required: a repeat with the same key and the
    same payload returns the original expense with
    ``idempotent_replay=true``; a repeat with a different payload is
    409 IDEMPOTENCY_CONFLICT.
    """

    client_request_id: str = Field(..., min_length=1, max_length=100)
    title: str | None = Field(default=None, max_length=200)
    category: str = Field(..., min_length=1, max_length=30)
    amount: Decimal = Field(..., gt=0, le=MONEY_MAX)
    paid_from_drawer: bool = True
    note: str | None = Field(default=None, max_length=2000)

    @field_validator("client_request_id")
    @classmethod
    def _non_blank_request_id(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("client_request_id must not be blank")
        return stripped

    @field_validator("title")
    @classmethod
    def _blank_title_is_none(cls, v: str | None) -> str | None:
        """B1 (Fix Round 2): title is optional.

        ``None`` stays ``None``, blank / whitespace-only becomes ``None``
        (NULL in the database), a supplied value is trimmed. No fake
        default title is ever invented; ``max_length=200`` still rejects
        an over-long supplied title with 422.
        """
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None

    @field_validator("category")
    @classmethod
    def _known_category(cls, v: str) -> str:
        from app.models.enums import ExpenseCategory

        stripped = v.strip()
        try:
            ExpenseCategory(stripped)
        except ValueError:
            allowed = ", ".join(c.value for c in ExpenseCategory)
            raise ValueError(f"category must be one of: {allowed}") from None
        return stripped

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, v: str | None) -> str | None:
        if v is None:
            return None
        stripped = v.strip()
        return stripped or None


class ExpenseCancelRequest(StrictBaseModel):
    """POST /api/v1/expenses/{id}/cancel — reason is mandatory (§7 B10).

    Blank after strip → 422, mirroring the Phase 12 void reason rule.
    """

    reason: str = Field(..., min_length=1, max_length=200)

    @field_validator("reason")
    @classmethod
    def _non_blank_reason(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("reason must not be blank")
        return stripped


class ExpenseResponse(StrictBaseModel):
    """One expense as returned by the API.

    ``idempotent_replay`` is only meaningful on the create response.
    """

    id: uuid.UUID
    title: str | None = None
    category: str
    amount: Decimal
    paid_from_drawer: bool
    note: str | None = None
    status: str
    user_id: uuid.UUID | None = None
    device_id: str | None = None
    client_request_id: str | None = None
    expense_date: datetime
    cancelled_at: datetime | None = None
    cancelled_by: uuid.UUID | None = None
    cancel_reason: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    idempotent_replay: bool = False


class ExpenseSummaryResponse(StrictBaseModel):
    """GET /api/v1/expenses/summary — legacy list metrics (W2).

    Cancelled rows are excluded (B11); ``drawer_amount`` + ``external_amount``
    always add up to ``total_amount``.
    """

    count: int
    total_amount: Decimal
    drawer_amount: Decimal
    external_amount: Decimal
