"""Phase 6 post-implementation regression — migration state & on-demand loading.

Proves:
A. GET /products succeeds after migration 0005 (table exists / model maps).
B. GET /products does NOT issue product_selling_units queries.
C. GET /products does NOT issue product_variants queries.
D. Explicit variants endpoint DOES load variants.
E. Explicit selling-units endpoint DOES load selling units.

Query capture uses SQLAlchemy Engine before_cursor_execute listeners —
not JSON shape checks — so accidental eager loading fails the test.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Category, Product, ProductSellingUnit, ProductVariant
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


def _login(client: TestClient) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client)


@pytest.fixture()
def catalog_session(db, engine):
    """Seed one product with category, variant, and selling units."""
    category = Category(name="Dairy")
    db.add(category)
    db.flush()

    product = Product(
        name="Fromage Test",
        barcode="900000",
        price=10,
        cost=6,
        quantity=240,
        unit="piece",
        category_id=category.id,
    )
    db.add(product)
    db.flush()

    db.add(
        ProductVariant(
            product_id=product.id,
            name="Large",
            barcode="VAR1",
            price=12,
            quantity=10,
        )
    )
    db.add(
        ProductSellingUnit(
            product_id=product.id,
            name="Piece",
            unit_type="piece",
            multiplier=1,
            barcode="SU-PIECE-900000",
            selling_price=10,
            is_base_unit=True,
        )
    )
    db.add(
        ProductSellingUnit(
            product_id=product.id,
            name="Box",
            unit_type="piece",
            multiplier=24,
            barcode="SU-BOX-900000",
            selling_price=220,
            is_base_unit=False,
        )
    )
    db.commit()
    return product.id


class _QueryCapture:
    """Capture SQL statements issued on a specific Engine."""

    def __init__(self, eng):
        self.eng = eng
        self.statements: list[str] = []
        self._listener = self._on_execute

    def _on_execute(self, conn, cursor, statement, parameters, context, executemany):
        self.statements.append(statement)

    def __enter__(self):
        self.statements.clear()
        event.listen(self.eng, "before_cursor_execute", self._listener)
        return self

    def __exit__(self, *exc):
        event.remove(self.eng, "before_cursor_execute", self._listener)
        return False

    def sql_matching(self, *needles: str) -> list[str]:
        out = []
        for s in self.statements:
            low = s.lower()
            if any(n.lower() in low for n in needles):
                out.append(s)
        return out


def _mentions_table(statements: list[str], table: str) -> list[str]:
    t = table.lower()
    hits = []
    for s in statements:
        low = s.lower()
        # Match table name as a SQL identifier (not a substring of another name
        # beyond the table itself — product_variants vs products is fine with word-ish match).
        if t in low:
            hits.append(s)
    return hits


# ---------------------------------------------------------------------------
# A — GET /products succeeds (model + create_all includes Phase 6 table)
# ---------------------------------------------------------------------------


def test_products_list_succeeds_with_phase6_models(client, admin_headers, engine, catalog_session):
    # Table is present in the metadata/schema used by the app session.
    assert engine.dialect.has_table(engine.connect(), "product_selling_units")

    with _QueryCapture(engine) as cap:
        resp = client.get("/api/v1/products", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] >= 1
    assert any(p["name"] == "Fromage Test" for p in body["items"])


# ---------------------------------------------------------------------------
# B + C — GET /products must NOT load child tables
# ---------------------------------------------------------------------------


def test_products_list_does_not_query_selling_units_or_variants(
    client, admin_headers, engine, catalog_session
):
    with _QueryCapture(engine) as cap:
        resp = client.get("/api/v1/products", headers=admin_headers)
    assert resp.status_code == 200, resp.text

    selling_unit_sql = _mentions_table(cap.statements, "product_selling_units")
    variant_sql = _mentions_table(cap.statements, "product_variants")

    assert selling_unit_sql == [], (
        "GET /products must not query product_selling_units, got:\n"
        + "\n".join(selling_unit_sql)
    )
    assert variant_sql == [], (
        "GET /products must not query product_variants, got:\n"
        + "\n".join(variant_sql)
    )

    # Sanity: the product list itself did run (and category selectin is allowed).
    product_sql = _mentions_table(cap.statements, "products")
    assert product_sql, "expected at least one products query on the list path"


def test_products_list_does_not_query_children_even_with_many_rows(
    client, admin_headers, engine, catalog_session, db
):
    """Regression for selectin cascade: many products still no child loads."""
    for i in range(5):
        db.add(
            Product(
                name=f"Bulk {i}",
                barcode=f"BULK-{i}",
                price=1,
                cost=0,
                quantity=1,
                unit="piece",
            )
        )
    db.commit()

    with _QueryCapture(engine) as cap:
        resp = client.get(
            "/api/v1/products", params={"page_size": 100}, headers=admin_headers
        )
    assert resp.status_code == 200

    assert _mentions_table(cap.statements, "product_selling_units") == []
    assert _mentions_table(cap.statements, "product_variants") == []


# ---------------------------------------------------------------------------
# D + E — Explicit endpoints DO load children
# ---------------------------------------------------------------------------


def test_variants_endpoint_loads_variants(
    client, admin_headers, engine, catalog_session
):
    with _QueryCapture(engine) as cap:
        resp = client.get(
            f"/api/v1/products/{catalog_session}/variants", headers=admin_headers
        )
    assert resp.status_code == 200, resp.text
    items = resp.json()["items"]
    assert len(items) == 1
    assert items[0]["name"] == "Large"

    assert _mentions_table(cap.statements, "product_variants"), (
        "expected product_variants query on explicit variants endpoint; got:\n"
        + "\n".join(cap.statements)
    )


def test_selling_units_endpoint_loads_selling_units(
    client, admin_headers, engine, catalog_session
):
    with _QueryCapture(engine) as cap:
        resp = client.get(
            f"/api/v1/products/{catalog_session}/selling-units",
            headers=admin_headers,
        )
    assert resp.status_code == 200, resp.text
    items = resp.json()["items"]
    assert len(items) == 2
    names = {u["name"] for u in items}
    assert names == {"Piece", "Box"}

    assert _mentions_table(cap.statements, "product_selling_units"), (
        "expected product_selling_units query on explicit selling-units endpoint; got:\n"
        + "\n".join(cap.statements)
    )


# ---------------------------------------------------------------------------
# Loader configuration guards (catch re-introduction of selectin)
# ---------------------------------------------------------------------------


def test_product_child_relationships_are_not_selectin():
    variants_prop = Product.__mapper__.relationships["variants"]
    selling_prop = Product.__mapper__.relationships["selling_units"]
    pack_prop = Product.__mapper__.relationships["pack_items_as_component"]

    for name, prop in (
        ("variants", variants_prop),
        ("selling_units", selling_prop),
        ("pack_items_as_component", pack_prop),
    ):
        assert prop.lazy in ("noload", "select"), (
            f"Product.{name} must not be eagerly loaded (selectin/joined); got lazy={prop.lazy!r}"
        )
        assert prop.lazy != "selectin"

    # Category still needs product name without N+1 on the list path.
    cat_prop = Product.__mapper__.relationships["category"]
    assert cat_prop.lazy == "selectin"

    # Category must not reverse-load every product when product.category loads.
    cat_products = Category.__mapper__.relationships["products"]
    assert cat_products.lazy != "selectin"
    assert cat_products.lazy in ("noload", "select")
