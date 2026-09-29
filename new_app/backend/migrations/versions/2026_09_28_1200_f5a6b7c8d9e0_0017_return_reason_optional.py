"""0017_return_reason_optional

Revision ID: f5a6b7c8d9e0
Revises: e4f5a6b7c8d9
Create Date: 2026-09-28

Phase 12 fix round 1 — return reason becomes OPTIONAL (product-owner
decision):

- returns.reason drops NOT NULL and its 'other' server default, so an
  omitted / null / blank API reason persists as NULL. Nothing else on the
  document changes: the authorization of a return stays actor (POS_RETURN)
  + audit row, and a SUPPLIED reason is still vocabulary-validated by
  app.schemas.returns.ReturnCreateRequest.
- Void reason is untouched: sales.void_reason stays nullable-at-DB with a
  mandatory non-blank API rule (422), unchanged by this revision.
- Existing rows keep their stored reason; no data is rewritten.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'f5a6b7c8d9e0'
down_revision = 'e4f5a6b7c8d9'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "returns",
        "reason",
        existing_type=sa.String(length=30),
        nullable=True,
        server_default=None,
    )


def downgrade() -> None:
    # Restoring NOT NULL first requires every existing row to carry a
    # reason. Fail with an explanation instead of a raw Postgres null
    # constraint error when optional-reason returns were recorded.
    from sqlalchemy import text

    conn = op.get_bind()
    missing = conn.execute(
        text("SELECT count(*) FROM returns WHERE reason IS NULL")
    ).scalar()
    if missing:
        raise RuntimeError(
            f"Cannot restore returns.reason NOT NULL: {missing} return "
            "row(s) have no reason (reason IS NULL). Give every return a "
            "supported reason before reverting this migration."
        )
    op.alter_column(
        "returns",
        "reason",
        existing_type=sa.String(length=30),
        nullable=False,
        server_default="other",
    )
