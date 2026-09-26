"""Phase 9 tests — customer management API.

Covers:
- create/get/update/archive customer (structured errors, audit rows)
- balance is never client-writable (CRUD never moves it)
- archive restriction: outstanding balance => structured 409
- archived customers hidden by default, visible with include_archived
- RBAC: customer_view for reads, customer_manage for mutations
- validation: blank name, overlong name/phone, negative debt ceiling
- structured 404 (valid UUID, unknown customer) — never a generic 500
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
from app.models.audit import AuditLog
from app.models.party import Customer
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
    """Seeded session: roles/permissions + admin + a role-less guest."""
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    # No roles at all — must be denied on every customer scope.
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


def _payload(**overrides) -> dict:
    payload = {
        "name": "Alice Market",
        "phone": "0555000001",
        "address": "Rue 1",
        "debt_ceiling": "5000.000",
    }
    payload.update(overrides)
    return payload


def _create(client, headers, **overrides) -> dict:
    resp = client.post(
        "/api/v1/customers", json=_payload(**overrides), headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _make_customer(db, *, name="Direct Customer", balance=0) -> str:
    customer = Customer(name=name, balance=balance)
    db.add(customer)
    db.commit()
    return str(customer.id)


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


def test_create_customer(client, admin_headers, db):
    body = _create(client, admin_headers, name="New Store")
    assert body["name"] == "New Store"
    assert body["phone"] == "0555000001"
    assert Decimal(body["balance"]) == Decimal("0")
    assert Decimal(body["debt_ceiling"]) == Decimal("5000")
    assert body["is_archived"] is False

    stored = db.get(Customer, uuid.UUID(body["id"]))
    assert stored is not None
    assert stored.name == "New Store"


def test_create_trims_name(client, admin_headers):
    body = _create(client, admin_headers, name="   Padded Name   ")
    assert body["name"] == "Padded Name"


def test_create_blank_name_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/customers", json=_payload(name="   "), headers=admin_headers
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_create_overlong_name_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/customers", json=_payload(name="x" * 201), headers=admin_headers
    )
    assert resp.status_code == 422


def test_create_overlong_phone_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/customers", json=_payload(phone="1" * 31), headers=admin_headers
    )
    assert resp.status_code == 422


def test_create_negative_debt_ceiling_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/customers",
        json=_payload(debt_ceiling="-1.000"),
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_writes_audit(client, admin_headers, db):
    body = _create(client, admin_headers, name="Audited Customer")
    log = db.execute(
        select(AuditLog).where(
            AuditLog.entity_type == "customer",
            AuditLog.action == "create",
            AuditLog.entity_id == uuid.UUID(body["id"]),
        )
    ).scalar_one_or_none()
    assert log is not None
    assert log.user_id is not None


# ---------------------------------------------------------------------------
# Read / update
# ---------------------------------------------------------------------------


def test_get_customer(client, admin_headers):
    body = _create(client, admin_headers)
    resp = client.get(
        f"/api/v1/customers/{body['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["id"] == body["id"]


def test_get_unknown_customer_structured_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}", headers=admin_headers
    )
    assert resp.status_code == 404
    data = resp.json()
    assert data["error"]["code"] == "NOT_FOUND"
    assert data["error"]["message"]


def test_get_invalid_uuid_is_structured_422(client, admin_headers):
    resp = client.get("/api/v1/customers/not-a-uuid", headers=admin_headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_update_partial_fields(client, admin_headers):
    body = _create(client, admin_headers, name="Before Edit")
    resp = client.put(
        f"/api/v1/customers/{body['id']}",
        json={"phone": "0777999888"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Before Edit"  # untouched
    assert resp.json()["phone"] == "0777999888"


def test_update_cannot_move_balance(client, admin_headers, db):
    body = _create(client, admin_headers, name="Debtor")
    cid = uuid.UUID(body["id"])
    db.get(Customer, cid).balance = Decimal("250")
    db.commit()

    resp = client.put(
        f"/api/v1/customers/{cid}",
        json={"name": "Renamed", "balance": "9999"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    db.expire_all()
    stored = db.get(Customer, cid)
    assert stored.name == "Renamed"
    # balance never moves through CRUD — only ledger operations touch it
    assert Decimal(str(stored.balance)) == Decimal("250")


def test_update_blank_name_rejected(client, admin_headers):
    body = _create(client, admin_headers)
    resp = client.put(
        f"/api/v1/customers/{body['id']}",
        json={"name": "  "},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_update_writes_audit(client, admin_headers, db):
    body = _create(client, admin_headers)
    resp = client.put(
        f"/api/v1/customers/{body['id']}",
        json={"address": "New address"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    log = db.execute(
        select(AuditLog).where(
            AuditLog.entity_type == "customer",
            AuditLog.action == "update",
            AuditLog.entity_id == uuid.UUID(body["id"]),
        )
    ).scalar_one_or_none()
    assert log is not None


# ---------------------------------------------------------------------------
# Archive (soft delete)
# ---------------------------------------------------------------------------


def test_archive_free_customer(client, admin_headers, db):
    body = _create(client, admin_headers, name="Free To Go")
    cid = uuid.UUID(body["id"])

    resp = client.delete(f"/api/v1/customers/{cid}", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True

    db.expire_all()
    stored = db.get(Customer, cid)
    assert stored is not None  # soft delete: row preserved
    assert stored.archived_at is not None


def test_archive_blocked_with_outstanding_balance(client, admin_headers, db):
    body = _create(client, admin_headers, name="Owes Money")
    cid = uuid.UUID(body["id"])
    db.get(Customer, cid).balance = Decimal("150")
    db.commit()

    resp = client.delete(f"/api/v1/customers/{cid}", headers=admin_headers)
    assert resp.status_code == 409
    data = resp.json()
    assert data["error"]["code"] == "OUTSTANDING_DEBT"
    assert "balance" in data["error"]["details"]

    db.expire_all()
    assert db.get(Customer, cid).archived_at is None


def test_archive_is_idempotent(client, admin_headers):
    body = _create(client, admin_headers)
    first = client.delete(
        f"/api/v1/customers/{body['id']}", headers=admin_headers
    )
    second = client.delete(
        f"/api/v1/customers/{body['id']}", headers=admin_headers
    )
    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["is_archived"] is True


def test_archived_hidden_by_default_and_listable_when_included(
    client, admin_headers, db
):
    _create(client, admin_headers, name="Active One")
    gone = _create(client, admin_headers, name="Gone Customer")
    client.delete(f"/api/v1/customers/{gone['id']}", headers=admin_headers)

    default = client.get("/api/v1/customers", headers=admin_headers)
    assert default.status_code == 200
    names = [i["name"] for i in default.json()["items"]]
    assert "Gone Customer" not in names
    assert "Active One" in names

    included = client.get(
        "/api/v1/customers",
        params={"include_archived": True},
        headers=admin_headers,
    )
    names = [i["name"] for i in included.json()["items"]]
    assert "Gone Customer" in names


def test_has_debt_filter_returns_only_debtors(client, admin_headers, db):
    _create(client, admin_headers, name="Settled Customer")
    _make_customer(db, name="Debtor One", balance=100)
    _make_customer(db, name="Debtor Two", balance=Decimal("0.001"))
    _make_customer(db, name="Zero Balance", balance=0)

    debtors = client.get(
        "/api/v1/customers",
        params={"has_debt": True},
        headers=admin_headers,
    )
    assert debtors.status_code == 200
    body = debtors.json()
    assert body["total"] == 2
    assert {i["name"] for i in body["items"]} == {"Debtor One", "Debtor Two"}

    default = client.get("/api/v1/customers", headers=admin_headers)
    assert default.json()["total"] == 4


def test_has_debt_filter_requires_view_permission(client, guest_headers, db):
    resp = client.get(
        "/api/v1/customers",
        params={"has_debt": True},
        headers=guest_headers,
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_archive_writes_audit(client, admin_headers, db):
    body = _create(client, admin_headers, name="Audit Archive")
    cid = uuid.UUID(body["id"])
    db.get(Customer, cid).balance = Decimal("0")
    db.commit()
    client.delete(f"/api/v1/customers/{cid}", headers=admin_headers)
    log = db.execute(
        select(AuditLog).where(
            AuditLog.entity_type == "customer",
            AuditLog.action == "delete",
            AuditLog.entity_id == cid,
        )
    ).scalar_one_or_none()
    assert log is not None


# ---------------------------------------------------------------------------
# RBAC
# ---------------------------------------------------------------------------


def test_requires_authentication(client):
    assert client.get("/api/v1/customers").status_code == 401
    assert client.post("/api/v1/customers", json=_payload()).status_code == 401


def test_guest_without_roles_denied_everything(client, guest_headers):
    assert (
        client.get("/api/v1/customers", headers=guest_headers).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/customers", json=_payload(), headers=guest_headers
        ).status_code
        == 403
    )
    body = client.post(
        "/api/v1/customers", json=_payload(), headers=guest_headers
    ).json()
    assert body["error"]["code"] in {"FORBIDDEN", "AUTHORIZATION_ERROR"}
    assert body["error"]["details"]["required_permission"] == "customer_manage"


def test_cashier_can_manage_customers(client, cashier_headers):
    """Existing seed policy: cashier holds customer_view + customer_manage
    (Phase 2 seed: 'Customers (view + limited manage for debt)')."""
    created = _create(client, cashier_headers, name="Cashier Customer")
    resp = client.put(
        f"/api/v1/customers/{created['id']}",
        json={"address": "Updated by cashier"},
        headers=cashier_headers,
    )
    assert resp.status_code == 200


def test_cashier_can_read_debt_history(client, cashier_headers, db):
    cid = _make_customer(db, name="History Reader")
    resp = client.get(
        f"/api/v1/customers/{cid}/debts", headers=cashier_headers
    )
    assert resp.status_code == 200
    assert resp.json()["items"] == []
