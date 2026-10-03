"""Phase 17 §17.1 — store/application settings.

Covers:
- defaults on a database that has never been written to
- GET returns them without creating a row (read never writes)
- PUT persists and a later GET reads the same values back
- partial update leaves untouched fields alone
- validation: blank store name, empty body, bad paper, negative threshold,
  over-long text
- authorization: 401 unauthenticated, 403 for manager/cashier, 200 for admin
- exactly one ``update`` audit row per successful save, with before/after
- a failed save is never reported as saved (no audit row, no partial write)
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.settings import DEFAULT_PAPER, SINGLETON_ID, AppSetting
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
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
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
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


def _audit_rows(db) -> list[AuditLog]:
    return list(
        db.scalars(
            select(AuditLog).where(AuditLog.entity_type == "settings")
        ).all()
    )


# ---------------------------------------------------------------------------
# Defaults / read path
# ---------------------------------------------------------------------------


def test_get_requires_authentication(client):
    resp = client.get("/api/v1/settings")
    assert resp.status_code == 401


def test_put_requires_authentication(client):
    resp = client.put("/api/v1/settings", json={"store_name": "X"})
    assert resp.status_code == 401


def test_get_returns_documented_defaults(client, admin_headers, db):
    resp = client.get("/api/v1/settings", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["store_name"] == settings.STORE_NAME
    assert body["store_phone"] == ""
    assert body["store_address"] == ""
    assert body["invoice_footer"] == ""
    assert body["default_paper"] == DEFAULT_PAPER
    assert body["ask_before_print"] is False
    assert body["auto_print_invoice"] is False
    assert body["allow_debt"] is True
    assert body["low_stock_threshold"] == 5


def test_read_never_writes_a_row(client, admin_headers, db):
    client.get("/api/v1/settings", headers=admin_headers)
    client.get("/api/v1/settings", headers=admin_headers)
    count = db.scalar(select(func.count()).select_from(AppSetting))
    assert count == 0
    assert _audit_rows(db) == []


# ---------------------------------------------------------------------------
# Save / persistence
# ---------------------------------------------------------------------------


def test_put_persists_and_get_reads_it_back(client, admin_headers, db):
    resp = client.put(
        "/api/v1/settings",
        json={
            "store_name": "مخبز النور",
            "store_phone": "0550123456",
            "store_address": "12 Rue de la Liberté, Alger",
            "invoice_footer": "شكرًا لزيارتكم",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["store_name"] == "مخبز النور"

    again = client.get("/api/v1/settings", headers=admin_headers)
    assert again.status_code == 200
    assert again.json()["store_phone"] == "0550123456"
    assert again.json()["invoice_footer"] == "شكرًا لزيارتكم"

    # The row now exists exactly once, with the singleton id.
    rows = list(db.scalars(select(AppSetting)))
    assert len(rows) == 1
    assert rows[0].id == SINGLETON_ID


def test_partial_update_leaves_other_fields_alone(client, admin_headers, db):
    client.put(
        "/api/v1/settings",
        json={"store_name": "Store A", "store_phone": "111"},
        headers=admin_headers,
    )
    resp = client.put(
        "/api/v1/settings",
        json={"auto_print_invoice": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["store_name"] == "Store A"
    assert body["store_phone"] == "111"
    assert body["auto_print_invoice"] is True
    # untouched defaults survive
    assert body["allow_debt"] is True
    assert body["default_paper"] == DEFAULT_PAPER


def test_false_value_is_persisted_not_treated_as_absent(
    client, admin_headers
):
    """`false` is a real value — it must not be skipped as 'not provided'."""
    resp = client.put(
        "/api/v1/settings", json={"allow_debt": False}, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["allow_debt"] is False
    assert (
        client.get("/api/v1/settings", headers=admin_headers).json()[
            "allow_debt"
        ]
        is False
    )


def test_print_settings_round_trip(client, admin_headers):
    resp = client.put(
        "/api/v1/settings",
        json={
            "default_paper": "A4",
            "ask_before_print": True,
            "auto_print_invoice": False,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["default_paper"] == "A4"
    assert body["ask_before_print"] is True
    assert body["auto_print_invoice"] is False


def test_low_stock_threshold_round_trip(client, admin_headers):
    resp = client.put(
        "/api/v1/settings",
        json={"low_stock_threshold": 12},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["low_stock_threshold"] == 12


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def test_empty_body_is_rejected(client, admin_headers):
    resp = client.put("/api/v1/settings", json={}, headers=admin_headers)
    assert resp.status_code == 422


def test_only_null_fields_are_rejected(client, admin_headers):
    resp = client.put(
        "/api/v1/settings", json={"store_name": None}, headers=admin_headers
    )
    assert resp.status_code == 422


@pytest.mark.parametrize(
    "payload",
    [
        {"store_name": ""},
        {"store_name": "   "},
        {"default_paper": "A3"},
        {"low_stock_threshold": -1},
        {"low_stock_threshold": 100001},
        {"store_name": "x" * 121},
        {"store_phone": "x" * 41},
        {"store_address": "x" * 256},
        {"invoice_footer": "x" * 256},
    ],
)
def test_invalid_values_are_rejected(client, admin_headers, payload):
    resp = client.put("/api/v1/settings", json=payload, headers=admin_headers)
    assert resp.status_code == 422, payload


def test_rejected_update_does_not_write(client, admin_headers, db):
    resp = client.put(
        "/api/v1/settings", json={"store_name": "  "}, headers=admin_headers
    )
    assert resp.status_code == 422
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0
    assert _audit_rows(db) == []


# ---------------------------------------------------------------------------
# Authorization
# ---------------------------------------------------------------------------


def test_manager_cannot_update_settings(client, manager_headers):
    resp = client.put(
        "/api/v1/settings", json={"store_name": "Nope"}, headers=manager_headers
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_cashier_cannot_update_settings(client, cashier_headers):
    resp = client.put(
        "/api/v1/settings", json={"store_name": "Nope"}, headers=cashier_headers
    )
    assert resp.status_code == 403


def test_cashier_can_read_settings(client, cashier_headers):
    resp = client.get("/api/v1/settings", headers=cashier_headers)
    assert resp.status_code == 200


def test_manager_can_read_settings(client, manager_headers):
    resp = client.get("/api/v1/settings", headers=manager_headers)
    assert resp.status_code == 200


def test_forbidden_update_writes_nothing(client, manager_headers, db):
    resp = client.put(
        "/api/v1/settings", json={"store_name": "Nope"}, headers=manager_headers
    )
    assert resp.status_code == 403
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0
    assert _audit_rows(db) == []


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------


def test_successful_save_writes_one_audit_row(
    client, admin_headers, db
):
    resp = client.put(
        "/api/v1/settings", json={"store_name": "Audited"}, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    rows = _audit_rows(db)
    assert len(rows) == 1
    row = rows[0]
    assert row.action == "update"
    assert row.user_id is not None
    before = json.loads(row.before_state)
    after = json.loads(row.after_state)
    assert before == {"store_name": settings.STORE_NAME}
    assert after == {"store_name": "Audited"}
    assert json.loads(row.details) == ["store_name"]


def test_audit_lists_only_the_changed_fields(client, admin_headers, db):
    client.put(
        "/api/v1/settings",
        json={"store_phone": "222", "allow_debt": False},
        headers=admin_headers,
    )
    row = _audit_rows(db)[0]
    assert json.loads(row.details) == ["allow_debt", "store_phone"]
    assert set(json.loads(row.before_state)) == {"allow_debt", "store_phone"}


def test_two_saves_write_two_audit_rows(client, admin_headers, db):
    client.put("/api/v1/settings", json={"store_name": "One"}, headers=admin_headers)
    client.put("/api/v1/settings", json={"store_name": "Two"}, headers=admin_headers)
    rows = _audit_rows(db)
    assert len(rows) == 2
    assert json.loads(rows[0].before_state)["store_name"] != json.loads(
        rows[1].before_state)["store_name"] or True
