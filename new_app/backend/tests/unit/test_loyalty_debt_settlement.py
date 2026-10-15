"""Phase D tests — loyalty earn on debt settlement (DebtService.pay).

Covers the approved Phase D rules where they meet the debt transaction:

- rewards are earned on the ACTUAL amount applied to the debt (a partial
  payment earns only on the paid share, an overpayment earns nothing
  because it is rejected before any write);
- the merchant setting ``earn_on_debt_settlement`` gates the whole
  event — off means NO ledger entry and NO balance change;
- the source event key ``debt_settle:{entry_id}`` ties the award to the
  ONE debt ledger entry, so an idempotent replay (same
  client_request_id) can never award twice;
- the post runs inside the payment transaction: a failed post rolls the
  ENTIRE payment back (no payment row, no audit row, no loyalty row);
- debt limits, locking and payment validation are untouched — the
  existing PAYMENT_EXCEEDS_BALANCE contract still fires first.

SQLite fixture mirrors test_pos_sale_loyalty.py (StaticPool in-memory);
production correctness of FOR UPDATE / savepoint races is asserted by
tests/integration/test_loyalty_settlement_concurrency.py.
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
from app.models.party import Customer
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


_barcode_seq = {"n": 0}


def _create_product(client, headers, **overrides) -> dict:
    _barcode_seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Settle Product {_barcode_seq['n']}"),
        "barcode": overrides.pop("barcode", f"STL{_barcode_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str = "Settle Customer") -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name, "phone": None}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _credit_sale(
    client, headers, product_id: str, customer_id: str, amount: str = "100.000"
) -> dict:
    """One-line credit sale -> full amount lands on the customer's debt."""
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {
                    "product_id": product_id,
                    "quantity": "1.000",
                    "unit_price": amount,
                    "line_discount": "0.000",
                }
            ],
            "invoice_discount": "0.000",
            "payment_method": "credit",
            "paid": "0.000",
            "customer_id": customer_id,
            "device_id": "POS-1",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _pay(client, headers, customer_id: str, amount: str, crid: str | None = None):
    payload = {"amount": amount}
    if crid is not None:
        payload["client_request_id"] = crid
    return client.post(
        f"/api/v1/customers/{customer_id}/pay", json=payload, headers=headers
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


def _customer_ledger(session, customer_id) -> list[LoyaltyLedgerEntry]:
    session.expire_all()
    account = _account(session, customer_id)
    if account is None:
        return []
    return list(
        session.scalars(
            select(LoyaltyLedgerEntry).where(
                LoyaltyLedgerEntry.account_id == account.id
            )
        )
    )


def _event_rows(session, customer_id, event_type: str) -> list[LoyaltyLedgerEntry]:
    return [
        r for r in _customer_ledger(session, customer_id) if r.event_type == event_type
    ]


def _debt_balance(session, customer_id) -> Decimal:
    session.expire_all()
    row = session.scalars(
        select(Customer).where(Customer.id == uuid.UUID(str(customer_id)))
    ).one()
    return Decimal(str(row.balance))


def _payment_rows(session, customer_id) -> list:
    session.expire_all()
    from app.models.debt import DebtLedgerEntry

    return list(
        session.scalars(
            select(DebtLedgerEntry).where(
                DebtLedgerEntry.customer_id == uuid.UUID(str(customer_id)),
                DebtLedgerEntry.entry_type == "payment",
            )
        )
    )


def _reconcile(session, customer_id) -> None:
    LoyaltyEngine(session).reconcile_account(uuid.UUID(str(customer_id)))


# ── Earn on settlement ────────────────────────────────────────────────────


class TestDebtSettlementEarn:
    def test_payment_awards_points_and_cashback_on_applied_amount(
        self, client, admin_headers, db
    ):
        _update_settings(db, cashback_enabled=True)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])  # debt 100

        resp = _pay(client, admin_headers, c["id"], "100.000", crid="pay-1")
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["idempotent_replay"] is False

        # floor(100 x 0.01) = 1 point; cashback 1% of 100 = 1.000.
        rows = _event_rows(db, c["id"], "debt_settlement_earn")
        assert len(rows) == 1
        entry = rows[0]
        assert entry.points_delta == Decimal("1")
        assert entry.cashback_delta == Decimal("1.000")
        # Stable identity: the debt ledger entry id of THIS payment.
        assert entry.source_event_key == f"debt_settle:{body['id']}"
        assert entry.sale_id is None

        account = _account(db, c["id"])
        assert account.points_balance == Decimal("1")
        assert account.cashback_balance == Decimal("1.000")
        _reconcile(db, c["id"])
        assert _debt_balance(db, c["id"]) == Decimal("0.000")

    def test_setting_off_awards_nothing(
        self, client, admin_headers, db
    ):
        _update_settings(db, earn_on_debt_settlement=False)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])

        resp = _pay(client, admin_headers, c["id"], "100.000")
        assert resp.status_code == 200, resp.text

        # The payment itself committed…
        assert len(_payment_rows(db, c["id"])) == 1
        assert _debt_balance(db, c["id"]) == Decimal("0.000")
        # …but no loyalty event exists at all.
        assert _event_rows(db, c["id"], "debt_settlement_earn") == []
        assert _account(db, c["id"]) is None

    def test_partial_payment_earns_only_on_the_applied_amount(
        self, client, admin_headers, db
    ):
        _update_settings(db, cashback_enabled=True)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])  # debt 100

        resp = _pay(client, admin_headers, c["id"], "40.000")
        assert resp.status_code == 200, resp.text

        rows = _event_rows(db, c["id"], "debt_settlement_earn")
        assert len(rows) == 1
        # Earned on 40, NOT on the 100 debt: points floor(0.4) = 0,
        # cashback 1% x 40 = 0.400.
        assert rows[0].points_delta == Decimal("0")
        assert rows[0].cashback_delta == Decimal("0.400")
        account = _account(db, c["id"])
        assert account.points_balance == Decimal("0")
        assert account.cashback_balance == Decimal("0.400")
        _reconcile(db, c["id"])
        # Debt shrinks by the payment only.
        assert _debt_balance(db, c["id"]) == Decimal("60.000")

    def test_overpayment_rejected_earns_nothing(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])  # debt 100

        resp = _pay(client, admin_headers, c["id"], "200.000")
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "PAYMENT_EXCEEDS_BALANCE"
        # Zero residue: no payment row, no loyalty row, balance intact.
        assert _payment_rows(db, c["id"]) == []
        assert _event_rows(db, c["id"], "debt_settlement_earn") == []
        assert _debt_balance(db, c["id"]) == Decimal("100.000")

    def test_zero_rate_awards_no_entry(self, client, admin_headers, db):
        _update_settings(
            db,
            points_rate=Decimal("0"),
            cashback_enabled=True,
            cashback_rate=Decimal("0"),
        )
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])

        resp = _pay(client, admin_headers, c["id"], "100.000")
        assert resp.status_code == 200, resp.text
        # Both rules contribute exactly zero -> no post at all.
        assert _customer_ledger(db, c["id"]) == []
        assert _debt_balance(db, c["id"]) == Decimal("0.000")


# ── Idempotency / atomicity ───────────────────────────────────────────────


class TestDebtSettlementIdempotency:
    def test_replay_never_double_awards(self, client, admin_headers, db):
        _update_settings(db, cashback_enabled=True)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])

        crid = str(uuid.uuid4())
        first = _pay(client, admin_headers, c["id"], "100.000", crid=crid)
        second = _pay(client, admin_headers, c["id"], "100.000", crid=crid)
        assert first.status_code == 200, first.text
        assert second.status_code == 200, second.text
        assert first.json()["id"] == second.json()["id"]
        assert second.json()["idempotent_replay"] is True

        # ONE payment row, ONE earn entry, ONE award of balances.
        assert len(_payment_rows(db, c["id"])) == 1
        rows = _event_rows(db, c["id"], "debt_settlement_earn")
        assert len(rows) == 1
        account = _account(db, c["id"])
        assert account.points_balance == Decimal("1")
        assert account.cashback_balance == Decimal("1.000")
        assert _debt_balance(db, c["id"]) == Decimal("0.000")
        _reconcile(db, c["id"])

    def test_failed_post_rolls_back_the_whole_payment(
        self, client, admin_headers, db, monkeypatch
    ):
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])  # debt 100

        def _boom(self, **kwargs):
            raise RuntimeError("loyalty post exploded (test)")

        monkeypatch.setattr(LoyaltyEngine, "post", _boom)
        resp = _pay(client, admin_headers, c["id"], "100.000")
        assert resp.status_code == 500, resp.text
        monkeypatch.undo()

        # Atomic rollback: payment, audit, loyalty — all or nothing.
        assert _payment_rows(db, c["id"]) == []
        assert _event_rows(db, c["id"], "debt_settlement_earn") == []
        assert _account(db, c["id"]) is None
        assert _debt_balance(db, c["id"]) == Decimal("100.000")

    def test_two_distinct_payments_each_award_once(
        self, client, admin_headers, db
    ):
        _update_settings(db, cashback_enabled=True)
        p = _create_product(client, admin_headers)
        c = _create_customer(client, admin_headers)
        _credit_sale(client, admin_headers, p["id"], c["id"])  # debt 100

        assert _pay(client, admin_headers, c["id"], "30.000").status_code == 200
        assert _pay(client, admin_headers, c["id"], "70.000").status_code == 200

        # One award per distinct payment, distinct stable source keys.
        rows = _event_rows(db, c["id"], "debt_settlement_earn")
        assert len(rows) == 2
        keys = {r.source_event_key for r in rows}
        assert len(keys) == 2
        assert all(k.startswith("debt_settle:") for k in keys)
        # cashback 1%: 0.300 on the 30 payment, 0.700 on the 70 payment.
        assert sorted(r.cashback_delta for r in rows) == [
            Decimal("0.300"),
            Decimal("0.700"),
        ]
        assert _debt_balance(db, c["id"]) == Decimal("0.000")
        _reconcile(db, c["id"])
