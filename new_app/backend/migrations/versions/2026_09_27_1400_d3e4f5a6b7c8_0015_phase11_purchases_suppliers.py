"""0015_phase11_purchases_suppliers

Revision ID: d3e4f5a6b7c8
Revises: c9d0e1f2a3b4
Create Date: 2026-09-27

Phase 11 (Purchases & Suppliers) — additive only:

1. suppliers: restore the legacy contact fields (email, contact_person,
   notes) from python_app's suppliers DDL (db_manager.py:664-676).
2. purchases: document lifecycle columns
   - status ('draft' | 'received' | 'cancelled'), GATE 2
   - client_request_id (unique idempotency key), GATE 18
   - received_at / cancelled_at audit timestamps
   server_default for status is 'received' so any pre-existing row is
   treated as received (legacy created purchases fully posted; no service
   ever wrote this table before Phase 11). New rows always set status
   explicitly from the ORM default ('draft').
   Indexes for real query paths: status, purchase_date (GATE 21).
3. supplier_ledger_entries: authoritative append-only payables ledger
   (GATE 10). suppliers.balance is a cached projection of this ledger.

Downgrade drops only what this revision added; no existing rows are
rewritten or dropped.
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'd3e4f5a6b7c8'
down_revision = 'c9d0e1f2a3b4'
branch_labels = None
depends_on = None

# UUID PK server default: gen_random_uuid() (requires pgcrypto or PG13+)
UUID_PK_SERVER_DEFAULT = sa.text("gen_random_uuid()")


def upgrade() -> None:
    # 1. Supplier contact fields (legacy parity) --------------------------
    op.add_column("suppliers", sa.Column("email", sa.String(length=100), nullable=True))
    op.add_column("suppliers", sa.Column("contact_person", sa.String(length=100), nullable=True))
    op.add_column("suppliers", sa.Column("notes", sa.Text(), nullable=True))

    # 2. Purchase lifecycle ----------------------------------------------
    op.add_column(
        "purchases",
        sa.Column(
            "status",
            sa.String(length=20),
            nullable=False,
            server_default="received",  # backfill: legacy purchases were posted
        ),
    )
    op.add_column(
        "purchases",
        sa.Column("client_request_id", sa.String(length=100), nullable=True),
    )
    op.add_column(
        "purchases",
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "purchases",
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index(op.f("ix_purchases_status"), "purchases", ["status"], unique=False)
    op.create_index(op.f("ix_purchases_purchase_date"), "purchases", ["purchase_date"], unique=False)
    op.create_index(
        op.f("ix_purchases_client_request_id"),
        "purchases",
        ["client_request_id"],
        unique=True,
    )

    # 3. Supplier ledger --------------------------------------------------
    op.create_table(
        "supplier_ledger_entries",
        sa.Column("supplier_id", sa.Uuid(), nullable=False),
        sa.Column("entry_type", sa.String(length=20), nullable=False),
        sa.Column("amount", sa.Numeric(precision=18, scale=3), server_default="0", nullable=False),
        sa.Column("reference_purchase_id", sa.Uuid(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("client_request_id", sa.String(length=100), nullable=True),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("entry_date", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("id", sa.Uuid(), server_default=UUID_PK_SERVER_DEFAULT, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["supplier_id"], ["suppliers.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["reference_purchase_id"], ["purchases.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_supplier_ledger_entries_id"),
        "supplier_ledger_entries",
        ["id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_supplier_ledger_entries_supplier_id"),
        "supplier_ledger_entries",
        ["supplier_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_supplier_ledger_entries_entry_type"),
        "supplier_ledger_entries",
        ["entry_type"],
        unique=False,
    )
    op.create_index(
        op.f("ix_supplier_ledger_entries_reference_purchase_id"),
        "supplier_ledger_entries",
        ["reference_purchase_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_supplier_ledger_entries_client_request_id"),
        "supplier_ledger_entries",
        ["client_request_id"],
        unique=True,
    )
    # Ledger read path: one supplier's history, newest first (GATE 21).
    op.create_index(
        "ix_supplier_ledger_entries_supplier_entry_date",
        "supplier_ledger_entries",
        ["supplier_id", "entry_date"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_supplier_ledger_entries_supplier_entry_date",
        table_name="supplier_ledger_entries",
    )
    op.drop_index(
        op.f("ix_supplier_ledger_entries_client_request_id"),
        table_name="supplier_ledger_entries",
    )
    op.drop_index(
        op.f("ix_supplier_ledger_entries_reference_purchase_id"),
        table_name="supplier_ledger_entries",
    )
    op.drop_index(
        op.f("ix_supplier_ledger_entries_entry_type"),
        table_name="supplier_ledger_entries",
    )
    op.drop_index(
        op.f("ix_supplier_ledger_entries_supplier_id"),
        table_name="supplier_ledger_entries",
    )
    op.drop_index(op.f("ix_supplier_ledger_entries_id"), table_name="supplier_ledger_entries")
    op.drop_table("supplier_ledger_entries")

    op.drop_index(op.f("ix_purchases_client_request_id"), table_name="purchases")
    op.drop_index(op.f("ix_purchases_purchase_date"), table_name="purchases")
    op.drop_index(op.f("ix_purchases_status"), table_name="purchases")
    op.drop_column("purchases", "cancelled_at")
    op.drop_column("purchases", "received_at")
    op.drop_column("purchases", "client_request_id")
    op.drop_column("purchases", "status")

    op.drop_column("suppliers", "notes")
    op.drop_column("suppliers", "contact_person")
    op.drop_column("suppliers", "email")
