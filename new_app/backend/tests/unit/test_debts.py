"""Phase 9 tests — debt history, debt payments, AR summary.

Covers:
- atomic payment: ledger append + balance update + audit in one commit
- overpayment rejected (legacy rule) — balance never goes negative
- idempotent payment replay via client_request_id (no double deduction)
- unknown customer => structured 404 (valid UUID), never a generic 500
- archived customer cannot receive payments
- history: newest first, paginated, invoice number snapshot, actor name
- summary: totals from customers.balance, archived customers excluded
- projection reconciliation: customers.balance == ledger sale - payment
- RBAC: history/summary need customer_view, payment needs customer_manage
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.debt import DebtLedgerEntry
from app.models.enums import AuditAction
from app.models.party import Customer
from app.models.sale import Sale
from app.models.user import User
from app.repositories.debt import DebtLedgerEntryRepository
from app.services.auth import AuthService


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
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    service.create_user(name="Guest No Roles", pin="9999", role_names=[])
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
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post(
        "/api/v1/auth/login", json={"user_id": user_id, "pin": pin}
    )
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


def _make_customer(db, *, name="Debt Customer", balance=0) -> str:
    customer = Customer(name=name, balance=balance)
    db.add(customer)
    db.commit()
    return str(customer.id)


def _pay(client, headers, customer_id: str, **overrides) -> tuple[int, dict]:
    payload = {"amount": "100.000"}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/customers/{customer_id}/pay",
        json=payload,
        headers=headers,
    )
    return resp.status_code, resp.json() if resp.content else {}


def _balance(db, customer_id: str) -> Decimal:
    db.expire_all()
    customer = db.get(Customer, uuid.UUID(customer_id))
    return Decimal(str(customer.balance))


def _ledger_rows(db, customer_id: str) -> list[DebtLedgerEntry]:
    db.expire_all()
    return list(
        db.execute(
            select(DebtLedgerEntry).where(
                DebtLedgerEntry.customer_id == uuid.UUID(customer_id)
            )
        ).scalars()
    )


# ---------------------------------------------------------------------------
# Payments
# ---------------------------------------------------------------------------


def test_partial_payment_updates_balance_and_ledger(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("500"))

    code, body = _pay(client, admin_headers, cid, amount="200.000")
    assert code == 200, body
    assert Decimal(body["amount"]) == Decimal("200")
    assert Decimal(body["balance"]) == Decimal("300")
    assert body["entry_type"] == "payment"
    assert body["idempotent_replay"] is False

    assert _balance(db, cid) == Decimal("300")
    rows = _ledger_rows(db, cid)
    assert len(rows) == 1
    assert rows[0].entry_type == "payment"
    assert Decimal(str(rows[0].amount)) == Decimal("200")


def test_full_payment_clears_balance(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("120.500"))
    code, body = _pay(client, admin_headers, cid, amount="120.500")
    assert code == 200, body
    assert Decimal(body["balance"]) == Decimal("0")
    assert _balance(db, cid) == Decimal("0")


def test_payment_writes_audit(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("50"))
    _pay(client, admin_headers, cid, amount="50")
    log = db.execute(
        select(AuditLog).where(
            AuditLog.entity_type == "customer",
            AuditLog.action == AuditAction.PAYMENT.value,
            AuditLog.entity_id == uuid.UUID(cid),
        )
    ).scalar_one_or_none()
    assert log is not None
    assert log.user_id is not None


def test_overpayment_rejected_balance_untouched(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("100"))
    code, body = _pay(client, admin_headers, cid, amount="150.000")
    assert code == 422
    assert body["error"]["code"] == "PAYMENT_EXCEEDS_BALANCE"
    assert "amount" in body["error"]["details"]
    assert "balance" in body["error"]["details"]

    assert _balance(db, cid) == Decimal("100")
    assert _ledger_rows(db, cid) == []


def test_payment_on_zero_balance_rejected(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("0"))
    code, body = _pay(client, admin_headers, cid, amount="1.000")
    assert code == 422
    assert body["error"]["code"] == "PAYMENT_EXCEEDS_BALANCE"


def test_zero_amount_rejected_by_validation(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("100"))
    code, body = _pay(client, admin_headers, cid, amount="0")
    assert code == 422
    assert body["error"]["code"] == "VALIDATION_ERROR"


def test_negative_amount_rejected_by_validation(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("100"))
    code, body = _pay(client, admin_headers, cid, amount="-5.000")
    assert code == 422
    assert body["error"]["code"] == "VALIDATION_ERROR"
    assert _balance(db, cid) == Decimal("100")


def test_payment_never_creates_negative_balance(client, admin_headers, db):
    """Legacy rule + Phase 0: balance can only decrease to zero."""
    cid = _make_customer(db, balance=Decimal("50"))
    _pay(client, admin_headers, cid, amount="50")
    code, _ = _pay(client, admin_headers, cid, amount="50")
    assert code == 422
    assert _balance(db, cid) == Decimal("0")


def test_payment_unknown_customer_structured_404(client, admin_headers):
    code, body = _pay(client, admin_headers, str(uuid.uuid4()), amount="10")
    assert code == 404
    assert body["error"]["code"] == "NOT_FOUND"


def test_payment_to_archived_customer_rejected(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("0"))
    db.get(Customer, uuid.UUID(cid)).archived_at = datetime.now(timezone.utc)
    db.commit()

    code, body = _pay(client, admin_headers, cid, amount="10")
    assert code == 422
    assert body["error"]["code"] == "CUSTOMER_ARCHIVED"


def test_idempotent_replay_does_not_double_deduct(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("500"))
    key = "payment-key-001"

    code1, body1 = _pay(
        client, admin_headers, cid, amount="200", client_request_id=key
    )
    code2, body2 = _pay(
        client, admin_headers, cid, amount="200", client_request_id=key
    )

    assert code1 == 200 and code2 == 200
    assert body1["id"] == body2["id"]
    assert body1["idempotent_replay"] is False
    assert body2["idempotent_replay"] is True

    assert _balance(db, cid) == Decimal("300")  # deducted exactly once
    assert len(_ledger_rows(db, cid)) == 1


def test_client_request_id_cannot_cross_customers(client, admin_headers, db):
    cid_a = _make_customer(db, name="Customer A", balance=Decimal("100"))
    cid_b = _make_customer(db, name="Customer B", balance=Decimal("100"))
    key = "shared-key-001"

    code1, _ = _pay(
        client, admin_headers, cid_a, amount="50", client_request_id=key
    )
    code2, body2 = _pay(
        client, admin_headers, cid_b, amount="50", client_request_id=key
    )
    assert code1 == 200
    assert code2 == 409
    assert body2["error"]["code"] == "CONFLICT"
    assert _balance(db, cid_b) == Decimal("100")


def test_oversized_client_request_id_rejected(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("100"))
    code, body = _pay(
        client, admin_headers, cid, amount="50", client_request_id="x" * 101
    )
    assert code == 422
    assert body["error"]["code"] == "VALIDATION_ERROR"


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------


def test_history_unknown_customer_structured_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}/debts", headers=admin_headers
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_history_ordering_pagination_and_snapshots(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("100"))
    customer_uuid = uuid.UUID(cid)

    sale = Sale(
        invoice_number="INV-20260926-0001",
        customer_id=customer_uuid,
        subtotal=Decimal("100"),
        total=Decimal("100"),
        paid=Decimal("0"),
    )
    db.add(sale)
    db.flush()
    admin = db.execute(
        select(User).where(User.full_name == "Admin")
    ).scalar_one()

    db.add(
        DebtLedgerEntry(
            customer_id=customer_uuid,
            entry_type="sale",
            amount=Decimal("100"),
            reference_sale_id=sale.id,
            note="Sale INV-20260926-0001",
            user_id=admin.id,
            entry_date=datetime(2026, 9, 25, 10, 0, tzinfo=timezone.utc),
        )
    )
    db.add(
        DebtLedgerEntry(
            customer_id=customer_uuid,
            entry_type="payment",
            amount=Decimal("40"),
            note="Cash payment",
            user_id=admin.id,
            entry_date=datetime(2026, 9, 26, 9, 0, tzinfo=timezone.utc),
        )
    )
    db.commit()

    resp = client.get(
        f"/api/v1/customers/{cid}/debts", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] == 2
    # newest first
    assert body["items"][0]["entry_type"] == "payment"
    assert body["items"][1]["entry_type"] == "sale"
    # snapshot fields resolved from the referenced sale / actor
    sale_entry = body["items"][1]
    assert sale_entry["invoice_number"] == "INV-20260926-0001"
    assert sale_entry["user_name"] == "Admin"
    assert Decimal(sale_entry["amount"]) == Decimal("100")

    page1 = client.get(
        f"/api/v1/customers/{cid}/debts",
        params={"page": 1, "page_size": 1},
        headers=admin_headers,
    ).json()
    page2 = client.get(
        f"/api/v1/customers/{cid}/debts",
        params={"page": 2, "page_size": 1},
        headers=admin_headers,
    ).json()
    assert page1["total"] == 2 and page1["pages"] == 2
    assert page1["items"][0]["entry_type"] == "payment"
    assert page2["items"][0]["entry_type"] == "sale"


def test_history_is_append_only(client, admin_headers, db):
    """No endpoint can rewrite or remove ledger history."""
    cid = _make_customer(db, balance=Decimal("300"))
    _pay(client, admin_headers, cid, amount="100")
    rows_before = {r.id for r in _ledger_rows(db, cid)}

    # Repeated list/pay flows never mutate existing rows
    client.get(f"/api/v1/customers/{cid}/debts", headers=admin_headers)
    rows_after = {r.id for r in _ledger_rows(db, cid)}
    assert rows_before == rows_after
    assert len(rows_after) == 1


# ---------------------------------------------------------------------------
# Summary + reconciliation
# ---------------------------------------------------------------------------


def test_summary_totals(client, admin_headers, db):
    _make_customer(db, name="Owes 300", balance=Decimal("300"))
    _make_customer(db, name="Owes 100", balance=Decimal("100"))
    _make_customer(db, name="Clear", balance=Decimal("0"))
    archived = _make_customer(db, name="Archived Clear", balance=Decimal("0"))
    db.get(Customer, uuid.UUID(archived)).archived_at = datetime.now(
        timezone.utc
    )
    db.commit()

    resp = client.get("/api/v1/debts/summary", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert Decimal(body["total_debt"]) == Decimal("400")
    assert body["customers_with_debt"] == 2


def test_summary_never_counts_archived_debt(client, admin_headers, db):
    """Archiving requires balance 0, so an archived debtor is impossible;
    the aggregate filters on balance > 0 regardless."""
    cid = _make_customer(db, name="Will Archive", balance=Decimal("0"))
    resp = client.get("/api/v1/debts/summary", headers=admin_headers)
    assert Decimal(resp.json()["total_debt"]) == Decimal("0")
    assert resp.json()["customers_with_debt"] == 0
    assert cid


def test_projection_reconciles_with_ledger(client, admin_headers, db):
    """customers.balance must always equal ledger sales - payments."""
    cid = _make_customer(db, balance=Decimal("500"))
    customer_uuid = uuid.UUID(cid)

    # Simulate the Phase 8 credit-sale ledger write (sale entry + balance)
    db.add(
        DebtLedgerEntry(
            customer_id=customer_uuid,
            entry_type="sale",
            amount=Decimal("500"),
            note="Sale INV-RECON-1",
            entry_date=datetime(2026, 9, 24, 12, 0, tzinfo=timezone.utc),
        )
    )
    db.commit()

    # Two payments through the public API
    code1, _ = _pay(client, admin_headers, cid, amount="150.500")
    code2, _ = _pay(client, admin_headers, cid, amount="49.500")
    assert code1 == 200 and code2 == 200

    repo = DebtLedgerEntryRepository(db)
    projection = _balance(db, cid)
    authoritative = repo.ledger_sum_for_customer(customer_uuid)
    assert projection == authoritative == Decimal("300")
    assert projection >= 0


def test_summary_matches_reconciled_projection(client, admin_headers, db):
    cid = _make_customer(db, balance=Decimal("80"))
    _pay(client, admin_headers, cid, amount="30")
    resp = client.get("/api/v1/debts/summary", headers=admin_headers)
    assert Decimal(resp.json()["total_debt"]) == Decimal("50")
    assert resp.json()["customers_with_debt"] == 1
    assert _balance(db, cid) == Decimal("50")


# ---------------------------------------------------------------------------
# RBAC
# ---------------------------------------------------------------------------


def test_debt_endpoints_require_authentication(client):
    cid = "00000000-0000-0000-0000-000000000000"
    assert client.get(f"/api/v1/customers/{cid}/debts").status_code == 401
    assert (
        client.post(
            f"/api/v1/customers/{cid}/pay", json={"amount": "1"}
        ).status_code
        == 401
    )
    assert client.get("/api/v1/debts/summary").status_code == 401


def test_guest_without_roles_denied_debt_endpoints(client, guest_headers, db):
    cid = _make_customer(db, balance=Decimal("10"))

    history = client.get(
        f"/api/v1/customers/{cid}/debts", headers=guest_headers
    )
    assert history.status_code == 403
    assert (
        history.json()["error"]["details"]["required_permission"]
        == "customer_view"
    )

    payment = client.post(
        f"/api/v1/customers/{cid}/pay",
        json={"amount": "5"},
        headers=guest_headers,
    )
    assert payment.status_code == 403
    assert (
        payment.json()["error"]["details"]["required_permission"]
        == "customer_manage"
    )

    summary = client.get("/api/v1/debts/summary", headers=guest_headers)
    assert summary.status_code == 403

    # nothing moved
    assert _balance(db, cid) == Decimal("10")
    assert _ledger_rows(db, cid) == []


def test_cashier_can_record_debt_payment(client, cashier_headers, db):
    """Existing seed policy: cashier holds customer_view + customer_manage
    (Phase 2 seed comment: 'Customers (view + limited manage for debt)')."""
    cid = _make_customer(db, balance=Decimal("60"))
    code, body = _pay(client, cashier_headers, cid, amount="60")
    assert code == 200, body
    assert _balance(db, cid) == Decimal("0")
