"""Loyalty Phase F tests — the loyalty report (backend surfaces).

Covers:

1.  Hand-computed scenario — earn, redeem, return clawback + restoration,
    void clawback + restoration, admin adjustment; every headline figure
    of ``GET /api/v1/reports/loyalty`` asserted field by field, including
    the sales context (§5.1 semantics, completed sales only) and the
    events breakdown in canonical order.
2.  The ``adjustment`` distinction — the headline adjustment metrics
    count ONLY ``admin_adjust:%`` keys while the events breakdown shows
    the raw ``adjustment`` event type (which also carries the
    return/void restorations).
3.  Shortfall — a return whose earned rewards were already spent is
    reported as an unrecovered shortfall, never a negative balance.
4.  Device filter — only ledger entries attached to a sale of that
    device; device-less entries (admin adjustment, debt settlement) are
    excluded.
5.  Window isolation — an empty window reports zeros for activity while
    the balance snapshot stays current; inverted ranges return the
    documented 422 code.
6.  Pagination — page/page_size/pages/total with newest-first ordering.
7.  Permissions — the existing ``report_financial`` scope (manager yes,
    cashier no); no new permission was introduced.
8.  Export contract — ``loyalty`` slug: landscape spec with four blocks,
    all label keys localized in ar/fr/en, and the full XLSX export
    pipeline through POST /api/v1/exports.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.exporting.contract import (
    REPORT_SLUGS,
    ROW_LEVEL_REPORTS,
    _LANDSCAPE,
    build_spec,
)
from app.main import app
from app.models.loyalty import LoyaltyAccount, LoyaltyLedgerEntry
from app.printing.labels import label
from app.schemas.loyalty import LoyaltySettingsUpdateRequest
from app.services.auth import AuthService
from app.services.loyalty import LoyaltyEngine, LoyaltySettingsService
from app.services.report import ReportService

# ── Fixtures (same recipe as test_pos_sale_loyalty.py) ────────────────────


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


# ── Helpers ───────────────────────────────────────────────────────────────

_seq = {"n": 0}


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _params(**kwargs) -> dict:
    day = kwargs.pop("day", _today())
    payload = {"date_from": day.isoformat(), "date_to": day.isoformat()}
    payload.update(kwargs)
    return payload


def _get(client, headers, path: str, **kwargs) -> dict:
    resp = client.get(f"/api/v1{path}", params=_params(**kwargs), headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _create_product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Loyal Report Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"LRP{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "1000.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_customer(client, headers, name: str) -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name, "phone": None}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sell(
    client,
    headers,
    product_id: str,
    *,
    quantity: str = "10.000",
    customer_id: str | None = None,
    reward_percent: int = 0,
    paid: str | None = None,
    payment_method: str = "cash",
    device_id: str = "POS-1",
) -> dict:
    unit = Decimal("100.000")
    gross = unit * Decimal(quantity)
    discount = (
        gross * Decimal(reward_percent) / Decimal(100)
    ).quantize(Decimal("0.001"))
    if paid is None:
        paid = str(gross - discount)
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": [
            {
                "product_id": product_id,
                "quantity": quantity,
                "unit_price": str(unit),
                "line_discount": "0.000",
            }
        ],
        "invoice_discount": "0.000",
        "payment_method": payment_method,
        "paid": paid,
        "device_id": device_id,
    }
    if customer_id is not None:
        payload["customer_id"] = customer_id
    if reward_percent:
        payload["loyalty_reward_percent"] = reward_percent
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _return(client, headers, sale: dict, quantity: str) -> dict:
    line = sale["lines"][0]
    resp = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "sale_id": sale["id"],
            "reason": "defective",
            "lines": [{"sale_line_id": line["id"], "quantity": quantity}],
            "device_id": "POS-1",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _void(client, headers, sale_id: str, reason: str = "wrong item") -> dict:
    resp = client.post(
        f"/api/v1/sales/{sale_id}/void",
        json={"reason": reason},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _update_settings(session, **fields) -> None:
    LoyaltySettingsService(session).update(
        LoyaltySettingsUpdateRequest(**fields),
        actor_id=None,
    )
    session.expire_all()


def _admin_adjust(session, customer_id, points: int) -> None:
    """Manual admin adjustment — the only ``admin_adjust:%`` reporter."""
    engine = LoyaltyEngine(session)
    with engine.transaction():
        engine.post(
            customer_id=uuid.UUID(str(customer_id)),
            event_type="adjustment",
            source_event_key=f"admin_adjust:{uuid.uuid4().hex}",
            points_delta=Decimal(points),
        )
    session.expire_all()


def _report(client, headers, **kwargs) -> dict:
    return _get(client, headers, "/reports/loyalty", **kwargs)


# ── 1. Hand-computed scenario ─────────────────────────────────────────────


@pytest.fixture()
def scenario(client, admin_headers, db):
    """Earn + reward + return + void + admin adjustment, same day.

    Settings: points 0.01/DA, cashback 2%, reward cap 20%.
    """
    _update_settings(
        db,
        points_enabled=True,
        cashback_enabled=True,
        cashback_rate="2.000",
        max_reward_discount_percent="20.000",
    )
    product = _create_product(client, admin_headers)
    customer = _create_customer(client, admin_headers, "Loyal Report Customer")

    # Manual +500 points — counted by the headline adjustment metrics.
    _admin_adjust(db, customer["id"], 500)

    # Sale 1: 10 x 100 = 1000 cash -> earn floor(1000 x 0.01) = 10 pts
    # and 1000 x 2% = 20.000 cashback.  Balance: 510 pts / 20.000.
    sale1 = _sell(client, admin_headers, product["id"], customer_id=customer["id"])

    # Sale 2: 1 x 100 = 100, ONE reward at 10% -> discount 10.000,
    # due 90 (100 points consumed).  Earn on 90: floor(0.9) = 0 pts
    # (zero points still posts because cashback 90 x 2% = 1.800 > 0).
    # Balance: 410 pts / 21.800.
    sale2 = _sell(
        client,
        admin_headers,
        product["id"],
        quantity="1.000",
        customer_id=customer["id"],
        reward_percent=10,
    )

    # Return of sale 1 (full 1000): clawback 10 pts / 20.000 cashback,
    # no reward to restore.  Balance: 400 pts / 1.800.
    ret = _return(client, admin_headers, sale1, "10.000")

    # Void of sale 2: clawback 0 pts / 1.800 cashback + restore the
    # 100 spent points / 10.000 value.  Balance: 500 pts / 0.000.
    voided = _void(client, admin_headers, sale2["id"])

    return {
        "product": product,
        "customer": customer,
        "sale1": sale1,
        "sale2": sale2,
        "return": ret,
        "void": voided,
    }


class TestLoyaltyReportScenario:
    def test_headline_figures_match_hand_computed_scenario(
        self, client, admin_headers, scenario
    ):
        body = _report(client, admin_headers)

        # Sales context — §5.1 semantics, completed sales only: the
        # voided sale contributes nothing.
        assert Decimal(str(body["sales_gross"])) == Decimal("1000.000")
        assert Decimal(str(body["sales_after_discounts"])) == Decimal("1000.000")
        assert body["invoice_count"] == 1

        # Period activity (ledger window).
        assert Decimal(str(body["points_earned"])) == Decimal("10")
        assert Decimal(str(body["cashback_earned"])) == Decimal("21.800")
        assert body["earn_entries"] == 2
        assert Decimal(str(body["settlement_points"])) == Decimal("0")
        assert Decimal(str(body["points_redeemed"])) == Decimal("100")
        assert Decimal(str(body["redemption_value"])) == Decimal("10.000")
        assert body["redeem_entries"] == 1
        # Return clawback -10 pts / -20.000; void clawback -0 / -1.800.
        assert Decimal(str(body["points_reversed"])) == Decimal("10")
        assert Decimal(str(body["cashback_reversed"])) == Decimal("21.800")
        assert body["reversal_entries"] == 2
        # Void restored the 100 spent pts / 10.000 (return had none).
        assert Decimal(str(body["points_restored"])) == Decimal("100")
        assert Decimal(str(body["restored_value"])) == Decimal("10.000")
        assert body["restore_entries"] == 1
        # Nothing was unrecovered in this scenario.
        assert Decimal(str(body["shortfall_points"])) == Decimal("0")
        assert Decimal(str(body["shortfall_cashback"])) == Decimal("0.000")
        # Headline adjustments count ONLY admin_adjust keys: the +500
        # seed, never the +100 void restoration.
        assert Decimal(str(body["adjustment_points"])) == Decimal("500")
        assert Decimal(str(body["adjustment_cashback"])) == Decimal("0.000")

        # Current balances (snapshot, not a window total).
        assert Decimal(str(body["outstanding_points"])) == Decimal("500")
        assert Decimal(str(body["outstanding_cashback"])) == Decimal("0.000")
        assert body["accounts_with_balance"] == 1

        # Window echo + ledger envelope.
        assert body["date_from"] == _today().isoformat()
        assert body["date_to"] == _today().isoformat()
        assert body["total"] == 7
        assert body["page"] == 1
        assert body["page_size"] == 100
        assert body["pages"] == 1
        assert len(body["items"]) == 7

    def test_events_breakdown_in_canonical_order(
        self, client, admin_headers, scenario
    ):
        body = _report(client, admin_headers)
        events = body["events"]
        assert [e["event_type"] for e in events] == [
            "sale_earn",
            "redeem",
            "return_clawback",
            "void_clawback",
            "adjustment",
        ]
        by_type = {e["event_type"]: e for e in events}

        # sale_earn: 10 pts / 20.000 (sale 1) + 0 pts / 1.800 (sale 2).
        assert by_type["sale_earn"]["entries"] == 2
        assert Decimal(str(by_type["sale_earn"]["points_delta"])) == Decimal("10")
        assert Decimal(str(by_type["sale_earn"]["cashback_delta"])) == Decimal(
            "21.800"
        )

        assert by_type["redeem"]["entries"] == 1
        assert Decimal(str(by_type["redeem"]["points_delta"])) == Decimal("-100")
        assert Decimal(str(by_type["redeem"]["cashback_delta"])) == Decimal("0.000")

        assert by_type["return_clawback"]["entries"] == 1
        assert Decimal(str(by_type["return_clawback"]["points_delta"])) == Decimal(
            "-10"
        )
        assert Decimal(str(by_type["return_clawback"]["cashback_delta"])) == Decimal(
            "-20.000"
        )

        assert by_type["void_clawback"]["entries"] == 1
        assert Decimal(str(by_type["void_clawback"]["points_delta"])) == Decimal("0")
        assert Decimal(str(by_type["void_clawback"]["cashback_delta"])) == Decimal(
            "-1.800"
        )

        # Raw ``adjustment`` event type: admin seed +500 AND the void
        # restoration +100 — the headline metrics above count only the
        # admin seed, this row shows everything the ledger recorded.
        assert by_type["adjustment"]["entries"] == 2
        assert Decimal(str(by_type["adjustment"]["points_delta"])) == Decimal("600")
        assert Decimal(str(by_type["adjustment"]["cashback_delta"])) == Decimal(
            "0.000"
        )

    def test_ledger_rows_reference_customer_and_invoice(
        self, client, admin_headers, scenario
    ):
        body = _report(client, admin_headers)
        items = body["items"]

        # The void restoration posted last (+100 pts, balance 500/0.000).
        restore = next(
            row
            for row in items
            if row["event_type"] == "adjustment"
            and Decimal(str(row["points_delta"])) == Decimal("100")
        )
        assert Decimal(str(restore["balance_after_points"])) == Decimal("500")
        assert Decimal(str(restore["balance_after_cashback"])) == Decimal("0.000")
        assert restore["customer_id"] == scenario["customer"]["id"]
        assert restore["customer_name"] == "Loyal Report Customer"
        assert restore["sale_id"] == scenario["sale2"]["id"]
        assert restore["invoice_number"] == scenario["sale2"]["invoice_number"]

        # The admin seed carries no sale / invoice reference.
        seed = next(
            row
            for row in items
            if row["event_type"] == "adjustment"
            and Decimal(str(row["points_delta"])) == Decimal("500")
        )
        assert seed["sale_id"] is None
        assert seed["invoice_number"] is None

        # Every entry names the customer; sale-linked entries name the
        # invoice.
        for row in items:
            assert row["customer_id"] == scenario["customer"]["id"]
            assert row["customer_name"] == "Loyal Report Customer"
            if row["event_type"] in {"redeem", "sale_earn", "return_clawback"}:
                assert row["invoice_number"] is not None

    def test_empty_window_reports_zero_activity_but_live_balances(
        self, client, admin_headers, scenario
    ):
        future = _today() + timedelta(days=30)
        body = _report(client, admin_headers, day=future)

        assert Decimal(str(body["points_earned"])) == Decimal("0")
        assert Decimal(str(body["cashback_earned"])) == Decimal("0.000")
        assert Decimal(str(body["points_redeemed"])) == Decimal("0")
        assert Decimal(str(body["redemption_value"])) == Decimal("0.000")
        assert Decimal(str(body["points_reversed"])) == Decimal("0")
        assert Decimal(str(body["points_restored"])) == Decimal("0")
        assert Decimal(str(body["shortfall_points"])) == Decimal("0")
        assert body["events"] == []
        assert body["items"] == []
        assert body["total"] == 0
        assert body["pages"] == 0
        assert body["invoice_count"] == 0
        assert Decimal(str(body["sales_gross"])) == Decimal("0.000")

        # The balance snapshot is NOT window-scoped.
        assert Decimal(str(body["outstanding_points"])) == Decimal("500")
        assert body["accounts_with_balance"] == 1

    def test_inverted_range_returns_documented_422(self, client, admin_headers):
        resp = client.get(
            "/api/v1/reports/loyalty",
            params={
                "date_from": (_today() + timedelta(days=1)).isoformat(),
                "date_to": _today().isoformat(),
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "REPORT_INVALID_RANGE"


# ── 3. Shortfall ──────────────────────────────────────────────────────────


class TestLoyaltyReportShortfall:
    def test_return_of_already_spent_rewards_reports_shortfall(
        self, client, admin_headers, db
    ):
        _update_settings(
            db,
            points_enabled=True,
            cashback_enabled=False,
        )
        product = _create_product(client, admin_headers, quantity="10000.000")
        customer = _create_customer(client, admin_headers, "Shortfall Customer")

        # Sale A: 100 x 100 = 10000 cash -> earn 100 pts.  Balance: 100.
        sale_a = _sell(
            client,
            admin_headers,
            product["id"],
            quantity="100.000",
            customer_id=customer["id"],
        )

        # Sale B: ONE reward at 10% consumes exactly the 100 points;
        # credit (paid 0) earns nothing, so the balance drops to 0.
        _sell(
            client,
            admin_headers,
            product["id"],
            quantity="1.000",
            customer_id=customer["id"],
            reward_percent=10,
            payment_method="credit",
            paid="0.000",
        )

        # Return of sale A: the clawback is due 100 pts but the balance
        # is 0 — recorded as a shortfall, never a negative balance.
        _return(client, admin_headers, sale_a, "100.000")

        body = _report(client, admin_headers)
        assert Decimal(str(body["shortfall_points"])) == Decimal("100")
        assert Decimal(str(body["shortfall_cashback"])) == Decimal("0.000")
        # The clawback entry exists but recovered nothing.
        assert Decimal(str(body["points_reversed"])) == Decimal("0")
        assert body["reversal_entries"] == 1
        assert Decimal(str(body["outstanding_points"])) == Decimal("0")

        claw = next(
            row
            for row in body["items"]
            if row["event_type"] == "return_clawback"
        )
        assert Decimal(str(claw["points_delta"])) == Decimal("0")
        assert "shortfall" in (claw["note"] or "")


# ── 4. Device filter ──────────────────────────────────────────────────────


class TestLoyaltyReportDeviceFilter:
    def test_device_filter_keeps_only_that_devices_entries(
        self, client, admin_headers, db
    ):
        _update_settings(
            db,
            points_enabled=True,
            cashback_enabled=False,
        )
        product = _create_product(client, admin_headers)
        customer = _create_customer(client, admin_headers, "Two Devices")

        # POS-1 sale (10 pts) + POS-2 sale (10 pts) + a device-less
        # admin adjustment (+500).
        _sell(
            client,
            admin_headers,
            product["id"],
            customer_id=customer["id"],
            device_id="POS-1",
        )
        _sell(
            client,
            admin_headers,
            product["id"],
            customer_id=customer["id"],
            device_id="POS-2",
        )
        _admin_adjust(db, customer["id"], 500)

        pos1 = _report(client, admin_headers, device_id="POS-1")
        assert pos1["total"] == 1
        assert [row["event_type"] for row in pos1["items"]] == ["sale_earn"]
        assert Decimal(str(pos1["points_earned"])) == Decimal("10")
        assert Decimal(str(pos1["adjustment_points"])) == Decimal("0")
        assert pos1["invoice_count"] == 1
        assert Decimal(str(pos1["sales_gross"])) == Decimal("1000.000")
        # The snapshot stays global regardless of the device filter.
        assert Decimal(str(pos1["outstanding_points"])) == Decimal("520")

        both = _report(client, admin_headers)
        assert both["total"] == 3
        assert Decimal(str(both["points_earned"])) == Decimal("20")
        assert Decimal(str(both["adjustment_points"])) == Decimal("500")
        assert both["invoice_count"] == 2


# ── 6. Pagination ─────────────────────────────────────────────────────────


class TestLoyaltyReportPagination:
    def test_pages_walk_newest_first(self, client, admin_headers, db):
        _update_settings(db, points_enabled=True, cashback_enabled=False)
        product = _create_product(client, admin_headers)
        customer = _create_customer(client, admin_headers, "Paginated Customer")
        for _ in range(3):
            _sell(
                client,
                admin_headers,
                product["id"],
                quantity="1.000",
                customer_id=customer["id"],
            )

        page1 = _report(client, admin_headers, page=1, page_size=2)
        assert page1["total"] == 3
        assert page1["pages"] == 2
        assert len(page1["items"]) == 2

        page2 = _report(client, admin_headers, page=2, page_size=2)
        assert len(page2["items"]) == 1

        # No overlap between the pages; union is the whole ledger.
        ids1 = {row["entry_id"] for row in page1["items"]}
        ids2 = {row["entry_id"] for row in page2["items"]}
        assert ids1.isdisjoint(ids2)
        assert len(ids1 | ids2) == 3


# ── 7. Permissions ────────────────────────────────────────────────────────


class TestLoyaltyReportPermissions:
    def test_manager_with_report_financial_is_allowed(
        self, client, manager_headers, scenario
    ):
        body = _report(client, manager_headers)
        assert Decimal(str(body["points_earned"])) == Decimal("10")

    def test_cashier_without_report_financial_is_forbidden(
        self, client, cashier_headers, scenario
    ):
        resp = client.get(
            "/api/v1/reports/loyalty", params=_params(), headers=cashier_headers
        )
        assert resp.status_code == 403, resp.text


# ── 8. Export contract ────────────────────────────────────────────────────


class TestLoyaltyExport:
    def test_slug_registered_landscape_and_out_of_row_level(
        self, client, admin_headers, scenario, testing_session
    ):
        assert "loyalty" in REPORT_SLUGS
        assert "loyalty" in _LANDSCAPE
        assert "loyalty" not in ROW_LEVEL_REPORTS

        with testing_session() as session:
            payload = ReportService(session).loyalty(
                date_from=_today(), date_to=_today()
            )
        spec = build_spec("loyalty", payload, locale="en")

        assert spec.landscape is True
        assert spec.title == "Loyalty"
        assert len(spec.blocks) == 4
        period, balances, events, ledger = spec.blocks
        assert len(period.rows) == 1
        assert len(balances.rows) == 1
        assert len(events.rows) == 5
        assert len(ledger.rows) == 7
        assert spec.row_count == 14
        assert "Gross sales" in period.headers

    def test_every_export_label_key_is_localized(
        self, client, admin_headers, scenario, testing_session
    ):
        keys = [
            "report_loyalty",
            "label_period",
            "kpi_gross_sales",
            "kpi_invoices",
            "loyalty_points_earned",
            "loyalty_cashback_earned",
            "loyalty_settlement_points",
            "loyalty_points_redeemed",
            "loyalty_redemption_value",
            "loyalty_points_reversed",
            "loyalty_cashback_reversed",
            "loyalty_points_restored",
            "loyalty_restored_value",
            "loyalty_shortfall_points",
            "loyalty_shortfall_cashback",
            "loyalty_outstanding_points",
            "loyalty_outstanding_cashback",
            "loyalty_accounts_with_balance",
            "col_event",
            "col_points",
            "col_cashback",
            "col_points_balance",
            "col_cashback_balance",
            "col_date",
            "col_customer",
            "col_invoice",
            "col_count",
            "note",
            "loyalty_event_sale_earn",
            "loyalty_event_debt_settlement_earn",
            "loyalty_event_redeem",
            "loyalty_event_return_clawback",
            "loyalty_event_void_clawback",
            "loyalty_event_adjustment",
            "loyalty_event_expiry",
        ]
        for key in keys:
            for locale in ("ar", "fr", "en"):
                # label() falls back to the raw key when missing.
                assert label(key, locale) != key, f"{key} missing for {locale}"

    def test_full_xlsx_export_through_the_api(
        self, client, admin_headers, scenario
    ):
        resp = client.post(
            "/api/v1/exports",
            json={
                "report": "loyalty",
                "format": "xlsx",
                "locale": "en",
                "date_from": _today().isoformat(),
                "date_to": _today().isoformat(),
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        # XLSX is a zip container.
        assert resp.content[:2] == b"PK"
        assert "loyalty" in resp.headers["Content-Disposition"]

    def test_export_requires_dates(self, client, admin_headers, scenario):
        resp = client.post(
            "/api/v1/exports",
            json={"report": "loyalty", "format": "xlsx", "locale": "en"},
            headers=admin_headers,
        )
        assert resp.status_code == 422, resp.text
