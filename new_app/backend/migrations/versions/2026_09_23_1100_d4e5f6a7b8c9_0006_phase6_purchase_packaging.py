"""0006_phase6_purchase_packaging

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-09-23

Architectural correction for Phase 6 purchase packaging / stock-breaking:
- product_purchase_units: purchase packaging units (Box ×24, …) — no selling price
- product_stock_packages: sealed full-package counts per product + purchase unit
- purchase_lines: document-unit columns (purchase_unit_id, unit_multiplier, base_qty_equivalent)
- inventory_movements: packaging columns (document_quantity, document_unit,
  purchase_unit_id, packages_change) + package_break/package_receive movement types
- products.quantity remains the canonical total base equivalent (loose = total − packed)
- Existing Phase 6 selling units (Piece ×1, Box ×24) are preserved — no data rewrite
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "d4e5f6a7b8c9"
down_revision = "c3d4e5f6a7b8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "product_purchase_units",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "product_id",
            sa.Uuid(),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("name", sa.String(50), nullable=False),
        sa.Column("unit_type", sa.String(20), nullable=False, server_default="piece"),
        sa.Column("multiplier", sa.Numeric(18, 3), nullable=False, server_default="1"),
        sa.Column("barcode", sa.String(50), nullable=True),
        sa.Column("is_default", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("product_id", "name", name="uq_purchase_unit_product_name"),
    )
    op.create_index("ix_product_purchase_units_id", "product_purchase_units", ["id"])
    op.create_index(
        "ix_product_purchase_units_barcode",
        "product_purchase_units",
        ["barcode"],
        unique=True,
    )

    op.create_table(
        "product_stock_packages",
        sa.Column("id", sa.Uuid(), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "product_id",
            sa.Uuid(),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column(
            "purchase_unit_id",
            sa.Uuid(),
            sa.ForeignKey("product_purchase_units.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("full_packages", sa.Numeric(18, 3), nullable=False, server_default="0"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("product_id", "purchase_unit_id", name="uq_stock_package_product_unit"),
    )
    op.create_index("ix_product_stock_packages_id", "product_stock_packages", ["id"])

    # purchase_lines: document-unit preservation
    op.add_column(
        "purchase_lines",
        sa.Column("purchase_unit_id", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "purchase_lines",
        sa.Column("purchase_unit_name", sa.String(50), nullable=True),
    )
    op.add_column(
        "purchase_lines",
        sa.Column("unit_multiplier", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "purchase_lines",
        sa.Column("base_qty_equivalent", sa.Numeric(18, 3), nullable=True),
    )
    op.create_foreign_key(
        "fk_purchase_lines_purchase_unit_id",
        "purchase_lines",
        "product_purchase_units",
        ["purchase_unit_id"],
        ["id"],
        ondelete="RESTRICT",
    )

    # inventory_movements: packaging audit columns
    op.add_column(
        "inventory_movements",
        sa.Column("document_quantity", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "inventory_movements",
        sa.Column("document_unit", sa.String(50), nullable=True),
    )
    op.add_column(
        "inventory_movements",
        sa.Column("purchase_unit_id", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "inventory_movements",
        sa.Column("packages_change", sa.Numeric(18, 3), nullable=True),
    )
    op.create_foreign_key(
        "fk_inventory_movements_purchase_unit_id",
        "inventory_movements",
        "product_purchase_units",
        ["purchase_unit_id"],
        ["id"],
        ondelete="RESTRICT",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_inventory_movements_purchase_unit_id",
        "inventory_movements",
        type_="foreignkey",
    )
    op.drop_column("inventory_movements", "packages_change")
    op.drop_column("inventory_movements", "purchase_unit_id")
    op.drop_column("inventory_movements", "document_unit")
    op.drop_column("inventory_movements", "document_quantity")

    op.drop_constraint(
        "fk_purchase_lines_purchase_unit_id",
        "purchase_lines",
        type_="foreignkey",
    )
    op.drop_column("purchase_lines", "base_qty_equivalent")
    op.drop_column("purchase_lines", "unit_multiplier")
    op.drop_column("purchase_lines", "purchase_unit_name")
    op.drop_column("purchase_lines", "purchase_unit_id")

    op.drop_index("ix_product_stock_packages_id", table_name="product_stock_packages")
    op.drop_table("product_stock_packages")
    op.drop_index(
        "ix_product_purchase_units_barcode", table_name="product_purchase_units"
    )
    op.drop_index("ix_product_purchase_units_id", table_name="product_purchase_units")
    op.drop_table("product_purchase_units")
