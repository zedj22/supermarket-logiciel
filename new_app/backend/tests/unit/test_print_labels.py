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
9.  Roll labels (`paper="roll"`) — exact content geometry (media
    width + labels + gaps, mathematically verified), single-column
    stacking with the configured gap, ordered multi-copy runs,
    margins honored, schema rejects impossible media geometry (422),
    A4 ignores roll fields (back-compat), and the roll path touches
    no inventory / no sales (same DB-free contract as A4).
"""

from __future__ import annotations

import json
import re
import sys
import time
import uuid
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
from app.printing.fonts import FONT_BOLD, register_fonts
from app.printing.price_labels import (
    PriceLabel,
    _measure,
    _wrap,
    render_price_labels,
)
from app.printing.text import shape_text
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


def test_labels_roll_renders_exact_content_geometry(client, admin_headers):
    product = _product(client, admin_headers, name="Roll Product", barcode="ROLL001")
    resp = _labels(
        client,
        admin_headers,
        [{"product_id": product["id"], "quantity": 3}],
        paper="roll",
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert b"/FontFile2" in resp.content
    width, height = _media_box(resp.content)
    assert width == pytest.approx(58 * _MM, abs=0.01)  # media width
    # 3*30 label + 2*2 gap + 0 top margin = 94 mm (spec example)
    assert height == pytest.approx(94 * _MM, abs=0.01)
    assert _page_count(resp.content) == 1  # one continuous strip


def test_labels_roll_stacks_labels_with_exact_vertical_gap():
    row = _price_row("Gap Probe", "GAP1", promo=True)
    layout = LabelLayout(**_roll_layout(margin_left_mm=4.0))
    pdf = render_price_labels([row] * 3, layout, "roll", "en", compress=False)

    pairs = _tm_pairs(pdf)
    assert len(pairs) >= 3 and len(pairs) % 3 == 0, pairs
    group = len(pairs) // 3
    step = (30.0 + 2.0) * _MM  # label height + gap, in pt
    first, second, third = pairs[:group], pairs[group : 2 * group], pairs[2 * group :]
    for (x1, y1), (x2, y2), (x3, y3) in zip(first, second, third):
        assert x1 == pytest.approx(x2) == pytest.approx(x3)  # same column
        assert y1 - y2 == pytest.approx(step, abs=0.01)  # label + gap
        assert y1 - y3 == pytest.approx(2 * step, abs=0.01)


def test_labels_roll_margins_keep_text_inside_media():
    row = _price_row("Margin Probe", "MRG1")
    layout = LabelLayout(
        **_roll_layout(margin_top_mm=5.0, margin_left_mm=4.0, margin_right_mm=4.0)
    )
    pdf = render_price_labels([row] * 2, layout, "roll", "en", compress=False)
    width, height = _media_box(pdf)
    assert width == pytest.approx(58 * _MM, abs=0.01)
    assert height == pytest.approx(67 * _MM, abs=0.01)  # 5 top + 2*30 + 1*2

    left_pt = 4.0 * _MM
    top_limit = height - 5.0 * _MM  # text never enters the top margin
    for x, y in _tm_pairs(pdf):
        assert left_pt <= x <= width  # never left of the left margin
        assert 0.0 <= y <= top_limit  # inside the strip, below the top margin


def test_labels_roll_multiple_copies_stack_in_order(client, admin_headers):
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
        locale="en",
    )
    assert resp.status_code == 200, resp.text
    width, height = _media_box(resp.content)
    assert width == pytest.approx(58 * _MM, abs=0.01)
    # 8 labels + 7 gaps = 8*30 + 7*2 = 254 mm
    assert height == pytest.approx(254 * _MM, abs=0.01)
    assert _page_count(resp.content) == 1
    text = _text(resp.content)
    assert text.count("Roll Alpha") == 3  # A A A B B B B B, in order
    assert text.count("Roll Beta") == 5
    assert text.index("Roll Alpha") < text.index("Roll Beta")  # first block


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
    width, height = _media_box(resp.content)
    assert width == pytest.approx(58 * _MM, abs=0.01)  # always one across
    assert height == pytest.approx(62 * _MM, abs=0.01)  # derived: 2*30+2
    assert _page_count(resp.content) == 1  # rows never paginate a roll


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
