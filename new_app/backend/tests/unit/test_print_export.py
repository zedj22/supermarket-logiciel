"""Phase 15 Step B tests — /api/v1/exports and /api/v1/print (§19.1).

Covers:

1.  G19 — sale detail carries customer/cashier/store header fields;
    lists stay null (no N+1).
2.  Print — 80 mm / A4 geometry for the approved Phase 15 documents
    (sale — including a VOID-state sale printed via ``document_type=
    "sale"`` — and return), allowlisted paper/locale/document_type
    enums (422 — ``purchase`` is deferred and rejected as unsupported),
    unknown ids (404), the body-dependent scope matrix (sale→pos_sale,
    return→pos_return; ``purchase_view`` does NOT unlock purchase
    printing) and ASCII download filenames.
3.  Export — XLSX structure (title/meta/header/freeze/RTL/autofilter),
    contract parity with ``GET /reports/*``, every report slug in both
    formats, derived-window filename for slow-moving.
4.  Error codes — EXPORT_FORMAT_UNSUPPORTED (422), VALIDATION_ERROR
    (missing dates), REPORT_INVALID_RANGE, EXPORT_ROW_LIMIT (422),
    EXPORT_TOO_LARGE (413), EXPORT_RENDER_FAILED (500), 403 for both
    endpoints.
5.  Audit — exactly one row per attempt, success details carry
    rows/bytes/duration/filename, failure details carry the error code,
    device id lands in the column.
"""

from __future__ import annotations

import io
import json
import re
import uuid
from datetime import date, datetime, timezone

import pytest
from fastapi.testclient import TestClient
from openpyxl import load_workbook
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.printing.labels import label
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


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


@pytest.fixture()
def guest_headers(client):
    return _login(client, "Guest No Roles", "9999")


# ── Helpers ───────────────────────────────────────────────────────────────

_seq = {"n": 0}


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Print Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"PRN{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "50.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _customer(client, headers, name: str = "Print Debtor") -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name, "phone": None}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale(client, headers, product_id: str, customer_id: str | None = None) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": [
            {
                "product_id": product_id,
                "quantity": "2.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            }
        ],
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "200.000",
        "device_id": "POS-1",
    }
    if customer_id is not None:
        payload["customer_id"] = customer_id
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _return(client, headers, product_id: str) -> dict:
    resp = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "lines": [{"product_id": product_id, "quantity": "1.000"}],
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["return"]


def _purchase(client, headers, product_id: str) -> dict:
    sup = client.post("/api/v1/suppliers", json={"name": "Print Supplier"}, headers=headers)
    assert sup.status_code == 201, sup.text
    resp = client.post(
        "/api/v1/purchases",
        json={
            "supplier_id": sup.json()["id"],
            "lines": [{"product_id": product_id, "quantity": "5", "unit_cost": "50.000"}],
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _media_box(content: bytes) -> tuple[float, float]:
    mb = content.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(mb[2]), float(mb[3])


def _export(client, headers, body: dict, **headers_extra):
    return client.post(
        "/api/v1/exports", json=body, headers={**headers, **headers_extra}
    )


def _audit_rows(db, action: str) -> list[AuditLog]:
    rows = db.execute(
        select(AuditLog).where(AuditLog.action == action)
    ).scalars().all()
    return list(rows)


# ── G19 — sale detail header fields ───────────────────────────────────────


def test_g19_detail_header_fields(client, admin_headers):
    product = _product(client, admin_headers)
    customer = _customer(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"], customer["id"])

    detail = client.get(f"/api/v1/sales/{sale['id']}", headers=admin_headers).json()
    assert detail["customer_name"] == "Print Debtor"
    assert detail["cashier_name"] == "Admin"
    assert (detail["store"] or {}).get("name") == settings.STORE_NAME


def test_g19_list_header_stays_null(client, admin_headers):
    product = _product(client, admin_headers)
    _sale(client, admin_headers, product["id"])

    item = client.get("/api/v1/sales", headers=admin_headers).json()["items"][0]
    assert item["customer_name"] is None
    assert item["cashier_name"] is None
    assert item["store"] is None


# ── Print — rendering ─────────────────────────────────────────────────────


def test_print_sale_80mm_ar(client, admin_headers):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": sale["id"],
            "paper": "80mm",
            "locale": "ar",
        },
        headers={**admin_headers, "X-Device-ID": "POS-1"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert resp.headers["content-type"].startswith("application/pdf")
    assert "attachment; filename=" in resp.headers["content-disposition"]
    assert b"/FontFile2" in resp.content  # embedded TTF subset (G7)
    width, _ = _media_box(resp.content)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)  # 80 mm in pt


def test_print_sale_a4_en(client, admin_headers):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": sale["id"],
            "paper": "A4",
            "locale": "en",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    width, height = _media_box(resp.content)
    assert width == pytest.approx(595.28, abs=0.01)
    assert height == pytest.approx(841.89, abs=0.01)


def test_print_return_80mm_fr(client, admin_headers):
    product = _product(client, admin_headers)
    _sale(client, admin_headers, product["id"])
    ret = _return(client, admin_headers, product["id"])

    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "return",
            "document_id": ret["id"],
            "paper": "80mm",
            "locale": "fr",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"


def test_print_voided_sale_via_sale_type(client, admin_headers):
    """Voided sale prints through document_type="sale" (VOID state)."""
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    void = client.post(
        f"/api/v1/sales/{sale['id']}/void",
        json={"reason": "print scope audit"},
        headers=admin_headers,
    )
    assert void.status_code == 200, void.text
    assert void.json()["sale"]["status"] == "void"

    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": sale["id"],
            "paper": "80mm",
            "locale": "ar",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"


def test_print_purchase_rejected_as_unsupported(
    client, admin_headers, cashier_headers, db
):
    """document_type="purchase" is deferred (Step A) → 422, no audit row.

    The admin holds ``purchase_view``; that scope must NOT make purchase
    printing available. Rejection happens at schema validation — before
    any document lookup, scope check, render or ``print`` audit row.
    """
    product = _product(client, admin_headers)
    purchase = _purchase(client, admin_headers, product["id"])

    for headers in (admin_headers, cashier_headers):
        resp = client.post(
            "/api/v1/print",
            json={"document_type": "purchase", "document_id": purchase["id"]},
            headers=headers,
        )
        assert resp.status_code == 422, resp.text
        body = resp.json()
        assert body["error"]["code"] == "VALIDATION_ERROR"
        # field error enumerates the allowlist: exactly sale / return
        details = body["error"]["details"]
        assert set(details) == {"document_type"}
        assert "'sale'" in details["document_type"]
        assert "'return'" in details["document_type"]

    # schema rejection never reaches the service → zero print audit rows
    assert _audit_rows(db, "print") == []


# ── Print — enums, ids, permissions, filename ─────────────────────────────


@pytest.mark.parametrize(
    "body",
    [
        {"document_type": "sale", "document_id": str(uuid.uuid4()), "paper": "A5"},
        {"document_type": "invoice", "document_id": str(uuid.uuid4())},
        {"document_type": "purchase", "document_id": str(uuid.uuid4())},
        {"document_type": "sale", "document_id": str(uuid.uuid4()), "locale": "de"},
        {"document_type": "sale", "document_id": "not-a-uuid"},
    ],
    ids=["paper", "document_type", "document_type_purchase_deferred", "locale", "document_id"],
)
def test_print_rejects_bad_enum_values(client, admin_headers, body):
    resp = client.post("/api/v1/print", json=body, headers=admin_headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


@pytest.mark.parametrize("document_type", ["sale", "return"])
def test_print_unknown_document_404(client, admin_headers, document_type):
    resp = client.post(
        "/api/v1/print",
        json={"document_type": document_type, "document_id": str(uuid.uuid4())},
        headers=admin_headers,
    )
    assert resp.status_code == 404


def test_print_scope_matrix(client, admin_headers, cashier_headers, guest_headers):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    ret = _return(client, admin_headers, product["id"])

    # cashier: pos_sale + pos_return yes (purchase printing is not
    # reachable at all — rejected as unsupported, see the test above)
    resp = client.post(
        "/api/v1/print",
        json={"document_type": "sale", "document_id": sale["id"]},
        headers=cashier_headers,
    )
    assert resp.status_code == 200, resp.text

    resp = client.post(
        "/api/v1/print",
        json={"document_type": "return", "document_id": ret["id"]},
        headers=cashier_headers,
    )
    assert resp.status_code == 200, resp.text

    # guest (no roles at all): no pos_sale
    resp = client.post(
        "/api/v1/print",
        json={"document_type": "sale", "document_id": sale["id"]},
        headers=guest_headers,
    )
    assert resp.status_code == 403


def test_print_filename_is_ascii(client, admin_headers):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    resp = client.post(
        "/api/v1/print",
        json={"document_type": "sale", "document_id": sale["id"]},
        headers=admin_headers,
    )
    cd = resp.headers["content-disposition"]
    name = cd.split('filename="')[1].rstrip('"')
    assert name.startswith("sale_") and name.endswith(".pdf")
    assert re.fullmatch(r"[A-Za-z0-9_.\-]+", name), name


# ── Export — XLSX structure + contract parity ─────────────────────────────


def test_export_financial_xlsx_structure(client, admin_headers):
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "financial",
            "format": "xlsx",
            "locale": "ar",
            "date_from": today,
            "date_to": today,
        },
        **{"X-Device-ID": "POS-1"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:2] == b"PK"
    assert resp.headers["content-type"].startswith(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
    cd = resp.headers["content-disposition"]
    assert cd.startswith('attachment; filename="reports_financial_')
    assert cd.endswith('.xlsx"')
    name = cd.split('filename="')[1].rstrip('"')
    assert re.fullmatch(r"[A-Za-z0-9_.\-]+", name), name

    ws = load_workbook(io.BytesIO(resp.content)).active
    title = ws["A1"].value
    assert isinstance(title, str) and " — " in title
    assert title.endswith(label("report_financial", "ar"))
    assert title.startswith(settings.STORE_NAME)
    assert "generated_at: " in str(ws["A2"].value)
    assert ws.cell(row=4, column=1).value is not None  # header row
    assert str(ws.freeze_panes) == "A5"
    assert ws.sheet_view.rightToLeft is True  # ar → RTL
    assert ws.auto_filter.ref is None  # financial is not row-level
    assert ws.page_setup.orientation == "portrait"


def test_export_financial_parity_with_get(client, admin_headers):
    product = _product(client, admin_headers)
    _sale(client, admin_headers, product["id"])
    today = _today().isoformat()

    got = client.get(
        f"/api/v1/reports/financial?date_from={today}&date_to={today}",
        headers=admin_headers,
    ).json()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "financial",
            "format": "xlsx",
            "locale": "en",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 200, resp.text

    ws = load_workbook(io.BytesIO(resp.content)).active
    assert ws.cell(row=4, column=9).value == label("kpi_net_sales", "en")
    cell = ws.cell(row=5, column=9)
    assert float(cell.value) == float(got["net_sales"])
    assert cell.number_format == "0.000"
    assert ws.sheet_view.rightToLeft is not True  # en → LTR


def test_export_sales_detail_contains_sale(client, admin_headers):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    today = _today().isoformat()

    resp = _export(
        client,
        admin_headers,
        {
            "report": "sales",
            "format": "xlsx",
            "locale": "en",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 200, resp.text

    ws = load_workbook(io.BytesIO(resp.content)).active
    assert ws.cell(row=4, column=1).value == label("col_invoice", "en")
    assert ws.cell(row=5, column=1).value == sale["invoice_number"]
    assert ws.auto_filter.ref is not None  # row-level → autofilter
    assert ws.page_setup.orientation == "landscape"
    assert ws.sheet_view.rightToLeft is not True

    got = client.get(
        f"/api/v1/reports/sales?date_from={today}&date_to={today}",
        headers=admin_headers,
    ).json()
    assert ws.cell(row=5, column=1).value == got["items"][0]["invoice_number"]


# ── Export — report PDFs (orientation) ────────────────────────────────────


def test_export_products_pdf_landscape(client, admin_headers):
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "products",
            "format": "pdf",
            "locale": "en",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert resp.headers["content-type"] == "application/pdf"
    width, height = _media_box(resp.content)
    assert width > height  # landscape


def test_export_daily_pdf_portrait(client, admin_headers):
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "daily",
            "format": "pdf",
            "locale": "ar",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 200, resp.text
    width, height = _media_box(resp.content)
    assert height > width
    assert width == pytest.approx(595.28, abs=0.01)
    assert height == pytest.approx(841.89, abs=0.01)


# ── Export — every slug × both formats ────────────────────────────────────


@pytest.mark.parametrize(
    "report",
    [
        "financial",
        "products",
        "categories",
        "daily",
        "hourly",
        "peak-hours",
        "slow-moving",
        "voided",
        "sales",
        "suppliers",
    ],
)
@pytest.mark.parametrize("fmt", ["xlsx", "pdf"])
def test_export_reports_render(client, admin_headers, report, fmt):
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": report,
            "format": fmt,
            "locale": "en",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 200, resp.text
    if fmt == "xlsx":
        assert resp.content[:2] == b"PK"
    else:
        assert resp.content[:5] == b"%PDF-"
    cd = resp.headers["content-disposition"]
    assert f'reports_{report}_' in cd
    name = cd.split('filename="')[1].rstrip('"')
    assert re.fullmatch(r"[A-Za-z0-9_.\-]+", name), name


def test_export_slow_moving_derived_window(client, admin_headers):
    resp = _export(
        client,
        admin_headers,
        {"report": "slow-moving", "format": "xlsx", "locale": "en", "days": 30},
    )
    assert resp.status_code == 200, resp.text
    cd = resp.headers["content-disposition"]
    assert "reports_slow-moving_20" in cd  # window derived from `days`


# ── Export — error codes ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    "body",
    [
        {"report": "financial", "format": "csv", "date_from": "2026-01-01", "date_to": "2026-01-01"},
        {"report": "nope", "format": "xlsx", "date_from": "2026-01-01", "date_to": "2026-01-01"},
    ],
    ids=["format", "report"],
)
def test_export_unsupported_422(client, admin_headers, body):
    resp = _export(client, admin_headers, body)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "EXPORT_FORMAT_UNSUPPORTED"
    assert resp.json()["error"]["message_key"] == "export_format_unsupported"


def test_export_missing_dates_422(client, admin_headers):
    resp = _export(client, admin_headers, {"report": "financial", "format": "xlsx"})
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_export_invalid_range_422(client, admin_headers):
    resp = _export(
        client,
        admin_headers,
        {
            "report": "daily",
            "format": "xlsx",
            "date_from": _today().isoformat(),
            "date_to": "2020-01-01",
        },
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "REPORT_INVALID_RANGE"


def test_export_row_limit_422(client, admin_headers, monkeypatch):
    import app.services.export as export_mod

    monkeypatch.setattr(export_mod, "EXPORT_ROW_LIMIT", -1)
    resp = _export(
        client,
        admin_headers,
        {"report": "slow-moving", "format": "xlsx", "locale": "en"},
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "EXPORT_ROW_LIMIT"


def test_export_too_large_413(client, admin_headers, monkeypatch):
    import app.services.export as export_mod

    monkeypatch.setattr(export_mod, "MAX_EXPORT_BYTES", 10)
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "financial",
            "format": "xlsx",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "EXPORT_TOO_LARGE"


def test_export_render_failed_500(client, admin_headers, monkeypatch):
    import app.services.export as export_mod

    def boom(*args, **kwargs):
        raise RuntimeError("renderer exploded")

    monkeypatch.setattr(export_mod, "render_xlsx", boom)
    today = _today().isoformat()
    resp = _export(
        client,
        admin_headers,
        {
            "report": "financial",
            "format": "xlsx",
            "date_from": today,
            "date_to": today,
        },
    )
    assert resp.status_code == 500
    assert resp.json()["error"]["code"] == "EXPORT_RENDER_FAILED"


def test_export_forbidden_403(client, cashier_headers, guest_headers):
    today = _today().isoformat()
    body = {
        "report": "financial",
        "format": "xlsx",
        "date_from": today,
        "date_to": today,
    }
    for headers in (cashier_headers, guest_headers):
        resp = _export(client, headers, body)
        assert resp.status_code == 403
        assert resp.json()["error"]["details"]["required_permission"] == "export_data"


# ── Audit ─────────────────────────────────────────────────────────────────


def test_export_audit_success_and_failure(client, admin_headers, db):
    today = _today().isoformat()
    ok = _export(
        client,
        admin_headers,
        {
            "report": "financial",
            "format": "xlsx",
            "locale": "en",
            "date_from": today,
            "date_to": today,
        },
        **{"X-Device-ID": "POS-1"},
    )
    assert ok.status_code == 200

    # three documented failures → three failure rows
    _export(client, admin_headers, {"report": "financial", "format": "csv"})
    _export(client, admin_headers, {"report": "financial", "format": "xlsx"})
    _export(
        client,
        admin_headers,
        {"report": "daily", "format": "xlsx", "date_from": today, "date_to": "2020-01-01"},
    )

    rows = _audit_rows(db, "export")
    successes = [r for r in rows if json.loads(r.details)["result"] == "success"]
    failures = [r for r in rows if json.loads(r.details)["result"] == "failure"]
    assert len(successes) == 1
    assert len(failures) == 3

    details = json.loads(successes[0].details)
    assert set(details) == {
        "report",
        "format",
        "locale",
        "date_from",
        "date_to",
        "filters",
        "rows",
        "bytes",
        "duration_ms",
        "filename",
        "result",
        "error_code",
    }
    assert details["report"] == "financial"
    assert details["rows"] == 1  # main row (no sales → empty device block)
    assert details["bytes"] > 0
    assert details["filename"].endswith(".xlsx")
    assert successes[0].device_id == "POS-1"
    assert successes[0].user_id is not None
    assert successes[0].entity_type == "export"
    assert successes[0].entity_id is None
    # no payload data in audit details (§12.2)
    assert "net_sales" not in details
    assert "200.000" not in json.dumps(details)

    error_codes = {json.loads(r.details)["error_code"] for r in failures}
    assert error_codes == {
        "EXPORT_FORMAT_UNSUPPORTED",
        "VALIDATION_ERROR",
        "REPORT_INVALID_RANGE",
    }


def test_print_audit_success_and_failure(client, admin_headers, db):
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    ok = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": sale["id"],
            "paper": "80mm",
            "locale": "ar",
        },
        headers={**admin_headers, "X-Device-ID": "POS-1"},
    )
    assert ok.status_code == 200
    missing = client.post(
        "/api/v1/print",
        json={"document_type": "sale", "document_id": str(uuid.uuid4())},
        headers=admin_headers,
    )
    assert missing.status_code == 404

    rows = _audit_rows(db, "print")
    successes = [r for r in rows if json.loads(r.details)["result"] == "success"]
    failures = [r for r in rows if json.loads(r.details)["result"] == "failure"]
    assert len(successes) == 1
    assert len(failures) == 1

    details = json.loads(successes[0].details)
    assert set(details) == {
        "document_type",
        "document_number",
        "paper",
        "locale",
        "bytes",
        "duration_ms",
        "filename",
        "result",
        "error_code",
    }
    assert details["document_type"] == "sale"
    assert details["paper"] == "80mm"
    assert details["bytes"] > 0
    assert successes[0].device_id == "POS-1"
    assert successes[0].entity_type == "sale"
    assert str(successes[0].entity_id) == sale["id"]

    failure_details = json.loads(failures[0].details)
    assert failure_details["error_code"] == "NOT_FOUND"
    assert failure_details["bytes"] == 0
