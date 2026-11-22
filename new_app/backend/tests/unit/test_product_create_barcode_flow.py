"""Regression — the REAL Add-Product flow must always end with a barcode.

The feature once appeared to do nothing in the running application: the
Flutter form leaves the barcode field empty, the request carries no (or a
blank) ``barcode``, and no code was generated.  These tests drive the exact
request the Flutter dialog builds (``product_form_dialog.dart::_payload``)
through the real endpoint and then read the row back from the database, so a
silently-null barcode can never pass again on the strength of a
``ProductService`` unit test alone.

Covered here:

* the AC shape sent by the form — ``null`` / ``""`` / whitespace-only all
  mean "generate";
* the generated code is checksum-valid EAN-13, stored, and returned by the
  create response (not a request echo);
* it resolves through the POS scanner lookup;
* a typed barcode is preserved verbatim and never replaced;
* edits never generate, never wipe and never overwrite a barcode;
* even a request model built WITHOUT schema validation cannot save blanks —
  the service itself is authoritative.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.seed import seed_roles_and_permissions
from app.db.base import Base
from app.db.session import get_db
from app.domain.barcode import is_valid_ean13
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


# ── the request the Flutter form actually sends ─────────────────────────


def flutter_create_payload(**overrides) -> dict:
    """Byte-for-byte the JSON ``ProductFormDialog._payload()`` produces.

    An empty barcode field contributes NO ``barcode`` key at all; every
    other optional field is either absent or explicitly null, exactly as the
    dialog writes it.
    """
    payload: dict = {
        "name": "Yaourt",
        "unit": "piece",
        "price": "120.000",
        "cost": "80.000",
        "wholesale_price": None,
        "wholesale_min_qty": None,
        "vat_rate": 0,
        "quantity": "0",
        "low_stock_threshold": "5",
        "variants": [],
        "selling_units": [],
        "purchase_units": [],
    }
    payload.update(overrides)
    return payload


def _create(client: TestClient, headers: dict, **overrides) -> dict:
    resp = client.post(
        "/api/v1/products", json=flutter_create_payload(**overrides), headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _stored_barcode(TestingSession, product_id: str) -> str | None:
    """Read the row in a FRESH session — proof it reached the database."""
    with TestingSession() as session:
        row = session.get(Product, uuid.UUID(product_id))
        assert row is not None
        return row.barcode


# ── the real-world failure ──────────────────────────────────────────────


def test_add_product_with_empty_barcode_field_stores_generated_code(
    client, headers, TestingSession
):
    created = _create(client, headers)

    barcode = created["barcode"]
    assert barcode, "the Add Product form left the barcode empty in production"
    assert is_valid_ean13(barcode)
    assert barcode.startswith("2"), "internal-use EAN-13 range"

    # The response is the SAVED product, not the request echoed back.
    assert _stored_barcode(TestingSession, created["id"]) == barcode
    again = client.get(f"/api/v1/products/{created['id']}", headers=headers)
    assert again.status_code == 200
    assert again.json()["barcode"] == barcode


@pytest.mark.parametrize(
    "blank", [None, "", " ", "   ", "\t", "\n  \n"], ids=repr
)
def test_every_blank_spelling_generates_a_barcode(
    client, headers, TestingSession, blank
):
    created = _create(client, headers, barcode=blank)
    assert created["barcode"] and is_valid_ean13(created["barcode"])
    assert _stored_barcode(TestingSession, created["id"]) == created["barcode"]


def test_generated_code_is_scannable_through_the_pos_lookup(client, headers):
    created = _create(client, headers)
    resp = client.get(
        "/api/v1/products/barcode-lookup",
        params={"barcode": created["barcode"]},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["kind"] == "product"
    assert resp.json()["product_id"] == created["id"]


# ── manual barcodes ─────────────────────────────────────────────────────


def test_typed_barcode_is_kept_verbatim(client, headers, TestingSession):
    created = _create(client, headers, barcode="6130000112233")
    assert created["barcode"] == "6130000112233"
    assert _stored_barcode(TestingSession, created["id"]) == "6130000112233"


def test_typed_barcode_is_trimmed_but_never_replaced(client, headers):
    created = _create(client, headers, barcode="  6130000445566  ")
    assert created["barcode"] == "6130000445566"


# ── edits ───────────────────────────────────────────────────────────────


def test_editing_without_a_barcode_neither_regenerates_nor_clears(
    client, headers, TestingSession
):
    created = _create(client, headers)
    original = created["barcode"]

    # The edit form omits an untouched barcode field entirely.
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"name": "Yaourt nature", "price": "130.000"},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["barcode"] == original
    assert _stored_barcode(TestingSession, created["id"]) == original


@pytest.mark.parametrize("blank", [None, "", "   "])
def test_edit_with_a_blank_barcode_cannot_destroy_the_existing_code(
    client, headers, TestingSession, blank
):
    created = _create(client, headers, barcode="6130000778899")
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"name": "Renamed", "barcode": blank},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["barcode"] == "6130000778899"
    assert _stored_barcode(TestingSession, created["id"]) == "6130000778899"


def test_edit_never_invents_a_second_barcode(client, headers, TestingSession):
    first = _create(client, headers)
    resp = client.put(
        f"/api/v1/products/{first['id']}",
        json={"price": "150.000"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["barcode"] == first["barcode"]
    # Exactly one product row, one code — no orphan replacement.
    with TestingSession() as session:
        products = list(session.scalars(select(Product)).all())
    assert len(products) == 1
    assert products[0].barcode == first["barcode"]


# ── backend authority, beyond schema validation ─────────────────────────


def test_service_normalises_blanks_even_without_schema_validation(db):
    """A request model built by hand still cannot save an empty barcode."""
    request = ProductCreateRequest(name="Bypass attempt", price="10.000")
    for blank in ("", "   ", "\t"):
        tampered = request.model_copy(update={"barcode": blank})
        product = ProductService(db).create(
            tampered.model_copy(update={"name": f"Bypass {blank!r}"})
        )
        assert product.barcode and is_valid_ean13(product.barcode)
