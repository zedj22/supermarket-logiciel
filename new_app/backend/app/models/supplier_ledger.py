"""Supplier ledger model: supplier_ledger_entries (Phase 11).

Table: supplier_ledger_entries

Design principles (mirrors debt_ledger_entries, Phase 9):
- Immutable append-only ledger entries.
- suppliers.balance is a cached projection, rebuilt/reconciled from
  entries; the ledger is authoritative.
- Entry types: purchase (payable incurred at receive), payment (payable
  reduced), purchase_cancel (payable reversed by a cancellation).
- Amounts are always stored positive; the sign is derived from
  entry_type (purchase +, payment -, purchase_cancel -).
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money


class SupplierLedgerEntry(Base, UUIDMixin, TimestampMixin):
    """Immutable ledger entry for supplier payables tracking."""

    __tablename__ = "supplier_ledger_entries"

    supplier_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("suppliers.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    entry_type: Mapped[str] = mapped_column(
        String(20), nullable=False, index=True,
    )
    amount: Mapped[float] = numeric_money()
    reference_purchase_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("purchases.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    note: Mapped[str | None] = mapped_column(Text)
    # Phase 11 idempotency: client-supplied key for payment commands;
    # unique when present (receive/cancel entries leave it NULL).
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
    supplier: Mapped["Supplier"] = relationship(  # noqa: F821
        "Supplier",
        back_populates="ledger_entries",
        lazy="selectin",
    )
    reference_purchase: Mapped["Purchase | None"] = relationship(  # noqa: F821
        "Purchase",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )

    __table_args__ = (
        # Ledger read path: one supplier's history, newest first (GATE 21).
        Index(
            "ix_supplier_ledger_entries_supplier_entry_date",
            "supplier_id",
            "entry_date",
        ),
        # Phase 14 §5.7 — supplier movement block over any date window,
        # across every supplier at once.
        Index(
            "ix_supplier_ledger_entries_entry_date",
            "entry_date",
        ),
    )
