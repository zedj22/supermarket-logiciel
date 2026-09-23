"""Purchase models: purchases, purchase lines.

Tables: purchases, purchase_lines

Design principles:
- Lines snapshot product name/SKU/unit/cost at time of purchase.
- Supplier balance increases by unpaid net.
- Deletion must reverse stock and supplier balance (service layer).
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, DocumentModel, TimestampMixin, UUIDMixin, numeric_money, numeric_quantity


class Purchase(DocumentModel):
    """Purchase invoice header."""

    __tablename__ = "purchases"

    invoice_number: Mapped[str] = mapped_column(String(50), nullable=False, unique=True, index=True)
    supplier_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("suppliers.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    subtotal: Mapped[float] = numeric_money()
    discount: Mapped[float] = numeric_money(default=0, server_default="0")
    total: Mapped[float] = numeric_money()
    paid: Mapped[float] = numeric_money(default=0, server_default="0")
    note: Mapped[str | None] = mapped_column(Text)
    device_id: Mapped[str | None] = mapped_column(String(100))
    purchase_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    supplier: Mapped["Supplier"] = relationship(  # noqa: F821
        "Supplier",
        back_populates="purchases",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
    lines: Mapped[list["PurchaseLine"]] = relationship(
        "PurchaseLine",
        back_populates="purchase",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class PurchaseLine(Base, UUIDMixin, TimestampMixin):
    """Purchase line item with product snapshot."""

    __tablename__ = "purchase_lines"

    purchase_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("purchases.id", ondelete="RESTRICT"),
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

    # Snapshot fields
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    product_sku: Mapped[str | None] = mapped_column(String(50))
    product_barcode: Mapped[str | None] = mapped_column(String(50))
    product_unit: Mapped[str] = mapped_column(String(20), nullable=False)
    unit_cost: Mapped[float] = numeric_money()
    quantity: Mapped[float] = numeric_quantity()
    line_total: Mapped[float] = numeric_money()
    # Phase 6 packaging: document unit may be Box ×24 while stock adds base.
    purchase_unit_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_purchase_units.id", ondelete="RESTRICT"),
        nullable=True,
    )
    purchase_unit_name: Mapped[str | None] = mapped_column(String(50))
    unit_multiplier: Mapped[float | None] = mapped_column(Numeric(18, 3), nullable=True)
    base_qty_equivalent: Mapped[float | None] = mapped_column(
        Numeric(18, 3), nullable=True
    )

    # Relationships
    purchase: Mapped["Purchase"] = relationship(
        "Purchase",
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
