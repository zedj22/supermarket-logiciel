"""Inventory model: inventory_movements.

Table: inventory_movements

Design principles:
- Immutable stock journal — every verified mutation is recorded.
- Captures direction, reason, source document, actor, device.
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_quantity


class InventoryMovement(Base, UUIDMixin, TimestampMixin):
    """Immutable stock movement journal entry."""

    __tablename__ = "inventory_movements"

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
    movement_type: Mapped[str] = mapped_column(
        String(30), nullable=False, index=True,
    )
    quantity_change: Mapped[float] = numeric_quantity()
    quantity_before: Mapped[float] = numeric_quantity()
    quantity_after: Mapped[float] = numeric_quantity()
    # Phase 6 packaging: document unit + package open/break bookkeeping.
    # quantity_* stay in BASE units; document_* preserve what was on paper.
    document_quantity: Mapped[float | None] = mapped_column(Numeric(18, 3), nullable=True)
    document_unit: Mapped[str | None] = mapped_column(String(50))
    purchase_unit_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_purchase_units.id", ondelete="RESTRICT"),
        nullable=True,
    )
    packages_change: Mapped[float | None] = mapped_column(Numeric(18, 3), nullable=True)
    reason: Mapped[str | None] = mapped_column(Text)
    source_document_type: Mapped[str | None] = mapped_column(String(30))
    source_document_id: Mapped[uuid.UUID | None] = mapped_column(index=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    device_id: Mapped[str | None] = mapped_column(String(100))
    movement_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # Relationships
    product: Mapped["Product"] = relationship(  # noqa: F821
        "Product",
        lazy="selectin",
    )
    variant: Mapped["ProductVariant | None"] = relationship(  # noqa: F821
        "ProductVariant",
        lazy="selectin",
    )
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
