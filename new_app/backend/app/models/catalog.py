"""Catalog models: categories, products, variants, selling units, packs.

Tables: categories, products, product_variants, product_selling_units,
packs, pack_items
"""

import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import Boolean, Date, ForeignKey, Numeric, String, UniqueConstraint
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
        # On-demand only: category list uses list_with_counts (subquery);
        # product list must not reverse-load every product in the category.
        lazy="noload",
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
    # Phase 7: authoritative moving weighted average cost (PMP).
    # products.cost stays nominal / last-purchase reference cost.
    avg_cost: Mapped[float] = numeric_money()
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
    # category stays selectin so GET /products resolves category_name
    # without N+1. Child collections are noload: catalog list must NOT
    # select all variants/selling units/pack lines for every product.
    # Explicit endpoints load them via repositories (variants / selling-units).
    category: Mapped["Category | None"] = relationship(
        "Category",
        back_populates="products",
        lazy="selectin",
    )
    variants: Mapped[list["ProductVariant"]] = relationship(
        "ProductVariant",
        back_populates="product",
        cascade="all, delete-orphan",
        lazy="noload",
    )
    selling_units: Mapped[list["ProductSellingUnit"]] = relationship(
        "ProductSellingUnit",
        back_populates="product",
        cascade="all, delete-orphan",
        lazy="noload",
    )
    purchase_units: Mapped[list["ProductPurchaseUnit"]] = relationship(
        "ProductPurchaseUnit",
        back_populates="product",
        cascade="all, delete-orphan",
        lazy="noload",
    )
    stock_packages: Mapped[list["ProductStockPackage"]] = relationship(
        "ProductStockPackage",
        back_populates="product",
        cascade="all, delete-orphan",
        lazy="noload",
    )
    pack_items_as_component: Mapped[list["PackItem"]] = relationship(
        "PackItem",
        back_populates="component_product",
        lazy="noload",
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
    price: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 3), nullable=True, default=None, server_default=None,
    )
    cost: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 3), nullable=True, default=None, server_default=None,
    )
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


class ProductSellingUnit(MasterModel):
    """Commercial selling unit for a product (Phase 6).

    One product may be sold in multiple selling forms simultaneously
    (e.g. piece ×1 and box ×24) sharing a single base stock quantity.
    Selling units live at PRODUCT level — variants inherit them
    (legacy: product unit is the only unit; variants have no unit field).

    multiplier = how many base units equal 1 selling unit.
    is_base_unit marks the authoritative base form (multiplier must be 1).
    Prices are independent rows — never derived from multiplier × base price.
    """

    __tablename__ = "product_selling_units"

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    unit_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=ProductUnit.PIECE.value,
        server_default=ProductUnit.PIECE.value,
    )
    multiplier: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=Decimal("1"), server_default="1",
    )
    barcode: Mapped[str | None] = mapped_column(String(50), unique=True, index=True)
    # NULL means inherit product.price — never coerce to 0 (0 is a valid free price).
    selling_price: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 3), nullable=True, default=None, server_default=None,
    )
    is_base_unit: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false",
    )

    # Relationships
    product: Mapped["Product"] = relationship(
        "Product",
        back_populates="selling_units",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("product_id", "name", name="uq_selling_unit_product_name"),
    )


class ProductPurchaseUnit(MasterModel):
    """Purchase packaging unit for a product (Phase 6 correction).

    Separate from selling units: used on supplier purchase documents.
    Example: Box ×24 means 1 purchased Box = 24 base Pieces.
    Document quantity stays in this unit (10 Box stays 10 Box).
    No selling_price — commercial price lives on selling units.
    """

    __tablename__ = "product_purchase_units"

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    unit_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=ProductUnit.PIECE.value,
        server_default=ProductUnit.PIECE.value,
    )
    multiplier: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=Decimal("1"), server_default="1",
    )
    barcode: Mapped[str | None] = mapped_column(String(50), unique=True, index=True)
    is_default: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false",
    )

    product: Mapped["Product"] = relationship(
        "Product",
        back_populates="purchase_units",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("product_id", "name", name="uq_purchase_unit_product_name"),
    )


class ProductStockPackage(MasterModel):
    """Sealed full-package stock per product + purchase unit (Phase 6).

    Aggregated packaging state (Option A generalized to multi sizes):
    full_packages of Box/Carton/… live here; loose base is derived as
    product.quantity − Σ(full × multiplier). Never store only a decimal
    fraction of a box as the physical package state.
    """

    __tablename__ = "product_stock_packages"

    product_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    purchase_unit_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("product_purchase_units.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    full_packages: Mapped[Decimal] = numeric_quantity(default=0, server_default="0")

    product: Mapped["Product"] = relationship(
        "Product",
        back_populates="stock_packages",
        lazy="noload",
    )
    purchase_unit: Mapped["ProductPurchaseUnit"] = relationship(
        "ProductPurchaseUnit",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint(
            "product_id", "purchase_unit_id", name="uq_stock_package_product_unit"
        ),
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
    """Component line of a pack.

    ``quantity`` always means BASE units consumed by one pack (GATE 2) —
    the column semantics are unchanged from the original Phase 10 schema so
    every pre-existing row keeps its meaning and every stock query keeps
    working without a data migration.

    Selling-unit support (Phase 10 UX/domain fix round) is additive:
    - ``selling_unit_id``  identity of the unit the user picked (NULL =
      product base unit — legacy rows and base-unit components),
    - ``selling_unit_name`` / ``selling_unit_multiplier`` snapshots taken
      when the pack was defined, so later renames or multiplier changes on
      the product's selling units can never silently rewrite how an
      existing pack reads (``2 Box`` keeps meaning ``48 Piece``).

    ``quantity`` itself is also pinned at definition time, so the base
    stock a pack consumes is stable regardless of catalog edits.
    """

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
    # Phase 10 fix round — selected selling unit (nullable, additive).
    selling_unit_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("product_selling_units.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    selling_unit_name: Mapped[str | None] = mapped_column(
        String(50), nullable=True, default=None, server_default=None,
    )
    selling_unit_multiplier: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 3), nullable=True, default=None, server_default=None,
    )

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
    # Snapshot columns stay authoritative for display; this link is only
    # for referential integrity / future catalog navigation.
    component_selling_unit: Mapped["ProductSellingUnit | None"] = relationship(
        "ProductSellingUnit",
        lazy="selectin",
    )

    __table_args__ = (
        UniqueConstraint("pack_id", "product_id", "variant_id", name="uq_pack_item_component"),
    )
