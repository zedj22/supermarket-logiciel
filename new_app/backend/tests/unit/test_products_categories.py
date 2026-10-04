"""Phase 5 tests — products & categories.

Covers:
- list/pagination/search/category filter/sorting
- get/create/update/archive product
- invalid product data, duplicate barcode
- search by name and exact barcode
- low-stock endpoint
- category CRUD, archive, duplicate name, product counts
- archived category rejects new product assignment
- permission denied (cashier cannot create/manage)
- authentication required (401)
- structured error contract
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
from app.models.catalog import Category, Product
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
    """Seeded session: roles/permissions + admin/manager/cashier users."""
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
    """TestClient with get_db overridden to the shared in-memory DB.

    get_current_user also uses Depends(get_db), so JWT auth resolves
    against this same database.
    """

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
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


def _product_payload(**overrides) -> dict:
    payload = {
        "name": "Test Product",
        "barcode": "123456789",
        "price": "100.000",
        "cost": "80.000",
        "quantity": "10.000",
    }
    payload.update(overrides)
    return payload


def _create_product(client, headers, **overrides) -> dict:
    resp = client.post(
        "/api/v1/products", json=_product_payload(**overrides), headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_category(client, headers, name="مواد غذائية") -> dict:
    resp = client.post("/api/v1/categories", json={"name": name}, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# Authentication required
# ---------------------------------------------------------------------------


def test_products_list_requires_auth(client):
    resp = client.get("/api/v1/products")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


def test_categories_list_requires_auth(client):
    resp = client.get("/api/v1/categories")
    assert resp.status_code == 401


def test_product_create_requires_auth(client):
    resp = client.post("/api/v1/products", json=_product_payload())
    assert resp.status_code == 401


def test_products_reject_invalid_token(client):
    resp = client.get(
        "/api/v1/products",
        headers={"Authorization": "Bearer not.a.token"},
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Product list / pagination / search / filter / sort
# ---------------------------------------------------------------------------


def test_list_products_empty(client, admin_headers):
    resp = client.get("/api/v1/products", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 1
    assert body["pages"] == 1


def test_create_product_and_get(client, admin_headers):
    created = _create_product(client, admin_headers)
    assert created["name"] == "Test Product"
    assert created["barcode"] == "123456789"
    assert created["is_archived"] is False
    assert Decimal(created["price"]) == Decimal("100")
    assert Decimal(created["cost"]) == Decimal("80")
    assert Decimal(created["quantity"]) == Decimal("10")

    resp = client.get(f"/api/v1/products/{created['id']}", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json()["id"] == created["id"]


def test_get_product_not_found(client, admin_headers):
    resp = client.get(f"/api/v1/products/{uuid.uuid4()}", headers=admin_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_list_products_pagination(client, admin_headers):
    for i in range(5):
        _create_product(
            client, admin_headers, name=f"Product {i}", barcode=f"BC{i:03d}"
        )

    resp = client.get(
        "/api/v1/products?page=1&page_size=2", headers=admin_headers
    )
    body = resp.json()
    assert body["total"] == 5
    assert body["page"] == 1
    assert body["page_size"] == 2
    assert body["pages"] == 3
    assert len(body["items"]) == 2

    resp2 = client.get(
        "/api/v1/products?page=3&page_size=2", headers=admin_headers
    )
    assert len(resp2.json()["items"]) == 1


def test_list_products_limit_alias(client, admin_headers):
    for i in range(3):
        _create_product(
            client, admin_headers, name=f"Limited {i}", barcode=f"LM{i:03d}"
        )
    resp = client.get("/api/v1/products?limit=2", headers=admin_headers)
    body = resp.json()
    assert body["page_size"] == 2
    assert len(body["items"]) == 2


def test_search_by_name(client, admin_headers):
    _create_product(client, admin_headers, name="Apple Juice", barcode="A1")
    _create_product(client, admin_headers, name="Banana", barcode="B1")

    resp = client.get(
        "/api/v1/products?search=apple", headers=admin_headers
    )
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["name"] == "Apple Juice"


def test_search_endpoint_by_name(client, admin_headers):
    _create_product(client, admin_headers, name="Milk Full Cream", barcode="M1")
    _create_product(client, admin_headers, name="Bread", barcode="BR1")

    resp = client.get(
        "/api/v1/products/search?q=milk", headers=admin_headers
    )
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["name"] == "Milk Full Cream"


def test_search_endpoint_exact_barcode(client, admin_headers):
    _create_product(client, admin_headers, name="Scan Me", barcode="999888777")
    _create_product(client, admin_headers, name="Other", barcode="111")

    resp = client.get(
        "/api/v1/products/search?barcode=999888777", headers=admin_headers
    )
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["barcode"] == "999888777"


def test_search_endpoint_bounded(client, admin_headers):
    for i in range(30):
        _create_product(
            client, admin_headers, name=f"Bulk {i}", barcode=f"BK{i:04d}"
        )
    resp = client.get(
        "/api/v1/products/search?q=Bulk&limit=5", headers=admin_headers
    )
    body = resp.json()
    assert len(body["items"]) <= 5
    assert body["total"] == 30


def test_search_total_is_capped(client, admin_headers, monkeypatch):
    """17.8: the match count stops at SEARCH_TOTAL_CAP (bounded scan)."""
    from app.repositories import catalog

    monkeypatch.setattr(catalog, "SEARCH_TOTAL_CAP", 10)
    for i in range(15):
        _create_product(
            client, admin_headers, name=f"Capped {i}", barcode=f"CP{i:04d}"
        )

    resp = client.get(
        "/api/v1/products/search?q=Capped&limit=50", headers=admin_headers
    )
    body = resp.json()
    assert len(body["items"]) == 15
    assert body["total"] == 10

    # Below the cap the total is still exact.
    resp = client.get(
        "/api/v1/products/search?q=Capped 14", headers=admin_headers
    )
    assert resp.json()["total"] == 1


def test_filter_by_category(client, admin_headers):
    cat = _create_category(client, admin_headers, "Drinks")
    other = _create_category(client, admin_headers, "Snacks")
    _create_product(
        client, admin_headers, name="Cola", barcode="C1", category_id=cat["id"]
    )
    _create_product(
        client, admin_headers, name="Chips", barcode="CH1", category_id=other["id"]
    )

    resp = client.get(
        f"/api/v1/products?category_id={cat['id']}", headers=admin_headers
    )
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["name"] == "Cola"
    assert body["items"][0]["category_name"] == "Drinks"


def test_sort_by_price_desc(client, admin_headers):
    _create_product(client, admin_headers, name="Cheap", barcode="P1", price="10")
    _create_product(client, admin_headers, name="Pricey", barcode="P2", price="500")
    _create_product(client, admin_headers, name="Mid", barcode="P3", price="100")

    resp = client.get(
        "/api/v1/products?sort_by=price&sort_order=desc",
        headers=admin_headers,
    )
    names = [i["name"] for i in resp.json()["items"]]
    assert names == ["Pricey", "Mid", "Cheap"]


def test_sort_by_name_asc(client, admin_headers):
    _create_product(client, admin_headers, name="Zeta", barcode="Z1")
    _create_product(client, admin_headers, name="Alpha", barcode="A1")

    resp = client.get(
        "/api/v1/products?sort_by=name&sort_order=asc", headers=admin_headers
    )
    names = [i["name"] for i in resp.json()["items"]]
    assert names[0] == "Alpha"


# ---------------------------------------------------------------------------
# Product create validation
# ---------------------------------------------------------------------------


def test_create_product_requires_name(client, admin_headers):
    resp = client.post(
        "/api/v1/products", json={"price": "10"}, headers=admin_headers
    )
    assert resp.status_code == 422


def test_create_product_blank_name_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json={"name": "   ", "price": "10"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_negative_price_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json={"name": "Bad", "price": "-1"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_negative_cost_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json={"name": "Bad", "price": "10", "cost": "-5"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_negative_quantity_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json={"name": "Bad", "price": "10", "quantity": "-1"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_invalid_category_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(category_id=str(uuid.uuid4())),
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_invalid_date_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(expiry_date="not-a-date"),
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_invalid_image_extension_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(image_path="/images/product.exe"),
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_product_invalid_unit_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(unit="furlong"),
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_duplicate_barcode_conflict(client, admin_headers):
    _create_product(client, admin_headers, barcode="DUP-1")
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(name="Another", barcode="DUP-1"),
        headers=admin_headers,
    )
    assert resp.status_code == 409
    body = resp.json()
    assert body["error"]["code"] == "CONFLICT"
    assert "barcode" in body["error"]["message"].lower()


def test_duplicate_barcode_on_update_conflict(client, admin_headers):
    _create_product(client, admin_headers, barcode="KEEP")
    second = _create_product(
        client, admin_headers, name="Second", barcode="OTHER"
    )
    resp = client.put(
        f"/api/v1/products/{second['id']}",
        json={"barcode": "KEEP"},
        headers=admin_headers,
    )
    assert resp.status_code == 409


def test_multiple_products_without_barcode_ok(client, admin_headers):
    # Barcode is optional and NULLable; unique constraint allows multiple NULLs.
    _create_product(client, admin_headers, name="No Barcode 1", barcode=None)
    _create_product(client, admin_headers, name="No Barcode 2", barcode=None)
    resp = client.get("/api/v1/products", headers=admin_headers)
    assert resp.json()["total"] == 2


# ---------------------------------------------------------------------------
# Product update / archive
# ---------------------------------------------------------------------------


def test_update_product(client, admin_headers):
    created = _create_product(client, admin_headers)
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"name": "Renamed Product", "price": "120.500"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "Renamed Product"
    assert Decimal(body["price"]) == Decimal("120.5")
    # Unchanged fields preserved
    assert Decimal(body["cost"]) == Decimal("80")
    assert body["barcode"] == "123456789"

    # Persists after reload
    again = client.get(
        f"/api/v1/products/{created['id']}", headers=admin_headers
    ).json()
    assert again["name"] == "Renamed Product"
    assert Decimal(again["price"]) == Decimal("120.5")


def test_update_product_validation_rejects_negative(client, admin_headers):
    created = _create_product(client, admin_headers)
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"price": "-1"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_update_product_not_found(client, admin_headers):
    resp = client.put(
        f"/api/v1/products/{uuid.uuid4()}",
        json={"name": "X"},
        headers=admin_headers,
    )
    assert resp.status_code == 404


def test_archive_product(client, admin_headers):
    created = _create_product(client, admin_headers)
    resp = client.delete(
        f"/api/v1/products/{created['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True

    # Excluded from default (active) list
    active = client.get("/api/v1/products", headers=admin_headers).json()
    assert active["total"] == 0

    # Visible with status=archived
    archived = client.get(
        "/api/v1/products?status=archived", headers=admin_headers
    ).json()
    assert archived["total"] == 1
    assert archived["items"][0]["is_archived"] is True

    # Visible with status=all
    all_resp = client.get(
        "/api/v1/products?status=all", headers=admin_headers
    ).json()
    assert all_resp["total"] == 1

    # Still retrievable by id (record preserved)
    detail = client.get(
        f"/api/v1/products/{created['id']}", headers=admin_headers
    )
    assert detail.status_code == 200


def test_archive_product_idempotent(client, admin_headers):
    created = _create_product(client, admin_headers)
    first = client.delete(
        f"/api/v1/products/{created['id']}", headers=admin_headers
    )
    second = client.delete(
        f"/api/v1/products/{created['id']}", headers=admin_headers
    )
    assert first.status_code == 200
    assert second.status_code == 200


def test_invalid_status_filter_rejected(client, admin_headers):
    resp = client.get(
        "/api/v1/products?status=deleted", headers=admin_headers
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Low stock
# ---------------------------------------------------------------------------


def test_low_stock_endpoint(client, admin_headers):
    _create_product(
        client,
        admin_headers,
        name="Low Item",
        barcode="LOW1",
        quantity="2",
        low_stock_threshold="5",
    )
    _create_product(
        client,
        admin_headers,
        name="Healthy Item",
        barcode="HI1",
        quantity="50",
        low_stock_threshold="5",
    )

    resp = client.get("/api/v1/products/low-stock", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["name"] == "Low Item"


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------


def test_list_categories_empty(client, admin_headers):
    resp = client.get("/api/v1/categories", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json()["items"] == []
    assert resp.json()["total"] == 0


def test_create_category(client, admin_headers):
    resp = client.post(
        "/api/v1/categories",
        json={"name": "مواد غذائية"},
        headers=admin_headers,
    )
    assert resp.status_code == 201
    body = resp.json()
    assert body["name"] == "مواد غذائية"
    assert body["is_archived"] is False
    assert body["product_count"] == 0


def test_create_category_blank_name_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/categories", json={"name": "  "}, headers=admin_headers
    )
    assert resp.status_code == 422


def test_duplicate_category_name_conflict(client, admin_headers):
    _create_category(client, admin_headers, "Drinks")
    resp = client.post(
        "/api/v1/categories", json={"name": "Drinks"}, headers=admin_headers
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "CONFLICT"


def test_update_category(client, admin_headers):
    cat = _create_category(client, admin_headers, "Old Name")
    resp = client.put(
        f"/api/v1/categories/{cat['id']}",
        json={"name": "New Name"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "New Name"

    again = client.get(
        f"/api/v1/categories/{cat['id']}", headers=admin_headers
    ).json()
    assert again["name"] == "New Name"


def test_category_product_count(client, admin_headers):
    cat = _create_category(client, admin_headers, "Counted")
    _create_product(
        client, admin_headers, name="In Cat", barcode="IC1", category_id=cat["id"]
    )
    _create_product(
        client, admin_headers, name="Also In", barcode="IC2", category_id=cat["id"]
    )
    # Archived product should not count as active
    extra = _create_product(
        client, admin_headers, name="Archived In", barcode="IC3", category_id=cat["id"]
    )
    client.delete(f"/api/v1/products/{extra['id']}", headers=admin_headers)

    resp = client.get("/api/v1/categories", headers=admin_headers)
    items = {i["name"]: i for i in resp.json()["items"]}
    assert items["Counted"]["product_count"] == 2


def test_archive_category(client, admin_headers):
    cat = _create_category(client, admin_headers, "Seasonal")
    resp = client.delete(
        f"/api/v1/categories/{cat['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True

    # Still listed with status=all (default), flagged archived
    listed = client.get("/api/v1/categories", headers=admin_headers).json()
    item = next(i for i in listed["items"] if i["id"] == cat["id"])
    assert item["is_archived"] is True

    # Excluded from status=active (used by product form dropdown)
    active = client.get(
        "/api/v1/categories?status=active", headers=admin_headers
    ).json()
    assert all(i["id"] != cat["id"] for i in active["items"])


def test_archived_category_rejects_new_product(client, admin_headers):
    cat = _create_category(client, admin_headers, "Retired")
    client.delete(f"/api/v1/categories/{cat['id']}", headers=admin_headers)

    resp = client.post(
        "/api/v1/products",
        json=_product_payload(category_id=cat["id"]),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert "archived" in resp.json()["error"]["message"].lower()


def test_existing_product_keeps_archived_category_reference(
    client, admin_headers
):
    cat = _create_category(client, admin_headers, "Legacy")
    product = _create_product(
        client, admin_headers, category_id=cat["id"], barcode="LEG1"
    )
    client.delete(f"/api/v1/categories/{cat['id']}", headers=admin_headers)

    detail = client.get(
        f"/api/v1/products/{product['id']}", headers=admin_headers
    ).json()
    assert detail["category_id"] == cat["id"]
    assert detail["category_name"] == "Legacy"


def test_get_category_not_found(client, admin_headers):
    resp = client.get(
        f"/api/v1/categories/{uuid.uuid4()}", headers=admin_headers
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------


def test_cashier_can_list_products(client, cashier_headers):
    resp = client.get("/api/v1/products", headers=cashier_headers)
    assert resp.status_code == 200


def test_cashier_cannot_create_product(client, cashier_headers):
    resp = client.post(
        "/api/v1/products", json=_product_payload(), headers=cashier_headers
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_cashier_cannot_update_product(client, cashier_headers, admin_headers):
    created = _create_product(client, admin_headers)
    resp = client.put(
        f"/api/v1/products/{created['id']}",
        json={"name": "Hacked"},
        headers=cashier_headers,
    )
    assert resp.status_code == 403


def test_cashier_cannot_archive_product(client, cashier_headers, admin_headers):
    created = _create_product(client, admin_headers)
    resp = client.delete(
        f"/api/v1/products/{created['id']}", headers=cashier_headers
    )
    assert resp.status_code == 403


def test_cashier_can_list_categories(client, cashier_headers):
    resp = client.get("/api/v1/categories", headers=cashier_headers)
    assert resp.status_code == 200


def test_cashier_cannot_create_category(client, cashier_headers):
    resp = client.post(
        "/api/v1/categories",
        json={"name": "Nope"},
        headers=cashier_headers,
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_cashier_cannot_archive_category(client, cashier_headers, admin_headers):
    cat = _create_category(client, admin_headers)
    resp = client.delete(
        f"/api/v1/categories/{cat['id']}", headers=cashier_headers
    )
    assert resp.status_code == 403


def test_manager_can_create_product(client, manager_headers):
    resp = client.post(
        "/api/v1/products",
        json=_product_payload(name="Manager Item", barcode="MG1"),
        headers=manager_headers,
    )
    assert resp.status_code == 201


def test_manager_can_create_category(client, manager_headers):
    resp = client.post(
        "/api/v1/categories",
        json={"name": "Manager Cat"},
        headers=manager_headers,
    )
    assert resp.status_code == 201


def test_forbidden_uses_structured_error(client, cashier_headers):
    resp = client.post(
        "/api/v1/products", json=_product_payload(), headers=cashier_headers
    )
    body = resp.json()
    assert "error" in body
    assert body["error"]["code"] == "FORBIDDEN"
    assert body["error"]["message_key"] == "errors.forbidden"
    assert "request_id" in body["error"]


# ---------------------------------------------------------------------------
# Data integrity (constraints / archive behavior)
# ---------------------------------------------------------------------------


def test_product_barcode_unique_at_db_level(db):
    from app.models.catalog import Product as ProductModel

    p1 = ProductModel(name="A", barcode="DBUNIQUE", price=1, cost=1, quantity=1)
    p2 = ProductModel(name="B", barcode="DBUNIQUE", price=1, cost=1, quantity=1)
    db.add(p1)
    db.flush()
    db.add(p2)
    with pytest.raises(Exception):
        db.flush()
    db.rollback()


def test_category_unique_name_at_db_level(db):
    from app.models.catalog import Category as CategoryModel

    db.add(CategoryModel(name="UNIQUE-CAT"))
    db.flush()
    db.add(CategoryModel(name="UNIQUE-CAT"))
    with pytest.raises(Exception):
        db.flush()
    db.rollback()


def test_no_n_plus_one_category_counts_in_single_page(client, admin_headers, TestingSession):
    """Category counts must not issue per-category queries (no N+1).

    Models use lazy='selectin', so a few constant batched statements are
    expected — the invariant is that the total query count does not grow
    as categories/products are added, and no per-category count() on
    products is issued.
    """
    from sqlalchemy import event

    from app.repositories.catalog import CategoryRepository

    def _repo_call_with_query_log(category_offset: int) -> list[str]:
        for i in range(5):
            idx = category_offset + i
            cat = _create_category(client, admin_headers, f"Cat {idx}")
            _create_product(
                client,
                admin_headers,
                name=f"P {idx}",
                barcode=f"NP{idx}",
                category_id=cat["id"],
            )

        session = TestingSession()
        queries: list[str] = []

        def _log(conn, cursor, statement, parameters, context, executemany):
            queries.append(statement)

        event.listen(session.bind, "before_cursor_execute", _log)
        try:
            repo = CategoryRepository(session)
            rows, total = repo.list_with_counts(page=1, page_size=50)
            counts = [c for _, c in rows]
            assert all(c >= 1 for c in counts)
            assert total == 10 if category_offset else total == 5
        finally:
            event.remove(session.bind, "before_cursor_execute", _log)
            session.close()
        return queries

    queries_5 = _repo_call_with_query_log(0)
    queries_10 = _repo_call_with_query_log(5)

    # Constant query count — independent of how many categories exist.
    assert len(queries_10) == len(queries_5), (queries_5, queries_10)

    # No standalone per-category count() against products (only the
    # grouped subquery embedded in the main list statement is allowed).
    product_count_queries = [
        q for q in queries_10
        if q.lower().lstrip().startswith("select count")
        and "from products" in q.lower()
    ]
    assert product_count_queries == [], product_count_queries
