"""Zakat snapshot models: ``zakat_calculations`` + ``zakat_payments``.

A calculation is an *immutable* snapshot: the exact inputs the operator
entered (``inputs`` JSON), the values the engine computed, and the
warnings it raised.  Corrections are made by saving a new calculation —
old snapshots are never edited, so history stays auditable.

Payments are a separate append-only record tied to one calculation; a
calculation without payments is simply an unpaid (or partially unpaid)
snapshot.  Nothing here touches sales, inventory, accounting or POS
data — the zakat feature is read-only with respect to the rest of the
business.

Design mirrors the loyalty/debt conventions (UUID PK, timestamps, JSON
where the shape is engine-owned, NUMERIC(18,3) money, CHECK
constraints on every constrained column).
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import (
    JSON,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money

#: Payment methods accepted by the zakat payment endpoint.
ZAKAT_PAYMENT_METHODS = ("cash", "transfer", "cheque", "other")
_PAYMENT_METHOD_CHECK_SQL = "method IN (%s)" % ", ".join(
    f"'{method}'" for method in ZAKAT_PAYMENT_METHODS
)


def _nullable_money():
    """NUMERIC(18,3) column with no server default (value may be unknown)."""
    return numeric_money(nullable=True, default=None, server_default=None)


class ZakatCalculation(Base, UUIDMixin, TimestampMixin):
    """One saved zakat calculation snapshot."""

    __tablename__ = "zakat_calculations"
    __table_args__ = (
        Index("ix_zakat_calculations_created_at", "created_at"),
        CheckConstraint(
            "zakat_rate >= 0", name="ck_zakat_calculations_zakat_rate"
        ),
        CheckConstraint(
            "status IN ('final', 'provisional')",
            name="ck_zakat_calculations_status",
        ),
        CheckConstraint(
            "inventory_basis IN ('market', 'cost', 'override')",
            name="ck_zakat_calculations_inventory_basis",
        ),
        CheckConstraint(
            "debt_treatment IN ('deduct_all', 'deduct_due_only', 'no_deduction')",
            name="ck_zakat_calculations_debt_treatment",
        ),
    )

    # -- dates / hawl -------------------------------------------------
    zakat_date: Mapped[date] = mapped_column(Date, nullable=False)
    hawl_start_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    hawl_days_elapsed: Mapped[int | None] = mapped_column(nullable=True)
    hawl_completed: Mapped[bool | None] = mapped_column(nullable=True)

    # -- nisab --------------------------------------------------------
    gold_price_per_gram: Mapped[Decimal | None] = _nullable_money()
    nisab_amount: Mapped[Decimal | None] = _nullable_money()
    nisab_source: Mapped[str | None] = mapped_column(String(20), nullable=True)

    # -- inventory ----------------------------------------------------
    inventory_basis: Mapped[str] = mapped_column(
        String(20), nullable=False, default="market", server_default="market"
    )
    inventory_value: Mapped[Decimal | None] = _nullable_money()
    inventory_override_reason: Mapped[str | None] = mapped_column(
        String(255), nullable=True
    )

    # -- cash / receivables -------------------------------------------
    cash_total: Mapped[Decimal | None] = _nullable_money()
    collectible_receivables: Mapped[Decimal | None] = _nullable_money()
    doubtful_receivables: Mapped[Decimal | None] = _nullable_money()
    other_receivables_total: Mapped[Decimal] = numeric_money()
    receivables_included_total: Mapped[Decimal | None] = _nullable_money()

    # -- liabilities ---------------------------------------------------
    debt_treatment: Mapped[str] = mapped_column(
        String(20), nullable=False, default="deduct_all", server_default="deduct_all"
    )
    liabilities_total_entered: Mapped[Decimal] = numeric_money()
    deductions_applied: Mapped[Decimal] = numeric_money()

    # -- result ---------------------------------------------------------
    net_zakatable: Mapped[Decimal] = numeric_money()
    zakat_rate: Mapped[Decimal] = numeric_money(
        default=Decimal("0.025"), server_default="0.025"
    )
    zakat_due: Mapped[Decimal | None] = _nullable_money()
    provisional_zakat_due: Mapped[Decimal | None] = _nullable_money()
    reaches_nisab: Mapped[bool | None] = mapped_column(nullable=True)
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default="provisional", server_default="provisional"
    )

    # -- engine output + reproducible inputs ---------------------------
    warnings: Mapped[list] = mapped_column(JSON, nullable=False, default=list)
    missing_fields: Mapped[list] = mapped_column(JSON, nullable=False, default=list)
    #: Full engine result on the wire (queryable columns above are the
    #: denormalized subset the list/history filters use).
    result: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)
    inputs: Mapped[dict] = mapped_column(JSON, nullable=False, default=dict)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    # -- provenance -----------------------------------------------------
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True
    )
    client_request_id: Mapped[str] = mapped_column(
        String(120), nullable=False, unique=True, index=True
    )

    payments: Mapped[list["ZakatPayment"]] = relationship(
        "ZakatPayment",
        back_populates="calculation",
        lazy="selectin",
        order_by="ZakatPayment.paid_at",
    )


class ZakatPayment(Base, UUIDMixin, TimestampMixin):
    """One actual payment recorded against a saved calculation."""

    __tablename__ = "zakat_payments"
    __table_args__ = (
        CheckConstraint("amount > 0", name="ck_zakat_payments_amount"),
        CheckConstraint(_PAYMENT_METHOD_CHECK_SQL, name="ck_zakat_payments_method"),
        Index("ix_zakat_payments_calculation_id", "calculation_id"),
    )

    calculation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("zakat_calculations.id", ondelete="CASCADE"), nullable=False
    )
    amount: Mapped[Decimal] = numeric_money()
    method: Mapped[str] = mapped_column(
        String(20), nullable=False, default="cash", server_default="cash"
    )
    paid_at: Mapped[date] = mapped_column(Date, nullable=False)
    note: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    client_request_id: Mapped[str] = mapped_column(
        String(120), nullable=False, unique=True, index=True
    )

    calculation: Mapped[ZakatCalculation] = relationship(
        "ZakatCalculation", back_populates="payments"
    )
