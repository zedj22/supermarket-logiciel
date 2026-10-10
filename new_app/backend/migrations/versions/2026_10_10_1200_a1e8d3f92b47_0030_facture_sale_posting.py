"""0030_facture_sale_posting

Revision ID: a1e8d3f92b47
Revises: c9d4e2a7f1b6
Create Date: 2026-10-10

Optional sale posting — additive only: two NEW nullable columns on
``invoice_documents`` linking a posted FAC document to the POS sale it
created (no other table changes, no backfill, no POS schema changes).

1. sale_id UUID NULL FK sales(id) ON DELETE SET NULL + unique constraint
2. posted_at TIMESTAMPTZ NULL

Semantics
---------
* ``sale_id`` is the ONE-WAY link from a Facturation FAC document to the
  authoritative POS sale created via ``SaleService.create_sale``. The
  POS sale's ``client_request_id`` is ``facture:{document_id}`` — a second
  POST can never create a duplicate sale (SaleService idempotency).
* ``posted_at`` records when the document was posted (audit display).
* ON DELETE SET NULL keeps the fiscal document valid if a POS sale row
  is ever removed (never done by the app — historical fiscal records).
* Only FAC documents are posted; DEV/PRO/BC/BL remain document-only
  (the service layer enforces eligibility — no DB CHECK so the domain
  stays the authority, same policy as tva_rate / doc_type combinations).
* No unpost endpoint exists; reversal is via the existing POS void /
  return workflow. Unchecking "Register as Sale" after posting is a
  no-op on the server side.

Deliberately absent
-------------------
* NO backfill: historical documents are NEVER auto-posted.
* NO sale-side columns (the sales.client_request_id idempotency key
  already provides the reverse lookup and uniqueness).

Downgrade drops ONLY what this revision added.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision = "a1e8d3f92b47"
down_revision = "c9d4e2a7f1b6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "invoice_documents",
        sa.Column("sale_id", sa.Uuid(), nullable=True),
    )
    op.add_column(
        "invoice_documents",
        sa.Column("posted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_foreign_key(
        "fk_invoice_documents_sale_id_sales",
        "invoice_documents",
        "sales",
        ["sale_id"],
        ["id"],
        ondelete="SET NULL",
    )
    # unique=True, index=True on the model emits a UNIQUE index, not a
    # separate UniqueConstraint — match that exactly so alembic check
    # reports no drift.
    op.create_index(
        "ix_invoice_documents_sale_id",
        "invoice_documents",
        ["sale_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_invoice_documents_sale_id",
        table_name="invoice_documents",
    )
    op.drop_constraint(
        "fk_invoice_documents_sale_id_sales",
        "invoice_documents",
        type_="foreignkey",
    )
    op.drop_column("invoice_documents", "posted_at")
    op.drop_column("invoice_documents", "sale_id")
