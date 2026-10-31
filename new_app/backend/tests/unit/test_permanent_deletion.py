"""Permanent (hard) deletion tests — variants, selling units, purchase units.

Covers (TASK safe permanent deletion):
- permanent deletion succeeds when no references exist (204)
- permanent deletion is rejected when references exist (409 + details)
  — EVERY foreign-key relationship is exercised, not just samples:
    variant: sale_lines, purchase_lines, return_lines, inventory_movements,
             pack_items, invoice_document_lines
    selling unit: pack_items, invoice_document_lines
    purchase unit: purchase_lines, inventory_movements,
                   product_stock_packages (sealed stock)
- archive (default behavior) is unchanged
- nonexistent IDs return 404
- historical records remain unchanged after a blocked delete
- database RESTRICT constraints backstop a bypassed application check
- permission contract (cashier 403, auth 401)
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Pack, PackItem, ProductStockPackage
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentLine,
)
from app.models.inventory import InventoryMovement
from app.models.purchase import Purchase, PurchaseLine
from app.models.return_doc import Return, ReturnLine
from app.models.sale import Sale, SaleLine
from app.services.auth import AuthService


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    # Enforce foreign keys so the DB-level RESTRICT backstop can be
    # verified exactly as PostgreSQL enforces it in production.
    @event.listens_for(eng, "connect")
    def _fk_on(dbapi_conn, _record):
        dbapi_conn.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def TestingSession(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, TestingSession):
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    yield session
    session.close()


@pytest.fixture()
def client(engine, TestingSession, db):
    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": pin}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


def _create_product(client, headers, **overrides) -> dict:
    payload = {
        "name": "Fromage Test",
        "barcode": f"PD{uuid.uuid4().hex[:8]}",
        "price": "10.000",
        "cost": "6.000",
        "quantity": "240.000",
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_variant(client, headers, product_id, **overrides) -> dict:
    payload = {"name": overrides.pop("name", "Large")}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/variants",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_selling_unit(client, headers, product_id, **overrides) -> dict:
    payload = {"name": overrides.pop("name", "Box")}
    if overrides.get("is_base_unit"):
        payload["multiplier"] = overrides.pop("multiplier", "1")
    else:
        payload["multiplier"] = overrides.pop("multiplier", "24")
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/selling-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_purchase_unit(client, headers, product_id, **overrides) -> dict:
    payload = {"name": overrides.pop("name", "Carton"), "multiplier": "48"}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/purchase-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _delete(client, headers, url) -> dict:
    resp = client.delete(url, headers=headers)
    return {"status": resp.status_code, "body": resp.json() if resp.content else {}}


def _assert_blocked(result: dict, expected_table: str) -> None:
    assert result["status"] == 409, result
    error = result["body"]["error"]
    assert error["code"] == "CONFLICT"
    assert error["details"]["archive_recommended"] is True
    assert expected_table in error["details"]["references"]
    assert error["details"]["references"][expected_table] >= 1


# ---------------------------------------------------------------------------
# Reference-row factories (direct DB inserts, one per FK relationship)
# ---------------------------------------------------------------------------


def _sale_with_line(db, product_id, variant_id=None) -> SaleLine:
    sale = Sale(
        invoice_number=f"INV-{uuid.uuid4().hex[:10]}",
        subtotal=10.0,
        discount=0.0,
        total=10.0,
        paid=10.0,
        change=0.0,
    )
    db.add(sale)
    db.flush()
    line = SaleLine(
        sale_id=sale.id,
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id) if variant_id else None,
        product_name="Fromage",
        product_unit="piece",
        variant_name="Large" if variant_id else None,
        unit_price=10.0,
        unit_cost=6.0,
        quantity=1.0,
        line_discount=0.0,
        line_total=10.0,
    )
    db.add(line)
    db.commit()
    return line


def _purchase_with_line(db, product_id, variant_id=None, purchase_unit_id=None):
    purchase = Purchase(
        invoice_number=f"PUR-{uuid.uuid4().hex[:10]}",
        subtotal=10.0,
        total=10.0,
        paid=10.0,
    )
    db.add(purchase)
    db.flush()
    line = PurchaseLine(
        purchase_id=purchase.id,
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id) if variant_id else None,
        product_name="Fromage",
        product_unit="piece",
        unit_cost=6.0,
        quantity=1.0,
        line_total=6.0,
        purchase_unit_id=uuid.UUID(purchase_unit_id) if purchase_unit_id else None,
        purchase_unit_name="Carton" if purchase_unit_id else None,
        unit_multiplier=48.0 if purchase_unit_id else None,
    )
    db.add(line)
    db.commit()
    return line


def _return_with_line(db, product_id, variant_id):
    ret = Return(return_number=f"RET-{uuid.uuid4().hex[:10]}", total=10.0)
    db.add(ret)
    db.flush()
    line = ReturnLine(
        return_id=ret.id,
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id),
        product_name="Fromage",
        product_unit="piece",
        variant_name="Large",
        unit_price=10.0,
        quantity=1.0,
        line_total=10.0,
    )
    db.add(line)
    db.commit()
    return line


def _movement(db, product_id, variant_id=None, purchase_unit_id=None):
    row = InventoryMovement(
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id) if variant_id else None,
        movement_type="adjustment",
        quantity_change=1.0,
        quantity_before=0.0,
        quantity_after=1.0,
        purchase_unit_id=uuid.UUID(purchase_unit_id) if purchase_unit_id else None,
    )
    db.add(row)
    db.commit()
    return row


def _pack_with_item(db, product_id, variant_id=None, selling_unit_id=None):
    pack = Pack(name=f"Pack {uuid.uuid4().hex[:6]}", price=20.0)
    db.add(pack)
    db.flush()
    item = PackItem(
        pack_id=pack.id,
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id) if variant_id else None,
        selling_unit_id=uuid.UUID(selling_unit_id) if selling_unit_id else None,
        quantity=1.0,
    )
    db.add(item)
    db.commit()
    return item


def _invoice_with_line(db, product_id, variant_id=None, selling_unit_id=None):
    client_row = InvoiceClient(name=f"Client {uuid.uuid4().hex[:6]}")
    db.add(client_row)
    db.flush()
    doc = InvoiceDocument(
        doc_type="FAC",
        number=f"N{uuid.uuid4().hex[:8]}",
        year=2026,
        document_date=date(2026, 1, 15),
        client_id=client_row.id,
    )
    db.add(doc)
    db.flush()
    line = InvoiceDocumentLine(
        document_id=doc.id,
        product_id=uuid.UUID(product_id),
        variant_id=uuid.UUID(variant_id) if variant_id else None,
        selling_unit_id=uuid.UUID(selling_unit_id) if selling_unit_id else None,
        description="Fromage",
        quantity=1.0,
        unit_price_ht=10.0,
        tva_rate=19.0,
    )
    db.add(line)
    db.commit()
    return line


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------


class TestVariantPermanentDelete:
    def test_delete_unreferenced_variant_permanently(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        url = (
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true"
        )
        resp = client.delete(url, headers=admin_headers)
        assert resp.status_code == 204, resp.text
        listing = client.get(
            f"/api/v1/products/{product['id']}/variants"
            "?include_archived=true",
            headers=admin_headers,
        ).json()
        assert listing["total"] == 0

    def test_default_behavior_still_archives(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is True

    def test_explicit_permanent_false_archives(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=false",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is True

    def test_delete_archived_variant_permanently(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}",
            headers=admin_headers,
        )
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text

    def test_nonexistent_variant_404(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{uuid.uuid4()}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "NOT_FOUND"

    def test_product_mismatch_404(self, client, admin_headers):
        p1 = _create_product(client, admin_headers, name="P1")
        p2 = _create_product(client, admin_headers, name="P2")
        variant = _create_variant(client, admin_headers, p1["id"])
        resp = client.delete(
            f"/api/v1/products/{p2['id']}/variants/{variant['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_cashier_cannot_delete_permanently(self, client, admin_headers,
                                               cashier_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
            headers=cashier_headers,
        )
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "FORBIDDEN"

    def test_anonymous_cannot_delete_permanently(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
        )
        assert resp.status_code == 401

    @pytest.mark.parametrize(
        "factory,expected_table",
        [
            ("sale_line", "sale_lines"),
            ("purchase_line", "purchase_lines"),
            ("return_line", "return_lines"),
            ("movement", "inventory_movements"),
            ("pack_item", "pack_items"),
            ("invoice_line", "invoice_document_lines"),
        ],
    )
    def test_blocked_by_every_referencing_table(
        self, client, admin_headers, db, factory, expected_table
    ):
        """One test per FK: every referencing table blocks deletion."""
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        factories = {
            "sale_line": lambda: _sale_with_line(
                db, product["id"], variant["id"]
            ),
            "purchase_line": lambda: _purchase_with_line(
                db, product["id"], variant["id"]
            ),
            "return_line": lambda: _return_with_line(
                db, product["id"], variant["id"]
            ),
            "movement": lambda: _movement(db, product["id"], variant["id"]),
            "pack_item": lambda: _pack_with_item(
                db, product["id"], variant["id"]
            ),
            "invoice_line": lambda: _invoice_with_line(
                db, product["id"], variant["id"]
            ),
        }
        reference = factories[factory]()

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, expected_table)

        # The variant still exists (even archived-included listing).
        listing = client.get(
            f"/api/v1/products/{product['id']}/variants"
            "?include_archived=true",
            headers=admin_headers,
        ).json()
        assert listing["total"] == 1

        # Historical reference is untouched.
        assert db.get(type(reference), reference.id) is not None

    def test_blocked_delete_leaves_sale_history_intact(
        self, client, admin_headers, db
    ):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        line = _sale_with_line(db, product["id"], variant["id"])
        sale_id = line.sale_id

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "sale_lines")

        # Sale header + line + variant all survive byte-for-byte.
        sale = db.get(Sale, sale_id)
        assert sale is not None
        assert sale.total == 10.0
        line_db = db.get(SaleLine, line.id)
        assert line_db is not None
        assert line_db.variant_id == uuid.UUID(variant["id"])
        assert line_db.variant_name == "Large"

    def test_multiple_references_all_reported(
        self, client, admin_headers, db
    ):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        _sale_with_line(db, product["id"], variant["id"])
        _movement(db, product["id"], variant["id"])

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
        )
        assert result["status"] == 409
        refs = result["body"]["error"]["details"]["references"]
        assert "sale_lines" in refs
        assert "inventory_movements" in refs

    def test_db_restrict_backstop_when_app_check_bypassed(
        self, client, admin_headers, db, monkeypatch
    ):
        """Race defense: if the app-level check is somehow bypassed, the
        ON DELETE RESTRICT constraint still refuses the delete and the
        client receives a 409 — never silent history loss."""
        from app.services.catalog import ProductVariantService

        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        line = _sale_with_line(db, product["id"], variant["id"])

        monkeypatch.setattr(
            ProductVariantService,
            "_blocking_references",
            lambda self, vid: {},
        )
        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
        )
        assert result["status"] == 409
        assert result["body"]["error"]["code"] == "DATABASE_CONSTRAINT"
        assert db.get(SaleLine, line.id) is not None
        from app.models.catalog import ProductVariant

        assert db.get(ProductVariant, uuid.UUID(variant["id"])) is not None


# ---------------------------------------------------------------------------
# Selling units
# ---------------------------------------------------------------------------


class TestSellingUnitPermanentDelete:
    def test_delete_unreferenced_selling_unit_permanently(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _create_selling_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text
        listing = client.get(
            f"/api/v1/products/{product['id']}/selling-units"
            "?include_archived=true",
            headers=admin_headers,
        ).json()
        assert listing["total"] == 0

    def test_delete_sole_base_unit_permanently_allowed(
        self, client, admin_headers
    ):
        """Permanent delete is explicit — unlike archive, the sole base
        unit may be removed when nothing references it (the product
        stays saleable in base pieces)."""
        product = _create_product(client, admin_headers)
        unit = _create_selling_unit(
            client, admin_headers, product["id"], is_base_unit=True
        )
        # Archive of the sole base unit is still blocked (regression).
        archive = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}",
            headers=admin_headers,
        )
        assert archive.status_code == 422
        # Permanent delete of the same unreferenced unit succeeds.
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text

    def test_default_behavior_still_archives(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        _create_selling_unit(
            client, admin_headers, product["id"], name="Base", is_base_unit=True
        )
        unit = _create_selling_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is True

    def test_nonexistent_unit_404(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{uuid.uuid4()}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_product_mismatch_404(self, client, admin_headers):
        p1 = _create_product(client, admin_headers, name="P1")
        p2 = _create_product(client, admin_headers, name="P2")
        unit = _create_selling_unit(client, admin_headers, p1["id"])
        resp = client.delete(
            f"/api/v1/products/{p2['id']}/selling-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_cashier_cannot_delete_permanently(
        self, client, admin_headers, cashier_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _create_selling_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}"
            "?permanent=true",
            headers=cashier_headers,
        )
        assert resp.status_code == 403

    def test_blocked_by_pack_item(self, client, admin_headers, db):
        product = _create_product(client, admin_headers)
        unit = _create_selling_unit(client, admin_headers, product["id"])
        item = _pack_with_item(
            db, product["id"], selling_unit_id=unit["id"]
        )

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "pack_items")

        # SET NULL was NOT applied — the pack link survives untouched.
        db.refresh(item)
        assert item.selling_unit_id == uuid.UUID(unit["id"])

    def test_blocked_by_invoice_document_line(self, client, admin_headers, db):
        product = _create_product(client, admin_headers)
        unit = _create_selling_unit(client, admin_headers, product["id"])
        line = _invoice_with_line(
            db, product["id"], selling_unit_id=unit["id"]
        )

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "invoice_document_lines")

        db.refresh(line)
        assert line.selling_unit_id == uuid.UUID(unit["id"])
        assert line.description == "Fromage"


# ---------------------------------------------------------------------------
# Purchase units
# ---------------------------------------------------------------------------


class TestPurchaseUnitPermanentDelete:
    def test_delete_unreferenced_purchase_unit_permanently(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text
        listing = client.get(
            f"/api/v1/products/{product['id']}/purchase-units"
            "?include_archived=true",
            headers=admin_headers,
        ).json()
        assert listing["total"] == 0

    def test_delete_archived_purchase_unit_permanently(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        archive = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}",
            headers=admin_headers,
        )
        assert archive.status_code == 204
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text

    def test_default_behavior_still_archives(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 204
        listing = client.get(
            f"/api/v1/products/{product['id']}/purchase-units"
            "?include_archived=true",
            headers=admin_headers,
        ).json()
        assert listing["items"][0]["is_archived"] is True

    def test_nonexistent_unit_404(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{uuid.uuid4()}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_product_mismatch_404(self, client, admin_headers):
        p1 = _create_product(client, admin_headers, name="P1")
        p2 = _create_product(client, admin_headers, name="P2")
        unit = _create_purchase_unit(client, admin_headers, p1["id"])
        resp = client.delete(
            f"/api/v1/products/{p2['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_cashier_cannot_delete_permanently(
        self, client, admin_headers, cashier_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
            headers=cashier_headers,
        )
        assert resp.status_code == 403

    def test_blocked_by_purchase_line(self, client, admin_headers, db):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        line = _purchase_with_line(
            db, product["id"], purchase_unit_id=unit["id"]
        )

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "purchase_lines")

        db.refresh(line)
        assert line.purchase_unit_id == uuid.UUID(unit["id"])
        assert line.purchase_unit_name == "Carton"

    def test_blocked_by_inventory_movement(self, client, admin_headers, db):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        row = _movement(
            db, product["id"], purchase_unit_id=unit["id"]
        )

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "inventory_movements")

        db.refresh(row)
        assert row.purchase_unit_id == uuid.UUID(unit["id"])

    def test_blocked_by_sealed_stock_packages(self, client, admin_headers, db):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        pkg = ProductStockPackage(
            product_id=uuid.UUID(product["id"]),
            purchase_unit_id=uuid.UUID(unit["id"]),
            full_packages=Decimal("5"),
        )
        db.add(pkg)
        db.commit()

        result = _delete(
            client,
            admin_headers,
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
        )
        _assert_blocked(result, "product_stock_packages")

        # Sealed stock was NOT cascade-destroyed.
        db.refresh(pkg)
        assert pkg.full_packages == Decimal("5")

    def test_allowed_when_stock_package_row_is_inert(
        self, client, admin_headers, db
    ):
        """A zero-count bookkeeping row is not business data: it is
        cascade-removed with the unit and loses nothing."""
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        pkg = ProductStockPackage(
            product_id=uuid.UUID(product["id"]),
            purchase_unit_id=uuid.UUID(unit["id"]),
            full_packages=Decimal("0"),
        )
        db.add(pkg)
        db.commit()

        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text
        remaining = db.scalars(
            select(ProductStockPackage).where(
                ProductStockPackage.purchase_unit_id == uuid.UUID(unit["id"])
            )
        ).all()
        assert remaining == []

    def test_archive_blocked_by_sealed_stock_still_regression(
        self, client, admin_headers, db
    ):
        product = _create_product(client, admin_headers)
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        db.add(
            ProductStockPackage(
                product_id=uuid.UUID(product["id"]),
                purchase_unit_id=uuid.UUID(unit["id"]),
                full_packages=Decimal("3"),
            )
        )
        db.commit()
        resp = client.delete(
            f"/api/v1/products/{product['id']}/purchase-units/{unit['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Regression: existing workflows unaffected
# ---------------------------------------------------------------------------


class TestRegression:
    def test_product_create_with_staged_children_still_works(
        self, client, admin_headers
    ):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Staged",
                "barcode": "STAGED1",
                "price": "5.000",
                "variants": [{"name": "Red"}],
                "selling_units": [
                    {"name": "Piece", "multiplier": "1", "is_base_unit": True}
                ],
                "purchase_units": [{"name": "Box", "multiplier": "12"}],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_variant_update_and_archive_still_work(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        variant = _create_variant(client, admin_headers, product["id"])
        upd = client.put(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}",
            json={"name": "Renamed", "price": "12.500"},
            headers=admin_headers,
        )
        assert upd.status_code == 200
        assert upd.json()["name"] == "Renamed"
        arch = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}",
            headers=admin_headers,
        )
        assert arch.status_code == 200
        assert arch.json()["is_archived"] is True

    def test_barcode_freed_after_permanent_delete(
        self, client, admin_headers
    ):
        """After a successful hard delete the barcode may be reused."""
        product = _create_product(client, admin_headers)
        variant = _create_variant(
            client, admin_headers, product["id"], barcode="FREE123"
        )
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}"
            "?permanent=true",
            headers=admin_headers,
        )
        assert resp.status_code == 204
        again = _create_variant(
            client, admin_headers, product["id"], barcode="FREE123"
        )
        assert again["barcode"] == "FREE123"
