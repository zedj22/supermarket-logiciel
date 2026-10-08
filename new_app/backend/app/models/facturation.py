"""Facturation models (Phase 2 — database foundation).

Tables: invoice_clients, invoice_documents, invoice_document_lines,
        invoice_document_counters

Isolation (Phase 0/2 integration decisions — hard rules)
--------------------------------------------------------
- ``invoice_clients`` is a SEPARATE fiscal/document client domain. It is
  never FK-linked to ``customers`` (no ``customer_id`` here): a document
  client carries fiscal identity (NIF / RC / AI / NIS), a Supermarket Pro
  customer is the POS debt master. The two coexist without sharing rows
  and neither table references the other.
- Numbering is a SEPARATE domain from POS sales:
  ``invoice_document_counters`` sequences per (doc_type, year) and NEVER
  touches ``sales.invoice_number`` (no shared counter, no shared format).

Snapshot rules (invoice lines are historical records)
-----------------------------------------------------
- ``description`` / ``quantity`` / ``unit_price_ht`` / ``tva_rate`` /
  ``discount_pct`` are snapshotted on the line and never re-read from the
  product afterwards: the invoice must not depend on the current product
  price after creation.
- ``product_id`` is a nullable convenience link with ON DELETE SET NULL:
  free-text lines keep ``product_id = NULL``, and deleting a product never
  destroys an invoice line. There is NO second invoice product catalog —
  ``products`` stays the single catalog.
- ``products.price`` is the default HT unit price when PREFILLING a line
  (Phase 3+ interpretation only): promotion / wholesale / selling-unit /
  pack / inventory-valuation prices are NEVER used for facturation, and
  ``products.price`` semantics are not modified globally.

factura_simple parity (source: models.py + main.py, re-read in Phase 2)
-----------------------------------------------------------------------
- Vocabulary: ``doc_type`` ∈ {FAC, DEV, PRO, BC, BL},
  ``payment_method`` ∈ {cash, transfer, cheque} (the POS PaymentMethod
  enum — cash/card/credit/partial — is a different domain).
- Numbering identity is the EXPLICIT triple ``(doc_type, year, number)``
  (UNIQUE constraint): the numbering year is a stored column, never
  inferred from ``document_date`` — the database itself distinguishes
  FAC/2026/0001 from FAC/2027/0001 and from DEV/2026/0001. Phase 5
  allocates ``number`` per (doc_type, year) from the counter row and
  renders ``{doc_type}-{year}-{n:04d}``; ``document_date`` remains the
  authoritative document date, stored as given (the source never
  replaces it with server "today" on read).
- The five ``show_*`` document options persist per document (the source
  stores them as one JSON blob; here they are typed boolean columns).
  ``show_timbre`` feeds the Phase 1 totals facade
  (``calculate_document_totals(..., show_timbre=...)``) — the database
  stores the flag but NEVER performs any calculation.
- Deleting a client that still has documents is rejected: the source
  answers 409 in the endpoint, here FK RESTRICT enforces it in the DB.

Scope of DB constraints
-----------------------
Constraints guard obvious data corruption only (qty > 0, price >= 0,
0 <= discount <= 100, counter year/last_number bounds, document
``year > 0``, vocabulary IN-lists, a number issued at most once per
``(doc_type, year)``). Phase 1 (``app.domain.facturation``) remains the
calculation/validation authority — notably ``tva_rate`` is NOT pinned to
{0, 9, 19} here so the database never outlives a domain rate change.
"""

import uuid
from datetime import date

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import (
    Base,
    DocumentModel,
    MasterModel,
    TimestampMixin,
    UUIDMixin,
    numeric_money,
    numeric_quantity,
)
from app.models.enums import InvoiceDocType, InvoicePaymentMethod

#: Shared doc_type vocabulary guard (stable five-value set).
_DOC_TYPE_CHECK = "doc_type IN ('FAC', 'DEV', 'PRO', 'BC', 'BL')"


class InvoiceClient(MasterModel):
    """Fiscal/document client — isolated from the POS Customer domain.

    Archive semantics (MasterModel ``archived_at``) match the project:
    clients are soft-archived, never hard-deleted while referenced
    (FK RESTRICT on ``invoice_documents.client_id`` keeps history intact).
    """

    __tablename__ = "invoice_clients"

    # Required identity — factura_simple: name is the only required field.
    name: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    # Fiscal/contact fields are all OPTIONAL: not every document client
    # carries every identifier (factura_simple defaults them to "").
    address: Mapped[str | None] = mapped_column(Text)
    wilaya: Mapped[str | None] = mapped_column(String(100))
    phone: Mapped[str | None] = mapped_column(String(30), index=True)
    nif: Mapped[str | None] = mapped_column(String(30), index=True)
    rc: Mapped[str | None] = mapped_column(String(30), index=True)
    ai: Mapped[str | None] = mapped_column(String(30))
    nis: Mapped[str | None] = mapped_column(String(30))

    # Relationships — documents are RESTRICTed, never cascade-deleted.
    documents: Mapped[list["InvoiceDocument"]] = relationship(
        "InvoiceDocument",
        back_populates="client",
        lazy="noload",
    )


class InvoiceDocument(DocumentModel):
    """One facturation document: FAC / DEV / PRO / BC / BL (shared table)."""

    __tablename__ = "invoice_documents"
    __table_args__ = (
        CheckConstraint(_DOC_TYPE_CHECK, name="ck_invoice_documents_doc_type"),
        CheckConstraint(
            "payment_method IN ('cash', 'transfer', 'cheque')",
            name="ck_invoice_documents_payment_method",
        ),
        # Numbering identity is the stored triple (doc_type, year, number):
        # a serial may repeat across years (FAC/2026/0001 vs FAC/2027/0001)
        # and across doc_types (FAC/2026/0001 vs DEV/2026/0001) but never
        # within the same (doc_type, year). ``year`` is an explicit column —
        # the rule never infers it from ``document_date``.
        UniqueConstraint(
            "doc_type",
            "year",
            "number",
            name="uq_invoice_documents_doc_type_year_number",
        ),
        CheckConstraint("year > 0", name="ck_invoice_documents_year"),
        Index("ix_invoice_documents_document_date", "document_date"),
        Index("ix_invoice_documents_doc_type", "doc_type"),
        Index(
            "ix_invoice_documents_doc_type_document_date",
            "doc_type",
            "document_date",
        ),
    )

    doc_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=InvoiceDocType.FAC.value,
        server_default=InvoiceDocType.FAC.value,
    )
    # Serial portion of the numbering identity, unique per (doc_type, year).
    # Phase 5 allocates it from invoice_document_counters — no server
    # default here (and deliberately NO global unique on number alone).
    number: Mapped[str] = mapped_column(String(50), nullable=False)
    # Numbering year of the (doc_type, year, number) identity — stored
    # explicitly so uniqueness never infers it from document_date.
    # NOT NULL, CHECK year > 0 (ck_invoice_documents_year), no server
    # default: Phase 5 supplies it alongside the counter allocation.
    year: Mapped[int] = mapped_column(Integer, nullable=False)
    # Stored exactly as supplied — never defaulted to server today.
    # Authoritative for the actual document date ONLY (see ``year`` above).
    document_date: Mapped[date] = mapped_column(Date, nullable=False)
    client_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("invoice_clients.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    payment_method: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default=InvoicePaymentMethod.CASH.value,
        server_default=InvoicePaymentMethod.CASH.value,
    )
    notes: Mapped[str | None] = mapped_column(Text)

    # Display/document options (factura_simple DocumentOptions). Typed
    # booleans instead of the source's JSON blob; defaults mirror
    # DocumentOptions (all True). show_timbre drives Phase 1 totals.
    show_discount: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )
    show_tva: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )
    show_timbre: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )
    show_payment_method: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )
    show_amount_words: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )

    # Relationships
    client: Mapped["InvoiceClient"] = relationship(
        "InvoiceClient",
        back_populates="documents",
        lazy="selectin",
    )
    lines: Mapped[list["InvoiceDocumentLine"]] = relationship(
        "InvoiceDocumentLine",
        back_populates="document",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class InvoiceDocumentLine(Base, UUIDMixin, TimestampMixin):
    """Immutable-ish invoice line snapshot (SaleLine pattern)."""

    __tablename__ = "invoice_document_lines"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="ck_invoice_document_lines_quantity"),
        CheckConstraint(
            "unit_price_ht >= 0",
            name="ck_invoice_document_lines_unit_price_ht",
        ),
        CheckConstraint(
            "discount_pct >= 0 AND discount_pct <= 100",
            name="ck_invoice_document_lines_discount_pct",
        ),
    )

    document_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("invoice_documents.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    # Nullable on purpose: free-text lines have no product, and
    # ON DELETE SET NULL keeps the line valid after a product deletion.
    product_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("products.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # Snapshots — historical data survives product renames/archives.
    description: Mapped[str] = mapped_column(Text, nullable=False)
    quantity: Mapped[float] = numeric_quantity()
    unit_price_ht: Mapped[float] = numeric_money()
    # No default: Phase 1 FactureLine always carries an explicit rate.
    tva_rate: Mapped[float] = mapped_column(Numeric(18, 3), nullable=False)
    discount_pct: Mapped[float] = mapped_column(
        Numeric(18, 3),
        nullable=False,
        default=0,
        server_default="0",
    )
    # Explicit line order: UUID pids and same-transaction now() timestamps
    # cannot order lines, and invoice rendering needs the authoring order.
    position: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )

    # Relationships
    document: Mapped["InvoiceDocument"] = relationship(
        "InvoiceDocument",
        back_populates="lines",
        lazy="selectin",
    )
    product: Mapped["Product | None"] = relationship(  # noqa: F821
        "Product",
        lazy="selectin",
    )


class InvoiceDocumentCounter(Base, UUIDMixin, TimestampMixin):
    """Independent sequential numbering per (doc_type, year).

    Structure only (Phase 5 allocates): UNIQUE(doc_type, year) guarantees
    the concurrency-safe allocation point — no naive read/increment code
    here, and POS sale counters are never reused.
    """

    __tablename__ = "invoice_document_counters"
    __table_args__ = (
        UniqueConstraint(
            "doc_type",
            "year",
            name="uq_invoice_document_counters_doc_type_year",
        ),
        CheckConstraint(_DOC_TYPE_CHECK, name="ck_invoice_document_counters_doc_type"),
        CheckConstraint("year > 0", name="ck_invoice_document_counters_year"),
        CheckConstraint(
            "last_number >= 0",
            name="ck_invoice_document_counters_last_number",
        ),
    )

    doc_type: Mapped[str] = mapped_column(String(20), nullable=False)
    year: Mapped[int] = mapped_column(Integer, nullable=False)
    last_number: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )
