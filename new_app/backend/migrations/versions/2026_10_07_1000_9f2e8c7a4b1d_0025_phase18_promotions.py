"""0025_phase18_promotions

Revision ID: 9f2e8c7a4b1d
Revises: c4e8a1d7b953
Create Date: 2026-10-07

Phase 18 (Promotions) — additive only.

1. promotions — ONE row per promotion
   - name             VARCHAR(200) NOT NULL
   - promotion_type   VARCHAR(20)  NOT NULL DEFAULT 'percentage'
        percentage    — value = percent OFF the retail price (0 < v <= 100)
        fixed_price   — value = the single selling price, replaces retail
   - value            NUMERIC(18,3) NOT NULL (0.001 quantum, app rounds
                      HALF_UP — same money rules as every other amount)
   - is_active        BOOLEAN NOT NULL DEFAULT true
        explicit toggle only; NO start/end date columns on purpose
        (no scheduling convention exists in this codebase yet)
   - client_request_id VARCHAR(100) NULL + PARTIAL unique index
        (WHERE client_request_id IS NOT NULL) — idempotent create replay
        key, same convention as expenses (Phase 13 GATE 10)
    - created_by       UUID NULL FK users(id) ON DELETE SET NULL — audit
        attribution without blocking a user deletion
    - created_at / updated_at  TIMESTAMPTZ from TimestampMixin
    - ix_promotions_id + ix_promotions_name — UUIDMixin.id is index=True,
        same as every other table (0021 convention)

2. promotion_products — promotion ↔ product membership (M:N)
   - promotion_id UUID NOT NULL FK promotions(id) ON DELETE CASCADE
   - product_id   UUID NOT NULL FK products(id)   ON DELETE CASCADE
   - UNIQUE (promotion_id, product_id) — one row per member product
    - created_at / updated_at  TIMESTAMPTZ from TimestampMixin
    - ix index on id (UUIDMixin.index = True) and on promotion_id
    - ix index on product_id — POS/checkout looks promotions up BY PRODUCT

Deliberately absent
-------------------
* NO start/end scheduling columns — activation is the is_active boolean
  only (see promotion service docstring).
* NO partial unique index on product_id alone (one ACTIVE promotion per
  product) — an index cannot span two tables portably, and it would also
  forbid two INACTIVE promotions sharing a product. Enforced in
  PromotionService inside the transaction (409
  PROMOTION_PRODUCT_CONFLICT) — documented Phase 18 decision.
* NO original-price column anywhere: products.price is NEVER written by
  a promotion, deactivation therefore needs no data restoration.

Downgrade drops ONLY what this revision added; upgrade writes no data.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '9f2e8c7a4b1d'
down_revision = 'c4e8a1d7b953'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. promotions --------------------------------------------------------
    op.create_table(
        "promotions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column(
            "promotion_type",
            sa.String(length=20),
            server_default="percentage",
            nullable=False,
        ),
        sa.Column("value", sa.Numeric(18, 3), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default="true",
                  nullable=False),
        sa.Column("client_request_id", sa.String(length=100), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
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
        sa.ForeignKeyConstraint(
            ["created_by"], ["users.id"], ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_promotions_id"), "promotions", ["id"], unique=False
    )
    op.create_index(
        op.f("ix_promotions_name"), "promotions", ["name"], unique=False
    )
    op.create_index(
        "ux_promotions_client_request_id",
        "promotions",
        ["client_request_id"],
        unique=True,
        postgresql_where=sa.text("client_request_id IS NOT NULL"),
    )

    # 2. promotion_products -------------------------------------------------
    op.create_table(
        "promotion_products",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("promotion_id", sa.Uuid(), nullable=False),
        sa.Column("product_id", sa.Uuid(), nullable=False),
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
        sa.ForeignKeyConstraint(
            ["promotion_id"],
            ["promotions.id"],
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["product_id"], ["products.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "promotion_id",
            "product_id",
            name="uq_promotion_products_promotion_product",
        ),
    )
    op.create_index(
        op.f("ix_promotion_products_id"),
        "promotion_products",
        ["id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_promotion_products_promotion_id"),
        "promotion_products",
        ["promotion_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_promotion_products_product_id"),
        "promotion_products",
        ["product_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        op.f("ix_promotion_products_product_id"),
        table_name="promotion_products",
    )
    op.drop_index(
        op.f("ix_promotion_products_promotion_id"),
        table_name="promotion_products",
    )
    op.drop_index(
        op.f("ix_promotion_products_id"), table_name="promotion_products"
    )
    op.drop_table("promotion_products")

    op.drop_index(
        "ux_promotions_client_request_id", table_name="promotions"
    )
    op.drop_index(op.f("ix_promotions_name"), table_name="promotions")
    op.drop_index(op.f("ix_promotions_id"), table_name="promotions")
    op.drop_table("promotions")
