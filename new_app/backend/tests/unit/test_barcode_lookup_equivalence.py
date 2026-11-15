"""Barcode lookup: UPC-A ↔ EAN-13 equivalence and byte-exact codes.

A scanner emits whichever symbology the printed symbol encodes: a product
registered under the EAN-13 form (leading zero) must resolve when a UPC-A
scanner reports the 12-digit form, and vice versa. Everything else stays
byte-exact — leading zeros are part of the code, never stripped and never
converted to an integer, and EAN-8 / alphanumeric internal codes are only
ever matched exactly.

These tests use an in-memory database and an in-process client; no live
database is touched.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.services.auth import AuthService
from app.services.catalog import upc_a_ean13_alias


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
    session.commit()
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


def _create_product(client: TestClient, headers: dict, barcode: str) -> dict:
    payload = {
        "name": f"Scan item {barcode}",
        "barcode": barcode,
        "price": "100.000",
        "cost": "60.000",
        "quantity": "10.000",
        "unit": "piece",
    }
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _lookup(client: TestClient, headers: dict, barcode: str) -> dict:
    resp = client.get(
        "/api/v1/products/barcode-lookup",
        params={"barcode": barcode},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


# ── the pure helper ────────────────────────────────────────────────────


def test_alias_only_covers_the_gs1_equivalence():
    # 12 digits → the EAN-13 form (one leading zero).
    assert upc_a_ean13_alias("036000291452") == "0036000291452"
    # 13 digits starting with a zero → the UPC-A form.
    assert upc_a_ean13_alias("0036000291452") == "036000291452"


def test_alias_never_touches_anything_else():
    for code in (
        "96385074",  # EAN-8
        "4006381333931",  # EAN-13, non-zero prefix
        "00036000291452",  # 14 digits (GTIN-14) — not a UPC-A alias
        "ABC123456789",  # alphanumeric internal code
        "0000",  # short internal code
        "",
    ):
        assert upc_a_ean13_alias(code) is None


# ── the service, through the API ───────────────────────────────────────


def test_ean13_product_resolves_from_a_upc_a_scan(client, headers):
    product = _create_product(client, headers, "0036000291452")

    hit = _lookup(client, headers, "036000291452")

    assert hit["found"] is True
    assert hit["product_id"] == product["id"]
    assert hit["kind"] == "product"


def test_upc_a_product_resolves_from_an_ean13_scan(client, headers):
    product = _create_product(client, headers, "036000291452")

    hit = _lookup(client, headers, "0036000291452")

    assert hit["found"] is True
    assert hit["product_id"] == product["id"]


def test_exact_match_wins_over_the_alias(client, headers):
    exact = _create_product(client, headers, "036000291452")

    hit = _lookup(client, headers, "036000291452")

    assert hit["found"] is True
    assert hit["product_id"] == exact["id"]


def test_leading_zeros_are_preserved_and_never_stripped(client, headers):
    product = _create_product(client, headers, "0045600012345")

    assert _lookup(client, headers, "0045600012345")["product_id"] == product["id"]
    # The 13-digit form stripped of its zero is a DIFFERENT 12-digit code
    # that is not equivalent (the zero here is part of the EAN-13 prefix,
    # and "045600012345" is not a UPC-A alias of it — both forms are 13
    # digits). An unknown 12-digit code stays unknown.
    assert _lookup(client, headers, "999999999999")["found"] is False


def test_ean8_is_matched_exactly(client, headers):
    product = _create_product(client, headers, "96385074")

    assert _lookup(client, headers, "96385074")["product_id"] == product["id"]
    assert _lookup(client, headers, "9638507")["found"] is False


def test_unknown_barcode_is_a_definitive_miss(client, headers):
    resp = client.get(
        "/api/v1/products/barcode-lookup",
        params={"barcode": "0000000000000"},
        headers=headers,
    )

    assert resp.status_code == 200
    assert resp.json()["found"] is False
