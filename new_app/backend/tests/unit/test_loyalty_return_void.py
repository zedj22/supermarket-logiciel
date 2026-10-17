"""Phase D tests — loyalty reversal on returns and voids.

Covers the approved Phase D rules where they meet the return/void
transactions:

RETURN
- the pro-rata share of the checkout rewards is clawed back (floored —
  a clawback never rounds up) and entitlement-exact across partial
  returns: fully returning a sale claws back exactly what it earned;
- balances can never go negative: the clawback is floored at the
  CURRENT balance, the unreversed shortfall is recorded in the ledger
  note, and the return itself stays valid;
- the redeemed share of the return restores points (entitlement
  pattern) and is carved out of the settlement base — refund =
  credit_reversed + cash_pending + restored value, never a second cash
  refund for the redeemed portion;
- idempotent replays never duplicate ledger entries, and the clawback /
  restoration post in the SAME transaction as the return document.

VOID
- checkout rewards are clawed back exactly once and the redeemed points
  are restored in full, in the same transaction as the void;
- SALE_ALREADY_VOID / SALE_HAS_RETURNS gates run BEFORE any loyalty
  write, so repeated or excluded operations leave zero residue;
- cash_pending is net of the redeemed value (points come back, not
  cash).

Anonymous / legacy sales (loyalty columns NULL) behave exactly as
before: no ledger rows, unchanged settlement numbers.

SQLite fixture mirrors test_pos_sale_loyalty.py; FOR UPDATE races are
gated by tests/integration/test_loyalty_settlement_concurrency.py.
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
from app.models.loyalty import LoyaltyAccount, LoyaltyLedgerEntry
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
        "name": overrides.pop("name", f"Rev Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"REV{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str = "Rev Customer") -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name, "phone": None}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sell(
    client,
    headers,
    product_id: str,
    *,
    quantity: str = "10.000",
    customer_id: str | None = None,
    reward_percent: int = 0,
    paid: str | None = None,
    payment_method: str = "cash",
) -> dict:
    """One-line sale; reward-percent and credit flows included."""
    unit = Decimal("100.000")
    gross = unit * Decimal(quantity)
    discount = (
        gross * Decimal(reward_percent) / Decimal(100)
    ).quantize(Decimal("0.001"))
    if paid is None:
        paid = str(gross - discount)
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": [
            {
                "product_id": product_id,
                "quantity": quantity,
                "unit_price": str(unit),
                "line_discount": "0.000",
            }
        ],
        "invoice_discount": "0.000",
        "payment_method": payment_method,
        "paid": paid,
        "device_id": "POS-1",
    }
    if customer_id is not None:
        payload["customer_id"] = customer_id
    if reward_percent:
        payload["loyalty_reward_percent"] = reward_percent
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _return(
    client, headers, sale_id: str, lines: list[dict], crid: str | None = None,
    customer_id: str | None = None,
):
    payload = {
        "client_request_id": crid or str(uuid.uuid4()),
        "reason": "defective",
        "sale_id": sale_id,
        "lines": lines,
        "device_id": "POS-1",
    }
    if customer_id is not None:
        payload["customer_id"] = customer_id
    return client.post("/api/v1/returns", json=payload, headers=headers)


def _void(client, headers, sale_id: str, reason: str = "wrong item scanned"):
    return client.post(
        f"/api/v1/sales/{sale_id}/void",
        json={"reason": reason},
        headers=headers,
    )


def _update_settings(session, **fields) -> None:
    LoyaltySettingsService(session).update(
        LoyaltySettingsUpdateRequest(**fields),
        actor_id=None,
    )
    session.expire_all()


def _account(session, customer_id) -> LoyaltyAccount | None:
    session.expire_all()
    return session.scalars(
        select(LoyaltyAccount).where(
            LoyaltyAccount.customer_id == uuid.UUID(str(customer_id))
        )
    ).first()


def _balances(session, customer_id) -> tuple[Decimal, Decimal]:
    account = _account(session, customer_id)
    if account is None:
        return Decimal(0), Decimal(0)
    return (
        Decimal(str(account.points_balance)),
        Decimal(str(account.cashback_balance)),
    )


def _spend_points(session, customer_id, points: int) -> None:
    """Simulate the customer spending rewards between sale and reversal."""
    engine = LoyaltyEngine(session)
    with engine.transaction():
        engine.post(
            customer_id=uuid.UUID(str(customer_id)),
            event_type="redeem",
            source_event_key=f"spend:{uuid.uuid4().hex}",
            points_delta=-Decimal(points),
        )
    session.expire_all()


def _ledger_rows(session, **filters) -> list[LoyaltyLedgerEntry]:
    session.expire_all()
    stmt = select(LoyaltyLedgerEntry)
    for attr, value in filters.items():
        stmt = stmt.where(getattr(LoyaltyLedgerEntry, attr) == value)
    return list(session.scalars(stmt).all())


def _reconcile(session, customer_id) -> None:
    LoyaltyEngine(session).reconcile_account(uuid.UUID(str(customer_id)))


def _money(value) -> Decimal:
    return Decimal(str(value))


# ── Returns ───────────────────────────────────────────────────────────────


class TestReturnClawback:
    def test_partial_return_claws_pro_rata_points(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        seed_engine = LoyaltyEngine(db)
        with seed_engine.transaction():
            seed_engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        # 1000 gross earns floor(1000 x 0.01) = 10 -> balance 510.
        assert _balances(db, c["id"])[0] == Decimal(510)

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "5.000"}],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        # Pro-rata clawback: floor(10 x 500/1000) = 5.
        assert _balances(db, c["id"])[0] == Decimal(505)
        rows = _ledger_rows(
            db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
        )
        assert len(rows) == 1
        assert rows[0].points_delta == Decimal(-5)
        assert rows[0].source_event_key == f"return_clawback:{body['return']['id']}"
        assert rows[0].return_id is not None
        # No redemption on this sale -> settlement numbers unchanged.
        assert _money(body["refund_total"]) == Decimal("500.000")
        assert _money(body["cash_pending"]) == Decimal("500.000")
        assert _money(body["credit_reversed"]) == Decimal("0.000")
        _reconcile(db, c["id"])

    def test_full_return_claws_back_exactly_what_it_earned(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        assert _balances(db, c["id"])[0] == Decimal(510)

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "10.000"}],
        )
        assert resp.status_code == 201, resp.text
        # Exactly the 10 earned come back off — balance returns to seed.
        assert _balances(db, c["id"])[0] == Decimal(500)
        _reconcile(db, c["id"])

    def test_spent_rewards_floor_at_balance_and_note_the_shortfall(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        # Spend everything but 4 points (510 -> 4): the 10 earned are gone.
        _spend_points(db, c["id"], 506)
        assert _balances(db, c["id"])[0] == Decimal(4)

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "10.000"}],
        )
        # The return itself stays VALID…
        assert resp.status_code == 201, resp.text

        rows = _ledger_rows(
            db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
        )
        assert len(rows) == 1
        # …floored at the balance, never negative…
        assert rows[0].points_delta == Decimal(-4)
        # …and the unreversed shortfall is recorded in the ledger note.
        assert "6 points already spent" in (rows[0].note or "")
        assert _balances(db, c["id"])[0] == Decimal(0)
        _reconcile(db, c["id"])

    def test_return_claws_cashback_too(self, client, admin_headers, db):
        _update_settings(db, cashback_enabled=True)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        points, cashback = _balances(db, c["id"])
        assert points == Decimal(10)
        assert cashback == Decimal("10.000")  # 1% of 1000

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "4.000"}],
        )
        assert resp.status_code == 201, resp.text
        points, cashback = _balances(db, c["id"])
        # floor pro-rata: 10 x 0.4 = 4 points, 10.000 x 0.4 = 4.000 DA.
        assert points == Decimal(6)
        assert cashback == Decimal("6.000")
        _reconcile(db, c["id"])


class TestReturnRedemptionRestoration:
    def test_full_return_restores_points_and_caps_cash_at_paid_amount(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(
            client,
            admin_headers,
            p["id"],
            customer_id=c["id"],
            reward_percent=10,  # 1000 gross - 100 reward = paid 900
        )
        assert _money(sale["amount_due"]) == Decimal("900.000")
        # Rule R: earn on min(paid, due)=900 + 100 (reward) = 1000 == the
        # cart total -> 10.
        assert _balances(db, c["id"])[0] == Decimal(410)  # 500-100+10

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "10.000"}],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # Settlement: 1000 = 0 credit + 900 cash + 100 restored in points.
        # Cash refunds EXACTLY what was tendered — the redeemed share is
        # never cashed out a second time.
        assert _money(body["refund_total"]) == Decimal("1000.000")
        assert _money(body["credit_reversed"]) == Decimal("0.000")
        assert _money(body["cash_pending"]) == Decimal("900.000")

        # Ledger: clawback of the 10 earned + full restoration of 100.
        claw = _ledger_rows(
            db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
        )
        restore = _ledger_rows(
            db, event_type="adjustment", sale_id=uuid.UUID(sale["id"])
        )
        assert len(claw) == 1 and claw[0].points_delta == Decimal(-10)
        assert len(restore) == 1
        assert restore[0].points_delta == Decimal(100)
        assert restore[0].source_event_key == (
            f"return_redemption:{body['return']['id']}"
        )
        # 410 - 10 clawed + 100 restored = 500, exactly the pre-sale seed.
        assert _balances(db, c["id"])[0] == Decimal(500)
        _reconcile(db, c["id"])

    def test_two_partial_returns_restore_exactly_the_redeemed_points(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(
            client, admin_headers, p["id"], customer_id=c["id"], reward_percent=10
        )
        line = sale["lines"][0]
        # Rule R: earn on min(900, 900) + 100 = 1000 -> 10 points.
        assert _balances(db, c["id"])[0] == Decimal(410)

        first = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "3.000"}],
        )
        assert first.status_code == 201, first.text
        f = first.json()
        # floor(100 x 3/10) = 30 restored; claw floor(10 x 0.3) = 3.
        assert _money(f["cash_pending"]) == Decimal("270.000")  # 300-30
        assert _balances(db, c["id"])[0] == Decimal(437)  # 410-3+30

        second = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "7.000"}],
        )
        assert second.status_code == 201, second.text
        s = second.json()
        # Entitlement pattern: restoration floor(100 x 10/10) - 30 = 70
        # and claw floor(10 x 10/10) - 3 = 7 — exact completion by
        # pattern, not by luck of the floor.
        assert _money(s["cash_pending"]) == Decimal("630.000")  # 700-70
        assert _balances(db, c["id"])[0] == Decimal(500)  # 437-7+70

        restored = _ledger_rows(
            db, event_type="adjustment", sale_id=uuid.UUID(sale["id"])
        )
        clawed = _ledger_rows(
            db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
        )
        assert sum(r.points_delta for r in restored) == Decimal(100)
        assert sum(r.points_delta for r in clawed) == Decimal(-10)
        _reconcile(db, c["id"])

    def test_credit_and_redemption_settlement_never_double_covers(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(
            client,
            admin_headers,
            p["id"],
            customer_id=c["id"],
            reward_percent=10,
            payment_method="credit",
            paid="0.000",
        )
        # 1000 gross = 100 points + 900 debt.
        assert _money(sale["debt"]) == Decimal("900.000")

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "10.000"}],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        # refund = credit forgiven + cash owed + restored points value.
        assert _money(body["refund_total"]) == Decimal("1000.000")
        assert _money(body["credit_reversed"]) == Decimal("900.000")
        assert _money(body["cash_pending"]) == Decimal("0.000")
        assert _money(body["cash_pending"]) + _money(
            body["credit_reversed"]
        ) + Decimal("100.000") == _money(body["refund_total"])
        _reconcile(db, c["id"])


class TestReturnIdempotencyAndLegacyPaths:
    def test_replay_never_duplicates_loyalty_entries(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        line = sale["lines"][0]
        crid = str(uuid.uuid4())
        lines = [{"sale_line_id": line["id"], "quantity": "10.000"}]

        first = _return(
            client, admin_headers, sale["id"], lines, crid=crid,
            customer_id=c["id"],
        )
        second = _return(
            client, admin_headers, sale["id"], lines, crid=crid,
            customer_id=c["id"],
        )
        assert first.status_code == 201, first.text
        assert second.status_code == 201, second.text
        assert second.json()["idempotent_replay"] is True

        rows = _ledger_rows(
            db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
        )
        assert len(rows) == 1
        assert _balances(db, c["id"])[0] == Decimal(0)  # 10 - 10
        _reconcile(db, c["id"])

    def test_anonymous_sale_return_posts_nothing_loyalty(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"])  # no customer
        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "4.000"}],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        # No loyalty columns -> no ledger rows, settlement unchanged.
        assert _ledger_rows(
            db, event_type="return_clawback"
        ) == []
        assert _ledger_rows(
            db, event_type="adjustment"
        ) == []
        assert _money(body["refund_total"]) == _money(body["cash_pending"])
        assert _money(body["credit_reversed"]) == Decimal("0.000")

    def test_independent_return_posts_nothing_loyalty(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        resp = client.post(
            "/api/v1/returns",
            json={
                "client_request_id": str(uuid.uuid4()),
                "reason": "defective",
                "lines": [
                    {"product_id": p["id"], "quantity": "1.000"}
                ],
                "device_id": "POS-1",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        assert _ledger_rows(db, event_type="return_clawback") == []
        assert _ledger_rows(db, event_type="adjustment") == []


# ── Voids ─────────────────────────────────────────────────────────────────


class TestVoidReversal:
    def test_void_claws_back_and_restores_exactly_once(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        engine = LoyaltyEngine(db)
        with engine.transaction():
            engine.post(
                customer_id=uuid.UUID(c["id"]),
                event_type="adjustment",
                source_event_key=f"seed:{uuid.uuid4().hex}",
                points_delta=Decimal(500),
            )
        sale = _sell(
            client, admin_headers, p["id"], customer_id=c["id"], reward_percent=10
        )
        # Rule R: earn on min(900, 900) + 100 = 1000 -> 10: 500-100+10 = 410.
        assert _balances(db, c["id"])[0] == Decimal(410)

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text
        body = resp.json()

        # Claw the 10 earned, restore the 100 redeemed: back to seed.
        assert _balances(db, c["id"])[0] == Decimal(500)
        claw = _ledger_rows(
            db, event_type="void_clawback", sale_id=uuid.UUID(sale["id"])
        )
        restore = _ledger_rows(
            db, event_type="adjustment", sale_id=uuid.UUID(sale["id"])
        )
        assert len(claw) == 1
        assert claw[0].points_delta == Decimal(-10)
        assert claw[0].source_event_key == f"void_clawback:{sale['id']}"
        assert len(restore) == 1
        assert restore[0].points_delta == Decimal(100)
        assert restore[0].source_event_key == f"void_redemption:{sale['id']}"

        # Cash settles net of the redeemed value: 1000 - 0 - 100 = 900.
        assert _money(body["refund_due"]) == Decimal("1000.000")
        assert _money(body["credit_reversed"]) == Decimal("0.000")
        assert _money(body["cash_pending"]) == Decimal("900.000")
        _reconcile(db, c["id"])

    def test_second_void_is_rejected_without_second_entries(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])

        first = _void(client, admin_headers, sale["id"])
        balance_after = _balances(db, c["id"])
        second = _void(client, admin_headers, sale["id"])
        assert first.status_code == 200, first.text
        assert second.status_code == 409, second.text
        assert second.json()["error"]["code"] == "SALE_ALREADY_VOID"

        # Exactly one set of entries, balance untouched by the retry.
        assert (
            len(
                _ledger_rows(
                    db,
                    event_type="void_clawback",
                    sale_id=uuid.UUID(sale["id"]),
                )
            )
            == 1
        )
        assert _balances(db, c["id"]) == balance_after
        _reconcile(db, c["id"])

    def test_void_shortfall_when_rewards_spent(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        # Sale earned 10 -> spend 7, leaving 3 of the 10.
        _spend_points(db, c["id"], 7)
        assert _balances(db, c["id"])[0] == Decimal(3)

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text

        claw = _ledger_rows(
            db, event_type="void_clawback", sale_id=uuid.UUID(sale["id"])
        )
        assert len(claw) == 1
        assert claw[0].points_delta == Decimal(-3)  # floored, never -10
        assert "7 points already spent" in (claw[0].note or "")
        assert _balances(db, c["id"])[0] == Decimal(0)
        _reconcile(db, c["id"])

    def test_anonymous_void_posts_nothing_loyalty(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"])  # no customer

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert _ledger_rows(db, event_type="void_clawback") == []
        assert _ledger_rows(db, event_type="adjustment") == []
        # Settlement untouched: cash = total - credit (existing §17 math).
        assert _money(body["cash_pending"]) == _money(
            body["refund_due"]
        ) - _money(body["credit_reversed"])

    def test_failed_post_rolls_back_the_whole_void(
        self, client, admin_headers, db, monkeypatch
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        balance_before = _balances(db, c["id"])

        def _boom(self, **kwargs):
            raise RuntimeError("loyalty post exploded (test)")

        monkeypatch.setattr(LoyaltyEngine, "post", _boom)
        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 500, resp.text
        monkeypatch.undo()

        # Zero residue: sale still COMPLETED, no loyalty rows, balance
        # untouched — status flip and stock restore rolled back together
        # with the failed post.
        sale_row = db.get(Sale, uuid.UUID(sale["id"]))
        db.expire_all()
        sale_row = db.get(Sale, uuid.UUID(sale["id"]))
        assert sale_row.status == "completed"
        assert (
            _ledger_rows(
                db, event_type="void_clawback", sale_id=uuid.UUID(sale["id"])
            )
            == []
        )
        assert _balances(db, c["id"]) == balance_before


class TestReturnVoidMutualExclusionWithLoyalty:
    def test_return_then_void_stays_excluded(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        line = sale["lines"][0]
        ret = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "1.000"}],
        )
        assert ret.status_code == 201, ret.text
        balance_after_return = _balances(db, c["id"])

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 409, resp.text
        assert resp.json()["error"]["code"] == "SALE_HAS_RETURNS"
        # The rejected void posted nothing.
        assert (
            _ledger_rows(
                db, event_type="void_clawback", sale_id=uuid.UUID(sale["id"])
            )
            == []
        )
        assert _balances(db, c["id"]) == balance_after_return

    def test_void_then_return_stays_excluded(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], customer_id=c["id"])
        assert _void(client, admin_headers, sale["id"]).status_code == 200
        balance_after_void = _balances(db, c["id"])

        line = sale["lines"][0]
        resp = _return(
            client,
            admin_headers,
            sale["id"],
            [{"sale_line_id": line["id"], "quantity": "1.000"}],
        )
        assert resp.status_code == 409, resp.text
        assert resp.json()["error"]["code"] == "SALE_ALREADY_VOID"
        # The rejected return posted nothing.
        assert (
            _ledger_rows(
                db, event_type="return_clawback", sale_id=uuid.UUID(sale["id"])
            )
            == []
        )
        assert _balances(db, c["id"]) == balance_after_void
