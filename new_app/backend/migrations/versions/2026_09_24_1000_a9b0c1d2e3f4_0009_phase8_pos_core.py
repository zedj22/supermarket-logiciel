"""0009_phase8_pos_core

Revision ID: a9b0c1d2e3f4
Revises: f1a2b3c4d5e6
Create Date: 2026-09-24

Phase 8 backend POS core:
- sales.client_request_id — idempotency key (unique when present)
- pos_holds — server-side cart snapshots (no stock reservation)
- product_favorites — manual POS favorites pins
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "a9b0c1d2e3f4"
down_revision = "f1a2b3c4d5e6"
branch_labels = None
depends_on = None

UUID_PK_SERVER_DEFAULT = sa.text("gen_random_uuid()")


def upgrade() -> None:
    op.add_column(
        "sales",
        sa.Column(
            "client_request_id",
            sa.String(length=100),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_sales_client_request_id",
        "sales",
        ["client_request_id"],
        unique=True,
    )

    op.create_table(
        "pos_holds",
        sa.Column(
            "id",
            sa.Uuid(),
            server_default=UUID_PK_SERVER_DEFAULT,
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("device_id", sa.String(length=100), nullable=True),
        sa.Column(
            "customer_id",
            sa.Uuid(),
            sa.ForeignKey("customers.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("cart_snapshot", sa.JSON(), nullable=False),
        sa.Column(
            "invoice_discount",
            sa.Numeric(18, 3),
            nullable=False,
            server_default="0",
        ),
        sa.Column("note", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_pos_holds_id"), "pos_holds", ["id"], unique=False)
    op.create_index("ix_pos_holds_user_id", "pos_holds", ["user_id"])
    op.create_index("ix_pos_holds_device_id", "pos_holds", ["device_id"])
    op.create_index("ix_pos_holds_customer_id", "pos_holds", ["customer_id"])

    op.create_table(
        "product_favorites",
        sa.Column(
            "id",
            sa.Uuid(),
            server_default=UUID_PK_SERVER_DEFAULT,
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "product_id",
            sa.Uuid(),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.UniqueConstraint(
            "product_id",
            "user_id",
            name="uq_product_favorite_user",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_product_favorites_id"), "product_favorites", ["id"], unique=False
    )
    op.create_index(
        "ix_product_favorites_product_id", "product_favorites", ["product_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_product_favorites_product_id", table_name="product_favorites")
    op.drop_index(op.f("ix_product_favorites_id"), table_name="product_favorites")
    op.drop_table("product_favorites")
    op.drop_index("ix_pos_holds_customer_id", table_name="pos_holds")
    op.drop_index("ix_pos_holds_device_id", table_name="pos_holds")
    op.drop_index("ix_pos_holds_user_id", table_name="pos_holds")
    op.drop_index(op.f("ix_pos_holds_id"), table_name="pos_holds")
    op.drop_table("pos_holds")
    op.drop_index("ix_sales_client_request_id", table_name="sales")
    op.drop_column("sales", "client_request_id")
