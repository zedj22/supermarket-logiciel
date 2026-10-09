"""0028_phase6_facturation_settings

Revision ID: 2dbe2160afb5
Revises: b2e603d5c016
Create Date: 2026-10-09

Phase 6 (facturation company/fiscal foundation) — SEVEN columns on the
EXISTING ``app_settings`` singleton; no new table, no second settings
system, no data rewrite of any other column.

What a future invoice header must render and where it comes from
-----------------------------------------------------------------
factura_simple keeps a ``Company`` singleton (``name, address, wilaya,
phone, email, rc, nif, ai, nis, rib``) whose values the DOCX header
and the Flutter PDF/preview print.  Supermarket Pro already owns
name/address/phone: they are ``store_name`` / ``store_address`` /
``store_phone`` (Phase 17).  Only the remaining fields were missing:

    store_wilaya  VARCHAR(100)  NOT NULL  DEFAULT model-side ''   wilaya line
    store_email   VARCHAR(100)  NOT NULL  DEFAULT model-side ''   e-mail line
    store_nif     VARCHAR(30)   NOT NULL  DEFAULT model-side ''   NIF
    store_nis     VARCHAR(30)   NOT NULL  DEFAULT model-side ''   NIS
    store_rc      VARCHAR(30)   NOT NULL  DEFAULT model-side ''   RC
    store_ai      VARCHAR(30)   NOT NULL  DEFAULT model-side ''   AI
    store_rib     VARCHAR(30)   NOT NULL  DEFAULT model-side ''   RIB/CCP

Deliberately absent
-------------------
* NO ``company_*`` / duplicate name+address+phone columns — Phase 6 maps
  them to the store_* columns and only ADDS what does not exist yet.
* NO second table, NO second endpoint: ``GET/PUT /api/v1/settings`` with
  ``settings_manage`` on write stays the single API surface, and
  ``SettingsService`` stays the single audited write path (Phase 6
  facturation only reads, via ``get_facturation_company_settings``).
* NO format CHECK constraints (no NIF/RC regex): neither factura_simple
  nor ``invoice_clients`` defines one, and every field is optional in the
  source (``str = ""``), so '' is the model default everywhere.
* NO default TVA / timbre / paper settings — Phase 1 calculation rules
  (``app.domain.facturation``) stay authoritative and no setting may
  override them.
* NO seed INSERT: like 0022, the singleton row is created on demand by
  ``SettingsService``, so Alembic installs and ``create_all`` test
  databases behave identically.

Existing rows: the columns are added NOT NULL with a temporary server
default of '' so an already-populated ``app_settings`` row is backfilled
in the same statement; the default is then dropped so the final DDL
matches ``Base.metadata.create_all`` exactly (model-side default only,
no server default).  Value columns keep the existing columns untouched.

Downgrade drops only the seven columns (their values are lost — that is
the whole point of a downgrade); 0027 and every earlier revision are
untouched.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '2dbe2160afb5'
down_revision = 'b2e603d5c016'
branch_labels = None
depends_on = None

# (column name, length) — order mirrors app/models/settings.py.
_NEW_COLUMNS: tuple[tuple[str, int], ...] = (
    ("store_wilaya", 100),
    ("store_email", 100),
    ("store_nif", 30),
    ("store_nis", 30),
    ("store_rc", 30),
    ("store_ai", 30),
    ("store_rib", 30),
)


def upgrade() -> None:
    for name, length in _NEW_COLUMNS:
        # Temporary DEFAULT '' backfills an existing singleton row
        # (ADD COLUMN ... NOT NULL requires it), then it is dropped so the
        # migrated schema is byte-for-byte what create_all produces.
        op.add_column(
            "app_settings",
            sa.Column(
                name,
                sa.String(length=length),
                nullable=False,
                server_default="",
            ),
        )
        op.alter_column("app_settings", name, server_default=None)


def downgrade() -> None:
    for name, _length in reversed(_NEW_COLUMNS):
        op.drop_column("app_settings", name)
