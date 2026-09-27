"""0012_phase10_packs_sale_line_target

Revision ID: d1e2f3a4b5c6
Revises: c8d4e5f6a1b2
Create Date: 2026-09-26

Phase 10 packs:
- sale_lines.product_id becomes NULLable. A pack sale persists ONE pack
  summary row whose target is the pack itself (product_id IS NULL,
  pack_id set — the shape documented in PHASE_8_POS_ANALYSIS.md:544),
  plus one row per component (product_id set, pack_id set, line_total 0).
  Ordinary product lines are unaffected: they keep product_id set.
- sale_lines.pack_id gains an index (the model already declared the
  column without one; without this index alembic autogenerate would
  report a pending change).

Non-destructive: the upgrade only relaxes a NOT NULL constraint and adds
an index — no rows are rewritten. The downgrade restores NOT NULL, which
is safe precisely because pack summary rows only exist once Phase 10
sales have been recorded (the migration test suite downgrades from a
freshly-upgraded database).
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "d1e2f3a4b5c6"
down_revision = "c8d4e5f6a1b2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column(
        "sale_lines",
        "product_id",
        existing_type=sa.Uuid(),
        nullable=True,
    )
    op.create_index(
        "ix_sale_lines_pack_id",
        "sale_lines",
        ["pack_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_sale_lines_pack_id", table_name="sale_lines")
    # Restoring NOT NULL is only possible while no pack summary rows
    # (product_id IS NULL) exist. Fail with an explanation instead of a raw
    # Postgres constraint error when the database already holds pack sales.
    from sqlalchemy import text

    conn = op.get_bind()
    orphan = conn.execute(
        text("SELECT count(*) FROM sale_lines WHERE product_id IS NULL")
    ).scalar()
    if orphan:
        raise RuntimeError(
            f"Cannot restore sale_lines.product_id NOT NULL: {orphan} pack "
            "summary row(s) exist (product_id IS NULL). Downgrade Phase 10 "
            "pack sales before reverting this migration."
        )
    op.alter_column(
        "sale_lines",
        "product_id",
        existing_type=sa.Uuid(),
        nullable=False,
    )
