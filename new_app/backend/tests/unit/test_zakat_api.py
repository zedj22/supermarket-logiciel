"""Zakat API tests: permissions, validation, save/list/get, payments, context.

Every surface is gated by the pre-existing ``report_financial`` scope
(admin + manager).  No new permission was introduced — this file proves
it, and that the cashier / role-less / anonymous denials carry the
right shape.

The formula itself is covered by ``test_zakat_domain.py``; here we only
assert the HTTP contract (status codes, idempotency, 422 shapes) plus
the "read-only w.r.t. the business" rule: nothing writes to products,
customers or sales.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.party import Customer
from app.services.auth import AuthService

TODAY = date.today()
LONG_AGO = date(TODAY.year - 2, 1, 1)

#: One complete, valid calculation payload (everything entered → final).
COMPLETE_PAYLOAD = {
    "zakat_date": TODAY.isoformat(),
    "hawl_start_date": LONG_AGO.isoformat(),
    "gold_price_per_gram": "27000",
    "use_imported_inventory": True,
    "cash_provided": True,
    "cash_items": [{"label": "Caisse", "amount": "500000"}],
    "collectible_receivables": "1000000",
    "liability_items": [{"label": "Fournisseur A", "amount": "1500000", "due": True}],
    "debt_treatment": "deduct_all",
}


# ── fixtures (Phase 14 report-permissions pattern) ───────────────────────


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
    # one product + one debtor so the context imports have data
    session.add(
        Product(name="Sucre 1kg", barcode="ZAK001", price=Decimal("100.000"),
                cost=Decimal("70.000"), avg_cost=Decimal("70.000"),
                quantity=Decimal("20.000"))
    )
    session.add(Customer(name="Omar", phone="0555000001", balance=Decimal("5000.000")))
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


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
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


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


READ_PATHS = ["/api/v1/zakat/context", "/api/v1/zakat"]


# ── permissions ──────────────────────────────────────────────────────────


@pytest.mark.parametrize("path", READ_PATHS)
def test_admin_can_read_every_zakat_surface(client, admin_headers, path):
    resp = client.get(path, headers=admin_headers)
    assert resp.status_code == 200, resp.text


@pytest.mark.parametrize("path", READ_PATHS)
def test_manager_can_read_every_zakat_surface(client, manager_headers, path):
    resp = client.get(path, headers=manager_headers)
    assert resp.status_code == 200, resp.text


@pytest.mark.parametrize("path", READ_PATHS)
def test_cashier_cannot_use_zakat(client, cashier_headers, path):
    resp = client.get(path, headers=cashier_headers)
    assert resp.status_code == 403, resp.text
    body = resp.json()["error"]
    assert body["code"] == "FORBIDDEN"
    assert body["details"]["required_permission"] == "report_financial"


@pytest.mark.parametrize("path", READ_PATHS)
def test_role_less_user_cannot_use_zakat(client, guest_headers, path):
    resp = client.get(path, headers=guest_headers)
    assert resp.status_code == 403, resp.text
    assert resp.json()["error"]["code"] == "FORBIDDEN"


@pytest.mark.parametrize("path", READ_PATHS)
def test_anonymous_request_is_unauthorised(client, path):
    resp = client.get(path)
    assert resp.status_code == 401, resp.text


def test_cashier_cannot_calculate_or_save(client, cashier_headers):
    resp = client.post(
        "/api/v1/zakat/calculate", json=COMPLETE_PAYLOAD, headers=cashier_headers
    )
    assert resp.status_code == 403, resp.text
    resp = client.post(
        "/api/v1/zakat",
        json={
            "client_request_id": "cashier-try-0001",
            "calculation": COMPLETE_PAYLOAD,
        },
        headers=cashier_headers,
    )
    assert resp.status_code == 403, resp.text


# ── context ──────────────────────────────────────────────────────────────


def test_context_carries_official_reference_and_imports(client, admin_headers):
    resp = client.get("/api/v1/zakat/context", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert Decimal(body["official_nisab_reference"]["amount"]) == Decimal("2295000")
    assert body["defaults"]["zakat_rate"] == "0.025"
    assert body["defaults"]["hawl_days"] == 354
    assert body["inventory"]["product_count"] == 1
    assert Decimal(body["inventory"]["total_market_value"]) == Decimal("2000.000")
    assert Decimal(body["receivables_reference"]["ledger_total"]) == Decimal("5000.000")
    assert body["receivables_reference"]["debtor_count"] == 1
    assert body["store_name"]  # settings singleton auto-created


def test_context_never_writes_to_business_tables(client, admin_headers, db):
    def counts():
        return {
            "products": db.query(Product).count(),
            "customers": db.query(Customer).count(),
        }

    before = counts()
    assert client.get("/api/v1/zakat/context", headers=admin_headers).status_code == 200
    db.expire_all()
    assert counts() == before


# ── calculate ────────────────────────────────────────────────────────────


def test_complete_payload_is_final_and_math_is_server_side(client, admin_headers):
    resp = client.post(
        "/api/v1/zakat/calculate", json=COMPLETE_PAYLOAD, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    result = resp.json()["result"]
    assert result["status"] == "final"
    # imported stock 20 × 100 = 2,000 + cash 500,000 + rec. 1,000,000
    # − debts 1,500,000 = net 2,000 (below the 2,295,000 nisab)
    assert Decimal(result["net_zakatable"]) == Decimal("2000.000")
    assert Decimal(result["nisab_amount"]) == Decimal("2295000.000")
    assert result["reaches_nisab"] is False
    assert Decimal(result["zakat_due"]) == Decimal("0.000")


def test_empty_payload_is_provisional_never_a_due_amount(client, admin_headers):
    resp = client.post(
        "/api/v1/zakat/calculate",
        json={"zakat_date": TODAY.isoformat(), "use_imported_inventory": False},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    result = resp.json()["result"]
    assert result["status"] == "provisional"
    assert result["zakat_due"] is None
    assert result["provisional_zakat_due"] is not None
    assert "nisab" in result["missing_fields"]


# ── validation (422 shapes) ──────────────────────────────────────────────


def test_hawl_start_after_zakat_date_is_rejected(client, admin_headers):
    payload = dict(COMPLETE_PAYLOAD, hawl_start_date="2027-01-01")
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_override_basis_requires_value_and_reason(client, admin_headers):
    payload = dict(
        COMPLETE_PAYLOAD,
        inventory_basis="override",
        inventory_override_value="123456",
        inventory_override_reason="",
    )
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 422, resp.text

    payload["inventory_override_reason"] = "inventaire tournant"
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 200, resp.text
    assert resp.json()["result"]["inventory_value"] == "123456.000"


def test_both_nisab_sources_are_rejected(client, admin_headers):
    payload = dict(COMPLETE_PAYLOAD, nisab_override="1000000")
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 422, resp.text


def test_negative_amounts_are_rejected(client, admin_headers):
    payload = dict(
        COMPLETE_PAYLOAD,
        cash_items=[{"label": "Caisse", "amount": "-1"}],
    )
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 422, resp.text


def test_amount_above_money_max_is_rejected(client, admin_headers):
    payload = dict(
        COMPLETE_PAYLOAD,
        collectible_receivables="9999999999999.999",
    )
    resp = client.post("/api/v1/zakat/calculate", json=payload, headers=admin_headers)
    assert resp.status_code == 422, resp.text


# ── save / history / get ─────────────────────────────────────────────────


def _save(client, headers, key="zakat-test-0001", payload=None, notes=None):
    body = {"client_request_id": key, "calculation": payload or COMPLETE_PAYLOAD}
    if notes is not None:
        body["notes"] = notes
    return client.post("/api/v1/zakat", json=body, headers=headers)


def test_save_creates_immutable_snapshot_with_stored_inputs(client, admin_headers):
    resp = _save(client, admin_headers, notes="fin d'année")
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["status"] == "final"
    assert body["notes"] == "fin d'année"
    assert Decimal(body["inputs"]["gold_price_per_gram"]) == Decimal("27000")
    assert body["payments_total"] == "0.000"

    detail = client.get(f"/api/v1/zakat/{body['id']}", headers=admin_headers)
    assert detail.status_code == 200, detail.text
    assert detail.json()["id"] == body["id"]
    assert detail.json()["result"]["net_zakatable"] == body["net_zakatable"]


def test_save_is_idempotent_on_client_request_id(client, admin_headers):
    first = _save(client, admin_headers, key="zakat-idem-0001")
    assert first.status_code == 201, first.text
    replay = _save(client, admin_headers, key="zakat-idem-0001")
    assert replay.status_code == 201, replay.text
    assert replay.json()["id"] == first.json()["id"]

    conflict = _save(
        client,
        admin_headers,
        key="zakat-idem-0001",
        payload=dict(COMPLETE_PAYLOAD, collectible_receivables="2000000"),
    )
    assert conflict.status_code == 409, conflict.text
    assert conflict.json()["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_history_lists_newest_first_and_paginates(client, admin_headers):
    for index in range(3):
        resp = _save(client, admin_headers, key=f"zakat-hist-000{index}")
        assert resp.status_code == 201, resp.text
    resp = client.get("/api/v1/zakat", params={"page": 1, "page_size": 2},
                      headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] >= 3
    assert body["page_size"] == 2
    assert len(body["items"]) == 2


def test_get_unknown_snapshot_is_404(client, admin_headers):
    resp = client.get(
        "/api/v1/zakat/00000000-0000-0000-0000-000000000000", headers=admin_headers
    )
    assert resp.status_code == 404, resp.text
    assert resp.json()["error"]["code"] == "ZAKAT_CALCULATION_NOT_FOUND"


# ── payments ─────────────────────────────────────────────────────────────


def test_payment_is_appended_and_never_edits_the_snapshot(client, admin_headers):
    saved = _save(client, admin_headers, key="zakat-pay-0001").json()
    calculation_id = saved["id"]
    net_before = saved["net_zakatable"]

    resp = client.post(
        f"/api/v1/zakat/{calculation_id}/payment",
        json={
            "client_request_id": "zakat-pay-0001-p1",
            "amount": "200000",
            "method": "cash",
            "note": "versement partiel",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert Decimal(body["payments_total"]) == Decimal("200000.000")
    assert body["net_zakatable"] == net_before
    assert len(body["payments"]) == 1
    assert body["payments"][0]["method"] == "cash"


def test_payment_idempotency_conflict(client, admin_headers):
    saved = _save(client, admin_headers, key="zakat-pay-0002").json()
    url = f"/api/v1/zakat/{saved['id']}/payment"
    payload = {"client_request_id": "zakat-pay-0002-p1", "amount": "100000"}
    assert client.post(url, json=payload, headers=admin_headers).status_code == 201
    replay = client.post(url, json=payload, headers=admin_headers)
    assert replay.status_code == 201, replay.text
    assert Decimal(replay.json()["payments_total"]) == Decimal("100000.000")

    conflict = client.post(
        url,
        json={"client_request_id": "zakat-pay-0002-p1", "amount": "99999"},
        headers=admin_headers,
    )
    assert conflict.status_code == 409, conflict.text


def test_payment_amount_must_be_positive(client, admin_headers):
    saved = _save(client, admin_headers, key="zakat-pay-0003").json()
    resp = client.post(
        f"/api/v1/zakat/{saved['id']}/payment",
        json={"client_request_id": "zakat-pay-0003-p1", "amount": "0"},
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text


def test_payment_on_unknown_calculation_is_404(client, admin_headers):
    resp = client.post(
        "/api/v1/zakat/00000000-0000-0000-0000-000000000000/payment",
        json={"client_request_id": "zakat-pay-9999-p1", "amount": "100"},
        headers=admin_headers,
    )
    assert resp.status_code == 404, resp.text


# ── read-only guarantee ──────────────────────────────────────────────────


def test_save_and_payment_do_not_touch_products_or_customers(
    client, admin_headers, db
):
    def counts():
        return {
            "products": db.query(Product).count(),
            "customers": db.query(Customer).count(),
        }

    before = counts()
    saved = _save(client, admin_headers, key="zakat-readonly-0001").json()
    client.post(
        f"/api/v1/zakat/{saved['id']}/payment",
        json={"client_request_id": "zakat-readonly-0001-p1", "amount": "1000"},
        headers=admin_headers,
    )
    db.expire_all()
    assert counts() == before
