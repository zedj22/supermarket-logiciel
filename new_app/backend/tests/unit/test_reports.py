"""Phase 14 tests — reports (§17.1 of the decision record).

Covers:

1.  Formula fixtures — one hand-built scenario (cash + line/invoice discount,
    card, partial, credit, pack, selling-unit, voided sale, pro-rata return,
    posted/cancelled/drawer expenses) asserted field by field.
2.  Invariants — `collected + debt_created = sales_after_discounts`,
    `discounts_total = line + invoice`, Σ §5.8 rows = §5.1/§5.2 totals,
    `drawer + external = total`, voided sales contribute 0.
3.  Pack COGS — summary line cost 0, component cost counted exactly once.
4.  Selling units — `unit_cost × quantity × multiplier`.
5.  Date semantics — inclusive window, next-day exclusion, 422 codes.
6.  Snapshot isolation — mutating `products.avg_cost` after the sale does not
    change the historical report.
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
from app.main import app
from app.models.catalog import Product
from app.models.debt import DebtLedgerEntry
from app.models.party import Customer
from app.services.auth import AuthService

# ── Fixtures ──────────────────────────────────────────────────────────────


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


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


# ── Helpers ───────────────────────────────────────────────────────────────

_seq = {"n": 0}


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Report Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"RPT{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "200.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale(client, headers, items: list[dict], **overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": items,
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "0.000",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _line(product_id: str, **overrides) -> dict:
    item = {
        "product_id": product_id,
        "quantity": "1.000",
        "unit_price": "100.000",
        "line_discount": "0.000",
    }
    item.update(overrides)
    return item


def _params(**kwargs) -> dict:
    day = kwargs.pop("day", _today())
    payload = {"date_from": day.isoformat(), "date_to": day.isoformat()}
    payload.update(kwargs)
    return payload


def _get(client, headers, path: str, **kwargs) -> dict:
    resp = client.get(f"/api/v1{path}", params=_params(**kwargs), headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _error(client, headers, path: str, **kwargs) -> dict:
    """GET with raw params, returning the parsed body of a non-200 reply."""
    resp = client.get(f"/api/v1{path}", params=kwargs, headers=headers)
    assert resp.status_code == 422, resp.text
    return resp.json()


# ── The §17.1 scenario ────────────────────────────────────────────────────


@pytest.fixture()
def scenario(client, admin_headers, db):
    """Cash / card / partial / credit / pack / unit / void / return / expense.

    Returns the hand-computed expectations alongside the created documents.
    """
    a = _product(client, admin_headers, name="Alpha", price="100.000", cost="60.000")
    b = _product(client, admin_headers, name="Bravo", price="10.000", cost="5.000")
    _product(
        client,
        admin_headers,
        name="Charlie Never Sold",
        price="30.000",
        cost="12.000",
        quantity="40.000",
    )
    box = client.post(
        f"/api/v1/products/{b['id']}/selling-units",
        json={
            "name": "Box",
            "unit_type": "piece",
            "multiplier": "6",
            "selling_price": "60.000",
            "is_base_unit": False,
        },
        headers=admin_headers,
    )
    assert box.status_code == 201, box.text
    pack = client.post(
        "/api/v1/packs",
        json={
            "name": "Alpha Pack",
            "barcode": "RPTPACK0001",
            "price": "200.000",
            "components": [{"product_id": a["id"], "quantity": "1.000"}],
        },
        headers=admin_headers,
    )
    assert pack.status_code == 201, pack.text
    pack = pack.json()

    customer = client.post(
        "/api/v1/customers",
        json={"name": "Report Debtor", "phone": None},
        headers=admin_headers,
    )
    assert customer.status_code == 201, customer.text
    customer = customer.json()

    # 1. cash sale with a line discount and an invoice discount
    s_cash = _sale(
        client,
        admin_headers,
        [_line(a["id"], quantity="1.000", unit_price="100.000", line_discount="10.000")],
        invoice_discount="5.000",
        payment_method="cash",
        paid="100.000",
    )
    # 2. card sale
    s_card = _sale(
        client,
        admin_headers,
        [_line(b["id"], quantity="3.000", unit_price="10.000")],
        payment_method="card",
        paid="30.000",
    )
    # 3. partial sale (50 paid of 200)
    s_partial = _sale(
        client,
        admin_headers,
        [_line(a["id"], quantity="2.000", unit_price="100.000")],
        payment_method="partial",
        paid="50.000",
        customer_id=customer["id"],
    )
    # 4. credit sale (0 paid of 100)
    s_credit = _sale(
        client,
        admin_headers,
        [_line(a["id"], quantity="1.000", unit_price="100.000")],
        payment_method="credit",
        paid="0.000",
        customer_id=customer["id"],
    )
    # 5. pack sale — summary line cost 0, component carries the cost
    s_pack = _sale(
        client,
        admin_headers,
        [{"pack_id": pack["id"], "quantity": "1.000", "unit_price": "200.000"}],
        payment_method="cash",
        paid="200.000",
    )
    # 6. selling-unit sale: 2 boxes = 12 base units
    s_unit = _sale(
        client,
        admin_headers,
        [
            {
                "product_id": b["id"],
                "selling_unit_id": box.json()["id"],
                "quantity": "2.000",
                "unit_price": "60.000",
                "line_discount": "0.000",
            }
        ],
        payment_method="cash",
        paid="120.000",
    )
    # 7. sale used for the pro-rata return below
    s_ret = _sale(
        client,
        admin_headers,
        [_line(a["id"], quantity="1.000", unit_price="100.000")],
        payment_method="cash",
        paid="100.000",
    )
    # 8. voided sale — must contribute nothing
    s_void = _sale(
        client,
        admin_headers,
        [_line(a["id"], quantity="1.000", unit_price="100.000")],
        payment_method="cash",
        paid="100.000",
    )
    voided = client.post(
        f"/api/v1/sales/{s_void['id']}/void",
        json={"reason": "wrong item"},
        headers=admin_headers,
    )
    assert voided.status_code == 200, voided.text

    # return 1 Alpha from sale 7 (no discount on that sale → refund 100)
    ret_line = next(ln for ln in s_ret["lines"] if ln["product_id"] == a["id"])
    ret = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "sale_id": s_ret["id"],
            "reason": "defective",
            "lines": [{"sale_line_id": ret_line["id"], "quantity": "1.000"}],
            "device_id": "POS-1",
        },
        headers=admin_headers,
    )
    assert ret.status_code == 201, ret.text

    # expenses: drawer + external posted, one cancelled (excluded)
    def _expense(amount: str, drawer: bool) -> dict:
        resp = client.post(
            "/api/v1/expenses",
            json={
                "client_request_id": str(uuid.uuid4()),
                "title": "Report expense",
                "category": "supplies",
                "amount": amount,
                "paid_from_drawer": drawer,
            },
            headers={**admin_headers, "X-Device-ID": "POS-1"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()

    exp_drawer = _expense("120.500", True)
    _expense("50.000", False)
    cancelled = _expense("99.000", True)
    cancel = client.post(
        f"/api/v1/expenses/{cancelled['id']}/cancel",
        json={"reason": "duplicate"},
        headers=admin_headers,
    )
    assert cancel.status_code == 200, cancel.text

    # one collected debt payment (Phase 9 ledger shape) for debt_collected
    now = datetime.now(timezone.utc)
    db.add(
        DebtLedgerEntry(
            customer_id=uuid.UUID(customer["id"]),
            entry_type="payment",
            amount=Decimal("50.000"),
            note="report test payment",
            user_id=None,
            entry_date=now,
        )
    )
    # mirror what DebtService does: ledger row + balance move together
    debtor = db.get(Customer, uuid.UUID(customer["id"]))
    debtor.balance = 200.0
    db.commit()

    expected = {
        "gross_sales": Decimal("850.000"),
        "line_discounts": Decimal("10.000"),
        "invoice_discounts": Decimal("5.000"),
        "discounts_total": Decimal("15.000"),
        "sales_after_discounts": Decimal("835.000"),
        "returns_count": 1,
        "returns_total": Decimal("100.000"),
        "net_sales": Decimal("735.000"),
        "invoice_count": 7,
        "items_sold": Decimal("11.000"),
        "cogs": Decimal("435.000"),
        "returns_cost": Decimal("60.000"),
        "cogs_net": Decimal("375.000"),
        "expenses_total": Decimal("170.500"),
        "expenses_drawer": Decimal("120.500"),
        "expenses_external": Decimal("50.000"),
        "gross_profit": Decimal("360.000"),
        "net_profit": Decimal("189.500"),
        "profit_margin_pct": Decimal("25.78"),
        "paid_cash": Decimal("505.000"),
        "paid_card": Decimal("30.000"),
        "paid_partial": Decimal("50.000"),
        "collected_total": Decimal("585.000"),
        "debt_created": Decimal("250.000"),
        "outstanding_debt": Decimal("250.000"),
        "debt_collected": Decimal("50.000"),
        "change_total": Decimal("15.000"),
    }
    return {
        "products": {"a": a, "b": b},
        "sales": {
            "cash": s_cash,
            "card": s_card,
            "partial": s_partial,
            "credit": s_credit,
            "pack": s_pack,
            "unit": s_unit,
            "return": s_ret,
            "void": s_void,
        },
        "customer": customer,
        "expected": expected,
        "exp_drawer": exp_drawer,
    }


# ── 1. formula fixtures ───────────────────────────────────────────────────


def test_financial_report_every_field(client, admin_headers, scenario):
    body = _get(client, admin_headers, "/reports/financial")

    for key, value in scenario["expected"].items():
        if isinstance(value, int) and not isinstance(value, bool):
            assert body[key] == value, f"{key}: {body[key]} != {value}"
        else:
            assert Decimal(body[key]) == value, f"{key}: {body[key]} != {value}"

    assert body["ar_outstanding"] == "200.000"  # 150 + 100 - 50 paid
    assert body["customers_with_debt"] == 1
    assert body["date_from"] == _today().isoformat()
    assert body["date_to"] == _today().isoformat()


def test_financial_invariants(client, admin_headers, scenario):
    body = _get(client, admin_headers, "/reports/financial")
    d = lambda key: Decimal(body[key])  # noqa: E731

    assert d("collected_total") + d("debt_created") == d("sales_after_discounts")
    assert d("discounts_total") == d("line_discounts") + d("invoice_discounts")
    assert d("expenses_drawer") + d("expenses_external") == d("expenses_total")
    assert d("net_sales") == d("sales_after_discounts") - d("returns_total")
    assert d("cogs_net") == d("cogs") - d("returns_cost")
    assert d("gross_profit") == d("net_sales") - d("cogs_net")
    assert d("net_profit") == d("gross_profit") - d("expenses_total")


def test_voided_sale_contributes_nothing(client, admin_headers, scenario):
    """A voided invoice is invisible to revenue, COGS, items and payments."""
    body = _get(client, admin_headers, "/reports/financial")
    # the voided sale was a 100.000 cash invoice for 1 Alpha
    assert Decimal(body["gross_sales"]) == Decimal("850.000")
    assert Decimal(body["cogs"]) == Decimal("435.000")
    assert body["invoice_count"] == 7
    assert Decimal(body["paid_cash"]) == Decimal("505.000")

    detail = _get(
        client,
        admin_headers,
        "/reports/sales",
        status="all",
    )
    statuses = [row["status"] for row in detail["items"]]
    assert statuses.count("void") == 1
    assert detail["totals"]["count"] == 8  # 7 completed + 1 void

    voided = _get(client, admin_headers, "/reports/voided")
    assert voided["total"] == 1
    assert voided["items"][0]["sale_id"] == scenario["sales"]["void"]["id"]
    assert voided["items"][0]["void_reason"] == "wrong item"
    assert voided["items"][0]["voided_by_name"] == "Admin"


# ── 2/3/4. §5.8 rows, packs, selling units ────────────────────────────────


def _row(items, kind: str, name: str) -> dict:
    match = [r for r in items if r["kind"] == kind and r["name"] == name]
    assert len(match) == 1, f"expected one {kind}/{name} row, got {len(match)}"
    return match[0]


def test_product_rows_and_totals_agree_with_financial(client, admin_headers, scenario):
    products = _get(client, admin_headers, "/reports/products")
    items = products["items"]
    assert products["total"] == 4  # Alpha, Bravo, pack, pack component

    alpha = _row(items, "product", "Alpha")
    assert Decimal(alpha["qty_sold"]) == Decimal("5.000")
    assert Decimal(alpha["gross"]) == Decimal("500.000")
    assert Decimal(alpha["line_discounts"]) == Decimal("10.000")
    assert Decimal(alpha["invoice_discount_share"]) == Decimal("5.000")
    assert Decimal(alpha["net_revenue"]) == Decimal("485.000")
    assert Decimal(alpha["return_qty"]) == Decimal("1.000")
    assert Decimal(alpha["return_amount"]) == Decimal("100.000")
    assert Decimal(alpha["cogs"]) == Decimal("300.000")
    assert Decimal(alpha["return_cost"]) == Decimal("60.000")
    assert Decimal(alpha["gross_profit"]) == Decimal("145.000")

    bravo = _row(items, "product", "Bravo")
    assert Decimal(bravo["qty_sold"]) == Decimal("15.000")  # 3 pieces + 2×6
    assert Decimal(bravo["net_revenue"]) == Decimal("150.000")
    assert Decimal(bravo["cogs"]) == Decimal("75.000")  # (3 + 12) × 5

    # §5.8 ↔ §5.1/§5.2 consistency: Σ rows equals the financial totals.
    financial = _get(client, admin_headers, "/reports/financial")
    net_revenue = sum(
        Decimal(r["net_revenue"]) - Decimal(r["return_amount"]) for r in items
    )
    cogs_net = sum(Decimal(r["cogs"]) - Decimal(r["return_cost"]) for r in items)
    assert net_revenue == Decimal(financial["net_sales"])
    assert cogs_net == Decimal(financial["cogs_net"])
    assert Decimal(products["totals"]["net_sales"]) == Decimal(financial["net_sales"])
    assert Decimal(products["totals"]["cogs_net"]) == Decimal(financial["cogs_net"])


def test_pack_component_cost_counted_once(client, admin_headers, scenario):
    items = _get(client, admin_headers, "/reports/products")["items"]

    pack = _row(items, "pack", "Alpha Pack")
    assert Decimal(pack["qty_sold"]) == Decimal("1.000")
    assert Decimal(pack["gross"]) == Decimal("200.000")
    assert Decimal(pack["net_revenue"]) == Decimal("200.000")
    assert Decimal(pack["cogs"]) == Decimal("0.000")  # GATE 9: summary cost 0

    component = _row(items, "component", "Alpha")
    assert Decimal(component["gross"]) == Decimal("0.000")
    assert Decimal(component["cogs"]) == Decimal("60.000")  # counted exactly once
    assert Decimal(component["gross_profit"]) == Decimal("-60.000")


def test_selling_unit_multiplier_in_cogs(client, admin_headers, scenario):
    """2 boxes × multiplier 6 × cost 5 = 60 on top of the 3-piece sale."""
    financial = _get(client, admin_headers, "/reports/financial")
    assert Decimal(financial["cogs"]) == Decimal("435.000")
    assert Decimal(financial["items_sold"]) == Decimal("11.000")


def test_category_report_totals_and_uncategorised(client, admin_headers, scenario):
    body = _get(client, admin_headers, "/reports/categories")
    names = {row["category"] for row in body["items"]}
    assert None in names  # pack rows are not categorised
    assert "Alpha" not in names  # names are categories, not products

    net_revenue = sum(
        Decimal(r["net_revenue"]) - Decimal(r["return_amount"]) for r in body["items"]
    )
    financial = _get(client, admin_headers, "/reports/financial")
    assert net_revenue == Decimal(financial["net_sales"])


def test_categories_are_grouped_when_assigned(client, admin_headers, scenario):
    category = client.post(
        "/api/v1/categories",
        json={"name": f"Drinks {uuid.uuid4().hex[:6]}"},
        headers=admin_headers,
    )
    assert category.status_code == 201, category.text
    category = category.json()

    product = _product(
        client,
        admin_headers,
        price="20.000",
        cost="8.000",
        category_id=category["id"],
    )
    _sale(
        client,
        admin_headers,
        [_line(product["id"], quantity="1.000", unit_price="20.000")],
        payment_method="cash",
        paid="20.000",
    )

    body = _get(client, admin_headers, "/reports/categories")
    match = [r for r in body["items"] if r["category_id"] == category["id"]]
    assert len(match) == 1
    assert Decimal(match[0]["net_revenue"]) == Decimal("20.000")


# ── 5. date semantics ─────────────────────────────────────────────────────


def test_date_window_is_inclusive_and_excludes_other_days(client, admin_headers, scenario):
    today = _today()
    empty_day = today - timedelta(days=1)
    body = _get(client, admin_headers, "/reports/financial", day=empty_day)
    assert Decimal(body["net_sales"]) == Decimal("0.000")
    assert body["invoice_count"] == 0
    assert body["returns_count"] == 0

    span = _get(
        client,
        admin_headers,
        "/reports/financial",
        date_from=empty_day.isoformat(),
        date_to=today.isoformat(),
    )
    assert span["invoice_count"] == 7
    assert Decimal(span["net_sales"]) == Decimal("735.000")


def test_invalid_range_and_caps_return_report_codes(client, admin_headers):
    today = _today()

    body = _error(
        client,
        admin_headers,
        "/reports/financial",
        date_from=today.isoformat(),
        date_to=(today - timedelta(days=1)).isoformat(),
    )
    assert body["error"]["code"] == "REPORT_INVALID_RANGE"

    body = _error(
        client,
        admin_headers,
        "/reports/daily",
        date_from=(today - timedelta(days=400)).isoformat(),
        date_to=today.isoformat(),
    )
    assert body["error"]["code"] == "REPORT_RANGE_TOO_WIDE"

    body = _error(
        client,
        admin_headers,
        "/reports/hourly",
        date_from=(today - timedelta(days=31)).isoformat(),
        date_to=today.isoformat(),
    )
    assert body["error"]["code"] == "REPORT_RANGE_TOO_WIDE"

    body = _error(client, admin_headers, "/reports/peak-hours", lookback_days=91)
    assert body["error"]["code"] == "REPORT_INVALID_RANGE"

    body = _error(client, admin_headers, "/reports/peak-hours", lookback_days=0)
    assert body["error"]["code"] == "REPORT_INVALID_RANGE"

    body = _error(client, admin_headers, "/reports/slow-moving", days=366)
    assert body["error"]["code"] == "REPORT_INVALID_RANGE"

    body = _error(
        client,
        admin_headers,
        "/reports/products",
        date_from=today.isoformat(),
        date_to=today.isoformat(),
        sort="balance",
    )
    assert body["error"]["code"] == "REPORT_SORT_INVALID"


# ── 6. snapshots ──────────────────────────────────────────────────────────


def test_avg_cost_mutation_does_not_reprice_history(client, admin_headers, scenario, db):
    """A later PMP change must never rewrite a completed report (§17.1.6)."""
    before = _get(client, admin_headers, "/reports/financial")

    product = scenario["products"]["a"]
    row = db.get(Product, uuid.UUID(product["id"]))
    row.avg_cost = 999.0
    db.commit()

    after = _get(client, admin_headers, "/reports/financial")
    assert Decimal(after["cogs"]) == Decimal(before["cogs"])
    assert Decimal(after["cogs"]) == Decimal("435.000")
    assert Decimal(after["net_profit"]) == Decimal(before["net_profit"])


# ── time buckets / detail surfaces ────────────────────────────────────────


def test_daily_hourly_and_peak_buckets(client, admin_headers, scenario):
    daily = _get(client, admin_headers, "/reports/daily")
    assert len(daily["items"]) == 1  # a single day window
    row = daily["items"][0]
    assert row["date"] == _today().isoformat()
    assert Decimal(row["net_sales"]) == Decimal("735.000")
    assert Decimal(row["cogs_net"]) == Decimal("375.000")
    assert Decimal(row["gross_profit"]) == Decimal("360.000")
    assert Decimal(row["expenses"]) == Decimal("170.500")
    assert Decimal(row["net_profit"]) == Decimal("189.500")
    assert row["invoice_count"] == 7
    assert Decimal(row["items_sold"]) == Decimal("11.000")
    assert Decimal(row["returns_total"]) == Decimal("100.000")

    hourly = _get(client, admin_headers, "/reports/hourly")
    assert Decimal(sum(Decimal(r["net_sales"]) for r in hourly["items"])) == Decimal(
        "735.000"
    )
    assert sum(r["invoice_count"] for r in hourly["items"]) == 7
    assert len(hourly["items"]) == 24  # one UTC day = 24 buckets

    peak = _get(client, admin_headers, "/reports/peak-hours", lookback_days=7)
    assert [r["hour"] for r in peak["items"]] == list(range(24))
    assert sum(r["invoice_count"] for r in peak["items"]) == 7


def test_sales_detail_filters_and_totals(client, admin_headers, scenario):
    completed = _get(client, admin_headers, "/reports/sales")
    assert completed["total"] == 7
    assert Decimal(completed["totals"]["subtotal"]) == Decimal("850.000")
    assert Decimal(completed["totals"]["discounts"]) == Decimal("15.000")
    assert Decimal(completed["totals"]["total"]) == Decimal("835.000")
    assert Decimal(completed["totals"]["paid"]) == Decimal("600.000")
    assert Decimal(completed["totals"]["change"]) == Decimal("15.000")

    card = _get(client, admin_headers, "/reports/sales", payment_method="card")
    assert card["total"] == 1
    assert card["items"][0]["payment_method"] == "card"

    by_device = _get(client, admin_headers, "/reports/sales", device_id="POS-1")
    assert by_device["total"] == 7
    missing = _get(client, admin_headers, "/reports/sales", device_id="NOPE")
    assert missing["total"] == 0
    assert missing["items"] == []


def test_slow_moving_only_lists_untouched_stock(client, admin_headers, scenario):
    body = _get(client, admin_headers, "/reports/slow-moving", days=30, threshold=0)
    names = [row["name"] for row in body["items"]]
    assert "Charlie Never Sold" in names
    assert "Alpha" not in names  # sold today
    assert "Bravo" not in names

    target = next(r for r in body["items"] if r["name"] == "Charlie Never Sold")
    assert Decimal(target["quantity"]) == Decimal("40.000")
    assert Decimal(target["stock_value"]) == Decimal("480.000")  # 40 × 12
    assert target["last_sale_date"] is None

    capped = _get(client, admin_headers, "/reports/slow-moving", days=30, threshold=40)
    assert capped["items"] == []


def test_device_breakdown_and_suppliers_empty_state(client, admin_headers, scenario):
    financial = _get(client, admin_headers, "/reports/financial")
    assert len(financial["device_breakdown"]) == 1
    row = financial["device_breakdown"][0]
    assert row["device_id"] == "POS-1"
    assert row["invoice_count"] == 7
    assert Decimal(row["net_sales"]) == Decimal("735.000")
    assert Decimal(row["share_pct"]) == Decimal("100.00")

    filtered = _get(client, admin_headers, "/reports/financial", device_id="POS-1")
    assert Decimal(filtered["net_sales"]) == Decimal("735.000")
    absent = _get(client, admin_headers, "/reports/financial", device_id="NOPE")
    assert Decimal(absent["net_sales"]) == Decimal("0.000")

    suppliers = _get(client, admin_headers, "/reports/suppliers")
    assert Decimal(suppliers["supplier_payable"]) == Decimal("0.000")
    assert Decimal(suppliers["purchases_total"]) == Decimal("0.000")
    assert suppliers["suppliers_with_balance"] == 0
