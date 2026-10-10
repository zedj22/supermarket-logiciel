"""0029_facturation_option_identity

Revision ID: c9d4e2a7f1b6
Revises: 2dbe2160afb5
Create Date: 2026-10-10

Stage 3A (Facturation option identity) — additive only: three NEW
nullable UUID columns on ``invoice_document_lines``, alters NOTHING that
exists (no POS/sales/catalog/product changes, no column retype, no
backfill).

1. variant_id UUID NULL FK product_variants(id) ON DELETE SET NULL
   + ix_invoice_document_lines_variant_id
2. selling_unit_id UUID NULL FK product_selling_units(id) ON DELETE
   SET NULL + ix_invoice_document_lines_selling_unit_id
3. pack_id UUID NULL FK packs(id) ON DELETE SET NULL
   + ix_invoice_document_lines_pack_id

Semantics
---------
* Traceability links ONLY. Pricing, totals, printing and stock never
  re-resolve them — the stored description / unit_price_ht snapshots
  stay the printable truth (SaleLine snapshot pattern).
* All three are nullable with ON DELETE SET NULL, mirroring the existing
  ``product_id`` column (0026): a deleted catalog option never destroys
  a historical fiscal line.
* The service layer validates combinations (variant XOR selling unit;
  pack lines carry pack_id alone) — no DB CHECK is added so the domain
  stays the single authority (same policy as tva_rate in 0026).

Deliberately absent
-------------------
* NO name/multiplier snapshot columns (the description snapshot already
  carries the printed option text; facturation never converts quantity
  to base units).
* NO data migration: existing rows keep NULL in all three columns.
* NO stock, pricing or totals columns.

Downgrade drops ONLY what this revision added; upgrade writes no data.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "c9d4e2a7f1b6"
down_revision = "2dbe2160afb5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "invoice_document_lines",
        sa.Column("variant_id", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "invoice_document_lines",
        sa.Column("selling_unit_id", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "invoice_document_lines",
        sa.Column("pack_id", sa.Uuid(), nullable=True),
    )
    op.create_foreign_key(
        "fk_invoice_document_lines_variant_id_product_variants",
        "invoice_document_lines",
        "product_variants",
        ["variant_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_foreign_key(
        "fk_invoice_document_lines_selling_unit_id_product_selling_units",
        "invoice_document_lines",
        "product_selling_units",
        ["selling_unit_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_foreign_key(
        "fk_invoice_document_lines_pack_id_packs",
        "invoice_document_lines",
        "packs",
        ["pack_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_invoice_document_lines_variant_id",
        "invoice_document_lines",
        ["variant_id"],
    )
    op.create_index(
        "ix_invoice_document_lines_selling_unit_id",
        "invoice_document_lines",
        ["selling_unit_id"],
    )
    op.create_index(
        "ix_invoice_document_lines_pack_id",
        "invoice_document_lines",
        ["pack_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_invoice_document_lines_pack_id",
        table_name="invoice_document_lines",
    )
    op.drop_index(
        "ix_invoice_document_lines_selling_unit_id",
        table_name="invoice_document_lines",
    )
    op.drop_index(
        "ix_invoice_document_lines_variant_id",
        table_name="invoice_document_lines",
    )
    op.drop_constraint(
        "fk_invoice_document_lines_pack_id_packs",
        "invoice_document_lines",
        type_="foreignkey",
    )
    op.drop_constraint(
        "fk_invoice_document_lines_selling_unit_id_product_selling_units",
        "invoice_document_lines",
        type_="foreignkey",
    )
    op.drop_constraint(
        "fk_invoice_document_lines_variant_id_product_variants",
        "invoice_document_lines",
        type_="foreignkey",
    )
    op.drop_column("invoice_document_lines", "pack_id")
    op.drop_column("invoice_document_lines", "selling_unit_id")
    op.drop_column("invoice_document_lines", "variant_id")
