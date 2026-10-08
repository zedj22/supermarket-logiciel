"""Promotion models (Phase 18 promotion system).

Tables: promotions, promotion_products

- ``promotions``      one promotion rule (name, type, value, active flag)
- ``promotion_products`` the product membership of a promotion (bulk apply
  targets a whole set of products in ONE transactional request)

Hard rules (Phase 18):
- ``value`` is NUMERIC(18,3): a percent OFF for ``percentage`` promotions
  (0 < value <= 100) or a replacement retail unit price for
  ``fixed_price`` promotions (value >= 0). Money is never a float.
- ``products.price`` is NEVER written by a promotion: the discount is
  computed at price-resolution time and the original retail price stays
  intact (deactivation restores it instantly).
- At most ONE ACTIVE promotion may contain a given product; multiple
  inactive promotions may target the same product. The rule is enforced
  in the service inside the same transaction (row locks + check) because
  a partial unique index cannot span two tables portably (SQLite vs PG).
- ``is_active`` is the only scheduling concept — there are no start/end
  dates (no scheduling convention exists in this codebase).
"""

import uuid

from sqlalchemy import (
    Boolean,
    ForeignKey,
    Index,
    Numeric,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin
from app.models.enums import PromotionType


class Promotion(Base, UUIDMixin, TimestampMixin):
    """One promotion rule."""

    __tablename__ = "promotions"

    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    promotion_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=PromotionType.PERCENTAGE.value,
        server_default=PromotionType.PERCENTAGE.value,
    )
    # percent OFF (percentage) or replacement unit price (fixed_price)
    value: Mapped[float] = mapped_column(Numeric(18, 3), nullable=False)
    is_active: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default="true",
    )
    # Idempotency key — required on create, unique when present (the
    # expenses Phase 13 pattern: NULL never collides).
    client_request_id: Mapped[str | None] = mapped_column(String(100))
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    __table_args__ = (
        Index(
            "ux_promotions_client_request_id",
            "client_request_id",
            unique=True,
            postgresql_where=text("client_request_id IS NOT NULL"),
        ),
    )

    products: Mapped[list["PromotionProduct"]] = relationship(  # noqa: F821
        "PromotionProduct",
        back_populates="promotion",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class PromotionProduct(Base, UUIDMixin, TimestampMixin):
    """Membership row: one product inside one promotion."""

    __tablename__ = "promotion_products"

    promotion_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("promotions.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    __table_args__ = (
        UniqueConstraint(
            "promotion_id",
            "product_id",
            name="uq_promotion_products_promotion_product",
        ),
    )

    promotion: Mapped["Promotion"] = relationship(  # noqa: F821
        "Promotion",
        back_populates="products",
    )
