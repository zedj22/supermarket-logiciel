"""Phase 14 tests — dashboard (§7 and §17.1.8 of the decision record).

One request must expose every KPI, the money fields must be byte-identical to
the §5 financial report for the same window (single-source-of-truth rule), and
the optional period must only shape ``recent_sales``/``top_products``.
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
from tests.unit import test_reports
from tests.unit.test_reports import _get, _login, _today

#: Shared §17.1 scenario fixture, re-exported so pytest can collect it here.
scenario = test_reports.scenario


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


def test_dashboard_bare_request_defaults_to_today(client, admin_headers, scenario):
    resp = client.get("/api/v1/dashboard", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["date_from"] == _today().isoformat()
    assert body["date_to"] == _today().isoformat()
    assert set(body) >= {
        "today_sales",
        "today_invoices",
        "today_net_profit",
        "today_expenses",
        "total_products",
        "total_customers",
        "stock_value",
        "low_stock_count",
        "customers_with_debt",
        "total_debt",
        "recent_sales",
        "top_products",
    }


def test_dashboard_kpis_match_financial_report(client, admin_headers, scenario):
    """§7 KPIs must be produced by the §5 formulas, not a second variant."""
    dash = _get(client, admin_headers, "/dashboard")
    fin = _get(client, admin_headers, "/reports/financial")

    assert Decimal(dash["today_sales"]) == Decimal(fin["sales_after_discounts"])
    assert dash["today_invoices"] == fin["invoice_count"]
    assert Decimal(dash["today_net_profit"]) == Decimal(fin["net_profit"])
    assert Decimal(dash["today_expenses"]) == Decimal(fin["expenses_total"])
    assert Decimal(dash["total_debt"]) == Decimal(fin["ar_outstanding"])
    assert dash["customers_with_debt"] == fin["customers_with_debt"]


def test_dashboard_scenarios_kpis(client, admin_headers, scenario):
    dash = _get(client, admin_headers, "/dashboard")

    assert Decimal(dash["today_sales"]) == Decimal("835.000")
    assert dash["today_invoices"] == 7
    assert Decimal(dash["today_net_profit"]) == Decimal("189.500")
    assert Decimal(dash["today_expenses"]) == Decimal("170.500")
    assert dash["total_products"] == 3  # packs are not products
    assert dash["total_customers"] == 1
    assert dash["customers_with_debt"] == 1
    assert Decimal(dash["total_debt"]) == Decimal("200.000")
    assert Decimal(dash["stock_value"]) > 0
    assert dash["low_stock_count"] >= 0


def test_dashboard_recent_sales_and_top_products(client, admin_headers, scenario):
    dash = _get(client, admin_headers, "/dashboard")

    assert 0 < len(dash["recent_sales"]) <= 5
    assert all(row["total"] for row in dash["recent_sales"])
    assert all(row["invoice_number"] for row in dash["recent_sales"])
    # the voided invoice is never "recent"
    assert dash["recent_sales"][0]["sale_id"] != scenario["sales"]["void"]["id"]
    assert all(
        row["sale_id"] != scenario["sales"]["void"]["id"]
        for row in dash["recent_sales"]
    )

    assert 0 < len(dash["top_products"]) <= 5
    top = dash["top_products"][0]
    assert top["name"] == "Alpha"
    assert Decimal(top["net_revenue"]) == Decimal("485.000")
    assert top["kind"] == "product"


def test_dashboard_period_shapes_detail_lists_not_kpis(
    client, admin_headers, scenario
):
    today = _today()
    empty = today - timedelta(days=1)

    yesterday = _get(
        client,
        admin_headers,
        "/dashboard",
        date_from=empty.isoformat(),
        date_to=empty.isoformat(),
    )
    assert yesterday["recent_sales"] == []
    assert yesterday["top_products"] == []
    # "today" KPIs are always today's (C1 UTC rule), whatever the period is
    assert Decimal(yesterday["today_sales"]) == Decimal("835.000")
    assert yesterday["today_invoices"] == 7


def test_dashboard_rejects_invalid_range(client, admin_headers, scenario):
    today = _today()
    resp = client.get(
        "/api/v1/dashboard",
        params={
            "date_from": today.isoformat(),
            "date_to": (today - timedelta(days=1)).isoformat(),
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "REPORT_INVALID_RANGE"
