"""0008_phase7_inventory_pmp

Revision ID: f1a2b3c4d5e6
Revises: e5f6a7b8c9d0
Create Date: 2026-09-23

Phase 7 inventory / PMP (moving weighted average cost):
- products.avg_cost NUMERIC(18,3) NOT NULL DEFAULT 0 — authoritative PMP
  (products.cost stays nominal/last-purchase — never overwritten by sales)
- inventory_movements.unit_cost — unit cost at time of receipt (nullable)
- inventory_movements.avg_cost_after — PMP snapshot after the movement (nullable)
- index on inventory_movements.movement_date for history queries
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "f1a2b3c4d5e6"
down_revision = "e5f6a7b8c9d0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "products",
        sa.Column(
            "avg_cost",
            sa.Numeric(18, 3),
            nullable=False,
            server_default="0",
        ),
    )
    op.add_column(
        "inventory_movements",
        sa.Column("unit_cost", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "inventory_movements",
        sa.Column("avg_cost_after", sa.Numeric(18, 3), nullable=True),
    )
    op.create_index(
        "ix_inventory_movements_movement_date",
        "inventory_movements",
        ["movement_date"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_inventory_movements_movement_date",
        table_name="inventory_movements",
    )
    op.drop_column("inventory_movements", "avg_cost_after")
    op.drop_column("inventory_movements", "unit_cost")
    op.drop_column("products", "avg_cost")
