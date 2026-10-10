"""Stage 3A tests — facturation option identity (variant / selling unit / pack).

SQLite in-memory with ``PRAGMA foreign_keys=ON`` (same rationale as
``test_facturation_product_prefill``): the option FK SET NULL scenario
must actually be enforced.

Covers:
- schema combination rules (variant XOR selling unit; pack alone;
  variant/unit require product_id) at the Pydantic layer, plus proof
  that the three new request fields are MODELLED (not silently dropped)
- variant prefill: variant.price wins, NULL falls back to
  products.price, description ``"{product} · {variant}"``, tva =
  products.vat_rate, ownership / archived / 404 gates
- selling-unit prefill: selling_price wins, NULL uses products.price
  AS-IS (multiplier NEVER multiplies price), ownership / archived /
  404 gates
- pack prefill: pack.price + pack name + tva 0 default + product_id
  NULL, inactive/archived/404 gates
- create/preview persistence: the three ids snapshot onto the line,
  client-sent values still win, free-text lines stay id-free
- INVENTORY ISOLATION (the core safety contract): creating option
  lines never writes inventory movements and never changes product /
  variant stock quantities (all four option kinds)
- SET NULL resilience: deleting an option row nulls only the link, the
  stored snapshot line stays intact
- response serialization carries the option ids (build_line_fields)
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

import pytest
from pydantic import ValidationError as PydanticValidationError
from sqlalchemy import create_engine, delete, event, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import BusinessRuleError, NotFoundError, ValidationError
from app.db.base import Base
from app.models.catalog import Pack, PackItem, Product, ProductSellingUnit, ProductVariant
from app.models.facturation import InvoiceClient, InvoiceDocumentLine
from app.models.inventory import InventoryMovement
from app.schemas.facturation import (
    InvoiceDocumentCreateRequest,
    InvoiceLineRequest,
)
from app.services.facturation import (
    InvoiceDocumentService,
    InvoiceProductService,
    build_line_fields,
    pack_line_prefill,
    product_line_prefill,
    selling_unit_line_prefill,
    variant_line_prefill,
)

DAY = date(2026, 10, 10)


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
def docs(db):
    return InvoiceDocumentService(db)


def _product(db, **overrides) -> Product:
    values = dict(name="Coca Cola", price=Decimal("100.000"), vat_rate=19)
    values.update(overrides)
    product = Product(**values)
    product.quantity = 50
    db.add(product)
    db.commit()
    return product


def _client(db, name: str = "Invoice Client") -> InvoiceClient:
    client = InvoiceClient(name=name)
    db.add(client)
    db.commit()
    return client


def _variant(db, product: Product, **overrides) -> ProductVariant:
    values = dict(product_id=product.id, name="Big")
    values.update(overrides)
    variant = ProductVariant(**values)
    variant.quantity = 10
    db.add(variant)
    db.commit()
    return variant


def _unit(db, product: Product, **overrides) -> ProductSellingUnit:
    values = dict(
        product_id=product.id,
        name="Box",
        multiplier=Decimal("24"),
    )
    values.update(overrides)
    unit = ProductSellingUnit(**values)
    db.add(unit)
    db.commit()
    return unit


def _pack(db, **overrides) -> Pack:
    values = dict(name="Pack Promo", price=Decimal("250.000"))
    values.update(overrides)
    pack = Pack(**values)
    db.add(pack)
    db.commit()
    return pack


def _create_req(client_id, lines, **overrides) -> InvoiceDocumentCreateRequest:
    values = dict(
        doc_type="FAC",
        client_id=client_id,
        payment_method="cash",
        document_date=DAY,
        lines=lines,
    )
    values.update(overrides)
    return InvoiceDocumentCreateRequest(**values)


# ===========================================================================
# Schema combination rules
# ===========================================================================


class TestLineRequestCombinations:
    def test_variant_and_unit_together_rejected(self):
        with pytest.raises(PydanticValidationError, match="cannot be combined"):
            InvoiceLineRequest(
                product_id=uuid.uuid4(),
                variant_id=uuid.uuid4(),
                selling_unit_id=uuid.uuid4(),
                quantity=1,
            )

    def test_pack_with_product_rejected(self):
        with pytest.raises(PydanticValidationError, match="pack_id cannot be combined"):
            InvoiceLineRequest(
                product_id=uuid.uuid4(),
                pack_id=uuid.uuid4(),
                quantity=1,
            )

    def test_pack_with_variant_rejected(self):
        with pytest.raises(PydanticValidationError, match="pack_id cannot be combined"):
            InvoiceLineRequest(
                variant_id=uuid.uuid4(),
                pack_id=uuid.uuid4(),
                quantity=1,
            )

    def test_pack_alone_is_valid_without_free_text_fields(self):
        line = InvoiceLineRequest(pack_id=uuid.uuid4(), quantity=2)
        assert line.pack_id is not None
        assert line.product_id is None
        assert line.description is None

    def test_variant_without_product_rejected(self):
        with pytest.raises(PydanticValidationError, match="variant_id requires product_id"):
            InvoiceLineRequest(variant_id=uuid.uuid4(), quantity=1)

    def test_unit_without_product_rejected(self):
        with pytest.raises(
            PydanticValidationError, match="selling_unit_id requires product_id"
        ):
            InvoiceLineRequest(selling_unit_id=uuid.uuid4(), quantity=1)

    def test_new_fields_are_modelled_not_dropped(self):
        """Regression: unmodeled request fields are silently dropped by
        StrictBaseModel. The three option ids MUST survive validation."""
        variant_id = uuid.uuid4()
        line = InvoiceLineRequest.model_validate(
            {
                "product_id": str(uuid.uuid4()),
                "variant_id": str(variant_id),
                "quantity": "2",
            }
        )
        assert line.variant_id == variant_id

    def test_free_text_rules_unchanged(self):
        with pytest.raises(PydanticValidationError, match="description is required"):
            InvoiceLineRequest(quantity=1, unit_price_ht=10, tva_rate=19)


# ===========================================================================
# Variant prefill
# ===========================================================================


class TestVariantPrefill:
    def test_variant_price_wins_over_product(self, service, db):
        product = _product(db, price=Decimal("100.000"))
        variant = _variant(db, product, price=Decimal("120.000"))
        prefill = service.get_variant_for_invoice(product.id, variant.id)
        assert prefill.unit_price_ht == Decimal("120.000")
        assert prefill.description == "Coca Cola · Big"
        assert prefill.tva_rate == Decimal("19")
        assert prefill.product_id == product.id
        assert prefill.variant_id == variant.id
        assert prefill.selling_unit_id is None
        assert prefill.pack_id is None

    def test_null_variant_price_falls_back_to_product(self, service, db):
        product = _product(db, price=Decimal("100.000"))
        variant = _variant(db, product, price=None)
        prefill = service.get_variant_for_invoice(product.id, variant.id)
        assert prefill.unit_price_ht == Decimal("100.000")

    def test_unknown_variant_is_404(self, service, db):
        product = _product(db)
        with pytest.raises(NotFoundError):
            service.get_variant_for_invoice(product.id, uuid.uuid4())

    def test_variant_of_other_product_is_422(self, service, db):
        product_a = _product(db, name="A")
        product_b = _product(db, name="B")
        foreign = _variant(db, product_b)
        with pytest.raises(ValidationError, match="does not belong"):
            service.get_variant_for_invoice(product_a.id, foreign.id)

    def test_archived_variant_is_422(self, service, db):
        from datetime import datetime, timezone

        product = _product(db)
        variant = _variant(db, product)
        variant.archived_at = datetime.now(timezone.utc)
        db.commit()
        with pytest.raises(BusinessRuleError, match="Archived variant"):
            service.get_variant_for_invoice(product.id, variant.id)

    def test_archived_product_gate_still_applies(self, service, db):
        from datetime import datetime, timezone

        product = _product(db)
        variant = _variant(db, product)
        product.archived_at = datetime.now(timezone.utc)
        db.commit()
        with pytest.raises(BusinessRuleError, match="Archived product"):
            service.get_variant_for_invoice(product.id, variant.id)

    def test_helper_is_pure(self, db):
        product = _product(db)
        variant = _variant(db, product, price=Decimal("120.000"))
        first = variant_line_prefill(product, variant)
        second = variant_line_prefill(product, variant)
        assert first == second
        assert first is not second


# ===========================================================================
# Selling-unit prefill
# ===========================================================================


class TestSellingUnitPrefill:
    def test_selling_price_wins(self, service, db):
        product = _product(db, price=Decimal("100.000"))
        unit = _unit(db, product, selling_price=Decimal("2200.000"))
        prefill = service.get_selling_unit_for_invoice(product.id, unit.id)
        assert prefill.unit_price_ht == Decimal("2200.000")
        assert prefill.description == "Coca Cola · Box"
        assert prefill.selling_unit_id == unit.id
        assert prefill.variant_id is None
        assert prefill.pack_id is None

    def test_null_selling_price_uses_product_price_as_is(self, service, db):
        """Multiplier 24 must NEVER multiply the price (domain rule)."""
        product = _product(db, price=Decimal("100.000"))
        unit = _unit(db, product, multiplier=Decimal("24"), selling_price=None)
        prefill = service.get_selling_unit_for_invoice(product.id, unit.id)
        assert prefill.unit_price_ht == Decimal("100.000")

    def test_unknown_unit_is_404(self, service, db):
        product = _product(db)
        with pytest.raises(NotFoundError):
            service.get_selling_unit_for_invoice(product.id, uuid.uuid4())

    def test_unit_of_other_product_is_422(self, service, db):
        product_a = _product(db, name="A")
        product_b = _product(db, name="B")
        foreign = _unit(db, product_b)
        with pytest.raises(ValidationError, match="does not belong"):
            service.get_selling_unit_for_invoice(product_a.id, foreign.id)

    def test_archived_unit_is_422(self, service, db):
        from datetime import datetime, timezone

        product = _product(db)
        unit = _unit(db, product)
        unit.archived_at = datetime.now(timezone.utc)
        db.commit()
        with pytest.raises(BusinessRuleError, match="Archived selling unit"):
            service.get_selling_unit_for_invoice(product.id, unit.id)

    def test_helper_is_pure(self, db):
        product = _product(db)
        unit = _unit(db, product, selling_price=Decimal("2200.000"))
        first = selling_unit_line_prefill(product, unit)
        second = selling_unit_line_prefill(product, unit)
        assert first == second
        assert first is not second


# ===========================================================================
# Pack prefill
# ===========================================================================


class TestPackPrefill:
    def test_pack_prefill_shape(self, service, db):
        pack = _pack(db, price=Decimal("250.000"))
        prefill = service.get_pack_for_invoice(pack.id)
        assert prefill.product_id is None
        assert prefill.description == "Pack Promo"
        assert prefill.unit_price_ht == Decimal("250.000")
        assert prefill.tva_rate == Decimal("0")
        assert prefill.pack_id == pack.id
        assert prefill.variant_id is None
        assert prefill.selling_unit_id is None

    def test_unknown_pack_is_404(self, service, db):
        with pytest.raises(NotFoundError):
            service.get_pack_for_invoice(uuid.uuid4())

    def test_inactive_pack_is_422(self, service, db):
        pack = _pack(db, is_active=False)
        with pytest.raises(BusinessRuleError, match="not active"):
            service.get_pack_for_invoice(pack.id)

    def test_archived_pack_is_422(self, service, db):
        from datetime import datetime, timezone

        pack = _pack(db)
        pack.archived_at = datetime.now(timezone.utc)
        db.commit()
        with pytest.raises(BusinessRuleError, match="not active"):
            service.get_pack_for_invoice(pack.id)

    def test_helper_is_pure(self, db):
        pack = _pack(db)
        first = pack_line_prefill(pack)
        second = pack_line_prefill(pack)
        assert first == second
        assert first is not second


# ===========================================================================
# Document create / preview — snapshot + isolation
# ===========================================================================


class TestOptionLineDocuments:
    def test_create_variant_line_snapshots_ids(self, docs, db):
        product = _product(db, price=Decimal("100.000"))
        variant = _variant(db, product, price=Decimal("120.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id,
                        variant_id=variant.id,
                        quantity=2,
                    )
                ],
            )
        )
        line = doc.lines[0]
        assert line.product_id == product.id
        assert line.variant_id == variant.id
        assert line.selling_unit_id is None
        assert line.pack_id is None
        assert line.description == "Coca Cola · Big"
        assert line.unit_price_ht == Decimal("120.000")
        assert line.tva_rate == Decimal("19")

    def test_create_unit_line_snapshots_ids(self, docs, db):
        product = _product(db)
        unit = _unit(db, product, selling_price=Decimal("2200.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id,
                        selling_unit_id=unit.id,
                        quantity=1,
                    )
                ],
            )
        )
        line = doc.lines[0]
        assert line.selling_unit_id == unit.id
        assert line.variant_id is None
        assert line.description == "Coca Cola · Box"
        assert line.unit_price_ht == Decimal("2200.000")

    def test_create_pack_line_product_id_null(self, docs, db):
        product = _product(db)
        other = _product(db, name="Water")
        pack = _pack(db, price=Decimal("250.000"))
        db.add(PackItem(pack_id=pack.id, product_id=product.id, quantity=1))
        db.add(PackItem(pack_id=pack.id, product_id=other.id, quantity=1))
        db.commit()
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [InvoiceLineRequest(pack_id=pack.id, quantity=1)],
            )
        )
        line = doc.lines[0]
        assert line.pack_id == pack.id
        assert line.product_id is None
        assert line.variant_id is None
        assert line.selling_unit_id is None
        assert line.description == "Pack Promo"
        assert line.unit_price_ht == Decimal("250.000")
        assert line.tva_rate == Decimal("0")

    def test_client_values_still_win_on_option_lines(self, docs, db):
        product = _product(db)
        variant = _variant(db, product, price=Decimal("120.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id,
                        variant_id=variant.id,
                        description="Custom label",
                        unit_price_ht=Decimal("99.900"),
                        tva_rate=Decimal("9"),
                        quantity=1,
                    )
                ],
            )
        )
        line = doc.lines[0]
        assert line.description == "Custom label"
        assert line.unit_price_ht == Decimal("99.900")
        assert line.tva_rate == Decimal("9")
        assert line.variant_id == variant.id

    def test_pack_tva_override_accepted(self, docs, db):
        pack = _pack(db)
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        pack_id=pack.id, tva_rate=Decimal("19"), quantity=1
                    )
                ],
            )
        )
        assert doc.lines[0].tva_rate == Decimal("19")

    def test_free_text_line_keeps_all_ids_null(self, docs, db):
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        description="Services",
                        unit_price_ht=Decimal("50.000"),
                        tva_rate=Decimal("9"),
                        quantity=1,
                    )
                ],
            )
        )
        line = doc.lines[0]
        assert line.product_id is None
        assert line.variant_id is None
        assert line.selling_unit_id is None
        assert line.pack_id is None

    def test_service_level_combination_guards(self, docs, db):
        """Direct (non-API) callers are equally protected.

        ``model_construct`` bypasses schema validation on purpose — the
        guards under test are the SERVICE-level mirrors.
        """
        with pytest.raises(ValidationError, match="pack_id cannot be combined"):
            docs._resolve_lines(
                [
                    InvoiceLineRequest.model_construct(
                        pack_id=uuid.uuid4(),
                        product_id=uuid.uuid4(),
                        variant_id=None,
                        selling_unit_id=None,
                        quantity=1,
                        description=None,
                        unit_price_ht=None,
                        tva_rate=None,
                        discount_pct=Decimal("0"),
                        position=None,
                    )
                ]
            )
        with pytest.raises(ValidationError, match="cannot be combined with variant"):
            docs._resolve_lines(
                [
                    InvoiceLineRequest.model_construct(
                        pack_id=None,
                        product_id=uuid.uuid4(),
                        variant_id=uuid.uuid4(),
                        selling_unit_id=uuid.uuid4(),
                        quantity=1,
                        description=None,
                        unit_price_ht=None,
                        tva_rate=None,
                        discount_pct=Decimal("0"),
                        position=None,
                    )
                ]
            )

    def test_preview_returns_option_ids(self, docs, db):
        product = _product(db)
        variant = _variant(db, product)
        client = _client(db)
        result = docs.preview(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id, variant_id=variant.id, quantity=1
                    )
                ],
            )
        )
        payload = build_line_fields(result.lines[0])
        assert payload["variant_id"] == variant.id
        assert payload["selling_unit_id"] is None
        assert payload["pack_id"] is None

    def test_plain_product_line_ids_stay_null(self, docs, db):
        product = _product(db)
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [InvoiceLineRequest(product_id=product.id, quantity=1)],
            )
        )
        line = doc.lines[0]
        assert line.product_id == product.id
        assert line.variant_id is None
        assert line.selling_unit_id is None
        assert line.pack_id is None
        # Plain product prefill is unchanged by Stage 3A.
        assert line.description == product_line_prefill(product).description
        assert line.unit_price_ht == Decimal("100.000")


# ===========================================================================
# Inventory isolation — the core safety contract
# ===========================================================================


class TestInventoryIsolation:
    def _assert_no_inventory_side_effects(self, db, *, product, variants=()):
        db.expire_all()
        movements = db.scalar(select(func.count()).select_from(InventoryMovement))
        assert movements == 0
        fresh_product = db.get(Product, product.id)
        assert fresh_product.quantity == 50
        for variant in variants:
            fresh_variant = db.get(ProductVariant, variant.id)
            assert fresh_variant.quantity == 10

    def test_variant_line_never_touches_stock(self, docs, db):
        product = _product(db)
        variant = _variant(db, product)
        client = _client(db)
        docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id, variant_id=variant.id, quantity=5
                    )
                ],
            )
        )
        self._assert_no_inventory_side_effects(db, product=product, variants=[variant])

    def test_unit_line_never_touches_stock(self, docs, db):
        product = _product(db)
        unit = _unit(db, product, multiplier=Decimal("24"))
        client = _client(db)
        docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id, selling_unit_id=unit.id, quantity=3
                    )
                ],
            )
        )
        self._assert_no_inventory_side_effects(db, product=product)

    def test_pack_line_never_touches_stock(self, docs, db):
        product = _product(db)
        other = _product(db, name="Water")
        pack = _pack(db)
        db.add(PackItem(pack_id=pack.id, product_id=product.id, quantity=2))
        db.add(PackItem(pack_id=pack.id, product_id=other.id, quantity=2))
        db.commit()
        client = _client(db)
        docs.create(
            _create_req(
                client.id,
                [InvoiceLineRequest(pack_id=pack.id, quantity=4)],
            )
        )
        self._assert_no_inventory_side_effects(db, product=product)
        assert db.get(Product, other.id).quantity == 50

    def test_product_line_never_touches_stock(self, docs, db):
        product = _product(db)
        client = _client(db)
        docs.create(
            _create_req(
                client.id,
                [InvoiceLineRequest(product_id=product.id, quantity=7)],
            )
        )
        self._assert_no_inventory_side_effects(db, product=product)


# ===========================================================================
# SET NULL resilience (option row deletion)
# ===========================================================================


class TestOptionDeletionResilience:
    def test_deleting_variant_nulls_link_keeps_snapshot(self, docs, db):
        product = _product(db, price=Decimal("100.000"))
        variant = _variant(db, product, price=Decimal("120.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id, variant_id=variant.id, quantity=1
                    )
                ],
            )
        )
        line_id = doc.lines[0].id
        db.execute(delete(ProductVariant).where(ProductVariant.id == variant.id))
        db.commit()
        stored = db.get(InvoiceDocumentLine, line_id)
        assert stored.variant_id is None
        assert stored.product_id == product.id
        assert stored.description == "Coca Cola · Big"
        assert stored.unit_price_ht == Decimal("120.000")

    def test_deleting_pack_nulls_link_keeps_snapshot(self, docs, db):
        pack = _pack(db, price=Decimal("250.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [InvoiceLineRequest(pack_id=pack.id, quantity=1)],
            )
        )
        line_id = doc.lines[0].id
        # PackItem FK would RESTRICT a pack with items — this pack has
        # none, mirroring a legacy/simple pack deletion.
        db.execute(delete(Pack).where(Pack.id == pack.id))
        db.commit()
        stored = db.get(InvoiceDocumentLine, line_id)
        assert stored.pack_id is None
        assert stored.description == "Pack Promo"
        assert stored.unit_price_ht == Decimal("250.000")
        assert stored.product_id is None

    def test_deleting_unit_nulls_link_keeps_snapshot(self, docs, db):
        product = _product(db)
        unit = _unit(db, product, selling_price=Decimal("2200.000"))
        client = _client(db)
        doc = docs.create(
            _create_req(
                client.id,
                [
                    InvoiceLineRequest(
                        product_id=product.id, selling_unit_id=unit.id, quantity=1
                    )
                ],
            )
        )
        line_id = doc.lines[0].id
        db.execute(
            delete(ProductSellingUnit).where(ProductSellingUnit.id == unit.id)
        )
        db.commit()
        stored = db.get(InvoiceDocumentLine, line_id)
        assert stored.selling_unit_id is None
        assert stored.description == "Coca Cola · Box"
        assert stored.unit_price_ht == Decimal("2200.000")
