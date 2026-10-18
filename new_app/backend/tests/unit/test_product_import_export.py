"""Product import / export (Objective 1) — API + service tests.

Covers:
- export: auth/permission gates, scopes (all/filtered/selected), CSV+XLSX
  bytes, headers, audit row, row-limit error
- import: dry-run preview (default), apply, conflict policies
  (skip/update/reject), per-row failure reporting, partial success
- malformed files: empty, bad encoding, missing name column, macro
  workbook, oversize file
- duplicate barcode inside one file, conflicting product_id/barcode
- Arabic headers and names, current_stock informational-only
- explicit column mapping, is_active=false archiving
- round-trip: export -> import leaves the catalogue unchanged
"""

from __future__ import annotations

import csv
import io
import json
import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from openpyxl import Workbook, load_workbook
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.schemas.product_transfer import (
    EXPORT_FIELDS,
    MAX_IMPORT_BYTES,
)
from app.services.auth import AuthService


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


def _create_product(client, headers, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", "Test Product"),
        "barcode": overrides.pop("barcode", "1111111111111"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "80.000"),
        "quantity": overrides.pop("quantity", "10.000"),
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _csv_upload(rows: list[list[str]], headers_row=None) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\r\n")
    writer.writerow(headers_row or list(EXPORT_FIELDS))
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue().encode("utf-8-sig")


def _import(
    client,
    headers,
    content: bytes,
    filename: str = "products.csv",
    *,
    dry_run: bool = True,
    on_conflict: str = "skip",
    mapping: dict | None = None,
):
    data = {"dry_run": str(dry_run).lower(), "on_conflict": on_conflict}
    if mapping is not None:
        data["mapping"] = json.dumps(mapping)
    return client.post(
        "/api/v1/products/import",
        files={"file": (filename, content, "text/csv")},
        data=data,
        headers=headers,
    )


def _row_for(name: str, report: dict) -> dict | None:
    return next((r for r in report["rows"] if r.get("name") == name), None)


# ---------------------------------------------------------------------------
# Export — gates and basics
# ---------------------------------------------------------------------------


def test_export_requires_auth(client):
    resp = client.post("/api/v1/products/export", json={"format": "csv"})
    assert resp.status_code == 401


def test_export_denied_for_cashier(client, cashier_headers):
    resp = client.post(
        "/api/v1/products/export",
        json={"format": "csv"},
        headers=cashier_headers,
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "FORBIDDEN"


def test_export_csv_all_returns_bytes_and_headers(
    client, admin_headers, db
):
    _create_product(client, admin_headers, name="Eau minérale", barcode="222")
    resp = client.post(
        "/api/v1/products/export",
        json={"format": "csv", "scope": "all"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.headers["X-Export-Scope"] == "all"
    assert resp.headers["X-Export-Rows"] == "1"
    assert "text/csv" in resp.headers["content-type"]
    assert "attachment" in resp.headers["content-disposition"]
    text = resp.content.decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(text)))
    assert rows[0] == list(EXPORT_FIELDS)
    assert any("Eau minérale" in cell for cell in rows[1])


def test_export_xlsx_is_readable(client, admin_headers):
    _create_product(client, admin_headers, name="X", barcode="333")
    resp = client.post(
        "/api/v1/products/export",
        json={"format": "xlsx", "scope": "all"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    workbook = load_workbook(io.BytesIO(resp.content), read_only=True)
    sheet = workbook.worksheets[0]
    header = [c.value for c in next(sheet.iter_rows(max_row=1))]
    assert header == list(EXPORT_FIELDS)
    workbook.close()


def test_export_selected_with_unknown_id_is_422(client, admin_headers):
    resp = client.post(
        "/api/v1/products/export",
        json={"scope": "selected", "product_ids": [str(uuid.uuid4())]},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_export_writes_audit_row(client, admin_headers, db):
    _create_product(client, admin_headers, barcode="444")
    client.post(
        "/api/v1/products/export",
        json={"format": "csv"},
        headers=admin_headers,
    )
    rows = db.scalars(
        select(AuditLog).where(AuditLog.entity_type == "product_export")
    ).all()
    assert len(rows) == 1
    assert rows[0].action == "export"


# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------


def test_template_requires_auth(client):
    resp = client.get("/api/v1/products/import/template")
    assert resp.status_code == 401


def test_template_downloadable_by_cashier(client, cashier_headers):
    resp = client.get(
        "/api/v1/products/import/template?format=csv",
        headers=cashier_headers,
    )
    assert resp.status_code == 200
    text = resp.content.decode("utf-8-sig")
    first_line = text.splitlines()[0]
    assert "name" in first_line
    # header only — never an importable example row
    assert len(text.splitlines()) == 1


def test_template_xlsx_has_docs_sheet(client, admin_headers):
    resp = client.get(
        "/api/v1/products/import/template?format=xlsx&locale=fr",
        headers=admin_headers,
    )
    assert resp.status_code == 200
    workbook = load_workbook(io.BytesIO(resp.content), read_only=True)
    assert "columns" in workbook.sheetnames
    workbook.close()


# ---------------------------------------------------------------------------
# Import — gates and dry run
# ---------------------------------------------------------------------------


def test_import_requires_auth(client):
    resp = client.post("/api/v1/products/import", files={"file": ("a.csv", b"a", "text/csv")})
    assert resp.status_code == 401


def test_import_denied_for_cashier(client, cashier_headers):
    resp = _import(client, cashier_headers, b"name,price\nA,1\n")
    assert resp.status_code == 403


def test_import_dry_run_is_default_and_writes_nothing(
    client, admin_headers, db
):
    content = _csv_upload([["", "Croissant", "", "", "", "", "25", "", "", "", "", "", "", "", "", "", "true", ""]])
    resp = _import(client, admin_headers, content)
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["dry_run"] is True
    assert report["applied"] is False
    assert report["created"] == 1
    db.expire_all()
    assert db.scalar(select(Product)) is None


def test_import_apply_creates_products(client, admin_headers, db):
    content = _csv_upload(
        [
            ["", "Croissant", "500", "", "", "", "25", "", "", "", "", "", "", "", "", "", "true", ""],
            ["", "Baguette", "501", "", "", "", "15", "", "", "", "", "", "", "", "", "", "true", ""],
        ]
    )
    resp = _import(client, admin_headers, content, dry_run=False)
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["applied"] is True
    assert report["created"] == 2
    assert report["failed"] == 0
    db.expire_all()
    names = {p.name for p in db.scalars(select(Product)).all()}
    assert names == {"Croissant", "Baguette"}


def test_import_writes_audit_row(client, admin_headers, db):
    content = _csv_upload([["", "AuditMe", "600", "", "", "", "10", "", "", "", "", "", "", "", "", "", "true", ""]])
    _import(client, admin_headers, content, dry_run=False)
    db.expire_all()
    rows = db.scalars(
        select(AuditLog).where(AuditLog.entity_type == "product_import")
    ).all()
    assert len(rows) == 1
    assert rows[0].action == "import"


# ---------------------------------------------------------------------------
# Malformed files (file-level errors, before any row)
# ---------------------------------------------------------------------------


def test_import_empty_file(client, admin_headers):
    resp = _import(client, admin_headers, b"")
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "IMPORT_EMPTY_FILE"


def test_import_non_utf8_csv_is_rejected(client, admin_headers):
    # latin-1 bytes that are not valid UTF-8
    content = b"name,price\nCaf\xe9,10\n"
    resp = _import(client, admin_headers, content)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "IMPORT_ENCODING_UNSUPPORTED"


def test_import_missing_name_column(client, admin_headers):
    resp = _import(client, admin_headers, b"foo,bar\n1,2\n")
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "IMPORT_MISSING_REQUIRED_COLUMN"


def test_import_macro_workbook_rejected(client, admin_headers):
    resp = _import(client, admin_headers, b"PK\x03\x04junk", filename="book.xlsm")
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "IMPORT_FORMAT_UNSUPPORTED"


def test_import_oversize_file_is_413(client, admin_headers):
    content = b"a" * (MAX_IMPORT_BYTES + 1)
    resp = _import(client, admin_headers, content)
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "IMPORT_FILE_TOO_LARGE"


# ---------------------------------------------------------------------------
# Row-level failures and conflict handling
# ---------------------------------------------------------------------------


def test_duplicate_barcode_in_file_fails_second_row(client, admin_headers, db):
    content = _csv_upload(
        [
            ["", "Dup A", "700", "", "", "", "10", "", "", "", "", "", "", "", "", "", "true", ""],
            ["", "Dup B", "700", "", "", "", "20", "", "", "", "", "", "", "", "", "", "true", ""],
        ]
    )
    resp = _import(client, admin_headers, content, dry_run=False)
    report = resp.json()
    assert report["created"] == 1
    assert report["failed"] == 1
    failed = next(r for r in report["rows"] if r["action"] == "failed")
    assert "barcode" in " ".join(failed["messages"]).lower()
    db.expire_all()
    assert db.scalar(select(Product).where(Product.name == "Dup B")) is None


def test_missing_required_fields_fail_row(client, admin_headers):
    # no name, no price
    content = _csv_upload([["", "", "800", "", "", "", "", "", "", "", "", "", "", "", "", "", "true", ""]])
    resp = _import(client, admin_headers, content, dry_run=False)
    report = resp.json()
    assert report["failed"] == 1
    assert report["created"] == 0


def test_conflict_skip_update_reject(client, admin_headers, db):
    product = _create_product(client, admin_headers, name="Existing", barcode="900", price="100")
    content = _csv_upload([[product["id"], "Existing", "900", "", "", "", "150", "", "", "", "", "", "", "", "", "", "true", ""]])

    # skip
    report = _import(client, admin_headers, content, dry_run=False, on_conflict="skip").json()
    assert report["skipped"] == 1
    db.expire_all()
    assert Decimal(db.get(Product, uuid.UUID(product["id"])).price) == Decimal("100")

    # reject
    report = _import(client, admin_headers, content, dry_run=False, on_conflict="reject").json()
    assert report["failed"] == 1

    # update
    report = _import(client, admin_headers, content, dry_run=False, on_conflict="update").json()
    assert report["updated"] == 1
    db.expire_all()
    assert Decimal(db.get(Product, uuid.UUID(product["id"])).price) == Decimal("150")


def test_partial_failure_keeps_successful_rows(client, admin_headers, db):
    content = _csv_upload(
        [
            ["", "Good Row", "950", "", "", "", "10", "", "", "", "", "", "", "", "", "", "true", ""],
            ["", "Bad Row", "951", "", "", "", "-5", "", "", "", "", "", "", "", "", "", "true", ""],
        ]
    )
    resp = _import(client, admin_headers, content, dry_run=False)
    report = resp.json()
    assert report["created"] == 1
    assert report["failed"] == 1
    db.expire_all()
    assert db.scalar(select(Product).where(Product.name == "Good Row")) is not None
    assert db.scalar(select(Product).where(Product.name == "Bad Row")) is None


def test_product_id_matched_by_barcode_when_id_unknown(client, admin_headers, db):
    product = _create_product(client, admin_headers, name="Fallback", barcode="980", price="50")
    fake_id = str(uuid.uuid4())
    content = _csv_upload([[fake_id, "Fallback", "980", "", "", "", "60", "", "", "", "", "", "", "", "", "", "true", ""]])
    report = _import(client, admin_headers, content, dry_run=False, on_conflict="update").json()
    assert report["updated"] == 1
    row = _row_for("Fallback", report)
    assert any("barcode" in m for m in row["messages"])
    db.expire_all()
    assert Decimal(db.get(Product, uuid.UUID(product["id"])).price) == Decimal("60")


# ---------------------------------------------------------------------------
# Localization & informational columns
# ---------------------------------------------------------------------------


def test_arabic_headers_and_names_import(client, admin_headers, db):
    content = _csv_upload(
        [["", "خبز عربي", "1234567890123", "", "", "", "30", "", "", "", "", "", "", "", "", "", "true", ""]],
        headers_row=["المعرف", "الاسم", "الباركود", "المرجع", "الفئة", "الوحدة", "سعر البيع", "سعر الشراء", "الجملة", "الحد الأدنى للجملة", "الضريبة", "حد التنبيه", "السالب", "الصلاحية", "الوصف", "الصورة", "الحالة", "الكمية"],
    )
    resp = _import(client, admin_headers, content, dry_run=False)
    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["created"] == 1
    db.expire_all()
    product = db.scalar(select(Product).where(Product.barcode == "1234567890123"))
    assert product is not None
    assert product.name == "خبز عربي"
    assert Decimal(product.price) == Decimal("30")


def test_current_stock_is_informational_only(client, admin_headers, db):
    content = _csv_upload(
        [["", "NoStock", "990", "", "", "", "10", "", "", "", "", "", "", "", "", "", "true", "999"]]
    )
    report = _import(client, admin_headers, content, dry_run=False).json()
    assert report["ignored_fields"] == ["current_stock"]
    assert any("stock" in w.lower() for w in report["warnings"])
    db.expire_all()
    product = db.scalar(select(Product).where(Product.barcode == "990"))
    assert Decimal(product.quantity) == Decimal("0")


def test_french_headers_map_automatically(client, admin_headers, db):
    content = _csv_upload(
        [["", "Yaourt", "880", "", "", "", "25", "", "", "", "", "", "", "", "", "", "true", ""]],
        headers_row=["identifiant", "nom", "code_barre", "ref", "categorie", "unite", "prix", "prix_achat", "prix_gros", "min_gros", "tva", "seuil", "stock_negatif", "dlc", "description", "image", "etat", "stock"],
    )
    report = _import(client, admin_headers, content, dry_run=False).json()
    assert report["created"] == 1


# ---------------------------------------------------------------------------
# Explicit mapping
# ---------------------------------------------------------------------------


def test_explicit_mapping_overrides_auto_map(client, admin_headers, db):
    content = b"colA,colB\nMapMe,42\n"
    mapping = {"name": 0, "sale_price": 1}
    report = _import(
        client, admin_headers, content, dry_run=False, mapping=mapping
    ).json()
    assert report["created"] == 1
    db.expire_all()
    product = db.scalar(select(Product).where(Product.name == "MapMe"))
    assert Decimal(product.price) == Decimal("42")


def test_invalid_mapping_is_422(client, admin_headers):
    content = b"name,price\nA,1\n"
    resp = _import(
        client, admin_headers, content, mapping={"nope": 0}
    )
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# is_active=false archiving
# ---------------------------------------------------------------------------


def test_is_active_false_archives_existing(client, admin_headers, db):
    product = _create_product(client, admin_headers, name="ToArchive", barcode="770")
    content = _csv_upload([[product["id"], "ToArchive", "770", "", "", "", "100", "", "", "", "", "", "", "", "", "", "false", ""]])
    report = _import(client, admin_headers, content, dry_run=False, on_conflict="update").json()
    assert report["updated"] == 1
    db.expire_all()
    refreshed = db.get(Product, uuid.UUID(product["id"]))
    assert refreshed.archived_at is not None


def test_is_active_false_on_create_row_fails(client, admin_headers):
    content = _csv_upload([["", "NewButInactive", "771", "", "", "", "10", "", "", "", "", "", "", "", "", "", "false", ""]])
    report = _import(client, admin_headers, content, dry_run=False).json()
    assert report["failed"] == 1


# ---------------------------------------------------------------------------
# XLSX import + round trip
# ---------------------------------------------------------------------------


def test_xlsx_import_creates(client, admin_headers, db):
    workbook = Workbook(write_only=True)
    sheet = workbook.create_sheet(title="Products")
    sheet.append(list(EXPORT_FIELDS))
    sheet.append(["", "Xlsx Product", "660", "", "", "", "33", "", "", "", "", "", "", "", "", "", "true", ""])
    buffer = io.BytesIO()
    workbook.save(buffer)
    resp = _import(client, admin_headers, buffer.getvalue(), filename="p.xlsx", dry_run=False)
    assert resp.status_code == 200, resp.text
    assert resp.json()["created"] == 1


def test_round_trip_export_then_import_is_noop(client, admin_headers, db):
    _create_product(client, admin_headers, name="Rounded", barcode="3101234567890", price="12.500", cost="9.000")
    export = client.post(
        "/api/v1/products/export",
        json={"format": "csv", "scope": "all"},
        headers=admin_headers,
    )
    assert export.status_code == 200

    before = [
        (p.id, p.name, p.barcode, p.price, p.quantity)
        for p in db.scalars(select(Product)).all()
    ]

    report = _import(client, admin_headers, export.content, dry_run=False, on_conflict="update").json()
    assert report["updated"] >= 1
    assert report["failed"] == 0

    db.expire_all()
    after = [
        (p.id, p.name, p.barcode, p.price, p.quantity)
        for p in db.scalars(select(Product)).all()
    ]
    assert after == before


def test_formula_injection_neutralized_on_export(client, admin_headers, db):
    _create_product(client, admin_headers, name="=cmd|' /C calc'!A0", barcode="320")
    resp = client.post(
        "/api/v1/products/export",
        json={"format": "csv", "scope": "all"},
        headers=admin_headers,
    )
    text = resp.content.decode("utf-8-sig")
    assert "'=cmd" in text  # prefixed, never a live formula
    # and the importer strips the prefix back on a round trip
    report = _import(client, admin_headers, resp.content, dry_run=False, on_conflict="update").json()
    assert report["failed"] == 0
    db.expire_all()
    product = db.scalar(select(Product).where(Product.barcode == "320"))
    assert product.name == "=cmd|' /C calc'!A0"


# ---------------------------------------------------------------------------
# Permissions: manager can import/export
# ---------------------------------------------------------------------------


def test_manager_can_export_and_import(client, manager_headers, db):
    resp = client.post(
        "/api/v1/products/export",
        json={"format": "csv"},
        headers=manager_headers,
    )
    assert resp.status_code == 200

    content = _csv_upload([["", "Manager Product", "330", "", "", "", "11", "", "", "", "", "", "", "", "", "", "true", ""]])
    report = _import(client, manager_headers, content, dry_run=False).json()
    assert report["created"] == 1
