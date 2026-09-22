"""Catalog models: categories, products, variants, packs, pack items.

Tables: categories, products, product_variants, packs, pack_items
"""

import uuid
from datetime import date

from sqlalchemy import Boolean, Date, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import (
    Base,
    MasterModel,
    TimestampMixin,
    UUIDMixin,
    numeric_money,
    numeric_quantity,
    text_column,
)
from app.models.enums import ProductUnit


class Category(MasterModel):
    """Product grouping (hierarchical via parent_id)."""

    __tablename__ = "categories"

    name: Mapped[str] = mapped_column(String(100), nullable=False, unique=True)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("categories.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    sort_order: Mapped[int] = mapped_column(default=0, server_default="0")

    # Relationships
    parent: Mapped["Category | None"] = relationship(
        "Category",
        remote_side="Category.id",
        back_populates="children",
        lazy="selectin",
    )
    children: Mapped[list["Category"]] = relationship(
        "Category",
        back_populates="parent",
        lazy="selectin",
    )
    products: Mapped[list["Product"]] = relationship(
        "Product",
        back_populates="category",
        lazy="selectin",
    )


class Product(MasterModel):
    """Core product catalogue entry."""

    __tablename__ = "products"

    name: Mapped[str] = mapped_column(String(200), nullable=False)
    barcode: Mapped[str | None] = mapped_column(String(50), unique=True, index=True)
    sku: Mapped[str | None] = mapped_column(String(50), index=True)
    description: Mapped[str | None] = text_column()
    unit: Mapped[str] = mapped_column(
        String(20), nullable=False, default=ProductUnit.PIECE.value,
        server_default=ProductUnit.PIECE.value,
    )
    price: Mapped[float] = numeric_money()
    cost: Mapped[float] = numeric_money()
    quantity: Mapped[float] = numeric_quantity()
    low_stock_threshold: Mapped[float] = numeric_quantity(default=5, server_default="5")
    allow_negative_stock: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false",
    )
    expiry_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    image_path: Mapped[str | None] = mapped_column(String(500))
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("categories.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )

    # Relationships
    category: Mapped["Category | None"] = relationship(
        "Category",
        back_populates="products",
        lazy="selectin",
    )
    variants: Mapped[list["ProductVariant"]] = relationship(
        "ProductVariant",
        back_populates="product",
        cascade="all, delete-orphan",
        lazy="selectin",
    )
    pack_items_as_component: Mapped[list["PackItem"]] = relationship(
        "PackItem",
        back_populates="component_product",
        lazy="selectin",
    )


class ProductVariant(MasterModel):
    """Stock/price variant of a product (e.g. size, color)."""

    __tablename__ = "product_variants"

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    barcode: Mapped[str | None] = mapped_column(String(50), unique=True, index=True)
    sku: Mapped[str | None] = mapped_column(String(50))
    price: Mapped[float | None] = numeric_money(nullable=True)
    cost: Mapped[float | None] = numeric_money(nullable=True)
    quantity: Mapped[float] = numeric_quantity(default=0)

    # Relationships
    product: Mapped["Product"] = relationship(
        "Product",
        back_populates="variants",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("product_id", "name", name="uq_variant_product_name"),
    )


class Pack(MasterModel):
    """Bundle definition: a pack is saleable as a single product."""

    __tablename__ = "packs"

    name: Mapped[str] = mapped_column(String(200), nullable=False)
    barcode: Mapped[str | None] = mapped_column(String(50), unique=True, index=True)
    price: Mapped[float] = numeric_money()
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true",
    )
    image_path: Mapped[str | None] = mapped_column(String(500))

    # Relationships
    pack_items: Mapped[list["PackItem"]] = relationship(
        "PackItem",
        back_populates="pack",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class PackItem(Base, UUIDMixin, TimestampMixin):
    """Component line of a pack."""

    __tablename__ = "pack_items"

    pack_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("packs.id", ondelete="CASCADE"),
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
    quantity: Mapped[float] = numeric_quantity(default=1, server_default="1")

    # Relationships
    pack: Mapped["Pack"] = relationship(
        "Pack",
        back_populates="pack_items",
        lazy="selectin",
    )
    component_product: Mapped["Product"] = relationship(
        "Product",
        back_populates="pack_items_as_component",
        lazy="selectin",
    )
    component_variant: Mapped["ProductVariant | None"] = relationship(
        "ProductVariant",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("pack_id", "product_id", "variant_id", name="uq_pack_item_component"),
    )
