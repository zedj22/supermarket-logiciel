"""0005_phase6_product_selling_units

Revision ID: c3d4e5f6a7b8
Revises: b2c3d4e5f6a7
Create Date: 2026-09-23

Adds Phase 6 selling units (commercial forms of a product):
- product_selling_units table (multiplier, independent price, own barcode)
- Does NOT modify products or product_variants (existing rows stay valid)
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "c3d4e5f6a7b8"
down_revision = "b2c3d4e5f6a7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # FK index=True already creates ix_product_selling_units_product_id;
    # barcode gets an explicit unique index below.
    op.create_table(
        "product_selling_units",
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
        sa.Column("selling_price", sa.Numeric(18, 3), nullable=False, server_default="0"),
        sa.Column("is_base_unit", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("product_id", "name", name="uq_selling_unit_product_name"),
    )
    op.create_index("ix_product_selling_units_id", "product_selling_units", ["id"])
    op.create_index(
        "ix_product_selling_units_barcode",
        "product_selling_units",
        ["barcode"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("ix_product_selling_units_barcode", table_name="product_selling_units")
    op.drop_index("ix_product_selling_units_id", table_name="product_selling_units")
    op.drop_table("product_selling_units")
