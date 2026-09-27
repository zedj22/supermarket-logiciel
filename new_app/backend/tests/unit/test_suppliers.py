"""Phase 11 tests — supplier master data, payables ledger, payments.

Covers:
- CRUD + soft archive (customer/legacy parity, names not unique)
- archive blocked by outstanding balance (409 OUTSTANDING_SUPPLIER_BALANCE)
- balance never client-writable (create/update payloads cannot set it)
- append-only ledger history with computed balance_after
- atomic payment: ledger append + balance update + audit in one commit
- overpayment rejected (legacy rule) — balance never goes negative
- idempotent payment replay via client_request_id (no double deduction)
- archived supplier cannot receive payments (422 SUPPLIER_ARCHIVED)
- unknown supplier => structured 404, never a generic 500
- RBAC: reads/ledger need supplier_view, mutations/payments supplier_manage
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
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.models.party import Supplier
from app.models.supplier_ledger import SupplierLedgerEntry
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


def _create_supplier(client, headers, **overrides) -> dict:
    payload = {"name": "Acme Supplies"}
    payload.update(overrides)
    resp = client.post("/api/v1/suppliers", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _seed_balance(db, supplier_id: str, amount: Decimal) -> None:
    """Seed an authoritative purchase ledger entry + cached balance."""
    supplier = db.get(Supplier, uuid.UUID(supplier_id))
    supplier.balance = float(amount)
    db.add(
        SupplierLedgerEntry(
            supplier_id=supplier.id,
            entry_type="purchase",
            amount=amount,
            note="seed",
        )
    )
    db.commit()


# ── CRUD + archive ──────────────────────────────────────────────────────


def test_create_supplier_starts_at_zero_balance(client, admin_headers, db):
    body = _create_supplier(
        client, admin_headers, phone="0555112233", email="ops@acme.dz"
    )
    assert Decimal(str(body["balance"])) == Decimal("0")
    assert body["is_archived"] is False
    assert body["email"] == "ops@acme.dz"

    rows = db.execute(
        select(AuditLog).where(AuditLog.entity_id == uuid.UUID(body["id"]))
    ).scalars().all()
    assert any(r.action == AuditAction.CREATE.value for r in rows)


def test_duplicate_supplier_names_allowed(client, admin_headers):
    first = _create_supplier(client, admin_headers, name="Twin Traders")
    second = _create_supplier(client, admin_headers, name="Twin Traders")
    assert first["id"] != second["id"]


def test_update_partial_only_sent_fields_change(client, admin_headers):
    body = _create_supplier(client, admin_headers, phone="0555")
    resp = client.put(
        f"/api/v1/suppliers/{body['id']}",
        json={"phone": "0666"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    updated = resp.json()
    assert updated["phone"] == "0666"
    assert updated["name"] == body["name"]


def test_balance_never_client_writable(client, admin_headers):
    body = _create_supplier(client, admin_headers)
    # StrictBaseModel ignores undeclared fields app-wide, and the service
    # filters writes to an allowlist — `balance` can never move here.
    resp = client.put(
        f"/api/v1/suppliers/{body['id']}",
        json={"balance": "999"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert Decimal(str(resp.json()["balance"])) == Decimal("0")

    fresh = client.get(
        f"/api/v1/suppliers/{body['id']}", headers=admin_headers
    ).json()
    assert Decimal(str(fresh["balance"])) == Decimal("0")


def test_archive_supplier_with_zero_balance(client, admin_headers):
    body = _create_supplier(client, admin_headers)
    resp = client.delete(
        f"/api/v1/suppliers/{body['id']}", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["is_archived"] is True

    default_list = client.get("/api/v1/suppliers", headers=admin_headers)
    assert body["id"] not in [i["id"] for i in default_list.json()["items"]]

    with_archived = client.get(
        "/api/v1/suppliers?include_archived=true", headers=admin_headers
    )
    assert body["id"] in [i["id"] for i in with_archived.json()["items"]]


def test_archive_blocked_by_outstanding_balance(
    client, admin_headers, db
):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("250.000"))

    resp = client.delete(
        f"/api/v1/suppliers/{body['id']}", headers=admin_headers
    )
    assert resp.status_code == 409, resp.text
    err = resp.json()["error"]
    assert err["code"] == "OUTSTANDING_SUPPLIER_BALANCE"
    assert err["details"]["balance"] == "250.000"

    # Row still active — archive rolled back with its audit row.
    fresh = client.get(
        f"/api/v1/suppliers/{body['id']}", headers=admin_headers
    ).json()
    assert fresh["is_archived"] is False


def test_list_search_matches_name_and_phone(client, admin_headers):
    _create_supplier(client, admin_headers, name="Delta Foods", phone="0777")
    _create_supplier(client, admin_headers, name="Echo Foods", phone="0888")

    by_name = client.get(
        "/api/v1/suppliers?q=Delta", headers=admin_headers
    ).json()
    assert by_name["total"] == 1

    by_phone = client.get(
        "/api/v1/suppliers?q=0888", headers=admin_headers
    ).json()
    assert by_phone["total"] == 1
    assert by_phone["items"][0]["name"] == "Echo Foods"


def test_unknown_supplier_returns_structured_404(client, admin_headers):
    missing = str(uuid.uuid4())
    resp = client.get(f"/api/v1/suppliers/{missing}", headers=admin_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


# ── Ledger history ──────────────────────────────────────────────────────


def test_ledger_history_newest_first_with_balance_after(
    client, admin_headers, db
):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("100.000"))
    # Phase 9 precedent: SQLite CURRENT_TIMESTAMP is second-precision —
    # separate the two entries past the tie window so ordering is the
    # contract under test, not uuid luck.
    time.sleep(1.05)

    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "40.000", "note": "settle"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text

    ledger = client.get(
        f"/api/v1/suppliers/{body['id']}/ledger", headers=admin_headers
    ).json()
    assert ledger["total"] == 2
    # Newest first: payment (balance_after 60) above the seeded purchase.
    assert ledger["items"][0]["entry_type"] == "payment"
    assert Decimal(str(ledger["items"][0]["balance_after"])) == Decimal("60")
    assert ledger["items"][1]["entry_type"] == "purchase"
    assert Decimal(str(ledger["items"][1]["balance_after"])) == Decimal("100")


def test_ledger_unknown_supplier_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/suppliers/{uuid.uuid4()}/ledger",
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


# ── Payments ────────────────────────────────────────────────────────────


def test_payment_atomic_ledger_balance_audit(client, admin_headers, db):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("500.000"))
    supplier_id = uuid.UUID(body["id"])

    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "200.000", "client_request_id": "pay-001"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    result = resp.json()
    assert Decimal(str(result["amount"])) == Decimal("200")
    assert Decimal(str(result["balance"])) == Decimal("300")
    assert result["idempotent_replay"] is False

    # Balance == ledger projection (cached == authoritative).
    entries = db.execute(
        select(SupplierLedgerEntry).where(
            SupplierLedgerEntry.supplier_id == supplier_id
        )
    ).scalars().all()
    assert len(entries) == 2
    projection = (
        sum(
            (
                Decimal(str(e.amount))
                for e in entries
                if e.entry_type == "purchase"
            ),
            Decimal("0"),
        )
        - sum(
            (
                Decimal(str(e.amount))
                for e in entries
                if e.entry_type == "payment"
            ),
            Decimal("0"),
        )
        - sum(
            (
                Decimal(str(e.amount))
                for e in entries
                if e.entry_type == "purchase_cancel"
            ),
            Decimal("0"),
        )
    )
    assert projection == Decimal("300")

    supplier = db.get(Supplier, supplier_id)
    assert Decimal(str(supplier.balance)) == Decimal("300")

    audits = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == supplier_id,
            AuditLog.action == AuditAction.PAYMENT.value,
        )
    ).scalars().all()
    assert len(audits) == 1
    assert "500.000 -> 300.000" in audits[0].details


def test_overpayment_rejected(client, admin_headers, db):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("100.000"))

    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "150.000"},
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()["error"]
    assert err["code"] == "SUPPLIER_PAYMENT_EXCEEDS_BALANCE"

    supplier = db.get(Supplier, uuid.UUID(body["id"]))
    assert Decimal(str(supplier.balance)) == Decimal("100")

    entries = db.execute(
        select(SupplierLedgerEntry).where(
            SupplierLedgerEntry.supplier_id == supplier.id
        )
    ).scalars().all()
    # Rejected operations roll back entirely: only the seed entry remains.
    assert len(entries) == 1


def test_payment_on_zero_balance_rejected(client, admin_headers, db):
    body = _create_supplier(client, admin_headers)
    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "10.000"},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "SUPPLIER_PAYMENT_EXCEEDS_BALANCE"


def test_payment_nonpositive_amount_rejected(client, admin_headers, db):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("100.000"))

    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "0"},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_payment_idempotent_replay_never_double_deducts(
    client, admin_headers, db
):
    body = _create_supplier(client, admin_headers)
    _seed_balance(db, body["id"], Decimal("300.000"))
    payload = {"amount": "100.000", "client_request_id": "pay-dup"}

    first = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json=payload,
        headers=admin_headers,
    )
    second = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json=payload,
        headers=admin_headers,
    )
    assert first.status_code == 200, first.text
    assert second.status_code == 200, second.text
    assert first.json()["id"] == second.json()["id"]
    assert second.json()["idempotent_replay"] is True
    assert Decimal(str(second.json()["balance"])) == Decimal("200")

    supplier = db.get(Supplier, uuid.UUID(body["id"]))
    assert Decimal(str(supplier.balance)) == Decimal("200")

    entries = db.execute(
        select(SupplierLedgerEntry).where(
            SupplierLedgerEntry.supplier_id == supplier.id,
            SupplierLedgerEntry.entry_type == "payment",
        )
    ).scalars().all()
    assert len(entries) == 1


def test_payment_on_archived_supplier_rejected(client, admin_headers, db):
    body = _create_supplier(client, admin_headers)
    client.delete(f"/api/v1/suppliers/{body['id']}", headers=admin_headers)

    resp = client.post(
        f"/api/v1/suppliers/{body['id']}/payments",
        json={"amount": "10.000"},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "SUPPLIER_ARCHIVED"


# ── RBAC ────────────────────────────────────────────────────────────────


def test_unauthenticated_supplier_endpoints_401(client):
    resp = client.get("/api/v1/suppliers")
    assert resp.status_code == 401


def test_cashier_denied_supplier_scopes(client, cashier_headers):
    assert (
        client.get("/api/v1/suppliers", headers=cashier_headers).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/suppliers",
            json={"name": "Nope"},
            headers=cashier_headers,
        ).status_code
        == 403
    )


def test_guest_without_roles_denied_supplier_endpoints(
    client, guest_headers
):
    assert (
        client.get("/api/v1/suppliers", headers=guest_headers).status_code
        == 403
    )
    body = {"name": "Ledger", "amount": "1.000"}
    resp = client.post(
        f"/api/v1/suppliers/{uuid.uuid4()}/payments",
        json=body,
        headers=guest_headers,
    )
    assert resp.status_code == 403
