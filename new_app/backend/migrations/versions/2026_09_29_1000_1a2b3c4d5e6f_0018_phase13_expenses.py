"""0018_phase13_expenses

Revision ID: 1a2b3c4d5e6f
Revises: f5a6b7c8d9e0
Create Date: 2026-09-29

Phase 13 (Expenses) — additive only (decision record §5, §6):

1. expenses lifecycle + payment classification
   - status VARCHAR(20) NOT NULL DEFAULT 'posted'
        posted     — recorded, immutable, counted in summaries
        cancelled  — terminal correction (never deleted, excluded from
                     the default list/summary; GATE 1 / GATE 11)
   - paid_from_drawer BOOLEAN NOT NULL DEFAULT 'true'
        legacy parity (paid_from_drawer TINYINT DEFAULT 1): true = paid
        from the cash drawer, false = paid outside. INFORMATIONAL ONLY —
        no cash ledger exists in the new backend (GATE 5).

2. expenses cancellation attribution
   - cancelled_at    TIMESTAMPTZ NULL
   - cancelled_by    UUID NULL FK users(id) ON DELETE SET NULL
   - cancel_reason   VARCHAR(200) NULL (mandatory at API level, 422 when
                    blank — the column stays nullable because pre-Phase-13
                    rows were never cancelled)

3. expenses idempotency
   - client_request_id VARCHAR(100) NULL + PARTIAL unique index
        (WHERE client_request_id IS NOT NULL) so the replay key is
        unique when present and NULL rows never collide (GATE 10).

4. expenses query path
   - ix_expenses_expense_date — list range filters + ordering (GATE 27)
   - ix_expenses_user_id      — attribution lookups

Downgrade drops ONLY what this revision added (no data is rewritten by
upgrade; there are 0 legacy expense rows in the Phase 13 dev database).
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '1a2b3c4d5e6f'
down_revision = 'f5a6b7c8d9e0'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. lifecycle + payment classification ---------------------------------
    op.add_column(
        "expenses",
        sa.Column(
            "status",
            sa.String(length=20),
            server_default="posted",
            nullable=False,
        ),
    )
    op.add_column(
        "expenses",
        sa.Column(
            "paid_from_drawer",
            sa.Boolean(),
            server_default="true",
            nullable=False,
        ),
    )

    # 2. cancellation attribution -------------------------------------------
    op.add_column(
        "expenses",
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "expenses",
        sa.Column("cancelled_by", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "expenses",
        sa.Column("cancel_reason", sa.String(length=200), nullable=True),
    )
    op.create_foreign_key(
        "expenses_cancelled_by_fkey",
        "expenses",
        "users",
        ["cancelled_by"],
        ["id"],
        ondelete="SET NULL",
    )

    # 3. idempotency key ----------------------------------------------------
    op.add_column(
        "expenses",
        sa.Column("client_request_id", sa.String(length=100), nullable=True),
    )
    op.create_index(
        "ux_expenses_client_request_id",
        "expenses",
        ["client_request_id"],
        unique=True,
        postgresql_where=sa.text("client_request_id IS NOT NULL"),
    )

    # 4. query path ---------------------------------------------------------
    op.create_index(
        op.f("ix_expenses_expense_date"),
        "expenses",
        ["expense_date"],
        unique=False,
    )
    op.create_index(
        op.f("ix_expenses_user_id"),
        "expenses",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_expenses_user_id"), table_name="expenses")
    op.drop_index(op.f("ix_expenses_expense_date"), table_name="expenses")

    op.drop_index("ux_expenses_client_request_id", table_name="expenses")
    op.drop_column("expenses", "client_request_id")

    op.drop_constraint("expenses_cancelled_by_fkey", "expenses",
                       type_="foreignkey")
    op.drop_column("expenses", "cancel_reason")
    op.drop_column("expenses", "cancelled_by")
    op.drop_column("expenses", "cancelled_at")

    op.drop_column("expenses", "paid_from_drawer")
    op.drop_column("expenses", "status")
