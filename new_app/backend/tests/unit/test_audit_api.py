"""Audit trail slice A — read API + upgraded writer tests.

Covers:
- RBAC: 401 unauthenticated, 403 for manager/cashier, 200 for admin
  (audit_view scope), and NO mutating verb on the audit surface
- list: filters (module/action/outcome/user/device/entity/dates/free
  text), pagination math, time-descending order
- detail: parsed before/after + computed diff, 404 for unknown id
- summary: outcome + group counts
- honesty: legacy NULL outcome renders "unknown"; deleted actor does not
  erase history
- writers: login outcomes (success / wrong pin / unknown user), settings
  update module+snapshots, inventory adjustment audit row
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.seed import seed_roles_and_permissions
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.enums import AuditAction, AuditModule, AuditOutcome
from app.models.user import User
from app.services.auth import AuthService
from app.services.audit import AuditService


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


def _user_id_by_name(db, name: str) -> uuid.UUID:
    row = db.scalar(select(User).where(User.full_name == name))
    assert row is not None
    return row.id


def _seed_events(db, n: int = 5, **overrides) -> list[uuid.UUID]:
    service = AuditService(db)
    ids = []
    for i in range(n):
        overrides = dict(overrides)
        details = overrides.pop("details", f"seed event {i}")
        row = service.record(
            action=AuditAction.UPDATE,
            module=AuditModule.SETTINGS,
            entity_type="settings",
            details=details,
            **overrides,
        )
        db.flush()
        ids.append(row.id)
    db.commit()
    return ids


# ---------------------------------------------------------------------------
# RBAC / surface
# ---------------------------------------------------------------------------


def test_list_requires_authentication(client):
    assert client.get("/api/v1/audit").status_code == 401


def test_detail_requires_authentication(client):
    assert client.get(f"/api/v1/audit/{uuid.uuid4()}").status_code == 401


def test_summary_requires_authentication(client):
    assert client.get("/api/v1/audit/summary").status_code == 401


def test_manager_forbidden(client, manager_headers, db):
    _seed_events(db, 1)
    assert client.get("/api/v1/audit", headers=manager_headers).status_code == 403


def test_cashier_forbidden(client, cashier_headers, db):
    _seed_events(db, 1)
    assert client.get("/api/v1/audit", headers=cashier_headers).status_code == 403


def test_admin_allowed(client, admin_headers, db):
    _seed_events(db, 1)
    resp = client.get("/api/v1/audit", headers=admin_headers)
    assert resp.status_code == 200, resp.text


@pytest.mark.parametrize("method", ["POST", "PUT", "PATCH", "DELETE"])
def test_audit_surface_is_read_only(client, admin_headers, method, db):
    _seed_events(db, 1)
    resp = client.request(method, "/api/v1/audit", headers=admin_headers, json={})
    assert resp.status_code in (404, 405), resp.text


# ---------------------------------------------------------------------------
# List behaviour
# ---------------------------------------------------------------------------


def test_list_returns_login_and_seeded_events_newest_first(client, admin_headers, db):
    _seed_events(db, 3)
    resp = client.get("/api/v1/audit", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] >= 3
    assert body["page"] == 1
    times = [item["occurred_at"] for item in body["items"]]
    assert times == sorted(times, reverse=True)


def test_filter_by_module_action_outcome(client, admin_headers, db):
    service = AuditService(db)
    service.record(action=AuditAction.UPDATE, module=AuditModule.SETTINGS,
                   details="settings change")
    service.record(action=AuditAction.ADJUSTMENT, module=AuditModule.INVENTORY,
                   outcome=AuditOutcome.SUCCESS, details="stock up")
    service.record(action=AuditAction.LOGIN, module=AuditModule.AUTH,
                   outcome=AuditOutcome.FAILURE, details="bad pin")
    db.commit()

    resp = client.get(
        "/api/v1/audit",
        params={"module": "settings", "action": "update", "outcome": "success"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["module"] == "settings"
    assert body["items"][0]["details"] == "settings change"


def test_filter_by_user_and_free_text(client, admin_headers, db):
    admin_id = _user_id_by_name(db, "Admin")
    _seed_events(db, 2, user_id=admin_id, actor_name="Admin", reason="restock shelf")
    _seed_events(db, 1, details="unrelated row")
    resp = client.get(
        "/api/v1/audit",
        params={"user_id": str(admin_id), "q": "restock"},
        headers=admin_headers,
    )
    body = resp.json()
    assert body["total"] == 2
    assert all(item["actor_id"] == str(admin_id) for item in body["items"])


def test_pagination_math(client, admin_headers, db):
    _seed_events(db, 7)
    resp = client.get(
        "/api/v1/audit",
        params={"module": "settings", "page": 2, "page_size": 3},
        headers=admin_headers,
    )
    body = resp.json()
    assert body["page"] == 2
    assert body["page_size"] == 3
    assert body["pages"] == 3  # ceil(7/3)
    assert len(body["items"]) == 3


def test_date_range_filter(client, admin_headers, db):
    _seed_events(db, 2)
    resp = client.get(
        "/api/v1/audit",
        params={"date_from": "2000-01-01T00:00:00", "date_to": "2100-01-01T00:00:00"},
        headers=admin_headers,
    )
    assert resp.json()["total"] >= 2
    resp = client.get(
        "/api/v1/audit",
        params={"date_from": "2100-01-01T00:00:00"},
        headers=admin_headers,
    )
    assert resp.json()["total"] == 0


# ---------------------------------------------------------------------------
# Detail / summary
# ---------------------------------------------------------------------------


def test_detail_parses_snapshots_and_diff(client, admin_headers, db):
    service = AuditService(db)
    row = service.record(
        action=AuditAction.UPDATE,
        module=AuditModule.SETTINGS,
        entity_type="settings",
        before={"store_name": "Old"},
        after={"store_name": "New"},
    )
    db.commit()

    resp = client.get(f"/api/v1/audit/{row.id}", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["before"] == {"store_name": "Old"}
    assert body["after"] == {"store_name": "New"}
    assert body["diff"] == {"store_name": {"before": "Old", "after": "New"}}
    assert body["outcome"] == "success"
    assert body["recorded_at"] is not None


def test_detail_404_for_unknown_id(client, admin_headers):
    resp = client.get(f"/api/v1/audit/{uuid.uuid4()}", headers=admin_headers)
    assert resp.status_code == 404


def test_summary_counts(client, admin_headers, db):
    service = AuditService(db)
    service.record(action=AuditAction.UPDATE, module=AuditModule.SETTINGS,
                   outcome=AuditOutcome.SUCCESS, details="summary marker s")
    service.record(action=AuditAction.LOGIN, module=AuditModule.AUTH,
                   outcome=AuditOutcome.FAILURE, details="summary marker f")
    service.record(action=AuditAction.LOGIN, module=AuditModule.AUTH,
                   outcome=AuditOutcome.DENIED, details="summary marker d")
    db.commit()

    resp = client.get(
        "/api/v1/audit/summary",
        params={"q": "summary marker"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 3
    assert body["success"] == 1
    assert body["failure"] == 1
    assert body["denied"] == 1
    assert body["unknown"] == 0
    actions = {g["key"]: g["count"] for g in body["by_action"]}
    assert actions["update"] == 1
    assert actions["login"] == 2


# ---------------------------------------------------------------------------
# Honesty guarantees
# ---------------------------------------------------------------------------


def test_legacy_null_outcome_renders_unknown(client, admin_headers, db):
    # A pre-0031 row has outcome NULL. The model's Python-side default
    # fills "success" at ORM INSERT, so the legacy shape is reproduced by
    # NULLing the column afterwards — exactly what the migration leaves
    # for historical rows.
    row = AuditLog(action="update", entity_type="settings", details="legacy row")
    db.add(row)
    db.commit()
    row.outcome = None
    db.commit()
    resp = client.get(
        "/api/v1/audit",
        params={"q": "legacy row"},
        headers=admin_headers,
    )
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["outcome"] == "unknown"


def test_deleted_user_does_not_erase_history(client, admin_headers, db):
    service = AuthService(db)
    victim = service.create_user(name="Temp Tom", pin="4444")
    victim_id = victim.id
    AuditService(db).record(
        action=AuditAction.UPDATE,
        module=AuditModule.SETTINGS,
        user_id=victim_id,
        actor_name="Temp Tom",
        details="tom did this",
    )
    db.commit()

    service.delete_user(victim_id)
    db.commit()

    resp = client.get("/api/v1/audit", params={"q": "tom did this"},
                      headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1  # row survived
    assert body["items"][0]["actor_name"] == "Temp Tom"  # snapshot kept


# ---------------------------------------------------------------------------
# Writer instrumentation visible through the API
# ---------------------------------------------------------------------------


def test_login_success_writes_outcome_row(client, admin_headers, db):
    resp = client.get(
        "/api/v1/audit",
        params={"module": "auth", "action": "login", "outcome": "success"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] >= 1
    item = body["items"][0]
    assert item["actor_name"] == "Admin"
    assert item["session_id"] is not None
    assert item["ip_address"] is not None
    assert item["request_id"] is not None


def test_wrong_pin_login_writes_failure_row(client, db):
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Manager Mo")
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "9999"})
    assert resp.status_code == 401

    admin = _login(client, "Admin", "1234")
    listed = client.get(
        "/api/v1/audit",
        params={"module": "auth", "action": "login", "outcome": "failure"},
        headers=admin,
    ).json()
    assert listed["total"] >= 1
    assert listed["items"][0]["reason"] == "invalid_pin"
    assert listed["items"][0]["actor_name"] == "Manager Mo"


def test_unknown_user_login_writes_denied_row(client, db):
    fake_id = str(uuid.uuid4())
    resp = client.post("/api/v1/auth/login", json={"user_id": fake_id, "pin": "1234"})
    assert resp.status_code == 401

    admin = _login(client, "Admin", "1234")
    listed = client.get(
        "/api/v1/audit",
        params={"module": "auth", "action": "login", "outcome": "denied"},
        headers=admin,
    ).json()
    assert listed["total"] >= 1
    item = listed["items"][0]
    assert item["reason"] == "unknown_user"
    assert item["actor_id"] is None  # no fabricated actor


def test_pin_never_appears_in_audit_payloads(client, db):
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Manager Mo")
    client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "9999"})

    admin = _login(client, "Admin", "1234")
    rows = client.get("/api/v1/audit", params={"module": "auth"}, headers=admin).json()
    blob = str(rows)
    assert "9999" not in blob  # the attempted PIN is never stored


def test_settings_update_writes_module_and_snapshots(client, admin_headers, db):
    resp = client.put(
        "/api/v1/settings",
        json={"store_name": "Audited Store"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text

    listed = client.get(
        "/api/v1/audit",
        params={"module": "settings", "action": "update"},
        headers=admin_headers,
    ).json()
    assert listed["total"] >= 1
    item = listed["items"][0]
    assert item["entity_type"] == "settings"
    assert item["after"]["store_name"] == "Audited Store"
    assert "store_name" in item["diff"]


def test_inventory_adjust_writes_audit_row(client, admin_headers, db, engine):
    from app.models.catalog import Product

    product = Product(name="Audit Widget", quantity=10.0)
    db.add(product)
    db.commit()
    product_id = product.id

    resp = client.post(
        "/api/v1/inventory/adjust",
        json={
            "product_id": str(product_id),
            "operation": "increase",
            "quantity": 5,
            "reason": "delivery recount",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text

    listed = client.get(
        "/api/v1/audit",
        params={"module": "inventory", "action": "adjustment"},
        headers=admin_headers,
    ).json()
    assert listed["total"] >= 1
    item = listed["items"][0]
    assert item["reason"] == "delivery recount"
    assert item["entity_type"] == "product"
    assert item["entity_id"] == str(product_id)
    assert float(item["diff"]["quantity"]["before"]) == 10.0
    assert float(item["diff"]["quantity"]["after"]) == 15.0
