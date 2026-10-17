"""Reward-redesign tests — configurable rate, milestone, rule R.

Covers the redesign where:

- the earning rate is merchant-configured as DZD per point
  (``amount_per_point``, stored inverted as ``points_rate``);
- one reward costs exactly the configured milestone
  (``min_reward_points``, default 100) and drives the milestone view
  (``available_rewards`` / ``remaining_points``);
- points on a SALE qualify on
  :func:`app.domain.loyalty.sale_points_qualifying_amount` — the
  settled part of the amount due PLUS the reward discount, capped at
  the sale total, and 0 when the sale settles nothing — while cashback
  keeps :func:`app.domain.loyalty.settled_amount`;
- a reward is eligible when the balance HOLDS the milestone or THIS
  SALE's own earning reaches it, which is exactly how a zero-point
  customer redeems on a first purchase;
- the checkout preview/revalidation evaluate affordability on the real
  ``paid`` amount, so a partial or credit sale that cannot reach the
  milestone is refused BEFORE any mutation.

SQLite fixture mirrors test_pos_sale_loyalty.py; PG correctness of
``FOR UPDATE`` is gated by tests/integration.
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
from app.domain.loyalty import (
    LoyaltyMathError,
    sale_points_qualifying_amount,
)
from app.main import app
from app.models.loyalty import LoyaltyAccount
from app.models.sale import Sale
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.services.auth import AuthService
from app.services.loyalty import LoyaltyEngine, LoyaltySettingsService

# ── Fixtures (same recipe as test_pos_sale_loyalty.py) ───────────────────


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


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


_seq = {"n": 0}


def _create_product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Earn Rule Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"ERL{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str = "Earn Rule Customer") -> dict:
    resp = client.post(
        "/api/v1/customers",
        json={"name": name, "phone": None},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale_payload(product_id: str, **overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": [
            {
                "product_id": product_id,
                "quantity": "1.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            }
        ],
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "100.000",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_sale(client, headers, payload: dict):
    return client.post("/api/v1/sales", json=payload, headers=headers)


def _seed_points(session, customer_id, points: int) -> None:
    engine = LoyaltyEngine(session)
    with engine.transaction():
        engine.post(
            customer_id=uuid.UUID(str(customer_id)),
            event_type="adjustment",
            source_event_key=f"seed:{uuid.uuid4().hex}",
            points_delta=Decimal(points),
        )
    session.expire_all()


def _account(session, customer_id) -> LoyaltyAccount | None:
    session.expire_all()
    return session.scalars(
        select(LoyaltyAccount).where(
            LoyaltyAccount.customer_id == uuid.UUID(str(customer_id))
        )
    ).first()


def _sale(session, sale_id) -> Sale:
    session.expire_all()
    return session.get(Sale, uuid.UUID(str(sale_id)))


def _update_settings(session, **fields) -> None:
    LoyaltySettingsService(session).update(
        LoyaltySettingsUpdateRequest(**fields),
        actor_id=None,
    )
    session.expire_all()


def _money(resp_json: dict, key: str) -> Decimal:
    return Decimal(str(resp_json[key]))


# ── 1. Domain: sale_points_qualifying_amount (rule R) ────────────────────


class TestSalePointsQualifyingAmount:
    def test_fully_paid_unredeemed_earns_on_the_settled_due(self):
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("1000"),
            amount_due=Decimal("1000"),
            redeem_value=Decimal("0"),
        ) == Decimal("1000.000")

    def test_fully_paid_redeemed_cart_earns_exactly_like_the_unredeemed(
        self,
    ):
        # 1000 cart, 20% reward -> due 800, paid 800:
        # min(800, 800) + 200 = 1000 == the cart total.
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("800"),
            amount_due=Decimal("800"),
            redeem_value=Decimal("200"),
        ) == Decimal("1000.000")

    def test_change_never_earns(self):
        # 1000 due, 1500 tendered: only min(1500, 1000) qualifies.
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("1500"),
            amount_due=Decimal("1000"),
            redeem_value=Decimal("0"),
        ) == Decimal("1000.000")

    def test_partial_settlement_qualifies_only_on_what_was_paid(self):
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("400"),
            amount_due=Decimal("1000"),
            redeem_value=Decimal("0"),
        ) == Decimal("400.000")

    def test_partial_settlement_plus_reward_is_capped_at_the_total(self):
        # paid 400 + reward 200 = 600 < 1000 -> 600.
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("400"),
            amount_due=Decimal("800"),
            redeem_value=Decimal("200"),
        ) == Decimal("600.000")

    def test_credit_settlement_earns_nothing(self):
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("0"),
            amount_due=Decimal("1000"),
            redeem_value=Decimal("0"),
        ) == Decimal("0.000")

    def test_fully_redeemed_cart_settles_nothing_and_earns_nothing(self):
        # 100% reward (cap parked at 100): due 0 -> nothing settled.
        assert sale_points_qualifying_amount(
            total=Decimal("1000"),
            paid=Decimal("0"),
            amount_due=Decimal("0"),
            redeem_value=Decimal("1000"),
        ) == Decimal("0.000")

    def test_negative_inputs_raise(self):
        with pytest.raises(LoyaltyMathError):
            sale_points_qualifying_amount(
                total=Decimal("-1"),
                paid=Decimal("0"),
                amount_due=Decimal("0"),
                redeem_value=Decimal("0"),
            )
        with pytest.raises(LoyaltyMathError):
            sale_points_qualifying_amount(
                total=Decimal("10"),
                paid=Decimal("-1"),
                amount_due=Decimal("10"),
                redeem_value=Decimal("0"),
            )


# ── 2. Settings API: amount_per_point + min_reward_points ────────────────


class TestSettingsEarningRate:
    def test_amount_per_point_round_trips(self, client, admin_headers):
        resp = client.put(
            "/api/v1/loyalty/settings",
            json={"amount_per_point": "250"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        # 250 DA per point -> rate 1/250 = 0.004, reported back as 250.
        assert _money(body, "amount_per_point") == Decimal("250.000")
        assert _money(body, "points_rate") == Decimal("0.004000")

        resp = client.get("/api/v1/loyalty/settings", headers=admin_headers)
        assert _money(resp.json(), "amount_per_point") == Decimal("250.000")

    def test_amount_per_point_takes_precedence_over_stale_points_rate(
        self, client, admin_headers
    ):
        resp = client.put(
            "/api/v1/loyalty/settings",
            # A stale client rate (50 DA/pt) next to the fresh alias.
            json={"points_rate": "0.02", "amount_per_point": "250"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert _money(body, "amount_per_point") == Decimal("250.000")
        assert _money(body, "points_rate") == Decimal("0.004000")

    def test_rate_of_zero_parks_earning_and_reports_zero(
        self, client, admin_headers
    ):
        resp = client.put(
            "/api/v1/loyalty/settings",
            json={"points_rate": "0"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert _money(resp.json(), "amount_per_point") == Decimal("0")

    def test_bad_amount_per_point_rejected(self, client, admin_headers):
        for bad in ("0", "-5", "0.0005", "1000001"):
            resp = client.put(
                "/api/v1/loyalty/settings",
                json={"amount_per_point": bad},
                headers=admin_headers,
            )
            assert resp.status_code == 422, (bad, resp.text)


class TestSettingsMilestone:
    def test_default_is_100(self, client, admin_headers):
        resp = client.get("/api/v1/loyalty/settings", headers=admin_headers)
        assert resp.json()["min_reward_points"] == "100"

    def test_update_and_persist(self, client, admin_headers):
        resp = client.put(
            "/api/v1/loyalty/settings",
            json={"min_reward_points": 250},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["min_reward_points"] == "250"
        resp = client.get("/api/v1/loyalty/settings", headers=admin_headers)
        assert resp.json()["min_reward_points"] == "250"

    @pytest.mark.parametrize("bad", ["0", "-1", "10.5", "1000001"])
    def test_invalid_milestone_rejected(self, client, admin_headers, bad):
        resp = client.put(
            "/api/v1/loyalty/settings",
            json={"min_reward_points": bad},
            headers=admin_headers,
        )
        assert resp.status_code == 422, (bad, resp.text)


# ── 3. Earning on a sale at the configured rate ──────────────────────────


class TestSaleEarningAtConfiguredRate:
    def test_default_rate_100_da_per_point(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="1000.000",
            customer_id=c["id"],
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert _money(resp.json(), "loyalty_points_earned") == Decimal("10")

    def test_custom_rate_doubles_the_earn(self, client, admin_headers, db):
        _update_settings(db, amount_per_point="50")
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="1000.000",
            customer_id=c["id"],
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        # 1000 / 50 = 20 points.
        assert _money(resp.json(), "loyalty_points_earned") == Decimal("20")

    def test_credit_earns_nothing(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0",
            customer_id=c["id"],
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert _money(resp.json(), "loyalty_points_earned") == Decimal("0")

    def test_change_never_earns(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="1500.000",
            customer_id=c["id"],
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        # min(1500 tendered, 1000 due) -> 10 points, change does not earn.
        assert _money(resp.json(), "loyalty_points_earned") == Decimal("10")
        assert _money(resp.json(), "change") == Decimal("500.000")


# ── 4. Milestone arithmetic + redemption cost ────────────────────────────


class TestMilestoneAndRedemptionCost:
    def test_balance_splits_by_the_configured_milestone(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=40)
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 100)
        resp = client.get(
            f"/api/v1/customers/{c['id']}/loyalty", headers=admin_headers
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["points_balance"] == "100"
        assert body["available_rewards"] == 2  # floor(100 / 40)
        assert body["remaining_points"] == "20"  # 100 % 40
        assert body["min_reward_points"] == "40"

    def test_one_redemption_costs_exactly_the_milestone(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=40)
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 100)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "5.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="450.000",
            customer_id=c["id"],
            loyalty_reward_percent=10,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert _money(body, "loyalty_points_redeemed") == Decimal("40")
        assert _money(body, "loyalty_redeemed_value") == Decimal("50.000")
        assert _money(body, "amount_due") == Decimal("450.000")
        # Rule R: min(450, 450) + 50 = 500 == total -> 5 points.
        assert _money(body, "loyalty_points_earned") == Decimal("5")
        assert _account(db, c["id"]).points_balance == Decimal(65)


# ── 5. First-purchase redemption (zero-point customer) ───────────────────


class TestFirstPurchaseRedemption:
    def test_zero_point_customer_redeems_when_this_sale_reaches_the_milestone(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=10)
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        assert _account(db, c["id"]) is None  # never earned before

        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="800.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert _money(body, "loyalty_points_redeemed") == Decimal("10")
        assert _money(body, "loyalty_redeemed_value") == Decimal("200.000")
        # Rule R: min(800, 800) + 200 = 1000 == total -> 10 points, and
        # 10 >= the 10-point milestone held the reward in the first place.
        assert _money(body, "loyalty_points_earned") == Decimal("10")
        assert _account(db, c["id"]).points_balance == Decimal(0)

    def test_partial_payment_that_cannot_reach_the_milestone_is_refused(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=10)
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)

        # paid 400: basis = min(400, 800) + 200 = 600 -> 6 < 10.
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="400.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert "no reward available" in err["message"]
        assert "points_balance" in err["details"]
        # Refused BEFORE any mutation: no account row, no ledger residue.
        assert _account(db, c["id"]) is None

    def test_credit_redemption_is_refused_and_leaves_no_residue(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=10)
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert "no reward available" in resp.json()["error"]["message"]
        assert _account(db, c["id"]) is None


# ── 6. Preview: payment-aware affordability ──────────────────────────────


class TestPreviewPaymentAwareness:
    def test_preview_without_paid_assumes_full_settlement(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=10)
        c = _create_customer(client, admin_headers)
        resp = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 20,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["reward_eligible"] is True
        # Assume settles at 800: min(800, 800) + 200 = 1000 -> 10.
        assert _money(body, "points_earned") == Decimal("10")
        assert _money(body, "points_after_sale") == Decimal("10")

    def test_preview_with_partial_paid_is_refused(self, client, admin_headers, db):
        _update_settings(db, min_reward_points=10)
        c = _create_customer(client, admin_headers)
        resp = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 20,
                "paid": "400",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
        assert "no reward available" in resp.json()["error"]["message"]

    def test_preview_with_credit_paid_is_refused(self, client, admin_headers, db):
        _update_settings(db, min_reward_points=10)
        c = _create_customer(client, admin_headers)
        resp = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 20,
                "paid": "0",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text

    def test_preview_earned_tracks_the_real_paid_amount(
        self, client, admin_headers, db
    ):
        c = _create_customer(client, admin_headers)
        resp = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 0,
                "paid": "600",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert _money(resp.json(), "points_earned") == Decimal("6")
        assert _money(resp.json(), "cashback_earned") == Decimal("0.000")

    def test_preview_reports_the_milestone_view(self, client, admin_headers, db):
        _update_settings(db, min_reward_points=40)
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 100)
        resp = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 0,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["available_rewards"] == 2
        assert body["remaining_points"] == "20"
        assert body["min_reward_points"] == "40"


# ── 7. Preview/revalidate agreement on the sale path ─────────────────────


class TestSalePreviewRevalidateAgreement:
    def test_preview_endpoint_and_sale_posting_agree(
        self, client, admin_headers, db
    ):
        _update_settings(db, min_reward_points=10)
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)

        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "10.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            paid="800.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        preview = client.post(
            "/api/v1/loyalty/preview",
            json={
                "customer_id": c["id"],
                "gross_total": "1000",
                "reward_percent": 20,
                "paid": "800",
            },
            headers=admin_headers,
        )
        assert preview.status_code == 200, preview.text
        pbody = preview.json()
        assert _money(pbody, "reward_discount") == Decimal("200")
        assert _money(pbody, "amount_due") == Decimal("800")
        assert _money(pbody, "points_earned") == Decimal("10")

        sale = _post_sale(client, admin_headers, payload)
        assert sale.status_code == 201, sale.text
        sbody = sale.json()
        assert _money(sbody, "loyalty_redeemed_value") == _money(
            pbody, "reward_discount"
        )
        assert _money(sbody, "amount_due") == _money(pbody, "amount_due")
        assert _money(sbody, "loyalty_points_earned") == _money(
            pbody, "points_earned"
        )
        assert _sale(db, sbody["id"]).loyalty_points_redeemed == Decimal("10")
