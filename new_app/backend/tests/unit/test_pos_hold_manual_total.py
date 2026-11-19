"""POS hold/resume round trip for the two cart-only line states.

The hold endpoint stores the POS cart's own display snapshot
(`CartLine.toJson`) and hands it back verbatim on resume. That snapshot now
carries two states the sale payload never sees:

* ``manual_total`` / ``custom_line`` / ``custom_ref`` — the cashier's manual
  line total and a price-only custom line's identity;
* a custom line has NO product_id and NO pack_id at all.

Both must survive the round trip, otherwise resuming a hold silently
re-prices a line the cashier fixed by hand, and a cart containing a custom
item cannot be held at all.
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
def testing_session(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, testing_session):
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    AuthService(session).setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    session.commit()
    yield session
    session.close()


@pytest.fixture()
def client(engine, testing_session, db):
    def override_get_db():
        session = testing_session()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


@pytest.fixture()
def admin_headers(client):
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


def _product(client, headers) -> dict:
    resp = client.post(
        "/api/v1/products",
        json={
            "name": "Hold Product",
            "barcode": f"HOLD{uuid.uuid4().hex[:8]}",
            "price": "100.000",
            "cost": "60.000",
            "quantity": "50.000",
            "unit": "piece",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _hold_item_product(product_id: str) -> dict:
    """A catalog line whose total the cashier fixed at 450 (5 × 100 − 50)."""
    return {
        "product_id": product_id,
        "quantity": "5.000",
        "unit_price": "100.000",
        "line_discount": "50.000",
        "product_name": "Hold Product",
        "product_unit": "piece",
        # Cart-only snapshot keys the POS sends (CartLine.toJson).
        "manual_total": "450",
        "custom_line": None,
        "custom_ref": None,
    }


def _hold_item_custom() -> dict:
    return {
        "product_id": None,
        "pack_id": None,
        "custom_name": "Unregistered item",
        "quantity": "1.000",
        "unit_price": "350.000",
        "line_discount": "0.000",
        "product_name": "Unregistered item",
        "product_unit": "piece",
        "manual_total": "350",
        "custom_line": True,
        "custom_ref": "qa-1",
    }


def test_hold_keeps_a_manual_total(client, admin_headers):
    product = _product(client, admin_headers)

    resp = client.post(
        "/api/v1/pos/holds",
        json={
            "device_id": "POS-QA",
            "items": [_hold_item_product(product["id"])],
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text

    hold_id = resp.json()["id"]
    detail = client.get(f"/api/v1/pos/holds/{hold_id}", headers=admin_headers)
    assert detail.status_code == 200, detail.text
    item = detail.json()["items"][0]

    assert item["line_discount"] == "50.000"
    assert item.get("manual_total") == "450", (
        "the cashier's manual total must survive hold/resume — otherwise the "
        "resumed cart re-prices the line (defect)"
    )


def test_hold_accepts_a_custom_line(client, admin_headers):
    resp = client.post(
        "/api/v1/pos/holds",
        json={"device_id": "POS-QA", "items": [_hold_item_custom()]},
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text

    hold_id = resp.json()["id"]
    detail = client.get(f"/api/v1/pos/holds/{hold_id}", headers=admin_headers)
    item = detail.json()["items"][0]
    assert item["product_name"] == "Unregistered item"
    assert item.get("custom_line") is True
    assert item.get("custom_ref") == "qa-1"
    assert Decimal(str(item["unit_price"])) == Decimal("350")


def test_hold_keeps_the_automatic_bundle_plan(client, admin_headers):
    """A Method 2 line must resume still knowing its bundle (4 × 300)."""
    product = _product(client, admin_headers)
    item = {
        "product_id": product["id"],
        "quantity": "6.000",
        "unit_price": "100.000",
        "line_discount": "100.000",
        "product_name": "Hold Product",
        "product_unit": "piece",
        "auto_bundle_quantity": "4",
        "auto_bundle_price": "300",
    }
    resp = client.post(
        "/api/v1/pos/holds",
        json={"device_id": "POS-QA", "items": [item]},
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    detail = client.get(
        f"/api/v1/pos/holds/{resp.json()['id']}", headers=admin_headers
    ).json()
    assert detail["items"][0]["auto_bundle_quantity"] == "4"
    assert detail["items"][0]["auto_bundle_price"] == "300"


def test_hold_round_trip_mixed_cart(client, admin_headers):
    product = _product(client, admin_headers)
    resp = client.post(
        "/api/v1/pos/holds",
        json={
            "device_id": "POS-QA",
            "items": [_hold_item_product(product["id"]), _hold_item_custom()],
            "invoice_discount": "0",
            "note": "qa mixed cart",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    detail = client.get(
        f"/api/v1/pos/holds/{resp.json()['id']}", headers=admin_headers
    ).json()
    assert len(detail["items"]) == 2
    assert detail["items"][0].get("manual_total") == "450"
    assert detail["items"][1].get("custom_line") is True
