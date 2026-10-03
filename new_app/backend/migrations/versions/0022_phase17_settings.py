"""0022_phase17_settings

Revision ID: e7d4a9c1f3b6
Revises: b7f3c2d91a04
Create Date: 2026-10-03

Phase 17 (§17.1 settings foundation) — ONE new table, nothing else touched.

Why a table is objectively necessary
------------------------------------
Every Phase 15 receipt/export field an owner must be able to change
(store phone, address, invoice footer, auto-print/ask-before-print, default
paper) and every POS rule the *backend* enforces (``allow_debt``,
``low_stock_threshold``) had no persistence at all: Phase 15 shipped
receipts with a name only because "there is no settings table until Phase
17" (``app/models/device.py:8``, ``server_identity.py:6``, ``0021``:48).
Storing them in a JSON file outside the database would leave them out of
the ``pg_dump`` backups Phase 17 §17.2 produces, so they would silently
disappear on restore.

app_settings
   id                     INTEGER PK — always 1 (singleton, CHECK-enforced)
   store_name             VARCHAR(120)  NOT NULL   receipt/export header
   store_phone            VARCHAR(40)   NOT NULL   '' until an owner sets it
   store_address          VARCHAR(255)  NOT NULL   '' until an owner sets it
   invoice_footer         VARCHAR(255)  NOT NULL   '' = no footer line
   default_paper          VARCHAR(10)   NOT NULL   '80mm' | 'A4'  (CHECK)
   ask_before_print       BOOLEAN       NOT NULL   default false
   auto_print_invoice     BOOLEAN       NOT NULL   default false
   allow_debt             BOOLEAN       NOT NULL   default true
   low_stock_threshold    INTEGER       NOT NULL   default 5, CHECK >= 0
   created_at / updated_at             TIMESTAMPTZ, from TimestampMixin

Deliberately absent
-------------------
* NO ``language`` / ``theme_mode`` columns — those are user/session
  preferences that live in Flutter SharedPreferences (``app_locale``,
  ``app_theme_mode``).  Mirroring them here would create a second,
  conflicting settings system.
* NO seeding INSERT.  ``app_settings`` is created on demand by
  ``SettingsService`` so that Alembic installs and in-memory test databases
  (``Base.metadata.create_all``) behave identically.  ``store_name``
  defaults to the ``STORE_NAME`` environment value, which is what Phase 15
  already renders today — behaviour is unchanged for an existing install.
* NO foreign keys, NO indexes beyond the primary key (single row).

Downgrade drops ONLY what this revision added; no data is read or rewritten
by upgrade.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'e7d4a9c1f3b6'
down_revision = 'b7f3c2d91a04'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "app_settings",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("store_name", sa.String(length=120), nullable=False),
        sa.Column("store_phone", sa.String(length=40), nullable=False),
        sa.Column("store_address", sa.String(length=255), nullable=False),
        sa.Column("invoice_footer", sa.String(length=255), nullable=False),
        sa.Column("default_paper", sa.String(length=10), nullable=False),
        sa.Column("ask_before_print", sa.Boolean(), nullable=False),
        sa.Column("auto_print_invoice", sa.Boolean(), nullable=False),
        sa.Column("allow_debt", sa.Boolean(), nullable=False),
        sa.Column("low_stock_threshold", sa.Integer(), nullable=False),
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
        sa.CheckConstraint(
            "default_paper IN ('80mm', 'A4')",
            name="ck_app_settings_default_paper",
        ),
        sa.CheckConstraint(
            "low_stock_threshold >= 0",
            name="ck_app_settings_low_stock_threshold",
        ),
        sa.CheckConstraint("id = 1", name="ck_app_settings_singleton"),
    )


def downgrade() -> None:
    op.drop_table("app_settings")
