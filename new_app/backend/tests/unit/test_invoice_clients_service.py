"""Invoice client service tests (Phase 3 — facturation client domain).

SQLite in-memory with ``PRAGMA foreign_keys=ON`` (dedicated engine, like
``test_facturation_models``): the shared conftest engine leaves FK
enforcement off, which would silently pass the FK RESTRICT scenario
(hard delete of a referenced client).

Covers the required Phase 3 scenarios:
- create / get / list / search / update / archive / unarchive + the
  new-document availability check
- validation + normalization (name required/trimmed, optional trim →
  NULL, column length guards) with structured errors
- duplicate tolerance (name / phone / fiscal identifiers — factura_simple
  parity, no unique constraints)
- document relationship preservation (archive keeps it, hard delete is
  blocked by the database, Phase 2 FK still works end to end)
- domain isolation from the POS Customer (no customer_id / no FK / no
  Customer mutation)
Phase 1 calculation regression is covered by ``test_facturation.py``.
"""

from __future__ import annotations

import uuid
from datetime import date

import pytest
from sqlalchemy import create_engine, delete, event, func, inspect, select
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
from app.models.facturation import InvoiceClient, InvoiceDocument
from app.models.party import Customer
from app.services.facturation import InvoiceClientService


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
    return InvoiceClientService(db)


def _create(service, **overrides):
    payload = {"name": "SARL Demo"}
    payload.update(overrides)
    return service.create(**payload)


def _document(db, client, **overrides):
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


def _audit_rows(db, *, action=None):
    stmt = select(AuditLog).where(AuditLog.entity_type == "invoice_client")
    if action is not None:
        stmt = stmt.where(AuditLog.action == action)
    return list(db.scalars(stmt).all())


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


def test_create_persists_all_fields_trimmed(service, db):
    client = service.create(
        name="  SARL Alpha  ",
        address="  Rue Didouche Mourad 1  ",
        wilaya="  Alger  ",
        phone="  0555 000 001  ",
        nif="  000123456789012  ",
        rc="  16/00-1234567 B23  ",
        ai="  09312345  ",
        nis="  09312345678  ",
    )
    assert client.id is not None
    assert client.name == "SARL Alpha"
    assert client.address == "Rue Didouche Mourad 1"
    assert client.wilaya == "Alger"
    assert client.phone == "0555 000 001"
    assert client.nif == "000123456789012"
    assert client.rc == "16/00-1234567 B23"
    assert client.ai == "09312345"
    assert client.nis == "09312345678"
    assert client.archived_at is None
    stored = db.get(InvoiceClient, client.id)
    assert stored is not None
    assert stored.name == "SARL Alpha"


def test_create_name_only_stores_optionals_as_null(service):
    client = service.create(name="Minimal Client")
    assert client.name == "Minimal Client"
    assert client.address is None
    assert client.wilaya is None
    assert client.phone is None
    assert client.nif is None
    assert client.rc is None
    assert client.ai is None
    assert client.nis is None


def test_create_trims_name(service):
    client = service.create(name="   Padded Name   ")
    assert client.name == "Padded Name"


def test_create_missing_name_rejected(service):
    with pytest.raises(ValidationError) as excinfo:
        service.create()
    assert excinfo.value.code == "VALIDATION_ERROR"
    assert excinfo.value.status_code == 422
    assert excinfo.value.details["field"] == "name"


def test_create_blank_name_rejected(service):
    with pytest.raises(ValidationError) as excinfo:
        service.create(name="    ")
    assert excinfo.value.code == "VALIDATION_ERROR"
    assert excinfo.value.status_code == 422
    assert excinfo.value.details["field"] == "name"


def test_create_overlong_name_rejected(service):
    with pytest.raises(ValidationError) as excinfo:
        service.create(name="x" * 201)
    assert excinfo.value.details["max_length"] == 200


def test_create_overlong_phone_rejected(service):
    with pytest.raises(ValidationError) as excinfo:
        service.create(name="Too Long Phone", phone="1" * 31)
    assert excinfo.value.code == "VALIDATION_ERROR"
    assert excinfo.value.details["field"] == "phone"
    assert excinfo.value.details["max_length"] == 30


def test_create_blank_optional_becomes_null(service):
    client = service.create(
        name="Blank Optionals",
        phone="   ",
        address="",
        wilaya="  ",
    )
    assert client.phone is None
    assert client.address is None
    assert client.wilaya is None


def test_create_writes_audit(service, db):
    client = service.create(name="Audited Client")
    rows = _audit_rows(db, action="create")
    assert len(rows) == 1
    assert rows[0].entity_id == client.id
    assert rows[0].user_id is None


# ---------------------------------------------------------------------------
# Get
# ---------------------------------------------------------------------------


def test_get_returns_client(service):
    client = _create(service, name="Fetchable")
    fetched = service.get(client.id)
    assert fetched.id == client.id
    assert fetched.name == "Fetchable"


def test_get_unknown_raises_structured_404(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.get(uuid.uuid4())
    assert excinfo.value.code == "NOT_FOUND"
    assert excinfo.value.status_code == 404


# ---------------------------------------------------------------------------
# List / search
# ---------------------------------------------------------------------------


def test_list_returns_active_clients_ordered_by_name(service):
    _create(service, name="Beta Store")
    _create(service, name="Alpha Store")
    _create(service, name="Gamma Store")

    items, total = service.list()
    assert total == 3
    assert [c.name for c in items] == ["Alpha Store", "Beta Store", "Gamma Store"]


def test_list_hides_archived_unless_requested(service):
    _create(service, name="Active One")
    gone = _create(service, name="Gone Client")
    service.archive(gone.id)

    items, total = service.list()
    assert total == 1
    assert [c.name for c in items] == ["Active One"]

    items, total = service.list(include_archived=True)
    assert total == 2
    assert "Gone Client" in [c.name for c in items]


def test_list_paginates(service):
    _create(service, name="P One")
    _create(service, name="P Two")
    _create(service, name="P Three")

    page1, total = service.list(page=1, page_size=2)
    page2, _ = service.list(page=2, page_size=2)
    assert total == 3
    assert len(page1) == 2
    assert len(page2) == 1


def test_search_matches_name_case_insensitive(service):
    _create(service, name="SARL Alpha")
    _create(service, name="Other Company")

    items, total = service.list(q="sarl")
    assert total == 1
    assert [c.name for c in items] == ["SARL Alpha"]


def test_search_matches_phone(service):
    _create(service, name="Caller One", phone="0555000001")
    _create(service, name="Caller Two", phone="0666000002")

    items, total = service.list(q="0666")
    assert total == 1
    assert [c.name for c in items] == ["Caller Two"]


def test_search_returns_empty_for_unknown_term(service):
    _create(service, name="Known Client")
    items, total = service.list(q="zzz-no-match")
    assert total == 0
    assert items == []


def test_search_hides_archived_unless_requested(service):
    _create(service, name="Visible Client", phone="0555000001")
    gone = _create(service, name="Hidden Client", phone="0555000002")
    service.archive(gone.id)

    items, total = service.list(q="Client")
    assert total == 1
    assert [c.name for c in items] == ["Visible Client"]

    items, total = service.list(q="Client", include_archived=True)
    assert total == 2
    assert "Hidden Client" in [c.name for c in items]


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


def test_update_changes_only_supplied_fields(service, db):
    client = _create(
        service,
        name="Full Client",
        phone="0555000001",
        nif="000123456789012",
        wilaya="Alger",
    )
    updated = service.update(client.id, phone="0777999888")

    assert updated.phone == "0777999888"
    assert updated.name == "Full Client"
    assert updated.nif == "000123456789012"
    assert updated.wilaya == "Alger"

    db.expire_all()
    stored = db.get(InvoiceClient, client.id)
    assert stored.phone == "0777999888"
    assert stored.name == "Full Client"


def test_update_trims_name(service, db):
    client = _create(service, name="Before Edit")
    updated = service.update(client.id, name="   After Edit   ")
    assert updated.name == "After Edit"
    db.expire_all()
    assert db.get(InvoiceClient, client.id).name == "After Edit"


def test_update_blank_name_rejected_and_row_unchanged(service, db):
    client = _create(service, name="Keep Me")
    with pytest.raises(ValidationError) as excinfo:
        service.update(client.id, name="   ")
    assert excinfo.value.details["field"] == "name"

    db.expire_all()
    assert db.get(InvoiceClient, client.id).name == "Keep Me"


def test_update_explicit_none_name_rejected(service):
    client = _create(service, name="Name Required")
    with pytest.raises(ValidationError) as excinfo:
        service.update(client.id, name=None)
    assert excinfo.value.details["field"] == "name"


def test_update_blank_string_clears_optional_field(service, db):
    client = _create(service, name="Clearable", phone="0555000001")
    updated = service.update(client.id, phone="   ")
    assert updated.phone is None
    db.expire_all()
    assert db.get(InvoiceClient, client.id).phone is None


def test_update_explicit_none_clears_optional_field(service, db):
    client = _create(service, name="Clear Me", nif="000123456789012")
    updated = service.update(client.id, nif=None)
    assert updated.nif is None
    db.expire_all()
    assert db.get(InvoiceClient, client.id).nif is None


def test_update_unknown_client_raises_structured_404(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.update(uuid.uuid4(), phone="0555000001")
    assert excinfo.value.code == "NOT_FOUND"
    assert excinfo.value.status_code == 404


def test_update_writes_audit(service, db):
    client = _create(service, name="Audited Update")
    service.update(client.id, wilaya="Oran")
    rows = _audit_rows(db, action="update")
    assert len(rows) == 1
    assert rows[0].entity_id == client.id
    assert "wilaya" in rows[0].details


def test_update_without_fields_is_noop(service, db):
    client = _create(service, name="Untouched")
    result = service.update(client.id)
    assert result.name == "Untouched"
    assert _audit_rows(db, action="update") == []


# ---------------------------------------------------------------------------
# Archive / unarchive
# ---------------------------------------------------------------------------


def test_archive_sets_archived_at_and_hides_from_list(service, db):
    client = _create(service, name="Archivable")
    archived = service.archive(client.id)

    assert archived.archived_at is not None
    assert archived.is_archived is True

    db.expire_all()
    stored = db.get(InvoiceClient, client.id)
    assert stored is not None
    assert stored.archived_at is not None

    items, total = service.list()
    assert total == 0
    assert items == []


def test_archive_is_idempotent(service, db):
    client = _create(service, name="Double Archive")
    first = service.archive(client.id)
    first_archived_at = first.archived_at
    second = service.archive(client.id)

    assert second.archived_at == first_archived_at
    assert len(_audit_rows(db, action="delete")) == 1


def test_archive_unknown_raises_structured_404(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.archive(uuid.uuid4())
    assert excinfo.value.code == "NOT_FOUND"


def test_archive_writes_audit(service, db):
    client = _create(service, name="Audit Archive")
    service.archive(client.id)
    rows = _audit_rows(db, action="delete")
    assert len(rows) == 1
    assert rows[0].entity_id == client.id
    assert "archived" in rows[0].details


def test_unarchive_restores_client_visibility(service, db):
    client = _create(service, name="Comeback Client")
    service.archive(client.id)
    restored = service.unarchive(client.id)

    assert restored.archived_at is None
    assert restored.is_archived is False

    db.expire_all()
    assert db.get(InvoiceClient, client.id).archived_at is None
    items, total = service.list()
    assert total == 1
    assert [c.name for c in items] == ["Comeback Client"]


def test_unarchive_is_idempotent_for_active_client(service, db):
    client = _create(service, name="Always Active")
    result = service.unarchive(client.id)

    assert result.archived_at is None
    assert _audit_rows(db, action="update") == []


def test_unarchive_unknown_raises_structured_404(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.unarchive(uuid.uuid4())
    assert excinfo.value.code == "NOT_FOUND"


def test_unarchive_writes_audit(service, db):
    client = _create(service, name="Audit Unarchive")
    service.archive(client.id)
    service.unarchive(client.id)
    rows = _audit_rows(db, action="update")
    assert len(rows) == 1
    assert rows[0].entity_id == client.id
    assert "unarchived" in rows[0].details


# ---------------------------------------------------------------------------
# New-document availability
# ---------------------------------------------------------------------------


def test_active_client_usable_for_new_document(service):
    client = _create(service, name="Usable Client")
    usable = service.ensure_usable_for_new_document(client.id)
    assert usable.id == client.id
    assert usable.is_archived is False


def test_archived_client_not_usable_for_new_document(service, db):
    client = _create(service, name="Retired Client")
    service.archive(client.id)

    with pytest.raises(BusinessRuleError) as excinfo:
        service.ensure_usable_for_new_document(client.id)
    assert excinfo.value.code == "INVOICE_CLIENT_ARCHIVED"
    assert excinfo.value.status_code == 422
    assert excinfo.value.details["client_id"] == str(client.id)

    assert service.get(client.id).is_archived is True


def test_usability_unknown_client_raises_structured_404(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.ensure_usable_for_new_document(uuid.uuid4())
    assert excinfo.value.code == "NOT_FOUND"
    assert excinfo.value.status_code == 404


def test_has_documents_false_then_true(service, db):
    client = _create(service, name="Documented Client")
    assert service.has_documents(client.id) is False

    _document(db, client)
    db.commit()
    assert service.has_documents(client.id) is True


# ---------------------------------------------------------------------------
# Duplicate tolerance (factura_simple parity — no unique constraints)
# ---------------------------------------------------------------------------


def test_duplicate_names_allowed(service):
    first = _create(service, name="Dup Name Client")
    second = _create(service, name="Dup Name Client")
    assert first.id != second.id
    _, total = service.list(q="Dup Name Client")
    assert total == 2


def test_duplicate_phones_allowed(service):
    first = _create(service, name="Twin One", phone="0555000009")
    second = _create(service, name="Twin Two", phone="0555000009")
    assert first.id != second.id
    items, total = service.list(q="0555000009")
    assert total == 2
    assert all(c.phone == "0555000009" for c in items)


def test_duplicate_fiscal_identifiers_allowed_stored_as_is(service):
    first = _create(service, name="Fiscal Twin A", nif="000123456789012")
    second = _create(service, name="Fiscal Twin B", nif="000123456789012")
    assert first.id != second.id
    assert second.nif == "000123456789012"

    oddities = _create(
        service,
        name="Odd Identifiers",
        nif="NIF not digits",
        rc="?? rc ??",
        ai="x",
        nis="y",
    )
    assert oddities.nif == "NIF not digits"
    assert oddities.rc == "?? rc ??"
    assert oddities.ai == "x"
    assert oddities.nis == "y"


# ---------------------------------------------------------------------------
# Document relationship preservation
# ---------------------------------------------------------------------------


def test_archive_client_with_document_keeps_relationship(service, db):
    client = _create(service, name="Doc Owner")
    doc = _document(db, client)
    db.commit()
    doc_id = doc.id

    archived = service.archive(client.id)
    assert archived.is_archived is True
    assert service.has_documents(client.id) is True

    db.expire_all()
    stored_doc = db.get(InvoiceDocument, doc_id)
    assert stored_doc.client_id == client.id
    stored_client = db.get(InvoiceClient, client.id)
    assert stored_client is not None
    assert stored_client.is_archived is True
    assert stored_client.name == "Doc Owner"


def test_hard_delete_of_referenced_client_blocked_by_fk(service, db):
    client = _create(service, name="Referenced Client")
    _document(db, client)
    db.commit()

    with pytest.raises(IntegrityError):
        with db.begin_nested():
            db.execute(delete(InvoiceClient).where(InvoiceClient.id == client.id))

    db.expire_all()
    survivors = db.scalar(
        select(func.count()).select_from(InvoiceClient).where(InvoiceClient.id == client.id)
    )
    assert survivors == 1
    assert (
        db.scalar(
            select(func.count())
            .select_from(InvoiceDocument)
            .where(InvoiceDocument.client_id == client.id)
        )
        == 1
    )


def test_phase2_document_fk_still_works_with_service_client(service, db):
    client = _create(service, name="Phase 2 Regression")
    doc = _document(db, client, doc_type="DEV", number="0007", year=2027)
    db.commit()

    db.expire_all()
    stored = db.get(InvoiceDocument, doc.id)
    assert stored.client_id == client.id
    assert stored.client.name == "Phase 2 Regression"
    assert stored.doc_type == "DEV"
    assert stored.year == 2027


# ---------------------------------------------------------------------------
# Domain isolation from the POS Customer
# ---------------------------------------------------------------------------


def test_invoice_clients_schema_has_no_customer_reference(engine, service, db):
    insp = inspect(engine)
    columns = {c["name"] for c in insp.get_columns("invoice_clients")}
    assert "customer_id" not in columns
    assert insp.get_foreign_keys("invoice_clients") == []
    assert "customers" in insp.get_table_names()

    for table in (
        "invoice_clients",
        "invoice_documents",
        "invoice_document_lines",
        "invoice_document_counters",
    ):
        for fk in insp.get_foreign_keys(table):
            assert fk["referred_table"] != "customers"

    _create(service, name="Fiscal Only Client")
    assert db.scalar(select(func.count()).select_from(Customer)) == 0


def test_service_operations_never_touch_customers(engine, service, db):
    client = _create(service, name="Isolated Client")
    service.update(client.id, phone="0555000009")
    service.archive(client.id)
    service.unarchive(client.id)

    assert db.scalar(select(func.count()).select_from(Customer)) == 0
    insp = inspect(engine)
    assert insp.get_columns("customers") is not None
