"""Phase 5 tests — InvoiceDocument service (numbering + document workflow).

SQLite in-memory with ``PRAGMA foreign_keys=ON`` (dedicated engine, same
rationale as ``test_facturation_models`` / ``test_facturation_product_prefill``):
the update line-replace cascade and the counter's UNIQUE constraints are
enforced by the schema itself.

Covers the required Phase 5 scenarios:

- NUMBERING (factura_simple ``next_number`` parity): full formatted
  string ``{doc_type}-{year}-{n:04d}`` stored in ``number``; the
  (doc_type, year) counter row is the only serial authority; sequences
  are independent per doc_type and per year; the year comes from
  ``document_date`` (default today); zero-padded serials; validation
  happens BEFORE allocation; a failed persist rolls the increment back
  (no gaps); DB-level UNIQUE backstops.
- DOCUMENT: create / read / list / update / preview orchestration with
  Phase 1 calculation reuse, Phase 4 product prefill, invoice-client
  gates, audit rows inside the same transaction, and the five doc types.
- UPDATE: partial semantics, immutable identity (doc_type / year /
  number / document_date can never be expressed), atomic line replace,
  explicit-null rejection, empty-body no-op, rollback-before-transaction
  on invalid lines.
- PREVIEW: zero persistence, zero number consumption, proposed number
  equals the next create's number.

Phase 1 domain math, Phase 2 model constraints, Phase 3 client rules and
Phase 4 prefill details are covered by their existing suites; the
PostgreSQL concurrency test lives in
``tests/integration/test_phase5_facturation_numbering.py``; the HTTP
layer lives in ``tests/unit/test_facturation_documents_api.py``.
"""

from __future__ import annotations

import uuid
from datetime import date

import pytest
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import create_engine, event, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import (
    BusinessRuleError,
    NotFoundError,
    ValidationError,
)
from app.db.base import Base
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.enums import AuditAction
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
    InvoiceDocumentLine,
)
from app.models.user import User
from app.repositories.facturation import InvoiceDocumentRepository
from app.schemas.facturation import (
    InvoiceDocumentCreateRequest,
    InvoiceDocumentUpdateRequest,
    InvoiceLineRequest,
)
from app.services.facturation import (
    InvoiceDocumentService,
    calculate_document_result,
)

TODAY = date.today()
FAC = "FAC"
DAY = date(2026, 10, 8)


def _create_fk_engine():
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
def engine():
    eng = _create_fk_engine()
    yield eng
    Base.metadata.drop_all(bind=eng)
    eng.dispose()


@pytest.fixture()
def db(engine):
    session = sessionmaker(bind=engine, autoflush=False)()
    yield session
    session.rollback()
    session.close()


@pytest.fixture()
def service(db):
    return InvoiceDocumentService(db)


def _client(db, name: str = "Invoice Client", *, archive: bool = False) -> InvoiceClient:
    client = InvoiceClient(name=name)
    if archive:
        from datetime import datetime, timezone

        client.archived_at = datetime.now(timezone.utc)
    db.add(client)
    db.commit()
    return client


def _product(db, **overrides) -> Product:
    values = dict(name="Coca Cola", price=100, vat_rate=19)
    values.update(overrides)
    product = Product(**values)
    db.add(product)
    db.commit()
    return product


def _user(db, name: str = "Doc Auditor") -> User:
    """A real user row — audit_logs.user_id has a FK constraint."""
    user = User(full_name=name, pin_hash="not-a-real-login")
    db.add(user)
    db.commit()
    return user


def _free_line(**overrides) -> InvoiceLineRequest:
    values = dict(
        description="Prestation",
        quantity=2,
        unit_price_ht=100,
        tva_rate=19,
        discount_pct=0,
    )
    values.update(overrides)
    return InvoiceLineRequest(**values)


def _request(client: InvoiceClient, **overrides) -> InvoiceDocumentCreateRequest:
    values = dict(
        doc_type=FAC,
        client_id=client.id,
        document_date=DAY,
        payment_method="cash",
        notes="First document",
        lines=[_free_line()],
    )
    values.update(overrides)
    return InvoiceDocumentCreateRequest(**values)


def _create(service, client, **overrides) -> InvoiceDocument:
    return service.create(_request(client, **overrides))


def _count(db, model, **filters) -> int:
    stmt = select(model)
    for field, value in filters.items():
        stmt = stmt.where(getattr(model, field) == value)
    return len(db.execute(stmt).scalars().all())


# ===========================================================================
# Numbering — factura_simple next_number parity
# ===========================================================================


def test_first_document_gets_zero_padded_number(service, db):
    client = _client(db)
    doc = _create(service, client)
    assert doc.number == "FAC-2026-0001"
    assert doc.year == 2026
    assert doc.doc_type == "FAC"


def test_number_stores_full_formatted_string(service, db):
    """Source stores the FULL ``FAC-2026-0001`` string, not the serial."""
    doc = _create(service, _client(db))
    assert doc.number == doc.doc_type + "-" + str(doc.year) + "-0001"
    assert "-" in doc.number


def test_numbers_increment_within_same_doc_type_and_year(service, db):
    client = _client(db)
    numbers = [_create(service, client).number for _ in range(3)]
    assert numbers == ["FAC-2026-0001", "FAC-2026-0002", "FAC-2026-0003"]


def test_each_doc_type_has_own_sequence(service, db):
    client = _client(db)
    fac = _create(service, client, doc_type="FAC")
    dev = _create(service, client, doc_type="DEV")
    pro = _create(service, client, doc_type="PRO")
    assert fac.number == "FAC-2026-0001"
    assert dev.number == "DEV-2026-0001"
    assert pro.number == "PRO-2026-0001"


def test_each_year_has_own_sequence(service, db):
    client = _client(db)
    y2025 = _create(service, client, document_date=date(2025, 6, 1))
    y2026 = _create(service, client, document_date=date(2026, 6, 1))
    assert y2025.number == "FAC-2025-0001"
    assert y2025.year == 2025
    assert y2026.number == "FAC-2026-0001"
    assert y2026.year == 2026


def test_counter_row_created_and_incremented(service, db):
    client = _client(db)
    _create(service, client)
    _create(service, client)
    counter = db.execute(
        select(InvoiceDocumentCounter).where(
            InvoiceDocumentCounter.doc_type == "FAC",
            InvoiceDocumentCounter.year == 2026,
        )
    ).scalar_one()
    assert counter.last_number == 2


def test_counter_seed_preserves_existing_serial(service, db):
    """A pre-existing counter (e.g. restored DB) continues where it left off."""
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=99))
    db.commit()
    doc = _create(service, _client(db))
    assert doc.number == "FAC-2026-0100"


def test_year_derived_from_document_date_not_today(service, db):
    doc = _create(service, _client(db), document_date=date(2024, 1, 15))
    assert doc.year == 2024
    assert doc.number == "FAC-2024-0001"


def test_default_document_date_is_today(service, db):
    """Source parity: ``data.date or date.today()``."""
    doc = service.create(
        InvoiceDocumentCreateRequest(
            client_id=_client(db).id,
            lines=[_free_line()],
        )
    )
    assert doc.document_date == TODAY
    assert doc.year == TODAY.year
    assert doc.number == f"FAC-{TODAY.year}-0001"


def test_counter_isolation_between_doc_type_and_year(service, db):
    client = _client(db)
    _create(service, client, doc_type="FAC")
    _create(service, client, doc_type="BL", document_date=date(2025, 1, 1))
    counters = {
        (c.doc_type, c.year): c.last_number
        for c in db.execute(select(InvoiceDocumentCounter)).scalars()
    }
    assert counters == {
        ("FAC", 2026): 1,
        ("BL", 2025): 1,
    }


def test_validation_runs_before_allocation(service, db):
    """An invalid request must never touch the counter (source order)."""
    client = _client(db)
    with pytest.raises(ValidationError):
        service.create(_request(client, lines=[_free_line(tva_rate=42)]))
    assert _count(db, InvoiceDocument) == 0
    assert _count(db, InvoiceDocumentCounter) == 0


def test_failed_persist_rolls_back_number_consumption(service, db, monkeypatch):
    """Counter increment + document insert share one transaction (no gap)."""
    client = _client(db)
    original = InvoiceDocumentRepository.create
    calls = {"n": 0}

    def flaky(self, instance):  # noqa: ANN001
        if calls["n"] == 0:
            calls["n"] += 1
            raise RuntimeError("simulated persist failure")
        return original(self, instance)

    monkeypatch.setattr(InvoiceDocumentRepository, "create", flaky)

    with pytest.raises(RuntimeError, match="simulated persist failure"):
        _create(service, client)

    assert _count(db, InvoiceDocument) == 0
    assert _count(db, InvoiceDocumentCounter) == 0

    monkeypatch.undo()
    doc = _create(service, client)
    assert doc.number == "FAC-2026-0001"  # failed attempt consumed nothing


def test_unique_number_is_db_backstop(service, db):
    """UNIQUE(doc_type, year, number) is the final safety net."""
    client = _client(db)
    first = _create(service, client)
    duplicate = InvoiceDocument(
        doc_type=first.doc_type,
        number=first.number,
        year=first.year,
        document_date=DAY,
        client_id=client.id,
        payment_method="cash",
    )
    db.add(duplicate)
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


def test_counter_unique_constraint_is_db_backstop(db):
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=0))
    db.commit()
    db.add(InvoiceDocumentCounter(doc_type="FAC", year=2026, last_number=0))
    with pytest.raises(IntegrityError):
        db.flush()
    db.rollback()


# ===========================================================================
# Create — orchestration, prefill, gates, audit
# ===========================================================================


def test_create_persists_document_and_lines(service, db):
    client = _client(db)
    doc = _create(
        service,
        client,
        lines=[
            _free_line(description="Line A", quantity=1),
            _free_line(description="Line B", quantity=3, tva_rate=9),
        ],
    )
    assert doc.id is not None
    assert doc.created_at is not None
    lines = (
        db.execute(
            select(InvoiceDocumentLine)
            .where(InvoiceDocumentLine.document_id == doc.id)
            .order_by(InvoiceDocumentLine.position)
        )
        .scalars()
        .all()
    )
    assert [line.description for line in lines] == ["Line A", "Line B"]
    assert [line.position for line in lines] == [0, 1]
    assert lines[1].tva_rate == 9


def test_create_product_line_prefills_four_fields(service, db):
    client = _client(db)
    product = _product(db, price=100, vat_rate=19, name="Eau Minérale")
    doc = _create(service, client, lines=[InvoiceLineRequest(product_id=product.id, quantity=2)])
    line = doc.lines[0]
    assert line.product_id == product.id
    assert line.description == "Eau Minérale"
    assert line.unit_price_ht == 100
    assert line.tva_rate == 19


def test_create_explicit_line_values_beat_prefill(service, db):
    client = _client(db)
    product = _product(db, price=100, vat_rate=19)
    doc = _create(
        service,
        client,
        lines=[
            InvoiceLineRequest(
                product_id=product.id,
                description="Promo label",
                quantity=2,
                unit_price_ht=55.5,
                tva_rate=9,
            )
        ],
    )
    line = doc.lines[0]
    assert line.description == "Promo label"
    assert line.unit_price_ht == 55.5
    assert line.tva_rate == 9


def test_create_free_text_line_keeps_null_product(service, db):
    doc = _create(service, _client(db))
    assert doc.lines[0].product_id is None


def test_create_flags_default_true_and_overrides_persist(service, db):
    doc = _create(service, _client(db))
    assert doc.show_discount is True
    assert doc.show_tva is True
    assert doc.show_timbre is True
    assert doc.show_payment_method is True
    assert doc.show_amount_words is True

    doc2 = _create(service, _client(db), show_timbre=False, show_tva=False)
    assert doc2.show_timbre is False
    assert doc2.show_tva is False
    assert doc2.show_discount is True


def test_create_trims_notes_and_blank_becomes_null(service, db):
    doc = _create(service, _client(db), notes="  padded note  ")
    assert doc.notes == "padded note"
    doc2 = _create(service, _client(db), notes="   ")
    assert doc2.notes is None


def test_create_default_doc_type_is_fac(service, db):
    client = _client(db)
    doc = service.create(
        InvoiceDocumentCreateRequest(
            client_id=client.id,
            document_date=DAY,
            lines=[_free_line()],
        )
    )
    assert doc.doc_type == "FAC"


@pytest.mark.parametrize("doc_type", ["FAC", "DEV", "PRO", "BC", "BL"])
def test_create_all_five_document_types(service, db, doc_type):
    doc = _create(service, _client(db), doc_type=doc_type)
    assert doc.doc_type == doc_type
    assert doc.number.startswith(f"{doc_type}-2026-")


def test_create_invalid_doc_type_rejected(service, db):
    with pytest.raises(ValidationError):
        _create(service, _client(db), doc_type="XYZ")
    assert _count(db, InvoiceDocument) == 0


def test_create_invalid_payment_method_rejected(service, db):
    with pytest.raises(ValidationError):
        _create(service, _client(db), payment_method="bitcoin")
    assert _count(db, InvoiceDocument) == 0


def test_create_unknown_client_404(service, db):
    with pytest.raises(NotFoundError):
        service.create(
            InvoiceDocumentCreateRequest(
                client_id=uuid.uuid4(),
                document_date=DAY,
                lines=[_free_line()],
            )
        )
    assert _count(db, InvoiceDocument) == 0
    assert _count(db, InvoiceDocumentCounter) == 0


def test_create_archived_client_422(service, db):
    archived = _client(db, "Archived Client", archive=True)
    with pytest.raises(BusinessRuleError) as exc:
        _create(service, archived)
    assert exc.value.code == "INVOICE_CLIENT_ARCHIVED"
    assert _count(db, InvoiceDocument) == 0


def test_create_unknown_product_404(service, db):
    with pytest.raises(NotFoundError):
        _create(
            service,
            _client(db),
            lines=[InvoiceLineRequest(product_id=uuid.uuid4(), quantity=1)],
        )
    assert _count(db, InvoiceDocumentCounter) == 0


def test_create_archived_product_422(service, db):
    product = _product(db, price=100, vat_rate=19)
    from datetime import datetime, timezone

    product.archived_at = datetime.now(timezone.utc)
    db.commit()
    with pytest.raises(BusinessRuleError):
        _create(
            service,
            _client(db),
            lines=[InvoiceLineRequest(product_id=product.id, quantity=1)],
        )
    assert _count(db, InvoiceDocumentCounter) == 0


def test_create_empty_lines_rejected(service, db):
    with pytest.raises(PydanticValidationError):
        _create(service, _client(db), lines=[])


def test_create_zero_quantity_rejected(service, db):
    with pytest.raises(PydanticValidationError):
        _create(service, _client(db), lines=[_free_line(quantity=0)])


def test_create_negative_price_rejected(service, db):
    with pytest.raises(PydanticValidationError):
        _create(service, _client(db), lines=[_free_line(unit_price_ht=-1)])


def test_create_discount_above_100_rejected(service, db):
    with pytest.raises(PydanticValidationError):
        _create(service, _client(db), lines=[_free_line(discount_pct=101)])


def test_create_invalid_tva_rejected_by_phase1_domain(service, db):
    """tva membership {0,9,19} stays a Phase 1 check (NOT in the schema)."""
    with pytest.raises(ValidationError) as exc:
        _create(service, _client(db), lines=[_free_line(tva_rate=42)])
    assert exc.value.code == "VALIDATION_ERROR"


def test_create_free_text_line_without_identity_rejected(service, db):
    with pytest.raises(PydanticValidationError):
        _create(service, _client(db), lines=[InvoiceLineRequest(quantity=1)])


def test_create_writes_audit_row(service, db):
    actor = _user(db).id
    doc = service.create(_request(_client(db)), actor_id=actor)
    audit = db.execute(select(AuditLog).where(AuditLog.entity_id == doc.id)).scalar_one()
    assert audit.action == AuditAction.CREATE.value
    assert audit.entity_type == "invoice_document"
    assert audit.user_id == actor
    assert doc.number in audit.details


def test_create_without_actor_keeps_audit_row_nullable(service, db):
    doc = _create(service, _client(db))
    audit = db.execute(select(AuditLog).where(AuditLog.entity_id == doc.id)).scalar_one()
    assert audit.user_id is None


# ===========================================================================
# Get / list
# ===========================================================================


def test_get_returns_document_or_404(service, db):
    doc = _create(service, _client(db))
    assert service.get(doc.id).number == "FAC-2026-0001"
    with pytest.raises(NotFoundError):
        service.get(uuid.uuid4())


def test_get_keeps_archived_client_embedded(service, db):
    """Documents outlive their client's archive state (RESTRICT FK)."""
    client = _client(db)
    doc = _create(service, client)
    from datetime import datetime, timezone

    client.archived_at = datetime.now(timezone.utc)
    db.commit()
    fetched = service.get(doc.id)
    assert fetched.client is not None
    assert fetched.client.name == client.name


def test_list_filters_doc_type(service, db):
    client = _client(db)
    _create(service, client, doc_type="FAC")
    _create(service, client, doc_type="BL")
    rows, total = service.list(doc_type="BL")
    assert total == 1
    assert rows[0].doc_type == "BL"


def test_list_invalid_doc_type_filter_is_422(service, db):
    with pytest.raises(ValidationError):
        service.list(doc_type="XYZ")


def test_list_filters_year(service, db):
    client = _client(db)
    _create(service, client, document_date=date(2025, 3, 1))
    _create(service, client, document_date=date(2026, 3, 1))
    rows, total = service.list(year=2025)
    assert total == 1
    assert rows[0].year == 2025


def test_list_filters_client_id(service, db):
    first = _client(db, "First")
    second = _client(db, "Second")
    _create(service, first)
    _create(service, second)
    _create(service, second)
    rows, total = service.list(client_id=second.id)
    assert total == 2
    assert {row.client_id for row in rows} == {second.id}


def test_list_filters_date_range(service, db):
    client = _client(db)
    _create(service, client, document_date=date(2026, 1, 5))
    _create(service, client, document_date=date(2026, 6, 5))
    _create(service, client, document_date=date(2026, 12, 5))
    rows, total = service.list(date_from=date(2026, 3, 1), date_to=date(2026, 9, 30))
    assert total == 1
    assert rows[0].document_date == date(2026, 6, 5)


def test_list_date_from_after_date_to_422(service, db):
    with pytest.raises(ValidationError) as exc:
        service.list(date_from=date(2026, 6, 1), date_to=date(2026, 1, 1))
    assert exc.value.code == "VALIDATION_ERROR"


def test_list_searches_formatted_number(service, db):
    client = _client(db)
    _create(service, client, doc_type="FAC")
    _create(service, client, doc_type="DEV")
    rows, total = service.list(q="FAC-2026")
    assert total == 1
    assert rows[0].doc_type == "FAC"


def test_list_pagination_envelope(service, db):
    client = _client(db)
    for _ in range(5):
        _create(service, client)
    page1, total = service.list(page=1, page_size=2)
    assert total == 5
    assert len(page1) == 2
    page3, _ = service.list(page=3, page_size=2)
    assert len(page3) == 1
    assert service.list(page=4, page_size=2)[0] == []


def test_list_orders_newest_first(service, db):
    client = _client(db)
    _create(service, client, document_date=date(2026, 1, 1))
    _create(service, client, document_date=date(2026, 12, 1))
    _create(service, client, document_date=date(2026, 6, 1))
    rows, _ = service.list()
    dates = [row.document_date for row in rows]
    assert dates == sorted(dates, reverse=True)


def test_list_keeps_documents_of_archived_client(service, db):
    client = _client(db)
    _create(service, client)
    from datetime import datetime, timezone

    client.archived_at = datetime.now(timezone.utc)
    db.commit()
    rows, total = service.list(client_id=client.id)
    assert total == 1


# ===========================================================================
# Update — partial semantics + immutability
# ===========================================================================


def _put(document_id, **overrides) -> InvoiceDocumentUpdateRequest:
    return InvoiceDocumentUpdateRequest(**overrides)


def test_update_payment_method(service, db):
    doc = _create(service, _client(db))
    updated = service.update(doc.id, _put(doc.id, payment_method="transfer"))
    assert updated.payment_method == "transfer"
    assert updated.number == doc.number  # never re-allocated


def test_update_notes_and_clear_with_null(service, db):
    doc = _create(service, _client(db), notes="old")
    updated = service.update(doc.id, _put(doc.id, notes="  new note  "))
    assert updated.notes == "new note"
    cleared = service.update(doc.id, InvoiceDocumentUpdateRequest.model_validate({"notes": None}))
    assert cleared.notes is None


def test_update_swaps_client(service, db):
    first = _client(db, "First")
    second = _client(db, "Second")
    doc = _create(service, first)
    updated = service.update(doc.id, _put(doc.id, client_id=second.id))
    assert updated.client_id == second.id


def test_update_archived_client_rejected(service, db):
    good = _client(db, "Good")
    archived = _client(db, "Gone", archive=True)
    doc = _create(service, good)
    with pytest.raises(BusinessRuleError) as exc:
        service.update(doc.id, _put(doc.id, client_id=archived.id))
    assert exc.value.code == "INVOICE_CLIENT_ARCHIVED"
    assert service.get(doc.id).client_id == good.id


def test_update_replaces_all_lines_atomically(service, db):
    doc = _create(service, _client(db))  # one line
    old_line_ids = [line.id for line in doc.lines]
    updated = service.update(
        doc.id,
        _put(
            doc.id,
            lines=[
                _free_line(description="New A", quantity=1),
                _free_line(description="New B", quantity=2, tva_rate=9),
            ],
        ),
    )
    ordered = sorted(updated.lines, key=lambda line: line.position)
    assert len(ordered) == 2
    assert [line.description for line in ordered] == ["New A", "New B"]
    surviving = {
        line.id
        for line in db.execute(select(InvoiceDocumentLine)).scalars().all()
        if line.document_id == doc.id
    }
    assert surviving.isdisjoint(set(old_line_ids))


def test_update_partial_leaves_other_fields_untouched(service, db):
    first = _client(db, "First")
    doc = _create(service, first, payment_method="cash", notes="keep me")
    service.update(doc.id, _put(doc.id, notes="changed"))
    fresh = service.get(doc.id)
    assert fresh.notes == "changed"
    assert fresh.client_id == first.id
    assert fresh.payment_method == "cash"
    assert len(fresh.lines) == 1  # lines untouched


def test_update_immutable_identity_fields_are_inexpressible(service, db):
    doc = _create(service, _client(db))
    hostile = InvoiceDocumentUpdateRequest.model_validate(
        {
            "number": "FAC-1999-9999",
            "doc_type": "BL",
            "year": 1999,
            "document_date": "1999-01-01",
            "notes": "still applies",
        }
    )
    updated = service.update(doc.id, hostile)
    assert updated.number == "FAC-2026-0001"
    assert updated.doc_type == "FAC"
    assert updated.year == 2026
    assert updated.document_date == DAY
    assert updated.notes == "still applies"


def test_update_rejects_explicit_null_client(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(PydanticValidationError):
        service.update(doc.id, InvoiceDocumentUpdateRequest.model_validate({"client_id": None}))


def test_update_rejects_explicit_null_payment(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(PydanticValidationError):
        service.update(
            doc.id, InvoiceDocumentUpdateRequest.model_validate({"payment_method": None})
        )


def test_update_rejects_explicit_null_lines(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(PydanticValidationError):
        service.update(doc.id, InvoiceDocumentUpdateRequest.model_validate({"lines": None}))


def test_update_rejects_empty_lines_list(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(PydanticValidationError):
        service.update(doc.id, InvoiceDocumentUpdateRequest.model_validate({"lines": []}))


def test_update_invalid_payment_rejected(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(ValidationError):
        service.update(doc.id, _put(doc.id, payment_method="gold"))
    assert service.get(doc.id).payment_method == "cash"


def test_update_unknown_product_in_lines_404(service, db):
    doc = _create(service, _client(db))
    with pytest.raises(NotFoundError):
        service.update(
            doc.id,
            _put(
                doc.id,
                lines=[InvoiceLineRequest(product_id=uuid.uuid4(), quantity=1)],
            ),
        )


def test_update_invalid_lines_rolls_back_whole_request(service, db):
    """Validation runs BEFORE the transaction: nothing half-applies."""
    doc = _create(service, _client(db), notes="original")
    with pytest.raises(ValidationError):
        service.update(
            doc.id,
            _put(doc.id, notes="should not stick", lines=[_free_line(tva_rate=42)]),
        )
    fresh = service.get(doc.id)
    assert fresh.notes == "original"
    assert len(fresh.lines) == 1


def test_update_empty_body_is_noop_without_audit(service, db):
    actor = uuid.uuid4()
    doc = _create(service, _client(db))
    audits_before = _count(db, AuditLog, entity_id=doc.id)
    updated = service.update(doc.id, InvoiceDocumentUpdateRequest(), actor_id=actor)
    assert updated.number == "FAC-2026-0001"
    assert _count(db, AuditLog, entity_id=doc.id) == audits_before


def test_update_writes_audit_row_with_fields(service, db):
    actor = _user(db).id
    doc = _create(service, _client(db))
    service.update(doc.id, _put(doc.id, payment_method="cheque"), actor_id=actor)
    audit = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == doc.id, AuditLog.action == AuditAction.UPDATE.value
        )
    ).scalar_one()
    assert audit.entity_type == "invoice_document"
    assert audit.user_id == actor
    assert "payment_method" in audit.details


def test_update_does_not_touch_counter(service, db):
    doc = _create(service, _client(db))
    service.update(doc.id, _put(doc.id, notes="x"))
    service.update(doc.id, _put(doc.id, notes="y"))
    counter = db.execute(
        select(InvoiceDocumentCounter).where(
            InvoiceDocumentCounter.doc_type == "FAC",
            InvoiceDocumentCounter.year == 2026,
        )
    ).scalar_one()
    assert counter.last_number == 1


def test_update_unknown_document_404(service, db):
    with pytest.raises(NotFoundError):
        service.update(uuid.uuid4(), _put(uuid.uuid4(), notes="x"))


# ===========================================================================
# Preview — no persistence, proposed number
# ===========================================================================


def test_preview_persists_nothing(service, db):
    client = _client(db)
    result = service.preview(_request(client))
    assert _count(db, InvoiceDocument) == 0
    assert _count(db, InvoiceDocumentCounter) == 0
    assert _count(db, InvoiceDocumentLine) == 0
    assert _count(db, AuditLog) == 0
    assert result is not None


def test_preview_proposed_number_matches_next_create(service, db):
    client = _client(db)
    proposed = service.preview(_request(client)).proposed_number
    assert proposed == "FAC-2026-0001"
    doc = _create(service, client)
    assert doc.number == proposed
    assert service.preview(_request(client)).proposed_number == "FAC-2026-0002"


def test_preview_computes_phase1_totals_with_timbre(service, db):
    """4 x 100 @ 19% = 476 TTC > 300 -> stamp duty applies (FAC + cash)."""
    client = _client(db)
    result = service.preview(_request(client, lines=[_free_line(quantity=4)]))
    totals = result.calculation.totals
    assert totals.total_ht == 400
    assert totals.total_tva == 76
    assert totals.total_ttc == 476
    assert totals.timbre == 5  # (476 * 1%) rounded up, minimum 5
    assert totals.net_a_payer == 481
    assert result.calculation.amount_in_words  # non-empty French sentence


def test_preview_timbre_threshold_at_300(service, db):
    """Source rule: totals <= 300 carry NO stamp duty."""
    client = _client(db)
    totals = service.preview(_request(client)).calculation.totals
    assert totals.total_ttc == 238
    assert totals.timbre == 0
    assert totals.net_a_payer == totals.total_ttc


def test_preview_show_timbre_false_excludes_duty(service, db):
    client = _client(db)
    result = service.preview(_request(client, lines=[_free_line(quantity=4)], show_timbre=False))
    totals = result.calculation.totals
    assert totals.total_ttc == 476
    assert totals.timbre == 0
    assert totals.net_a_payer == totals.total_ttc


def test_preview_invalid_doc_type_rejected(service, db):
    with pytest.raises(ValidationError):
        service.preview(_request(_client(db), doc_type="NOPE"))


def test_preview_archived_client_rejected(service, db):
    with pytest.raises(BusinessRuleError):
        service.preview(_request(_client(db, "Gone", archive=True)))


def test_preview_lines_are_unpersisted(service, db):
    result = service.preview(_request(_client(db)))
    assert len(result.lines) == 1
    assert result.lines[0].id is None
    assert result.client is not None
    assert result.year == 2026
    assert result.document_date == DAY


# ===========================================================================
# Shared calculation path
# ===========================================================================


def test_calculate_document_result_orders_lines_by_position(service, db):
    """line_totals align with position order, not input order."""
    client = _client(db)
    doc = _create(
        service,
        client,
        lines=[
            _free_line(description="first-input", quantity=1, position=7),
            _free_line(description="second-input", quantity=10, position=2),
        ],
    )
    calculation = calculate_document_result(
        doc.doc_type, doc.payment_method, doc.show_timbre, doc.lines
    )
    assert len(calculation.line_totals) == 2
    assert calculation.line_totals[0].net_ht == 1000  # position 2 first
    assert calculation.line_totals[1].net_ht == 100  # position 7 second


def test_detail_calculation_matches_domain_totals(service, db):
    doc = _create(service, _client(db), lines=[_free_line(quantity=4)])
    calculation = calculate_document_result(
        doc.doc_type, doc.payment_method, doc.show_timbre, doc.lines
    )
    assert calculation.totals.net_a_payer == 481
    assert len(calculation.line_totals) == len(doc.lines)
