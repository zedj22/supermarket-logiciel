"""Sales models: sales, sale lines, sale payments.

Tables: sales, sale_lines, sale_payments

Design principles:
- All lines snapshot product name/SKU/unit/price/cost at time of sale.
- Payment is tracked separately to support split/cash/card/credit.
- Historical records are append-only; void uses compensating entries.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, DocumentModel, TimestampMixin, UUIDMixin, numeric_money, numeric_quantity
from app.models.enums import PaymentMethod, SaleStatus


class Sale(DocumentModel):
    """Sale invoice header."""

    __tablename__ = "sales"

    invoice_number: Mapped[str] = mapped_column(String(50), nullable=False, unique=True, index=True)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("customers.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=SaleStatus.COMPLETED.value,
        server_default=SaleStatus.COMPLETED.value,
    )
    subtotal: Mapped[float] = numeric_money()
    discount: Mapped[float] = numeric_money(default=0, server_default="0")
    total: Mapped[float] = numeric_money()
    paid: Mapped[float] = numeric_money(default=0, server_default="0")
    change: Mapped[float] = numeric_money(default=0, server_default="0")
    payment_method: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PaymentMethod.CASH.value,
        server_default=PaymentMethod.CASH.value,
    )
    # Phase 8 idempotency: client-supplied key; unique when present.
    # Repeated checkout with the same key returns the original sale.
    client_request_id: Mapped[str | None] = mapped_column(
        String(100), unique=True, index=True, nullable=True,
    )
    note: Mapped[str | None] = mapped_column(Text)
    device_id: Mapped[str | None] = mapped_column(String(100))
    sale_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    customer: Mapped["Customer | None"] = relationship(  # noqa: F821
        "Customer",
        back_populates="sales",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
    lines: Mapped[list["SaleLine"]] = relationship(
        "SaleLine",
        back_populates="sale",
        cascade="all, delete-orphan",
        lazy="selectin",
    )
    payments: Mapped[list["SalePayment"]] = relationship(
        "SalePayment",
        back_populates="sale",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class SaleLine(Base, UUIDMixin, TimestampMixin):
    """Sale line item with product snapshot at time of sale."""

    __tablename__ = "sale_lines"

    sale_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("sales.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    variant_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_variants.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    pack_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("packs.id", ondelete="RESTRICT"),
        nullable=True,
    )

    # Snapshot fields (preserved even if product changes)
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    product_sku: Mapped[str | None] = mapped_column(String(50))
    product_barcode: Mapped[str | None] = mapped_column(String(50))
    product_unit: Mapped[str] = mapped_column(String(20), nullable=False)
    # Phase 8 UX FIX #11 — historical display snapshots for variant /
    # selling unit. Nullable (base-unit sales have neither) and never
    # FK-linked: the values must survive renames, multiplier changes and
    # catalog archives. product_unit above stays the base-unit snapshot.
    variant_name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    selling_unit_name: Mapped[str | None] = mapped_column(String(50), nullable=True)
    selling_unit_multiplier: Mapped[float | None] = mapped_column(
        Numeric(18, 3), nullable=True
    )
    unit_price: Mapped[float] = numeric_money()
    unit_cost: Mapped[float] = numeric_money()
    quantity: Mapped[float] = numeric_quantity()
    line_discount: Mapped[float] = numeric_money(default=0, server_default="0")
    line_total: Mapped[float] = numeric_money()

    # Relationships
    sale: Mapped["Sale"] = relationship(
        "Sale",
        back_populates="lines",
        lazy="selectin",
    )
    product: Mapped["Product"] = relationship(  # noqa: F821
        "Product",
        lazy="selectin",
    )
    variant: Mapped["ProductVariant | None"] = relationship(  # noqa: F821
        "ProductVariant",
        lazy="selectin",
    )


class SalePayment(Base, UUIDMixin, TimestampMixin):
    """Individual payment against a sale (cash, card, credit)."""

    __tablename__ = "sale_payments"

    sale_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("sales.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    method: Mapped[str] = mapped_column(
        String(20), nullable=False, default=PaymentMethod.CASH.value,
    )
    amount: Mapped[float] = numeric_money()
    reference: Mapped[str | None] = mapped_column(String(100))
    payment_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    sale: Mapped["Sale"] = relationship(
        "Sale",
        back_populates="payments",
        lazy="selectin",
    )
