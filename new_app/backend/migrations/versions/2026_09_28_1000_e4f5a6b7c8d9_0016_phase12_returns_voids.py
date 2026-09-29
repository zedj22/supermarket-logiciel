"""0016_phase12_returns_voids

Revision ID: e4f5a6b7c8d9
Revises: d3e4f5a6b7c8
Create Date: 2026-09-28

Phase 12 (Returns / Voids) — additive only (decision record §5, §6):

1. sales: void attribution columns (GATE 9)
   - voided_at      TIMESTAMPTZ NULL — when the invoice was voided
   - voided_by      UUID NULL FK users(id) SET NULL — who voided it
   - void_reason    TEXT NULL — operator reason (mandatory at API level,
                    422 when blank; the column stays nullable because
                    pre-Phase-12 rows were never voided)
   Snapshot columns (subtotal/discount/total/paid/change) are NEVER
   rewritten — Phase 0 rules #3/#4 forbid zeroing them.

2. returns: idempotency + refund decomposition (GATE 14, GATE 16)
   - client_request_id VARCHAR(100) UNIQUE NULL — replay key
   - subtotal  NUMERIC(18,3) NOT NULL DEFAULT 0 — Σ line refunds
   - discount  NUMERIC(18,3) NOT NULL DEFAULT 0 — invoice-discount share
   total (existing) = subtotal - discount.
   Indexes: unique client_request_id + return_date (list query path).
   returns.sale_id already carries ix_returns_sale_id from 0002.

3. return_lines: pack/variant/selling-unit return shapes (GATE 11-13)
   - product_id becomes NULLable — a charged pack summary return line
     targets the pack (product_id IS NULL, pack_id set), mirroring the
     Phase 10 sale_lines shape.
   - pack_id UUID NULL FK packs RESTRICT (+ index, matching sale_lines)
   - variant_name / selling_unit_name / selling_unit_multiplier —
     historical display snapshots copied from the sale line, never
     re-read from the catalog
   - quantity_base NUMERIC(18,3) NULL — base units actually restored
   - unit_cost NUMERIC(18,3) NOT NULL DEFAULT 0 — movement snapshot
   - line_discount NUMERIC(18,3) NOT NULL DEFAULT 0

Downgrade drops ONLY what this revision added. The only destructive
step is restoring return_lines.product_id NOT NULL, guarded exactly like
migration 0012: it fails loudly if pack summary return rows exist instead
of raising a raw Postgres constraint error.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'e4f5a6b7c8d9'
down_revision = 'd3e4f5a6b7c8'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. sales: void attribution -------------------------------------------
    op.add_column(
        "sales",
        sa.Column("voided_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sales",
        sa.Column("voided_by", sa.Uuid(), nullable=True),
    )
    op.add_column("sales", sa.Column("void_reason", sa.Text(), nullable=True))
    op.create_foreign_key(
        "sales_voided_by_fkey",
        "sales",
        "users",
        ["voided_by"],
        ["id"],
        ondelete="SET NULL",
    )

    # 2. returns: idempotency + refund decomposition -----------------------
    op.add_column(
        "returns",
        sa.Column("client_request_id", sa.String(length=100), nullable=True),
    )
    op.add_column(
        "returns",
        sa.Column(
            "subtotal", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
    )
    op.add_column(
        "returns",
        sa.Column(
            "discount", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
    )
    op.create_index(
        op.f("ix_returns_client_request_id"),
        "returns",
        ["client_request_id"],
        unique=True,
    )
    op.create_index(
        op.f("ix_returns_return_date"),
        "returns",
        ["return_date"],
        unique=False,
    )

    # 3. return_lines: pack / variant / selling-unit shapes ----------------
    op.alter_column(
        "return_lines",
        "product_id",
        existing_type=sa.Uuid(),
        nullable=True,
    )
    op.add_column(
        "return_lines", sa.Column("pack_id", sa.Uuid(), nullable=True)
    )
    op.add_column(
        "return_lines",
        sa.Column("variant_name", sa.String(length=100), nullable=True),
    )
    op.add_column(
        "return_lines",
        sa.Column("selling_unit_name", sa.String(length=50), nullable=True),
    )
    op.add_column(
        "return_lines",
        sa.Column(
            "selling_unit_multiplier", sa.Numeric(18, 3), nullable=True
        ),
    )
    op.add_column(
        "return_lines",
        sa.Column("quantity_base", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "return_lines",
        sa.Column(
            "unit_cost", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
    )
    op.add_column(
        "return_lines",
        sa.Column(
            "line_discount",
            sa.Numeric(18, 3),
            server_default="0",
            nullable=False,
        ),
    )
    op.create_foreign_key(
        "return_lines_pack_id_fkey",
        "return_lines",
        "packs",
        ["pack_id"],
        ["id"],
        ondelete="RESTRICT",
    )
    op.create_index(
        op.f("ix_return_lines_pack_id"),
        "return_lines",
        ["pack_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_return_lines_pack_id"), table_name="return_lines")
    op.drop_constraint(
        "return_lines_pack_id_fkey", "return_lines", type_="foreignkey"
    )
    op.drop_column("return_lines", "line_discount")
    op.drop_column("return_lines", "unit_cost")
    op.drop_column("return_lines", "quantity_base")
    op.drop_column("return_lines", "selling_unit_multiplier")
    op.drop_column("return_lines", "selling_unit_name")
    op.drop_column("return_lines", "variant_name")
    op.drop_column("return_lines", "pack_id")

    # Restoring NOT NULL is only possible while no pack summary return rows
    # exist (product_id IS NULL). Fail with an explanation instead of a raw
    # Postgres constraint error when Phase 12 pack returns were recorded.
    from sqlalchemy import text

    conn = op.get_bind()
    orphan = conn.execute(
        text("SELECT count(*) FROM return_lines WHERE product_id IS NULL")
    ).scalar()
    if orphan:
        raise RuntimeError(
            f"Cannot restore return_lines.product_id NOT NULL: {orphan} pack "
            "summary return row(s) exist (product_id IS NULL). Delete Phase 12 "
            "pack returns before reverting this migration."
        )
    op.alter_column(
        "return_lines",
        "product_id",
        existing_type=sa.Uuid(),
        nullable=False,
    )

    op.drop_index(op.f("ix_returns_return_date"), table_name="returns")
    op.drop_index(op.f("ix_returns_client_request_id"), table_name="returns")
    op.drop_column("returns", "discount")
    op.drop_column("returns", "subtotal")
    op.drop_column("returns", "client_request_id")

    op.drop_constraint("sales_voided_by_fkey", "sales", type_="foreignkey")
    op.drop_column("sales", "void_reason")
    op.drop_column("sales", "voided_by")
    op.drop_column("sales", "voided_at")
