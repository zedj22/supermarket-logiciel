"""Expense model: expenses.

Table: expenses

Phase 13 (decision record §4/§5):
- ``status``            posted | cancelled — the whole lifecycle (GATE 1)
- ``paid_from_drawer``  classification flag, informational only (GATE 5)
- ``client_request_id`` idempotency key, unique when present (GATE 10)
- ``cancelled_at`` / ``cancelled_by`` / ``cancel_reason`` — cancellation
  attribution (never a delete: the row and its original amount stay).

Indexes: category (0002), expense_date + user_id + partial-unique
client_request_id (0018).
"""

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money
from app.models.enums import ExpenseStatus


class Expense(Base, UUIDMixin, TimestampMixin):
    """Store expense record."""

    __tablename__ = "expenses"

    __table_args__ = (
        # GATE 10 — the replay key is unique when it is present; NULL
        # (any pre-Phase-13 row) never collides.
        Index(
            "ux_expenses_client_request_id",
            "client_request_id",
            unique=True,
            postgresql_where=text("client_request_id IS NOT NULL"),
        ),
    )

    title: Mapped[str | None] = mapped_column(String(200), nullable=True)
    category: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    amount: Mapped[float] = numeric_money()
    note: Mapped[str | None] = mapped_column(Text)
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    device_id: Mapped[str | None] = mapped_column(String(100))
    # Server-assigned and immutable (GATE 6 — no client backdating).
    expense_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
        index=True,
    )

    # Phase 13 lifecycle (GATE 1). Server-assigned, never client-sent.
    status: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=ExpenseStatus.POSTED.value,
        server_default=ExpenseStatus.POSTED.value,
    )
    # GATE 5 — legacy parity flag (true = paid from the cash drawer).
    paid_from_drawer: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true",
    )
    # GATE 10 — required on every POST, replay-unique when present.
    client_request_id: Mapped[str | None] = mapped_column(String(100))

    # Cancellation attribution (GATE 6). The row is never deleted.
    cancelled_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True,
    )
    cancelled_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    cancel_reason: Mapped[str | None] = mapped_column(String(200))

    # Relationships (two FKs → users, so foreign_keys is mandatory)
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        foreign_keys=[user_id],
        lazy="selectin",
    )
