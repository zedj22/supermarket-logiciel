"""Return models: returns, return lines.

Tables: returns, return_lines

Design principles:
- Linked to source sale when possible (returns can be independent too).
- Lines snapshot product info at time of return.
- Return quantity ≤ unreturned sold quantity.
- Authorization required (POS_RETURN + audit row); the reason is
  OPTIONAL (Phase 12 fix round 1) and persists as NULL when omitted.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, DocumentModel, TimestampMixin, UUIDMixin, numeric_money, numeric_quantity


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
    # Optional reason (Phase 12 fix round 1): NULL when the operator did
    # not supply one. The API validates the vocabulary only when a reason
    # IS supplied (see app.schemas.returns.ReturnCreateRequest).
    reason: Mapped[str | None] = mapped_column(String(30), nullable=True)
    total: Mapped[float] = numeric_money()
    # Phase 12: refund decomposition. total = subtotal - discount
    # (GATE 14 pro-rata refund + invoice-discount conservation).
    subtotal: Mapped[float] = numeric_money(default=0, server_default="0")
    discount: Mapped[float] = numeric_money(default=0, server_default="0")
    note: Mapped[str | None] = mapped_column(Text)
    device_id: Mapped[str | None] = mapped_column(String(100))
    # Phase 12 idempotency (GATE 16): replay key, unique when present.
    client_request_id: Mapped[str | None] = mapped_column(
        String(100), unique=True, index=True, nullable=True,
    )
    return_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
        index=True,
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
    # Phase 12: exactly one target applies per line, mirroring sale_lines
    # (decision record §5, GATE 11/12):
    #   product line   -> product_id set,  pack_id NULL  (restores variant only)
    #   pack summary   -> product_id NULL, pack_id set   (restores all pack components)
    # Independent returns set sale_line_id NULL (no source line to link).
    product_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("products.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    variant_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_variants.id", ondelete="RESTRICT"),
        nullable=True,
    )
    pack_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("packs.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    sale_line_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sale_lines.id", ondelete="RESTRICT"),
        nullable=True,
    )

    # Snapshot fields — copied from the historical sale line, never re-read
    # from the catalog (GATE 11-13). unit_cost feeds the RETURN movement's
    # value; line_discount feeds the pro-rata refund (GATE 14).
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    product_sku: Mapped[str | None] = mapped_column(String(50))
    product_barcode: Mapped[str | None] = mapped_column(String(50))
    product_unit: Mapped[str] = mapped_column(String(20), nullable=False)
    variant_name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    selling_unit_name: Mapped[str | None] = mapped_column(
        String(50), nullable=True
    )
    selling_unit_multiplier: Mapped[float | None] = mapped_column(
        Numeric(18, 3), nullable=True
    )
    unit_price: Mapped[float] = numeric_money()
    unit_cost: Mapped[float] = numeric_money(default=0, server_default="0")
    quantity: Mapped[float] = numeric_quantity()
    # Base units actually restored to stock (quantity x multiplier), NULL for
    # independent returns without a source line multiplier context.
    quantity_base: Mapped[float | None] = mapped_column(
        Numeric(18, 3), nullable=True
    )
    line_discount: Mapped[float] = numeric_money(default=0, server_default="0")
    line_total: Mapped[float] = numeric_money()

    # Relationships
    return_doc: Mapped["Return"] = relationship(
        "Return",
        back_populates="lines",
        lazy="selectin",
    )
    product: Mapped["Product | None"] = relationship(  # noqa: F821
        "Product",
        lazy="selectin",
    )
    pack: Mapped["Pack | None"] = relationship(  # noqa: F821
        "Pack",
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
