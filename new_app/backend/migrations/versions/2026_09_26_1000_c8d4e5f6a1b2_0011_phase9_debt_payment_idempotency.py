"""0011_phase9_debt_payment_idempotency

Revision ID: c8d4e5f6a1b2
Revises: b7c3d4e5f6a1
Create Date: 2026-09-26

Phase 9 backend customers/debts:
- debt_ledger_entries.client_request_id — payment idempotency key
  (unique when present). Repeats of the same payment command return the
  original entry instead of deducting the balance twice.

Non-destructive: adds one nullable column + one unique index. No rows
are rewritten; downgrade removes only what this revision added.
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "c8d4e5f6a1b2"
down_revision = "b7c3d4e5f6a1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "debt_ledger_entries",
        sa.Column(
            "client_request_id",
            sa.String(length=100),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_debt_ledger_entries_client_request_id",
        "debt_ledger_entries",
        ["client_request_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_debt_ledger_entries_client_request_id",
        table_name="debt_ledger_entries",
    )
    op.drop_column("debt_ledger_entries", "client_request_id")
