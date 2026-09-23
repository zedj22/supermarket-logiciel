"""Phase 6 purchase-unit endpoint + service regression tests.

Covers the runtime bug fix (ProductRepository had no `.get`):
- valid create → 201 (real route + real service + real ProductRepository)
- nonexistent product → structured 404 (code/message/request_id)
- invalid multiplier → 422
- duplicate name → 409
- duplicate barcode → 409
- cashier (no product_create) → 403
- list via GET → 200 with created items
- persistence across a fresh session/request
- packaging-state GET still works (same _get_product path)
- service-level create_unit against real ProductRepository
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
from app.schemas.catalog import PurchaseUnitCreateRequest
from app.services.auth import AuthService
from app.services.catalog import ProductRepository, PurchaseUnitService


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
        "name": "Fromage Endpoint",
        "barcode": "PU900001",
        "price": "10.000",
        "cost": "6.000",
        "quantity": "240.000",
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _unit_url(product_id: str) -> str:
    return f"/api/v1/products/{product_id}/purchase-units"


class TestPurchaseUnitEndpoints:
    def test_valid_create_201(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            _unit_url(product["id"]),
            json={
                "name": "Box",
                "unit_type": "piece",
                "multiplier": "24",
                "barcode": "PUBOX001",
                "is_default": True,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["name"] == "Box"
        assert body["multiplier"] in ("24", "24.000")
        assert body["product_id"] == product["id"]
        assert body["is_default"] is True
        assert "selling_price" not in body

    def test_nonexistent_product_404_structured(self, client, admin_headers):
        resp = client.post(
            "/api/v1/products/00000000-0000-0000-0000-000000000001/purchase-units",
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        assert resp.status_code == 404, resp.text
        err = resp.json()["error"]
        assert err["code"] == "NOT_FOUND"
        assert err["message"] == "Product not found"
        assert err["details"]["product_id"] == "00000000-0000-0000-0000-000000000001"
        assert "request_id" in err

    def test_invalid_multiplier_422(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            _unit_url(product["id"]),
            json={"name": "Zero", "unit_type": "piece", "multiplier": "0"},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    def test_duplicate_name_409(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = _unit_url(product["id"])
        first = client.post(
            url,
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        assert first.status_code == 201, first.text
        second = client.post(
            url,
            json={"name": "Box", "unit_type": "piece", "multiplier": "48"},
            headers=admin_headers,
        )
        assert second.status_code == 409, second.text

    def test_duplicate_barcode_409(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = _unit_url(product["id"])
        first = client.post(
            url,
            json={
                "name": "Box",
                "unit_type": "piece",
                "multiplier": "24",
                "barcode": "PUDUP001",
            },
            headers=admin_headers,
        )
        assert first.status_code == 201, first.text
        second = client.post(
            url,
            json={
                "name": "Carton",
                "unit_type": "piece",
                "multiplier": "48",
                "barcode": "PUDUP001",
            },
            headers=admin_headers,
        )
        assert second.status_code == 409, second.text

    def test_cashier_cannot_create_403(self, client, admin_headers, cashier_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            _unit_url(product["id"]),
            json={"name": "Nope", "unit_type": "piece", "multiplier": "2"},
            headers=cashier_headers,
        )
        assert resp.status_code == 403

    def test_list_get_200(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        url = _unit_url(product["id"])
        created = client.post(
            url,
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        assert created.status_code == 201, created.text
        resp = client.get(url, headers=admin_headers)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["total"] == 1
        assert body["items"][0]["name"] == "Box"
        assert body["items"][0]["full_packages"] in ("0", "0.000", 0, 0.0)

    def test_persistence_fresh_session(
        self, client, admin_headers, TestingSession
    ):
        product = _create_product(client, admin_headers)
        url = _unit_url(product["id"])
        created = client.post(
            url,
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        assert created.status_code == 201, created.text
        unit_id = created.json()["id"]

        # Fresh HTTP request (new SQLAlchemy session per request via override)
        resp = client.get(url, headers=admin_headers)
        assert resp.status_code == 200, resp.text
        items = resp.json()["items"]
        assert any(i["id"] == unit_id for i in items)

        # Direct read through a brand-new session against the same engine
        session = TestingSession()
        try:
            from app.models.catalog import ProductPurchaseUnit

            row = session.get(ProductPurchaseUnit, uuid.UUID(unit_id))
            assert row is not None
            assert row.name == "Box"
        finally:
            session.close()

    def test_packaging_state_get_200(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.get(
            f"/api/v1/products/{product['id']}/packaging-state",
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["product_id"] == product["id"]
        assert body["total_base_qty"] == "240.000"


class TestPurchaseUnitServiceRealRepository:
    """Service-level test: PurchaseUnitService.create_unit against real ProductRepository."""

    def test_create_unit_uses_product_repository(self, engine, TestingSession, db):
        session = TestingSession()
        try:
            from app.models.catalog import Product

            product = Product(
                name="Svc Product",
                barcode="SVC001",
                price=10.0,
                cost=6.0,
                quantity=240.0,
                unit="piece",
            )
            session.add(product)
            session.flush()

            service = PurchaseUnitService(session)
            # Regression: previously raised AttributeError: 'ProductRepository' object has no attribute 'get'
            assert hasattr(service.products, "get_by_id")
            assert not hasattr(service.products, "get")

            request = PurchaseUnitCreateRequest(
                name="Box",
                unit_type="piece",
                multiplier=Decimal("24"),
                barcode="SVCBOX001",
                is_default=True,
            )
            response = service.create_unit(product.id, request)
            assert response.name == "Box"
            assert response.multiplier == Decimal("24.000")
            assert response.product_id == product.id
            session.flush()
        finally:
            session.close()

    def test_create_unit_nonexistent_product_raises_not_found(self, engine, TestingSession, db):
        session = TestingSession()
        try:
            from app.core.exceptions import NotFoundError

            service = PurchaseUnitService(session)
            request = PurchaseUnitCreateRequest(
                name="Box", unit_type="piece", multiplier=Decimal("24")
            )
            with pytest.raises(NotFoundError) as exc:
                service.create_unit(uuid.uuid4(), request)
            assert exc.value.message == "Product not found"
            assert exc.value.status_code == 404
        finally:
            session.close()


class TestPurchaseUnitArchive:
    """Archive (soft-delete) purchase units via DELETE endpoint (204 No Content)."""

    def test_archive_purchase_unit(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        created = client.post(
            _unit_url(product["id"]),
            json={
                "name": "Box",
                "unit_type": "piece",
                "multiplier": "24",
                "is_default": True,
            },
            headers=admin_headers,
        )
        assert created.status_code == 201, created.text
        uid = created.json()["id"]

        resp = client.delete(
            f"{_unit_url(product['id'])}/{uid}",
            headers=admin_headers,
        )
        assert resp.status_code == 204, resp.text
        assert resp.content == b""

        # Active list no longer includes it; include_archived shows it.
        active = client.get(
            _unit_url(product["id"]),
            headers=admin_headers,
        ).json()
        assert all(i["id"] != uid for i in active["items"])

        with_arch = client.get(
            _unit_url(product["id"]),
            params={"include_archived": True},
            headers=admin_headers,
        ).json()
        row = next(i for i in with_arch["items"] if i["id"] == uid)
        assert row["is_archived"] is True
        assert row["archived_at"] is not None

    def test_archive_unknown_purchase_unit_404(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.delete(
            f"{_unit_url(product['id'])}/00000000-0000-0000-0000-000000000001",
            headers=admin_headers,
        )
        assert resp.status_code == 404

    def test_unauthenticated_archive_401(self, client):
        admin = _login(client, "Admin", "1234")
        product = _create_product(client, admin)
        created = client.post(
            _unit_url(product["id"]),
            json={"name": "Box", "multiplier": "24"},
            headers=admin,
        ).json()
        resp = client.delete(f"{_unit_url(product['id'])}/{created['id']}")
        assert resp.status_code == 401

    def test_product_repository_exposes_get_by_id_not_get(self, engine, TestingSession, db):
        session = TestingSession()
        try:
            repo = ProductRepository(session)
            assert hasattr(repo, "get_by_id")
            assert not hasattr(repo, "get")
        finally:
            session.close()
