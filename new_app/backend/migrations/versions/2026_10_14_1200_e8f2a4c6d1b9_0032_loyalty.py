"""0032_loyalty

Revision ID: e8f2a4c6d1b9
Revises: f3c8a21d9e05
Create Date: 2026-10-14

Phase A (loyalty foundation) — three new tables + five nullable sale
summary columns. No existing column is rewritten, no row is read.

loyalty_settings
   id                        INTEGER PK — always 1 (singleton, CHECK-enforced)
   points_enabled            BOOLEAN       NOT NULL   default true (Python-side)
   points_rate               NUMERIC(18,6) NOT NULL   points per 1 DA, CHECK >= 0
   cashback_enabled          BOOLEAN       NOT NULL   default false (Python-side)
   cashback_rate             NUMERIC(18,3) NOT NULL   percent, CHECK >= 0
   point_value               NUMERIC(18,3) NOT NULL   DA per point, CHECK > 0
   min_redemption_points     NUMERIC(18,0) NOT NULL   CHECK >= 0
   max_redemption_percent    NUMERIC(18,3) NOT NULL   of amount due, CHECK (0, 100]
   earn_on_debt_settlement   BOOLEAN       NOT NULL   default true (Python-side)
   created_at / updated_at                 TIMESTAMPTZ, from TimestampMixin

loyalty_accounts
   id                        UUID PK  gen_random_uuid()
   customer_id               UUID NOT NULL FK customers CASCADE, UNIQUE
   points_balance            NUMERIC(18,0) NOT NULL   default 0, CHECK >= 0
   cashback_balance          NUMERIC(18,3) NOT NULL   default 0, CHECK >= 0
   created_at / updated_at                 TIMESTAMPTZ

loyalty_ledger_entries
   id                        UUID PK  gen_random_uuid()
   account_id                UUID NOT NULL FK loyalty_accounts CASCADE
   event_type                VARCHAR(30) NOT NULL     CHECK IN (Phase B set)
   points_delta              NUMERIC(18,0) NOT NULL   default 0, signed
   cashback_delta            NUMERIC(18,3) NOT NULL   default 0, signed
   balance_after_points      NUMERIC(18,0) NOT NULL   default 0, CHECK >= 0
   balance_after_cashback    NUMERIC(18,3) NOT NULL   default 0, CHECK >= 0
   source_event_key          VARCHAR(120) NOT NULL    UNIQUE idempotency key
   sale_id                   UUID NULL FK sales RESTRICT
   return_id                 UUID NULL FK returns RESTRICT
   created_by                UUID NULL FK users SET NULL
   note                      TEXT NULL
   created_at / updated_at                 TIMESTAMPTZ

sales (additive, all NULLABLE, no defaults)
   loyalty_points_earned     NUMERIC(18,0) NULL   CHECK >= 0
   loyalty_cashback_earned   NUMERIC(18,3) NULL   CHECK >= 0
   loyalty_points_redeemed   NUMERIC(18,0) NULL   CHECK >= 0
   loyalty_redeemed_value    NUMERIC(18,3) NULL   CHECK >= 0
   amount_due                NUMERIC(18,3) NULL   CHECK >= 0

NULL sale columns = every pre-loyalty sale stays distinguishable from a
loyalty sale that legitimately earned zero; legacy rows are preserved as
is. Settings carry Python-side defaults only (no seeding INSERT), exactly
like app_settings (0022): ``LoyaltySettingsService`` creates the row on
demand, so Alembic installs and ``create_all`` test databases behave
identically.

Downgrade drops ONLY what this revision added; no data is read or rewritten
by upgrade.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e8f2a4c6d1b9"
down_revision = "f3c8a21d9e05"
branch_labels = None
depends_on = None

UUID_PK_SERVER_DEFAULT = sa.text("gen_random_uuid()")

_EVENT_TYPE_IN_SQL = (
    "event_type IN ("
    "'sale_earn', 'debt_settlement_earn', 'redeem', "
    "'return_clawback', 'void_clawback', 'adjustment', 'expiry'"
    ")"
)


def upgrade() -> None:
    # -- loyalty_settings: singleton rules row (0022 app_settings style) ---
    op.create_table(
        "loyalty_settings",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("points_enabled", sa.Boolean(), nullable=False),
        sa.Column("points_rate", sa.Numeric(18, 6), nullable=False),
        sa.Column("cashback_enabled", sa.Boolean(), nullable=False),
        sa.Column("cashback_rate", sa.Numeric(18, 3), nullable=False),
        sa.Column("point_value", sa.Numeric(18, 3), nullable=False),
        sa.Column("min_redemption_points", sa.Numeric(18, 0), nullable=False),
        sa.Column("max_redemption_percent", sa.Numeric(18, 3), nullable=False),
        sa.Column("earn_on_debt_settlement", sa.Boolean(), nullable=False),
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
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint("id = 1", name="ck_loyalty_settings_singleton"),
        sa.CheckConstraint(
            "points_rate >= 0", name="ck_loyalty_settings_points_rate"
        ),
        sa.CheckConstraint(
            "cashback_rate >= 0", name="ck_loyalty_settings_cashback_rate"
        ),
        sa.CheckConstraint(
            "point_value > 0", name="ck_loyalty_settings_point_value"
        ),
        sa.CheckConstraint(
            "min_redemption_points >= 0",
            name="ck_loyalty_settings_min_redemption_points",
        ),
        sa.CheckConstraint(
            "max_redemption_percent > 0 AND max_redemption_percent <= 100",
            name="ck_loyalty_settings_max_redemption_percent",
        ),
    )

    # -- loyalty_accounts: one row per customer, balances are projections ---
    op.create_table(
        "loyalty_accounts",
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
            "customer_id",
            sa.Uuid(),
            sa.ForeignKey("customers.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "points_balance",
            sa.Numeric(18, 0),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "cashback_balance",
            sa.Numeric(18, 3),
            server_default="0",
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint(
            "points_balance >= 0",
            name="ck_loyalty_accounts_points_balance",
        ),
        sa.CheckConstraint(
            "cashback_balance >= 0",
            name="ck_loyalty_accounts_cashback_balance",
        ),
    )
    op.create_index(
        op.f("ix_loyalty_accounts_id"), "loyalty_accounts", ["id"], unique=False
    )
    op.create_index(
        "ix_loyalty_accounts_customer_id",
        "loyalty_accounts",
        ["customer_id"],
        unique=True,
    )

    # -- sales: nullable loyalty summary (additive, legacy rows untouched) --
    op.add_column(
        "sales",
        sa.Column("loyalty_points_earned", sa.Numeric(18, 0), nullable=True),
    )
    op.add_column(
        "sales",
        sa.Column("loyalty_cashback_earned", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "sales",
        sa.Column("loyalty_points_redeemed", sa.Numeric(18, 0), nullable=True),
    )
    op.add_column(
        "sales",
        sa.Column("loyalty_redeemed_value", sa.Numeric(18, 3), nullable=True),
    )
    op.add_column(
        "sales",
        sa.Column("amount_due", sa.Numeric(18, 3), nullable=True),
    )
    op.create_check_constraint(
        "ck_sales_loyalty_points_earned",
        "sales",
        "loyalty_points_earned >= 0",
    )
    op.create_check_constraint(
        "ck_sales_loyalty_cashback_earned",
        "sales",
        "loyalty_cashback_earned >= 0",
    )
    op.create_check_constraint(
        "ck_sales_loyalty_points_redeemed",
        "sales",
        "loyalty_points_redeemed >= 0",
    )
    op.create_check_constraint(
        "ck_sales_loyalty_redeemed_value",
        "sales",
        "loyalty_redeemed_value >= 0",
    )
    op.create_check_constraint(
        "ck_sales_amount_due",
        "sales",
        "amount_due >= 0",
    )

    # -- loyalty_ledger_entries: append-only, one row per event ------------
    op.create_table(
        "loyalty_ledger_entries",
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
            "account_id",
            sa.Uuid(),
            sa.ForeignKey("loyalty_accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("event_type", sa.String(length=30), nullable=False),
        sa.Column(
            "points_delta",
            sa.Numeric(18, 0),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "cashback_delta",
            sa.Numeric(18, 3),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "balance_after_points",
            sa.Numeric(18, 0),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "balance_after_cashback",
            sa.Numeric(18, 3),
            server_default="0",
            nullable=False,
        ),
        sa.Column("source_event_key", sa.String(length=120), nullable=False),
        sa.Column(
            "sale_id",
            sa.Uuid(),
            sa.ForeignKey("sales.id", ondelete="RESTRICT"),
            nullable=True,
        ),
        sa.Column(
            "return_id",
            sa.Uuid(),
            sa.ForeignKey("returns.id", ondelete="RESTRICT"),
            nullable=True,
        ),
        sa.Column(
            "created_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("note", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint(
            _EVENT_TYPE_IN_SQL,
            name="ck_loyalty_ledger_entries_event_type",
        ),
        sa.CheckConstraint(
            "balance_after_points >= 0",
            name="ck_loyalty_ledger_entries_balance_after_points",
        ),
        sa.CheckConstraint(
            "balance_after_cashback >= 0",
            name="ck_loyalty_ledger_entries_balance_after_cashback",
        ),
    )
    op.create_index(
        op.f("ix_loyalty_ledger_entries_id"),
        "loyalty_ledger_entries",
        ["id"],
        unique=False,
    )
    op.create_index(
        "ix_loyalty_ledger_entries_account_id",
        "loyalty_ledger_entries",
        ["account_id"],
        unique=False,
    )
    op.create_index(
        "ix_loyalty_ledger_entries_source_event_key",
        "loyalty_ledger_entries",
        ["source_event_key"],
        unique=True,
    )
    op.create_index(
        "ix_loyalty_ledger_entries_sale_id",
        "loyalty_ledger_entries",
        ["sale_id"],
        unique=False,
    )
    op.create_index(
        "ix_loyalty_ledger_entries_return_id",
        "loyalty_ledger_entries",
        ["return_id"],
        unique=False,
    )
    op.create_index(
        "ix_loyalty_ledger_entries_account_created",
        "loyalty_ledger_entries",
        ["account_id", "created_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_loyalty_ledger_entries_account_created",
        table_name="loyalty_ledger_entries",
    )
    op.drop_index(
        "ix_loyalty_ledger_entries_return_id",
        table_name="loyalty_ledger_entries",
    )
    op.drop_index(
        "ix_loyalty_ledger_entries_sale_id",
        table_name="loyalty_ledger_entries",
    )
    op.drop_index(
        "ix_loyalty_ledger_entries_source_event_key",
        table_name="loyalty_ledger_entries",
    )
    op.drop_index(
        "ix_loyalty_ledger_entries_account_id",
        table_name="loyalty_ledger_entries",
    )
    op.drop_index(
        op.f("ix_loyalty_ledger_entries_id"), table_name="loyalty_ledger_entries"
    )
    op.drop_table("loyalty_ledger_entries")

    op.drop_constraint(
        "ck_sales_amount_due", "sales", type_="check"
    )
    op.drop_constraint(
        "ck_sales_loyalty_redeemed_value", "sales", type_="check"
    )
    op.drop_constraint(
        "ck_sales_loyalty_points_redeemed", "sales", type_="check"
    )
    op.drop_constraint(
        "ck_sales_loyalty_cashback_earned", "sales", type_="check"
    )
    op.drop_constraint(
        "ck_sales_loyalty_points_earned", "sales", type_="check"
    )
    op.drop_column("sales", "amount_due")
    op.drop_column("sales", "loyalty_redeemed_value")
    op.drop_column("sales", "loyalty_points_redeemed")
    op.drop_column("sales", "loyalty_cashback_earned")
    op.drop_column("sales", "loyalty_points_earned")

    op.drop_index(
        "ix_loyalty_accounts_customer_id", table_name="loyalty_accounts"
    )
    op.drop_index(op.f("ix_loyalty_accounts_id"), table_name="loyalty_accounts")
    op.drop_table("loyalty_accounts")

    op.drop_table("loyalty_settings")
