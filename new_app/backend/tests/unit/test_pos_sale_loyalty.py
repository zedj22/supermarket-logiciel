"""Phase C tests — loyalty integration in POS checkout (create_sale).

Covers the approved Phase 1 rules where they meet the sale transaction:

- reward eligibility (an available reward, the owner's cap, points
  enabled) enforced SERVER-side under the account lock; the client
  submits a percent only, never points or value; ONE reward always
  costs exactly 100 points and the server derives the DA discount;
- amount_due = total - reward discount drives every payment rule
  (cash/card/partial/credit), while sale.total stays the GROSS price;
- earn qualifies on min(paid, amount_due), floored; a disabled rule is
  exactly zero; a zero earn writes 0 columns but no ledger entry;
- ledger keys ``redeem:{sale.id}`` / ``sale_earn:{sale.id}`` post in the
  SAME transaction as the sale (rollback leaves zero residue);
- pre-loyalty / facturation sales keep all five loyalty columns NULL;
- idempotent replay returns the original sale and never double-posts.

SQLite fixture mirrors test_pos_sale.py (StaticPool in-memory shared by
service + API sessions); production correctness of FOR UPDATE / SAVEPOINT
is asserted by the PG concurrency gate in tests/integration.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import ValidationError
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.loyalty import LoyaltyAccount, LoyaltyLedgerEntry, LoyaltySetting
from app.models.party import Customer
from app.models.sale import Sale
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.schemas.sale import CreateSaleRequest, SaleLineRequest
from app.services.auth import AuthService
from app.services.loyalty import LoyaltyEngine, LoyaltySettingsService, RewardDecision
from app.services.sale import SaleService

# ── Fixtures (Phase B recipe engine — real BEGIN/SAVEPOINT) ─────────────


@pytest.fixture()
def engine():
    # Same recipe as test_pos_sale.py: per-test in-memory SQLite with a
    # StaticPool connection shared by the service session and the
    # per-request API sessions.
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


_barcode_seq = {"n": 0}


def _create_product(client, headers, **overrides) -> dict:
    _barcode_seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Loyalty Product {_barcode_seq['n']}"),
        "barcode": overrides.pop("barcode", f"LOY{_barcode_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str = "Loyal Customer") -> dict:
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


def _seed_points(session, customer_id, points: int, key: str | None = None) -> None:
    engine = LoyaltyEngine(session)
    with engine.transaction():
        engine.post(
            customer_id=uuid.UUID(str(customer_id)),
            event_type="adjustment",
            source_event_key=key or f"seed:{uuid.uuid4().hex}",
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


def _ledger_rows(session, sale_id) -> list[LoyaltyLedgerEntry]:
    session.expire_all()
    return list(
        session.scalars(
            select(LoyaltyLedgerEntry).where(
                LoyaltyLedgerEntry.sale_id == uuid.UUID(str(sale_id))
            )
        )
    )


def _update_settings(session, **fields) -> None:
    LoyaltySettingsService(session).update(
        LoyaltySettingsUpdateRequest(**fields),
        actor_id=None,
    )
    session.expire_all()


def _money(resp_json: dict, key: str) -> Decimal:
    return Decimal(str(resp_json[key]))


# ── Reward + earn happy paths ───────────────────────────────────────────


class TestRewardSale:
    def test_reward_reduces_amount_due_and_posts_both_entries(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

        # 10 x 100 = 1000 gross; ONE reward at 20% (the default cap)
        # -> 200.000 DA off -> due 800, cost is always 100 points.
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

        # Gross stays 1000; payable is 800; response carries the summary.
        assert _money(body, "total") == Decimal("1000.000")
        assert _money(body, "amount_due") == Decimal("800.000")
        assert _money(body, "loyalty_redeemed_value") == Decimal("200.000")
        assert _money(body, "loyalty_points_redeemed") == Decimal("100")
        assert _money(body, "paid") == Decimal("800.000")
        assert _money(body, "change") == Decimal("0.000")
        assert _money(body, "debt") == Decimal("0.000")
        # Earn on min(paid, due) = 800 x 0.01 -> floor -> 8 points.
        assert _money(body, "loyalty_points_earned") == Decimal("8")
        assert _money(body, "loyalty_cashback_earned") == Decimal("0.000")

        # Sale row mirrors the response (same transaction, same numbers).
        sale = _sale(db, body["id"])
        assert sale.amount_due == Decimal("800.000")
        assert sale.loyalty_points_redeemed == Decimal("100")
        assert sale.loyalty_redeemed_value == Decimal("200.000")
        assert sale.loyalty_points_earned == Decimal("8")
        assert sale.total == 1000.0  # GROSS untouched

        # Ledger: one redeem debit + one earn credit; balances reconcile.
        rows = _ledger_rows(db, body["id"])
        by_type = {r.event_type: r for r in rows}
        assert set(by_type) == {"redeem", "sale_earn"}
        assert by_type["redeem"].points_delta == Decimal("-100")
        assert by_type["sale_earn"].points_delta == Decimal("8")
        assert by_type["redeem"].source_event_key == f"redeem:{body['id']}"
        # The note records percent -> discount provenance.
        assert "reward 20%: discount 200.000 DA" in by_type["redeem"].note
        assert by_type["sale_earn"].source_event_key == f"sale_earn:{body['id']}"

        account = _account(db, c["id"])
        assert account.points_balance == Decimal("408")  # 500 - 100 + 8
        assert LoyaltyEngine(db).reconcile_account(
            uuid.UUID(str(c["id"]))
        ).points == Decimal("408")

    def test_earn_only_sale_no_reward(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
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
        body = resp.json()

        assert _money(body, "amount_due") == Decimal("1000.000")
        assert _money(body, "loyalty_points_redeemed") == Decimal("0")
        assert _money(body, "loyalty_redeemed_value") == Decimal("0.000")
        assert _money(body, "loyalty_points_earned") == Decimal("10")

        rows = _ledger_rows(db, body["id"])
        assert [r.event_type for r in rows] == ["sale_earn"]
        assert _account(db, c["id"]).points_balance == Decimal("10")

    def test_zero_earn_writes_zero_columns_but_no_entry(
        self, client, admin_headers, db
    ):
        # 5 DA x 0.01 = 0.05 -> floor 0: columns record "loyalty sale that
        # earned zero" (0), never NULL, and no ledger row is appended.
        p = _create_product(client, admin_headers, price="5.000", quantity="10.000")
        c = _create_customer(client, admin_headers)

        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "1.000",
                    "unit_price": "5.000",
                    "line_discount": "0.000",
                }
            ],
            paid="5.000",
            customer_id=c["id"],
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()

        assert _money(body, "loyalty_points_earned") == Decimal("0")
        assert _money(body, "loyalty_cashback_earned") == Decimal("0.000")
        assert _ledger_rows(db, body["id"]) == []
        assert _account(db, c["id"]) is None  # nothing was ever posted

    def test_anonymous_sale_writes_nothing_loyalty(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="10.000")
        payload = _sale_payload(p["id"], paid="100.000")
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # amount_due + redeemed always written; earned stays NULL w/o customer.
        assert _money(body, "amount_due") == Decimal("100.000")
        assert _money(body, "loyalty_points_redeemed") == Decimal("0")
        assert _money(body, "loyalty_redeemed_value") == Decimal("0.000")
        assert body["loyalty_points_earned"] is None
        assert body["loyalty_cashback_earned"] is None

        assert db.scalar(select(func.count()).select_from(LoyaltyAccount)) == 0
        assert (
            db.scalar(select(func.count()).select_from(LoyaltyLedgerEntry)) == 0
        )
        # No loyalty-relevant event happened => singleton never created.
        assert db.scalar(select(func.count()).select_from(LoyaltySetting)) == 0

        sale = _sale(db, body["id"])
        assert sale.loyalty_points_earned is None
        assert sale.loyalty_cashback_earned is None
        assert sale.amount_due is not None
        assert sale.amount_due == Decimal("100.000")

    def test_idempotent_replay_never_double_posts(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 200)

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
            paid="400.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        first = _post_sale(client, admin_headers, payload)
        assert first.status_code == 201, first.text
        second = _post_sale(client, admin_headers, payload)
        assert second.status_code == 201, second.text

        a, b = first.json(), second.json()
        assert a["id"] == b["id"]
        assert a["idempotent_replay"] is False
        assert b["idempotent_replay"] is True
        # Original numbers on replay — same sale, no second deduction.
        assert _money(b, "amount_due") == _money(a, "amount_due")
        assert _money(b, "loyalty_points_redeemed") == Decimal("100")

        assert len(_ledger_rows(db, a["id"])) == 2  # redeem + earn once
        # 200 - 100 + earn(min(400, 400)=400 -> 4) = 104
        assert _account(db, c["id"]).points_balance == Decimal("104")


# ── Payment rules against amount_due ────────────────────────────────────


class TestRewardPaymentRules:
    def test_cash_below_amount_due_rejected(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

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
            paid="800.000",  # due is 900 after a 10% reward on 1000
            customer_id=c["id"],
            loyalty_reward_percent=10,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text

    def test_partial_debt_uses_amount_due_not_total(
        self, client, admin_headers, db
    ):
        # KEY regression: debt must derive from amount_due, so a partial
        # sale discounted by a reward cannot report total - paid.
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

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
            payment_method="partial",
            paid="400.000",  # due 900 -> debt 500 (NOT 600)
            customer_id=c["id"],
            loyalty_reward_percent=10,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert _money(body, "amount_due") == Decimal("900.000")
        assert _money(body, "debt") == Decimal("500.000")

        sale = _sale(db, body["id"])
        assert sale.amount_due == Decimal("900.000")
        assert sale.paid == 400.0

        customer = db.get(Customer, uuid.UUID(str(c["id"])))
        # debt 500 (not 600) landed on the customer balance.
        assert Decimal(str(customer.balance)) == Decimal("500.000")

    def test_reward_covering_full_total_tenders_zero(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 1000)
        # Owner allows 100%: ONE reward can cover the whole cart.
        _update_settings(db, max_reward_discount_percent=Decimal("100"))

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
            paid="0.000",
            customer_id=c["id"],
            loyalty_reward_percent=100,  # discount 1000 = full total
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert _money(body, "amount_due") == Decimal("0.000")
        assert _money(body, "debt") == Decimal("0.000")
        assert _money(body, "change") == Decimal("0.000")
        assert _money(body, "paid") == Decimal("0.000")
        # ONE reward cost exactly 100 points, not 1000.
        assert _money(body, "loyalty_points_redeemed") == Decimal("100")
        # earn qualifies on min(0, 0) = 0 -> zero columns, no earn entry.
        assert _money(body, "loyalty_points_earned") == Decimal("0")
        rows = _ledger_rows(db, body["id"])
        assert [r.event_type for r in rows] == ["redeem"]
        assert _account(db, c["id"]).points_balance == Decimal("900")

    @pytest.mark.parametrize("method", ["credit", "partial"])
    def test_zero_amount_credit_or_partial_rejected(
        self, client, admin_headers, db, method
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 1000)
        _update_settings(db, max_reward_discount_percent=Decimal("100"))

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
            payment_method=method,
            paid="0.000",
            customer_id=c["id"],
            loyalty_reward_percent=100,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert db.scalar(select(func.count()).select_from(Sale)) == 0
        # nothing leaked: balance untouched (seed only), no sale-linked rows
        account = _account(db, c["id"])
        assert account is None or account.points_balance == Decimal("1000")
        sale_linked = db.scalar(
            select(func.count())
            .select_from(LoyaltyLedgerEntry)
            .where(LoyaltyLedgerEntry.sale_id.is_not(None))
        )
        assert sale_linked == 0

    def test_credit_sale_debt_equals_amount_due(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

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
            paid="0.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        # debt = amount_due = 800 (gross 1000 minus the 200 reward);
        # credit earns nothing (paid is 0).
        assert _money(body, "debt") == Decimal("800.000")
        assert _money(body, "loyalty_points_earned") == Decimal("0")
        rows = _ledger_rows(db, body["id"])
        assert [r.event_type for r in rows] == ["redeem"]


# ── Server-side eligibility (percent only from client) ──────────────────


class TestRewardEligibility:
    def test_no_reward_available_rejected(self, client, admin_headers, db):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 50)  # below the 100-point milestone

        payload = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=20
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert db.scalar(select(func.count()).select_from(Sale)) == 0

    def test_percent_above_owner_cap_rejected(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 5000)  # default cap is 20%

        payload = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=25
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert "exceeds the owner maximum" in resp.json()["error"]["message"]
        assert db.scalar(select(func.count()).select_from(Sale)) == 0

    def test_owner_cap_selectable_boundary(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 5000)
        _update_settings(db, max_reward_discount_percent=Decimal("50"))

        too_much = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=60
        )  # cap = 50
        assert (
            _post_sale(client, admin_headers, too_much).status_code == 422
        )

        ok = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=50
        )
        resp = _post_sale(client, admin_headers, ok)
        assert resp.status_code == 201, resp.text
        assert _money(resp.json(), "amount_due") == Decimal("50.000")
        assert _money(resp.json(), "loyalty_points_redeemed") == Decimal("100")

    def test_parked_cap_rejects_any_reward(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)
        _update_settings(db, max_reward_discount_percent=Decimal("0"))

        below = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=10
        )
        assert _post_sale(client, admin_headers, below).status_code == 422

        # A plain sale still works while redemption is parked.
        ok = _sale_payload(p["id"], customer_id=c["id"], paid="100.000")
        assert _post_sale(client, admin_headers, ok).status_code == 201

    def test_disabled_points_rejects_reward(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)
        _update_settings(db, points_enabled=False)

        payload = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=10
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text

        # A plain sale still works; earn is exactly zero while disabled.
        plain = _sale_payload(p["id"], customer_id=c["id"], paid="100.000")
        resp = _post_sale(client, admin_headers, plain)
        assert resp.status_code == 201, resp.text
        assert _money(resp.json(), "loyalty_points_earned") == Decimal("0")
        assert _ledger_rows(db, resp.json()["id"]) == []

    def test_reward_without_customer_rejected(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, price="100.000")
        payload = _sale_payload(
            p["id"], loyalty_reward_percent=10  # no customer_id
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert "customer_id" in resp.json()["error"]["message"]

    @pytest.mark.parametrize("percent", [-5, 101])
    def test_out_of_range_percent_rejected_by_schema(
        self, client, admin_headers, db, percent
    ):
        p = _create_product(client, admin_headers, price="100.000")
        c = _create_customer(client, admin_headers)
        payload = _sale_payload(
            p["id"], customer_id=c["id"], loyalty_reward_percent=percent
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert db.scalar(select(func.count()).select_from(Sale)) == 0


# ── In-transaction revalidation (drift) ─────────────────────────────────


class TestInTransactionRevalidation:
    def test_preview_vs_locked_state_drift_aborts_before_mutation(
        self, client, admin_headers, db, monkeypatch
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="1000.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

        # Simulate a STALE pre-tx preview: the preview reports a bigger
        # discount than the authoritative locked revalidation computes.
        # The in-tx equality check must abort the sale with zero residue
        # and tell the cashier to retry.
        original = LoyaltyEngine.preview_reward

        def _stale(self, **kwargs):
            decision = original(self, **kwargs)
            return RewardDecision(
                decision.points_cost,
                decision.percent,
                decision.discount + Decimal("100"),
            )

        monkeypatch.setattr(LoyaltyEngine, "preview_reward", _stale)

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
            paid="900.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        assert "retry" in resp.json()["error"]["message"].lower()

        # Zero residue: no sale, no stock movement, balance untouched.
        assert db.scalar(select(func.count()).select_from(Sale)) == 0
        assert _account(db, c["id"]).points_balance == Decimal("500")
        stock = db.get(Product, uuid.UUID(str(p["id"]))).quantity
        assert stock == 1000.0

    def test_failed_sale_rolls_back_loyalty_posts(
        self, client, admin_headers, db, monkeypatch
    ):
        # Stock failure AFTER revalidation but BEFORE any post: the whole
        # transaction rolls back, so the ledger must stay empty.
        p = _create_product(client, admin_headers, price="100.000", quantity="10.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

        original_decrement = SaleService._decrement_stock

        def _fail(self, line):
            raise RuntimeError("forced failure after loyalty revalidation")

        monkeypatch.setattr(SaleService, "_decrement_stock", _fail)

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
            paid="400.000",
            customer_id=c["id"],
            loyalty_reward_percent=20,
        )
        with pytest.raises(RuntimeError):
            SaleService(db).create_sale(CreateSaleRequest(**payload), user=None)
        monkeypatch.setattr(SaleService, "_decrement_stock", original_decrement)

        db.rollback()
        db.expire_all()
        assert db.scalar(select(func.count()).select_from(Sale)) == 0
        sale_linked = db.scalar(
            select(func.count())
            .select_from(LoyaltyLedgerEntry)
            .where(LoyaltyLedgerEntry.sale_id.is_not(None))
        )
        assert sale_linked == 0  # seed entry predates the failed sale
        account = _account(db, c["id"])
        assert account is None or account.points_balance == Decimal("500")


# ── Facturation isolation (enable_loyalty=False) ────────────────────────


class TestFacturationIsolation:
    def test_loyalty_disabled_sale_keeps_all_columns_null(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 500)

        request = CreateSaleRequest(
            client_request_id=str(uuid.uuid4()),
            items=[
                SaleLineRequest(
                    product_id=uuid.UUID(str(p["id"])),
                    quantity=Decimal("10"),
                    unit_price=Decimal("100.000"),
                )
            ],
            payment_method="cash",
            paid=Decimal("1000.000"),
            customer_id=uuid.UUID(str(c["id"])),
        )
        response = SaleService(db).create_sale(
            request,
            user=None,
            enable_loyalty=False,
        )

        assert response.amount_due is None
        assert response.loyalty_points_earned is None
        assert response.loyalty_cashback_earned is None
        assert response.loyalty_points_redeemed is None
        assert response.loyalty_redeemed_value is None
        # Legacy debt derivation from total still applies.
        assert response.debt == Decimal("0.000")

        sale = _sale(db, response.id)
        assert sale.amount_due is None
        assert sale.loyalty_points_earned is None
        assert sale.loyalty_points_redeemed is None
        assert sale.loyalty_redeemed_value is None
        assert sale.loyalty_cashback_earned is None

        # No engine activity in THIS sale: balance untouched by the sale,
        # no sale-linked entries (the seed row predates it).
        account = _account(db, c["id"])
        assert account is not None
        assert account.points_balance == Decimal("500")
        sale_linked = db.scalar(
            select(func.count())
            .select_from(LoyaltyLedgerEntry)
            .where(LoyaltyLedgerEntry.sale_id.is_not(None))
        )
        assert sale_linked == 0

    def test_loyalty_disabled_rejects_reward_request(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, price="100.000", quantity="100.000")
        c = _create_customer(client, admin_headers)
        _seed_points(db, c["id"], 100)

        request = CreateSaleRequest(
            client_request_id=str(uuid.uuid4()),
            items=[
                SaleLineRequest(
                    product_id=uuid.UUID(str(p["id"])),
                    quantity=Decimal("1"),
                    unit_price=Decimal("100.000"),
                )
            ],
            payment_method="cash",
            paid=Decimal("50.000"),
            customer_id=uuid.UUID(str(c["id"])),
            loyalty_reward_percent=50,
        )
        with pytest.raises(ValidationError):
            SaleService(db).create_sale(
                request, user=None, enable_loyalty=False
            )
        db.rollback()
        assert db.scalar(select(func.count()).select_from(Sale)) == 0

    def test_legacy_debt_fallback_when_amount_due_null(
        self, client, admin_headers, db
    ):
        # Facturation sale with partial-style debt: response debt must come
        # from total (amount_due NULL), never crash or report 0.
        p = _create_product(client, admin_headers, price="100.000", quantity="100.000")
        c = _create_customer(client, admin_headers)

        request = CreateSaleRequest(
            client_request_id=str(uuid.uuid4()),
            items=[
                SaleLineRequest(
                    product_id=uuid.UUID(str(p["id"])),
                    quantity=Decimal("10"),
                    unit_price=Decimal("100.000"),
                )
            ],
            payment_method="partial",
            paid=Decimal("400.000"),
            customer_id=uuid.UUID(str(c["id"])),
        )
        response = SaleService(db).create_sale(
            request, user=None, enable_loyalty=False
        )
        assert response.amount_due is None
        assert response.debt == Decimal("600.000")
