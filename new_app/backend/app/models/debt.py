"""Debt ledger model: debt_ledger_entries.

Table: debt_ledger_entries

Design principles:
- Immutable append-only ledger entries.
- customer.balance is a cached projection, rebuilt/reconciled from entries.
- Entry types: sale (debt incurred), payment (debt reduced), adjustment.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money


class DebtLedgerEntry(Base, UUIDMixin, TimestampMixin):
    """Immutable ledger entry for customer debt tracking."""

    __tablename__ = "debt_ledger_entries"

    customer_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("customers.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    entry_type: Mapped[str] = mapped_column(
        String(20), nullable=False, index=True,
    )
    amount: Mapped[float] = numeric_money()
    reference_sale_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sales.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    note: Mapped[str | None] = mapped_column(Text)
    # Phase 9 idempotency: client-supplied key for payment commands;
    # unique when present (sale entries leave it NULL).
    client_request_id: Mapped[str | None] = mapped_column(
        String(100), unique=True, index=True, nullable=True,
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    entry_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    customer: Mapped["Customer"] = relationship(  # noqa: F821
        "Customer",
        back_populates="debt_entries",
        lazy="selectin",
    )
    reference_sale: Mapped["Sale | None"] = relationship(  # noqa: F821
        "Sale",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
