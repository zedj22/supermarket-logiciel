"""0007_selling_price_nullable

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-09-23

Phase 6 selling-unit price fix:
- product_selling_units.selling_price becomes NULLable
- NULL means "inherit product.price" (effective_unit_price)
- Previously NOT NULL + default 0 coerced missing prices to 0.000
- Existing explicit 0 rows stay 0 (valid free price) — no data rewrite
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "e5f6a7b8c9d0"
down_revision = "d4e5f6a7b8c9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "product_selling_units",
        "selling_price",
        existing_type=sa.Numeric(18, 3),
        nullable=True,
        server_default=None,
    )


def downgrade() -> None:
    # Restore NOT NULL: existing NULLs become 0 before tightening the constraint.
    op.execute(
        "UPDATE product_selling_units SET selling_price = 0 WHERE selling_price IS NULL"
    )
    op.alter_column(
        "product_selling_units",
        "selling_price",
        existing_type=sa.Numeric(18, 3),
        nullable=False,
        server_default="0",
    )
