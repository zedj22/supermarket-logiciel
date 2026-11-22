"""Automatic product barcode generation (EAN-13, internal use).

Contract under test:

* a product created WITHOUT a barcode receives one — checksum-valid,
  internal-use EAN-13, stored permanently, immediately scannable;
* a barcode the operator typed is used verbatim and never replaced;
* editing an existing product never regenerates or clears its barcode;
* generated codes are unique across products (and never steal a code that
  already belongs to a selling unit);
* a collision (two creates racing on the same random code) is retried;
* an exhausted generation is a clear 4xx and creates NO product;
* the stored code survives closing and reopening the database.

All tests run against throwaway SQLite databases; no live database is used.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

import app.services.catalog as catalog_module
from app.core.seed import seed_roles_and_permissions
from app.db.base import Base
from app.db.session import get_db
from app.domain.barcode import (
    ean13_check_digit,
    generate_internal_ean13,
    is_valid_ean13,
)
from app.main import app
from app.models.catalog import Product
from app.schemas.catalog import ProductCreateRequest
from app.services.auth import AuthService
from app.services.catalog import ProductService


# ── fixtures ────────────────────────────────────────────────────────────


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
    seed_roles_and_permissions(session)
    AuthService(session).setup_first_admin(
        name="Admin", pin="1234", pin_confirm="1234"
    )
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


def _payload(**over) -> dict:
    data = {
        "name": "Auto barcode item",
        "price": "100.000",
        "cost": "60.000",
        "quantity": "10.000",
        "unit": "piece",
    }
    data.update(over)
    return data


def _create(client: TestClient, headers: dict, **over) -> dict:
    resp = client.post("/api/v1/products", json=_payload(**over), headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _products(session: Session) -> list[Product]:
    return list(session.scalars(select(Product)).all())


# ── the pure helpers ────────────────────────────────────────────────────


def test_ean13_check_digit_matches_known_codes():
    # 4006381333931 — a published EAN-13 example.
    assert ean13_check_digit("400638133393") == "1"
    assert is_valid_ean13("4006381333931")


def test_generated_code_is_a_valid_internal_ean13():
    for _ in range(50):
        code = generate_internal_ean13()
        assert len(code) == 13 and code.isdigit()
        assert code.startswith("2"), "internal-use GS1 prefix"
        assert is_valid_ean13(code)


def test_invalid_ean13_is_rejected():
    assert not is_valid_ean13("4006381333932")  # wrong check digit
    assert not is_valid_ean13("400638133393")  # too short
    assert not is_valid_ean13("400638133393A")


# ── create ──────────────────────────────────────────────────────────────


def test_product_created_without_barcode_gets_a_valid_one(client, headers):
    created = _create(client, headers)
    assert created["barcode"], "a barcode must be generated automatically"
    assert is_valid_ean13(created["barcode"])
    assert created["barcode"].startswith("2")

    # Read back through the API — the value is the product's, not a display
    # artefact of the create response.
    again = client.get(f"/api/v1/products/{created['id']}", headers=headers)
    assert again.status_code == 200
    assert again.json()["barcode"] == created["barcode"]


def test_manual_barcode_is_used_verbatim(client, headers):
    created = _create(client, headers, barcode="6130000112233")
    assert created["barcode"] == "6130000112233"


def test_blank_barcode_is_treated_as_missing(client, headers):
    created = _create(client, headers, barcode="   ")
    assert created["barcode"]
    assert is_valid_ean13(created["barcode"])


def test_editing_a_product_never_regenerates_its_barcode(client, headers):
    created = _create(client, headers)
    original = created["barcode"]

    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"name": "Renamed item", "price": "120.000"},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["barcode"] == original

    # And an operator can still set a different one explicitly.
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"barcode": "6130000999888"},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["barcode"] == "6130000999888"


def test_generated_barcodes_are_unique_across_products(client, headers):
    codes = [_create(client, headers, name=f"Item {i}")["barcode"] for i in range(12)]
    assert len(set(codes)) == len(codes)
    assert all(is_valid_ean13(code) for code in codes)


def test_generation_retries_when_the_database_rejects_a_collision(
    client, headers, monkeypatch
):
    first = _create(client, headers, barcode="2000000000017")
    taken = first["barcode"]
    free = "2001234567894"

    sequence = iter([taken, free])
    monkeypatch.setattr(
        catalog_module,
        "generate_internal_ean13",
        lambda: next(sequence),
    )

    created = _create(client, headers, name="Second item")
    assert created["barcode"] == free


def test_generation_avoids_a_code_already_used_by_a_selling_unit(
    client, headers, monkeypatch
):
    unit_barcode = "2005555555555"
    _create(
        client,
        headers,
        name="Unit owner",
        barcode="2007777777777",
        selling_units=[
            {
                "name": "Carton",
                "unit_type": "piece",
                "multiplier": "6",
                "barcode": unit_barcode,
                "is_base_unit": False,
            }
        ],
    )

    free = "2008888888888"
    sequence = iter([unit_barcode, free])
    monkeypatch.setattr(
        catalog_module,
        "generate_internal_ean13",
        lambda: next(sequence),
    )
    created = _create(client, headers, name="Unit-safe item")
    assert created["barcode"] == free


def test_exhausted_generation_fails_loudly_and_creates_nothing(
    client, headers, db, monkeypatch
):
    existing = _create(client, headers, barcode="2000000000093")["barcode"]
    monkeypatch.setattr(
        catalog_module, "generate_internal_ean13", lambda: existing
    )

    resp = client.post(
        "/api/v1/products",
        json=_payload(name="Never created"),
        headers=headers,
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "BARCODE_GENERATION_FAILED"

    db.expire_all()
    names = {p.name for p in _products(db)}
    assert "Never created" not in names


def test_manual_duplicate_barcode_is_still_a_conflict(client, headers):
    _create(client, headers, barcode="6130000112233")
    resp = client.post(
        "/api/v1/products",
        json=_payload(name="Duplicate", barcode="6130000112233"),
        headers=headers,
    )
    assert resp.status_code == 409, resp.text


# ── scanner workflow ────────────────────────────────────────────────────


def test_generated_barcode_resolves_through_the_pos_scanner_lookup(
    client, headers
):
    created = _create(client, headers, name="Scanner item")
    code = created["barcode"]

    resp = client.get(
        "/api/v1/products/barcode-lookup",
        params={"barcode": code},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["found"] is True
    assert body["kind"] == "product"
    assert body["product_id"] == created["id"]


def test_generated_barcode_is_found_by_product_search(client, headers):
    created = _create(client, headers, name="Searchable item")
    resp = client.get(
        "/api/v1/products/search",
        params={"barcode": created["barcode"]},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert created["id"] in {item["id"] for item in resp.json()["items"]}


# ── persistence ─────────────────────────────────────────────────────────


def test_barcode_is_persisted_across_a_database_reopen(tmp_path):
    """Close the engine, reopen the file: the generated code is still there."""
    url = f"sqlite+pysqlite:///{tmp_path / 'catalog.db'}"

    engine = create_engine(url)
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine)
    with factory() as session:
        seed_roles_and_permissions(session)
        AuthService(session).setup_first_admin(
            name="Admin", pin="1234", pin_confirm="1234"
        )
        session.commit()
        product = ProductService(session).create(
            ProductCreateRequest(name="Persisted item", price="10.000")
        )
        product_id = product.id
        barcode = product.barcode
    engine.dispose()

    reopened = create_engine(url)
    try:
        with sessionmaker(bind=reopened)() as session:
            stored = session.get(Product, product_id)
            assert stored is not None
            assert stored.barcode == barcode
            assert barcode and is_valid_ean13(barcode)
            assert ProductService(session).repo.barcode_exists(barcode) is True
    finally:
        reopened.dispose()


def test_generated_barcode_does_not_touch_other_columns(client, headers, db):
    """Only the barcode is invented: price/cost/name/stock stay as sent."""
    created = _create(
        client, headers, name="Untouched", price="77.000", cost="70.000"
    )
    row = db.get(Product, uuid.UUID(created["id"]))
    assert row is not None
    assert row.name == "Untouched"
    assert str(row.price) == "77.000"
    db.expire_all()
    assert db.scalar(select(func.count()).select_from(Product)) == 1
