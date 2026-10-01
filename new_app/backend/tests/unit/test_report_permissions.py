"""Phase 14 tests — permissions (§11 / §17.1.7 of the decision record).

Every report surface (ten ``/api/v1/reports/*`` endpoints plus ``/dashboard``)
is gated by the pre-existing ``report_financial`` scope: admin and manager read,
cashier and role-less users get ``403 FORBIDDEN`` with the required scope in
``details``, anonymous callers get ``401``.  No new permission was introduced.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.services.auth import AuthService
from tests.unit.test_reports import _login, _today

TODAY = _today()

#: (path, extra query params) for the eleven Phase 14 read surfaces.
ENDPOINTS: list[tuple[str, dict]] = [
    ("/api/v1/reports/financial", {}),
    ("/api/v1/reports/sales", {}),
    ("/api/v1/reports/products", {}),
    ("/api/v1/reports/categories", {}),
    ("/api/v1/reports/daily", {}),
    ("/api/v1/reports/hourly", {}),
    ("/api/v1/reports/peak-hours", {"lookback_days": 30}),
    ("/api/v1/reports/slow-moving", {"days": 30, "threshold": 0}),
    ("/api/v1/reports/voided", {}),
    ("/api/v1/reports/suppliers", {}),
    ("/api/v1/dashboard", {}),
]


def _params(extra: dict) -> dict:
    payload = {"date_from": TODAY.isoformat(), "date_to": TODAY.isoformat()}
    payload.update(extra)
    return payload


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
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
    service.create_user(name="Guest No Roles", pin="9999", role_names=[])
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
    return _login(client, "Admin", "1234")


@pytest.fixture()
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


# ── allowed roles ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(("path", "extra"), ENDPOINTS, ids=[p for p, _ in ENDPOINTS])
def test_admin_can_read_every_report(client, admin_headers, path, extra):
    resp = client.get(path, params=_params(extra), headers=admin_headers)
    assert resp.status_code == 200, f"{path}: {resp.text}"
    assert "error" not in resp.json()


@pytest.mark.parametrize(("path", "extra"), ENDPOINTS, ids=[p for p, _ in ENDPOINTS])
def test_manager_can_read_every_report(client, manager_headers, path, extra):
    resp = client.get(path, params=_params(extra), headers=manager_headers)
    assert resp.status_code == 200, f"{path}: {resp.text}"
    assert "error" not in resp.json()


# ── denied roles ──────────────────────────────────────────────────────────


@pytest.mark.parametrize(("path", "extra"), ENDPOINTS, ids=[p for p, _ in ENDPOINTS])
def test_cashier_cannot_read_reports(client, cashier_headers, path, extra):
    resp = client.get(path, params=_params(extra), headers=cashier_headers)
    assert resp.status_code == 403, f"{path}: {resp.text}"
    body = resp.json()["error"]
    assert body["code"] == "FORBIDDEN"
    assert body["details"]["required_permission"] == "report_financial"


@pytest.mark.parametrize(("path", "extra"), ENDPOINTS, ids=[p for p, _ in ENDPOINTS])
def test_role_less_user_cannot_read_reports(client, guest_headers, path, extra):
    resp = client.get(path, params=_params(extra), headers=guest_headers)
    assert resp.status_code == 403, f"{path}: {resp.text}"
    assert resp.json()["error"]["code"] == "FORBIDDEN"


@pytest.mark.parametrize(("path", "extra"), ENDPOINTS, ids=[p for p, _ in ENDPOINTS])
def test_anonymous_request_is_unauthorised(client, path, extra):
    resp = client.get(path, params=_params(extra))
    assert resp.status_code == 401, f"{path}: {resp.text}"


# ── shared conventions ────────────────────────────────────────────────────


def test_pagination_bounds_are_enforced(client, admin_headers):
    resp = client.get(
        "/api/v1/reports/sales",
        params={
            "date_from": TODAY.isoformat(),
            "date_to": TODAY.isoformat(),
            "page_size": 101,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    resp = client.get(
        "/api/v1/reports/sales",
        params={
            "date_from": TODAY.isoformat(),
            "date_to": TODAY.isoformat(),
            "page": 0,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text


def test_date_window_is_required_by_dated_endpoints(client, admin_headers):
    resp = client.get("/api/v1/reports/financial", headers=admin_headers)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    # undated endpoints stay usable with no date parameters at all
    resp = client.get("/api/v1/reports/peak-hours", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    assert len(resp.json()["items"]) == 24


def test_empty_window_returns_zeroed_money_not_errors(client, admin_headers):
    yesterday = _today() - timedelta(days=1)
    resp = client.get(
        "/api/v1/reports/financial",
        params={"date_from": yesterday.isoformat(), "date_to": yesterday.isoformat()},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert Decimal(body["net_sales"]) == Decimal("0.000")
    assert Decimal(body["gross_profit"]) == Decimal("0.000")
    assert Decimal(body["profit_margin_pct"]) == Decimal("0.00")
    assert body["invoice_count"] == 0
    assert Decimal(body["collected_total"]) + Decimal(body["debt_created"]) == Decimal(
        "0.000"
    )
