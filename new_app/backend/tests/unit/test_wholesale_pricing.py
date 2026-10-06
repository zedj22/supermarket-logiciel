"""Phase 17 pricing tests — wholesale price, TVA rate, sale-line resolution.

Covers the Phase 17 checklist:

- product CRUD for wholesale_price / wholesale_min_qty / vat_rate
- validation: price >= 0, min qty > 0, TVA in {0, 9, 19}
- disabled wholesale = NULL = pre-phase behaviour (backward compatible)
- dynamic POS pricing: threshold measured on the line's BASE quantity
- wholesale applies ONLY to the product's base unit: a custom selling
  unit (Box/Carton/...) never inherits it, and its multiplier only
  converts quantity to base quantity for inventory
- below / at / above threshold, and crossing the threshold on a second sale
- price precedence: selling unit > variant > product retail > pack
- server authoritative: a client unit_price can neither invent a cheaper
  line nor lose the wholesale price (mismatch reported, never fatal)
- VAT is metadata only: sale totals never change with vat_rate
- pure domain function behaviour (no DB, no HTTP)
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
from app.domain.wholesale import (
    resolve_wholesale_unit_price,
    wholesale_is_configured,
)
from app.main import app
from app.models.sale import Sale, SaleLine
from app.services.auth import AuthService

# ── Fixtures (mirrors tests/unit/test_pos_sale.py) ─────────────────────


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

_seq = {"n": 0}

# Canonical wholesale fixture: retail 100, wholesale 80 from 5 units.
RETAIL = "100.000"
WHOLESALE = "80.000"
MIN_QTY = "5.000"


def _create_product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Wholesale Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"WSP{_seq['n']:06d}"),
        "price": overrides.pop("price", RETAIL),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "100.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _update_product(client, headers, product_id: str, payload: dict) -> dict:
    resp = client.put(
        f"/api/v1/products/{product_id}", json=payload, headers=headers
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _create_variant(client, headers, product_id: str, **overrides) -> dict:
    payload = {"name": overrides.pop("name", "Variant A")}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/variants",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_selling_unit(client, headers, product_id: str, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", "Box"),
        "unit_type": overrides.pop("unit_type", "piece"),
        "multiplier": overrides.pop("multiplier", "24"),
        "selling_price": overrides.pop("selling_price", None),
        "is_base_unit": overrides.pop("is_base_unit", False),
    }
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/selling-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _buy(client, headers, payload: dict) -> dict:
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale_payload(product_id: str, quantity: str, unit_price: str, paid: str, **item_overrides) -> dict:
    item = {
        "product_id": product_id,
        "quantity": quantity,
        "unit_price": unit_price,
        "line_discount": "0.000",
    }
    item.update(item_overrides)
    return {
        "client_request_id": str(uuid.uuid4()),
        "items": [item],
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": paid,
        "device_id": "POS-1",
    }


def _sell(client, headers, product_id: str, quantity: str, unit_price: str = RETAIL, paid: str = "99999.000") -> dict:
    """Sell one line and return the checkout response body."""
    payload = _sale_payload(product_id, quantity, unit_price, paid)
    payload["paid"] = str(
        Decimal(paid) if Decimal(paid) >= Decimal(quantity) * Decimal(unit_price)
        else Decimal(quantity) * Decimal(unit_price)
    )
    return _buy(client, headers, payload)


def _line_prices(db, product_id: str) -> list[float]:
    """Historic unit_price snapshot of every sale line for a product.

    Returned sorted: sale_lines carry no stable ordering column and the
    assertions below care about the multiset of applied prices, not order.
    """
    db.expire_all()
    rows = db.execute(
        select(SaleLine.unit_price).where(
            SaleLine.product_id == uuid.UUID(product_id)
        )
    ).scalars().all()
    return sorted(float(v) for v in rows)


def _stock(client, headers, product_id: str) -> float:
    """Current products.quantity — moves only by the line's BASE quantity."""
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return float(resp.json()["quantity"])


# ── A. Product CRUD + validation ───────────────────────────────────────


class TestWholesaleProductFields:
    def test_create_with_wholesale_and_vat(self, client, admin_headers):
        p = _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
            vat_rate=9,
        )
        assert float(p["wholesale_price"]) == 80.0
        assert float(p["wholesale_min_qty"]) == 5.0
        assert p["vat_rate"] == 9

        got = client.get(
            f"/api/v1/products/{p['id']}", headers=admin_headers
        ).json()
        assert float(got["wholesale_price"]) == 80.0
        assert float(got["wholesale_min_qty"]) == 5.0
        assert got["vat_rate"] == 9

    def test_create_defaults_are_backward_compatible(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        assert p["wholesale_price"] is None
        assert p["wholesale_min_qty"] is None
        assert p["vat_rate"] == 0

    def test_product_list_exposes_pricing_fields(self, client, admin_headers):
        p = _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
            vat_rate=19,
        )
        resp = client.get("/api/v1/products", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        item = next(
            i for i in resp.json()["items"] if i["id"] == p["id"]
        )
        assert "wholesale_price" in item
        assert "wholesale_min_qty" in item
        assert "vat_rate" in item
        assert item["vat_rate"] == 19

    def test_update_sets_then_clears_wholesale(self, client, admin_headers):
        p = _create_product(client, admin_headers)

        updated = _update_product(
            client,
            admin_headers,
            p["id"],
            {"wholesale_price": WHOLESALE, "wholesale_min_qty": MIN_QTY},
        )
        assert float(updated["wholesale_price"]) == 80.0
        assert float(updated["wholesale_min_qty"]) == 5.0

        cleared = _update_product(
            client,
            admin_headers,
            p["id"],
            {"wholesale_price": None, "wholesale_min_qty": None},
        )
        assert cleared["wholesale_price"] is None
        assert cleared["wholesale_min_qty"] is None

    def test_update_is_partial_around_wholesale(self, client, admin_headers):
        p = _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
            vat_rate=9,
        )
        updated = _update_product(
            client, admin_headers, p["id"], {"price": "120.000"}
        )
        assert float(updated["price"]) == 120.0
        # untouched fields survive a partial update
        assert float(updated["wholesale_price"]) == 80.0
        assert float(updated["wholesale_min_qty"]) == 5.0
        assert updated["vat_rate"] == 9

    def test_update_vat_rate(self, client, admin_headers):
        p = _create_product(client, admin_headers, vat_rate=0)
        assert p["vat_rate"] == 0
        assert _update_product(
            client, admin_headers, p["id"], {"vat_rate": 19}
        )["vat_rate"] == 19
        assert _update_product(
            client, admin_headers, p["id"], {"vat_rate": 0}
        )["vat_rate"] == 0

    @pytest.mark.parametrize(
        "field,value",
        [
            ("wholesale_price", "-0.001"),
            ("wholesale_price", "-1.000"),
            ("wholesale_min_qty", "0.000"),
            ("wholesale_min_qty", "-5.000"),
        ],
    )
    def test_invalid_wholesale_values_rejected_on_create(
        self, client, admin_headers, field, value
    ):
        resp = client.post(
            "/api/v1/products",
            json={
                "name": "Bad Wholesale",
                "price": RETAIL,
                field: value,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    @pytest.mark.parametrize(
        "field,value",
        [
            ("wholesale_price", "-1.000"),
            ("wholesale_min_qty", "0.000"),
        ],
    )
    def test_invalid_wholesale_values_rejected_on_update(
        self, client, admin_headers, field, value
    ):
        p = _create_product(client, admin_headers)
        resp = client.put(
            f"/api/v1/products/{p['id']}",
            json={field: value},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    @pytest.mark.parametrize("bad_rate", [7, 15, 19.5])
    def test_vat_rate_outside_supported_set(self, client, admin_headers, bad_rate):
        resp = client.post(
            "/api/v1/products",
            json={"name": "Bad TVA", "price": RETAIL, "vat_rate": bad_rate},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    @pytest.mark.parametrize("bad_rate", [7, 19.5])
    def test_vat_rate_rejected_on_update(self, client, admin_headers, bad_rate):
        p = _create_product(client, admin_headers)
        resp = client.put(
            f"/api/v1/products/{p['id']}",
            json={"vat_rate": bad_rate},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    @pytest.mark.parametrize("rate", [0, 9, 19])
    def test_supported_vat_rates_accepted(self, client, admin_headers, rate):
        p = _create_product(client, admin_headers, vat_rate=rate)
        assert p["vat_rate"] == rate


# ── B. Dynamic POS wholesale pricing ───────────────────────────────────


class TestWholesaleThresholdPricing:
    @pytest.fixture()
    def product(self, client, admin_headers):
        return _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
        )

    def test_qty_below_threshold_keeps_retail(self, client, admin_headers, product):
        body = _sell(client, admin_headers, product["id"], "4.000")
        assert float(body["total"]) == 400.0  # 4 x 100

    def test_qty_at_threshold_takes_wholesale(self, client, admin_headers, product):
        # The client still shows retail (100) while the server applies 80:
        # the mismatch is REPORTED through price_overrides, never fatal.
        body = _sell(client, admin_headers, product["id"], "5.000")
        assert float(body["total"]) == 400.0  # 5 x 80
        assert len(body["price_overrides"]) == 1
        assert float(body["price_overrides"][0]["requested_unit_price"]) == 100.0
        assert float(body["price_overrides"][0]["applied_unit_price"]) == 80.0

    def test_qty_above_threshold_takes_wholesale(self, client, admin_headers, product):
        body = _sell(client, admin_headers, product["id"], "6.000")
        assert float(body["total"]) == 480.0  # 6 x 80

    def test_decrease_across_threshold_returns_to_retail(
        self, client, admin_headers, product, db
    ):
        _sell(client, admin_headers, product["id"], "6.000")  # wholesale 480
        _sell(client, admin_headers, product["id"], "4.000")  # retail 400
        assert _line_prices(db, product["id"]) == [80.0, 100.0]

    def test_line_prices_below_and_above_threshold(
        self, client, admin_headers, product, db
    ):
        _sell(client, admin_headers, product["id"], "4.000")
        _sell(client, admin_headers, product["id"], "5.000")
        _sell(client, admin_headers, product["id"], "6.000")
        assert _line_prices(db, product["id"]) == [80.0, 80.0, 100.0]

    def test_client_cannot_invent_a_cheaper_line(
        self, client, admin_headers, product
    ):
        payload = _sale_payload(product["id"], "4.000", "1.000", "400.000")
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 400.0
        assert len(body["price_overrides"]) == 1
        assert float(body["price_overrides"][0]["requested_unit_price"]) == 1.0
        assert float(body["price_overrides"][0]["applied_unit_price"]) == 100.0

    def test_client_cannot_lose_the_wholesale_price(
        self, client, admin_headers, product
    ):
        payload = _sale_payload(product["id"], "5.000", RETAIL, "500.000")
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 400.0  # server applied 80
        assert len(body["price_overrides"]) == 1
        assert float(body["price_overrides"][0]["requested_unit_price"]) == 100.0
        assert float(body["price_overrides"][0]["applied_unit_price"]) == 80.0

    def test_wholesale_disabled_product_sells_at_retail(
        self, client, admin_headers
    ):
        plain = _create_product(client, admin_headers)  # wholesale NULL
        body = _sell(client, admin_headers, plain["id"], "50.000")
        assert float(body["total"]) == 5000.0  # 50 x 100

    def test_clearing_wholesale_disables_dynamic_pricing(
        self, client, admin_headers, product
    ):
        body = _sell(client, admin_headers, product["id"], "6.000")
        assert float(body["total"]) == 480.0

        _update_product(
            client,
            admin_headers,
            product["id"],
            {"wholesale_price": None, "wholesale_min_qty": None},
        )
        body = _sell(client, admin_headers, product["id"], "6.000")
        assert float(body["total"]) == 600.0  # back to 6 x 100

    def test_negative_wholesale_price_never_applies(
        self, client, admin_headers
    ):
        # A NULL/disabled half of the pair keeps wholesale off.
        p = _create_product(
            client, admin_headers, wholesale_min_qty=MIN_QTY
        )
        body = _sell(client, admin_headers, p["id"], "10.000")
        assert float(body["total"]) == 1000.0

        p2 = _create_product(
            client, admin_headers, wholesale_price=WHOLESALE
        )
        body = _sell(client, admin_headers, p2["id"], "10.000")
        assert float(body["total"]) == 1000.0


# ── C. Price precedence ────────────────────────────────────────────────


class TestWholesalePricePrecedence:
    @pytest.fixture()
    def product(self, client, admin_headers):
        return _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
        )

    def test_variant_explicit_price_beats_wholesale(
        self, client, admin_headers, product
    ):
        v = _create_variant(
            client, admin_headers, product["id"], price="90.000", quantity="50.000"
        )
        payload = _sale_payload(
            product["id"], "6.000", RETAIL, "540.000", variant_id=v["id"]
        )
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 540.0  # 6 x 90, wholesale ignored

    def test_variant_without_price_inherits_retail_then_wholesale(
        self, client, admin_headers, product
    ):
        v = _create_variant(
            client, admin_headers, product["id"], quantity="50.000"
        )  # price omitted -> NULL = inherit
        payload = _sale_payload(
            product["id"], "6.000", RETAIL, "480.000", variant_id=v["id"]
        )
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 480.0  # 6 x 80

    def test_selling_unit_price_beats_wholesale(
        self, client, admin_headers, product
    ):
        su = _create_selling_unit(
            client,
            admin_headers,
            product["id"],
            multiplier="24",
            selling_price="550.000",
        )
        payload = _sale_payload(
            product["id"], "1.000", "550.000", "550.000", selling_unit_id=su["id"]
        )
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 550.0
        assert body["price_overrides"] == []

    def test_selling_unit_without_price_falls_back_to_retail_not_wholesale(
        self, client, admin_headers, product
    ):
        su = _create_selling_unit(
            client,
            admin_headers,
            product["id"],
            multiplier="24",
            selling_price=None,
        )
        # 1 box = 24 base units, but a CUSTOM selling unit never inherits
        # the product's wholesale rule: it keeps the RETAIL price (100).
        payload = _sale_payload(
            product["id"], "1.000", RETAIL, "100.000", selling_unit_id=su["id"]
        )
        body = _buy(client, admin_headers, payload)
        assert float(body["lines"][0]["unit_price"]) == 100.0
        assert float(body["total"]) == 100.0
        assert body["price_overrides"] == []

    def test_selling_unit_below_threshold_keeps_retail(
        self, client, admin_headers
    ):
        # Threshold on the line's BASE quantity: a 1-unit sale stays retail.
        p = _create_product(
            client,
            admin_headers,
            wholesale_price=WHOLESALE,
            wholesale_min_qty=MIN_QTY,
        )
        body = _sell(client, admin_headers, p["id"], "4.999")
        assert float(body["total"]) == pytest.approx(499.9)

        su = _create_selling_unit(
            client, admin_headers, p["id"], multiplier="1", selling_price=None
        )
        payload = _sale_payload(
            p["id"], "4.000", RETAIL, "400.000", selling_unit_id=su["id"]
        )
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 400.0  # retail — custom unit, no wholesale

    def test_pack_price_is_not_rewritten_by_wholesale(
        self, client, admin_headers
    ):
        components = [
            _create_product(
                client,
                admin_headers,
                wholesale_price=WHOLESALE,
                wholesale_min_qty=MIN_QTY,
            )
            for _ in range(2)
        ]
        resp = client.post(
            "/api/v1/packs",
            json={
                "name": "Wholesale Bundle",
                "barcode": "PKWHOLESALE01",
                "price": "500.000",
                "is_active": True,
                "components": [
                    {"product_id": components[0]["id"], "quantity": "1.000"},
                    {"product_id": components[1]["id"], "quantity": "1.000"},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        pack = resp.json()

        payload = {
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {
                    "pack_id": pack["id"],
                    "quantity": "1.000",
                    "unit_price": "500.000",
                    "line_discount": "0.000",
                }
            ],
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "500.000",
            "device_id": "POS-1",
        }
        body = _buy(client, admin_headers, payload)
        assert float(body["total"]) == 500.0
        assert body["price_overrides"] == []


# ── C2. Wholesale belongs to the product's BASE unit only ──────────────


class TestWholesaleOnlyOnBaseUnit:
    """The Phase 17 rule in exact numbers: retail 200, wholesale 180 from 5.

    * Piece (the product's base unit) reaches the threshold on its OWN
      quantity: 1 -> 200, 4 -> 200, 5 -> 180, 10 -> 180.
    * Box (24 Piece) NEVER reaches it through its multiplier: 1/5/10 Box
      all charge 200 each (totals 200 / 1000 / 2000) while the inventory
      still moves 24 / 120 / 240 base units.
    """

    PRICE = "200.000"
    WHOLESALE = "180.000"
    MIN_QTY = "5.000"

    @pytest.fixture()
    def product(self, client, admin_headers):
        return _create_product(
            client,
            admin_headers,
            price=self.PRICE,
            cost="100.000",
            quantity="1000.000",
            wholesale_price=self.WHOLESALE,
            wholesale_min_qty=self.MIN_QTY,
        )

    @pytest.mark.parametrize(
        "quantity,expected_unit,expected_total",
        [
            ("1.000", 200.0, 200.0),
            ("4.000", 200.0, 800.0),
            ("5.000", 180.0, 900.0),
            ("10.000", 180.0, 1800.0),
        ],
    )
    def test_base_unit_reaches_wholesale_on_its_own_quantity(
        self,
        client,
        admin_headers,
        product,
        quantity,
        expected_unit,
        expected_total,
    ):
        # The client always quotes retail — the SERVER decides the price.
        before = _stock(client, admin_headers, product["id"])
        body = _sell(
            client, admin_headers, product["id"], quantity, unit_price=self.PRICE
        )
        line = body["lines"][0]
        assert float(line["unit_price"]) == expected_unit
        assert float(line["quantity"]) == float(quantity)
        assert float(body["total"]) == expected_total
        # Base unit: the threshold quantity IS the sold quantity.
        assert before - _stock(client, admin_headers, product["id"]) == float(
            quantity
        )

    @pytest.mark.parametrize(
        "quantity,expected_total,expected_base",
        [
            ("1.000", 200.0, 24.0),
            ("5.000", 1000.0, 120.0),
            ("10.000", 2000.0, 240.0),
        ],
    )
    @pytest.mark.parametrize("selling_price", [None, PRICE])
    def test_custom_selling_unit_never_takes_wholesale(
        self,
        client,
        admin_headers,
        product,
        quantity,
        expected_total,
        expected_base,
        selling_price,
    ):
        su = _create_selling_unit(
            client,
            admin_headers,
            product["id"],
            multiplier="24",
            selling_price=selling_price,
        )
        before = _stock(client, admin_headers, product["id"])
        payload = _sale_payload(
            product["id"],
            quantity,
            self.PRICE,
            "99999.000",
            selling_unit_id=su["id"],
        )
        body = _buy(client, admin_headers, payload)
        line = body["lines"][0]
        # Wholesale stays FALSE for every Box case: retail, never 180.
        assert float(line["unit_price"]) == 200.0
        assert float(line["quantity"]) == float(quantity)
        assert float(body["total"]) == expected_total
        assert body["price_overrides"] == []
        # The multiplier still converts quantity -> base quantity, but for
        # INVENTORY only: 1/5/10 Box deduct 24/120/240 Piece.
        assert before - _stock(client, admin_headers, product["id"]) == (
            expected_base
        )

    def test_base_unit_and_box_price_differ_on_the_same_product(
        self, client, admin_headers, product
    ):
        """Wholesale for Piece, retail for Box — same cart, same product."""
        box = _create_selling_unit(
            client,
            admin_headers,
            product["id"],
            multiplier="24",
            selling_price=None,
        )
        payload = {
            "client_request_id": str(uuid.uuid4()),
            "items": [
                # 6 Piece -> threshold reached -> 180
                {
                    "product_id": product["id"],
                    "quantity": "6.000",
                    "unit_price": self.PRICE,
                    "line_discount": "0.000",
                },
                # 1 Box (24 Piece, threshold as a base quantity would be
                # reached) -> still retail 200
                {
                    "product_id": product["id"],
                    "quantity": "1.000",
                    "unit_price": self.PRICE,
                    "line_discount": "0.000",
                    "selling_unit_id": box["id"],
                },
            ],
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "99999.000",
            "device_id": "POS-1",
        }
        before = _stock(client, admin_headers, product["id"])
        body = _buy(client, admin_headers, payload)
        piece, box_line = body["lines"]
        assert float(piece["unit_price"]) == 180.0
        assert float(box_line["unit_price"]) == 200.0
        assert float(body["total"]) == float(6 * 180 + 1 * 200)
        assert before - _stock(client, admin_headers, product["id"]) == 30.0  # 6 + 24

    def test_pos_cart_validate_reports_base_quantity_and_retail_price(
        self, client, admin_headers, product
    ):
        """The stateless POS validation mirrors the same two numbers."""
        su = _create_selling_unit(
            client,
            admin_headers,
            product["id"],
            multiplier="24",
            selling_price=None,
        )
        resp = client.post(
            "/api/v1/pos/cart/validate",
            json={
                "items": [
                    {
                        "product_id": product["id"],
                        "quantity": "5.000",
                        "unit_price": self.PRICE,
                        "selling_unit_id": su["id"],
                    }
                ],
                "payment_method": "cash",
                "paid": "99999.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["ok"] is True, (body["errors"], body["lines"][0])
        line = body["lines"][0]
        assert float(line["unit_price"]) == 200.0  # never wholesale
        assert float(line["required_quantity"]) == 120.0  # 5 Box = 120 Piece
        assert float(body["total"]) == 1000.0


# ── D. VAT is metadata only ────────────────────────────────────────────


class TestVatRateDoesNotChangeTotals:
    @pytest.mark.parametrize("rate", [0, 9, 19])
    def test_sale_total_is_identical_for_every_rate(
        self, client, admin_headers, rate
    ):
        p = _create_product(client, admin_headers, vat_rate=rate)
        body = _sell(client, admin_headers, p["id"], "3.000")
        assert float(body["total"]) == 300.0  # 3 x 100, no tax arithmetic

    def test_vat_rate_is_stored_but_not_charged(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, vat_rate=19, price="50.000")
        _sell(client, admin_headers, p["id"], "2.000")

        db.expire_all()
        sale = db.execute(
            select(Sale).order_by(Sale.created_at.desc())
        ).scalars().first()
        line = db.execute(
            select(SaleLine).where(SaleLine.sale_id == sale.id)
        ).scalars().first()
        assert float(line.unit_price) == 50.0
        assert float(sale.total) == 100.0

        stored = client.get(
            f"/api/v1/products/{p['id']}", headers=admin_headers
        ).json()
        assert stored["vat_rate"] == 19


# ── E. Pure domain function ────────────────────────────────────────────


class TestWholesaleDomain:
    @pytest.mark.parametrize(
        "kwargs,expected",
        [
            ({"wholesale_price": "80", "wholesale_min_qty": "5"}, True),
            ({"wholesale_price": None, "wholesale_min_qty": "5"}, False),
            ({"wholesale_price": "80", "wholesale_min_qty": None}, False),
            ({"wholesale_price": None, "wholesale_min_qty": None}, False),
            ({"wholesale_price": "80", "wholesale_min_qty": "0"}, False),
            ({"wholesale_price": "80", "wholesale_min_qty": "-5"}, False),
            ({"wholesale_price": "-1", "wholesale_min_qty": "5"}, False),
            # price 0 is CONFIGURED, exactly like retail price 0: a free
            # wholesale line is legal (and visible in the POS) rather than
            # silently falling back to retail.
            ({"wholesale_price": "0", "wholesale_min_qty": "5"}, True),
        ],
    )
    def test_wholesale_is_configured(self, kwargs, expected):
        assert wholesale_is_configured(
            wholesale_price=kwargs["wholesale_price"],
            wholesale_min_qty=kwargs["wholesale_min_qty"],
        ) is expected

    @pytest.mark.parametrize(
        "quantity_base,expected",
        [
            ("4.999", "100.000"),
            ("5.000", "80.000"),
            ("5.001", "80.000"),
            ("100.000", "80.000"),
        ],
    )
    def test_threshold_is_inclusive_of_the_minimum(self, quantity_base, expected):
        assert resolve_wholesale_unit_price(
            retail_price=Decimal("100.000"),
            wholesale_price=Decimal("80.000"),
            wholesale_min_qty=Decimal("5.000"),
            quantity_base=Decimal(quantity_base),
        ) == Decimal(expected)

    @pytest.mark.parametrize(
        "kwargs,quantity_base",
        [
            ({"wholesale_price": None, "wholesale_min_qty": "5"}, "10"),
            ({"wholesale_price": "80", "wholesale_min_qty": None}, "10"),
            ({"wholesale_price": "80", "wholesale_min_qty": "0"}, "10"),
            ({"wholesale_price": "-1", "wholesale_min_qty": "5"}, "10"),
        ],
    )
    def test_disabled_wholesale_returns_retail_unchanged(
        self, kwargs, quantity_base
    ):
        assert resolve_wholesale_unit_price(
            retail_price=Decimal("100.000"),
            wholesale_price=kwargs["wholesale_price"],
            wholesale_min_qty=kwargs["wholesale_min_qty"],
            quantity_base=Decimal(quantity_base),
        ) == Decimal("100.000")

    def test_wholesale_higher_than_retail_is_still_the_wholesale_price(self):
        # No "never charge more" rule: the configured wholesale price wins
        # once the threshold is met (documented in docs/PHASE_17_PRICING.md).
        assert resolve_wholesale_unit_price(
            retail_price=Decimal("100.000"),
            wholesale_price=Decimal("120.000"),
            wholesale_min_qty=Decimal("5.000"),
            quantity_base=Decimal("10.000"),
        ) == Decimal("120.000")

    def test_non_finite_inputs_are_ignored(self):
        assert resolve_wholesale_unit_price(
            retail_price=Decimal("100.000"),
            wholesale_price=Decimal("NaN"),
            wholesale_min_qty=Decimal("5.000"),
            quantity_base=Decimal("10.000"),
        ) == Decimal("100.000")
