"""0010_phase8_sale_line_snapshots

Revision ID: b7c3d4e5f6a1
Revises: a9b0c1d2e3f4
Create Date: 2026-09-24

Phase 8 UX FIX #11 — historical sale-line display snapshots:
- sale_lines.variant_name               (nullable)
- sale_lines.selling_unit_name          (nullable)
- sale_lines.selling_unit_multiplier    (nullable, NUMERIC(18,3))

Additive + non-destructive: existing rows keep NULL (base-unit sales and
all pre-Phase-8 sales stay readable). No foreign keys — these are display
snapshots that must survive catalog renames / multiplier changes / archives.
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "b7c3d4e5f6a1"
down_revision = "a9b0c1d2e3f4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sale_lines",
        sa.Column("variant_name", sa.String(length=100), nullable=True),
    )
    op.add_column(
        "sale_lines",
        sa.Column("selling_unit_name", sa.String(length=50), nullable=True),
    )
    op.add_column(
        "sale_lines",
        sa.Column(
            "selling_unit_multiplier",
            sa.Numeric(18, 3),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("sale_lines", "selling_unit_multiplier")
    op.drop_column("sale_lines", "selling_unit_name")
    op.drop_column("sale_lines", "variant_name")
