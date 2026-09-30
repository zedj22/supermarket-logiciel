"""Fix Round 2 — customer debt must be the AGGREGATE of the whole ledger.

The product owner reported that the customer detail balance "does not go
up when a new debt is added" and that "a payment seems to clear one debt
and then move to the next one".  The source of truth was traced first
(Step 2A/2F of the fix round):

    sale/payment -> debt_ledger_entries (append-only, authoritative)
                 -> customers.balance   (cached projection, same tx)
                 -> GET /customers/{id} (returns the projection)
                 -> Flutter detail card (cached provider - the bug)

This module proves the three backend layers agree for the exact numbers
of the report (520 + 534 = 1054, pay 500 -> 554, +200 -> 754, pay 754 ->
0) and that the write paths stay atomic.  Nothing here rewrites or
deletes a ledger row - the history keeps every entry.

Covered regression list (12):
 1. existing 520 + credit sale 534           -> 1054
 2. a second credit sale increases again
 3. a payment reduces the aggregate
 4. multiple payments reduce it cumulatively
 5. paying the exact aggregate reaches 0
 6. overpayment is still rejected
 7. the ledger history stays complete
 8. customers.balance == authoritative ledger sum
 9. customer detail API returns the aggregate after a new debt
10. customer detail API returns the aggregate after a payment
11. create debt + balance update are atomic
12. payment + balance update are atomic
"""

from __future__ import annotations

import time
import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.debt import DebtLedgerEntry
from app.models.party import Customer
from app.models.sale import Sale
from app.repositories.debt import DebtLedgerEntryRepository
from app.services.auth import AuthService

# ── Fixtures (same self-contained harness as test_debts.py) ───────────────


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
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


# ── Helpers ───────────────────────────────────────────────────────────────

_barcode_seq = {"n": 0}
_customer_seq = {"n": 0}


def _separate_seconds() -> None:
    """SQLite CURRENT_TIMESTAMP has second precision — keep entries apart
    so chronological running balances are deterministic."""
    time.sleep(1.05)


def _create_product(client, headers, price: str) -> dict:
    _barcode_seq["n"] += 1
    resp = client.post(
        "/api/v1/products",
        json={
            "name": f"Aggregate Product {_barcode_seq['n']}",
            "barcode": f"AGG{_barcode_seq['n']:05d}",
            "price": price,
            "cost": "0.100",
            "quantity": "1000000.000",
            "unit": "piece",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, **overrides) -> dict:
    _customer_seq["n"] += 1
    payload = {"name": f"Aggregate Customer {_customer_seq['n']}"}
    payload.update(overrides)
    resp = client.post("/api/v1/customers", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _credit_sale(
    client, headers, product_id: str, customer_id: str, *, amount: str
) -> dict:
    """One fully-on-credit sale of exactly ``amount`` money units."""
    unit_price = _price_by_product[product_id]
    quantity = (Decimal(amount) / Decimal(unit_price)).quantize(
        Decimal("0.001")
    )
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {
                    "product_id": product_id,
                    "quantity": f"{quantity}",
                    "unit_price": unit_price,
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
    body = resp.json()
    assert Decimal(body["debt"]) == Decimal(amount), body
    return body


_price_by_product: dict[str, str] = {}


def _bind_price(client, headers, product: dict) -> dict:
    _price_by_product[product["id"]] = str(product["price"])
    return product


def _pay(
    client, headers, customer_id: str, amount: str, *, expect: int = 200
) -> tuple[int, dict]:
    resp = client.post(
        f"/api/v1/customers/{customer_id}/pay",
        json={"amount": amount, "client_request_id": str(uuid.uuid4())},
        headers=headers,
    )
    return resp.status_code, (resp.json() if resp.content else {})


def _detail(client, headers, customer_id: str) -> dict:
    resp = client.get(f"/api/v1/customers/{customer_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _history(client, headers, customer_id: str, **params) -> dict:
    resp = client.get(
        f"/api/v1/customers/{customer_id}/debts",
        params=params,
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _balance(db, customer_id: str) -> Decimal:
    db.expire_all()
    customer = db.get(Customer, uuid.UUID(customer_id))
    return Decimal(str(customer.balance)).quantize(Decimal("0.001"))


def _ledger_sum(db, customer_id: str) -> Decimal:
    db.expire_all()
    return DebtLedgerEntryRepository(db).ledger_sum_for_customer(
        uuid.UUID(customer_id)
    ).quantize(Decimal("0.001"))


def _ledger_rows(db, customer_id: str) -> list[DebtLedgerEntry]:
    db.expire_all()
    return list(
        db.execute(
            select(DebtLedgerEntry)
            .where(DebtLedgerEntry.customer_id == uuid.UUID(customer_id))
            .order_by(DebtLedgerEntry.entry_date.asc(), DebtLedgerEntry.id.asc())
        ).scalars()
    )


def _sale_count(db) -> int:
    db.expire_all()
    return db.execute(select(func.count()).select_from(Sale)).scalar_one()


def _seed_debt(client, headers, db, amount: str) -> tuple[dict, dict, str]:
    """Create a customer whose outstanding balance is exactly ``amount``.

    Price is always 1.000 so ``quantity == amount`` exactly — no
    rounding noise in an aggregate-arithmetic test.
    """
    product = _bind_price(
        client, headers, _create_product(client, headers, price="1.000")
    )
    customer = _create_customer(client, headers)
    _credit_sale(
        client, headers, product["id"], customer["id"], amount=amount
    )
    assert _balance(db, customer["id"]) == Decimal(amount)
    return product, customer, product["id"]


# ── 1 + 9: 520 + 534 = 1054, detail API agrees ───────────────────────────


def test_new_credit_sale_adds_to_the_existing_balance(
    client, admin_headers, db
):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    _credit_sale(client, admin_headers, product_id, cid, amount="534")

    assert _balance(db, cid) == Decimal("1054")
    assert _ledger_sum(db, cid) == Decimal("1054")
    assert Decimal(_detail(client, admin_headers, cid)["balance"]) == Decimal(
        "1054"
    )


# ── 2: a second credit sale increases the aggregate again ────────────────


def test_second_credit_sale_increases_the_aggregate_again(
    client, admin_headers, db
):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    _credit_sale(client, admin_headers, product_id, cid, amount="534")
    _credit_sale(client, admin_headers, product_id, cid, amount="200")

    assert _balance(db, cid) == Decimal("1254")
    assert _ledger_sum(db, cid) == Decimal("1254")


# ── 3 + 10: a payment reduces the aggregate; detail API agrees ───────────


def test_payment_reduces_the_aggregate_balance(client, admin_headers, db):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]
    _credit_sale(client, admin_headers, product_id, cid, amount="534")

    code, body = _pay(client, admin_headers, cid, "500.000")
    assert code == 200, body

    assert _balance(db, cid) == Decimal("554")
    assert _ledger_sum(db, cid) == Decimal("554")
    assert Decimal(body["balance"]) == Decimal("554")
    assert Decimal(_detail(client, admin_headers, cid)["balance"]) == Decimal(
        "554"
    )


# ── 4: multiple payments reduce it cumulatively ──────────────────────────


def test_multiple_payments_reduce_the_aggregate_cumulatively(
    client, admin_headers, db
):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    code, _ = _pay(client, admin_headers, cid, "300.000")
    assert code == 200
    assert _balance(db, cid) == Decimal("220")

    code, _ = _pay(client, admin_headers, cid, "120.000")
    assert code == 200
    assert _balance(db, cid) == Decimal("100")
    assert _ledger_sum(db, cid) == Decimal("100")


# ── 5: the reported sequence ends at exactly 0 ────────────────────────────


def test_reported_sequence_ends_at_zero(client, admin_headers, db):
    """520 + 534 -> 1054, -500 -> 554, +200 -> 754, -754 -> 0."""
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    _credit_sale(client, admin_headers, product_id, cid, amount="534")
    assert _balance(db, cid) == Decimal("1054")

    code, _ = _pay(client, admin_headers, cid, "500.000")
    assert code == 200
    assert _balance(db, cid) == Decimal("554")

    _credit_sale(client, admin_headers, product_id, cid, amount="200")
    assert _balance(db, cid) == Decimal("754")

    code, body = _pay(client, admin_headers, cid, "754.000")
    assert code == 200, body
    assert _balance(db, cid) == Decimal("0")
    assert _ledger_sum(db, cid) == Decimal("0")
    assert Decimal(_detail(client, admin_headers, cid)["balance"]) == Decimal(
        "0"
    )


# ── 6: overpayment is still rejected ─────────────────────────────────────


def test_overpayment_is_still_rejected(client, admin_headers, db):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]
    _credit_sale(client, admin_headers, product_id, cid, amount="534")

    code, body = _pay(client, admin_headers, cid, "1054.001")
    assert code == 422
    assert body["error"]["code"] == "PAYMENT_EXCEEDS_BALANCE"

    assert _balance(db, cid) == Decimal("1054")
    assert _ledger_sum(db, cid) == Decimal("1054")


# ── 7: the ledger history keeps every entry ───────────────────────────────


def test_ledger_history_remains_complete(client, admin_headers, db):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    # Every entry needs its own second: SQLite CURRENT_TIMESTAMP is
    # second-precision and the id tie-break (uuid4) would otherwise make
    # the chronological order — and therefore balance_after — random.
    _separate_seconds()
    _credit_sale(client, admin_headers, product_id, cid, amount="534")
    _separate_seconds()
    _pay(client, admin_headers, cid, "500.000")
    _separate_seconds()
    _credit_sale(client, admin_headers, product_id, cid, amount="200")
    _separate_seconds()
    code, _ = _pay(client, admin_headers, cid, "754.000")
    assert code == 200

    body = _history(client, admin_headers, cid, page_size=50)
    assert body["total"] == 5, "no ledger row may ever be deleted"
    assert [e["entry_type"] for e in body["items"]] == [
        "payment",
        "sale",
        "payment",
        "sale",
        "sale",
    ]

    rows = _ledger_rows(db, cid)
    assert len(rows) == 5
    # The oldest entry's running balance is the first sale, the newest
    # one's is the final aggregate — both computed from the full history.
    balances = {
        str(e["id"]): e["balance_after"] for e in body["items"]
    }
    assert Decimal(balances[str(rows[0].id)]) == Decimal("520")
    assert Decimal(balances[str(rows[-1].id)]) == Decimal("0")


# ── 8: customers.balance == authoritative ledger sum ──────────────────────


def test_customer_balance_equals_ledger_authoritative_total(
    client, admin_headers, db
):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]

    _credit_sale(client, admin_headers, product_id, cid, amount="534")
    _pay(client, admin_headers, cid, "500.000")
    _credit_sale(client, admin_headers, product_id, cid, amount="200")

    assert _balance(db, cid) == _ledger_sum(db, cid) == Decimal("754")
    assert Decimal(_detail(client, admin_headers, cid)["balance"]) == Decimal(
        "754"
    )

    # AR summary uses the same projection.
    summary = client.get("/api/v1/debts/summary", headers=admin_headers).json()
    assert Decimal(summary["total_debt"]) >= Decimal("754")


# ── 11: creating a debt and updating the balance are atomic ───────────────


def test_create_debt_and_balance_update_are_atomic(
    client, admin_headers, db
):
    """A rejected credit sale leaves balance, ledger and sales untouched."""
    product = _bind_price(
        client, admin_headers, _create_product(client, admin_headers, price="10")
    )
    customer = _create_customer(
        client, admin_headers, debt_ceiling="1000.000"
    )
    cid = customer["id"]
    _credit_sale(client, admin_headers, product["id"], cid, amount="520")
    balances_before = _balance(db, cid)
    rows_before = len(_ledger_rows(db, cid))
    sales_before = _sale_count(db)

    # 520 + 534 = 1054 > ceiling 1000 -> rejected before any mutation.
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {
                    "product_id": product["id"],
                    "quantity": "53.400",
                    "unit_price": "10.000",
                    "line_discount": "0.000",
                }
            ],
            "invoice_discount": "0.000",
            "payment_method": "credit",
            "paid": "0.000",
            "customer_id": cid,
            "device_id": "POS-1",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "DEBT_CEILING_EXCEEDED"

    assert _balance(db, cid) == balances_before
    assert _ledger_sum(db, cid) == balances_before
    assert len(_ledger_rows(db, cid)) == rows_before
    assert _sale_count(db) == sales_before
    assert Decimal(_detail(client, admin_headers, cid)["balance"]) == (
        balances_before
    )


# ── 12: a payment and the balance update are atomic ───────────────────────


def test_payment_and_balance_update_are_atomic(client, admin_headers, db):
    product, customer, product_id = _seed_debt(client, admin_headers, db, "520")
    cid = customer["id"]
    rows_before = len(_ledger_rows(db, cid))

    # Rejected payment: no ledger row, no balance change (one commit).
    code, body = _pay(client, admin_headers, cid, "999.000")
    assert code == 422
    assert body["error"]["code"] == "PAYMENT_EXCEEDS_BALANCE"
    assert len(_ledger_rows(db, cid)) == rows_before
    assert _balance(db, cid) == Decimal("520")

    # Accepted payment: BOTH the ledger row and the balance move together.
    code, body = _pay(client, admin_headers, cid, "200.000")
    assert code == 200
    assert len(_ledger_rows(db, cid)) == rows_before + 1
    assert _balance(db, cid) == Decimal("320")
    assert _ledger_sum(db, cid) == Decimal("320")
    assert Decimal(body["balance"]) == Decimal("320")
