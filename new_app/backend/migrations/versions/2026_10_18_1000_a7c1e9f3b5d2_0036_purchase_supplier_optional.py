"""0036_purchase_supplier_optional

Revision ID: a7c1e9f3b5d2
Revises: 9f4c1a7d2e63
Create Date: 2026-10-18

Quick-add / optional-supplier feature: purchases.supplier_id becomes
NULLABLE so a purchase can be recorded without a supplier (cash /
walk-in delivery). No placeholder supplier row is ever created; NULL
means "no supplier". Existing rows keep their supplier link untouched.

App-level behaviour that accompanies this revision (app/services/
purchases.py):
- create accepts an omitted / null supplier_id;
- draft update can clear the supplier with an explicit null;
- receive/cancel skip the supplier payable ledger when supplier_id IS
  NULL (stock still posts; no ledger account exists to post to).
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'a7c1e9f3b5d2'
down_revision = '9f4c1a7d2e63'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "purchases",
        "supplier_id",
        existing_type=sa.Uuid(),
        nullable=True,
    )


def downgrade() -> None:
    # Restoring NOT NULL first requires every existing row to carry a
    # supplier. Fail with an explanation instead of a raw Postgres null
    # constraint error when no-supplier purchases were recorded.
    from sqlalchemy import text

    conn = op.get_bind()
    missing = conn.execute(
        text("SELECT count(*) FROM purchases WHERE supplier_id IS NULL")
    ).scalar()
    if missing:
        raise RuntimeError(
            f"Cannot restore purchases.supplier_id NOT NULL: {missing} "
            "purchase row(s) have no supplier (supplier_id IS NULL). "
            "Give every purchase a supplier before reverting this migration."
        )
    op.alter_column(
        "purchases",
        "supplier_id",
        existing_type=sa.Uuid(),
        nullable=False,
    )
