"""Initial migration — create the alembic_version table.

This is the baseline migration. Future migrations will create
the actual application tables (Phase 2+).

Revision ID: 0001_initial
Revises:
Create Date: 2026-09-22
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "0001_initial"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # The alembic_version table is created automatically by Alembic.
    # This migration exists to establish the baseline.
    # Application tables will be added in Phase 2.
    pass


def downgrade() -> None:
    pass
