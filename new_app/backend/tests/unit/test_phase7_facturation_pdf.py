"""Phase 7 tests — facturation PDF (``POST /api/v1/factures/{id}/pdf``).

A4-only, ``facturation_view``-gated (Admin + Manager only), locale
allowlist ar / fr / en. Same TestClient + StaticPool SQLite pattern as
``test_facturation_documents_api`` (seeded roles, admin, manager,
cashier, role-less guest, real bearer login).

Covers the required Phase 7 scenarios:

- Structure: ``%PDF`` header, A4 ``/MediaBox``, embedded TTF subsets
  (``/FontFile2``), one page, ``facture_{number}_{stamp}.pdf`` filename.
- All five doc types render their localized titles.
- Seller + client fiscal identity blocks (Phase 6 settings columns).
- The printed number/date are the STORED values, never today.
- Totals and the French amount-in-words sentence are exactly the
  Phase 1 ``calculate_document_result`` output the API serves (the PDF
  never recalculates).
- ``show_discount`` / ``show_tva`` / ``show_timbre`` /
  ``show_payment_method`` / ``show_amount_words`` flags, discount x TVA
  rate matrix cells, stamp duty only for FAC + cash + show_timbre.
- Default locale ar (shaped Arabic title), explicit fr, allowed en,
  unsupported locale → structured 422 before any render/audit.
- Multi-page documents repeat the items header; the footer area is
  left blank (no ``Page N / M`` stamp, no company-name prefix) while
  sales-invoice / report PDFs keep their numbering.
- 401 / Cashier and role-less guest denied with ``required_permission``
  ``facturation_view`` / structured 404.
- Exactly one ``print`` audit row per attempt: success (bytes, filename,
  paper A4, locale) and failure (``PRINT_RENDER_FAILED`` via a monkeypatched
  renderer, ``COMPANY_MISSING`` via a blanked ``store_name``).
"""

from __future__ import annotations

import json
import re
import sys
import uuid
from datetime import date
from decimal import Decimal
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, update
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.facturation import InvoiceClient, InvoiceDocument
from app.models.settings import AppSetting
from app.printing.labels import label
from app.printing.text import shape_text
from app.services.auth import AuthService
from app.services.facturation import calculate_document_result

DAY = "2026-01-15"

# Phase 6 settings columns — full seller identity (PUT /api/v1/settings).
COMPANY: dict[str, str] = {
    "store_name": "SARL Print Test",
    "store_address": "01 Rue de la Liberte",
    "store_phone": "021 45 67 89",
    "store_wilaya": "16 Alger",
    "store_email": "contact@sp.dz",
    "store_nif": "0002213400067",
    "store_nis": "0011223344",
    "store_rc": "16/00-1234567 B 09",
    "store_ai": "0991612345678",
    "store_rib": "00799999001234567890",
}

COMPANY_LINES_FR = [
    "SARL Print Test",
    "01 Rue de la Liberte",
    "16 Alger",
    "Tél : 021 45 67 89",
    "E-mail : contact@sp.dz",
    "RC : 16/00-1234567 B 09",
    "NIF : 0002213400067",
    "AI : 0991612345678",
    "NIS : 0011223344",
    "RIB/CCP : 00799999001234567890",
]

CLIENT_LINES_FR = [
    "Client",
    "SARL EL BARAKA",
    "12 Didouche Mourad",
    "Alger",
    "Tél : 0661 22 33 44",
    "RC : 16/00-1234567 B 21",
    "NIF : 0009988776655",
    "AI : 0009161234567",
    "NIS : 0998161234567",
]


# ---------------------------------------------------------------------------
# PDF text extraction (content-stream order, ToUnicode aware)
# ---------------------------------------------------------------------------


_TOKEN_RE = re.compile(
    rb"(?P<bt>BT)|(?P<et>ET)|/(?P<font>F[\w+]+)\s+[\d.]+\s+Tf"
    rb"|<(?P<hex>[0-9A-Fa-f]+)>\s*Tj"
    rb"|\[(?P<arr>.*?)\]\s*TJ"
    rb"|\((?P<lit>.*?)\)\s*Tj"
    rb"|(?P<br>T\*)",
    re.DOTALL,
)


def _pdf_text(raw: bytes) -> str:
    """All drawn text of a PDF, in content-stream order.

    Uses the G7 spike parser primitives (``parse_objects`` /
    ``stream_data`` / ``parse_tounicode`` / ``decode_pdf_literal``) but
    walks the token stream in ORDER instead of ``extract_text_blocks``:
    that helper pairs ``BT``/``ET`` with a regex that stops at the first
    ``ET`` *inside a literal string* (any drawn word containing ``ET`` —
    e.g. ``SUPERMARKET`` — truncates the block and desynchronizes every
    block after it).
    """
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    objs = g7_spike.parse_objects(raw)

    font_maps: dict[str, dict[int, str]] = {}
    for obj in objs.values():
        m = re.search(rb"/ToUnicode\s+(\d+)\s+0\s+R", obj)
        if not m:
            continue
        data = g7_spike.stream_data(objs.get(int(m.group(1)), b""))
        if not data:
            continue
        bm = re.search(rb"/BaseFont\s*/([A-Za-z0-9+\-_,.]+)", obj)
        key = bm.group(1).decode("latin1") if bm else f"anon{m.group(1)}"
        font_maps[key] = g7_spike.parse_tounicode(data)

    res_fonts: dict[str, str] = {}
    for obj in objs.values():
        if b"/Font" not in obj or b"/BaseFont" in obj:
            continue
        refs: list[tuple[bytes, bytes]] = []
        direct = re.search(rb"/Font\s*<<(.*?)>>", obj, re.DOTALL)
        if direct:
            refs = re.findall(rb"/(F[\w+]+)\s+(\d+)\s+0\s+R", direct.group(1))
        else:
            indirect = re.search(rb"/Font\s+(\d+)\s+0\s+R", obj)
            if indirect:
                target = objs.get(int(indirect.group(1)), b"")
                refs = re.findall(rb"/(F[\w+]+)\s+(\d+)\s+0\s+R", target)
        for res_name, ref in refs:
            bm = re.search(rb"/BaseFont\s*/([A-Za-z0-9+\-_,.]+)", objs.get(int(ref), b""))
            if bm:
                res_fonts[res_name.decode()] = bm.group(1).decode("latin1")

    lines: list[str] = []
    for obj in objs.values():
        if b"stream" not in obj:
            continue
        data = g7_spike.stream_data(obj)
        if not data or b"BT" not in data:
            continue
        current: dict[int, str] = {}
        parts: list[str] = []
        open_block = False
        for tok in _TOKEN_RE.finditer(data):
            if tok.group("bt") is not None:
                open_block = True
                parts = []
                continue
            if tok.group("et") is not None:
                if open_block:
                    text = "".join(parts)
                    if text.strip():
                        lines.append(text)
                    open_block = False
                    parts = []
                continue
            if tok.group("font") is not None:
                base = res_fonts.get(tok.group("font").decode(), "")
                if base in font_maps:
                    current = font_maps[base]
                continue
            if not open_block:
                continue
            if tok.group("hex") is not None:
                hexs = tok.group("hex").decode()
                parts.append(
                    "".join(
                        current.get(int(hexs[i : i + 4], 16), "")
                        for i in range(0, len(hexs) - 3, 4)
                    )
                )
            elif tok.group("arr") is not None:
                segs: list[str] = []
                for seg in re.findall(rb"<([0-9A-Fa-f]+)>", tok.group("arr")):
                    hexs = seg.decode()
                    segs.append(
                        "".join(
                            current.get(int(hexs[i : i + 4], 16), "")
                            for i in range(0, len(hexs) - 3, 4)
                        )
                    )
                for seg in re.findall(rb"\((.*?)\)", tok.group("arr")):
                    segs.append("".join(current.get(c, "") for c in g7_spike.decode_pdf_literal(seg)))
                parts.append("".join(segs))
            elif tok.group("lit") is not None:
                parts.append(
                    "".join(current.get(c, "") for c in g7_spike.decode_pdf_literal(tok.group("lit")))
                )
            elif tok.group("br") is not None:
                parts.append("\n")
        if open_block:
            text = "".join(parts)
            if text.strip():
                lines.append(text)
    return "\n".join(lines)


def _flat(text: str) -> str:
    """Whitespace-collapsed text so wrapped paragraphs still match."""
    return " ".join(text.split())


def _media_box(content: bytes) -> tuple[float, float]:
    mb = content.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(mb[2]), float(mb[3])


def _page_count(content: bytes) -> int:
    return len(re.findall(rb"/Type\s*/Page[^s]", content))


# ---------------------------------------------------------------------------
# Fixtures (same pattern as test_facturation_documents_api)
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
def testing_session(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, testing_session):
    """Seeded session: roles/permissions + admin + manager + cashier + role-less guest."""
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
        with TestClient(app) as c:
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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _invoice_client(db, **fields) -> InvoiceClient:
    values: dict[str, object] = {"name": "SARL EL BARAKA"}
    values.update(fields)
    row = InvoiceClient(**values)
    db.add(row)
    db.commit()
    return row


def _payload(client_id: str, **overrides) -> dict:
    payload = {
        "doc_type": "FAC",
        "client_id": client_id,
        "document_date": DAY,
        "payment_method": "cash",
        "notes": "Phase 7 render",
        "lines": [
            {
                "description": "Prestation",
                "quantity": "4",
                "unit_price_ht": "100",
                "tva_rate": "19",
                "discount_pct": "0",
            }
        ],
    }
    payload.update(overrides)
    return payload


def _create(client, headers, client_id: str, **overrides) -> dict:
    resp = client.post(
        "/api/v1/factures",
        json=_payload(client_id, **overrides),
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _detail(client, headers, document_id: str) -> dict:
    resp = client.get(f"/api/v1/factures/{document_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _print(client, headers, document_id: str, **params):
    return client.post(
        f"/api/v1/factures/{document_id}/pdf",
        params=params,
        headers={**headers, "X-Device-ID": "POS-1"},
    )


def _print_fr(client, headers, document_id: str) -> str:
    resp = _print(client, headers, document_id, locale="fr")
    assert resp.status_code == 200, resp.text
    return _pdf_text(resp.content)


def _put_settings(client, headers, payload: dict) -> dict:
    resp = client.put("/api/v1/settings", json=payload, headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _print_audit_rows(db) -> list[AuditLog]:
    return list(db.scalars(select(AuditLog).where(AuditLog.action == "print")).all())


def _footer_band_texts(raw: bytes) -> list[str]:
    """Joined text of each page's bottom band (the footer zone, < 20 pt)."""
    import pymupdf

    bands: list[str] = []
    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        for page in doc:
            height = page.rect.height
            bands.append(
                " ".join(
                    span["text"]
                    for block in page.get_text("dict")["blocks"]
                    for line in block.get("lines", [])
                    for span in line["spans"]
                    if height - span["bbox"][3] < 20.0
                )
            )
    finally:
        doc.close()
    return bands


def _page_number_hits(text: str) -> list[str]:
    """Every ``Page N / M`` occurrence drawn in the extracted text."""
    return re.findall(r"Page \d+ / \d+", text)


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------


def test_pdf_is_a4_with_embedded_fonts_and_filename(client, admin_headers, db):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"].startswith("application/pdf")
    raw = resp.content
    assert raw[:5] == b"%PDF-"
    assert b"/FontFile2" in raw  # embedded TTF subset (G7)
    w, h = _media_box(raw)
    assert w == pytest.approx(595.28, abs=0.01)
    assert h == pytest.approx(841.89, abs=0.01)
    assert _page_count(raw) == 1
    disposition = resp.headers["content-disposition"]
    assert disposition.startswith('attachment; filename="facture_')
    assert body["number"] in disposition
    assert disposition.endswith('.pdf"')


@pytest.mark.parametrize(
    ("doc_type", "fr_title"),
    [
        ("FAC", "FACTURE"),
        ("DEV", "DEVIS"),
        ("PRO", "FACTURE PROFORMA"),
        ("BC", "BON DE COMMANDE"),
        ("BL", "BON DE LIVRAISON"),
    ],
)
def test_all_five_doc_types_render_fr_titles(client, admin_headers, db, doc_type, fr_title):
    client_row = _invoice_client(db)
    body = _create(client, admin_headers, str(client_row.id), doc_type=doc_type)
    text = _print_fr(client, admin_headers, body["id"])
    assert fr_title in text
    assert body["number"] in text
    assert DAY in text


# ---------------------------------------------------------------------------
# Content parity (company / client / stored values / Phase 1 totals)
# ---------------------------------------------------------------------------


def test_company_and_client_fiscal_identity(client, admin_headers, db):
    _put_settings(client, admin_headers, COMPANY)
    fiscal = _invoice_client(
        db,
        address="12 Didouche Mourad",
        wilaya="Alger",
        phone="0661 22 33 44",
        nif="0009988776655",
        rc="16/00-1234567 B 21",
        ai="0009161234567",
        nis="0998161234567",
    )
    body = _create(client, admin_headers, str(fiscal.id))
    text = _print_fr(client, admin_headers, body["id"])
    for line in COMPANY_LINES_FR:
        assert line in text, line
    for line in CLIENT_LINES_FR:
        assert line in text, line


def test_stored_number_and_date_are_printed_not_today(client, admin_headers, db):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    text = _print_fr(client, admin_headers, body["id"])
    assert body["number"] in text
    assert f"Date : {DAY}" in text
    today = date.today().isoformat()
    if today != DAY:
        assert today not in text


def test_totals_and_amount_words_match_phase1(client, admin_headers, db):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    detail = _detail(client, admin_headers, body["id"])

    document = db.get(InvoiceDocument, uuid.UUID(body["id"]))
    assert document is not None
    calculation = calculate_document_result(
        document.doc_type,
        document.payment_method,
        document.show_timbre,
        document.lines,
    )
    for key in ("total_ht", "total_tva", "total_ttc", "timbre", "net_a_payer"):
        assert detail["totals"][key] == str(getattr(calculation.totals, key)), key
    assert detail["amount_in_words"] == calculation.amount_in_words

    text = _print_fr(client, admin_headers, body["id"])
    for key in ("total_ht", "total_tva", "total_ttc", "timbre", "net_a_payer"):
        assert f"{Decimal(detail['totals'][key]):.2f} DA" in text, key
    assert " ".join(detail["amount_in_words"].split()) in _flat(text)
    assert "Arrêté" in text
    assert "Signature" in text


@pytest.mark.parametrize(
    ("show_discount", "show_tva", "discount_col", "tva_col"),
    [
        (True, True, True, True),
        (True, False, True, False),
        (False, True, False, True),
        (False, False, False, False),
    ],
)
def test_discount_and_tva_columns_follow_flags(
    client, admin_headers, db, show_discount, show_tva, discount_col, tva_col
):
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        show_discount=show_discount,
        show_tva=show_tva,
    )
    text = _print_fr(client, admin_headers, body["id"])
    assert ("Remise %" in text) is discount_col
    assert ("TVA %" in text) is tva_col
    assert ("Total TVA" in text) is tva_col


@pytest.mark.parametrize(
    ("line", "total_ht", "total_tva", "cell_qty", "cell_rate"),
    [
        (
            {"quantity": "2", "unit_price_ht": "50", "tva_rate": "0", "discount_pct": "0"},
            "100.00",
            "0.00",
            "2",
            None,
        ),
        (
            {"quantity": "4", "unit_price_ht": "100", "tva_rate": "9", "discount_pct": "10"},
            "360.00",
            "32.40",
            "4",
            "9",
        ),
        (
            {"quantity": "12.5", "unit_price_ht": "56", "tva_rate": "19", "discount_pct": "10"},
            "630.00",
            "119.70",
            "12.5",
            "19",
        ),
    ],
)
def test_discount_and_tva_rate_matrix_cells(
    client, admin_headers, db, line, total_ht, total_tva, cell_qty, cell_rate
):
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        lines=[
            {
                "description": "Article matrix",
                "quantity": line["quantity"],
                "unit_price_ht": line["unit_price_ht"],
                "tva_rate": line["tva_rate"],
                "discount_pct": line["discount_pct"],
            }
        ],
    )
    detail = _detail(client, admin_headers, body["id"])
    assert detail["totals"]["total_ht"] == total_ht
    assert detail["totals"]["total_tva"] == total_tva

    text = _print_fr(client, admin_headers, body["id"])
    assert f"{total_ht} DA" in text
    assert f"{total_tva} DA" in text
    lines = set(text.split("\n"))
    assert cell_qty in lines
    if cell_rate is not None:
        assert cell_rate in lines
    if line["discount_pct"] != "0":
        assert line["discount_pct"] in lines


@pytest.mark.parametrize(
    ("doc_type", "payment", "show_timbre", "expect_duty"),
    [
        ("FAC", "cash", True, True),
        ("FAC", "cash", False, False),
        ("FAC", "transfer", True, False),
        ("DEV", "cash", True, False),
    ],
)
def test_timbre_row_only_when_phase1_applies_duty(
    client, admin_headers, db, doc_type, payment, show_timbre, expect_duty
):
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        doc_type=doc_type,
        payment_method=payment,
        show_timbre=show_timbre,
    )
    detail = _detail(client, admin_headers, body["id"])
    has_duty = Decimal(detail["totals"]["timbre"]) > 0
    assert has_duty is expect_duty

    text = _print_fr(client, admin_headers, body["id"])
    assert ("Droit de timbre" in text) is expect_duty
    assert "Net à payer" in text
    if expect_duty:
        assert f"{Decimal(detail['totals']['timbre']):.2f} DA" in text
        assert f"{Decimal(detail['totals']['net_a_payer']):.2f} DA" in text


def test_optional_sections_follow_show_flags(client, admin_headers, db):
    off = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        show_amount_words=False,
        show_payment_method=False,
    )
    on = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        show_amount_words=True,
        show_payment_method=True,
    )
    text_off = _print_fr(client, admin_headers, off["id"])
    text_on = _print_fr(client, admin_headers, on["id"])
    assert "Arrêté" not in text_off
    assert "Espèces" not in text_off
    assert "Arrêté" in text_on
    assert "Espèces" in text_on


# ---------------------------------------------------------------------------
# Locales
# ---------------------------------------------------------------------------


def test_default_locale_ar_and_explicit_fr_keep_french_amount_words(
    client, admin_headers, db
):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    detail = _detail(client, admin_headers, body["id"])
    words = " ".join(detail["amount_in_words"].split())
    assert words.startswith("Arrêté la présente facture")

    ar_resp = _print(client, admin_headers, body["id"])  # default locale = ar
    assert ar_resp.status_code == 200, ar_resp.text
    ar_text = _pdf_text(ar_resp.content)
    fr_text = _print_fr(client, admin_headers, body["id"])

    assert shape_text(label("doc_facture", "ar")) in ar_text
    assert label("doc_facture", "fr") in fr_text
    assert body["number"] in ar_text and body["number"] in fr_text
    # Phase 1 amount-in-words is French-only in BOTH locales.
    assert words in _flat(ar_text)
    assert words in _flat(fr_text)


def test_locale_en_is_allowed(client, admin_headers, db):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="en")
    assert resp.status_code == 200, resp.text
    assert label("doc_facture", "en") in _pdf_text(resp.content)


def test_unsupported_locale_is_structured_422_before_any_render(
    client, admin_headers, db
):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="de")
    assert resp.status_code == 422
    error = resp.json()["error"]
    assert error["code"] == "VALIDATION_ERROR"
    assert error["message_key"] == "errors.validation"
    # Rejected before the service: no print audit row, no PDF.
    assert _print_audit_rows(db) == []
    assert not resp.content.startswith(b"%PDF-")


# ---------------------------------------------------------------------------
# Multi-page
# ---------------------------------------------------------------------------


def test_multi_page_repeats_items_header_without_page_numbers(
    client, admin_headers, db
):
    """Multi-page facturation: the items header repeats on every page,
    but NO ``Page N / M`` stamp is drawn anywhere — the footer band is
    blank on each page."""
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        lines=[
            {
                "description": f"Article numero {i}",
                "quantity": "1",
                "unit_price_ht": "100.000",
                "tva_rate": "19",
                "discount_pct": "0",
            }
            for i in range(120)
        ],
    )
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    pages = _page_count(raw)
    assert pages >= 3

    text = _pdf_text(raw)
    assert text.split("\n").count("Désignation") >= 2  # repeated table header
    assert "Article numero 0" in text
    assert "Article numero 119" in text  # continuation page carries rows
    # No page-number footer on ANY page.
    assert _page_number_hits(text) == []
    assert "Page" not in text
    for pno, band in enumerate(_footer_band_texts(raw), start=1):
        assert band.strip() == "", (
            f"page {pno}: footer band must be blank, got {band!r}"
        )


# ---------------------------------------------------------------------------
# Auth / errors / audit contract
# ---------------------------------------------------------------------------


def test_pdf_requires_authentication(client):
    resp = client.post(
        "/api/v1/factures/00000000-0000-0000-0000-000000000000/pdf"
    )
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


@pytest.mark.parametrize("fixture_name", ["cashier_headers", "guest_headers"])
def test_denied_roles_cannot_print(client, request, fixture_name, db):
    """PDF requires facturation_view (admin + manager only)."""
    headers = request.getfixturevalue(fixture_name)
    resp = _print(client, headers, str(uuid.uuid4()))
    assert resp.status_code == 403
    assert (
        resp.json()["error"]["details"]["required_permission"]
        == "facturation_view"
    )


def test_manager_can_print(client, manager_headers, db):
    body = _create(client, manager_headers, str(_invoice_client(db).id))
    resp = _print(client, manager_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    assert resp.content[:5] == b"%PDF-"


def test_unknown_document_structured_404(client, admin_headers):
    resp = _print(client, admin_headers, str(uuid.uuid4()))
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_print_writes_one_success_audit_row(client, admin_headers, db):
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text

    rows = _print_audit_rows(db)
    assert len(rows) == 1
    row = rows[0]
    assert row.entity_type == "invoice_document"
    assert str(row.entity_id) == body["id"]
    assert row.device_id == "POS-1"
    assert row.user_id is not None

    details = json.loads(row.details)
    assert details["result"] == "success"
    assert details["error_code"] is None
    assert details["paper"] == "A4"
    assert details["locale"] == "fr"
    assert details["document_type"] == "FAC"
    assert details["document_number"] == body["number"]
    assert details["bytes"] == len(resp.content)
    assert details["bytes"] > 0
    assert details["duration_ms"] >= 0
    assert details["filename"] in resp.headers["content-disposition"]


def test_render_failure_writes_failure_audit_row(client, admin_headers, db, monkeypatch):
    body = _create(client, admin_headers, str(_invoice_client(db).id))

    def boom(_data):  # noqa: ANN001 - zero-arg renderer contract
        raise RuntimeError("font subset exploded")

    monkeypatch.setattr("app.services.print.render_facture", boom)
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 500
    assert resp.json()["error"]["code"] == "PRINT_RENDER_FAILED"

    rows = _print_audit_rows(db)
    assert len(rows) == 1
    details = json.loads(rows[0].details)
    assert details["result"] == "failure"
    assert details["error_code"] == "PRINT_RENDER_FAILED"
    assert details["bytes"] == 0
    assert details["filename"] is None
    assert details["document_number"] == body["number"]


def test_empty_company_name_refuses_with_company_missing(client, admin_headers, db):
    _put_settings(client, admin_headers, COMPANY)
    db.execute(update(AppSetting).values(store_name=""))
    db.commit()

    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 422
    error = resp.json()["error"]
    assert error["code"] == "COMPANY_MISSING"
    assert error["message_key"] == "company_missing"
    assert error["details"] == {"field": "store_name"}
    assert not resp.content.startswith(b"%PDF-")

    rows = _print_audit_rows(db)
    assert len(rows) == 1
    details = json.loads(rows[0].details)
    assert details["result"] == "failure"
    assert details["error_code"] == "COMPANY_MISSING"


# ---------------------------------------------------------------------------
# Signature placement (bottom-pinned Flowable)
# ---------------------------------------------------------------------------


def test_signature_stays_on_single_page_for_short_document(
    client, admin_headers, db
):
    """A short FAC fits on one page; the bottom-pinned signature does not
    force a spurious second page."""
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    assert _page_count(raw) == 1
    text = _pdf_text(raw)
    assert label("signature", "fr") in text
    # Signature is drawn once (label appears exactly once).
    assert text.count(label("signature", "fr")) == 1


def test_signature_drawn_after_notes_on_short_document(client, admin_headers, db):
    """Content-stream order: the signature label is drawn AFTER the notes
    line, i.e. at the end of the story — not interleaved with totals."""
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        notes="Bottom pin check",
    )
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    text = _pdf_text(resp.content)
    notes_at = text.find("Bottom pin check")
    sig_at = text.find(label("signature", "fr"))
    assert notes_at != -1 and sig_at != -1
    assert sig_at > notes_at


def test_signature_label_drawn_in_lower_region_of_flowable_box():
    """Unit: draw() places the label at the bottom of the flowable box
    (local y = 30 pt above the box edge) and draws NO rule — the
    horizontal signature line was removed in the layout cleanup."""
    from app.printing.facture_data import FactureData, IdentityBlock
    from app.printing.templates.facture_a4 import _BottomSignature

    data = FactureData(
        locale="fr",
        title="FACTURE",
        number="FAC-2026-0001",
        document_date="2026-01-15",
        company=IdentityBlock(heading=None, name="SARL", lines=()),
        client=None,
        show_discount=True,
        show_tva=True,
        lines=(),
        totals=None,  # type: ignore[arg-type] — not used by draw()
        amount_in_words=None,
        payment_method=None,
        notes=None,
    )
    flow = _BottomSignature(data)
    flow.wrap(500.0, 400.0)

    drawn: list[tuple[float, float]] = []
    ruled: list[tuple[float, float, float, float]] = []

    class _FakePara:
        def wrap(self, w, h):
            return 60.0, 12.0

        def drawOn(self, canvas, x, y):  # noqa: N802
            drawn.append((x, y))

    class _FakeCanvas:
        def setStrokeColorRGB(self, *a):  # noqa: ANN002, ANN202, N802
            pass

        def setLineWidth(self, w):  # noqa: ANN001, N802
            pass

        def line(self, x1, y1, x2, y2):  # noqa: ANN001
            ruled.append((x1, y1, x2, y2))

    import app.printing.templates.facture_a4 as tmpl

    original_p = tmpl._p
    tmpl._p = lambda *a, **k: _FakePara()  # type: ignore[assignment]
    try:
        flow.canv = _FakeCanvas()  # type: ignore[attr-defined]
        flow.draw()
    finally:
        tmpl._p = original_p

    assert drawn, "draw() produced no canvas calls"
    # Label-only block: nothing else is drawn — no signature rule.
    assert ruled == [], f"signature rule must be absent, got lines={ruled}"
    ys = {y for _x, y in drawn}
    assert ys == {30.0}, f"label not at legacy 30 pt gap: ys={ys}"


def test_multi_page_signature_on_final_page_only(client, admin_headers, db):
    """Long document: the signature appears once, on the last page."""
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        lines=[
            {
                "description": f"Article numero {i}",
                "quantity": "1",
                "unit_price_ht": "100.000",
                "tva_rate": "19",
                "discount_pct": "0",
            }
            for i in range(120)
        ],
    )
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    pages = _page_count(raw)
    assert pages >= 3
    text = _pdf_text(raw)
    assert text.count(label("signature", "fr")) == 1
    # The last article row and the signature are both present; the
    # signature is drawn after the final row (end of the story).
    assert text.find("Article numero 119") < text.find(label("signature", "fr"))


def _signature_rule_y_from_bottom(raw: bytes, page_index: int = -1) -> float | None:
    """Absolute Y (pt from paper bottom) of the short grey signature rule.

    The signature rule is the only ~60 mm horizontal hairline in the
    bottom 25 mm of the page that is NOT the footer. Table grid lines
    are full-width; the footer is text, not a line.
    """
    import pymupdf

    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        page = doc[page_index]
        h = page.rect.height
        best: float | None = None
        for drawing in page.get_drawings():
            for item in drawing["items"]:
                if item[0] != "l":
                    continue
                p1, p2 = item[1], item[2]
                if abs(p1.y - p2.y) > 0.5:
                    continue
                span = abs(p2.x - p1.x)
                # Signature rule ≈ 60 mm ≈ 170 pt (not the 498 pt table grid).
                if not (140 < span < 220):
                    continue
                y_from_bottom = h - p1.y
                if 0 < y_from_bottom < 80:
                    best = y_from_bottom if best is None else min(best, y_from_bottom)
        return best
    finally:
        doc.close()


def _signature_label_y_from_bottom(raw: bytes, locale: str) -> float | None:
    """Absolute Y (pt from paper bottom) of the Signature label's bottom."""
    import pymupdf

    shaped = shape_text(label("signature", locale))
    expected = {shaped, shaped[::-1]}
    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        page = doc[-1]
        h = page.rect.height
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for span in line["spans"]:
                    if span["text"].strip() in expected:
                        return h - span["bbox"][3]
        return None
    finally:
        doc.close()


def test_signature_rule_absent_and_label_stays_at_bottom(
    client, admin_headers, db
):
    """Final layout cleanup: the horizontal rule under the Signature
    label is GONE; the label itself keeps its bottom-pinned position
    (bottom edge ≈ 86 pt from the paper edge, above the footer)."""
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    assert _signature_rule_y_from_bottom(resp.content) is None, (
        "signature rule must be absent from the rendered PDF"
    )
    y = _signature_label_y_from_bottom(resp.content, "fr")
    assert y is not None, "signature label not found in rendered PDF"
    assert 70.0 <= y <= 100.0, (
        f"signature label at {y:.1f} pt from bottom; "
        f"expected bottom-pinned position ~86 pt"
    )


def test_signature_rule_absent_on_all_pages_of_long_document(
    client, admin_headers, db
):
    """Multi-page: no signature rule on ANY page; the label appears once,
    at the bottom of the final page."""
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        lines=[
            {
                "description": f"Article numero {i}",
                "quantity": "1",
                "unit_price_ht": "100.000",
                "tva_rate": "19",
                "discount_pct": "0",
            }
            for i in range(120)
        ],
    )
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    pages = _page_count(raw)
    assert pages >= 3
    import pymupdf

    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        for pno in range(pages):
            page = doc[pno]
            h = page.rect.height
            for drawing in page.get_drawings():
                for item in drawing["items"]:
                    if item[0] != "l":
                        continue
                    p1, p2 = item[1], item[2]
                    if abs(p1.y - p2.y) > 0.5:
                        continue
                    span = abs(p2.x - p1.x)
                    assert not (
                        140 < span < 220 and 0 < (h - p1.y) < 80
                    ), f"unexpected signature rule on page {pno + 1}"
    finally:
        doc.close()
    text = _pdf_text(raw)
    assert text.count(label("signature", "fr")) == 1
    assert text.find(label("signature", "fr")) > text.find("Article numero 119")
    y = _signature_label_y_from_bottom(raw, "fr")
    assert y is not None
    assert 70.0 <= y <= 100.0, f"last-page label at {y:.1f} pt from bottom"


def test_bottom_signature_flowable_wrap_contract():
    """Unit: wrap() consumes remaining height, or forces a page break."""
    from app.printing.facture_data import FactureData, IdentityBlock
    from app.printing.templates.facture_a4 import (
        MIN_SIGNATURE_AREA,
        _BottomSignature,
    )

    data = FactureData(
        locale="fr",
        title="FACTURE",
        number="FAC-2026-0001",
        document_date="2026-01-15",
        company=IdentityBlock(heading=None, name="SARL", lines=()),
        client=None,
        show_discount=True,
        show_tva=True,
        lines=(),
        totals=None,  # type: ignore[arg-type] — not used by wrap()
        amount_in_words=None,
        payment_method=None,
        notes=None,
    )
    flow = _BottomSignature(data)
    # Sufficient room: consumes it all.
    w, h = flow.wrap(500.0, 400.0)
    assert (w, h) == (500.0, 400.0)
    # Insufficient room: asks for MIN_SIGNATURE_AREA → frame wraps page.
    w, h = flow.wrap(500.0, MIN_SIGNATURE_AREA - 1)
    assert h == MIN_SIGNATURE_AREA
    assert h > MIN_SIGNATURE_AREA - 1


def _signature_block_geometry(raw: bytes, locale: str) -> dict[str, object]:
    """Signature label geometry on the last page (PyMuPDF).

    Returns ``{"label": (x0, x1) | None, "label_y0": float | None,
    "has_rule": bool, "content_max_y1": float, "page_width": float}``
    in PDF coordinates (y grows down). ``content_max_y1`` is the lowest
    text bottom excluding the footer and the signature label itself, so
    overlap can be asserted; ``has_rule`` reports whether a signature-
    sized rule (≈60 mm hairline in the bottom 80 pt) is still drawn.
    """
    import pymupdf

    shaped = shape_text(label("signature", locale))
    # ``shape_text`` emits reversed presentation forms for RTL (the
    # ReportLab wordWrap='RTL' convention); PyMuPDF extracts them in
    # logical order — accept either orientation.
    expected = {shaped, shaped[::-1]}
    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        page = doc[-1]
        height = page.rect.height
        label_span: tuple[float, float] | None = None
        label_y0: float | None = None
        has_rule = False
        content_max_y1 = 0.0
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for span in line["spans"]:
                    text = span["text"].strip()
                    if not text:
                        continue
                    x0, y0, x1, y1 = span["bbox"]
                    if text in expected:
                        label_span = (x0, x1)
                        label_y0 = y0
                        continue
                    # Footer sits within the bottom 20 pt, centered.
                    if height - y1 < 20.0 and 200 < x0 < 400:
                        continue
                    content_max_y1 = max(content_max_y1, y1)
        for drawing in page.get_drawings():
            for item in drawing["items"]:
                if item[0] != "l":
                    continue
                p1, p2 = item[1], item[2]
                if abs(p1.y - p2.y) > 0.5:
                    continue
                span = abs(p2.x - p1.x)
                if 140 < span < 220 and 0 < (height - p1.y) < 80:
                    has_rule = True
        return {
            "label": label_span,
            "label_y0": label_y0,
            "has_rule": has_rule,
            "content_max_y1": content_max_y1,
            "page_width": page.rect.width,
        }
    finally:
        doc.close()


def test_signature_label_centered_on_block_span_fr_and_ar(
    client, admin_headers, db):
    """The label stays centered on the block's 60 mm span (legacy
    ``pdf_invoice.dart`` Align+Column centering) for both LTR and RTL,
    and no signature rule is drawn anymore."""
    from reportlab.lib.units import mm

    body = _create(client, admin_headers, str(_invoice_client(db).id))
    for locale in ("fr", "ar"):
        resp = _print(client, admin_headers, body["id"], locale=locale)
        assert resp.status_code == 200, resp.text
        geo = _signature_block_geometry(resp.content, locale)
        label_span = geo["label"]
        assert label_span is not None, f"label not found ({locale})"
        assert geo["has_rule"] is False, f"rule must be absent ({locale})"
        # Frame content edges: 15 mm margin + 6 pt Frame padding.
        edge = 15 * mm + 6
        page_width = float(geo["page_width"])
        if locale == "ar":
            block_center = edge + 30 * mm
        else:
            block_center = page_width - edge - 30 * mm
        label_center = (label_span[0] + label_span[1]) / 2
        assert abs(label_center - block_center) <= 5.0, (
            f"{locale}: label center {label_center:.1f} vs block center "
            f"{block_center:.1f} (label={label_span})"
        )


def test_signature_block_never_overlaps_content(client, admin_headers, db):
    """The bottom-pinned signature block keeps its own area: the label
    starts below the lowest content line (notes / payment / words), on
    both a short document and a nearly-full final page."""
    for lines in (None, 16):
        kwargs = {"notes": "Bottom pin check"}
        if lines is not None:
            kwargs["lines"] = [
                {
                    "description": f"Article numero {i}",
                    "quantity": "1",
                    "unit_price_ht": "100.000",
                    "tva_rate": "19",
                    "discount_pct": "0",
                }
                for i in range(lines)
            ]
        body_i = _create(client, admin_headers, str(_invoice_client(db).id), **kwargs)
        resp = _print(client, admin_headers, body_i["id"], locale="fr")
        assert resp.status_code == 200, resp.text
        geo = _signature_block_geometry(resp.content, "fr")
        label_y0 = geo["label_y0"]
        assert label_y0 is not None
        content_bottom = float(geo["content_max_y1"])
        assert label_y0 > content_bottom - 2.0, (
            f"signature label top {label_y0:.1f} overlaps content "
            f"(lowest content bottom {content_bottom:.1f}) for lines={lines}"
        )


def test_facture_footer_blank_no_page_numbers_company_in_header(
    client, admin_headers, db):
    """Final layout cleanup: the A4 facturation footer is EMPTY — no
    ``Page N / M`` stamp and no company-name prefix on ANY page. The
    seller identity still prints in the page header block, and the
    signature label keeps its bottom-pinned position."""
    _put_settings(client, admin_headers, COMPANY)
    body = _create(
        client,
        admin_headers,
        str(_invoice_client(db).id),
        lines=[
            {
                "description": f"Article numero {i}",
                "quantity": "1",
                "unit_price_ht": "100.000",
                "tva_rate": "19",
                "discount_pct": "0",
            }
            for i in range(120)
        ],
    )
    resp = _print(client, admin_headers, body["id"], locale="fr")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    pages = _page_count(raw)
    assert pages >= 3

    text = _pdf_text(raw)
    # No `Page N / M` text anywhere in the document.
    assert _page_number_hits(text) == [], (
        f"page numbering must be absent, got {_page_number_hits(text)}"
    )
    assert "Page" not in text
    # Every page's footer band is completely blank (no prefix either).
    for pno, band in enumerate(_footer_band_texts(raw), start=1):
        assert band.strip() == "", (
            f"page {pno}: footer band must be blank, got {band!r}"
        )

    import pymupdf

    doc = pymupdf.open(stream=raw, filetype="pdf")
    try:
        page = doc[0]
        header_texts = [
            span["text"]
            for block in page.get_text("dict")["blocks"]
            for line in block.get("lines", [])
            for span in line["spans"]
            if span["bbox"][1] < 150.0
        ]
        assert "SARL Print Test" in " ".join(header_texts), (
            "company name must stay in the page header block"
        )
    finally:
        doc.close()
    # The seller identity is still printed in the document text…
    assert "SARL Print Test" in text
    # …and the signature label keeps its bottom-pinned spot.
    y = _signature_label_y_from_bottom(raw, "fr")
    assert y is not None, "signature label not found in rendered PDF"
    assert 70.0 <= y <= 100.0, f"signature label at {y:.1f} pt from bottom"


def test_facture_footer_blank_in_arabic_too(client, admin_headers, db):
    """Arabic (RTL) facturation PDF: the shaped ``صفحة`` page label is
    never drawn and every footer band stays blank — while the header
    company block and the signature label are untouched."""
    _put_settings(client, admin_headers, COMPANY)
    body = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = _print(client, admin_headers, body["id"], locale="ar")
    assert resp.status_code == 200, resp.text
    raw = resp.content
    text = _pdf_text(raw)
    assert shape_text(label("page", "ar")) not in text
    assert _page_number_hits(text) == []
    for pno, band in enumerate(_footer_band_texts(raw), start=1):
        assert band.strip() == "", (
            f"page {pno}: footer band must be blank, got {band!r}"
        )
    assert shape_text(COMPANY["store_name"]) in text  # header block
    assert shape_text(label("signature", "ar")) in text
