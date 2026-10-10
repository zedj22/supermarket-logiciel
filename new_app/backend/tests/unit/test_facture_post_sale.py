"""Post-as-sale tests — ``POST /api/v1/factures/{id}/post`` + ``register_as_sale``.

Same TestClient + StaticPool SQLite pattern as
``test_facturation_documents_api`` (seeded roles, admin, manager,
cashier, role-less guest, real bearer login).

Covers the required optional-sale-posting scenarios:

- Only FAC may post; DEV / PRO / BC / BL → 422.
- Free-text lines (no product_id / pack_id) → 422.
- Successful post creates exactly one POS sale + stock movement +
  inventory adjustment; document.sale_id / posted_at set.
- Idempotent: second POST returns the same sale (no duplicate).
- POST /factures with register_as_sale=true posts in the same request.
- Posted document rejects content edits (lines / client / payment)
  with 409 POSTED_DOCUMENT_LOCKED; notes / show_* still editable.
- No unpost endpoint exists.
- RBAC: Cashier / guest → 403 on /post.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.facturation import InvoiceClient
from app.models.inventory import InventoryMovement
from app.models.sale import Sale, SaleLine
from app.services.auth import AuthService

DAY = "2026-10-10"
YEAR = 2026


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
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    service.create_user(name="Guest No Roles", pin="9999", role_names=[])
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
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


@pytest.fixture()
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


def _invoice_client(db, name: str = "Fiscal Client") -> InvoiceClient:
    client = InvoiceClient(name=name, nif="0002213400067")
    db.add(client)
    db.commit()
    return client


def _product(db, **overrides) -> Product:
    values = dict(name="Coca Cola", price=Decimal("100.000"), vat_rate=19, quantity=Decimal("50"))
    values.update(overrides)
    product = Product(**values)
    db.add(product)
    db.commit()
    return product


def _product_payload(client_id: str, product_id: str, **overrides) -> dict:
    payload = {
        "doc_type": "FAC",
        "client_id": client_id,
        "document_date": DAY,
        "payment_method": "cash",
        "lines": [
            {
                "product_id": product_id,
                "quantity": "2",
                "unit_price_ht": "100",
                "tva_rate": "19",
                "discount_pct": "0",
            }
        ],
    }
    payload.update(overrides)
    return payload


def _free_text_payload(client_id: str, **overrides) -> dict:
    payload = {
        "doc_type": "FAC",
        "client_id": client_id,
        "document_date": DAY,
        "payment_method": "cash",
        "lines": [
            {
                "description": "Prestation libre",
                "quantity": "1",
                "unit_price_ht": "100",
                "tva_rate": "19",
                "discount_pct": "0",
            }
        ],
    }
    payload.update(overrides)
    return payload


def _create(client, headers, client_id: str, product_id: str, **overrides) -> dict:
    resp = client.post(
        "/api/v1/factures",
        json=_product_payload(client_id, product_id, **overrides),
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# Post endpoint — RBAC + eligibility
# ---------------------------------------------------------------------------


def test_unauthenticated_post_is_401(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db)
    resp = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert resp.status_code == 201
    doc_id = resp.json()["id"]
    no_auth = client.post(f"/api/v1/factures/{doc_id}/post")
    assert no_auth.status_code == 401


def test_cashier_post_is_403(client, db, admin_headers, cashier_headers):
    fiscal = _invoice_client(db)
    product = _product(db)
    resp = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert resp.status_code == 201
    doc_id = resp.json()["id"]
    denied = client.post(f"/api/v1/factures/{doc_id}/post", headers=cashier_headers)
    assert denied.status_code == 403


def test_guest_post_is_403(client, db, admin_headers, guest_headers):
    fiscal = _invoice_client(db)
    product = _product(db)
    resp = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert resp.status_code == 201
    doc_id = resp.json()["id"]
    denied = client.post(f"/api/v1/factures/{doc_id}/post", headers=guest_headers)
    assert denied.status_code == 403


def test_non_fac_doc_type_rejected(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db)
    for doc_type in ("DEV", "PRO", "BC", "BL"):
        resp = client.post(
            "/api/v1/factures",
            json=_product_payload(
                str(fiscal.id), str(product.id), doc_type=doc_type
            ),
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        doc_id = resp.json()["id"]
        post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
        assert post.status_code == 422
        body = post.json()
        assert body["error"]["code"] == "VALIDATION_ERROR"


def test_free_text_line_rejected(client, db, admin_headers):
    fiscal = _invoice_client(db)
    resp = client.post(
        "/api/v1/factures",
        json=_free_text_payload(str(fiscal.id)),
        headers=admin_headers,
    )
    assert resp.status_code == 201
    doc_id = resp.json()["id"]
    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 422
    detail = post.json()["error"].get("details", {})
    assert detail.get("code") == "FREE_TEXT_LINE_NOT_POSTABLE"


def test_post_unknown_document_is_404(client, db, admin_headers):
    resp = client.post(
        f"/api/v1/factures/{uuid.uuid4()}/post",
        headers=admin_headers,
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Successful post — exactly one sale, stock, financials
# ---------------------------------------------------------------------------


def test_successful_post_creates_sale_and_links(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    db.commit()

    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201, create.text
    doc_id = create.json()["id"]
    assert create.json()["sale_id"] is None

    # Pre-post stock
    db.expire_all()
    product_before = db.get(Product, product.id)
    stock_before = Decimal(str(product_before.quantity))

    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200, post.text
    body = post.json()
    assert body["sale_id"] is not None
    assert body["posted_at"] is not None

    # Exactly one sale exists with the deterministic idempotency key
    sales = db.execute(
        select(Sale).where(Sale.client_request_id == f"facture:{doc_id}")
    ).scalars().all()
    assert len(sales) == 1
    sale = sales[0]

    # Sale line exists and stock decreased by 2
    lines = db.execute(
        select(SaleLine).where(SaleLine.sale_id == sale.id)
    ).scalars().all()
    assert len(lines) == 1
    assert Decimal(str(lines[0].quantity)) == Decimal("2")

    db.expire_all()
    product_after = db.get(Product, product.id)
    stock_after = Decimal(str(product_after.quantity))
    assert stock_after == stock_before - Decimal("2")

    # Inventory movement recorded
    movements = db.execute(
        select(InventoryMovement).where(InventoryMovement.product_id == product.id)
    ).scalars().all()
    assert len(movements) >= 1


def test_second_post_is_idempotent(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]

    first = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert first.status_code == 200
    sale_id = first.json()["sale_id"]

    second = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert second.status_code == 200
    assert second.json()["sale_id"] == sale_id

    # Still exactly one sale
    sales = db.execute(
        select(Sale).where(Sale.client_request_id == f"facture:{doc_id}")
    ).scalars().all()
    assert len(sales) == 1


# ---------------------------------------------------------------------------
# register_as_sale on create / update
# ---------------------------------------------------------------------------


def test_create_with_register_as_sale_posts(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    payload = _product_payload(str(fiscal.id), str(product.id))
    payload["register_as_sale"] = True
    resp = client.post("/api/v1/factures", json=payload, headers=admin_headers)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["sale_id"] is not None
    assert body["posted_at"] is not None


def test_update_with_register_as_sale_posts(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]
    assert create.json()["sale_id"] is None

    update = client.put(
        f"/api/v1/factures/{doc_id}",
        json={"register_as_sale": True},
        headers=admin_headers,
    )
    assert update.status_code == 200, update.text
    assert update.json()["sale_id"] is not None


# ---------------------------------------------------------------------------
# Lifecycle: posted document is content-locked
# ---------------------------------------------------------------------------


def test_posted_document_rejects_content_edit(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]
    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200

    # Lines change → 409
    update = client.put(
        f"/api/v1/factures/{doc_id}",
        json={
            "lines": [
                {
                    "product_id": str(product.id),
                    "quantity": "5",
                    "unit_price_ht": "100",
                    "tva_rate": "19",
                    "discount_pct": "0",
                }
            ]
        },
        headers=admin_headers,
    )
    assert update.status_code == 409
    assert update.json()["error"]["details"]["code"] == "POSTED_DOCUMENT_LOCKED"

    # client_id change → 409
    other = _invoice_client(db, name="Other Client")
    update_client = client.put(
        f"/api/v1/factures/{doc_id}",
        json={"client_id": str(other.id)},
        headers=admin_headers,
    )
    assert update_client.status_code == 409

    # payment_method change → 409
    update_pay = client.put(
        f"/api/v1/factures/{doc_id}",
        json={"payment_method": "transfer"},
        headers=admin_headers,
    )
    assert update_pay.status_code == 409

    # notes change → 200 (still editable)
    update_notes = client.put(
        f"/api/v1/factures/{doc_id}",
        json={"notes": "edited after post"},
        headers=admin_headers,
    )
    assert update_notes.status_code == 200
    assert update_notes.json()["notes"] == "edited after post"

    # show_* flags still editable
    update_flags = client.put(
        f"/api/v1/factures/{doc_id}",
        json={"show_timbre": False},
        headers=admin_headers,
    )
    assert update_flags.status_code == 200
    assert update_flags.json()["show_timbre"] is False


def test_no_unpost_endpoint_exists(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db)
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]
    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200

    # No DELETE /factures/{id}
    delete = client.delete(f"/api/v1/factures/{doc_id}", headers=admin_headers)
    assert delete.status_code == 405

    # No POST /factures/{id}/unpost
    unpost = client.post(f"/api/v1/factures/{doc_id}/unpost", headers=admin_headers)
    assert unpost.status_code in (404, 405)


# ---------------------------------------------------------------------------
# Pricing / discounts mapping
# ---------------------------------------------------------------------------


def test_discount_is_preserved_on_sale_line(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    payload = _product_payload(str(fiscal.id), str(product.id))
    payload["lines"][0]["discount_pct"] = "10"
    create = client.post("/api/v1/factures", json=payload, headers=admin_headers)
    assert create.status_code == 201
    doc_id = create.json()["id"]

    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200, post.text

    sale = db.execute(
        select(Sale).where(Sale.client_request_id == f"facture:{doc_id}")
    ).scalars().one()
    line = db.execute(
        select(SaleLine).where(SaleLine.sale_id == sale.id)
    ).scalars().one()
    # 100 * 2 * 10% = 20.00 line discount
    assert Decimal(str(line.line_discount)) == Decimal("20.00")


def test_posted_document_detail_exposes_sale_id(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]

    # Pre-post: sale_id null on detail
    detail = client.get(f"/api/v1/factures/{doc_id}", headers=admin_headers)
    assert detail.status_code == 200
    assert detail.json()["sale_id"] is None
    assert detail.json()["posted_at"] is None

    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200

    detail2 = client.get(f"/api/v1/factures/{doc_id}", headers=admin_headers)
    assert detail2.status_code == 200
    assert detail2.json()["sale_id"] is not None
    assert detail2.json()["posted_at"] is not None


def test_list_summary_exposes_sale_id(client, db, admin_headers):
    fiscal = _invoice_client(db)
    product = _product(db, quantity=Decimal("50"))
    create = client.post(
        "/api/v1/factures",
        json=_product_payload(str(fiscal.id), str(product.id)),
        headers=admin_headers,
    )
    assert create.status_code == 201
    doc_id = create.json()["id"]
    post = client.post(f"/api/v1/factures/{doc_id}/post", headers=admin_headers)
    assert post.status_code == 200

    listing = client.get("/api/v1/factures", headers=admin_headers)
    assert listing.status_code == 200
    row = next(i for i in listing.json()["items"] if i["id"] == doc_id)
    assert row["sale_id"] is not None
    assert row["posted_at"] is not None
