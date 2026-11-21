"""Endpoint-level regression — ``POST /api/v1/print`` for a sale receipt.

The thermal-receipt redesign lives in ``app/printing/templates/receipt_80mm.py``
and is selected by ``render_invoice`` when ``data.receipt is not None``.  Unit
tests of that module passed while the real application still produced the OLD
layout, because nothing pinned the *production* path end to end:

    POST /api/v1/print  ->  PrintService.render  ->  render_invoice(data, paper)

This suite drives exactly the request the Flutter POS client sends
(``lib/features/pos/print_document.dart::fetchPrintDocument``:
``document_type`` / ``document_id`` / ``paper`` / ``locale`` + ``X-Device-ID``)
and asserts, on the returned bytes and on the renderer's own inputs:

* ``PrintRequest.paper`` is ``"80mm"`` and ``DocumentData.receipt`` IS populated;
* ``render_invoice`` selected ``receipt_80mm`` (and did NOT call the legacy
  ``invoice_80mm``);
* the PDF carries the new headings, the Reçu / Total / Rendu payment box, the
  closing message configured in Settings (or the built-in default) and NO
  barcode / invoice reference in the footer;
* the cash tender stored on the sale is what `Reçu` prints, with the real
  `Rendu`; card/partial/credit never invent a cash change;
* pack components are counted as physical pieces;
* A4 sales and 80mm returns are untouched (still their existing templates).

The rasterised check is skipped when no PDF rasteriser is installed; the
text/geometry assertions still run.
"""

from __future__ import annotations

import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.printing.templates import invoice_80mm, receipt_80mm
from app.services.auth import AuthService

# ── Fixtures (same shape as test_print_export.py) ─────────────────────────


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


def _product(client, headers, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", "Thermal Receipt Product"),
        "barcode": overrides.pop("barcode", f"THM{uuid.uuid4().hex[:8].upper()}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "50.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale(client, headers, product_id: str, **overrides) -> dict:
    """Two pieces at 100.000, 300.000 cash → a real change of 100.000."""
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
        "paid": overrides.pop("paid", "300.000"),
        "device_id": "POS-1",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/sales", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _print_sale(client, headers, document_id: str, paper: str = "80mm", locale: str = "fr"):
    """The EXACT request body/headers ``fetchPrintDocument`` sends."""
    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "sale",
            "document_id": document_id,
            "paper": paper,
            "locale": locale,
            "device_id": "POS-1",
        },
        headers={**headers, "X-Device-ID": "POS-1"},
    )
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"
    assert resp.headers["content-type"].startswith("application/pdf")
    return resp.content


def _pdf_text(raw: bytes) -> str:
    """Drawn text via the G7 spike ToUnicode extractor (no extra dependency)."""
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return "\n".join(text for _font, text in g7_spike.extract_text_blocks(raw))


def _media_box(content: bytes) -> tuple[float, float]:
    mb = content.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(mb[2]), float(mb[3])


class _RendererSpy:
    """Records which 80mm template the renderer actually chose."""

    def __init__(self, monkeypatch):
        self.calls: list[dict] = []
        self.legacy_calls = 0

        real_build = receipt_80mm.build_flowables
        real_height = receipt_80mm.estimate_height
        real_legacy = invoice_80mm.build_flowables

        def build(data):
            story = real_build(data)
            self.calls.append({"data": data, "story": story})
            return story

        def legacy(data):
            self.legacy_calls += 1
            return real_legacy(data)

        monkeypatch.setattr(receipt_80mm, "build_flowables", build)
        monkeypatch.setattr(receipt_80mm, "estimate_height", real_height)
        monkeypatch.setattr(invoice_80mm, "build_flowables", legacy)

    @property
    def data(self):
        assert self.calls, "the thermal receipt template was never selected"
        return self.calls[-1]["data"]

    @property
    def story(self):
        assert self.calls, "the thermal receipt template was never selected"
        return self.calls[-1]["story"]


# ── The real production path ──────────────────────────────────────────────


def test_print_endpoint_sale_80mm_selects_thermal_receipt(
    client, admin_headers, monkeypatch
):
    """Endpoint → service → 80mm routing: the NEW template must be chosen.

    This is the assertion whose absence let the old layout survive: every
    individual round trip (build_sale_document, render_invoice, receipt_80mm)
    was covered, but not the three of them joined by the HTTP endpoint.
    """
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    spy = _RendererSpy(monkeypatch)
    raw = _print_sale(client, admin_headers, sale["id"])

    assert spy.legacy_calls == 0, "legacy invoice_80mm must not render a sale receipt"
    data = spy.data

    # DocumentData as handed to the renderer
    assert data.meta.locale == "fr"
    assert data.receipt is not None, "build_sale_document did not populate ReceiptSummary"
    assert data.receipt.reference == sale["invoice_number"]
    assert data.receipt.cashier == "Admin"
    assert data.receipt.article_count == 1
    assert data.receipt.total_qty is not None
    assert data.customer_facing is True
    # 80mm paper: page width is 80 mm in points
    width, _height = _media_box(raw)
    assert width == pytest.approx(80 * 2.8346456693, abs=0.01)


def test_print_endpoint_sale_80mm_pdf_has_new_layout(client, admin_headers):
    """The returned PDF itself carries the redesigned blocks."""
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    raw = _print_sale(client, admin_headers, sale["id"])
    text = _pdf_text(raw)

    # four column headings
    for heading in ("Désignation", "Prix U", "Qté", "Montant"):
        assert heading in text, f"missing column heading {heading!r} in:\n{text}"
    # article count / pieces / gross subtotal
    assert "Article" in text
    assert "Sous-total" in text
    # cashier from the sale
    assert "Encaissé par" in text and "Admin" in text
    # bordered payment summary
    for row in ("Reçu", "Total", "Rendu"):
        assert row in text, f"missing payment row {row!r} in:\n{text}"
    # default footer (no message configured) — and NO barcode/reference
    assert "Merci pour votre visite" in text
    assert "Veuillez conserver votre Ticket de Caisse" in text
    assert sale["invoice_number"] not in text


def test_print_endpoint_sale_80mm_has_no_barcode_or_footer_reference(
    client, admin_headers, monkeypatch
):
    """No Code128 flowable and no invoice reference anywhere on the receipt."""
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    spy = _RendererSpy(monkeypatch)
    raw = _print_sale(client, admin_headers, sale["id"])

    assert not any(
        type(f).__module__.startswith("reportlab.graphics.barcode")
        for f in spy.story
    ), "the thermal receipt must not embed a barcode"
    assert sale["invoice_number"] not in _pdf_text(raw)


def test_print_endpoint_sale_80mm_arabic_receipt(client, admin_headers, monkeypatch):
    """The ar locale keeps the new layout and shapes the Arabic footer."""
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    spy = _RendererSpy(monkeypatch)
    raw = _print_sale(client, admin_headers, sale["id"], locale="ar")

    assert spy.data.rtl is True
    text = _pdf_text(raw)
    assert "Encaissé par" not in text  # arabic labels, not the french ones
    assert sale["invoice_number"] not in text


# ── Settings-driven footer ────────────────────────────────────────────────


def test_print_endpoint_uses_the_footer_configured_in_settings(
    client, admin_headers
):
    """The receipt prints the Settings text, not the hardcoded thank-you."""
    resp = client.put(
        "/api/v1/settings",
        json={"invoice_footer": "Merci et à bientôt !"},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["invoice_footer"] == "Merci et à bientôt !"

    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))

    assert "Merci et à bientôt !" in text
    assert "Merci pour votre visite" not in text
    assert "Veuillez conserver votre Ticket de Caisse" in text


def test_print_endpoint_default_footer_when_settings_message_is_blank(
    client, admin_headers
):
    resp = client.put(
        "/api/v1/settings", json={"invoice_footer": ""}, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text

    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))

    assert "Merci pour votre visite" in text
    assert "Veuillez conserver votre Ticket de Caisse" in text


# ── Payment mapping through the real endpoint ─────────────────────────────


def _sale_6500(client, admin_headers, **overrides):
    """One article at 6 500; `paid` / `payment_method` / `customer_id` vary."""
    product = _product(
        client, admin_headers, name="Article 6500", price="6500.000", quantity="10.000"
    )
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": [
            {
                "product_id": product["id"],
                "quantity": "1.000",
                "unit_price": "6500.000",
                "line_discount": "0.000",
            }
        ],
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "6500.000",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/sales", json=payload, headers=admin_headers)
    assert resp.status_code == 201, resp.text
    return resp.json(), product


def test_print_endpoint_cash_tender_prints_received_total_and_change(
    client, admin_headers
):
    """7 000 handed over for a 6 500 payable → Reçu 7 000, Rendu 500."""
    sale, _ = _sale_6500(client, admin_headers, paid="7000.000")
    assert sale["paid"] == "7000.000"
    assert sale["total"] == "6500.000"
    assert sale["change"] == "500.000"

    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))
    assert "7 000.00 DA" in text
    assert "6 500.00 DA" in text
    assert "500.00 DA" in text
    assert "Rendu" in text


def test_print_endpoint_exact_cash_payment_has_no_change(client, admin_headers):
    sale, _ = _sale_6500(client, admin_headers, paid="6500.000")
    assert sale["change"] == "0.000"
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))
    assert "6 500.00 DA" in text
    assert "Rendu" not in text


def test_print_endpoint_card_sale_has_no_cash_change(client, admin_headers):
    sale, _ = _sale_6500(
        client, admin_headers, paid="6500.000", payment_method="card"
    )
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))
    assert "Rendu" not in text
    assert "Reçu" in text


def _customer(client, headers, name="Receipt Customer") -> dict:
    resp = client.post(
        "/api/v1/customers", json={"name": name, "phone": None}, headers=headers
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_print_endpoint_partial_payment_reports_paid_without_change(
    client, admin_headers
):
    customer = _customer(client, admin_headers)
    sale, _ = _sale_6500(
        client,
        admin_headers,
        paid="4000.000",
        payment_method="partial",
        customer_id=customer["id"],
    )
    assert sale["debt"] == "2500.000"
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))
    assert "4 000.00 DA" in text  # Reçu = what was actually paid
    assert "Rendu" not in text


def test_print_endpoint_credit_sale_has_no_received_row(client, admin_headers):
    customer = _customer(client, admin_headers)
    sale, _ = _sale_6500(
        client,
        admin_headers,
        paid="0.000",
        payment_method="credit",
        customer_id=customer["id"],
    )
    assert sale["debt"] == "6500.000"
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))
    assert "Reçu" not in text
    assert "Rendu" not in text


# ── Pieces include pack components ────────────────────────────────────────


def test_print_endpoint_pack_components_count_as_physical_pieces(
    client, admin_headers, monkeypatch
):
    """asa 1 + dek 1 + a 4-piece pack → 3 Articles / 6 pièces."""
    asa = _product(client, admin_headers, name="asa", price="100.000")
    dek = _product(client, admin_headers, name="dek", price="200.000")
    parts = [
        _product(
            client, admin_headers, name=f"pack part {i}", price="25.000"
        )
        for i in range(4)
    ]
    pack = client.post(
        "/api/v1/packs",
        json={
            "name": "Pack Famille",
            "barcode": f"PK{uuid.uuid4().hex[:8].upper()}",
            "price": "400.000",
            "is_active": True,
            "components": [
                {"product_id": part["id"], "quantity": "1.000"} for part in parts
            ],
        },
        headers=admin_headers,
    )
    assert pack.status_code == 201, pack.text
    pack = pack.json()

    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {"product_id": asa["id"], "quantity": "1.000", "unit_price": "100.000"},
                {"product_id": dek["id"], "quantity": "1.000", "unit_price": "200.000"},
                {"pack_id": pack["id"], "quantity": "1.000", "unit_price": "400.000"},
            ],
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "700.000",
            "device_id": "POS-1",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text
    sale = resp.json()

    spy = _RendererSpy(monkeypatch)
    text = _pdf_text(_print_sale(client, admin_headers, sale["id"]))

    assert spy.data.receipt is not None
    assert spy.data.receipt.article_count == 3
    assert spy.data.receipt.total_qty == "6"
    assert "3 Articles" in text
    assert "6 pièces" in text


def test_print_endpoint_item_table_has_one_separator_after_all_rows(
    client, admin_headers, monkeypatch
):
    """No per-product rule: exactly one hairline closes the item block."""
    a = _product(client, admin_headers, name="Un", price="10.000")
    b = _product(client, admin_headers, name="Deux", price="20.000")
    resp = client.post(
        "/api/v1/sales",
        json={
            "client_request_id": str(uuid.uuid4()),
            "items": [
                {"product_id": a["id"], "quantity": "1.000"},
                {"product_id": b["id"], "quantity": "1.000"},
            ],
            "invoice_discount": "0.000",
            "payment_method": "cash",
            "paid": "30.000",
            "device_id": "POS-1",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 201, resp.text

    spy = _RendererSpy(monkeypatch)
    _print_sale(client, admin_headers, resp.json()["id"])

    items = next(
        f for f in spy.story if hasattr(f, "_linecmds") and getattr(f, "_ncols", 0) == 4
    )
    rules = [cmd for cmd in items._linecmds if cmd[0] == "LINEBELOW"]
    assert len(rules) == 2  # header rule + ONE closing rule
    assert rules[1][1] == (0, items._nrows - 1)


def test_print_endpoint_sale_80mm_rasterises(client, admin_headers, tmp_path):
    """Render the endpoint PDF to an IMAGE and check the new blocks are inked.

    Skipped when no rasteriser is available (pytest.importorskip) — the text
    and geometry assertions above are the always-on contract.
    """
    fitz = pytest.importorskip("fitz", reason="no PDF rasteriser installed")

    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])
    raw = _print_sale(client, admin_headers, sale["id"])

    pdf = fitz.open(stream=raw, filetype="pdf")
    assert pdf.page_count == 1, "the receipt must fit on one 80mm segment"
    page = pdf[0]
    pix = page.get_pixmap(dpi=203)  # Xprinter XP-365B native resolution
    png = tmp_path / "receipt_80mm_endpoint.png"
    pix.save(str(png))
    assert pix.width > 0 and pix.height > 0
    # ink present (not a blank page)
    assert any(byte < 250 for byte in pix.samples[: pix.width * pix.height * 3][::997])
    assert png.exists() and png.stat().st_size > 2000


# ── Preserved paths ───────────────────────────────────────────────────────


def test_print_endpoint_sale_a4_keeps_a4_layout(client, admin_headers, monkeypatch):
    """A4 sales must NOT switch to the thermal receipt."""
    product = _product(client, admin_headers)
    sale = _sale(client, admin_headers, product["id"])

    spy = _RendererSpy(monkeypatch)
    raw = _print_sale(client, admin_headers, sale["id"], paper="A4", locale="en")

    assert spy.calls == [], "A4 must not build the 80mm receipt story"
    width, height = _media_box(raw)
    assert width == pytest.approx(595.28, abs=0.01)
    assert height == pytest.approx(841.89, abs=0.01)


def test_print_endpoint_return_80mm_keeps_legacy_layout(
    client, admin_headers, monkeypatch
):
    """Internal return documents keep invoice_80mm (no customer ReceiptSummary)."""
    product = _product(client, admin_headers)
    _sale(client, admin_headers, product["id"])
    ret = client.post(
        "/api/v1/returns",
        json={
            "client_request_id": str(uuid.uuid4()),
            "lines": [{"product_id": product["id"], "quantity": "1.000"}],
        },
        headers=admin_headers,
    )
    assert ret.status_code == 201, ret.text
    return_id = ret.json()["return"]["id"]

    spy = _RendererSpy(monkeypatch)
    resp = client.post(
        "/api/v1/print",
        json={
            "document_type": "return",
            "document_id": return_id,
            "paper": "80mm",
            "locale": "fr",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    assert spy.calls == [], "returns must not use the customer sale receipt"
    assert spy.legacy_calls == 1
