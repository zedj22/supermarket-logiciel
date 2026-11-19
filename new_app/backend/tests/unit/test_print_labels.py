"""Barcode-label subphase tests — POST /api/v1/print/labels.

Covers:

1.  Geometry — default 50x30 mm sheet on A4 (3 cols x 9 rows = 27/page),
    pagination (30 labels -> 2 pages), explicit cols/rows respected, the
    80 mm roll (auto single column; pinned rows derive the page height).
2.  Content — product name, effective price, verbatim Code128 value and
    the Settings store name reach the PDF; Arabic names are drawn shaped
    (one bidi pass); a unit price carries its localized unit suffix.
3.  Price rule (STOP condition) — promo products print the SERVER
    effective promo price plus the untouched retail struck through;
    non-promo products print retail only. Clients never send prices.
4.  No barcode -> price label still renders (never an invented barcode);
    non-Code128 (non-ASCII) barcode -> 422, never a substitution.
5.  Scope matrix — product_view (admin + cashier) yes, guest 403 with
    `required_permission: product_view`; schema rejects bad bodies with
    no audit row.
6.  Audit — one `print` row per attempt (entity_type=product_label),
    success/failure details, device id column; render failures map to
    PRINT_RENDER_FAILED (500).
7.  Perf — a 1000-label batch stays inside the render budget.
8.  Presentation — long names ellipsize within the wrap budget,
    identical copies draw identical text, the percent badge prints
    the DECLARED promotion value (percentage only, shaped in RTL)
    and a fixed-price promotion prints prices without a badge.
9.  Roll labels (`paper="roll"`) — ONE PAGE PER PHYSICAL LABEL
    (a 4-label job is a 4-page document: the page is the label, so a
    label printer can never print just the first one), quantities
    expanded in selection order, media width / margins honoured,
    schema rejects impossible media geometry (422), A4 ignores roll
    fields (back-compat), and the roll path touches no inventory /
    no sales (same DB-free contract as A4).
10. Layout — store name + product name bold and larger, every block
    centred horizontally, barcode centred with quiet zones, digits
    centred under the bars, no block overlapping another.
"""

from __future__ import annotations

import json
import re
import base64
import zlib
import sys
import time
import uuid
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.inventory import InventoryMovement
from app.models.sale import Sale
from app.printing.fonts import FONT_BOLD, FONT_REGULAR, register_fonts
from app.printing.price_labels import (
    PriceLabel,
    _measure,
    _wrap,
    render_price_labels,
)
from app.printing.text import shape_text
from reportlab.pdfbase.pdfmetrics import stringWidth
from app.schemas.export import LabelLayout
from app.services.auth import AuthService

# ── Fixtures (same harness as test_print_export.py) ──────────────────────


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


def _product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Label Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"LBL{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "50.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _labels(
    client,
    headers,
    items: list[dict],
    *,
    paper: str = "A4",
    locale: str = "en",
    layout: dict | None = None,
    **extra,
):
    body: dict = {"items": items, "paper": paper, "locale": locale}
    if layout is not None:
        body["layout"] = layout
    body.update(extra)
    return client.post(
        "/api/v1/print/labels",
        json=body,
        headers={**headers, "X-Device-ID": "POS-1"},
    )


def _media_box(content: bytes) -> tuple[float, float]:
    mb = content.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(mb[2]), float(mb[3])


def _page_count(content: bytes) -> int:
    return len(re.findall(rb"/Type\s*/Page[^s]", content))


def _blocks(raw: bytes) -> list[str]:
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return [text for _font, text in g7_spike.extract_text_blocks(raw)]


def _text(raw: bytes) -> str:
    return "\n".join(_blocks(raw))


def _audit_rows(db, action: str) -> list[AuditLog]:
    return list(db.execute(select(AuditLog).where(AuditLog.action == action)).scalars().all())


def _promo(client, headers, product_id: str) -> dict:
    resp = client.post(
        "/api/v1/promotions",
        json={
            "client_request_id": str(uuid.uuid4()),
            "name": "Label Promo",
            "promotion_type": "percentage",
            "value": "20",
            "product_ids": [product_id],
            "is_active": True,
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _promo_fixed(client, headers, product_id: str) -> dict:
    resp = client.post(
        "/api/v1/promotions",
        json={
            "client_request_id": str(uuid.uuid4()),
            "name": "Label Fixed Promo",
            "promotion_type": "fixed_price",
            "value": "80",
            "product_ids": [product_id],
            "is_active": True,
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


# ── Geometry ──────────────────────────────────────────────────────────────


def test_labels_render_default_a4_sheet(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])

    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert resp.headers["content-type"].startswith("application/pdf")
    assert b"/FontFile2" in resp.content  # embedded TTF subset (G7)
    width, height = _media_box(resp.content)
    assert width == pytest.approx(595.28, abs=0.01)  # A4 portrait
    assert height == pytest.approx(841.89, abs=0.01)
    cd = resp.headers["content-disposition"]
    name = cd.split('filename="')[1].rstrip('"')
    assert name.startswith("labels_") and name.endswith(".pdf")
    assert re.fullmatch(r"[A-Za-z0-9_.\-]+", name), name


def test_labels_default_grid_paginates_27_per_page(client, admin_headers):
    product = _product(client, admin_headers)
    # 50x30 labels, 2/5 gaps, 5mm margins -> 3 cols x 9 rows = 27/page
    resp = _labels(client, admin_headers, [{"product_id": product["id"], "quantity": 30}])
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 2  # ceil(30 / 27)


def test_labels_explicit_cols_rows_respected(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 5}],
        layout={"columns": 2, "rows": 2},
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 2  # ceil(5 / 4)


def test_labels_80mm_roll_pinned_rows_derive_height(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"]}],
        paper="80mm",
        layout={"columns": 1, "rows": 2},
    )
    assert resp.status_code == 200, resp.text
    width, height = _media_box(resp.content)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)
    # 2*5 margin + 2*30 label + 1*2 gap = 72 mm
    assert height == pytest.approx(72 * 2.8346456693, abs=0.01)


def test_labels_80mm_auto_fits_single_column(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}], paper="80mm")
    assert resp.status_code == 200, resp.text
    width, _ = _media_box(resp.content)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)
    assert _page_count(resp.content) == 1


# ── Content ───────────────────────────────────────────────────────────────


def test_labels_carry_name_price_barcode_and_store(client, admin_headers):
    product = _product(
        client, admin_headers, name="Apple Juice", barcode="1234567890123"
    )
    saved = client.put(
        "/api/v1/settings", json={"store_name": "Label Store"}, headers=admin_headers
    )
    assert saved.status_code == 200, saved.text

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text

    text = _text(resp.content)
    assert "Apple Juice" in text
    assert "100.00 DA" in text
    assert "1234567890123" in text  # verbatim barcode + human readable
    assert "Label Store" in text  # tiny store identity line


def test_labels_arabic_name_is_drawn_shaped(client, admin_headers):
    name = "عصير التفاح الطازج"
    product = _product(client, admin_headers, name=name, barcode="AR123")
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}], locale="ar")
    assert resp.status_code == 200, resp.text

    blocks = _blocks(resp.content)
    shaped = shape_text(name)
    assert any(shaped == b or shaped in b for b in blocks), blocks


def test_labels_unit_price_carries_localized_unit_suffix(client, admin_headers):
    product = _product(
        client, admin_headers, name="Tomatoes", barcode="TOM1", unit="kg", price="250.000"
    )
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}], locale="en")
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "250.00 DA / kg" in text

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}], locale="ar")
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    # piece suffix never printed; Arabic unit label appears with the price
    assert "250.00 DA" in text
    assert shape_text("كغ") in text


def test_labels_without_barcode_still_render(client, admin_headers):
    product = _product(client, admin_headers, name="Bread", barcode=None)
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "Bread" in text
    assert "100.00 DA" in text


def test_labels_long_name_is_ellipsized_and_keeps_barcode(client, admin_headers):
    name = (
        "Premium Organic Wholegrain Breakfast Cereal With Raisins Honey "
        "Almonds And Dark Chocolate 500g Resealable Family Pack"
    )
    product = _product(client, admin_headers, name=name, barcode="1234567890128")
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "…" in text  # truncated, never overflowing the label
    assert name not in text  # full string never drawn
    assert "1234567890128" in text  # barcode untouched
    assert "100.00 DA" in text


def test_label_name_wrap_never_exceeds_width_or_line_count():
    register_fonts()
    max_w = 135.7
    long_name = (
        "Premium Organic Wholegrain Breakfast Cereal With Raisins Honey "
        "Almonds And Dark Chocolate 500g Resealable Family Pack"
    )
    lines = _wrap(long_name, FONT_BOLD, 7.2, max_w, 2)
    assert 1 <= len(lines) <= 2
    for line in lines:
        assert _measure(line, FONT_BOLD, 7.2) <= max_w + 0.01
    assert lines[-1].endswith("…")  # overflow marked, not clipped


def test_labels_identical_copies_render_identical_text(client, admin_headers):
    product = _product(client, admin_headers, name="Twin Item", barcode="TWN1")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 2}],
        layout={"columns": 1, "rows": 2},
    )
    assert resp.status_code == 200, resp.text
    blocks = _blocks(resp.content)
    # stream order = draw order: label 1's blocks, then label 2's
    assert len(blocks) % 2 == 0 and len(blocks) >= 2, blocks
    half = len(blocks) // 2
    assert blocks[:half] == blocks[half:]


# ── Price rule (STOP condition) ───────────────────────────────────────────


def test_labels_promo_prints_effective_price_and_struck_retail(
    client, admin_headers
):
    product = _product(client, admin_headers, name="Promo Item", barcode="PRO1")
    _promo(client, admin_headers, product["id"])

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "80.00 DA" in text  # server effective promo price (20% off 100)
    assert "100.00 DA" in text  # retail kept, drawn struck through


def test_labels_non_promo_prints_retail_only(client, admin_headers):
    product = _product(client, admin_headers, name="Plain Item", barcode="PLN1")
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert text.count("100.00 DA") == 1  # no struck duplicate


def test_labels_deactivated_promotion_restores_retail(client, admin_headers):
    product = _product(client, admin_headers, name="Toggle Item", barcode="TGL1")
    promo = _promo(client, admin_headers, product["id"])
    toggled = client.post(
        f"/api/v1/promotions/{promo['id']}/toggle", headers=admin_headers
    )
    assert toggled.status_code == 200, toggled.text

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "100.00 DA" in text
    assert "80.00 DA" not in text


# ── Percent badge (declared value, never computed) ────────────────────────


def test_labels_percentage_promo_prints_declared_off_badge(client, admin_headers):
    product = _product(client, admin_headers, name="Badge Item", barcode="BDG1")
    _promo(client, admin_headers, product["id"])

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "20% OFF" in text  # declared percent straight from the rule
    assert "80.00 DA" in text  # server effective promo price
    assert "100.00 DA" in text  # struck retail on its own line


def test_labels_arabic_off_badge_is_shaped(client, admin_headers):
    product = _product(client, admin_headers, name="Badge عربي", barcode="BDG2")
    _promo(client, admin_headers, product["id"])

    resp = _labels(
        client, admin_headers, [{"product_id": product["id"]}], locale="ar"
    )
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert shape_text("خصم 20%") in text


def test_labels_fixed_price_promo_shows_prices_without_badge(
    client, admin_headers
):
    product = _product(client, admin_headers, name="Fixed Item", barcode="FIX1")
    _promo_fixed(client, admin_headers, product["id"])

    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "80.00 DA" in text  # server effective fixed price
    assert "100.00 DA" in text  # struck retail kept
    assert "OFF" not in text  # fixed price declares no percent
    assert "خصم 20%" not in text


# ── Barcodes: never invented, never substituted ───────────────────────────


def test_labels_non_ascii_barcode_rejected_422(client, admin_headers, db):
    product = _product(client, admin_headers, name="Arabic Code", barcode="منتج123")
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 422, resp.text
    body = resp.json()
    assert body["error"]["code"] == "VALIDATION_ERROR"
    assert body["error"]["details"]["product_id"] == product["id"]
    # service-level rejection still leaves its documented failure row
    failures = [
        r for r in _audit_rows(db, "print")
        if json.loads(r.details)["result"] == "failure"
    ]
    assert len(failures) == 1
    assert json.loads(failures[0].details)["error_code"] == "VALIDATION_ERROR"


# ── Scope matrix ──────────────────────────────────────────────────────────


def test_labels_scope_matrix(client, admin_headers, cashier_headers, guest_headers):
    product = _product(client, admin_headers)

    for headers in (admin_headers, cashier_headers):  # both hold product_view
        resp = _labels(client, headers, [{"product_id": product["id"]}])
        assert resp.status_code == 200, resp.text

    resp = _labels(client, guest_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 403, resp.text
    assert resp.json()["error"]["details"]["required_permission"] == "product_view"


# ── Validation (schema level, no audit row) ───────────────────────────────


@pytest.mark.parametrize(
    "body",
    [
        {"items": []},
        {"items": [{"product_id": str(uuid.uuid4()), "quantity": 0}]},
        {"items": [{"product_id": str(uuid.uuid4()), "quantity": 1000}]},
        {"items": [{"product_id": "not-a-uuid"}]},
        {"items": [{"product_id": str(uuid.uuid4())}], "paper": "A5"},
        {"items": [{"product_id": str(uuid.uuid4())}], "locale": "de"},
        {  # columns exceed paper width
            "items": [{"product_id": str(uuid.uuid4())}],
            "layout": {"columns": 30},
        },
        {  # rows exceed A4 height
            "items": [{"product_id": str(uuid.uuid4())}],
            "layout": {"rows": 100},
        },
        {  # label taller than the sheet
            "items": [{"product_id": str(uuid.uuid4())}],
            "layout": {"label_height_mm": 100, "margin_y_mm": 50, "rows": 3},
        },
        {  # label wider than the sheet
            "items": [{"product_id": str(uuid.uuid4())}],
            "layout": {"label_width_mm": 100, "margin_x_mm": 50, "columns": 2},
        },
        {  # label below minimum size
            "items": [{"product_id": str(uuid.uuid4())}],
            "layout": {"label_height_mm": 10},
        },
    ],
    ids=[
        "empty_items",
        "quantity_zero",
        "quantity_too_big",
        "bad_uuid",
        "paper",
        "locale",
        "columns_overflow",
        "rows_overflow",
        "label_too_tall",
        "label_too_wide",
        "label_too_small",
    ],
)
def test_labels_rejects_bad_bodies_422(client, admin_headers, db, body):
    before = len(_audit_rows(db, "print"))
    resp = client.post("/api/v1/print/labels", json=body, headers=admin_headers)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert len(_audit_rows(db, "print")) == before  # rejected pre-service


def test_labels_batch_cap_422(client, admin_headers):
    product = _product(client, admin_headers)
    body = {
        "items": [
            {"product_id": product["id"], "quantity": 999},
            {"product_id": product["id"], "quantity": 999},
            {"product_id": product["id"], "quantity": 999},
            {"product_id": product["id"], "quantity": 999},
            {"product_id": product["id"], "quantity": 999},
            {"product_id": product["id"], "quantity": 999},
        ]
    }
    resp = client.post("/api/v1/print/labels", json=body, headers=admin_headers)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_labels_duplicate_product_ids_422(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(
        client,
        admin_headers,
        [
            {"product_id": product["id"]},
            {"product_id": product["id"]},
        ],
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_labels_unknown_product_404(client, admin_headers, db):
    resp = _labels(client, admin_headers, [{"product_id": str(uuid.uuid4())}])
    assert resp.status_code == 404, resp.text
    assert resp.json()["error"]["code"] == "NOT_FOUND"


# ── Error mapping ─────────────────────────────────────────────────────────


def test_labels_render_failed_500(client, admin_headers, monkeypatch, db):
    import app.services.print as print_mod

    def boom(*args, **kwargs):
        raise RuntimeError("label renderer exploded")

    monkeypatch.setattr(print_mod, "render_price_labels", boom)
    product = _product(client, admin_headers)
    resp = _labels(client, admin_headers, [{"product_id": product["id"]}])
    assert resp.status_code == 500, resp.text
    assert resp.json()["error"]["code"] == "PRINT_RENDER_FAILED"

    failures = [
        r
        for r in _audit_rows(db, "print")
        if json.loads(r.details)["result"] == "failure"
    ]
    assert any(
        json.loads(r.details)["error_code"] == "PRINT_RENDER_FAILED"
        for r in failures
    )


# ── Audit ─────────────────────────────────────────────────────────────────


def test_labels_audit_success_and_failure(client, admin_headers, db):
    product = _product(client, admin_headers)

    ok = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 2}],
        layout={"columns": 1, "rows": 1},
    )
    assert ok.status_code == 200, ok.text
    missing = _labels(client, admin_headers, [{"product_id": str(uuid.uuid4())}])
    assert missing.status_code == 404

    rows = _audit_rows(db, "print")
    successes = [r for r in rows if json.loads(r.details)["result"] == "success"]
    failures = [r for r in rows if json.loads(r.details)["result"] == "failure"]
    assert len(successes) == 1
    assert len(failures) == 1

    details = json.loads(successes[0].details)
    assert set(details) == {
        "document_type",
        "products",
        "total_labels",
        "paper",
        "locale",
        "bytes",
        "duration_ms",
        "filename",
        "result",
        "error_code",
    }
    assert details["document_type"] == "product_label"
    assert details["products"] == 1
    assert details["total_labels"] == 2
    assert details["paper"] == "A4"
    assert details["bytes"] > 0
    assert details["filename"].endswith(".pdf")
    assert successes[0].entity_type == "product_label"
    assert successes[0].entity_id is None
    assert successes[0].device_id == "POS-1"
    assert successes[0].user_id is not None
    # no product payload in audit details (§12.2)
    assert product["name"] not in json.dumps(details)
    assert product["id"] not in json.dumps(details)

    failure_details = json.loads(failures[0].details)
    assert failure_details["error_code"] == "NOT_FOUND"
    assert failure_details["bytes"] == 0


# ── Perf budget ───────────────────────────────────────────────────────────


def test_labels_1000_render_within_budget(client, admin_headers):
    p1 = _product(client, admin_headers, name="Bulk A", barcode="BLK001")
    p2 = _product(client, admin_headers, name="Bulk B", barcode="BLK002")
    started = time.perf_counter()
    resp = _labels(
        client,
        admin_headers,
        [
            {"product_id": p1["id"], "quantity": 500},
            {"product_id": p2["id"], "quantity": 500},
        ],
    )
    elapsed = time.perf_counter() - started
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 38  # ceil(1000 / 27)
    assert elapsed < 10.0, f"1000 labels took {elapsed:.2f}s"

# -- Roll labels (adhesive media, paper="roll") --------------------------

_MM = 2.8346456693  # mm -> pt


def _roll_layout(**overrides) -> dict:
    """Stock roll geometry: 58 mm media, 50x30 label, 2 mm gap, flush."""
    layout = {"roll_width_mm": 58.0, "label_width_mm": 50.0, "label_height_mm": 30.0, "gap_y_mm": 2.0}
    layout.update(overrides)
    return layout


def _tm_pairs(pdf: bytes) -> list[tuple[float, float]]:
    """All text positions (x, y) from the (uncompressed) content stream."""
    return [
        (float(x), float(y))
        for x, y in re.findall(rb"([\d.-]+) ([\d.-]+) Tm", pdf)
    ]


def _price_row(name: str, barcode: str, *, promo: bool = False) -> PriceLabel:
    return PriceLabel(
        name=name,
        barcode=barcode,
        retail=Decimal("200.000"),
        price=Decimal("160.000" if promo else "200.000"),
        promo=promo,
        unit="piece",
        store_name="Roll Store",
        discount_percent="20" if promo else None,
    )


# ── Render introspection (raw, uncompressed content streams) ─────────────

_TJ_RE = re.compile(r"\(((?:[^()\\]|\\.)*)\)\s*Tj")
_RUN_RE = re.compile(r"1 0 0 1 ([\d.-]+) ([\d.-]+) Tm /(F\d+)\+\d+ ([\d.]+) Tf")
_BAR_RE = re.compile(
    r"1 0 0 1 ([\d.-]+) ([\d.-]+) cm|n ([\d.-]+) ([\d.-]+) ([\d.-]+) ([\d.-]+) re f\*"
)


@dataclass(frozen=True)
class _Run:
    """One drawn string: font resource, size, origin and text."""

    font: str
    size: float
    x: float
    y: float
    text: str


def _decode_candidates(body: bytes) -> list[bytes]:
    """Every plausible decoding of a PDF stream (page streams are either
    plain, FlateDecode, or ASCII85Decode + FlateDecode)."""
    out: list[bytes] = []
    try:
        out.append(zlib.decompress(body))
    except zlib.error:
        pass
    compact = b"".join(body.split())
    for adobe in (False, True):
        try:
            a85 = base64.a85decode(compact, adobe=adobe)
        except ValueError:
            continue
        out.append(a85)
        try:
            out.append(zlib.decompress(a85))
        except zlib.error:
            pass
        break
    out.append(body)
    return out


def _page_streams(pdf: bytes) -> list[str]:
    """One decoded content stream per rendered page, in page order."""
    streams: list[str] = []
    for match in re.finditer(rb"stream\r?\n(.*?)endstream", pdf, re.S):
        for candidate in _decode_candidates(match.group(1)):
            if b"BT" in candidate and b"Tf" in candidate and b"begincmap" not in candidate:
                streams.append(candidate.decode("latin-1"))
                break
    return streams


def _runs(stream: str) -> list[_Run]:
    """Every drawn string on a page, in draw order."""
    runs: list[_Run] = []
    for match in _RUN_RE.finditer(stream):
        x, y, font, size = match.groups()
        text = _TJ_RE.search(stream, match.end())
        if text is None:
            continue
        runs.append(
            _Run(
                font=font,
                size=float(size),
                x=float(x),
                y=float(y),
                text=text.group(1).replace("\\(", "(").replace("\\)", ")"),
            )
        )
    return runs


def _page_boxes(pdf: bytes) -> list[tuple[float, float]]:
    """(width, height) of every page, in points."""
    boxes: list[tuple[float, float]] = []
    for raw in re.findall(rb"/MediaBox\s*\[([^\]]*)\]", pdf):
        parts = raw.split()
        boxes.append((float(parts[2]), float(parts[3])))
    return boxes


def _bar_bounds(stream: str) -> tuple[float, float, float, float]:
    """(x0, x1, y0, y1) of the drawn Code128 bars, in page points."""
    xs: list[float] = []
    ys: list[float] = []
    tx = ty = 0.0
    for token in _BAR_RE.finditer(stream):
        if token.group(1) is not None:
            tx, ty = float(token.group(1)), float(token.group(2))
        elif tx or ty:
            x, y, w, h = (float(token.group(i)) for i in (3, 4, 5, 6))
            xs.extend([tx + x, tx + x + w])
            ys.extend([ty + y, ty + y + h])
    assert xs, "no barcode rects found"
    return min(xs), max(xs), min(ys), max(ys)


def _roll_45(**overrides) -> dict:
    """XP-365B stock: 45 mm media, 45x35 mm label, no liner offsets."""
    layout = {
        "roll_width_mm": 45.0,
        "label_width_mm": 45.0,
        "label_height_mm": 35.0,
        "gap_y_mm": 0.0,
    }
    layout.update(overrides)
    return layout


def _page_names(pdf: bytes) -> list[list[str]]:
    """The product-name run of every page (the run after the store line)."""
    names: list[list[str]] = []
    for stream in _page_streams(pdf):
        runs = _runs(stream)
        names.append([r.text for r in runs[1:2]])
    return names


# ── One page per label (the multi-label defect) ──────────────────────────


def test_labels_roll_renders_one_page_per_label(client, admin_headers):
    product = _product(client, admin_headers, name="Roll Product", barcode="ROLL001")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 3}],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert b"/FontFile2" in resp.content
    # Three labels -> three pages, each exactly one 45x35 mm label.
    assert _page_count(resp.content) == 3
    for width, height in _page_boxes(resp.content):
        assert width == pytest.approx(45 * _MM, abs=0.01)
        assert height == pytest.approx(35 * _MM, abs=0.01)


def test_labels_roll_single_label_is_one_page(client, admin_headers):
    product = _product(client, admin_headers, name="Solo Label", barcode="SOLO1")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 1}],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 1
    text = _text(resp.content)
    assert "Solo Label" in text
    assert "SOLO1" in text


def test_labels_roll_quantity_five_is_five_pages(client, admin_headers):
    product = _product(client, admin_headers, name="Five Copies", barcode="FIVE5")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 5}],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 5
    streams = _page_streams(resp.content)
    assert len(streams) == 5
    for stream in streams:  # every copy carries the product + its barcode
        assert "Five Copies" in stream
        assert "FIVE5" in stream


def test_labels_roll_mixed_quantities_two_one_one_is_four_labels(
    client, admin_headers
):
    """The reported case: 1001 x2, aroma2 x1, asa x1 -> exactly 4 labels."""
    a = _product(client, admin_headers, name="1001", barcode="1001")
    b = _product(client, admin_headers, name="aroma2", barcode="AROMA2")
    c = _product(client, admin_headers, name="asa", barcode="ASA1")
    resp = _labels(
        client,
        admin_headers,
        [
            {"product_id": a["id"], "quantity": 2},
            {"product_id": b["id"], "quantity": 1},
            {"product_id": c["id"], "quantity": 1},
        ],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 4
    assert _page_names(resp.content) == [["1001"], ["1001"], ["aroma2"], ["asa"]]


def test_labels_roll_nothing_dropped_or_duplicated(client, admin_headers):
    a = _product(client, admin_headers, name="Alpha", barcode="ALP1")
    b = _product(client, admin_headers, name="Beta", barcode="BET1")
    resp = _labels(
        client,
        admin_headers,
        [
            {"product_id": a["id"], "quantity": 3},
            {"product_id": b["id"], "quantity": 2},
        ],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    names = [page[0] for page in _page_names(resp.content)]
    assert len(names) == 5  # 3 + 2, no more, no less
    assert names.count("Alpha") == 3
    assert names.count("Beta") == 2
    assert names == ["Alpha", "Alpha", "Alpha", "Beta", "Beta"]  # order kept


def test_labels_roll_zero_quantity_is_rejected(client, admin_headers):
    product = _product(client, admin_headers)
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 0}],
        paper="roll",
        layout=_roll_45(),
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_labels_roll_each_page_holds_exactly_one_label():
    row = _price_row("Gap Probe", "GAP1", promo=True)
    layout = LabelLayout(**_roll_layout(margin_left_mm=4.0))
    pdf = render_price_labels([row] * 3, layout, "roll", "en", compress=False)

    streams = _page_streams(pdf)
    assert len(streams) == 3 and _page_count(pdf) == 3
    # Identical copies -> identical page content (same runs, same spots).
    pages = [
        [
            (r.font, round(r.size, 3), round(r.x, 3), round(r.y, 3), r.text)
            for r in _runs(s)
        ]
        for s in streams
    ]
    assert pages[0] == pages[1] == pages[2]
    for stream in streams:
        assert "Gap Probe" in stream


def test_labels_roll_margins_keep_text_inside_media():
    row = _price_row("Margin Probe", "MRG1")
    layout = LabelLayout(
        **_roll_layout(margin_top_mm=5.0, margin_left_mm=4.0, margin_right_mm=4.0)
    )
    pdf = render_price_labels([row] * 2, layout, "roll", "en", compress=False)
    width, height = _media_box(pdf)
    assert width == pytest.approx(58 * _MM, abs=0.01)
    assert height == pytest.approx(30 * _MM, abs=0.01)  # one label per page
    assert _page_count(pdf) == 2

    left_pt = 4.0 * _MM
    top_limit = height - 5.0 * _MM  # text never enters the top margin
    for stream in _page_streams(pdf):
        for run in _runs(stream):
            assert left_pt - 0.01 <= run.x <= width
            assert 0.0 <= run.y <= top_limit


def test_labels_roll_multiple_copies_print_in_order(client, admin_headers):
    a = _product(client, admin_headers, name="Roll Alpha", barcode="RAL001")
    b = _product(client, admin_headers, name="Roll Beta", barcode="RBE001")
    resp = _labels(
        client,
        admin_headers,
        [
            {"product_id": a["id"], "quantity": 3},
            {"product_id": b["id"], "quantity": 5},
        ],
        paper="roll",
        layout=_roll_45(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 8
    names = [page[0] for page in _page_names(resp.content)]
    assert names == ["Roll Alpha"] * 3 + ["Roll Beta"] * 5


def test_labels_roll_ignores_columns_and_rows(client, admin_headers):
    product = _product(client, admin_headers, name="Single Column", barcode="SC001")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 2}],
        paper="roll",
        layout={"columns": 2, "rows": 5},
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert _page_count(resp.content) == 2  # rows never paginate a roll
    for width, height in _page_boxes(resp.content):
        assert width == pytest.approx(58 * _MM, abs=0.01)  # always one across
        assert height == pytest.approx(30 * _MM, abs=0.01)


# ── Redesigned label layout (centred, bold, larger) ──────────────────────


def _single_label_pdf(**layout_overrides) -> tuple[bytes, str, float, float]:
    row = _price_row("Centred Item", "CEN123")
    layout = LabelLayout(**_roll_45(**layout_overrides))
    pdf = render_price_labels([row], layout, "roll", "en", compress=False)
    width, height = _media_box(pdf)
    return pdf, _page_streams(pdf)[0], width, height


def test_label_store_and_name_are_bold_and_larger():
    _pdf, stream, _w, _h = _single_label_pdf()
    runs = {run.text: run for run in _runs(stream)}

    store = runs["Roll Store"]
    name = runs["Centred Item"]
    price = runs["200.00 DA"]
    digits = runs["CEN123"]

    # Noticeably larger than the old 5 pt store / 7.2 pt name ramp.
    assert store.size > 5.0 and store.size >= 7.0
    assert name.size > 7.2 and name.size >= 9.5
    assert price.size >= 12.0
    # Store, name and price share ONE bold face; the human-readable
    # barcode line stays regular.
    assert store.font == name.font == price.font
    assert digits.font != name.font


def test_label_blocks_are_centered_horizontally():
    _pdf, stream, width, _h = _single_label_pdf()
    center = width / 2
    runs = _runs(stream)
    assert {r.text for r in runs} >= {
        "Roll Store",
        "Centred Item",
        "200.00 DA",
        "CEN123",
    }
    for run in runs:
        font = FONT_REGULAR if run.text == "CEN123" else FONT_BOLD
        half = stringWidth(shape_text(run.text), font, run.size) / 2
        assert run.x + half == pytest.approx(center, abs=1.0), run


def test_label_barcode_is_centered_and_keeps_quiet_zones():
    _pdf, stream, width, _h = _single_label_pdf()
    x0, x1, y0, y1 = _bar_bounds(stream)
    assert (x0 + x1) / 2 == pytest.approx(width / 2, abs=1.0)  # centred
    assert x0 >= 3.0  # ≈1 mm quiet zone on each side, never edge-to-edge
    assert width - x1 >= 3.0
    assert y1 - y0 >= 9.0  # tall enough to scan

    digits = next(r for r in _runs(stream) if r.text == "CEN123")
    assert digits.y < y0  # human-readable value sits BELOW the bars


def test_label_blocks_stack_without_overlap():
    _pdf, stream, _w, height = _single_label_pdf()
    runs = {run.text: run for run in _runs(stream)}
    store, name, price = runs["Roll Store"], runs["Centred Item"], runs["200.00 DA"]
    digits = runs["CEN123"]
    _x0, _x1, bars_y0, bars_y1 = _bar_bounds(stream)

    # store -> name -> price -> bars -> digits, top to bottom
    assert store.y > name.y > price.y > bars_y1 > bars_y0 > digits.y
    assert bars_y1 <= height  # nothing above the label
    assert digits.y >= 0.0  # nothing below the label


def test_label_long_name_wraps_inside_the_label():
    name = "Premium Organic Wholegrain Breakfast Cereal With Raisins"
    row = PriceLabel(
        name=name,
        barcode="1234567890128",
        retail=Decimal("200.000"),
        price=Decimal("200.000"),
        promo=False,
        unit="piece",
        store_name="Roll Store",
    )
    layout = LabelLayout(**_roll_45())
    pdf = render_price_labels([row], layout, "roll", "en", compress=False)
    stream = _page_streams(pdf)[0]
    width, _height = _media_box(pdf)

    runs = _runs(stream)
    name_runs = [
        r for r in runs if r.text not in {"Roll Store", "200.00 DA", "1234567890128"}
    ]
    assert 1 <= len(name_runs) <= 2  # wrapped, never a third line
    for run in name_runs:
        half = stringWidth(shape_text(run.text), FONT_BOLD, run.size) / 2
        assert run.x + half == pytest.approx(width / 2, abs=1.0)
        assert 0.0 <= run.x and run.x + 2 * half <= width
    _x0, _x1, bars_y0, _y1 = _bar_bounds(stream)
    assert min(r.y for r in name_runs) > bars_y0  # name never touches bars


def test_label_arabic_blocks_are_centered():
    name = "عصير التفاح الطازج"
    row = PriceLabel(
        name=name,
        barcode="AR123",
        retail=Decimal("200.000"),
        price=Decimal("200.000"),
        promo=False,
        unit="piece",
        store_name="سوبر ماركت النخبة",
    )
    layout = LabelLayout(**_roll_45())
    pdf = render_price_labels([row], layout, "roll", "ar", compress=False)
    stream = _page_streams(pdf)[0]
    width, _height = _media_box(pdf)

    shaped_store = shape_text("سوبر ماركت النخبة")
    shaped_name = shape_text(name)
    runs = _runs(stream)
    # Arabic is drawn through the subset encoder, so the raw Tj operand is
    # not readable text — identify the blocks by draw order (store, then
    # name) and measure their width with the same font + shaped string.
    store_run, name_run = runs[0], runs[1]
    for run, shaped in ((store_run, shaped_store), (name_run, shaped_name)):
        half = stringWidth(shaped, FONT_BOLD, run.size) / 2
        assert run.x + half == pytest.approx(width / 2, abs=1.0)


def test_labels_roll_promotion_matches_a4_presentation(client, admin_headers):
    product = _product(client, admin_headers, name="Cola", barcode="COC500")
    _promo(client, admin_headers, product["id"])
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"]}],
        paper="roll",
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "Cola" in text
    assert "80.00 DA" in text  # server effective promo price
    assert "100.00 DA" in text  # untouched retail struck through
    assert "20% OFF" in text  # declared percent badge


def test_labels_roll_arabic_product_is_drawn_shaped(client, admin_headers):
    name = "عصير التفاح الطازج"
    product = _product(client, admin_headers, name=name, barcode="ARROLL")
    resp = _labels(
        client, admin_headers, [{"product_id": product["id"]}], paper="roll", locale="ar"
    )
    assert resp.status_code == 200, resp.text
    blocks = _blocks(resp.content)
    shaped = shape_text(name)
    assert any(shaped == b or shaped in b for b in blocks), blocks


def test_labels_roll_long_name_ellipsized_keeps_barcode(client, admin_headers):
    name = (
        "Premium Organic Wholegrain Breakfast Cereal With Raisins Honey "
        "Almonds And Dark Chocolate 500g Resealable Family Pack"
    )
    product = _product(client, admin_headers, name=name, barcode="1234567890128")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"]}],
        paper="roll",
        layout=_roll_layout(),
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    text = _text(resp.content)
    assert "…" in text
    assert name not in text
    assert "1234567890128" in text  # verbatim Code128 + digits
    assert "100.00 DA" in text


def test_labels_roll_barcode_verbatim_and_human_readable(client, admin_headers):
    product = _product(
        client, admin_headers, name="Barcode Roll", barcode="4006381333931"
    )
    resp = _labels(
        client, admin_headers, [{"product_id": product["id"]}], paper="roll", locale="en"
    )
    assert resp.status_code == 200, resp.text
    assert "4006381333931" in _text(resp.content)  # digits line under the bars


def test_labels_roll_touches_no_inventory_or_sales(client, admin_headers, db):
    product = _product(client, admin_headers, name="ReadOnly Roll", barcode="RO500")
    qty_before = client.get(
        f"/api/v1/products/{product['id']}", headers=admin_headers
    ).json()["quantity"]
    moves_before = len(db.execute(select(InventoryMovement)).scalars().all())
    sales_before = len(db.execute(select(Sale)).scalars().all())

    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 4}],
        paper="roll",
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    db.expire_all()
    qty_after = client.get(
        f"/api/v1/products/{product['id']}", headers=admin_headers
    ).json()["quantity"]
    assert qty_after == qty_before  # printing never decrements stock
    assert len(db.execute(select(InventoryMovement)).scalars().all()) == moves_before
    assert len(db.execute(select(Sale)).scalars().all()) == sales_before


def test_labels_a4_ignores_roll_fields(client, admin_headers):
    """Back-compat: roll-only fields never perturb the A4 sheet."""
    product = _product(client, admin_headers, name="A4 Rollback", barcode="A4R001")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"]}],
        paper="A4",
        layout={"roll_width_mm": 30.0, "margin_left_mm": 40.0, "margin_top_mm": 40.0},
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    width, height = _media_box(resp.content)
    assert width == pytest.approx(210 * _MM, abs=0.01)
    assert height == pytest.approx(297 * _MM, abs=0.01)


@pytest.mark.parametrize(
    "layout",
    [
        {"roll_width_mm": 5.0},  # media below the minimum
        {"roll_width_mm": 200.0},  # media above the maximum
        {"label_width_mm": 20.0},  # label below the minimum
        {"label_width_mm": 120.0},  # label above the maximum
        {"label_height_mm": 15.0},  # label shorter than the minimum
        {"label_height_mm": 150.0},  # label taller than the maximum
        {"gap_y_mm": -1.0},  # negative gap
        {"gap_y_mm": 25.0},  # gap above the maximum
        {"margin_left_mm": 60.0},  # margin above the maximum
        {"margin_right_mm": -0.5},  # negative margin
        {"margin_top_mm": 60.0},  # margin above the maximum
        # cross-check: 5 + 50 + 4 = 59 mm > 58 mm media
        {"margin_left_mm": 5.0, "label_width_mm": 50.0, "margin_right_mm": 4.0},
    ],
    ids=[
        "roll_width_too_small",
        "roll_width_too_large",
        "label_width_too_small",
        "label_width_too_large",
        "label_height_too_small",
        "label_height_too_large",
        "gap_negative",
        "gap_too_large",
        "left_margin_too_large",
        "right_margin_negative",
        "top_margin_too_large",
        "margins_plus_label_exceed_media",
    ],
)
def test_labels_roll_invalid_geometry_422(client, admin_headers, db, layout):
    before = len(_audit_rows(db, "print"))
    body = {
        "items": [{"product_id": str(uuid.uuid4())}],
        "paper": "roll",
        "layout": layout,
    }
    resp = client.post("/api/v1/print/labels", json=body, headers=admin_headers)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert len(_audit_rows(db, "print")) == before  # rejected pre-service
