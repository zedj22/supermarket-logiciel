"""0003_fix_timestamp_defaults

Revision ID: a1b2c3d4e5f6
Revises: 73355bdf31d4
Create Date: 2026-09-22

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a1b2c3d4e5f6'
down_revision: Union[str, None] = '73355bdf31d4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Fix 8 timestamp columns that had fixed literal timestamps as defaults.
    # Change them to use dynamic now() function instead.
    now_text = sa.text('now()')

    op.alter_column('sales', 'sale_date',
                     server_default=now_text)
    op.alter_column('purchases', 'purchase_date',
                     server_default=now_text)
    op.alter_column('returns', 'return_date',
                     server_default=now_text)
    op.alter_column('sale_payments', 'payment_date',
                     server_default=now_text)
    op.alter_column('debt_ledger_entries', 'entry_date',
                     server_default=now_text)
    op.alter_column('inventory_movements', 'movement_date',
                     server_default=now_text)
    op.alter_column('expenses', 'expense_date',
                     server_default=now_text)
    op.alter_column('audit_logs', 'action_at',
                     server_default=now_text)


def downgrade() -> None:
    # Revert to the literal timestamp defaults (not recommended, but reversible).
    literal_default = sa.text("'2026-09-22 12:36:17.302169+01'::timestamp with time zone")

    op.alter_column('sales', 'sale_date',
                     server_default=literal_default)
    op.alter_column('purchases', 'purchase_date',
                     server_default=literal_default)
    op.alter_column('returns', 'return_date',
                     server_default=literal_default)
    op.alter_column('sale_payments', 'payment_date',
                     server_default=literal_default)
    op.alter_column('debt_ledger_entries', 'entry_date',
                     server_default=literal_default)
    op.alter_column('inventory_movements', 'movement_date',
                     server_default=literal_default)
    op.alter_column('expenses', 'expense_date',
                     server_default=literal_default)
    op.alter_column('audit_logs', 'action_at',
                     server_default=literal_default)
