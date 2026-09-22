"""Return models: returns, return lines.

Tables: returns, return_lines

Design principles:
- Linked to source sale when possible (returns can be independent too).
- Lines snapshot product info at time of return.
- Return quantity ≤ unreturned sold quantity.
- Reason and authorization required.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, DocumentModel, TimestampMixin, UUIDMixin, numeric_money, numeric_quantity
from app.models.enums import ReturnReason


class Return(DocumentModel):
    """Return header — linked to a sale or independent."""

    __tablename__ = "returns"

    return_number: Mapped[str] = mapped_column(String(50), nullable=False, unique=True, index=True)
    sale_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sales.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("customers.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    reason: Mapped[str] = mapped_column(
        String(30), nullable=False, default=ReturnReason.OTHER.value,
        server_default=ReturnReason.OTHER.value,
    )
    total: Mapped[float] = numeric_money()
    note: Mapped[str | None] = mapped_column(Text)
    device_id: Mapped[str | None] = mapped_column(String(100))
    return_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    sale: Mapped["Sale | None"] = relationship(  # noqa: F821
        "Sale",
        lazy="selectin",
    )
    customer: Mapped["Customer | None"] = relationship(  # noqa: F821
        "Customer",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
    lines: Mapped[list["ReturnLine"]] = relationship(
        "ReturnLine",
        back_populates="return_doc",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class ReturnLine(Base, UUIDMixin, TimestampMixin):
    """Return line item with product snapshot."""

    __tablename__ = "return_lines"

    return_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("returns.id", ondelete="RESTRICT"),
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
    )
    sale_line_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sale_lines.id", ondelete="RESTRICT"),
        nullable=True,
    )

    # Snapshot fields
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    product_sku: Mapped[str | None] = mapped_column(String(50))
    product_barcode: Mapped[str | None] = mapped_column(String(50))
    product_unit: Mapped[str] = mapped_column(String(20), nullable=False)
    unit_price: Mapped[float] = numeric_money()
    quantity: Mapped[float] = numeric_quantity()
    line_total: Mapped[float] = numeric_money()

    # Relationships
    return_doc: Mapped["Return"] = relationship(
        "Return",
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
    sale_line: Mapped["SaleLine | None"] = relationship(  # noqa: F821
        "SaleLine",
        lazy="selectin",
    )
