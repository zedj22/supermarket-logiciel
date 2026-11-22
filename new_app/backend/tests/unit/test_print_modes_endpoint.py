"""All four receipt-printing modes, exercised through the REAL endpoints.

The unified ``receipt_print_mode`` is a client-decided behaviour, so the
server-side contract is: every one of the four modes is accepted, stored
verbatim, read back unchanged, and the print endpoint keeps producing the
same valid 80mm thermal receipt regardless of the chosen mode (the POS
decides *whether* to call it, never *what* it returns).

For each mode this drives ``PUT /settings`` → ``GET /settings`` →
``POST /api/v1/print`` for a fresh sale, which is exactly the request the
Flutter client sends.
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

SETTINGS_URL = "/api/v1/settings"
MODES = ("disabled", "ask", "auto_print", "ask_above_threshold")


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
def client(engine, testing_session):
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    AuthService(session).setup_first_admin(
        name="Admin", pin="1234", pin_confirm="1234"
    )
    session.commit()
    session.close()

    def override_get_db():
        db = testing_session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


@pytest.fixture()
def headers(client):
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


def _sale(client, headers, *, barcode: str) -> dict:
    product = client.post(
        "/api/v1/products",
        json={
            "name": "Mode probe item",
            "barcode": barcode,
            "price": "100.000",
            "cost": "60.000",
            "quantity": "20.000",
            "unit": "piece",
        },
        headers=headers,
    )
    assert product.status_code == 201, product.text
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {
                    "product_id": product.json()["id"],
                    "quantity": "1.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "100.000",
            "device_id": "POS-1",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


@pytest.mark.parametrize("mode", MODES)
def test_each_mode_round_trips_and_the_print_endpoint_still_renders(
    client, headers, mode
):
    threshold = 750 if mode == "ask_above_threshold" else 0
    put = client.put(
        SETTINGS_URL,
        json={"receipt_print_mode": mode, "receipt_min_amount": threshold},
        headers=headers,
    )
    assert put.status_code == 200, put.text
    assert put.json()["receipt_print_mode"] == mode
    assert put.json()["receipt_min_amount"] == threshold

    # Reopening Settings (a brand-new request) shows the saved option.
    body = client.get(SETTINGS_URL, headers=headers).json()
    assert body["receipt_print_mode"] == mode
    assert body["receipt_min_amount"] == threshold

    # The receipt itself is unaffected by the mode.
    sale = _sale(client, headers, barcode=f"MODE{uuid.uuid4().hex[:8].upper()}")
    printed = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": sale["id"],
            "paper": "80mm",
            "locale": "fr",
            "device_id": "POS-1",
        },
        headers={**headers, "X-Device-ID": "POS-1"},
    )
    assert printed.status_code == 200, printed.text
    assert printed.content[:5] == b"%PDF-"
    assert printed.headers["content-type"].startswith("application/pdf")
    assert len(printed.content) > 5_000


def test_legacy_flags_cannot_override_the_unified_mode(client, headers):
    """The old pair is inert: the mode stays exactly what was chosen."""
    client.put(
        SETTINGS_URL,
        json={
            "receipt_print_mode": "disabled",
            "ask_before_print": True,
            "auto_print_invoice": True,
        },
        headers=headers,
    )
    body = client.get(SETTINGS_URL, headers=headers).json()
    assert body["receipt_print_mode"] == "disabled"
    # Legacy columns still exist for wire compatibility…
    assert body["ask_before_print"] is True
    # …and the mode is what every client behaviour reads.

    client.put(
        SETTINGS_URL, json={"receipt_print_mode": "ask"}, headers=headers
    )
    assert client.get(SETTINGS_URL, headers=headers).json()[
        "receipt_print_mode"
    ] == "ask"


def test_threshold_validation_is_preserved(client, headers):
    assert (
        client.put(
            SETTINGS_URL, json={"receipt_min_amount": -1}, headers=headers
        ).status_code
        == 422
    )
    client.put(
        SETTINGS_URL,
        json={"receipt_print_mode": "ask_above_threshold", "receipt_min_amount": 500},
        headers=headers,
    )
    # A later partial save never silently resets the threshold.
    client.put(SETTINGS_URL, json={"receipt_print_mode": "ask"}, headers=headers)
    assert client.get(SETTINGS_URL, headers=headers).json()["receipt_min_amount"] == 500
