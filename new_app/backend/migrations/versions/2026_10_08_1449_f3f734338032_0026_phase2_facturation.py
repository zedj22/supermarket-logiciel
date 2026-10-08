"""0026_phase2_facturation

Revision ID: f3f734338032
Revises: 9f2e8c7a4b1d
Create Date: 2026-10-08

Phase 2 (Facturation database foundation) — additive only: creates four
NEW tables, alters NOTHING that exists (no POS/sales/purchase/inventory/
product/customer changes, no column retype anywhere).

1. invoice_clients — fiscal/document clients, ISOLATED from ``customers``
   - id UUID PK (UUIDMixin) + ix_invoice_clients_id
   - name VARCHAR(200) NOT NULL + index (source lists clients by name)
   - address TEXT NULL, wilaya VARCHAR(100) NULL
   - phone VARCHAR(30) NULL + index (lookup field, == customers.phone shape)
   - nif VARCHAR(30) NULL + index, rc VARCHAR(30) NULL + index
     (fiscal lookup/dedup fields; ai/nis stay unindexed — no query path)
   - created_at / updated_at TIMESTAMPTZ (now()), archived_at TIMESTAMPTZ NULL
     — MasterModel soft-archive semantics: no hard delete, NO customer_id,
     NO FK to customers (factura_simple fiscal fields: address/wilaya/
     phone/nif/rc/ai/nis)

2. invoice_documents — ONE shared table for FAC/DEV/PRO/BC/BL
   - id UUID PK + ix_invoice_documents_id
   - doc_type VARCHAR(20) NOT NULL DEFAULT 'FAC'
       CHECK IN ('FAC','DEV','PRO','BC','BL')  (ck_invoice_documents_doc_type)
   - number VARCHAR(50) NOT NULL — format {doc_type}-{year}-{n:04d} from
       invoice_document_counters (Phase 5 allocates; NO server default here,
       NO POS numbering, NO global unique on number alone)
   - UNIQUE (doc_type, number) uq_invoice_documents_doc_type_number — the
       numbering domain is (doc_type, year, number) and the year is embedded
       in the number, so DEV-2026-0001 and FAC-2026-0001 may coexist
   - document_date DATE NOT NULL — stored exactly as supplied, never
       defaulted to server "today"
   - client_id UUID NOT NULL FK invoice_clients(id) ON DELETE RESTRICT
       + ix_invoice_documents_client_id — deleting a client with documents
       must fail (factura_simple answers 409 in the endpoint; the DB
       enforces it here)
   - payment_method VARCHAR(20) NOT NULL DEFAULT 'cash'
       CHECK IN ('cash','transfer','cheque') (ck_invoice_documents_payment_method)
       — factura_simple vocabulary; DISTINCT from the POS PaymentMethod enum
   - notes TEXT NULL
   - show_discount / show_tva / show_timbre / show_payment_method /
       show_amount_words BOOLEAN NOT NULL DEFAULT true — the five
       factura_simple DocumentOptions persisted per document (the source
       stores one JSON blob; typed columns here). show_timbre feeds the
       Phase 1 totals facade; the DATABASE never calculates anything.
   - version INTEGER NOT NULL DEFAULT 1 (DocumentModel optimistic lock)
   - created_at / updated_at TIMESTAMPTZ (now())
   - indexes: document_date, doc_type, (doc_type, document_date)

3. invoice_document_lines — snapshot lines (SaleLine pattern)
   - id UUID PK + ix_invoice_document_lines_id
   - document_id UUID NOT NULL FK invoice_documents(id) ON DELETE CASCADE
       + index — deleting a document cascades its lines
   - product_id UUID NULL FK products(id) ON DELETE SET NULL + index —
       nullable for free-text lines; a deleted product never destroys the
       historical line (SP sale_lines RESTRICT here would be wrong for
       facturation: the brief demands SET NULL)
   - description TEXT NOT NULL, quantity NUMERIC(18,3) NOT NULL DEFAULT 0
       CHECK quantity > 0, unit_price_ht NUMERIC(18,3) NOT NULL DEFAULT 0
       CHECK unit_price_ht >= 0, tva_rate NUMERIC(18,3) NOT NULL (no
       default — Phase 1 always passes an explicit rate; deliberately NOT
       CHECKed against {0,9,19} so the DB never outlives a domain rate
       change), discount_pct NUMERIC(18,3) NOT NULL DEFAULT 0
       CHECK 0 <= discount_pct <= 100, position INTEGER NOT NULL DEFAULT 0
       (authoring order: UUID pids and same-transaction now() cannot order
       lines)
   - created_at / updated_at TIMESTAMPTZ (now())
   - Snapshots are written once at document creation and are independent
       of later products.price / product renames (products.price stays the
       Phase-3 prefill source only; promotions/wholesale/selling-unit/pack/
       valuation prices are never used by facturation)

4. invoice_document_counters — numbering structure ONLY (no allocation
   service in this phase)
   - id UUID PK + ix_invoice_document_counters_id
   - doc_type VARCHAR(20) NOT NULL CHECK IN (...), year INTEGER NOT NULL
       CHECK year > 0, last_number INTEGER NOT NULL DEFAULT 0
       CHECK last_number >= 0
   - UNIQUE (doc_type, year) uq_invoice_document_counters_doc_type_year —
       independent sequences FAC/2026, FAC/2027, DEV/2026, ... and the
       concurrency-safe allocation point for Phase 5 (POS sale counters are
       never reused)

Deliberately absent
-------------------
* NO columns on customers / sales / products — products.price semantics
  untouched, no invoice_products table, no second catalog.
* NO allocation code (naive read/increment is a Phase 5 service concern).
* NO totals/money columns: amounts stay in the Phase 1 domain; lines carry
  inputs only (calc stays app.domain.facturation).
* NO tva_rate value CHECK (Phase 1 TVA_RATES is the authority).

Downgrade drops ONLY what this revision added (reverse dependency order:
counters, lines, documents, clients); upgrade writes no data.
"""

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'f3f734338032'
down_revision = '9f2e8c7a4b1d'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. invoice_clients ----------------------------------------------------
    op.create_table(
        "invoice_clients",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("wilaya", sa.String(length=100), nullable=True),
        sa.Column("phone", sa.String(length=30), nullable=True),
        sa.Column("nif", sa.String(length=30), nullable=True),
        sa.Column("rc", sa.String(length=30), nullable=True),
        sa.Column("ai", sa.String(length=30), nullable=True),
        sa.Column("nis", sa.String(length=30), nullable=True),
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
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_invoice_clients_id"), "invoice_clients", ["id"], unique=False
    )
    op.create_index(
        op.f("ix_invoice_clients_name"), "invoice_clients", ["name"], unique=False
    )
    op.create_index(
        op.f("ix_invoice_clients_phone"), "invoice_clients", ["phone"], unique=False
    )
    op.create_index(op.f("ix_invoice_clients_nif"), "invoice_clients", ["nif"], unique=False)
    op.create_index(op.f("ix_invoice_clients_rc"), "invoice_clients", ["rc"], unique=False)

    # 2. invoice_documents --------------------------------------------------
    op.create_table(
        "invoice_documents",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "doc_type",
            sa.String(length=20),
            server_default="FAC",
            nullable=False,
        ),
        sa.Column("number", sa.String(length=50), nullable=False),
        sa.Column("document_date", sa.Date(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column(
            "payment_method",
            sa.String(length=20),
            server_default="cash",
            nullable=False,
        ),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column(
            "show_discount", sa.Boolean(), server_default="true", nullable=False
        ),
        sa.Column("show_tva", sa.Boolean(), server_default="true", nullable=False),
        sa.Column("show_timbre", sa.Boolean(), server_default="true", nullable=False),
        sa.Column(
            "show_payment_method", sa.Boolean(), server_default="true", nullable=False
        ),
        sa.Column(
            "show_amount_words", sa.Boolean(), server_default="true", nullable=False
        ),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
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
        sa.CheckConstraint(
            "doc_type IN ('FAC', 'DEV', 'PRO', 'BC', 'BL')",
            name="ck_invoice_documents_doc_type",
        ),
        sa.CheckConstraint(
            "payment_method IN ('cash', 'transfer', 'cheque')",
            name="ck_invoice_documents_payment_method",
        ),
        sa.ForeignKeyConstraint(
            ["client_id"], ["invoice_clients.id"], ondelete="RESTRICT"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "doc_type",
            "number",
            name="uq_invoice_documents_doc_type_number",
        ),
    )
    op.create_index(
        op.f("ix_invoice_documents_id"), "invoice_documents", ["id"], unique=False
    )
    op.create_index(
        op.f("ix_invoice_documents_client_id"),
        "invoice_documents",
        ["client_id"],
        unique=False,
    )
    op.create_index(
        "ix_invoice_documents_document_date",
        "invoice_documents",
        ["document_date"],
        unique=False,
    )
    op.create_index(
        "ix_invoice_documents_doc_type",
        "invoice_documents",
        ["doc_type"],
        unique=False,
    )
    op.create_index(
        "ix_invoice_documents_doc_type_document_date",
        "invoice_documents",
        ["doc_type", "document_date"],
        unique=False,
    )

    # 3. invoice_document_lines ---------------------------------------------
    op.create_table(
        "invoice_document_lines",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("document_id", sa.Uuid(), nullable=False),
        sa.Column("product_id", sa.Uuid(), nullable=True),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column(
            "quantity", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
        sa.Column(
            "unit_price_ht", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
        sa.Column("tva_rate", sa.Numeric(18, 3), nullable=False),
        sa.Column(
            "discount_pct", sa.Numeric(18, 3), server_default="0", nullable=False
        ),
        sa.Column("position", sa.Integer(), server_default="0", nullable=False),
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
        sa.CheckConstraint("quantity > 0", name="ck_invoice_document_lines_quantity"),
        sa.CheckConstraint(
            "unit_price_ht >= 0",
            name="ck_invoice_document_lines_unit_price_ht",
        ),
        sa.CheckConstraint(
            "discount_pct >= 0 AND discount_pct <= 100",
            name="ck_invoice_document_lines_discount_pct",
        ),
        sa.ForeignKeyConstraint(
            ["document_id"], ["invoice_documents.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_invoice_document_lines_id"),
        "invoice_document_lines",
        ["id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_invoice_document_lines_document_id"),
        "invoice_document_lines",
        ["document_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_invoice_document_lines_product_id"),
        "invoice_document_lines",
        ["product_id"],
        unique=False,
    )

    # 4. invoice_document_counters ------------------------------------------
    op.create_table(
        "invoice_document_counters",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("doc_type", sa.String(length=20), nullable=False),
        sa.Column("year", sa.Integer(), nullable=False),
        sa.Column("last_number", sa.Integer(), server_default="0", nullable=False),
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
        sa.CheckConstraint(
            "doc_type IN ('FAC', 'DEV', 'PRO', 'BC', 'BL')",
            name="ck_invoice_document_counters_doc_type",
        ),
        sa.CheckConstraint("year > 0", name="ck_invoice_document_counters_year"),
        sa.CheckConstraint(
            "last_number >= 0",
            name="ck_invoice_document_counters_last_number",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "doc_type",
            "year",
            name="uq_invoice_document_counters_doc_type_year",
        ),
    )
    op.create_index(
        op.f("ix_invoice_document_counters_id"),
        "invoice_document_counters",
        ["id"],
        unique=False,
    )


def downgrade() -> None:
    # Reverse dependency order: counters, lines, documents, clients.
    op.drop_index(
        op.f("ix_invoice_document_counters_id"),
        table_name="invoice_document_counters",
    )
    op.drop_table("invoice_document_counters")

    op.drop_index(
        op.f("ix_invoice_document_lines_product_id"),
        table_name="invoice_document_lines",
    )
    op.drop_index(
        op.f("ix_invoice_document_lines_document_id"),
        table_name="invoice_document_lines",
    )
    op.drop_index(
        op.f("ix_invoice_document_lines_id"),
        table_name="invoice_document_lines",
    )
    op.drop_table("invoice_document_lines")

    op.drop_index(
        "ix_invoice_documents_doc_type_document_date",
        table_name="invoice_documents",
    )
    op.drop_index("ix_invoice_documents_doc_type", table_name="invoice_documents")
    op.drop_index("ix_invoice_documents_document_date", table_name="invoice_documents")
    op.drop_index(
        op.f("ix_invoice_documents_client_id"),
        table_name="invoice_documents",
    )
    op.drop_index(op.f("ix_invoice_documents_id"), table_name="invoice_documents")
    op.drop_table("invoice_documents")

    op.drop_index(op.f("ix_invoice_clients_rc"), table_name="invoice_clients")
    op.drop_index(op.f("ix_invoice_clients_nif"), table_name="invoice_clients")
    op.drop_index(op.f("ix_invoice_clients_phone"), table_name="invoice_clients")
    op.drop_index(op.f("ix_invoice_clients_name"), table_name="invoice_clients")
    op.drop_index(op.f("ix_invoice_clients_id"), table_name="invoice_clients")
    op.drop_table("invoice_clients")
