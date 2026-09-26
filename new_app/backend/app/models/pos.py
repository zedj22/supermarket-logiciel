"""POS models: server-side holds and manual favorites (Phase 8).

Tables: pos_holds, product_favorites

Design principles:
- Holds are cart snapshots only — they NEVER reserve stock.
- Favorites are minimal manual pins (no auto-ranking analytics).
"""

from __future__ import annotations

import uuid

from sqlalchemy import JSON, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money


class PosHold(Base, UUIDMixin, TimestampMixin):
    """Server-side hold (parked sale) — snapshot only, no stock reserve."""

    __tablename__ = "pos_holds"

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    device_id: Mapped[str | None] = mapped_column(String(100), index=True)
    customer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("customers.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # JSON snapshot: {"items": [...], "invoice_discount": "...", ...}
    cart_snapshot: Mapped[dict] = mapped_column(JSON, nullable=False)
    invoice_discount: Mapped[float] = numeric_money(default=0, server_default="0")
    note: Mapped[str | None] = mapped_column(Text)

    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
    customer: Mapped["Customer | None"] = relationship(  # noqa: F821
        "Customer",
        lazy="selectin",
    )


class ProductFavorite(Base, UUIDMixin, TimestampMixin):
    """Manual product favorite pin for the POS favorites strip."""

    __tablename__ = "product_favorites"

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    product: Mapped["Product"] = relationship(  # noqa: F821
        "Product",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("product_id", "user_id", name="uq_product_favorite_user"),
    )
