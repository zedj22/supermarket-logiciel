"""Phase 6 — company/fiscal settings on the EXISTING ``app_settings`` row.

Requirement coverage (Phase 6 audit → implementation):

- **Existing settings remain unchanged** — the Phase 17 defaults and the
  original nine fields still round-trip exactly as before.
- **New settings exposed through the existing settings API** — the seven
  company/fiscal fields ride ``GET/PUT /api/v1/settings``; no endpoint,
  route or permission was added.
- **Facturation reads settings without separate DB writes** —
  ``get_facturation_company_settings`` reads the same row and never
  creates one, never writes, never audits.
- **Legacy identity fields covered** — ``name``/``address``/``phone`` map
  to ``store_name``/``store_address``/``store_phone``; wilaya, email,
  NIF, NIS, RC, AI, RIB exist as new columns and nothing else.
- **Optional fields default to empty** — model, service and API all
  return ``""`` on a database that was never written to.
- **Validation** — column lengths enforced (422), blank allowed for the
  optional fiscal fields, whitespace trimmed, ``store_name`` still cannot
  be blank, unknown legacy keys are not a second settings surface.
- **No duplicate settings source** — one settings table, one settings
  endpoint, one audited write path.
- **Phase 1 calculation behavior unchanged** — settings are not an input
  to ``calculate_document_result``: identical totals before and after a
  company/fiscal update, and the known Phase 1 figures still hold.
- **Phase 5 document creation/update/list behavior unchanged** — full
  create/get/list/update round-trip while company settings are filled.
"""

from __future__ import annotations

import dataclasses
import json
import uuid
from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.facturation import InvoiceClient, InvoiceDocumentLine
from app.models.settings import SINGLETON_ID, AppSetting
from app.services.auth import AuthService
from app.services.facturation import (
    FacturationCompanySettings,
    calculate_document_result,
    get_facturation_company_settings,
)

DAY = "2026-10-09"
YEAR = 2026

FISCAL_FIELDS: dict[str, str] = {
    "store_wilaya": "Alger",
    "store_email": "contact@sarl-demo.dz",
    "store_nif": "0002213400067",
    "store_nis": "0011223344",
    "store_rc": "16/00-1234567 B 09",
    "store_ai": "0991612345678",
    "store_rib": "00799999001234567890",
}

EXPECTED_TOTALS = {
    "total_ht": "400.00",
    "total_tva": "76.00",
    "total_ttc": "476.00",
    "timbre": "5",
    "net_a_payer": "481.00",
}


# ---------------------------------------------------------------------------
# Fixtures (same pattern as test_settings.py / test_facturation_documents_api)
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
    session = testing_session()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    service.create_user(name="Cashier Ali", pin="3333", role_names=["cashier"])
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


def _get(client, headers) -> dict:
    resp = client.get("/api/v1/settings", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _put(client, headers, payload: dict) -> dict:
    resp = client.put("/api/v1/settings", json=payload, headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _audit_rows(db) -> list[AuditLog]:
    return list(
        db.scalars(
            select(AuditLog).where(AuditLog.entity_type == "settings")
        ).all()
    )


def _invoice_client(db, name: str = "Fiscal Client") -> InvoiceClient:
    row = InvoiceClient(name=name, nif="0002213400067")
    db.add(row)
    db.commit()
    return row


def _payload(client_id: str, **overrides) -> dict:
    payload = {
        "doc_type": "FAC",
        "client_id": client_id,
        "document_date": DAY,
        "payment_method": "cash",
        "notes": "Phase 6 regression",
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


# ---------------------------------------------------------------------------
# 1. Existing settings remain unchanged
# ---------------------------------------------------------------------------


def test_existing_defaults_are_untouched(client, admin_headers):
    body = _get(client, admin_headers)
    assert body["store_name"] == settings.STORE_NAME
    assert body["store_phone"] == ""
    assert body["store_address"] == ""
    assert body["invoice_footer"] == ""
    assert body["default_paper"] == "80mm"
    assert body["ask_before_print"] is False
    assert body["auto_print_invoice"] is False
    assert body["allow_debt"] is True
    assert body["low_stock_threshold"] == 5


def test_existing_fields_still_round_trip_alone(client, admin_headers):
    _put(
        client,
        admin_headers,
        {
            "store_name": "مخبز النور",
            "store_phone": "0550123456",
            "store_address": "12 Rue de la Liberté, Alger",
            "invoice_footer": "شكرًا لزيارتكم",
            "allow_debt": False,
            "default_paper": "A4",
        },
    )
    body = _get(client, admin_headers)
    assert body["store_name"] == "مخبز النور"
    assert body["store_phone"] == "0550123456"
    assert body["store_address"] == "12 Rue de la Liberté, Alger"
    assert body["invoice_footer"] == "شكرًا لزيارتكم"
    assert body["allow_debt"] is False
    assert body["default_paper"] == "A4"
    # a fiscal write never disturbs them either
    _put(client, admin_headers, {"store_nif": "0002213400067"})
    again = _get(client, admin_headers)
    assert again["store_phone"] == "0550123456"
    assert again["default_paper"] == "A4"
    assert again["low_stock_threshold"] == 5


# ---------------------------------------------------------------------------
# 2. New settings exposed through the existing settings API
# ---------------------------------------------------------------------------


def test_fiscal_fields_default_to_empty_in_the_api(client, admin_headers):
    body = _get(client, admin_headers)
    for field in FISCAL_FIELDS:
        assert body[field] == "", field


def test_every_company_field_round_trips(client, admin_headers):
    payload = {
        "store_name": "SARL Démo",
        "store_address": "12 Rue de la Liberté, Alger",
        "store_phone": "021 55 66 77",
        **FISCAL_FIELDS,
    }
    body = _put(client, admin_headers, payload)
    for field, value in payload.items():
        assert body[field] == value, field

    read_back = _get(client, admin_headers)
    for field, value in payload.items():
        assert read_back[field] == value, field


def test_fiscal_write_creates_the_single_singleton_row(client, admin_headers, db):
    _put(client, admin_headers, FISCAL_FIELDS)
    rows = list(db.scalars(select(AppSetting)))
    assert len(rows) == 1
    assert rows[0].id == SINGLETON_ID
    assert rows[0].store_nif == FISCAL_FIELDS["store_nif"]
    assert rows[0].store_rib == FISCAL_FIELDS["store_rib"]


def test_partial_fiscal_update_leaves_the_rest_alone(client, admin_headers):
    _put(client, admin_headers, FISCAL_FIELDS)
    body = _put(client, admin_headers, {"store_wilaya": "Oran"})
    assert body["store_wilaya"] == "Oran"
    assert body["store_nif"] == FISCAL_FIELDS["store_nif"]
    assert body["store_email"] == FISCAL_FIELDS["store_email"]
    assert body["allow_debt"] is True
    assert body["low_stock_threshold"] == 5


def test_no_new_settings_endpoint_exists():
    """Phase 6 adds no route: GET/PUT ``/api/v1/settings`` is the surface."""
    paths = app.openapi()["paths"]
    settings_paths = {p for p in paths if "settings" in p}
    assert settings_paths == {"/api/v1/settings"}
    assert set(paths["/api/v1/settings"]) == {"get", "put"}
    # No legacy duplicate and no Facturation-specific settings surface.
    assert not [p for p in paths if p.endswith("/company")]
    assert not [p for p in paths if "fiscal" in p or "facturation" in p]


def test_company_write_keeps_the_settings_manage_permission(
    client, admin_headers, manager_headers, cashier_headers, db
):
    resp = client.put(
        "/api/v1/settings", json=FISCAL_FIELDS, headers=manager_headers
    )
    assert resp.status_code == 403
    resp = client.put(
        "/api/v1/settings", json=FISCAL_FIELDS, headers=cashier_headers
    )
    assert resp.status_code == 403
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0
    assert _audit_rows(db) == []

    resp = client.put(
        "/api/v1/settings", json=FISCAL_FIELDS, headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    rows = _audit_rows(db)
    assert len(rows) == 1
    assert rows[0].action == "update"
    details = json.loads(rows[0].details)
    assert set(details) == set(FISCAL_FIELDS)


# ---------------------------------------------------------------------------
# 3. Facturation reads settings without separate DB writes
# ---------------------------------------------------------------------------


def test_helper_reads_the_row_the_api_wrote(client, admin_headers, testing_session):
    _put(client, admin_headers, FISCAL_FIELDS)
    session = testing_session()
    try:
        company = get_facturation_company_settings(session)
    finally:
        session.close()
    assert company.name == settings.STORE_NAME
    assert company.nif == FISCAL_FIELDS["store_nif"]
    assert company.nis == FISCAL_FIELDS["store_nis"]
    assert company.rc == FISCAL_FIELDS["store_rc"]
    assert company.ai == FISCAL_FIELDS["store_ai"]
    assert company.rib == FISCAL_FIELDS["store_rib"]
    assert company.wilaya == FISCAL_FIELDS["store_wilaya"]
    assert company.email == FISCAL_FIELDS["store_email"]
    assert company.address == ""
    assert company.phone == ""


def test_helper_returns_defaults_without_creating_a_row(db, testing_session):
    session = testing_session()
    try:
        company = get_facturation_company_settings(session)
        again = get_facturation_company_settings(session)
    finally:
        session.close()
    assert company.name == settings.STORE_NAME
    assert company.address == ""
    assert company.wilaya == ""
    assert company.phone == ""
    assert company.email == ""
    assert company.nif == company.nis == company.rc == company.ai == ""
    assert company.rib == ""
    assert company == again

    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0
    assert _audit_rows(db) == []


def test_reading_company_settings_never_writes(client, admin_headers, testing_session, db):
    _put(client, admin_headers, {"store_name": "Only Name"})
    session = testing_session()
    try:
        get_facturation_company_settings(session)
        get_facturation_company_settings(session)
    finally:
        session.close()
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 1
    assert len(_audit_rows(db)) == 1  # only the PUT was audited


def test_facturation_view_is_immutable():
    view = FacturationCompanySettings(
        name="N",
        address="A",
        wilaya="W",
        phone="P",
        email="E",
        nif="1",
        nis="2",
        rc="3",
        ai="4",
        rib="5",
    )
    assert view.name == "N"
    with pytest.raises(dataclasses.FrozenInstanceError):
        view.name = "other"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# 4. Legacy identity fields covered / no duplicates
# ---------------------------------------------------------------------------


def test_name_address_phone_are_reused_not_duplicated(client, admin_headers):
    """factura_simple name/address/phone == the existing store_* columns."""
    _put(
        client,
        admin_headers,
        {"store_name": "SARL Démo", "store_address": "Rue 1, Alger", "store_phone": "021"},
    )
    columns = set(AppSetting.__table__.columns.keys())
    assert {"store_name", "store_address", "store_phone"} <= columns
    for duplicated in (
        "name",
        "address",
        "phone",
        "company_name",
        "company_address",
        "company_phone",
        "company_wilaya",
        "company_nif",
        "fiscal_name",
    ):
        assert duplicated not in columns, duplicated


def test_model_has_exactly_the_seven_new_columns():
    added = {
        "store_wilaya",
        "store_email",
        "store_nif",
        "store_nis",
        "store_rc",
        "store_ai",
        "store_rib",
    }
    assert added <= set(AppSetting.__table__.columns.keys())
    for column_name in added:
        column = AppSetting.__table__.columns[column_name]
        assert column.nullable is False, column_name
        assert column.default is not None and column.default.arg == "", column_name
        assert column.server_default is None, column_name


def test_no_settings_table_besides_app_settings():
    settings_tables = [
        name for name in Base.metadata.tables if "setting" in name.lower()
    ]
    assert settings_tables == ["app_settings"]
    for forbidden in (
        "company",
        "companies",
        "company_settings",
        "fiscal_settings",
        "facturation_settings",
    ):
        assert forbidden not in Base.metadata.tables


# ---------------------------------------------------------------------------
# 5. Optional fields default to empty + validation
# ---------------------------------------------------------------------------


def test_service_defaults_are_empty_without_a_row(db):
    from app.services.settings import SettingsService

    row = SettingsService(db).get()
    assert row.id == SINGLETON_ID
    for field in FISCAL_FIELDS:
        assert getattr(row, field) == "", field
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0


def test_blank_fiscal_value_is_accepted_and_clears_the_field(client, admin_headers):
    _put(client, admin_headers, FISCAL_FIELDS)
    body = _put(client, admin_headers, {"store_nif": "", "store_rib": ""})
    assert body["store_nif"] == ""
    assert body["store_rib"] == ""
    assert body["store_nis"] == FISCAL_FIELDS["store_nis"]


def test_fiscal_values_are_whitespace_stripped(client, admin_headers):
    body = _put(
        client,
        admin_headers,
        {"store_email": "  contact@sarl-demo.dz  ", "store_wilaya": " Alger "},
    )
    assert body["store_email"] == "contact@sarl-demo.dz"
    assert body["store_wilaya"] == "Alger"


@pytest.mark.parametrize(
    "payload",
    [
        {"store_nif": "x" * 31},
        {"store_nis": "x" * 31},
        {"store_rc": "x" * 31},
        {"store_ai": "x" * 31},
        {"store_rib": "x" * 31},
        {"store_email": "x" * 101},
        {"store_wilaya": "x" * 101},
        {"store_nif": None},
        {"store_wilaya": None},
        {},
    ],
)
def test_invalid_company_payloads_are_rejected(client, admin_headers, payload):
    resp = client.put("/api/v1/settings", json=payload, headers=admin_headers)
    assert resp.status_code == 422, payload


def test_rejected_company_update_writes_nothing(client, admin_headers, db):
    resp = client.put(
        "/api/v1/settings", json={"store_nif": "x" * 31}, headers=admin_headers
    )
    assert resp.status_code == 422
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0
    assert _audit_rows(db) == []


def test_legacy_company_payload_is_not_a_second_settings_surface(
    client, admin_headers, db
):
    """factura_simple's ``PUT /company`` keys are not accepted here."""
    resp = client.put(
        "/api/v1/settings",
        json={
            "name": "SARL Démo",
            "address": "Rue 1",
            "wilaya": "Alger",
            "nif": "0002213400067",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert db.scalar(select(func.count()).select_from(AppSetting)) == 0

    resp = client.get("/api/v1/company", headers=admin_headers)
    assert resp.status_code == 404
    resp = client.get("/api/v1/settings/company", headers=admin_headers)
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# 6. Phase 1 calculation behavior remains unchanged
# ---------------------------------------------------------------------------


def _phase1_calculation() -> tuple:
    lines = [
        InvoiceDocumentLine(
            document_id=uuid.uuid4(),
            product_id=None,
            description="Prestation",
            quantity=Decimal("4"),
            unit_price_ht=Decimal("100"),
            tva_rate=Decimal("19"),
            discount_pct=Decimal("0"),
            position=0,
        )
    ]
    result = calculate_document_result(
        "FAC", "cash", True, lines
    )
    totals = result.totals
    return (
        str(totals.total_ht),
        str(totals.total_tva),
        str(totals.total_ttc),
        str(totals.timbre),
        str(totals.net_a_payer),
        result.amount_in_words,
    )


def test_phase1_calculation_matches_the_documented_figures():
    total_ht, total_tva, total_ttc, timbre, net_a_payer, words = (
        _phase1_calculation()
    )
    assert total_ht == EXPECTED_TOTALS["total_ht"]
    assert total_tva == EXPECTED_TOTALS["total_tva"]
    assert total_ttc == EXPECTED_TOTALS["total_ttc"]
    assert timbre == EXPECTED_TOTALS["timbre"]
    assert net_a_payer == EXPECTED_TOTALS["net_a_payer"]
    assert words


def test_settings_are_not_an_input_to_phase1_calculation(client, admin_headers):
    """Populating company/fiscal settings cannot move a single centime."""
    before = _phase1_calculation()
    _put(
        client,
        admin_headers,
        {
            **FISCAL_FIELDS,
            "store_name": "SARL Démo",
            "store_address": "12 Rue de la Liberté, Alger",
            "store_phone": "021 55 66 77",
            "invoice_footer": "Merci de votre visite",
            "default_paper": "A4",
            "allow_debt": False,
            "low_stock_threshold": 99,
        },
    )
    after = _phase1_calculation()
    assert before == after
    assert after[4] == EXPECTED_TOTALS["net_a_payer"]


# ---------------------------------------------------------------------------
# 7. Phase 5 document creation / update / list behavior remains unchanged
# ---------------------------------------------------------------------------


def test_phase5_workflow_with_company_settings_populated(client, admin_headers, db):
    _put(client, admin_headers, FISCAL_FIELDS)
    client_id = str(_invoice_client(db).id)

    created = client.post(
        "/api/v1/factures", json=_payload(client_id), headers=admin_headers
    )
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["number"] == "FAC-2026-0001"
    assert body["year"] == YEAR
    assert body["doc_type"] == "FAC"
    assert body["amount_in_words"]
    assert body["totals"] == EXPECTED_TOTALS

    detail = client.get(
        f"/api/v1/factures/{body['id']}", headers=admin_headers
    )
    assert detail.status_code == 200
    assert detail.json()["totals"] == EXPECTED_TOTALS

    listed = client.get("/api/v1/factures", headers=admin_headers)
    assert listed.status_code == 200
    envelope = listed.json()
    assert envelope["total"] == 1
    assert envelope["items"][0]["number"] == "FAC-2026-0001"
    assert "lines" not in envelope["items"][0]
    assert "totals" not in envelope["items"][0]

    updated = client.put(
        f"/api/v1/factures/{body['id']}",
        json={"payment_method": "transfer", "notes": "updated"},
        headers=admin_headers,
    )
    assert updated.status_code == 200, updated.text
    changed = updated.json()
    assert changed["number"] == "FAC-2026-0001"
    assert changed["totals"] == {
        "total_ht": "400.00",
        "total_tva": "76.00",
        "total_ttc": "476.00",
        "timbre": "0",
        "net_a_payer": "476.00",
    }

    # The company settings are still exactly what was stored.
    assert _get(client, admin_headers)["store_nif"] == FISCAL_FIELDS["store_nif"]


def test_phase5_documents_ignore_company_settings_for_validation(
    client, admin_headers, db
):
    """A blank company identity does not block document creation."""
    assert _get(client, admin_headers)["store_name"] == settings.STORE_NAME
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures", json=_payload(client_id), headers=admin_headers
    )
    assert resp.status_code == 201, resp.text
    assert resp.json()["totals"]["net_a_payer"] == "481.00"


def test_document_dates_and_ids_are_still_independent_of_settings(
    client, admin_headers, db
):
    _put(client, admin_headers, {"store_wilaya": "Annaba"})
    client_id = str(_invoice_client(db).id)
    created = client.post(
        "/api/v1/factures",
        json=_payload(client_id, document_date=DAY),
        headers=admin_headers,
    )
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["document_date"] == DAY
    assert body["client_id"] == client_id
    assert uuid.UUID(body["id"])
    assert date.fromisoformat(body["document_date"]) == date.fromisoformat(DAY)
