"""Zakat PDF tests — snapshot report + ad-hoc preview report.

Asserts the HTTP contract (200 + ``application/pdf`` + attachment
filename), the localized disclaimer presence (via the uncompressed
report bytes where possible) and the three-block structure the service
builds (assets / liabilities / result).
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
from app.services.auth import AuthService
from app.services.zakat import ZakatService, _result_from_row
from app.printing.templates.report_table import build_flowables

TODAY = date.today()
LONG_AGO = date(TODAY.year - 2, 1, 1)

COMPLETE_PAYLOAD = {
    "zakat_date": TODAY.isoformat(),
    "hawl_start_date": LONG_AGO.isoformat(),
    "gold_price_per_gram": "27000",
    "use_imported_inventory": False,
    "cash_provided": True,
    "cash_items": [{"label": "Caisse", "amount": "500000"}],
    "collectible_receivables": "3000000",
    "liability_items": [{"label": "Fournisseur", "amount": "1000000", "due": True}],
}


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


def _login(client: TestClient) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == "Admin")
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": "1234"})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


@pytest.fixture()
def admin_headers(client):
    return _login(client)


def test_adhoc_preview_pdf_is_a_pdf(client, admin_headers):
    resp = client.post(
        "/api/v1/zakat/pdf?locale=en", json=COMPLETE_PAYLOAD, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"].startswith("application/pdf")
    assert resp.content[:5] == b"%PDF-"
    assert "zakat_preview_" in resp.headers["content-disposition"]


def test_snapshot_pdf_is_a_pdf_with_locale_and_filename(client, admin_headers):
    saved = client.post(
        "/api/v1/zakat",
        json={"client_request_id": "zakat-pdf-0001", "calculation": COMPLETE_PAYLOAD},
        headers=admin_headers,
    )
    assert saved.status_code == 201, saved.text
    calculation_id = saved.json()["id"]

    resp = client.get(
        f"/api/v1/zakat/{calculation_id}/pdf?locale=ar", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    disposition = resp.headers["content-disposition"]
    assert f"zakat_{TODAY.isoformat()}" in disposition


def test_unknown_locale_is_rejected(client, admin_headers):
    resp = client.post(
        "/api/v1/zakat/pdf?locale=de", json=COMPLETE_PAYLOAD, headers=admin_headers
    )
    assert resp.status_code == 422, resp.text


def test_pdf_for_unknown_calculation_is_404(client, admin_headers):
    resp = client.get(
        "/api/v1/zakat/00000000-0000-0000-0000-000000000000/pdf",
        headers=admin_headers,
    )
    assert resp.status_code == 404, resp.text


def test_report_input_has_three_blocks_and_disclaimer(db):
    """The report story: assets + liabilities + result, disclaimer in meta."""
    from datetime import datetime, timezone

    from app.schemas.zakat import ZakatCalculateRequest
    from app.services.zakat import to_result_response

    service = ZakatService(db)
    request = ZakatCalculateRequest.model_validate(COMPLETE_PAYLOAD)
    result, _products = service._compute(request)
    store = service.settings.get()
    inp = service._report_input(
        result=to_result_response(result),
        inputs=request,
        store_name=store.store_name,
        locale="en",
        notes=None,
        calculation_id=None,
        created_at=datetime.now(timezone.utc),
    )
    assert len(inp.blocks) == 3
    assert inp.rtl is False
    assert any("Ministry reference" in line for line in inp.meta_lines)
    flowables = build_flowables(inp)
    assert flowables  # renders without raising


def test_arabic_report_is_rtl(db):
    from datetime import datetime, timezone

    from app.schemas.zakat import ZakatCalculateRequest
    from app.services.zakat import to_result_response

    service = ZakatService(db)
    request = ZakatCalculateRequest.model_validate(COMPLETE_PAYLOAD)
    result, _products = service._compute(request)
    store = service.settings.get()
    inp = service._report_input(
        result=to_result_response(result),
        inputs=request,
        store_name=store.store_name,
        locale="ar",
        notes="ملاحظة",
        calculation_id=None,
        created_at=datetime.now(timezone.utc),
    )
    assert inp.rtl is True
    assert build_flowables(inp)


def _report(db, payload, locale="en"):
    from datetime import datetime, timezone

    from app.schemas.zakat import ZakatCalculateRequest
    from app.services.zakat import to_result_response

    service = ZakatService(db)
    request = ZakatCalculateRequest.model_validate(payload)
    result, _products = service._compute(request)
    store = service.settings.get()
    return service._report_input(
        result=to_result_response(result),
        inputs=request,
        store_name=store.store_name,
        locale=locale,
        notes=None,
        calculation_id=None,
        created_at=datetime.now(timezone.utc),
    )


def test_report_carries_the_stock_only_breakdown_when_stock_is_imported(db):
    """The PDF mirrors the result card: remaining quantity + cost and
    market reference values + the 2.5 % stock-only estimate, with the
    stock-only note in meta — all presented as rows, never as a total
    that could be mistaken for the complete business zakat."""
    from app.models.catalog import Product
    from app.printing.labels import label

    db.add(
        Product(
            name="Sucre 1kg",
            barcode="ZAKPDF1",
            price=Decimal("100.000"),
            cost=Decimal("70.000"),
            avg_cost=Decimal("70.000"),
            quantity=Decimal("20.000"),
        )
    )
    db.commit()

    payload = dict(COMPLETE_PAYLOAD, use_imported_inventory=True)
    inp = _report(db, payload, locale="en")
    assert len(inp.blocks) == 3

    def dec(cell: str) -> Decimal:
        return Decimal(cell.removesuffix(" DA").replace(" ", ""))

    result_rows = inp.blocks[2].rows
    by_label = {row[0]: row for row in result_rows}
    qty_row = by_label[label("zakat_stock_qty", "en")]
    assert dec(qty_row[1]) == Decimal("20.000")  # quantity, no currency
    assert not qty_row[1].endswith(" DA")
    cost_row = by_label[label("zakat_stock_cost_value", "en")]
    assert dec(cost_row[1]) == Decimal("1400.000")
    market_row = by_label[label("zakat_stock_market_value", "en")]
    assert dec(market_row[1]) == Decimal("2000.000")
    only_row = by_label[label("zakat_stock_only_zakat", "en")]
    assert dec(only_row[1]) == Decimal("50.000")
    assert only_row[2] == "2.5%"

    assert any(
        line == label("zakat_stock_only_note", "en") for line in inp.meta_lines
    ), "the stock-only note must travel with the report"
    # The stock-only rows sit in the result block only — the assets
    # total still counts the merchandise value exactly once
    # (2000 stock + 500000 cash + 3000000 receivables).
    assert dec(inp.blocks[0].totals[1]) == Decimal("3502000.000")
    assert build_flowables(inp)


def test_report_omits_the_breakdown_when_stock_was_not_imported(db):
    """Old payloads / no import → no stock-only rows, no note; the
    report layout stays byte-identical to what existed before."""
    from app.printing.labels import label

    inp = _report(db, dict(COMPLETE_PAYLOAD, use_imported_inventory=False))
    assert len(inp.blocks) == 3
    result_labels = {row[0] for row in inp.blocks[2].rows}
    for key in (
        "zakat_stock_qty",
        "zakat_stock_cost_value",
        "zakat_stock_market_value",
        "zakat_stock_only_zakat",
    ):
        assert label(key, "en") not in result_labels
    assert not any(
        line == label("zakat_stock_only_note", "en") for line in inp.meta_lines
    )
    assert build_flowables(inp)
