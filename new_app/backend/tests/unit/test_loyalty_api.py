"""Phase E — loyalty API surface.

Covers the REST contract added in Phase E, one area per section:

- settings: authenticated read of approved defaults (read never writes),
  admin-only partial update with domain validation and one audit row
- preview: server-computed checkout preview — the server decides the
  reward (percent + DA discount), amount due, reward view and earned
  rewards; client input is only cart inputs (customer, gross total,
  selected percent), never a claimed balance or discount
- lookup: phone lookup by digits-only comparison (no Algerian format
  rewriting, duplicates come back as a disambiguation list) and opaque
  ``KLICK:C:<uuid>`` QR resolution (invalid/unknown/archived handled)
- balance/history: read-never-writes contract, 404 on unknown customer,
  newest-first paginated ledger with running balances
- adjustment: SETTINGS_MANAGE only, mandatory reason + client_request_id,
  idempotent replay, 409 on key reuse with a different payload, refusal
  of any negative result (ledger + audit in one transaction)
"""

from __future__ import annotations

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
from app.models.audit import AuditLog
from app.models.loyalty import (
    LoyaltyAccount,
    LoyaltyLedgerEntry,
    LoyaltySetting,
)
from app.services.auth import AuthService

# ---------------------------------------------------------------------------
# Fixtures (mirrors tests/unit/test_settings.py — three-role pattern)
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _create_customer(
    client, headers, *, name: str = "Amine", phone: str | None = None
) -> dict:
    payload: dict = {"name": name}
    if phone is not None:
        payload["phone"] = phone
    resp = client.post("/api/v1/customers", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _adjust(
    client,
    headers,
    customer_id: str,
    *,
    points: int | None = None,
    cashback: str | None = None,
    reason: str = "good customer",
    key: str = "adj-1",
):
    payload: dict = {"reason": reason, "client_request_id": key}
    if points is not None:
        payload["points_delta"] = points
    if cashback is not None:
        payload["cashback_delta"] = cashback
    return client.post(
        f"/api/v1/customers/{customer_id}/loyalty/adjustment",
        json=payload,
        headers=headers,
    )


def _balance(client, headers, customer_id: str) -> dict:
    resp = client.get(
        f"/api/v1/customers/{customer_id}/loyalty", headers=headers
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _money(value) -> Decimal:
    return Decimal(str(value))


def _setting_rows(db) -> int:
    return db.scalar(select(func.count()).select_from(LoyaltySetting)) or 0


def _account_rows(db) -> int:
    return db.scalar(select(func.count()).select_from(LoyaltyAccount)) or 0


def _ledger_rows(db) -> int:
    return db.scalar(select(func.count()).select_from(LoyaltyLedgerEntry)) or 0


def _audit_rows(db, *, action: str | None = None) -> list[AuditLog]:
    stmt = select(AuditLog)
    if action is not None:
        stmt = stmt.where(AuditLog.action == action)
    return list(db.scalars(stmt).all())


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------


def test_settings_get_requires_authentication(client):
    assert client.get("/api/v1/loyalty/settings").status_code == 401


def test_settings_put_requires_authentication(client):
    resp = client.put(
        "/api/v1/loyalty/settings", json={"points_rate": 0.02}
    )
    assert resp.status_code == 401


def test_get_returns_approved_defaults(client, admin_headers, db):
    resp = client.get("/api/v1/loyalty/settings", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["points_enabled"] is True
    assert _money(body["points_rate"]) == Decimal("0.01")
    assert body["cashback_enabled"] is False
    assert _money(body["cashback_rate"]) == Decimal("1.000")
    assert _money(body["max_reward_discount_percent"]) == Decimal("20.000")
    assert body["earn_on_debt_settlement"] is True


def test_settings_read_never_writes_a_row(client, admin_headers, db):
    client.get("/api/v1/loyalty/settings", headers=admin_headers)
    client.get("/api/v1/loyalty/settings", headers=admin_headers)
    assert _setting_rows(db) == 0
    assert _audit_rows(db, action="update") == []


def test_admin_can_update_settings_round_trip(client, admin_headers, db):
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"points_rate": 0.02, "max_reward_discount_percent": "30"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert _money(resp.json()["points_rate"]) == Decimal("0.02")

    again = client.get("/api/v1/loyalty/settings", headers=admin_headers)
    assert _money(again.json()["points_rate"]) == Decimal("0.02")
    assert _money(again.json()["max_reward_discount_percent"]) == Decimal(
        "30.000"
    )
    assert _setting_rows(db) == 1
    # untouched defaults survive
    assert again.json()["cashback_enabled"] is False
    assert _money(again.json()["cashback_rate"]) == Decimal("1.000")


def test_settings_partial_update_preserves_other_fields(
    client, admin_headers
):
    client.put(
        "/api/v1/loyalty/settings",
        json={"points_rate": 0.05},
        headers=admin_headers,
    )
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"cashback_enabled": True},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["points_rate"]) == Decimal("0.05")
    assert body["cashback_enabled"] is True
    assert body["earn_on_debt_settlement"] is True


@pytest.mark.parametrize(
    "payload",
    [
        {"points_rate": "-0.1"},
        {"cashback_rate": "-1"},
        {"max_reward_discount_percent": -1},
        {"max_reward_discount_percent": 100.001},
    ],
)
def test_invalid_settings_are_rejected(client, admin_headers, payload):
    resp = client.put(
        "/api/v1/loyalty/settings", json=payload, headers=admin_headers
    )
    assert resp.status_code == 422, payload
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_rejected_settings_update_writes_nothing(
    client, admin_headers, db
):
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"max_reward_discount_percent": -1},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert _setting_rows(db) == 0
    assert _audit_rows(db, action="update") == []


def test_manager_cannot_update_settings(client, manager_headers):
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"points_rate": 0.09},
        headers=manager_headers,
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_cashier_cannot_update_settings(client, cashier_headers):
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"points_rate": 0.09},
        headers=cashier_headers,
    )
    assert resp.status_code == 403


def test_cashier_and_manager_can_read_settings(client, cashier_headers, manager_headers):
    assert (
        client.get("/api/v1/loyalty/settings", headers=cashier_headers).status_code
        == 200
    )
    assert (
        client.get("/api/v1/loyalty/settings", headers=manager_headers).status_code
        == 200
    )


def test_settings_update_writes_one_audit_row(client, admin_headers, db):
    resp = client.put(
        "/api/v1/loyalty/settings",
        json={"points_rate": 0.03},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    rows = _audit_rows(db, action="update")
    assert len(rows) == 1
    row = rows[0]
    assert row.module == "settings"
    assert row.entity_type == "loyalty_settings"
    assert row.user_id is not None


# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------


def test_preview_requires_authentication(client):
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={"customer_id": str(uuid.uuid4()), "gross_total": "100"},
    )
    assert resp.status_code == 401


def test_preview_unknown_customer_is_404(client, admin_headers):
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={"customer_id": str(uuid.uuid4()), "gross_total": "100"},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_preview_basic_no_reward(client, admin_headers, db):
    customer = _create_customer(client, admin_headers)
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 0,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["gross_total"]) == Decimal("100")
    assert _money(body["reward_percent"]) == 0
    assert _money(body["reward_discount"]) == 0
    assert _money(body["amount_due"]) == Decimal("100")
    # no account yet -> nothing to spend, balances are zero
    assert body["available_rewards"] == 0
    assert _money(body["remaining_points"]) == 0
    assert _money(body["points_balance"]) == 0
    assert _money(body["cashback_balance"]) == 0
    # the owner's cap travels with every preview so the POS builds its
    # percent selector without a second settings read
    assert _money(body["max_reward_discount_percent"]) == Decimal("20.000")
    # default rules: 0.01 pt per DA, cashback off
    assert _money(body["points_earned"]) == Decimal("1")
    assert _money(body["cashback_earned"]) == 0
    # a read must never create rows
    assert _account_rows(db) == 0
    assert _setting_rows(db) == 0


def test_preview_selects_reward_within_cap(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    granted = _adjust(client, admin_headers, customer["id"], points=1000)
    assert granted.status_code == 200, granted.text

    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "500",
            "reward_percent": 20,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["reward_percent"]) == Decimal("20")
    # server derives the money: 20% of 500 DA, amount due net of it
    assert _money(body["reward_discount"]) == Decimal("100")
    assert _money(body["amount_due"]) == Decimal("400")
    # 1000 points = 10 whole rewards, no points left over
    assert body["available_rewards"] == 10
    assert _money(body["remaining_points"]) == 0
    assert _money(body["points_balance"]) == Decimal("1000")
    # earn applies to the amount due, not the gross cart
    assert _money(body["points_earned"]) == Decimal("4")


def test_preview_rejects_when_no_reward_available(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=10)
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 20,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()["error"]
    assert err["code"] == "VALIDATION_ERROR"
    assert "no reward available" in err["message"]
    assert "available_rewards" in err["details"]


def test_preview_rejects_when_points_disabled(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=100)
    client.put(
        "/api/v1/loyalty/settings",
        json={"points_enabled": False},
        headers=admin_headers,
    )
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 10,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert "disabled" in resp.json()["error"]["message"]


def test_preview_cap_collapses_when_points_disabled(client, admin_headers):
    """A disabled feature reports cap 0 -> empty selector, one read."""
    customer = _create_customer(client, admin_headers)
    client.put(
        "/api/v1/loyalty/settings",
        json={"points_enabled": False},
        headers=admin_headers,
    )
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={"customer_id": customer["id"], "gross_total": "100"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert _money(resp.json()["max_reward_discount_percent"]) == 0


def test_preview_rejects_percent_above_cap(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=1000)
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 30,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422, resp.text
    err = resp.json()["error"]
    assert err["code"] == "VALIDATION_ERROR"
    assert "exceeds the owner maximum" in err["message"]


def test_preview_rejects_when_cap_parks_redemption(client, admin_headers):
    """Cap 0 = redemption parked: any selected percent is rejected."""
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=1000)
    client.put(
        "/api/v1/loyalty/settings",
        json={"max_reward_discount_percent": 0},
        headers=admin_headers,
    )
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 10,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert "exceeds the owner maximum" in resp.json()["error"]["message"]


def test_preview_rejects_percent_above_100(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 101,
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_preview_ignores_client_supplied_balances(client, admin_headers):
    """Injected balances/values in the request are ignored, not trusted."""
    customer = _create_customer(client, admin_headers)
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={
            "customer_id": customer["id"],
            "gross_total": "100",
            "reward_percent": 0,
            "points_balance": 999999,
            "cashback_balance": 999999,
            "amount_due": "0.01",
            "available_rewards": 999,
            "points_earned": 999999,
            "reward_discount": "99",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["points_balance"]) == 0
    assert _money(body["amount_due"]) == Decimal("100")
    assert body["available_rewards"] == 0
    assert _money(body["points_earned"]) == Decimal("1")
    assert _money(body["reward_discount"]) == 0


def test_preview_cashback_earned_when_enabled(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    client.put(
        "/api/v1/loyalty/settings",
        json={
            "cashback_enabled": True,
            "cashback_rate": "2.000",
        },
        headers=admin_headers,
    )
    resp = client.post(
        "/api/v1/loyalty/preview",
        json={"customer_id": customer["id"], "gross_total": "100"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["cashback_earned"]) == Decimal("2.000")
    assert _money(body["points_earned"]) == Decimal("1")


# ---------------------------------------------------------------------------
# Lookup — phone (conservative) and QR (opaque)
# ---------------------------------------------------------------------------


def test_lookup_requires_authentication(client):
    resp = client.get("/api/v1/loyalty/lookup", params={"q": "0550"})
    assert resp.status_code == 401


def test_lookup_by_phone_matches_digits_only(client, admin_headers):
    _create_customer(client, admin_headers, name="One", phone="0550 12 34 56")
    _create_customer(client, admin_headers, name="Two", phone="0550-12-34-56")
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0550123456"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] == 2
    assert {i["name"] for i in body["items"]} == {"One", "Two"}


def test_lookup_does_not_rewrite_country_prefixes(client, admin_headers):
    _create_customer(
        client, admin_headers, name="Intl", phone="+213550123456"
    )
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0550123456"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["total"] == 0
    # digits-only equality still finds it when the digits match exactly
    resp2 = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "+213 550 12 34 56"},
        headers=admin_headers,
    )
    assert resp2.json()["total"] == 1


def test_lookup_without_digits_is_rejected(client, admin_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "abc"},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "LOYALTY_LOOKUP_INVALID"


def test_lookup_blank_value_is_rejected(client, admin_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup", params={"q": " "}, headers=admin_headers
    )
    assert resp.status_code == 422


def test_lookup_no_match_returns_empty_page(client, admin_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0999999999"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0


def test_lookup_excludes_archived_customers(client, admin_headers):
    customer = _create_customer(
        client, admin_headers, name="Gone", phone="0550111222"
    )
    resp = client.delete(
        f"/api/v1/customers/{customer['id']}", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    found = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0550111222"},
        headers=admin_headers,
    )
    assert found.json()["total"] == 0


def test_lookup_qr_resolves_customer(client, admin_headers):
    customer = _create_customer(client, admin_headers, name="QR Holder")
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": f"KLICK:C:{customer['id']}"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["id"] == customer["id"]
    assert body["items"][0]["name"] == "QR Holder"


def test_lookup_qr_prefix_is_case_insensitive(client, admin_headers):
    customer = _create_customer(client, admin_headers, name="Lower")
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": f"klick:c:{customer['id']}"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["total"] == 1


def test_lookup_qr_invalid_payload_is_422(client, admin_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "KLICK:C:not-a-uuid"},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "LOYALTY_QR_INVALID"


def test_lookup_qr_unknown_customer_is_404(client, admin_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": f"KLICK:C:{uuid.uuid4()}"},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "LOYALTY_QR_NOT_FOUND"


def test_lookup_qr_excludes_archived_customer(client, admin_headers):
    customer = _create_customer(client, admin_headers, name="Arch QR")
    client.delete(f"/api/v1/customers/{customer['id']}", headers=admin_headers)
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": f"KLICK:C:{customer['id']}"},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "LOYALTY_QR_NOT_FOUND"


def test_cashier_can_lookup(client, cashier_headers):
    resp = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0550"},
        headers=cashier_headers,
    )
    assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Balance + history (read-never-writes)
# ---------------------------------------------------------------------------


def test_balance_requires_authentication(client):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}/loyalty"
    )
    assert resp.status_code == 401


def test_balance_unknown_customer_is_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}/loyalty", headers=admin_headers
    )
    assert resp.status_code == 404


def test_balance_without_account_is_zeros_and_read_never_writes(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    body = _balance(client, admin_headers, customer["id"])
    assert body["has_account"] is False
    assert _money(body["points_balance"]) == 0
    assert _money(body["cashback_balance"]) == 0
    # reward view of a zero balance: nothing unlocked, nothing over
    assert body["available_rewards"] == 0
    assert _money(body["remaining_points"]) == 0
    assert _account_rows(db) == 0
    assert _ledger_rows(db) == 0


def test_balance_reflects_adjustment(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(client, admin_headers, customer["id"], points=50)
    assert resp.status_code == 200, resp.text
    body = _balance(client, admin_headers, customer["id"])
    assert body["has_account"] is True
    assert _money(body["points_balance"]) == Decimal("50")
    # 50 points -> no whole reward yet, all 50 still milestone-bound
    assert body["available_rewards"] == 0
    assert _money(body["remaining_points"]) == Decimal("50")


def test_balance_reward_view_counts_whole_rewards(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=230)
    body = _balance(client, admin_headers, customer["id"])
    assert body["available_rewards"] == 2
    assert _money(body["remaining_points"]) == Decimal("30")


def test_history_requires_authentication(client):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}/loyalty/history"
    )
    assert resp.status_code == 401


def test_history_unknown_customer_is_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/customers/{uuid.uuid4()}/loyalty/history",
        headers=admin_headers,
    )
    assert resp.status_code == 404


def test_history_empty_without_account(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = client.get(
        f"/api/v1/customers/{customer['id']}/loyalty/history",
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["pages"] == 1


def test_history_newest_first_with_running_balances(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    for i in range(1, 26):
        resp = _adjust(
            client,
            admin_headers,
            customer["id"],
            points=1,
            reason=f"grant {i}",
            key=f"grant-{i}",
        )
        assert resp.status_code == 200, resp.text

    page1 = client.get(
        f"/api/v1/customers/{customer['id']}/loyalty/history",
        params={"page": 1, "page_size": 20},
        headers=admin_headers,
    ).json()
    assert page1["total"] == 25
    assert page1["pages"] == 2
    assert len(page1["items"]) == 20

    page2 = client.get(
        f"/api/v1/customers/{customer['id']}/loyalty/history",
        params={"page": 2, "page_size": 20},
        headers=admin_headers,
    ).json()
    assert len(page2["items"]) == 5

    # Completeness: pagination never skips or repeats a row — the two
    # pages together hold every grant exactly once.  (Rows are ordered
    # created_at DESC with a deterministic id tie-break; SQLite's
    # CURRENT_TIMESTAMP is second-granular so same-second grants may
    # interleave, hence completeness + determinism, not a fixed order.)
    all_rows = page1["items"] + page2["items"]
    balances = sorted(
        int(_money(r["balance_after_points"])) for r in all_rows
    )
    assert balances == list(range(1, 26))

    # Every row is self-consistent: grant i left a balance of i.
    for row in all_rows:
        balance = int(_money(row["balance_after_points"]))
        assert row["note"] == f"grant {balance}"
        assert row["event_type"] == "adjustment"
        assert _money(row["points_delta"]) == Decimal("1")
        # the row never leaks internal posting keys or the adjuster
        assert "source_event_key" not in row
        assert "client_request_id" not in row

    # Deterministic: the same request returns the same page.
    page1_again = client.get(
        f"/api/v1/customers/{customer['id']}/loyalty/history",
        params={"page": 1, "page_size": 20},
        headers=admin_headers,
    ).json()
    assert [r["id"] for r in page1_again["items"]] == [
        r["id"] for r in page1["items"]
    ]

    # Ordering: every row on page 1 is at least as new as the newest
    # row on page 2 (created_at DESC across the page boundary).
    assert page1["items"][-1]["created_at"] >= page2["items"][0]["created_at"]


# ---------------------------------------------------------------------------
# Administrative adjustment
# ---------------------------------------------------------------------------


def test_adjust_requires_authentication(client):
    customer_id = uuid.uuid4()
    resp = client.post(
        f"/api/v1/customers/{customer_id}/loyalty/adjustment",
        json={"reason": "no auth", "client_request_id": "k", "points_delta": 1},
    )
    assert resp.status_code == 401


def test_adjust_forbidden_for_manager(client, manager_headers, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client, manager_headers, customer["id"], points=10, key="mgr-1"
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_adjust_forbidden_for_cashier(client, cashier_headers, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client, cashier_headers, customer["id"], points=10, key="cash-1"
    )
    assert resp.status_code == 403


def test_adjust_unknown_customer_is_404(client, admin_headers):
    resp = _adjust(
        client, admin_headers, str(uuid.uuid4()), points=10, key="k"
    )
    assert resp.status_code == 404


def test_adjust_grants_points_writes_ledger_and_audit(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client,
        admin_headers,
        customer["id"],
        points=50,
        reason="loyalty correction",
        key="grant-a",
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert _money(body["points_delta"]) == Decimal("50")
    assert _money(body["points_balance"]) == Decimal("50")
    assert body["idempotent_replay"] is False
    assert body["customer_id"] == customer["id"]

    entries = list(
        db.scalars(
            select(LoyaltyLedgerEntry)
            .join(LoyaltyAccount)
            .where(LoyaltyAccount.customer_id == uuid.UUID(customer["id"]))
        ).all()
    )
    assert len(entries) == 1
    assert entries[0].event_type == "adjustment"
    assert _money(entries[0].points_delta) == Decimal("50")
    assert _money(entries[0].balance_after_points) == Decimal("50")
    assert entries[0].note == "loyalty correction"

    audits = _audit_rows(db, action="adjustment")
    assert len(audits) == 1
    assert audits[0].entity_type == "customer"
    assert audits[0].entity_id == uuid.UUID(customer["id"])
    assert audits[0].module == "customers"
    assert audits[0].reason == "loyalty correction"


def test_adjust_idempotent_replay_does_not_double(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    first = _adjust(
        client, admin_headers, customer["id"], points=70, key="replay-1"
    )
    assert first.status_code == 200
    assert first.json()["idempotent_replay"] is False

    second = _adjust(
        client, admin_headers, customer["id"], points=70, key="replay-1"
    )
    assert second.status_code == 200, second.text
    assert second.json()["idempotent_replay"] is True
    assert _money(second.json()["points_balance"]) == Decimal("70")

    body = _balance(client, admin_headers, customer["id"])
    assert _money(body["points_balance"]) == Decimal("70")
    assert _ledger_rows(db) == 1
    assert len(_audit_rows(db, action="adjustment")) == 1


def test_adjust_same_key_different_payload_is_conflict(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    first = _adjust(
        client, admin_headers, customer["id"], points=10, key="same-key"
    )
    assert first.status_code == 200
    second = _adjust(
        client, admin_headers, customer["id"], points=11, key="same-key"
    )
    assert second.status_code == 409
    assert second.json()["error"]["code"] == "CONFLICT"
    body = _balance(client, admin_headers, customer["id"])
    assert _money(body["points_balance"]) == Decimal("10")


def test_adjust_cannot_go_negative_from_zero(client, admin_headers, db):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client, admin_headers, customer["id"], points=-10, key="neg-1"
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "BUSINESS_RULE_ERROR"
    assert _ledger_rows(db) == 0
    assert len(_audit_rows(db, action="adjustment")) == 0
    body = _balance(client, admin_headers, customer["id"])
    assert body["has_account"] is False


def test_adjust_cannot_overdraw_existing_balance(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    _adjust(client, admin_headers, customer["id"], points=5, key="seed")
    resp = _adjust(
        client, admin_headers, customer["id"], points=-10, key="over-1"
    )
    assert resp.status_code == 422
    body = _balance(client, admin_headers, customer["id"])
    assert _money(body["points_balance"]) == Decimal("5")
    assert _ledger_rows(db) == 1


def test_adjust_negative_cashback_from_zero_is_rejected(
    client, admin_headers, db
):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client, admin_headers, customer["id"], cashback="-1.000", key="cb-1"
    )
    assert resp.status_code == 422
    assert _ledger_rows(db) == 0


def test_adjust_cashback_only(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    up = _adjust(
        client, admin_headers, customer["id"], cashback="10.000", key="cb-up"
    )
    assert up.status_code == 200, up.text
    down = _adjust(
        client, admin_headers, customer["id"], cashback="-2.500", key="cb-dn"
    )
    assert down.status_code == 200, down.text
    body = _balance(client, admin_headers, customer["id"])
    assert _money(body["cashback_balance"]) == Decimal("7.500")
    assert _money(body["points_balance"]) == 0


def test_adjust_combined_points_and_cashback(client, admin_headers):
    customer = _create_customer(client, admin_headers)
    resp = _adjust(
        client,
        admin_headers,
        customer["id"],
        points=100,
        cashback="3.000",
        key="both-1",
    )
    assert resp.status_code == 200, resp.text
    body = _balance(client, admin_headers, customer["id"])
    assert _money(body["points_balance"]) == Decimal("100")
    assert _money(body["cashback_balance"]) == Decimal("3.000")


@pytest.mark.parametrize(
    "payload",
    [
        {"client_request_id": "k", "points_delta": 1},  # no reason
        {"reason": "xy", "client_request_id": "k", "points_delta": 1},
        {"reason": "ok reason", "points_delta": 1},  # no key
        {"reason": "ok reason", "client_request_id": "k"},  # no delta
        {"reason": "ok reason", "client_request_id": "k", "points_delta": 0},
        {
            "reason": "ok reason",
            "client_request_id": "k",
            "points_delta": 0,
            "cashback_delta": "0",
        },
    ],
)
def test_adjust_requires_reason_key_and_nonzero_delta(
    client, admin_headers, payload
):
    customer = _create_customer(client, admin_headers)
    resp = client.post(
        f"/api/v1/customers/{customer['id']}/loyalty/adjustment",
        json=payload,
        headers=admin_headers,
    )
    assert resp.status_code == 422, payload


def test_rejected_adjust_writes_nothing(client, admin_headers, db):
    customer = _create_customer(client, admin_headers)
    resp = client.post(
        f"/api/v1/customers/{customer['id']}/loyalty/adjustment",
        json={"reason": "x"},  # missing key and delta
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert _ledger_rows(db) == 0
    assert _audit_rows(db, action="adjustment") == []


def test_lookup_and_balance_allowed_for_manager(
    client, manager_headers, admin_headers
):
    """Manager holds CUSTOMER_VIEW: reads work, writes stay admin-only."""
    customer = _create_customer(client, admin_headers, phone="0550777888")
    assert _balance(client, manager_headers, customer["id"])["has_account"] is False
    hist = client.get(
        f"/api/v1/customers/{customer['id']}/loyalty/history",
        headers=manager_headers,
    )
    assert hist.status_code == 200
    look = client.get(
        "/api/v1/loyalty/lookup",
        params={"q": "0550777888"},
        headers=manager_headers,
    )
    assert look.status_code == 200
    assert look.json()["total"] == 1
