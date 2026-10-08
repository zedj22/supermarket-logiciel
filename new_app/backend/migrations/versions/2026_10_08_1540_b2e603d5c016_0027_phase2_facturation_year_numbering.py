"""0027_phase2_facturation_year_numbering

Revision ID: b2e603d5c016
Revises: f3f734338032
Create Date: 2026-10-08

Phase 2 review fix — the numbering year becomes an explicit column.

0026 created invoice_documents with UNIQUE (doc_type, number) while the
documented numbering domain is the triple (doc_type, year, number). The
year existed only implicitly (rendered inside the number string / to be
inferred from document_date) — an application-only convention the
database itself could not enforce. This corrective migration makes the
invariant structural:

- adds invoice_documents.year INTEGER NOT NULL
    CHECK year > 0 (ck_invoice_documents_year), NO server default
- replaces uq_invoice_documents_doc_type_number (doc_type, number)
  with uq_invoice_documents_doc_type_year_number (doc_type, year, number)

The facturation tables contain ZERO rows at this point (development
state, verified on both databases before this revision): the column is
added directly as NOT NULL — no backfill, no temporary server default,
no table rebuild. document_date is untouched (it stays authoritative
for the actual document date only; year is the numbering year).

Downgrade reverses exactly these operations and restores the 0026
state. Migration 0026 itself is never edited.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'b2e603d5c016'
down_revision = 'f3f734338032'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. Explicit numbering year (table is empty: direct NOT NULL add).
    op.add_column(
        "invoice_documents",
        sa.Column("year", sa.Integer(), nullable=False),
    )

    # 2. year > 0 — same bounds as invoice_document_counters.year.
    op.create_check_constraint(
        "ck_invoice_documents_year",
        "invoice_documents",
        "year > 0",
    )

    # 3. Numbering identity becomes (doc_type, year, number).
    op.drop_constraint(
        "uq_invoice_documents_doc_type_number",
        "invoice_documents",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_invoice_documents_doc_type_year_number",
        "invoice_documents",
        ["doc_type", "year", "number"],
    )


def downgrade() -> None:
    # Reverse order: restore the 0026 unique, drop the check, drop the column.
    op.drop_constraint(
        "uq_invoice_documents_doc_type_year_number",
        "invoice_documents",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_invoice_documents_doc_type_number",
        "invoice_documents",
        ["doc_type", "number"],
    )
    op.drop_constraint(
        "ck_invoice_documents_year",
        "invoice_documents",
        type_="check",
    )
    op.drop_column("invoice_documents", "year")
