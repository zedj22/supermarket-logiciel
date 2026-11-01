"""TASK 5 — Variants XOR selling units (approved business rule).

A product is EITHER a variant product (S/M/L, 500g/1kg, …) OR a
selling-unit product (Piece/Box/Carton) — never both. Enforced in the
service layer under a product-row lock (see the PostgreSQL concurrency
gate in tests/integration/). Archived rows (archived_at IS NOT NULL)
are historical records the data model explicitly distinguishes, so they
never block the other category.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.services.auth import AuthService

CODE = "PRODUCT_VARIANTS_EXCLUSIVE"
KEY = "errors.productVariantsExclusive"


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


def _create_product(client, headers, **overrides) -> dict:
    payload = {
        "name": "Exclusive Product",
        "barcode": f"XOR{uuid.uuid4().hex[:10].upper()}",
        "price": "10.000",
        "cost": "6.000",
        "quantity": "50.000",
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _add_variant(client, headers, product_id, **overrides) -> dict:
    payload = {"name": f"V{uuid.uuid4().hex[:6]}", **overrides}
    resp = client.post(
        f"/api/v1/products/{product_id}/variants",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _add_unit(client, headers, product_id, **overrides) -> dict:
    payload = {
        "name": f"U{uuid.uuid4().hex[:6]}",
        "multiplier": "12",
        **overrides,
    }
    resp = client.post(
        f"/api/v1/products/{product_id}/selling-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _archive_variant(client, headers, product_id, variant_id) -> None:
    resp = client.delete(
        f"/api/v1/products/{product_id}/variants/{variant_id}",
        headers=headers,
    )
    assert resp.status_code == 200, resp.text


def _archive_unit(client, headers, product_id, unit_id) -> None:
    resp = client.delete(
        f"/api/v1/products/{product_id}/selling-units/{unit_id}",
        headers=headers,
    )
    assert resp.status_code == 200, resp.text


class TestVariantCreateBlockedByUnits:
    def test_variant_rejected_when_active_units_exist(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        _add_unit(client, admin_headers, product["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large"},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert err["code"] == CODE
        assert err["message_key"] == KEY
        assert err["details"]["product_id"] == product["id"]
        assert err["details"]["active_selling_units"] == 1
        assert "Archive" in err["message"]

        # No variant was created.
        variants = client.get(
            f"/api/v1/products/{product['id']}/variants",
            headers=admin_headers,
        ).json()
        assert variants["total"] == 0

    def test_variant_allowed_after_all_units_archived(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _add_unit(client, admin_headers, product["id"])
        _archive_unit(client, admin_headers, product["id"], unit["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_archived_units_do_not_block_variants(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        unit = _add_unit(client, admin_headers, product["id"])
        _archive_unit(client, admin_headers, product["id"], unit["id"])

        # A SECOND unit create is allowed too (no active variants yet),
        # and the archived first unit never blocks anything.
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Carton", "multiplier": "24"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text


class TestUnitCreateBlockedByVariants:
    def test_unit_rejected_when_active_variants_exist(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        _add_variant(client, admin_headers, product["id"], name="Large")

        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Box", "multiplier": "12"},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert err["code"] == CODE
        assert err["message_key"] == KEY
        assert err["details"]["product_id"] == product["id"]
        assert err["details"]["active_variants"] == 1
        assert "Archive" in err["message"]

        units = client.get(
            f"/api/v1/products/{product['id']}/selling-units",
            headers=admin_headers,
        ).json()
        assert units["total"] == 0

    def test_unit_allowed_after_all_variants_archived(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        variant = _add_variant(client, admin_headers, product["id"])
        _archive_variant(client, admin_headers, product["id"], variant["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text


class TestHappyPaths:
    def test_first_variant_on_plain_product(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_first_unit_on_plain_product(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Piece", "multiplier": "1", "is_base_unit": True},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_multiple_variants_accepted(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        _add_variant(client, admin_headers, product["id"], name="S")
        _add_variant(client, admin_headers, product["id"], name="M")
        _add_variant(client, admin_headers, product["id"], name="L")
        variants = client.get(
            f"/api/v1/products/{product['id']}/variants",
            headers=admin_headers,
        ).json()
        assert variants["total"] == 3

    def test_multiple_units_accepted(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        _add_unit(
            client,
            admin_headers,
            product["id"],
            name="Piece",
            multiplier="1",
            is_base_unit=True,
        )
        _add_unit(client, admin_headers, product["id"], name="Box")
        units = client.get(
            f"/api/v1/products/{product['id']}/selling-units",
            headers=admin_headers,
        ).json()
        assert units["total"] == 2


class TestArchiveLifecycle:
    def test_archive_all_variants_then_unit_allowed(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        v1 = _add_variant(client, admin_headers, product["id"], name="S")
        v2 = _add_variant(client, admin_headers, product["id"], name="M")
        _archive_variant(client, admin_headers, product["id"], v1["id"])
        _archive_variant(client, admin_headers, product["id"], v2["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Box", "multiplier": "12"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_archive_all_units_then_variant_allowed(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        u1 = _add_unit(client, admin_headers, product["id"], name="Box")
        u2 = _add_unit(client, admin_headers, product["id"], name="Carton")
        _archive_unit(client, admin_headers, product["id"], u1["id"])
        _archive_unit(client, admin_headers, product["id"], u2["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text


class TestNoBypassOnEdit:
    def test_editing_variant_on_variant_product_still_works(
        self, client, admin_headers
    ):
        product = _create_product(client, admin_headers)
        variant = _add_variant(client, admin_headers, product["id"])
        resp = client.put(
            f"/api/v1/products/{product['id']}/variants/{variant['id']}",
            json={"name": "Renamed", "price": "15.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["name"] == "Renamed"

    def test_update_cannot_unarchive_via_archived_at(
        self, client, admin_headers
    ):
        """archived_at is not an updatable field — no reactivation bypass."""
        product = _create_product(client, admin_headers)
        unit = _add_unit(client, admin_headers, product["id"])
        _archive_unit(client, admin_headers, product["id"], unit["id"])

        # The variant is now allowed on the unit-free (active) product.
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Large"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

        # Attempting to sneak archived_at into an update never reactivates.
        resp = client.put(
            f"/api/v1/products/{product['id']}/selling-units/{unit['id']}",
            json={"name": unit["name"], "archived_at": None},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        active = client.get(
            f"/api/v1/products/{product['id']}/selling-units",
            headers=admin_headers,
        ).json()
        assert active["total"] == 0, "archived unit must stay archived"


class TestStagedChildren:
    def test_staging_both_kinds_rejected(self, client, admin_headers):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Both Staged",
                "barcode": f"XORBOTH{uuid.uuid4().hex[:8].upper()}",
                "price": "10.000",
                "variants": [{"name": "L"}],
                "selling_units": [{"name": "Box", "multiplier": "12"}],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert err["code"] == CODE
        assert err["message_key"] == KEY
        assert err["details"]["variants"] == 1
        assert err["details"]["selling_units"] == 1

        # Nothing was created (validated before any DB write).
        check = client.get(
            "/api/v1/products",
            params={"search": "Both Staged"},
            headers=admin_headers,
        ).json()
        assert check["total"] == 0

    def test_staging_variants_only_accepted(self, client, admin_headers):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Variants Staged",
                "barcode": f"XORVS{uuid.uuid4().hex[:8].upper()}",
                "price": "10.000",
                "variants": [{"name": "L"}, {"name": "M"}],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text

    def test_staging_units_only_accepted(self, client, admin_headers):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Units Staged",
                "barcode": f"XORUS{uuid.uuid4().hex[:8].upper()}",
                "price": "10.000",
                "selling_units": [
                    {"name": "Piece", "multiplier": "1", "is_base_unit": True},
                    {"name": "Box", "multiplier": "12"},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text


class TestErrorContract:
    def test_error_envelope_shape(self, client, admin_headers):
        product = _create_product(client, admin_headers)
        _add_variant(client, admin_headers, product["id"])

        resp = client.post(
            f"/api/v1/products/{product['id']}/selling-units",
            json={"name": "Box", "multiplier": "12"},
            headers=admin_headers,
        )
        assert resp.status_code == 422
        body = resp.json()
        assert "error" in body
        err = body["error"]
        assert err["code"] == CODE
        assert err["message_key"] == KEY
        assert isinstance(err["message"], str) and err["message"]
        assert isinstance(err["details"], dict)
        assert err["details"]["product_id"] == product["id"]
        assert err["details"]["active_variants"] == 1
