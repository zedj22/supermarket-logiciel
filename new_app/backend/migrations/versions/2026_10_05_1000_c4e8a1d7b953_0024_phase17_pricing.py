"""0024_phase17_pricing

Revision ID: c4e8a1d7b953
Revises: 5c8d2e1f4a73
Create Date: 2026-10-05

Phase 17 pricing enhancement - ADDITIVE ONLY.

products gains the three new pricing columns:

    wholesale_price    NUMERIC(18,3) NULL    wholesale unit price
    wholesale_min_qty  NUMERIC(18,3) NULL    threshold in product units
    vat_rate           SMALLINT NOT NULL     strict {0, 9, 19} TVA rate

Backward compatibility: the two wholesale columns are NULL, which is
EXACTLY the "wholesale not configured" state - every existing product keeps
selling at its retail price with zero data rewrite. vat_rate defaults to 0
(no VAT), matching the pre-phase behaviour where no tax concept existed.

No sale / invoice / report column is touched: vat_rate is stored product
metadata only (see docs/PHASE_17_PRICING.md - VAT policy).

- upgrade   : three additive ADD COLUMNs, no row rewritten
- downgrade : DROP the three columns (wholesale/VAT configuration is lost,
              prices and sale history are untouched)
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'c4e8a1d7b953'
down_revision = '5c8d2e1f4a73'
branch_labels = None
depends_on = None

_WHOLESALE_COLUMNS = (
    ("wholesale_price", sa.Numeric(18, 3), True, None),
    ("wholesale_min_qty", sa.Numeric(18, 3), True, None),
)


def upgrade() -> None:
    for name, type_, nullable, server_default in _WHOLESALE_COLUMNS:
        op.add_column(
            "products",
            sa.Column(name, type_, nullable=nullable, server_default=server_default),
        )
    op.add_column(
        "products",
        sa.Column("vat_rate", sa.SmallInteger(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_column("products", "vat_rate")
    for name, _type, _nullable, _server_default in reversed(_WHOLESALE_COLUMNS):
        op.drop_column("products", name)
