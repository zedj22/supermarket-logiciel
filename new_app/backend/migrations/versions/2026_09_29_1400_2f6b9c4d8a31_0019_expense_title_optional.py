"""0019_expense_title_optional

Revision ID: 2f6b9c4d8a31
Revises: 1a2b3c4d5e6f
Create Date: 2026-09-29

Phase 13 Fix Round 2 — the expense title is OPTIONAL (product-owner
requirement).

``expenses.title`` was created NOT NULL by 0002 (legacy parity:
``title VARCHAR(200) NOT NULL``) and 0018 never touched it. The API now
accepts an omitted / null / blank title and stores NULL (decision record
B1, Fix Round 2), so the column must become nullable.

- upgrade   : ALTER expenses.title DROP NOT NULL  (additive, no data
              rewrite, no row is touched)
- downgrade : ALTER expenses.title SET NOT NULL - only succeeds when no
              NULL title remains, so normalize / delete the NULL rows
              first. 0018 itself is NOT modified (applied migration
              stays byte-identical).

This revision does nothing else: status / paid_from_drawer /
cancellation / idempotency columns and indexes are unchanged.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '2f6b9c4d8a31'
down_revision = '1a2b3c4d5e6f'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "expenses",
        "title",
        existing_type=sa.String(length=200),
        existing_nullable=False,
        nullable=True,
    )


def downgrade() -> None:
    # Fails while any row still has title IS NULL (explicit, not silent):
    # normalize those titles before downgrading.
    op.alter_column(
        "expenses",
        "title",
        existing_type=sa.String(length=200),
        existing_nullable=True,
        nullable=False,
    )
