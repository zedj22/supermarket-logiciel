"""POS "quick custom item" — a price-only sale line with no catalog product.

Covers the whole lifecycle of the third sale-line shape:

* it is accepted by the sale schema (``custom_name`` WITHOUT product/pack),
  validated (positive price, no variant/selling unit) and persisted with its
  name snapshotted into ``sale_lines.product_name``;
* it never creates a product, never touches stock and carries no COGS;
* it totals like any other line (discounts, VAT policy, grand total);
* the invoice/receipt builder reads it and both papers render;
* full and partial returns refund it pro rata WITHOUT restoring stock.
"""

from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.sale import SaleLine
from app.printing.document_data import build_sale_document
from app.printing.render import render_invoice
from app.schemas.sale import SaleResponse
from app.services.auth import AuthService

# ── Fixtures (same SQLite TestClient scaffold as test_wholesale_pricing) ──


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


# ── Helpers ────────────────────────────────────────────────────────────


def _custom_item(name: str = "Unregistered item", price: str = "350.000") -> dict:
    return {
        "custom_name": name,
        "quantity": "1.000",
        "unit_price": price,
        "line_discount": "0.000",
    }


def _sale_payload(items: list[dict], paid: str = "9999.000") -> dict:
    return {
        "client_request_id": str(uuid.uuid4()),
        "items": items,
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": paid,
        "device_id": "POS-1",
    }


def _buy(client, headers, items: list[dict], paid: str = "9999.000") -> dict:
    resp = client.post(
        "/api/v1/sales", json=_sale_payload(items, paid=paid), headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _product(client, headers, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", f"Custom Line Product {uuid.uuid4().hex[:6]}"),
        "barcode": overrides.pop("barcode", f"CLP{uuid.uuid4().hex[:8]}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "50.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _stock(client, headers, product_id: str) -> Decimal:
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return Decimal(resp.json()["quantity"])


def _sale(client, headers, sale_id: str) -> dict:
    resp = client.get(f"/api/v1/sales/{sale_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _pos_payload(items: list[dict], *, paid: str = "100.00") -> dict:
    """The body the FLUTTER cart really posts (``PosCartNotifier.checkout``).

    Deliberately not the same shape as ``_sale_payload``: the POS sends
    ungrouped decimal STRINGS (``quantity`` / ``unit_price`` /
    ``line_discount``), a two-decimal ``paid``, an ``invoice_discount``
    that serializes as ``0.0`` and a ``device_id``. A schema regression
    that only accepts the ``.000`` test shape would pass ``_sale_payload``
    and still 422 the real app, so the wire contract is pinned here.
    """
    return {
        "client_request_id": f"pos-{uuid.uuid4().int}-42",
        "payment_method": "cash",
        "paid": paid,
        "invoice_discount": "0.0",
        "items": items,
        "device_id": "pos-test-device",
    }


def _money_text(text: str) -> Decimal:
    """Digits of a rendered money cell, whatever grouping it uses."""
    return Decimal(re.sub(r"[^0-9.]", "", text))


# ── Sale creation / persistence ────────────────────────────────────────


def test_custom_line_is_persisted_without_a_catalog_row(client, admin_headers, db):
    products_before = db.execute(select(func.count(Product.id))).scalar_one()

    body = _buy(client, admin_headers, [_custom_item()])
    sale = _sale(client, admin_headers, body["id"])

    assert len(sale["lines"]) == 1
    line = sale["lines"][0]
    assert line["product_id"] is None
    assert line["pack_id"] is None
    assert line["product_name"] == "Unregistered item"
    assert line["product_unit"] == "piece"
    assert Decimal(str(line["quantity"])) == Decimal("1")
    assert Decimal(str(line["unit_price"])) == Decimal("350")
    assert Decimal(str(line["line_total"])) == Decimal("350")
    assert Decimal(str(sale["total"])) == Decimal("350")

    db.expire_all()
    stored = db.execute(select(SaleLine)).scalars().all()
    assert len(stored) == 1
    assert stored[0].product_id is None
    assert stored[0].product_name == "Unregistered item"
    assert Decimal(str(stored[0].unit_cost)) == Decimal("0")

    products_after = db.execute(select(func.count(Product.id))).scalar_one()
    assert products_after == products_before, "no product may be created"


def test_custom_line_leaves_stock_untouched(client, admin_headers):
    product = _product(client, admin_headers, quantity="50.000")
    before = _stock(client, admin_headers, product["id"])

    body = _buy(
        client,
        admin_headers,
        [
            _custom_item(price="120.000"),
            {
                "product_id": product["id"],
                "quantity": "2.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            },
        ],
    )
    sale = _sale(client, admin_headers, body["id"])

    assert _stock(client, admin_headers, product["id"]) == before - Decimal("2")
    assert Decimal(str(sale["total"])) == Decimal("320")
    custom = next(ln for ln in sale["lines"] if ln["product_id"] is None)
    assert custom["product_name"] == "Unregistered item"


def test_custom_line_is_validated_by_the_server(client, admin_headers):
    # Zero price.
    resp = client.post(
        "/api/v1/sales",
        json=_sale_payload([_custom_item(price="0.000")]),
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text

    # No name at all and no product/pack.
    resp = client.post(
        "/api/v1/sales",
        json=_sale_payload(
            [{"quantity": "1.000", "unit_price": "350.000", "line_discount": "0"}]
        ),
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text

    # custom_name on a real product line is refused (it would be ambiguous).
    product = _product(client, admin_headers)
    resp = client.post(
        "/api/v1/sales",
        json=_sale_payload(
            [
                {
                    "product_id": product["id"],
                    "custom_name": "Nope",
                    "quantity": "1.000",
                    "unit_price": "100.000",
                    "line_discount": "0",
                }
            ]
        ),
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text

    # A custom line cannot reference a variant.
    resp = client.post(
        "/api/v1/sales",
        json=_sale_payload(
            [
                {
                    "custom_name": "Nope",
                    "variant_id": str(uuid.uuid4()),
                    "quantity": "1.000",
                    "unit_price": "10.000",
                    "line_discount": "0",
                }
            ]
        ),
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text


# ── Cart shapes: custom-only, several customs, mixed, catalog-only ─────


def test_pos_client_custom_only_payload_is_accepted(client, admin_headers):
    """The EXACT body the POS posts for one custom item (reported 422 case)."""
    body = client.post(
        "/api/v1/sales",
        json=_pos_payload(
            [
                {
                    "custom_name": "a",
                    "quantity": "1",
                    "unit_price": "100",
                    "line_discount": "0",
                }
            ],
            paid="100.00",
        ),
        headers=admin_headers,
    )
    assert body.status_code == 201, body.text
    sale = _sale(client, admin_headers, body.json()["id"])

    assert len(sale["lines"]) == 1
    line = sale["lines"][0]
    assert line["product_id"] is None
    assert line["product_name"] == "a"
    assert Decimal(str(line["unit_price"])) == Decimal("100")
    assert Decimal(str(line["quantity"])) == Decimal("1")
    assert Decimal(str(line["line_total"])) == Decimal("100")
    assert Decimal(str(sale["subtotal"])) == Decimal("100")
    assert Decimal(str(sale["total"])) == Decimal("100")
    assert Decimal(str(sale["change"])) == Decimal("0")
    assert Decimal(str(sale["debt"])) == Decimal("0")


def test_multiple_custom_items_stay_separate_lines(client, admin_headers):
    """Two customs with the SAME name and price must never merge."""
    body = _buy(
        client,
        admin_headers,
        [
            _custom_item(name="Gift wrap", price="75.500"),
            _custom_item(name="Bag", price="12.000"),
            _custom_item(name="Gift wrap", price="75.500"),
        ],
    )
    sale = _sale(client, admin_headers, body["id"])

    assert len(sale["lines"]) == 3
    assert [ln["product_name"] for ln in sale["lines"]] == [
        "Gift wrap",
        "Bag",
        "Gift wrap",
    ]
    assert all(ln["product_id"] is None for ln in sale["lines"])
    assert len({ln["id"] for ln in sale["lines"]}) == 3
    assert Decimal(str(sale["total"])) == Decimal("163")


def test_catalog_line_checkout_is_unchanged(client, admin_headers):
    """Guard: the custom-line branch must not touch normal product sales."""
    product = _product(client, admin_headers, price="100.000", quantity="50.000")
    before = _stock(client, admin_headers, product["id"])

    body = _buy(
        client,
        admin_headers,
        [
            {
                "product_id": product["id"],
                "quantity": "2.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            }
        ],
        paid="200.000",
    )
    sale = _sale(client, admin_headers, body["id"])

    assert len(sale["lines"]) == 1
    line = sale["lines"][0]
    assert line["product_id"] == product["id"]
    assert line["product_name"] == product["name"]
    assert Decimal(str(line["unit_price"])) == Decimal("100")
    assert Decimal(str(line["line_total"])) == Decimal("200")
    assert Decimal(str(line["unit_cost"])) == Decimal("60")
    assert Decimal(str(sale["total"])) == Decimal("200")
    assert _stock(client, admin_headers, product["id"]) == before - Decimal("2")


# ── Invoice / receipt ──────────────────────────────────────────────────


@pytest.mark.parametrize("paper", ["A4", "80mm"])
def test_custom_line_renders_on_both_papers(client, admin_headers, paper):
    body = _buy(client, admin_headers, [_custom_item(name="Gift wrap", price="75.500")])
    data = build_sale_document(SaleResponse.model_validate(_sale(
        client, admin_headers, body["id"]
    )), locale="en")

    line = data.lines[0]
    assert line.name == "Gift wrap"
    assert line.qty == "1"
    assert data.totals is not None

    raw = render_invoice(data, paper=paper)
    assert raw.startswith(b"%PDF")
    assert len(raw) > 1000


def test_mixed_invoice_totals_include_the_custom_line(client, admin_headers):
    product = _product(client, admin_headers, price="100.000", quantity="50.000")
    body = _buy(
        client,
        admin_headers,
        [
            {
                "product_id": product["id"],
                "quantity": "2.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            },
            _custom_item(name="Gift wrap", price="75.500"),
        ],
    )
    sale = _sale(client, admin_headers, body["id"])
    data = build_sale_document(SaleResponse.model_validate(sale), locale="en")

    assert [ln.name for ln in data.lines] == [product["name"], "Gift wrap"]
    assert Decimal(str(data.lines[1].qty)) == Decimal("1")
    assert data.totals is not None
    assert _money_text(data.totals.total) == Decimal("275.5")
    assert _money_text(data.totals.subtotal) == Decimal("275.5")
    assert Decimal(str(sale["total"])) == Decimal("275.5")


def test_line_without_a_target_is_rejected_with_the_exact_error(
    client, admin_headers
):
    """The 422 an older backend returns for the POS custom payload.

    A custom line ONLY works because the server understands
    ``custom_name``. A build whose schema predates it answers this exact
    ``product_id or pack_id is required`` 422 — the Arabic "validation
    error" the cashier sees — so the message is pinned as documentation.
    """
    resp = client.post(
        "/api/v1/sales",
        json=_pos_payload(
            [{"quantity": "1", "unit_price": "100", "line_discount": "0"}]
        ),
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    assert "product_id or pack_id is required" in resp.text


# ── Returns ────────────────────────────────────────────────────────────


def test_custom_line_full_and_partial_returns_refund_without_stock(
    client, admin_headers
):
    product = _product(client, admin_headers, quantity="50.000")
    body = _buy(
        client,
        admin_headers,
        [
            _custom_item(price="350.000"),
            {
                "product_id": product["id"],
                "quantity": "1.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            },
        ],
    )
    sale = _sale(client, admin_headers, body["id"])
    custom = next(ln for ln in sale["lines"] if ln["product_id"] is None)
    stock_after_sale = _stock(client, admin_headers, product["id"])

    # Partial return of the SALE: only the custom line comes back.
    resp = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "sale_id": sale["id"],
            "reason": "defective",
            "device_id": "POS-1",
            "lines": [{"sale_line_id": custom["id"], "quantity": "1.000"}],
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    returned = resp.json()["return"]
    assert Decimal(str(returned["total"])) == Decimal("350")
    # No stock restored: the product line was not returned.
    assert _stock(client, admin_headers, product["id"]) == stock_after_sale

    # Full return of the remaining product line closes the sale.
    resp = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "sale_id": sale["id"],
            "reason": "defective",
            "device_id": "POS-1",
            "lines": [
                {
                    "sale_line_id": next(
                        ln["id"] for ln in sale["lines"] if ln["product_id"] is not None
                    ),
                    "quantity": "1.000",
                }
            ],
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    assert _stock(client, admin_headers, product["id"]) == stock_after_sale + Decimal("1")


# ── Reports / dashboard (§5.8 item rows) ───────────────────────────────


def test_reports_and_dashboard_include_custom_lines(client, admin_headers):
    """A price-only line has no product/pack id — reports must not 500 on it.

    Regression: ``/reports/products`` and the dashboard embed the same §5.8
    item rows, whose ``item_id`` is ``coalesce(product_id, pack_id)``. A
    custom line makes that NULL, which failed response validation with
    ``UUID input should be a string`` — the generic "server error" toast —
    as soon as one custom item had been sold.
    """
    product = _product(
        client, admin_headers, name="Alpha", price="100.000", cost="60.000"
    )
    _buy(
        client,
        admin_headers,
        [
            {
                "product_id": product["id"],
                "quantity": "2.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            },
            _custom_item(name="Gift wrap", price="75.500"),
        ],
        paid="275.500",
    )
    _buy(client, admin_headers, [_custom_item(name="Gift wrap", price="24.500")], paid="24.500")

    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    window = {"date_from": day, "date_to": day}
    resp = client.get(
        "/api/v1/reports/products", params=window, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    custom = [i for i in body["items"] if i["kind"] == "custom"]
    assert len(custom) == 1, body["items"]  # same name -> one row
    assert custom[0]["name"] == "Gift wrap"
    assert custom[0]["sku"] is None
    assert custom[0]["category_id"] is None
    uuid.UUID(custom[0]["item_id"])  # typed, non-null, stable shape
    assert Decimal(str(custom[0]["net_revenue"])) == Decimal("100")
    assert Decimal(str(custom[0]["qty_sold"])) == Decimal("2")

    alpha = next(i for i in body["items"] if i["kind"] == "product")
    assert alpha["name"] == "Alpha"
    assert Decimal(str(alpha["net_revenue"])) == Decimal("200")

    financial = client.get(
        "/api/v1/reports/financial", params=window, headers=admin_headers
    )
    assert financial.status_code == 200, financial.text
    assert Decimal(str(body["totals"]["net_sales"])) == Decimal(
        str(financial.json()["net_sales"])
    )

    dash = client.get("/api/v1/dashboard", headers=admin_headers)
    assert dash.status_code == 200, dash.text
    assert "Gift wrap" in [p["name"] for p in dash.json()["top_products"]]
