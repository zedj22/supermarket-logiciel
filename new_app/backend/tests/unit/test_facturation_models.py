"""Facturation model / database tests (Phase 2).

SQLite in-memory with ``PRAGMA foreign_keys=ON`` so ON DELETE behaviour
(RESTRICT / CASCADE / SET NULL) and CHECK constraints are actually
enforced — the shared conftest engine leaves FK enforcement off, which
would silently pass broken FK tests, hence the dedicated engine here.

Covers the 15 required database-level scenarios plus enum/domain parity.
The PostgreSQL migration upgrade/smoke/downgrade lives in
``tests/integration/test_phase2_facturation_migration.py``.
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, delete, event, func, inspect, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.domain.facturation import DOC_TYPES, PAYMENT_METHODS
from app.models import Product
from app.models.enums import InvoiceDocType, InvoicePaymentMethod
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
    InvoiceDocumentLine,
)

# ── Fixtures ───────────────────────────────────────────────────────────


@pytest.fixture()
def engine():
    """Fresh in-memory SQLite schema with FK enforcement ON."""
    eng = create_fk_engine()
    yield eng
    Base.metadata.drop_all(bind=eng)
    eng.dispose()


def create_fk_engine():
    eng = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    @event.listens_for(eng, "connect")
    def _fk_on(dbapi_connection, _connection_record):  # noqa: ANN001
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    Base.metadata.create_all(bind=eng)
    return eng


@pytest.fixture()
def db(engine):
    """Session bound to the FK-enforcing engine; rolls back on teardown."""
    session = sessionmaker(bind=engine)()
    yield session
    session.rollback()
    session.close()


# ── Helpers ────────────────────────────────────────────────────────────


def _client(db, name: str = "SARL Test") -> InvoiceClient:
    row = InvoiceClient(name=name, nif="000123456789012")
    db.add(row)
    db.flush()
    return row


def _document(db, client: InvoiceClient, **overrides) -> InvoiceDocument:
    values = dict(
        number="0001",
        year=2026,
        document_date=date(2026, 10, 8),
        client_id=client.id,
    )
    values.update(overrides)
    row = InvoiceDocument(**values)
    db.add(row)
    db.flush()
    return row


def _line(document: InvoiceDocument, **overrides) -> InvoiceDocumentLine:
    values = dict(
        document_id=document.id,
        description="Line under test",
        quantity=Decimal("1"),
        unit_price_ht=Decimal("10.000"),
        tva_rate=Decimal("19"),
        discount_pct=Decimal("0"),
        position=0,
    )
    values.update(overrides)
    return InvoiceDocumentLine(**values)


def _count(db, model) -> int:  # noqa: ANN001
    return db.scalar(select(func.count()).select_from(model))


# ── 1. invoice client creation ─────────────────────────────────────────


def test_invoice_client_creation(db):
    row = InvoiceClient(
        name="Entreprise Demo",
        address="12 Rue Didouche Mourad",
        wilaya="Alger",
        phone="0555123456",
        nif="099887766554433",
        rc="16/00-1234567 B 21",
        ai="AI-1",
        nis="0998877665",
    )
    db.add(row)
    db.flush()
    db.refresh(row)

    assert row.id is not None and isinstance(row.id, uuid.UUID)
    assert row.name == "Entreprise Demo"
    assert row.wilaya == "Alger"
    assert row.nif == "099887766554433"
    assert row.rc == "16/00-1234567 B 21"
    # Soft archive semantics (MasterModel), not hard deletion.
    assert row.archived_at is None
    assert row.is_archived is False
    assert row.created_at is not None
    assert row.updated_at is not None


def test_invoice_client_fiscal_fields_are_optional(db):
    row = InvoiceClient(name="Minimal Client")
    db.add(row)
    db.flush()
    db.refresh(row)
    assert row.phone is None
    assert row.nif is None
    assert row.rc is None
    assert row.address is None


def test_invoice_client_requires_name(db):
    db.add(InvoiceClient())
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


# ── 2. invoice document creation ───────────────────────────────────────


def test_invoice_document_creation_and_factura_defaults(db):
    client = _client(db)
    doc = InvoiceDocument(
        number="0001",
        year=2026,
        document_date=date(2026, 1, 15),
        client_id=client.id,
    )
    db.add(doc)
    db.flush()
    db.refresh(doc)

    # factura_simple defaults: FAC / cash / all options true.
    assert doc.doc_type == "FAC"
    assert doc.payment_method == "cash"
    assert doc.show_discount is True
    assert doc.show_tva is True
    assert doc.show_timbre is True
    assert doc.show_payment_method is True
    assert doc.show_amount_words is True
    assert doc.version == 1
    # The stored numbering year — explicit, never derived from the date.
    assert doc.year == 2026
    # The stored date is preserved exactly — never replaced by "today".
    assert doc.document_date == date(2026, 1, 15)
    assert doc.number == "0001"
    assert doc.notes is None
    assert doc.created_at is not None


def test_invoice_document_show_flags_are_storable_false(db):
    client = _client(db)
    doc = _document(
        db,
        client,
        number="0001",
        doc_type="DEV",
        payment_method="transfer",
        show_timbre=False,
        show_amount_words=False,
        notes="sans timbre",
    )
    db.refresh(doc)
    assert doc.doc_type == "DEV"
    assert doc.payment_method == "transfer"
    assert doc.show_timbre is False
    assert doc.show_amount_words is False
    assert doc.show_tva is True  # untouched flag keeps its default
    assert doc.notes == "sans timbre"


# ── 3. document -> invoice_client FK ───────────────────────────────────


def test_document_to_client_foreign_key(db):
    client = _client(db, "Client FK")
    doc = _document(db, client)

    stored_client_id = db.scalar(
        select(InvoiceDocument.client_id).where(InvoiceDocument.id == doc.id)
    )
    assert stored_client_id == client.id
    # ORM relationship resolves the same row (client side is lazy="noload"
    # by project convention — no reverse-loading of all client documents).
    assert doc.client is client


# ── 4. line -> document FK ─────────────────────────────────────────────


def test_line_to_document_foreign_key(db):
    client = _client(db)
    doc = _document(db, client)
    line = _line(doc, description="First item")
    db.add(line)
    db.flush()

    stored = db.scalar(
        select(InvoiceDocumentLine.document_id).where(InvoiceDocumentLine.id == line.id)
    )
    assert stored == doc.id
    assert line.document is doc
    assert doc.lines[0] is line


# ── 5. document deletion cascades to lines ─────────────────────────────


def test_document_deletion_cascades_to_lines(db):
    client = _client(db)
    doc = _document(db, client)
    db.add(_line(doc, position=0))
    db.add(_line(doc, description="Second", position=1))
    db.flush()
    assert _count(db, InvoiceDocumentLine) == 2

    # RAW delete: proves the DB-level ON DELETE CASCADE, not ORM cascade.
    db.execute(delete(InvoiceDocument).where(InvoiceDocument.id == doc.id))
    db.flush()

    assert _count(db, InvoiceDocument) == 0
    assert _count(db, InvoiceDocumentLine) == 0
    # The client survives (documents are not master data).
    assert _count(db, InvoiceClient) == 1


# ── 6. deleting a referenced client is rejected ────────────────────────


def test_deleting_referenced_client_is_restricted(db):
    used = _client(db, "Used Client")
    unused = _client(db, "Unused Client")
    _document(db, used)
    db.flush()

    # The referenced one is rejected by FK RESTRICT — invoices never vanish
    # silently with their client (factura_simple: HTTP 409 in the endpoint).
    # Savepoint: the rejection must not destroy anything either.
    with pytest.raises(IntegrityError):
        with db.begin_nested():
            db.execute(delete(InvoiceClient).where(InvoiceClient.id == used.id))
    # Only the savepoint rolled back: both clients and the document survive.
    assert _count(db, InvoiceClient) == 2
    assert _count(db, InvoiceDocument) == 1

    # An unreferenced client can still be deleted (archive is app policy).
    db.execute(delete(InvoiceClient).where(InvoiceClient.id == unused.id))
    db.flush()
    assert _count(db, InvoiceClient) == 1
    assert _count(db, InvoiceDocument) == 1


# ── 7. free-text line: product_id NULL ─────────────────────────────────


def test_line_product_id_can_be_null(db):
    client = _client(db)
    doc = _document(db, client)
    line = _line(doc, description="Free text line")
    db.add(line)
    db.flush()
    db.refresh(line)

    assert line.product_id is None
    assert line.product is None
    # Snapshots still fully present without a product.
    assert line.description == "Free text line"
    assert line.unit_price_ht == Decimal("10.000")
    assert line.tva_rate == Decimal("19")
    assert line.discount_pct == Decimal("0")


# ── 8. line references an existing Supermarket Pro product ─────────────


def test_line_references_existing_product(db):
    product = Product(name="Coca Cola 1L", price=Decimal("120.000"))
    db.add(product)
    db.flush()

    client = _client(db)
    doc = _document(db, client)
    line = _line(doc, description="Coca Cola 1L", product_id=product.id)
    db.add(line)
    db.flush()
    db.refresh(line)

    assert line.product_id == product.id
    assert line.product is product
    # The ONLY catalog is products — no invoice_products table exists.
    assert "invoice_products" not in Base.metadata.tables


# ── 9. product deletion -> product_id SET NULL ─────────────────────────


def test_product_delete_sets_line_product_id_null(db):
    product = Product(name="Disposable Product", price=Decimal("50.000"))
    db.add(product)
    db.flush()
    client = _client(db)
    doc = _document(db, client)
    line = _line(doc, product_id=product.id)
    db.add(line)
    db.flush()

    # RAW delete: proves DB-level ON DELETE SET NULL (sale_lines use
    # RESTRICT — facturation deliberately keeps historical lines alive).
    db.execute(delete(Product).where(Product.id == product.id))
    db.flush()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored is not None
    assert stored.product_id is None
    # The line itself survives with all snapshots intact.
    assert stored.description == "Line under test"
    assert stored.unit_price_ht == Decimal("10.000")


# ── 10. snapshots independent of product changes ───────────────────────


def test_line_snapshots_survive_product_changes(db):
    product = Product(name="Original Name", price=Decimal("100.000"))
    db.add(product)
    db.flush()
    client = _client(db)
    doc = _document(db, client)
    line = _line(
        doc,
        description="Original Name",
        product_id=product.id,
        unit_price_ht=Decimal("100.000"),
    )
    db.add(line)
    db.flush()

    # The invoice must NEVER depend on the current product afterwards.
    product.name = "Renamed Product"
    product.price = Decimal("999.000")
    db.flush()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored is not None
    assert stored.description == "Original Name"
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.product_id == product.id


# ── 11-13. counter uniqueness ──────────────────────────────────────────


def test_counter_same_doc_type_year_rejected_twice(db):
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=1))
    db.flush()
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=2))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_counter_different_years_allowed(db):
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=3))
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2027, last_number=0))
    db.flush()
    assert _count(db, InvoiceDocumentCounter) == 2


def test_counter_different_doc_types_same_year_allowed(db):
    for doc_type in ("FAC", "DEV", "PRO", "BC", "BL"):
        db.add(InvoiceDocumentCounter(doc_type=doc_type, year=2026, last_number=1))
    db.flush()
    assert _count(db, InvoiceDocumentCounter) == 5


# ── 14. monetary fields keep Decimal / NUMERIC semantics ───────────────


def test_monetary_columns_are_numeric_and_decimal_roundtrip(db, engine):
    client = _client(db)
    doc = _document(db, client)
    line = _line(
        doc,
        quantity=Decimal("2.500"),
        unit_price_ht=Decimal("19.990"),
        tva_rate=Decimal("19.000"),
        discount_pct=Decimal("33.333"),
    )
    db.add(line)
    db.flush()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored is not None
    assert isinstance(stored.unit_price_ht, Decimal)
    assert isinstance(stored.quantity, Decimal)
    assert isinstance(stored.tva_rate, Decimal)
    assert isinstance(stored.discount_pct, Decimal)
    assert stored.unit_price_ht == Decimal("19.99")
    assert stored.quantity == Decimal("2.5")
    assert stored.discount_pct == Decimal("33.333")

    columns = {c["name"]: c for c in inspect(engine).get_columns("invoice_document_lines")}
    for name in ("quantity", "unit_price_ht", "tva_rate", "discount_pct"):
        col_type = columns[name]["type"]
        assert col_type.__class__.__name__.upper() == "NUMERIC", name
        assert col_type.precision == 18, name
        assert col_type.scale == 3, name


def test_no_float_columns_anywhere_in_facturation_schema(engine):
    insp = inspect(engine)
    for table in (
        "invoice_clients",
        "invoice_documents",
        "invoice_document_lines",
        "invoice_document_counters",
    ):
        for col in insp.get_columns(table):
            assert col["type"].__class__.__name__ != "FLOAT", (table, col["name"])
            assert col["type"].__class__.__name__ != "REAL", (table, col["name"])


# ── 15. obvious invalid values rejected by intentional DB constraints ──


def test_invalid_doc_type_rejected(db):
    client = _client(db)
    db.add(
        InvoiceDocument(
            doc_type="XX",
            number="0001",
            year=2026,
            document_date=date(2026, 1, 1),
            client_id=client.id,
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_invalid_payment_method_rejected(db):
    client = _client(db)
    db.add(
        InvoiceDocument(
            number="0002",
            year=2026,
            document_date=date(2026, 1, 1),
            client_id=client.id,
            payment_method="card",  # POS vocabulary — not facturation
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_same_number_allowed_across_years(db):
    """FAC / 2026 / 0001 and FAC / 2027 / 0001 are distinct documents."""
    client = _client(db, "Year Client")
    _document(db, client, doc_type="FAC", year=2026, number="0001")
    _document(db, client, doc_type="FAC", year=2027, number="0001")
    db.flush()
    assert _count(db, InvoiceDocument) == 2
    years = db.scalars(select(InvoiceDocument.year).where(InvoiceDocument.doc_type == "FAC")).all()
    assert sorted(years) == [2026, 2027]


def test_same_number_allowed_across_doc_types(db):
    """FAC / 2026 / 0001 and DEV / 2026 / 0001 are distinct documents."""
    client = _client(db, "Type Client")
    _document(db, client, doc_type="FAC", year=2026, number="0001")
    _document(db, client, doc_type="DEV", year=2026, number="0001")
    db.flush()
    assert _count(db, InvoiceDocument) == 2


def test_duplicate_number_same_doc_type_year_rejected(db):
    """FAC / 2026 / 0001 twice is rejected by UNIQUE(doc_type, year, number)."""
    client = _client(db, "Dup Client")
    _document(db, client, doc_type="FAC", year=2026, number="0001")
    with pytest.raises(IntegrityError):
        _document(db, client, doc_type="FAC", year=2026, number="0001")
    db.rollback()
    assert _count(db, InvoiceDocument) == 0


def test_year_is_stored_independently_of_document_date(db, engine):
    """year is the numbering year — never derived from document_date."""
    client = _client(db)
    doc = _document(db, client, year=2026, document_date=date(2027, 3, 15))
    db.expire_all()
    stored_year = db.scalar(select(InvoiceDocument.year).where(InvoiceDocument.id == doc.id))
    assert stored_year == 2026
    assert doc.document_date == date(2027, 3, 15)

    # Column shape: NOT NULL integer, NO server default.
    # (SQLite inspector reports nullability as a bool, not "NO".)
    columns = {c["name"]: c for c in inspect(engine).get_columns("invoice_documents")}
    assert columns["year"]["nullable"] is False
    assert columns["year"]["default"] is None
    assert columns["year"]["type"].__class__.__name__.upper() == "INTEGER"


@pytest.mark.parametrize("bad_year", [0, -1])
def test_document_year_must_be_positive(db, bad_year):
    client = _client(db)
    db.add(
        InvoiceDocument(
            number="0001",
            year=bad_year,
            document_date=date(2026, 1, 1),
            client_id=client.id,
        )
    )
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


@pytest.mark.parametrize(
    "overrides",
    [
        {"quantity": Decimal("0")},
        {"quantity": Decimal("-1")},
        {"unit_price_ht": Decimal("-0.01")},
        {"discount_pct": Decimal("100.01")},
        {"discount_pct": Decimal("-0.01")},
    ],
)
def test_invalid_line_numbers_rejected(db, overrides):
    client = _client(db)
    doc = _document(db, client)
    db.add(_line(doc, **overrides))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_counter_year_must_be_positive(db):
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=0, last_number=0))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_counter_last_number_must_be_non_negative(db):
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=-1))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_counter_doc_type_vocabulary_enforced(db):
    db.add(InvoiceDocumentCounter(doc_type="XX", year=2026, last_number=0))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


# ── Ordering + vocabulary parity ───────────────────────────────────────


def test_line_position_orders_lines(db):
    client = _client(db)
    doc = _document(db, client)
    for pos, label in ((2, "third"), (0, "first"), (1, "second")):
        db.add(_line(doc, description=label, position=pos))
    db.flush()

    labels = db.scalars(
        select(InvoiceDocumentLine.description)
        .where(InvoiceDocumentLine.document_id == doc.id)
        .order_by(InvoiceDocumentLine.position)
    ).all()
    assert labels == ["first", "second", "third"]


def test_enum_vocabulary_matches_phase1_domain():
    # The DB vocabulary mirrors app.domain.facturation (Phase 1 authority),
    # so the schema can never drift from the calculation domain.
    assert {member.value for member in InvoiceDocType} == set(DOC_TYPES)
    assert {member.value for member in InvoicePaymentMethod} == set(PAYMENT_METHODS)
    # The POS PaymentMethod enum stays a different vocabulary.
    assert {member.value for member in InvoicePaymentMethod} != {
        "card",
        "credit",
        "partial",
    }


def test_no_customer_link_and_no_pos_tables_modified(db):
    # Isolation: invoice_clients has no customer_id column at all.
    columns = {c["name"] for c in inspect(db.bind).get_columns("invoice_clients")}
    assert "customer_id" not in columns
    assert columns >= {"id", "name", "address", "wilaya", "phone", "nif", "rc", "ai", "nis"}
    # No per-type document tables, no invoice product catalog.
    tables = set(Base.metadata.tables)
    assert not any(t.startswith("invoice_document_fac") for t in tables)
    assert "invoice_products" not in tables
