"""PHASE 9 BUG FIX — authoritative customer debt-ceiling gate at checkout.

Rule (existing app-wide semantics, now ENFORCED on the server):

    debt_ceiling == 0  -> NO ceiling (unlimited)
    debt_ceiling  > 0  -> reject when current_balance + new_debt > ceiling
                          (projected == ceiling is allowed)

Where new_debt = total - paid (cash/card full payment -> new_debt = 0,
so never blocked).

Rejection contract:
    HTTP 422, error.code = "DEBT_CEILING_EXCEEDED",
    error.details = {customer_id, current_balance, new_debt,
                     projected_balance, debt_ceiling} as strings,
    raised BEFORE any mutation -> zero residue (no sale, lines, stock
    decrement, movements, payments, balance/ledger change).

Edge cases covered (brief list 1-11; case 12 lives in
tests/integration/test_sale_ceiling_concurrency.py):
    1. credit sale within ceiling -> 201, balance + ledger written
    2. projected > ceiling -> 422 DEBT_CEILING_EXCEEDED + exact details
    3. projected == ceiling -> 201 (boundary allowed)
    4. partial payment: only the debt portion counts
    5. cash/card full payment never blocked (even when already over)
    6. debt_ceiling == 0 means unlimited
    7. existing balance counts toward the ceiling
    8. sequential sales cannot cross the ceiling
    9. rejection leaves zero residue (all tables + stock unchanged)
   10. after rejection the session stays usable (follow-up sale works)
   11. error envelope shape (code/message/message_key/details/request_id)
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.debt import DebtLedgerEntry
from app.models.inventory import InventoryMovement
from app.models.party import Customer
from app.models.sale import Sale, SaleLine, SalePayment
from app.services.auth import AuthService


# ── Fixtures (self-contained harness, same pattern as test_pos_sale.py) ──


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


@pytest.fixture()
def admin_headers(client):
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


_barcode_seq = {"n": 0}


def _create_product(client, headers, **overrides) -> dict:
    _barcode_seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Ceiling Product {_barcode_seq['n']}"),
        "barcode": overrides.pop("barcode", f"CEIL{_barcode_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
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


_customer_seq = {"n": 0}


def _customer_row(db, *, balance: str, ceiling: str) -> Customer:
    """Customer with an exact starting balance/ceiling (API always starts at 0)."""
    _customer_seq["n"] += 1
    c = Customer(
        name=f"Ceiling Customer {_customer_seq['n']}",
        phone=None,
        balance=float(balance),
        debt_ceiling=float(ceiling),
    )
    db.add(c)
    db.commit()
    return c


def _credit_sale(product_id: str, quantity: str, customer_id) -> dict:
    """Credit sale: debt = quantity x 100 (unit price)."""
    return _sale_payload(
        product_id,
        items=[
            {
                "product_id": product_id,
                "quantity": quantity,
                "unit_price": "100.000",
                "line_discount": "0.000",
            }
        ],
        payment_method="credit",
        paid="0.000",
        customer_id=str(customer_id),
    )


def _counts(db) -> dict:
    def one(model):
        return db.execute(select(func.count()).select_from(model)).scalar()

    db.expire_all()
    return {
        "sales": one(Sale),
        "sale_lines": one(SaleLine),
        "sale_payments": one(SalePayment),
        "movements": one(InventoryMovement),
        "ledger": one(DebtLedgerEntry),
    }


def _fresh_customer(db, customer_id) -> Customer:
    db.expire_all()
    return db.get(Customer, customer_id)


def _fresh_product(db, product_id) -> Product:
    db.expire_all()
    return db.get(Product, uuid.UUID(product_id))


# ── 1/3/6/7/8: successful paths & boundary ─────────────────────────────


class TestCeilingAllows:
    def test_credit_within_ceiling_writes_balance_and_ledger(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="0.000", ceiling="500.000")
        p = _create_product(client, admin_headers)
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "3", cust.id))
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert float(body["debt"]) == 300.0

        fresh = _fresh_customer(db, cust.id)
        assert float(fresh.balance) == 300.0
        assert float(fresh.debt_ceiling) == 500.0

        rows = db.execute(
            select(DebtLedgerEntry).where(DebtLedgerEntry.customer_id == cust.id)
        ).scalars().all()
        assert len(rows) == 1
        assert rows[0].entry_type == "sale"
        assert float(rows[0].amount) == 300.0
        assert rows[0].reference_sale_id == uuid.UUID(body["id"])

    def test_projected_equal_ceiling_is_allowed(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="0.000", ceiling="300.000")
        p = _create_product(client, admin_headers)
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "3", cust.id))
        assert resp.status_code == 201, resp.text
        assert float(_fresh_customer(db, cust.id).balance) == 300.0

    def test_zero_ceiling_means_unlimited(self, client, admin_headers, db):
        cust = _customer_row(db, balance="5000.000", ceiling="0.000")
        p = _create_product(client, admin_headers)
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "7", cust.id))
        assert resp.status_code == 201, resp.text
        assert float(_fresh_customer(db, cust.id).balance) == 5700.0

    def test_existing_balance_counts_toward_ceiling(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="900.000", ceiling="1000.000")
        p = _create_product(client, admin_headers)

        # 900 + 150 = 1050 > 1000 -> rejected
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "1.5", cust.id))
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "DEBT_CEILING_EXCEEDED"
        assert float(_fresh_customer(db, cust.id).balance) == 900.0

        # 900 + 100 = 1000 == 1000 -> allowed (boundary)
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "1", cust.id))
        assert resp.status_code == 201, resp.text
        assert float(_fresh_customer(db, cust.id).balance) == 1000.0

    def test_sequential_sales_cannot_cross_ceiling(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="0.000", ceiling="500.000")
        p = _create_product(client, admin_headers)

        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "3", cust.id))
        assert resp.status_code == 201, resp.text

        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "3", cust.id))
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "DEBT_CEILING_EXCEEDED"

        assert _counts(db)["sales"] == 1
        assert float(_fresh_customer(db, cust.id).balance) == 300.0


# ── 4/5: debt-only counting ────────────────────────────────────────────


class TestCeilingCountsOnlyTheDebt:
    def test_partial_payment_debt_portion_is_checked(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="0.000", ceiling="140.000")
        p = _create_product(client, admin_headers)

        # total 200 - paid 50 = debt 150 > 140 -> rejected
        payload = _sale_payload(
            p["id"],
            items=[
                {
                    "product_id": p["id"],
                    "quantity": "2.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="partial",
            paid="50.000",
            customer_id=str(cust.id),
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert err["code"] == "DEBT_CEILING_EXCEEDED"
        assert err["details"]["new_debt"] == "150.000"
        assert float(_fresh_customer(db, cust.id).balance) == 0.0

        # same sale with ceiling 150 -> debt 150 == 150 -> allowed
        cust.debt_ceiling = 150.0
        db.commit()
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert float(_fresh_customer(db, cust.id).balance) == 150.0

    @pytest.mark.parametrize("method", ["cash", "card"])
    def test_full_payment_never_blocked_even_when_over_ceiling(
        self, client, admin_headers, db, method
    ):
        # Already far above the ceiling; full cash/card payment adds no debt.
        cust = _customer_row(db, balance="900.000", ceiling="100.000")
        p = _create_product(client, admin_headers)
        payload = _sale_payload(
            p["id"],
            payment_method=method,
            paid="100.000",
            customer_id=str(cust.id),
        )
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert float(resp.json()["debt"]) == 0.0
        assert float(_fresh_customer(db, cust.id).balance) == 900.0


# ── 2/9/10/11: rejection contract ──────────────────────────────────────


class TestCeilingRejection:
    def test_rejection_envelope_and_zero_residue(
        self, client, admin_headers, db
    ):
        cust = _customer_row(db, balance="0.000", ceiling="500.000")
        p = _create_product(client, admin_headers, quantity="100.000")

        before_counts = _counts(db)
        before_qty = float(_fresh_product(db, p["id"]).quantity)

        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "6", cust.id))
        assert resp.status_code == 422, resp.text

        # 11: envelope shape
        body = resp.json()
        assert set(body.keys()) == {"error"}
        err = body["error"]
        assert set(err.keys()) == {
            "code",
            "message_key",
            "message",
            "details",
            "request_id",
        }
        assert err["code"] == "DEBT_CEILING_EXCEEDED"
        assert err["message"] == "Customer debt ceiling exceeded"
        assert err["message_key"] == "errors.businessRule"

        # 2: exact structured details
        assert err["details"] == {
            "customer_id": str(cust.id),
            "current_balance": "0.000",
            "new_debt": "600.000",
            "projected_balance": "600.000",
            "debt_ceiling": "500.000",
        }

        # 9: zero residue — every table and stock untouched
        assert _counts(db) == before_counts
        assert float(_fresh_product(db, p["id"]).quantity) == before_qty
        fresh = _fresh_customer(db, cust.id)
        assert float(fresh.balance) == 0.0

        # 10: session/DB fully usable right after the rejection
        resp = _post_sale(client, admin_headers, _credit_sale(p["id"], "4", cust.id))
        assert resp.status_code == 201, resp.text
        assert float(_fresh_customer(db, cust.id).balance) == 400.0
        assert float(_fresh_product(db, p["id"]).quantity) == before_qty - 4.0
        assert _counts(db)["sales"] == before_counts["sales"] + 1
        assert _counts(db)["ledger"] == before_counts["ledger"] + 1

    def test_rejection_does_not_consume_idempotency_key(
        self, client, admin_headers, db
    ):
        """A rejected attempt must not burn the client_request_id: the same
        payload retried after lowering the ceiling succeeds exactly once."""
        cust = _customer_row(db, balance="0.000", ceiling="100.000")
        p = _create_product(client, admin_headers)
        payload = _credit_sale(p["id"], "3", cust.id)

        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 422, resp.text

        cust.debt_ceiling = 500.0
        db.commit()

        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert resp.json()["idempotent_replay"] is False

        # replay of the committed sale still returns the same sale
        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        assert resp.json()["idempotent_replay"] is True
        assert _counts(db)["sales"] == 1
