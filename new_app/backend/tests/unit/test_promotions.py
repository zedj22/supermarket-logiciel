"""Phase 18 promotion system tests.

Covers the Phase 18 checklist:

- pure domain: promotional_unit_price / promotion_is_configured (no DB)
- CRUD: create (bulk, idempotent), list (filters), get, update (partial
  membership replace), toggle (active <-> inactive)
- validation: percentage 0 < v <= 100, fixed price >= 0, multi-product
  x fixed price ban, unknown product, blank name
- idempotency: same key + payload = replay, different payload = 409
- overlap: at most ONE ACTIVE promotion per product (409 on conflict,
  inactive promotions may overlap, activating re-checks under locks)
- bulk atomicity: any failure = nothing persisted (no partial state)
- price integration: promotion discounts the retail branch only;
  products.price is NEVER written; deactivation restores retail;
  historical sale snapshots unchanged; wholesale precedence unchanged;
  selling units / variants with explicit prices are never promoted
- product responses expose the active promotion + server-computed price
- permissions: promotion_view/create/update = admin + manager, cashier 403
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
from app.domain.promotion import (
    promotion_is_configured,
    promotional_unit_price,
)
from app.main import app
from app.models.sale import SaleLine
from app.services.auth import AuthService

# ── Fixtures (mirrors tests/unit/test_expenses.py) ─────────────────────


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
        with TestClient(app, raise_server_exceptions=False) as c:
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


# ── Helpers ────────────────────────────────────────────────────────────

_seq = {"n": 0}

RETAIL = "200.000"


def _next() -> int:
    _seq["n"] += 1
    return _seq["n"]


def _create_product(client, headers, **overrides) -> dict:
    n = _next()
    payload = {
        "name": overrides.pop("name", f"Promo Product {n}"),
        "barcode": overrides.pop("barcode", f"PRM{n:06d}"),
        "price": overrides.pop("price", RETAIL),
        "cost": overrides.pop("cost", "100.000"),
        "quantity": overrides.pop("quantity", "500.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _promo_payload(**overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "name": f"Promo {_next()}",
        "promotion_type": "percentage",
        "value": "20",
        "product_ids": [],
        "is_active": True,
    }
    payload.update(overrides)
    return payload


def _create_promo(client, headers, payload: dict | None = None, **kwargs) -> dict:
    body = payload if payload is not None else _promo_payload(**kwargs)
    resp = client.post("/api/v1/promotions", json=body, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_promo_raw(client, headers, payload: dict):
    return client.post("/api/v1/promotions", json=payload, headers=headers)


def _toggle(client, headers, promo_id: str):
    return client.post(
        f"/api/v1/promotions/{promo_id}/toggle", headers=headers
    )


def _buy(client, headers, items: list[dict]) -> dict:
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": items,
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "99999.000",
            "device_id": "POS-1",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _line_item(product_id: str, quantity: str = "1", **overrides) -> dict:
    item = {
        "product_id": product_id,
        "quantity": quantity,
        "unit_price": RETAIL,  # display hint only — server is authoritative
        "line_discount": "0.000",
    }
    item.update(overrides)
    return item


def _sell_one(client, headers, product_id: str, quantity: str = "1") -> dict:
    return _buy(client, headers, [_line_item(product_id, quantity)])


def _unit_price(body: dict, index: int = 0) -> Decimal:
    return Decimal(body["lines"][index]["unit_price"])


def _product_price(client, headers, product_id: str) -> Decimal:
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return Decimal(resp.json()["price"])


# ══════════════════════════════════════════════════════════════════════
# 1. Pure domain (no DB, no HTTP)
# ══════════════════════════════════════════════════════════════════════


class TestPromotionDomain:
    def test_percentage_discounts_the_retail_price(self):
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="percentage",
            value=Decimal("20"),
        ) == Decimal("160.000")

    def test_percentage_is_half_up_on_the_money_quantum(self):
        # 10.001 x 50% = 5.0005 -> ROUND_HALF_UP -> 5.001
        # (HALF_EVEN would give 5.000 — money here is HALF_UP, sale.py _money)
        assert promotional_unit_price(
            retail_price=Decimal("10.001"), promotion_type="percentage",
            value=Decimal("50"),
        ) == Decimal("5.001")

    def test_percentage_100_is_free(self):
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="percentage",
            value=Decimal("100"),
        ) == Decimal("0.000")

    def test_fixed_price_replaces_retail(self):
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="fixed_price",
            value=Decimal("160"),
        ) == Decimal("160.000")

    def test_fixed_price_above_retail_never_raises_the_price(self):
        # A promotion is a discount: invariant promo <= retail.
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="fixed_price",
            value=Decimal("300"),
        ) == Decimal("200.000")

    @pytest.mark.parametrize("bad_value", ["0", "101", "-5", "not-a-number"])
    def test_invalid_percentage_returns_retail_unchanged(self, bad_value):
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="percentage",
            value=bad_value,
        ) == Decimal("200.000")

    def test_unknown_type_returns_retail_unchanged(self):
        assert promotional_unit_price(
            retail_price=Decimal("200"), promotion_type="bogus",
            value=Decimal("20"),
        ) == Decimal("200.000")

    def test_promotion_is_configured_matrix(self):
        assert promotion_is_configured("percentage", Decimal("20")) is True
        assert promotion_is_configured("percentage", Decimal("100")) is True
        assert promotion_is_configured("percentage", Decimal("0")) is False
        assert promotion_is_configured("percentage", Decimal("101")) is False
        assert promotion_is_configured("fixed_price", Decimal("0")) is True
        assert promotion_is_configured("fixed_price", None) is False
        assert promotion_is_configured(None, Decimal("20")) is False


# ══════════════════════════════════════════════════════════════════════
# 2. CRUD
# ══════════════════════════════════════════════════════════════════════


class TestPromotionCrud:
    def test_create_returns_the_full_promotion(self, client, admin_headers):
        p1 = _create_product(client, admin_headers)
        p2 = _create_product(client, admin_headers)
        promo = _create_promo(
            client, admin_headers,
            name="Weekend -20%", value="20",
            product_ids=[p1["id"], p2["id"]],
        )
        assert promo["promotion_type"] == "percentage"
        assert Decimal(promo["value"]) == Decimal("20")
        assert promo["is_active"] is True
        assert promo["product_count"] == 2
        assert {p["id"] for p in promo["products"]} == {p1["id"], p2["id"]}
        assert promo["product_ids"] == [p["id"] for p in promo["products"]]
        assert promo["idempotent_replay"] is False

    def test_get_and_list(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        promo = _create_promo(
            client, admin_headers, name="Alpha Sale", product_ids=[p["id"]]
        )
        fetched = client.get(
            f"/api/v1/promotions/{promo['id']}", headers=admin_headers
        )
        assert fetched.status_code == 200
        assert fetched.json()["name"] == "Alpha Sale"

        listing = client.get("/api/v1/promotions", headers=admin_headers)
        assert listing.status_code == 200
        body = listing.json()
        assert body["total"] >= 1
        assert any(item["id"] == promo["id"] for item in body["items"])

    def test_list_filters_by_name_and_active_flag(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        target = _create_promo(
            client, admin_headers, name="Ramadan Special",
            product_ids=[p["id"]],
        )
        other = _create_promo(
            client, admin_headers, name="Other Deal", value="10",
            is_active=False, product_ids=[_create_product(client, admin_headers)["id"]],
        )

        by_q = client.get(
            "/api/v1/promotions", params={"q": "Ramadan"},
            headers=admin_headers,
        ).json()
        assert [i["id"] for i in by_q["items"]] == [target["id"]]

        active = client.get(
            "/api/v1/promotions", params={"is_active": "true"},
            headers=admin_headers,
        ).json()
        ids = [i["id"] for i in active["items"]]
        assert target["id"] in ids and other["id"] not in ids

        inactive = client.get(
            "/api/v1/promotions", params={"is_active": "false"},
            headers=admin_headers,
        ).json()
        assert [i["id"] for i in inactive["items"]] == [other["id"]]

    def test_update_is_partial_and_replaces_membership(
        self, client, admin_headers
    ):
        p1 = _create_product(client, admin_headers)
        p2 = _create_product(client, admin_headers)
        promo = _create_promo(
            client, admin_headers, name="Old Name", value="20",
            product_ids=[p1["id"]],
        )

        renamed = client.put(
            f"/api/v1/promotions/{promo['id']}",
            json={"name": "New Name"},
            headers=admin_headers,
        )
        assert renamed.status_code == 200
        body = renamed.json()
        assert body["name"] == "New Name"
        assert Decimal(body["value"]) == Decimal("20")  # untouched
        assert body["product_count"] == 1  # untouched

        moved = client.put(
            f"/api/v1/promotions/{promo['id']}",
            json={"product_ids": [p2["id"]], "value": "15"},
            headers=admin_headers,
        )
        assert moved.status_code == 200
        body = moved.json()
        assert body["product_ids"] == [p2["id"]]
        assert Decimal(body["value"]) == Decimal("15")

    def test_get_missing_is_404_promotion_not_found(
        self, client, admin_headers
    ):
        resp = client.get(
            f"/api/v1/promotions/{uuid.uuid4()}", headers=admin_headers
        )
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "PROMOTION_NOT_FOUND"

    def test_toggle_flips_is_active(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        promo = _create_promo(
            client, admin_headers, product_ids=[p["id"]]
        )
        assert promo["is_active"] is True

        off = _toggle(client, admin_headers, promo["id"])
        assert off.status_code == 200
        assert off.json()["is_active"] is False

        on = _toggle(client, admin_headers, promo["id"])
        assert on.status_code == 200
        assert on.json()["is_active"] is True


# ══════════════════════════════════════════════════════════════════════
# 3. Validation rules
# ══════════════════════════════════════════════════════════════════════


class TestPromotionValidation:
    @pytest.mark.parametrize("bad", ["0", "101", "150"])
    def test_invalid_percentage_value_422(
        self, client, admin_headers, bad
    ):
        p = _create_product(client, admin_headers)
        resp = _create_promo_raw(
            client, admin_headers,
            _promo_payload(value=bad, product_ids=[p["id"]]),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "INVALID_PROMOTION_VALUE"

    def test_negative_fixed_price_is_422_by_schema(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        resp = _create_promo_raw(
            client, admin_headers,
            _promo_payload(
                promotion_type="fixed_price", value="-1",
                product_ids=[p["id"]],
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_multi_product_fixed_price_is_422(
        self, client, admin_headers
    ):
        p1 = _create_product(client, admin_headers)
        p2 = _create_product(client, admin_headers)
        resp = _create_promo_raw(
            client, admin_headers,
            _promo_payload(
                promotion_type="fixed_price", value="160",
                product_ids=[p1["id"], p2["id"]],
            ),
        )
        assert resp.status_code == 422
        assert (
            resp.json()["error"]["code"]
            == "MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED"
        )
        # nothing was written
        assert client.get(
            "/api/v1/promotions", headers=admin_headers
        ).json()["total"] == 0

    def test_unknown_product_is_422_and_leaves_no_partial_state(
        self, client, admin_headers
    ):
        real = _create_product(client, admin_headers)
        resp = _create_promo_raw(
            client, admin_headers,
            _promo_payload(
                product_ids=[real["id"], str(uuid.uuid4())],
                name="Atomic Check",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "UNKNOWN_PRODUCT"

        # ALL OR NOTHING: no promotion row, no membership row.
        assert client.get(
            "/api/v1/promotions", headers=admin_headers
        ).json()["total"] == 0
        detail = client.get(
            f"/api/v1/products/{real['id']}", headers=admin_headers
        ).json()
        assert detail["promotion"] is None

    @pytest.mark.parametrize(
        "payload_patch,expected_code",
        [
            ({"name": "   "}, "VALIDATION_ERROR"),
            ({"name": ""}, "VALIDATION_ERROR"),
            ({"promotion_type": "bogus"}, "VALIDATION_ERROR"),
            ({"product_ids": []}, "VALIDATION_ERROR"),
            ({"client_request_id": ""}, "VALIDATION_ERROR"),
        ],
    )
    def test_schema_rejections(
        self, client, admin_headers, payload_patch, expected_code
    ):
        payload = _promo_payload(**payload_patch)
        resp = _create_promo_raw(client, admin_headers, payload)
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == expected_code

    def test_duplicate_product_ids_collapse(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        promo = _create_promo(
            client, admin_headers, product_ids=[p["id"], p["id"]]
        )
        assert promo["product_count"] == 1


# ══════════════════════════════════════════════════════════════════════
# 4. Idempotency
# ══════════════════════════════════════════════════════════════════════


class TestPromotionIdempotency:
    def test_same_key_and_payload_replays(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        payload = _promo_payload(
            client_request_id="promo-key-1", name="Replay Test",
            value="25", product_ids=[p["id"]],
        )
        first = _create_promo_raw(client, admin_headers, payload)
        assert first.status_code == 201
        assert first.json()["idempotent_replay"] is False

        second = _create_promo_raw(client, admin_headers, payload)
        assert second.status_code == 201
        assert second.json()["idempotent_replay"] is True
        assert second.json()["id"] == first.json()["id"]
        assert client.get(
            "/api/v1/promotions", headers=admin_headers
        ).json()["total"] == 1

    def test_same_key_different_payload_is_409(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        payload = _promo_payload(
            client_request_id="promo-key-2", name="First",
            product_ids=[p["id"]],
        )
        assert _create_promo_raw(
            client, admin_headers, payload
        ).status_code == 201

        payload["name"] = "Changed"
        resp = _create_promo_raw(client, admin_headers, payload)
        assert resp.status_code == 409
        assert resp.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"
        assert client.get(
            "/api/v1/promotions", headers=admin_headers
        ).json()["total"] == 1


# ══════════════════════════════════════════════════════════════════════
# 5. Overlap rule — ONE ACTIVE promotion per product
# ══════════════════════════════════════════════════════════════════════


class TestPromotionOverlap:
    def test_second_active_promotion_on_same_product_is_409(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        first = _create_promo(
            client, admin_headers, name="First Claim",
            product_ids=[p["id"]],
        )
        resp = _create_promo_raw(
            client, admin_headers,
            _promo_payload(name="Rival", product_ids=[p["id"]]),
        )
        assert resp.status_code == 409
        body = resp.json()
        assert body["error"]["code"] == "PROMOTION_PRODUCT_CONFLICT"
        conflict = body["error"]["details"]["products"][0]
        assert conflict["product_id"] == p["id"]
        assert conflict["promotion_id"] == first["id"]

    def test_inactive_promotions_may_overlap(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        _create_promo(client, admin_headers, product_ids=[p["id"]])
        # inactive rival on the same product — allowed
        rival = _create_promo(
            client, admin_headers, name="Dormant", is_active=False,
            product_ids=[p["id"]],
        )
        assert rival["is_active"] is False

    def test_activating_a_conflicting_promotion_is_409(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        _create_promo(client, admin_headers, product_ids=[p["id"]])
        dormant = _create_promo(
            client, admin_headers, name="Dormant", is_active=False,
            product_ids=[p["id"]],
        )
        resp = _toggle(client, admin_headers, dormant["id"])
        assert resp.status_code == 409
        assert (
            resp.json()["error"]["code"] == "PROMOTION_PRODUCT_CONFLICT"
        )

    def test_deactivation_frees_the_product(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        first = _create_promo(
            client, admin_headers, product_ids=[p["id"]]
        )
        assert _toggle(
            client, admin_headers, first["id"]
        ).json()["is_active"] is False

        rival = _create_promo(
            client, admin_headers, name="Now Allowed",
            product_ids=[p["id"]],
        )
        assert rival["is_active"] is True

    def test_update_membership_into_an_active_conflict_is_409(
        self, client, admin_headers
    ):
        a = _create_product(client, admin_headers)
        b = _create_product(client, admin_headers)
        _create_promo(client, admin_headers, product_ids=[a["id"]])
        rival = _create_promo(
            client, admin_headers, name="Rival", is_active=False,
            product_ids=[b["id"]],
        )
        resp = client.put(
            f"/api/v1/promotions/{rival['id']}",
            json={"product_ids": [a["id"]], "is_active": True},
            headers=admin_headers,
        )
        assert resp.status_code == 409
        assert (
            resp.json()["error"]["code"] == "PROMOTION_PRODUCT_CONFLICT"
        )


# ══════════════════════════════════════════════════════════════════════
# 6. Price integration (checkout)
# ══════════════════════════════════════════════════════════════════════


class TestPromotionPriceIntegration:
    def test_percentage_promotion_prices_the_checkout(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        _create_promo(
            client, admin_headers, value="20", product_ids=[p["id"]]
        )
        sale = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(sale) == Decimal("160.000")
        assert Decimal(sale["total"]) == Decimal("160.000")

    def test_fixed_price_promotion_prices_the_checkout(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        _create_promo(
            client, admin_headers, promotion_type="fixed_price",
            value="160", product_ids=[p["id"]],
        )
        sale = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(sale) == Decimal("160.000")

    def test_multi_product_bulk_promotion(
        self, client, admin_headers
    ):
        p1 = _create_product(client, admin_headers, price="200.000")
        p2 = _create_product(client, admin_headers, price="350.000")
        p3 = _create_product(client, admin_headers, price="500.000")
        _create_promo(
            client, admin_headers, value="20",
            product_ids=[p1["id"], p2["id"], p3["id"]],
        )
        sale = _buy(
            client, admin_headers,
            [
                _line_item(p1["id"]),
                _line_item(p2["id"]),
                _line_item(p3["id"]),
            ],
        )
        prices = [_unit_price(sale, i) for i in range(3)]
        assert prices == [
            Decimal("160.000"),
            Decimal("280.000"),
            Decimal("400.000"),
        ]
        assert Decimal(sale["total"]) == Decimal("840.000")

    def test_inactive_promotion_charges_retail_then_toggle_activates(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="200.000")
        promo = _create_promo(
            client, admin_headers, is_active=False,
            product_ids=[p["id"]],
        )

        # inactive -> retail
        assert _unit_price(
            _sell_one(client, admin_headers, p["id"])
        ) == Decimal("200.000")

        # activate -> promotion price
        assert _toggle(
            client, admin_headers, promo["id"]
        ).json()["is_active"] is True
        assert _unit_price(
            _sell_one(client, admin_headers, p["id"])
        ) == Decimal("160.000")

        # deactivate -> retail again, and products.price NEVER changed
        assert _toggle(
            client, admin_headers, promo["id"]
        ).json()["is_active"] is False
        assert _unit_price(
            _sell_one(client, admin_headers, p["id"])
        ) == Decimal("200.000")
        assert _product_price(client, admin_headers, p["id"]) == Decimal(
            "200.000"
        )

    def test_original_price_is_never_written(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="200.000")
        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])
        _sell_one(client, admin_headers, p["id"])

        db.expire_all()
        from app.models.catalog import Product

        row = db.execute(
            select(Product).where(Product.id == uuid.UUID(p["id"]))
        ).scalar_one()
        assert Decimal(row.price) == Decimal("200.000")

    def test_historical_sale_lines_are_frozen(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="200.000")
        before = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(before) == Decimal("200.000")

        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])
        after = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(after) == Decimal("160.000")

        # the old line snapshot still carries the pre-promotion price
        db.expire_all()
        lines = (
            db.execute(
                select(SaleLine).where(
                    SaleLine.sale_id == uuid.UUID(before["id"])
                )
            )
            .scalars()
            .all()
        )
        assert len(lines) == 1
        assert Decimal(lines[0].unit_price) == Decimal("200.000")

    def test_wholesale_threshold_wins_at_or_above_min_qty(
        self, client, admin_headers
    ):
        # retail 100, 20% off -> promo 80; wholesale 70 from 5 units.
        p = _create_product(
            client, admin_headers, price="100.000",
            wholesale_price="70.000", wholesale_min_qty="5.000",
        )
        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])

        below = _sell_one(client, admin_headers, p["id"], "3")
        assert _unit_price(below) == Decimal("80.000")  # promotion wins

        at = _sell_one(client, admin_headers, p["id"], "5")
        assert _unit_price(at) == Decimal("70.000")  # wholesale wins

    def test_no_promotion_behaviour_is_unchanged(
        self, client, admin_headers
    ):
        # Phase 17 regression: wholesale applies with no promotion around.
        p = _create_product(
            client, admin_headers, price="100.000",
            wholesale_price="80.000", wholesale_min_qty="5.000",
        )
        assert _unit_price(
            _sell_one(client, admin_headers, p["id"], "3")
        ) == Decimal("100.000")
        assert _unit_price(
            _sell_one(client, admin_headers, p["id"], "5")
        ) == Decimal("80.000")

    def test_selling_unit_with_explicit_price_is_never_promoted(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        unit = client.post(
            f"/api/v1/products/{p['id']}/selling-units",
            json={
                "name": "Box",
                "unit_type": "piece",
                "multiplier": "10",
                "selling_price": "900.000",
            },
            headers=admin_headers,
        )
        assert unit.status_code == 201, unit.text
        unit_id = unit.json()["id"]

        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])
        sale = _buy(
            client, admin_headers,
            [_line_item(p["id"], selling_unit_id=unit_id)],
        )
        assert _unit_price(sale) == Decimal("900.000")

    def test_variant_with_explicit_price_is_never_promoted(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        variant = client.post(
            f"/api/v1/products/{p['id']}/variants",
            json={"name": "Blue", "price": "150.000", "quantity": "10"},
            headers=admin_headers,
        )
        assert variant.status_code == 201, variant.text

        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])
        sale = _buy(
            client, admin_headers,
            [_line_item(p["id"], variant_id=variant.json()["id"])],
        )
        assert _unit_price(sale) == Decimal("150.000")

    def test_awkward_rounding_is_half_up(self, client, admin_headers):
        p = _create_product(client, admin_headers, price="10.001")
        _create_promo(
            client, admin_headers, value="50", product_ids=[p["id"]]
        )
        sale = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(sale) == Decimal("5.001")

    def test_fixed_price_above_retail_charges_retail(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        _create_promo(
            client, admin_headers, promotion_type="fixed_price",
            value="300", product_ids=[p["id"]],
        )
        sale = _sell_one(client, admin_headers, p["id"])
        assert _unit_price(sale) == Decimal("200.000")


# ══════════════════════════════════════════════════════════════════════
# 7. Product responses carry the active promotion
# ══════════════════════════════════════════════════════════════════════


class TestProductResponsePromotion:
    def test_product_detail_carries_the_promotion(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="200.000")
        promo = _create_promo(
            client, admin_headers, name="Flash -20%", value="20",
            product_ids=[p["id"]],
        )
        body = client.get(
            f"/api/v1/products/{p['id']}", headers=admin_headers
        ).json()
        assert Decimal(body["price"]) == Decimal("200.000")  # retail intact
        promotion = body["promotion"]
        assert promotion is not None
        assert promotion["id"] == promo["id"]
        assert promotion["name"] == "Flash -20%"
        assert promotion["promotion_type"] == "percentage"
        assert Decimal(promotion["value"]) == Decimal("20")
        # server-computed effective price — clients never re-derive it
        assert Decimal(promotion["price"]) == Decimal("160.000")

    def test_list_and_search_expose_the_promotion(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, price="350.000")
        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])

        listed = client.get(
            "/api/v1/products", params={"page_size": 100},
            headers=admin_headers,
        ).json()
        hit = next(i for i in listed["items"] if i["id"] == p["id"])
        assert Decimal(hit["promotion"]["price"]) == Decimal("280.000")

        found = client.get(
            "/api/v1/products/search", params={"q": p["barcode"]},
            headers=admin_headers,
        ).json()
        assert Decimal(found["items"][0]["promotion"]["price"]) == Decimal(
            "280.000"
        )

    def test_promotion_block_is_null_when_inactive_or_absent(
        self, client, admin_headers
    ):
        plain = _create_product(client, admin_headers, price="200.000")
        body = client.get(
            f"/api/v1/products/{plain['id']}", headers=admin_headers
        ).json()
        assert body["promotion"] is None

        promo = _create_promo(
            client, admin_headers, product_ids=[plain["id"]], is_active=False
        )
        body = client.get(
            f"/api/v1/products/{plain['id']}", headers=admin_headers
        ).json()
        assert body["promotion"] is None

        _toggle(client, admin_headers, promo["id"])
        body = client.get(
            f"/api/v1/products/{plain['id']}", headers=admin_headers
        ).json()
        assert body["promotion"] is not None


# ══════════════════════════════════════════════════════════════════════
# 8. Permissions
# ══════════════════════════════════════════════════════════════════════


class TestPromotionPermissions:
    def test_requires_authentication(self, client):
        assert client.get("/api/v1/promotions").status_code == 401
        assert (
            client.post(
                "/api/v1/promotions", json=_promo_payload()
            ).status_code
            == 401
        )

    def test_cashier_is_denied_management(
        self, client, cashier_headers
    ):
        assert (
            client.get("/api/v1/promotions", headers=cashier_headers).status_code
            == 403
        )
        resp = client.post(
            "/api/v1/promotions",
            json=_promo_payload(product_ids=[str(uuid.uuid4())]),
            headers=cashier_headers,
        )
        assert resp.status_code == 403

    def test_roleless_user_is_denied(self, client, guest_headers):
        assert (
            client.get("/api/v1/promotions", headers=guest_headers).status_code
            == 403
        )

    def test_cashier_still_reads_promotion_prices_through_products(
        self, client, admin_headers, cashier_headers
    ):
        # The POS keeps working for a cashier: promotion prices ride on
        # the product response, which requires only product_view.
        p = _create_product(client, admin_headers, price="200.000")
        _create_promo(client, admin_headers, value="20", product_ids=[p["id"]])
        body = client.get(
            f"/api/v1/products/{p['id']}", headers=cashier_headers
        )
        assert body.status_code == 200
        assert Decimal(body.json()["promotion"]["price"]) == Decimal("160.000")

    def test_manager_can_manage_promotions(
        self, client, admin_headers, manager_headers
    ):
        p = _create_product(client, admin_headers)
        promo = _create_promo(
            client, manager_headers, product_ids=[p["id"]]
        )
        assert (
            client.get(
                "/api/v1/promotions", headers=manager_headers
            ).status_code
            == 200
        )
        assert _toggle(client, manager_headers, promo["id"]).status_code == 200
