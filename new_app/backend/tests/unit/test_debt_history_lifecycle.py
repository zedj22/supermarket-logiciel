"""PHASE 9 FINAL UX FIX — complete customer debt history (lifecycle).

The history endpoint must expose everything the UI needs to render the
full debt lifecycle for one customer:

    1. credit sale (full debt) -> `sale` entry, invoice_number present,
       balance_after = debt amount
    2. partial sale -> `sale` entry for the DEBT PORTION only
    3. normal (partial) payment -> `payment` entry, balance_after drops
    4. Pay All -> recorded as a NORMAL payment entry (no special type),
       balance_after = 0
    5. after balance reaches 0 every entry remains visible (append-only)
    6. sale entry carries the invoice number snapshot
    7. payment note is preserved
    8. ordering stays newest first (unchanged)
    9. running balances are exact: 1200 -> 700 -> 0

`balance_after` is COMPUTED per request (chronological prefix sum
mirroring ledger_sum_for_customer: sale +, payment -, adjustment +0)
and never stored — no ledger/schema change.
"""

from __future__ import annotations

import time
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
from app.models.debt import DebtLedgerEntry
from app.models.party import Customer
from app.repositories.debt import DebtLedgerEntryRepository
from app.services.auth import AuthService


# ── Fixtures (self-contained harness, same pattern as test_debts.py) ──────


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
_customer_seq = {"n": 0}


def _separate_seconds() -> None:
    """Advance past SQLite's second-precision func.now() tie window.

    entry_date is server-generated: PostgreSQL now() has microsecond
    precision so consecutive requests never tie, but SQLite's
    CURRENT_TIMESTAMP truncates to seconds — entries written within the
    same second would tie and the id DESC tie-break (uuid4) would make
    newest-first ordering (and chronological running balances)
    nondeterministic. Sleeping >1s keeps the test focused on the
    ordering contract instead of uuid luck.
    """
    time.sleep(1.05)


def _create_product(client, headers, **overrides) -> dict:
    _barcode_seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Lifecycle Product {_barcode_seq['n']}"),
        "barcode": overrides.pop("barcode", f"LCYCL{_barcode_seq['n']:05d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, **overrides) -> dict:
    _customer_seq["n"] += 1
    payload = {"name": f"Lifecycle Customer {_customer_seq['n']}"}
    payload.update(overrides)
    resp = client.post(
        "/api/v1/customers", json=payload, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale_payload(product_id: str, customer_id, **overrides) -> dict:
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
        "customer_id": str(customer_id),
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_sale(client, headers, payload: dict):
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _pay(client, headers, customer_id, amount: str, **overrides) -> dict:
    payload = {"amount": amount}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/customers/{customer_id}/pay",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _history(client, headers, customer_id, **params) -> dict:
    resp = client.get(
        f"/api/v1/customers/{customer_id}/debts",
        params=params,
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _customer_balance(db, customer_id: str) -> Decimal:
    db.expire_all()
    customer = db.get(Customer, uuid.UUID(customer_id))
    return Decimal(str(customer.balance))


# ── 1 + 6: credit sale -> sale entry with invoice_number ──────────────────


def test_credit_sale_entry_visible_with_invoice_and_balance(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)

    # 12 x 100 = 1200 fully on credit (sale entry amount = debt portion).
    _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            items=[
                {
                    "product_id": product["id"],
                    "quantity": "12.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0.000",
        ),
    )

    body = _history(client, admin_headers, customer["id"])
    assert body["total"] == 1
    entry = body["items"][0]
    assert entry["entry_type"] == "sale"
    assert Decimal(entry["amount"]) == Decimal("1200")
    assert entry["invoice_number"] is not None
    assert entry["invoice_number"].startswith("INV-")
    assert entry["user_name"] == "Admin"
    assert entry["entry_date"] is not None
    # Running balance after the only entry = full debt.
    assert Decimal(entry["balance_after"]) == Decimal("1200")
    assert _customer_balance(db, customer["id"]) == Decimal("1200")


# ── 2: partial sale records only the debt portion ─────────────────────────


def test_partial_sale_records_debt_portion_only(client, admin_headers, db):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)

    # total 200, paid 50 -> debt 150
    sale = _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            items=[
                {
                    "product_id": product["id"],
                    "quantity": "2.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="partial",
            paid="50.000",
        ),
    )
    assert Decimal(sale["total"]) == Decimal("200")
    assert Decimal(sale["debt"]) == Decimal("150")

    body = _history(client, admin_headers, customer["id"])
    entry = body["items"][0]
    assert entry["entry_type"] == "sale"
    assert Decimal(entry["amount"]) == Decimal("150")
    assert Decimal(entry["balance_after"]) == Decimal("150")
    assert _customer_balance(db, customer["id"]) == Decimal("150")


# ── 3 + 4 + 5 + 7 + 8: full lifecycle, Pay All, retention, note, order ───


def test_full_lifecycle_pay_all_stays_visible_newest_first(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)

    # (a) Credit sale: debt 1200 -> sale entry.
    sale = _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            items=[
                {
                    "product_id": product["id"],
                    "quantity": "12.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0.000",
        ),
    )
    _separate_seconds()

    # (b) Normal partial payment 500 (with note -> preserved, test 7).
    _pay(
        client,
        admin_headers,
        customer["id"],
        "500.000",
        note="Cash 500",
    )
    _separate_seconds()

    # (c) Pay All: remaining 700 as a NORMAL payment entry (test 4).
    _pay(
        client,
        admin_headers,
        customer["id"],
        "700.000",
        note="Pay all",
    )

    assert _customer_balance(db, customer["id"]) == Decimal("0")

    body = _history(client, admin_headers, customer["id"])
    # (5) Everything remains visible after balance reaches 0.
    assert body["total"] == 3

    # (8) Newest first: pay-all payment, partial payment, sale.
    items = body["items"]
    assert [i["entry_type"] for i in items] == [
        "payment",
        "payment",
        "sale",
    ]

    # (4) Pay All is indistinguishable from any other payment entry,
    #     but its running balance is exactly zero.
    assert Decimal(items[0]["amount"]) == Decimal("700")
    assert Decimal(items[0]["balance_after"]) == Decimal("0")
    assert items[0]["note"] == "Pay all"

    # (3 + 9) Exact running balances: 1200 -> 700 -> 0.
    assert Decimal(items[1]["amount"]) == Decimal("500")
    assert Decimal(items[1]["balance_after"]) == Decimal("700")
    assert items[1]["note"] == "Cash 500"

    # (6) Sale entry keeps its invoice snapshot.
    assert items[2]["entry_type"] == "sale"
    assert Decimal(items[2]["amount"]) == Decimal("1200")
    assert Decimal(items[2]["balance_after"]) == Decimal("1200")
    assert items[2]["invoice_number"] == sale["invoice_number"]


# ── 9 + reconciliation: balance_after == ledger sum == customers.balance ──


def test_balance_after_matches_ledger_sum_and_customer_balance(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)

    _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            items=[
                {
                    "product_id": product["id"],
                    "quantity": "6.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0.000",
        ),
    )
    _separate_seconds()
    _pay(client, admin_headers, customer["id"], "150.000")
    _separate_seconds()
    _pay(client, admin_headers, customer["id"], "250.000")

    body = _history(client, admin_headers, customer["id"])
    items = body["items"]
    assert [Decimal(i["balance_after"]) for i in items] == [
        Decimal("200"),  # 600 - 150 - 250 (newest first)
        Decimal("450"),  # 600 - 150
        Decimal("600"),  # after the sale
    ]

    # The newest entry's running balance is the authoritative projection.
    customer_uuid = uuid.UUID(customer["id"])
    ledger_sum = DebtLedgerEntryRepository(db).ledger_sum_for_customer(
        customer_uuid
    )
    assert Decimal(items[0]["balance_after"]) == ledger_sum
    assert ledger_sum == _customer_balance(db, customer["id"])
    assert ledger_sum == Decimal("200")


# ── balance_after covers older entries beyond the current page ────────────


def test_balance_after_is_correct_on_second_page(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)

    _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            items=[
                {
                    "product_id": product["id"],
                    "quantity": "3.000",
                    "unit_price": "100.000",
                    "line_discount": "0.000",
                }
            ],
            payment_method="credit",
            paid="0.000",
        ),
    )
    _separate_seconds()
    _pay(client, admin_headers, customer["id"], "100.000")
    _separate_seconds()
    _pay(client, admin_headers, customer["id"], "100.000")

    # Page 2 holds only the original sale entry; its balance_after must
    # reflect the FULL chronological history (300), not just itself.
    body = _history(
        client, admin_headers, customer["id"], page=2, page_size=2
    )
    assert body["total"] == 3
    assert len(body["items"]) == 1
    assert body["items"][0]["entry_type"] == "sale"
    assert Decimal(body["items"][0]["balance_after"]) == Decimal("300")


# ── append-only proof: history reads never mutate the ledger ──────────────


def test_history_read_does_not_touch_ledger(client, admin_headers, db):
    product = _create_product(client, admin_headers, price="100.000")
    customer = _create_customer(client, admin_headers)
    _post_sale(
        client,
        admin_headers,
        _sale_payload(
            product["id"],
            customer["id"],
            payment_method="credit",
            paid="0.000",
        ),
    )

    def _rows():
        db.expire_all()
        return list(
            db.execute(
                select(DebtLedgerEntry).where(
                    DebtLedgerEntry.customer_id == uuid.UUID(customer["id"])
                )
            ).scalars()
        )

    before = [(r.id, r.entry_type, str(r.amount)) for r in _rows()]
    _history(client, admin_headers, customer["id"])
    _history(client, admin_headers, customer["id"], page=1, page_size=1)
    after = [(r.id, r.entry_type, str(r.amount)) for r in _rows()]
    assert before == after
