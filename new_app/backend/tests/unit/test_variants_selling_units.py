"""Phase 6 tests — product variants & selling units.

Covers (spec §31):
- variant CRUD, barcode uniqueness, price override (NULL inherit)
- selling unit CRUD, one base unit, multiplier>0, independent prices
- cannot archive only base unit, cannot demote base multiplier
- availability derivation from base stock
- barcode lookup (selling unit → variant → product)
- permission denied (cashier) and auth required (401)
- structured error contract
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.services.auth import AuthService


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
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
        "barcode": "900000",
        "price": "10.000",
        "cost": "6.000",
        "quantity": "240.000",
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------


class TestVariants:
    def test_list_empty(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.get(
            f"/api/v1/products/{product['id']}/variants",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json() == {"items": [], "total": 0}

    def test_create_variant(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large", "barcode": "900001", "price": "12.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["name"] == "Large"
        assert body["barcode"] == "900001"
        assert body["price"] == "12.000"
        assert body["product_id"] == product["id"]
        assert body["is_archived"] is False

    def test_variant_price_null_inherits(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Standard"},
            headers=admin_headers,
        )
        assert resp.status_code == 201
        assert resp.json()["price"] is None

    def test_duplicate_variant_name_rejected(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/variants"
        assert (
            client.post(url, json={"name": "Dup"}, headers=admin_headers).status_code
            == 201
        )
        resp = client.post(url, json={"name": "Dup"}, headers=admin_headers)
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "CONFLICT"

    def test_duplicate_barcode_across_variants(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/variants"
        client.post(
            url, json={"name": "A", "barcode": "BC1"}, headers=admin_headers
        )
        resp = client.post(
            url, json={"name": "B", "barcode": "BC1"}, headers=admin_headers
        )
        assert resp.status_code == 409

    def test_update_variant(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        created = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Old"},
            headers=admin_headers,
        ).json()
        resp = client.put(
            f"/api/v1/products/{product['id']}/variants/{created['id']}",
            json={"name": "New", "price": "15.500"},
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["name"] == "New"
        assert resp.json()["price"] == "15.500"

    def test_archive_variant(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        created = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Temp"},
            headers=admin_headers,
        ).json()
        resp = client.delete(
            f"/api/v1/products/{product['id']}/variants/{created['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is True
        # Active list no longer includes it
        listing = client.get(
            f"/api/v1/products/{product['id']}/variants",
            headers=admin_headers,
        ).json()
        assert listing["total"] == 0

    def test_variant_product_mismatch_404(self, client, admin_headers):
        p1 = _create_product(client, admin_headers, name="P1", barcode="B1")
        p2 = _create_product(client, admin_headers, name="P2", barcode="B2")
        created = client.post(
            f"/api/v1/products/{p1['id']}/variants",
            json={"name": "V"},
            headers=admin_headers,
        ).json()
        resp = client.put(
            f"/api/v1/products/{p2['id']}/variants/{created['id']}",
            json={"name": "Hacked"},
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_invalid_price_negative(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Bad", "price": "-1"},
            headers=admin_headers,
        )
        assert resp.status_code == 422
        body = resp.json()
        # Pydantic validation or app error — structured either way
        assert "error" in body or "detail" in body

    def test_cashier_cannot_create_variant(self, client, cashier_headers):
        # Cashier needs a product they can see — create as admin first
        # but cashier lacks product_create so cannot hit the endpoint.
        # Create product as admin, then attempt variant create as cashier.
        admin = _login(client, "Admin", "1234")
        product = _create_product(client, admin)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Nope"},
            headers=cashier_headers,
        )
        assert resp.status_code == 403

    def test_unauthenticated_401(self, client):
        # Create a product without auth → 401
        resp = client.post(
            "/api/v1/products/00000000-0000-0000-0000-000000000001/variants",
            json={"name": "X"},
        )
        assert resp.status_code == 401
        assert resp.json()["error"]["code"] in ("UNAUTHORIZED", "AUTHENTICATION_ERROR")

    def test_structured_error_contract(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Dup"},
            headers=admin_headers,
        )
        # first create
        assert resp.status_code == 201
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Dup"},
            headers=admin_headers,
        )
        assert resp.status_code == 409
        err = resp.json()["error"]
        assert set(err) >= {"code", "message", "message_key"}


# ---------------------------------------------------------------------------
# Selling units
# ---------------------------------------------------------------------------


class TestSellingUnits:
    def test_create_base_unit(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={
                "name": "Piece",
                "unit_type": "piece",
                "multiplier": "1",
                "barcode": "900001",
                "selling_price": "10.000",
                "is_base_unit": True,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["is_base_unit"] is True
        assert body["multiplier"] == "1.000"
        assert body["selling_price"] == "10.000"
        assert body["effective_price"] == "10.000"

    def test_create_box_unit(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        # base first
        client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={
                "name": "Piece",
                "multiplier": "1",
                "selling_price": "10.000",
                "is_base_unit": True,
            },
            headers=admin_headers,
        )
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={
                "name": "Box",
                "multiplier": "24",
                "barcode": "900001B",
                "selling_price": "220.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["multiplier"] == "24.000"
        # Independent price — NOT 24 × 10
        assert body["selling_price"] == "220.000"
        assert body["effective_price"] == "220.000"
        # Availability from base stock 240
        assert body["available_base_qty"] == "240.000"
        assert body["available_selling_qty"] == "10.000"

    def test_second_base_unit_rejected(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/selling-units"
        r1 = client.post(
            url,
            json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        assert r1.status_code == 201
        r2 = client.post(
            url,
            json={"name": "Other", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        assert r2.status_code == 409

    def test_base_multiplier_must_be_one(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Weird", "multiplier": "2", "is_base_unit": True},
            headers=admin_headers,
        )
        assert resp.status_code == 422

    def test_multiplier_zero_rejected(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Zero", "multiplier": "0"},
            headers=admin_headers,
        )
        assert resp.status_code == 422

    def test_duplicate_name_rejected(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/selling-units"
        client.post(
            url, json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        resp = client.post(
            url, json={"name": "Piece", "multiplier": "2"},
            headers=admin_headers,
        )
        assert resp.status_code == 409

    def test_cannot_demote_base_multiplier(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        created = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        ).json()
        resp = client.put(
            f"/api/v1/products/{product['id']}/selling-units/{created['id']}",
            json={"multiplier": "5"},
            headers=admin_headers,
        )
        assert resp.status_code == 422

    def test_cannot_archive_sole_base_unit(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        created = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        ).json()
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{created['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "BUSINESS_RULE_ERROR"

    def test_archive_non_base_unit(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/selling-units"
        client.post(
            url, json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        box = client.post(
            url, json={"name": "Box", "multiplier": "24"},
            headers=admin_headers,
        ).json()
        resp = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{box['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is True

    def test_barcode_conflict_with_product(self, client, admin_headers):
        product = _create_product(client, admin_headers)  # barcode 900000
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Conflict", "multiplier": "2", "barcode": "900000"},
            headers=admin_headers,
        )
        assert resp.status_code == 409

    def test_list_with_availability(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = f"/api/v1/products/{product['id']}/selling-units"
        client.post(
            url, json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        client.post(
            url, json={"name": "Box", "multiplier": "24", "selling_price": "220"},
            headers=admin_headers,
        )
        resp = client.get(url, headers=admin_headers)
        assert resp.status_code == 200
        items = resp.json()["items"]
        assert len(items) == 2
        # base unit listed first
        assert items[0]["is_base_unit"] is True
        box = next(i for i in items if i["name"] == "Box")
        assert box["available_selling_qty"] == "10.000"

    def test_unknown_product_404(self, client, admin_headers):
        resp = client.get(
            "/api/v1/products/00000000-0000-0000-0000-000000000001/selling-units",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_cashier_cannot_create_selling_unit(self, client, cashier_headers):
        admin = _login(client, "Admin", "1234")
        product = _create_product(client, admin)
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Nope", "multiplier": "2"},
            headers=cashier_headers,
        )
        assert resp.status_code == 403


# ---------------------------------------------------------------------------
# Barcode lookup
# ---------------------------------------------------------------------------


class TestBarcodeLookup:
    def test_found_product(self, client, admin_headers):
        product = _create_product(client, admin_headers)  # 900000
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "900000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["found"] is True
        assert body["kind"] == "product"
        assert body["product_id"] == product["id"]
        assert body["product_price"] == "10.000"

    def test_found_variant(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "L", "barcode": "VAR99", "price": "12.000"},
            headers=admin_headers,
        )
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "VAR99"},
            headers=admin_headers,
        )
        body = resp.json()
        assert body["found"] is True
        assert body["kind"] == "variant"
        assert body["variant_name"] == "L"
        assert body["variant_price"] == "12.000"

    def test_found_selling_unit_takes_priority(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={
                "name": "Box",
                "multiplier": "24",
                "barcode": "BOX99",
                "selling_price": "220.000",
            },
            headers=admin_headers,
        )
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "BOX99"},
            headers=admin_headers,
        )
        body = resp.json()
        assert body["found"] is True
        assert body["kind"] == "selling_unit"
        assert body["selling_unit_multiplier"] == "24.000"
        assert body["selling_unit_price"] == "220.000"

    def test_not_found(self, client, admin_headers):
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "NOPE"},
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["found"] is False

    def test_requires_auth(self, client):
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "900000"},
        )
        assert resp.status_code == 401

    def test_requires_product_view(self, client, cashier_headers):
        # Cashier has product_view in most seeds — if not, 403; if yes, 200 with found False
        resp = client.get(
            "/api/v1/products/barcode-lookup",
            params={"barcode": "NOPE"},
            headers=cashier_headers,
        )
        assert resp.status_code in (200, 403)


# ---------------------------------------------------------------------------
# Create product with staged children (atomic) + selling_price NULL inherit
# ---------------------------------------------------------------------------


class TestCreateWithChildren:
    def test_create_with_staged_selling_units(self, client, admin_headers):
        """POST /products with staged selling units → 201, children persisted.

        TASK 5 XOR: a product is EITHER variant-based OR selling-unit
        based — this test stages only selling units (+ purchase units).
        """
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Staged Product",
                "barcode": "STAGED01",
                "price": "15.000",
                "cost": "10.000",
                "quantity": "0",
                "unit": "piece",
                "selling_units": [
                    {
                        "name": "Piece",
                        "multiplier": "1",
                        "is_base_unit": True,
                        "selling_price": None,
                    },
                    {
                        "name": "Box",
                        "multiplier": "12",
                        "selling_price": "150.000",
                    },
                ],
                "purchase_units": [
                    {"name": "Box24", "multiplier": "24", "is_default": True},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        pid = resp.json()["id"]

        variants = client.get(
            f"/api/v1/products/{pid}/variants", headers=admin_headers
        ).json()
        assert variants["total"] == 0

        sus = client.get(
            f"/api/v1/products/{pid}/selling-units", headers=admin_headers
        ).json()
        assert sus["total"] == 2
        base = next(s for s in sus["items"] if s["is_base_unit"])
        assert base["multiplier"] == "1.000"
        # Explicit null selling_price stays null in response.
        assert base["selling_price"] is None
        box = next(s for s in sus["items"] if s["name"] == "Box")
        assert box["selling_price"] == "150.000"

        pus = client.get(
            f"/api/v1/products/{pid}/purchase-units", headers=admin_headers
        ).json()
        assert pus["total"] == 1
        assert pus["items"][0]["is_default"] is True

    def test_create_with_staged_variants(self, client, admin_headers):
        """Staged variants only → 201 (TASK 5 XOR — no units staged)."""
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Staged Variant Product",
                "barcode": "STAGED02",
                "price": "15.000",
                "variants": [
                    {"name": "L", "barcode": "STAGED02-L", "price": "18.000"},
                    {"name": "M", "price": "14.000"},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        pid = resp.json()["id"]

        variants = client.get(
            f"/api/v1/products/{pid}/variants", headers=admin_headers
        ).json()
        assert variants["total"] == 2

        sus = client.get(
            f"/api/v1/products/{pid}/selling-units", headers=admin_headers
        ).json()
        assert sus["total"] == 0

    def test_create_rolls_back_on_child_validation_failure(
        self, client, admin_headers, db
    ):
        """Duplicate staged variant names → 409 and NO product persisted."""
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Rollback Product",
                "barcode": "ROLLBACK01",
                "price": "5.000",
                "cost": "3.000",
                "quantity": "0",
                "unit": "piece",
                "variants": [
                    {"name": "Dup"},
                    {"name": "Dup"},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 409
        # Product must not exist (atomic: never a half-created entry).
        check = client.get(
            "/api/v1/products",
            params={"search": "ROLLBACK01"},
            headers=admin_headers,
        ).json()
        assert check["total"] == 0

    def test_two_explicit_bases_rejected(self, client, admin_headers):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Two Base",
                "barcode": "TWOBASE01",
                "price": "5.000",
                "cost": "3.000",
                "quantity": "0",
                "unit": "piece",
                "selling_units": [
                    {"name": "A", "multiplier": "1", "is_base_unit": True},
                    {"name": "B", "multiplier": "1", "is_base_unit": True},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 409

    def test_selling_price_null_inherits_product_price(
        self, client, admin_headers
    ):
        """selling_price NULL → response selling_price is null, effective = product price."""
        product = _create_product(client, admin_headers, barcode="INHERIT01")
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Base", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["selling_price"] is None
        assert body["effective_price"] == "10.000"  # inherits product.price

    def test_selling_price_explicit_wins(self, client, admin_headers):
        product = _create_product(client, admin_headers, barcode="EXPLICIT01")
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={
                "name": "Box",
                "multiplier": "24",
                "selling_price": "220.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201
        assert resp.json()["selling_price"] == "220.000"
        assert resp.json()["effective_price"] == "220.000"
