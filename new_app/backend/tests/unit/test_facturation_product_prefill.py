"""Facturation product integration tests (Phase 4).

SQLite in-memory with ``PRAGMA foreign_keys=ON`` (dedicated engine, same
rationale as ``test_facturation_models``): the product-deletion SET NULL
scenario must actually be enforced.

Covers the required Phase 4 scenarios:
- product resolution through the existing ProductService read (single
  catalog — no invoice_products table, no second repository)
- the four-field invoice-line prefill snapshot: product_id, description
  (name snapshot), unit_price_ht (products.price snapshot), tva_rate
  (products.vat_rate snapshot)
- archived-product eligibility for NEW invoice lines; historical lines
  stay valid regardless of current product state
- free-text lines (product_id NULL) remain fully supported
- snapshots survive product price / name / VAT changes and DB-level
  product deletion (FK ON DELETE SET NULL)
- explicit pricing exclusions: promotion, wholesale, selling-unit are
  proven to apply in their own domains while facturation prefill still
  uses products.price; inventory is never touched
- product/customer domain separation

Phase 1/2/3 regressions are covered by their existing suites; the
PostgreSQL behavioral test lives in
``tests/integration/test_phase4_facturation_product_snapshot.py``.
"""

from __future__ import annotations

import uuid
from dataclasses import fields
from datetime import date
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, delete, event, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import BusinessRuleError, NotFoundError
from app.db.base import Base
from app.domain.promotion import promotional_unit_price
from app.domain.unit_conversions import effective_unit_price
from app.domain.wholesale import resolve_wholesale_unit_price
from app.models.catalog import Product, ProductSellingUnit
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentLine,
)
from app.models.inventory import InventoryMovement
from app.models.party import Customer
from app.models.promotion import Promotion, PromotionProduct
from app.services.catalog import ProductService
from app.services.facturation import (
    InvoiceLinePrefill,
    InvoiceProductService,
    product_line_prefill,
)


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
    return InvoiceProductService(db)


@pytest.fixture()
def products(db):
    return ProductService(db)


def _make_product(db, **overrides):
    values = dict(name="Coca Cola", price=Decimal("100.000"), vat_rate=19)
    values.update(overrides)
    product = Product(**values)
    db.add(product)
    db.commit()
    return product


def _make_client(db, name="Invoice Client"):
    client = InvoiceClient(name=name)
    db.add(client)
    db.commit()
    return client


def _make_document(db, client, **overrides):
    values = dict(
        number="0001",
        year=2026,
        document_date=date(2026, 10, 8),
        client_id=client.id,
    )
    values.update(overrides)
    document = InvoiceDocument(**values)
    db.add(document)
    db.commit()
    return document


def _line_from_prefill(db, document, prefill, **overrides):
    values = dict(
        document_id=document.id,
        product_id=prefill.product_id,
        description=prefill.description,
        quantity=Decimal("1"),
        unit_price_ht=prefill.unit_price_ht,
        tva_rate=prefill.tva_rate,
    )
    values.update(overrides)
    line = InvoiceDocumentLine(**values)
    db.add(line)
    db.commit()
    return line


def _snapshot_line(db, service, product, **line_overrides):
    prefill = service.get_product_for_invoice(product.id)
    client = _make_client(db)
    document = _make_document(db, client)
    return _line_from_prefill(db, document, prefill, **line_overrides)


def _count(db, model) -> int:
    return db.scalar(select(func.count()).select_from(model))


# ---------------------------------------------------------------------------
# Product resolution / prefill snapshot fields (required 1-5, 7, 17)
# ---------------------------------------------------------------------------


def test_product_resolves_for_facturation(service, db):
    product = _make_product(db)
    prefill = service.get_product_for_invoice(product.id)
    assert isinstance(prefill, InvoiceLinePrefill)
    assert prefill.product_id == product.id


def test_prefill_preserves_product_id(service, db):
    product = _make_product(db)
    prefill = service.get_product_for_invoice(product.id)
    assert prefill.product_id == product.id
    assert isinstance(prefill.product_id, uuid.UUID)


def test_product_name_becomes_description_snapshot(service, db):
    product = _make_product(db, name="Coca Cola 1L")
    prefill = service.get_product_for_invoice(product.id)
    assert prefill.description == "Coca Cola 1L"
    assert prefill.description == product.name


def test_product_price_becomes_unit_price_ht(service, db):
    product = _make_product(db, price=Decimal("100.500"))
    prefill = service.get_product_for_invoice(product.id)
    assert prefill.unit_price_ht == Decimal("100.500")
    assert isinstance(prefill.unit_price_ht, Decimal)


@pytest.mark.parametrize("vat", [0, 9, 19])
def test_product_vat_becomes_tva_rate(service, db, vat):
    product = _make_product(db, vat_rate=vat)
    prefill = service.get_product_for_invoice(product.id)
    assert prefill.tva_rate == Decimal(str(vat))
    assert isinstance(prefill.tva_rate, Decimal)


def test_nonexistent_product_raises_structured_not_found(service):
    with pytest.raises(NotFoundError) as excinfo:
        service.get_product_for_invoice(uuid.uuid4())
    assert excinfo.value.code == "NOT_FOUND"
    assert excinfo.value.status_code == 404
    assert "id" in excinfo.value.details


def test_lookup_does_not_mutate_product(service, db):
    product = _make_product(
        db,
        price=Decimal("100.000"),
        vat_rate=19,
        wholesale_price=Decimal("80.000"),
        wholesale_min_qty=Decimal("5"),
    )
    before = (
        product.name,
        product.price,
        product.vat_rate,
        product.wholesale_price,
        product.wholesale_min_qty,
        product.updated_at,
    )

    service.get_product_for_invoice(product.id)
    db.expire_all()

    stored = db.get(Product, product.id)
    assert (
        stored.name,
        stored.price,
        stored.vat_rate,
        stored.wholesale_price,
        stored.wholesale_min_qty,
        stored.updated_at,
    ) == before


def test_catalog_unchanged_after_prefill_lookup(service, db, engine):
    from sqlalchemy import inspect as sa_inspect

    product = _make_product(
        db,
        price=Decimal("100.000"),
        cost=Decimal("60.000"),
        avg_cost=Decimal("62.000"),
        quantity=Decimal("42"),
        vat_rate=9,
        wholesale_price=Decimal("80.000"),
        wholesale_min_qty=Decimal("5"),
    )

    insp = sa_inspect(engine)
    column_names = [c["name"] for c in insp.get_columns("products")]
    before = {}
    db.expire_all()
    stored = db.get(Product, product.id)
    for column in column_names:
        before[column] = getattr(stored, column)

    service.get_product_for_invoice(product.id)
    db.expire_all()
    stored = db.get(Product, product.id)
    after = {column: getattr(stored, column) for column in column_names}
    assert after == before


# ---------------------------------------------------------------------------
# Free-text lines (required 8)
# ---------------------------------------------------------------------------


def test_free_text_line_without_product_supported(db):
    client = _make_client(db)
    document = _make_document(db, client)
    line = InvoiceDocumentLine(
        document_id=document.id,
        product_id=None,
        description="Installation service",
        quantity=Decimal("1"),
        unit_price_ht=Decimal("5000"),
        tva_rate=Decimal("19"),
    )
    db.add(line)
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.product_id is None
    assert stored.description == "Installation service"
    assert stored.unit_price_ht == Decimal("5000")
    assert stored.tva_rate == Decimal("19")


def test_free_text_line_never_requires_product_resolution(service, db):
    client = _make_client(db)
    document = _make_document(db, client)
    line = InvoiceDocumentLine(
        document_id=document.id,
        product_id=None,
        description="Sans produit",
        quantity=Decimal("2"),
        unit_price_ht=Decimal("250"),
        tva_rate=Decimal("0"),
    )
    db.add(line)
    db.commit()
    assert line.product_id is None
    assert _count(db, Product) == 0


# ---------------------------------------------------------------------------
# Historical snapshots (required 9-12)
# ---------------------------------------------------------------------------


def test_snapshot_survives_product_price_change(service, db):
    product = _make_product(db, price=Decimal("100.000"))
    line = _snapshot_line(db, service, product)

    product.price = Decimal("120.000")
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.product_id == product.id


def test_snapshot_survives_product_name_change(service, db):
    product = _make_product(db, name="Coca Cola")
    line = _snapshot_line(db, service, product)

    product.name = "Coca Cola 1L"
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.description == "Coca Cola"
    assert stored.product_id == product.id


def test_snapshot_survives_product_vat_change(service, db):
    product = _make_product(db, vat_rate=19)
    line = _snapshot_line(db, service, product)

    product.vat_rate = 9
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.tva_rate == Decimal("19")
    assert db.get(Product, product.id).vat_rate == 9


def test_product_deletion_set_null_keeps_snapshot(service, db):
    product = _make_product(db, price=Decimal("100.000"), vat_rate=19)
    line = _snapshot_line(db, service, product)

    db.execute(delete(Product).where(Product.id == product.id))
    db.commit()
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.product_id is None
    assert stored.product is None
    assert stored.description == "Coca Cola"
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.tva_rate == Decimal("19")


# ---------------------------------------------------------------------------
# Pricing exclusions (required 13-15) and inventory isolation (16)
# ---------------------------------------------------------------------------


def test_promotion_price_is_not_used(service, db):
    product = _make_product(db, price=Decimal("100.000"))
    promotion = Promotion(
        name="Facturation Promo",
        promotion_type="fixed_price",
        value=Decimal("60.000"),
        is_active=True,
    )
    db.add(promotion)
    db.flush()
    db.add(PromotionProduct(promotion_id=promotion.id, product_id=product.id))
    db.commit()

    domain_price = promotional_unit_price(
        retail_price=Decimal("100.000"),
        promotion_type="fixed_price",
        value=Decimal("60.000"),
    )
    assert domain_price == Decimal("60.000")

    prefill = service.get_product_for_invoice(product.id)
    assert prefill.unit_price_ht == Decimal("100.000")
    assert prefill.unit_price_ht != domain_price


def test_wholesale_price_is_not_used(service, db):
    product = _make_product(
        db,
        price=Decimal("100.000"),
        wholesale_price=Decimal("80.000"),
        wholesale_min_qty=Decimal("5"),
    )

    domain_price = resolve_wholesale_unit_price(
        retail_price=Decimal("100.000"),
        wholesale_price=Decimal("80.000"),
        wholesale_min_qty=Decimal("5"),
        quantity_base=Decimal("10"),
    )
    assert domain_price == Decimal("80.000")

    prefill = service.get_product_for_invoice(product.id)
    assert prefill.unit_price_ht == Decimal("100.000")
    assert prefill.unit_price_ht != domain_price


def test_selling_unit_price_is_not_used(service, db):
    product = _make_product(db, price=Decimal("100.000"))
    unit = ProductSellingUnit(
        product_id=product.id,
        name="Box",
        multiplier=Decimal("24"),
        selling_price=Decimal("90.000"),
    )
    db.add(unit)
    db.commit()

    domain_price = effective_unit_price(
        selling_price=Decimal("90.000"),
        product_price=Decimal("100.000"),
    )
    assert domain_price == Decimal("90.000")

    prefill = service.get_product_for_invoice(product.id)
    assert prefill.unit_price_ht == Decimal("100.000")
    assert prefill.unit_price_ht != domain_price


def test_inventory_is_not_touched(service, db):
    product = _make_product(db, quantity=Decimal("42"))
    movements_before = _count(db, InventoryMovement)
    quantity_before = db.get(Product, product.id).quantity

    service.get_product_for_invoice(product.id)
    db.expire_all()

    assert db.get(Product, product.id).quantity == quantity_before
    assert _count(db, InventoryMovement) == movements_before == 0


# ---------------------------------------------------------------------------
# Product eligibility (established archived-product rule)
# ---------------------------------------------------------------------------


def test_archived_product_rejected_for_new_invoice_line(service, db, products):
    product = _make_product(db)
    products.archive(product.id)

    with pytest.raises(BusinessRuleError) as excinfo:
        service.get_product_for_invoice(product.id)
    assert excinfo.value.code == "BUSINESS_RULE_ERROR"
    assert excinfo.value.status_code == 422
    assert excinfo.value.details["product_id"] == str(product.id)


def test_historical_line_remains_valid_after_product_archival(service, db, products):
    product = _make_product(db, price=Decimal("100.000"))
    line = _snapshot_line(db, service, product)

    products.archive(product.id)
    db.expire_all()

    stored = db.get(InvoiceDocumentLine, line.id)
    assert stored.product_id == product.id
    assert stored.description == "Coca Cola"
    assert stored.unit_price_ht == Decimal("100.000")
    assert stored.tva_rate == Decimal("19")
    assert db.get(Product, product.id).archived_at is not None


# ---------------------------------------------------------------------------
# Domain separation / purity (required 18 + helper determinism)
# ---------------------------------------------------------------------------


def test_product_customer_domain_separation(service, db):
    product = _make_product(db)
    prefill = service.get_product_for_invoice(product.id)

    assert {f.name for f in fields(InvoiceLinePrefill)} == {
        "product_id",
        "description",
        "unit_price_ht",
        "tva_rate",
    }
    assert not hasattr(prefill, "customer_id")
    assert "invoice_products" not in Base.metadata.tables
    assert _count(db, Customer) == 0


def test_prefill_helper_is_pure_and_deterministic(db):
    product = _make_product(db, price=Decimal("100.000"), vat_rate=19)
    first = product_line_prefill(product)
    second = product_line_prefill(product)
    assert first == second
    assert first is not second
    assert (
        first.unit_price_ht,
        first.tva_rate,
    ) == (Decimal("100.000"), Decimal("19"))
