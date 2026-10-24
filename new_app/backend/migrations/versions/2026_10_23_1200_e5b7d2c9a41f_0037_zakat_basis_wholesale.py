"""0037_zakat_basis_wholesale

Revision ID: e5b7d2c9a41f
Revises: a7c1e9f3b5d2
Create Date: 2026-10-23

Widens the Zakat calculator's inventory valuation choice with a
transparent WHOLESALE basis (app/domain/zakat.py InventoryBasis):
zakat_calculations.inventory_basis now accepts 'wholesale' alongside
'market' | 'cost' | 'override'. Existing rows are untouched (the three
previous values keep validating).

The valuation logic itself lives in the domain layer (wholesale price
per line with a transparent retail fallback + warning) — this revision
only widens the CHECK constraint the column carries, so a snapshot
saved with the wholesale basis commits instead of failing with a
23514 violation.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'e5b7d2c9a41f'
down_revision = 'a7c1e9f3b5d2'
branch_labels = None
depends_on = None

_CONSTRAINT = 'ck_zakat_calculations_inventory_basis'
_NEW_SQL = "inventory_basis IN ('market', 'cost', 'wholesale', 'override')"
_OLD_SQL = "inventory_basis IN ('market', 'cost', 'override')"


def upgrade() -> None:
    op.drop_constraint(_CONSTRAINT, 'zakat_calculations', type_='check')
    op.create_check_constraint(_CONSTRAINT, 'zakat_calculations', _NEW_SQL)


def downgrade() -> None:
    # Refuse to drop 'wholesale' from the vocabulary while snapshots
    # still use it — history must stay validatable, never rewritten.
    from sqlalchemy import text

    conn = op.get_bind()
    count = conn.execute(
        text(
            "SELECT count(*) FROM zakat_calculations "
            "WHERE inventory_basis = 'wholesale'"
        )
    ).scalar()
    if count:
        raise RuntimeError(
            f"Cannot remove the 'wholesale' zakat inventory basis: {count} "
            "saved calculation(s) use it. Re-point or archive those "
            "snapshots before reverting this migration."
        )
    op.drop_constraint(_CONSTRAINT, 'zakat_calculations', type_='check')
    op.create_check_constraint(_CONSTRAINT, 'zakat_calculations', _OLD_SQL)
