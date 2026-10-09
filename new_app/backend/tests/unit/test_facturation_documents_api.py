"""Phase 5 tests — ``/api/v1/factures`` REST layer.

Same TestClient pattern as ``test_customers_crud``: one shared
StaticPool SQLite engine, seeded roles + admin + role-less guest, real
login for bearer tokens, ``get_db`` overridden per request.

Covers the required Phase 5 API scenarios:

- RBAC: 401 without a token on every route (including PDF); a
  role-less guest and a Cashier are 403 on every route with the
  ``required_permission`` envelope; Admin and Manager are allowed
  subject to normal validation; no DELETE route exists (405), because
  historical fiscal documents are never deleted.
- Create: 201 + full body (number / year / flags / embedded client /
  lines with ids / Phase 1 totals / amount in words), Decimal fields
  serialized as JSON strings, all five doc types, structured error
  envelopes (404 / 422).
- Get / list: detail with calculation, 404 envelope, lean summary rows
  (no lines / totals), pagination envelope, filters, deterministic
  newest-first ordering, 422 filter validation.
- Update: partial PUT, immutable identity ignored, explicit-null 422,
  404 envelope, lines replacement.
- Preview: totals + proposed number, zero persistence, mirrors create
  validation.
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
)
from app.services.auth import AuthService

DAY = "2026-10-08"
YEAR = 2026


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
    """Seeded session: roles/permissions + admin + manager + cashier + role-less guest."""
    session = TestingSession()
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


def _invoice_client(db, name: str = "Fiscal Client") -> InvoiceClient:
    client = InvoiceClient(name=name, nif="0002213400067")
    db.add(client)
    db.commit()
    return client


def _product(db, **overrides) -> Product:
    values = dict(name="Coca Cola", price=Decimal("100.000"), vat_rate=19)
    values.update(overrides)
    product = Product(**values)
    db.add(product)
    db.commit()
    return product


def _payload(client_id: str, **overrides) -> dict:
    payload = {
        "doc_type": "FAC",
        "client_id": client_id,
        "document_date": DAY,
        "payment_method": "cash",
        "notes": "API document",
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


# ---------------------------------------------------------------------------
# Auth / RBAC / route surface
# ---------------------------------------------------------------------------

UNAUTH_CASES = [
    ("get", "/api/v1/factures"),
    ("post", "/api/v1/factures"),
    ("post", "/api/v1/factures/preview"),
    ("get", "/api/v1/factures/00000000-0000-0000-0000-000000000000"),
    ("put", "/api/v1/factures/00000000-0000-0000-0000-000000000000"),
    ("post", "/api/v1/factures/00000000-0000-0000-0000-000000000000/pdf"),
]


@pytest.mark.parametrize("method,path", UNAUTH_CASES)
def test_every_route_requires_authentication(client, method, path):
    kwargs = {"json": {}} if method in ("post", "put") else {}
    resp = getattr(client, method)(path, **kwargs)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


# All 11 facturation routes: (method, path, body?, required_permission)
DENIED_CASES = [
    ("get", "/api/v1/factures", False, "facturation_view"),
    ("post", "/api/v1/factures", True, "facturation_manage"),
    ("post", "/api/v1/factures/preview", True, "facturation_view"),
    ("get", "/api/v1/factures/00000000-0000-0000-0000-000000000000", False, "facturation_view"),
    ("put", "/api/v1/factures/00000000-0000-0000-0000-000000000000", True, "facturation_manage"),
    ("post", "/api/v1/factures/00000000-0000-0000-0000-000000000000/pdf", False, "facturation_view"),
    ("get", "/api/v1/invoice-clients", False, "facturation_view"),
    ("post", "/api/v1/invoice-clients", True, "facturation_manage"),
    ("get", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000", False, "facturation_view"),
    ("put", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000", True, "facturation_manage"),
    ("delete", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000", False, "facturation_manage"),
]


@pytest.mark.parametrize(
    "fixture_name", ["cashier_headers", "guest_headers"]
)
@pytest.mark.parametrize("method,path,has_body,required", DENIED_CASES)
def test_denied_roles_get_403_envelope(
    client, request, fixture_name, method, path, has_body, required
):
    """Cashier and role-less guest are 403 on every facturation route."""
    headers = request.getfixturevalue(fixture_name)
    kwargs = {"json": {}} if has_body else {}
    resp = getattr(client, method)(path, headers=headers, **kwargs)
    assert resp.status_code == 403, resp.text
    body = resp.json()
    assert body["error"]["code"] == "FORBIDDEN"
    assert body["error"]["details"]["required_permission"] == required


def test_role_less_guest_is_denied_everything(client, guest_headers, db):
    """Facturation scopes are admin+manager only — guest can never create."""
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures", json=_payload(client_id), headers=guest_headers
    )
    assert resp.status_code == 403
    assert (
        resp.json()["error"]["details"]["required_permission"]
        == "facturation_manage"
    )


def test_manager_can_use_facturation(client, manager_headers, db):
    """Manager holds both facturation scopes (seeded) — allowed end to end."""
    client_id = str(_invoice_client(db).id)
    body = _create(client, manager_headers, client_id)
    assert body["number"].startswith("FAC-2026-")
    detail = client.get(
        f"/api/v1/factures/{body['id']}", headers=manager_headers
    )
    assert detail.status_code == 200


def test_cashier_is_denied_facturation_create(client, cashier_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures", json=_payload(client_id), headers=cashier_headers
    )
    assert resp.status_code == 403
    assert (
        resp.json()["error"]["details"]["required_permission"]
        == "facturation_manage"
    )


def test_no_delete_route_on_collection_or_detail(client, admin_headers):
    """Historical fiscal documents are never deleted by the API."""
    resp = client.delete("/api/v1/factures", headers=admin_headers)
    assert resp.status_code == 405
    resp = client.delete(
        "/api/v1/factures/00000000-0000-0000-0000-000000000000",
        headers=admin_headers,
    )
    assert resp.status_code == 405


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


def test_create_returns_201_with_full_document(client, admin_headers, db):
    fiscal = _invoice_client(db, "SARL Demo")
    body = _create(client, admin_headers, str(fiscal.id))
    assert body["id"]
    assert body["doc_type"] == "FAC"
    assert body["year"] == YEAR
    assert body["number"] == "FAC-2026-0001"
    assert body["document_date"] == DAY
    assert body["payment_method"] == "cash"
    assert body["notes"] == "API document"
    assert body["show_timbre"] is True
    assert body["client"]["name"] == "SARL Demo"
    assert body["client"]["is_archived"] is False
    assert body["client"]["nif"] == "0002213400067"
    assert len(body["lines"]) == 1
    assert body["lines"][0]["id"]
    assert body["amount_in_words"]

    stored = db.get(InvoiceDocument, uuid.UUID(body["id"]))
    assert stored is not None
    assert stored.number == "FAC-2026-0001"


def test_decimals_serialize_as_json_strings(client, admin_headers, db):
    """Money is never a JSON number anywhere in this API."""
    client_id = str(_invoice_client(db).id)
    body = _create(client, admin_headers, client_id)
    totals = body["totals"]
    assert totals == {
        "total_ht": "400.00",
        "total_tva": "76.00",
        "total_ttc": "476.00",
        "timbre": "5",  # Phase 1 duty is integer-valued (raw Decimal)
        "net_a_payer": "481.00",
    }
    line = body["lines"][0]
    assert line["quantity"] == "4.000"
    assert line["unit_price_ht"] == "100.000"
    assert line["tva_rate"] == "19.000"
    assert line["discount_pct"] == "0.000"
    assert line["total_ht"] == "400.00"
    assert line["total_tva"] == "76.00"
    assert isinstance(body["year"], int)


def test_numbering_sequence_through_api(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    first = _create(client, admin_headers, client_id)
    second = _create(client, admin_headers, client_id)
    assert first["number"] == "FAC-2026-0001"
    assert second["number"] == "FAC-2026-0002"


@pytest.mark.parametrize("doc_type", ["FAC", "DEV", "PRO", "BC", "BL"])
def test_create_all_five_doc_types(client, admin_headers, db, doc_type):
    client_id = str(_invoice_client(db).id)
    body = _create(client, admin_headers, client_id, doc_type=doc_type)
    assert body["doc_type"] == doc_type
    assert body["number"] == f"{doc_type}-2026-0001"


def test_create_with_product_line_prefills(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    product = _product(db, price=Decimal("100.000"), vat_rate=19, name="Eau 1L")
    body = _create(
        client,
        admin_headers,
        client_id,
        lines=[{"product_id": str(product.id), "quantity": "2"}],
    )
    line = body["lines"][0]
    assert line["product_id"] == str(product.id)
    assert line["description"] == "Eau 1L"
    assert line["unit_price_ht"] == "100.000"
    assert line["tva_rate"] == "19.000"


def test_create_omitted_date_defaults_to_today(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    payload = _payload(client_id)
    payload.pop("document_date")
    resp = client.post("/api/v1/factures", json=payload, headers=admin_headers)
    assert resp.status_code == 201, resp.text
    assert resp.json()["year"] == date.today().year


def test_create_invalid_doc_type_structured_422(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures",
        json=_payload(client_id, doc_type="XYZ"),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_create_unknown_client_structured_404(client, admin_headers):
    resp = client.post(
        "/api/v1/factures",
        json=_payload(str(uuid.uuid4())),
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_create_archived_client_structured_422(client, admin_headers, db):
    from datetime import datetime, timezone

    fiscal = _invoice_client(db, "Archived Fiscal")
    fiscal.archived_at = datetime.now(timezone.utc)
    db.commit()
    resp = client.post(
        "/api/v1/factures",
        json=_payload(str(fiscal.id)),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "INVOICE_CLIENT_ARCHIVED"


def test_create_missing_body_structured_422(client, admin_headers):
    resp = client.post("/api/v1/factures", json={}, headers=admin_headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_create_empty_lines_structured_422(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures",
        json=_payload(client_id, lines=[]),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_create_zero_quantity_structured_422(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures",
        json=_payload(client_id, lines=[{"description": "x", "quantity": "0"}]),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_create_invalid_tva_structured_422(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures",
        json=_payload(
            client_id,
            lines=[
                {
                    "description": "x",
                    "quantity": "1",
                    "unit_price_ht": "10",
                    "tva_rate": "42",
                }
            ],
        ),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


# ---------------------------------------------------------------------------
# Get
# ---------------------------------------------------------------------------


def test_get_detail_includes_calculation(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    created = _create(client, admin_headers, client_id)
    resp = client.get(f"/api/v1/factures/{created['id']}", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["number"] == "FAC-2026-0001"
    assert body["totals"]["net_a_payer"] == "481.00"
    assert body["amount_in_words"]
    assert body["client"]["name"] == "Fiscal Client"
    assert body["lines"][0]["position"] == 0


def test_get_unknown_uuid_structured_404(client, admin_headers):
    resp = client.get(
        "/api/v1/factures/00000000-0000-0000-0000-000000000000",
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_get_invalid_uuid_is_422_not_500(client, admin_headers):
    resp = client.get("/api/v1/factures/not-a-uuid", headers=admin_headers)
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


def test_list_pagination_envelope(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    for _ in range(3):
        _create(client, admin_headers, client_id)
    resp = client.get("/api/v1/factures", params={"page": 1, "page_size": 2}, headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 3
    assert body["page"] == 1
    assert body["page_size"] == 2
    assert body["pages"] == 2
    assert len(body["items"]) == 2


def test_list_summary_rows_omit_lines_and_totals(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    _create(client, admin_headers, client_id)
    items = client.get("/api/v1/factures", headers=admin_headers).json()["items"]
    assert "lines" not in items[0]
    assert "totals" not in items[0]
    assert "amount_in_words" not in items[0]
    assert items[0]["client"]["name"] == "Fiscal Client"


def test_list_order_newest_first(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    _create(client, admin_headers, client_id, document_date="2026-01-05")
    _create(client, admin_headers, client_id, document_date="2026-12-05")
    _create(client, admin_headers, client_id, document_date="2026-06-05")
    items = client.get("/api/v1/factures", headers=admin_headers).json()["items"]
    dates = [item["document_date"] for item in items]
    assert dates == sorted(dates, reverse=True)


def test_list_filters(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    other_id = str(_invoice_client(db, "Other Client").id)
    _create(client, admin_headers, client_id, doc_type="FAC")
    _create(client, admin_headers, client_id, doc_type="DEV")
    _create(client, admin_headers, other_id, doc_type="FAC")
    _create(client, admin_headers, other_id, document_date="2026-01-05")

    by_type = client.get(
        "/api/v1/factures", params={"doc_type": "DEV"}, headers=admin_headers
    ).json()
    assert by_type["total"] == 1

    by_client = client.get(
        "/api/v1/factures", params={"client_id": other_id}, headers=admin_headers
    ).json()
    assert by_client["total"] == 2

    by_year = client.get("/api/v1/factures", params={"year": YEAR}, headers=admin_headers).json()
    assert by_year["total"] == 4

    by_q = client.get("/api/v1/factures", params={"q": "-2026-0001"}, headers=admin_headers).json()
    assert by_q["total"] == 2  # one per doc_type sequence

    by_range = client.get(
        "/api/v1/factures",
        params={"date_from": "2026-06-01", "date_to": "2026-12-31"},
        headers=admin_headers,
    ).json()
    assert by_range["total"] == 3  # the three October documents

    early = client.get(
        "/api/v1/factures", params={"date_to": "2026-03-31"}, headers=admin_headers
    ).json()
    assert early["total"] == 1


def test_list_invalid_doc_type_filter_422(client, admin_headers):
    resp = client.get("/api/v1/factures", params={"doc_type": "NOPE"}, headers=admin_headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_list_inverted_date_range_422(client, admin_headers):
    resp = client.get(
        "/api/v1/factures",
        params={"date_from": "2026-12-01", "date_to": "2026-01-01"},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


def test_update_partial_fields(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    created = _create(client, admin_headers, client_id)
    resp = client.put(
        f"/api/v1/factures/{created['id']}",
        json={"payment_method": "transfer", "notes": "  updated  "},
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["payment_method"] == "transfer"
    assert body["notes"] == "updated"
    assert body["number"] == "FAC-2026-0001"  # never re-allocated
    assert body["totals"]["timbre"] == "0"  # transfer -> no cash duty
    assert body["totals"]["net_a_payer"] == "476.00"
    assert body["client_id"] == client_id  # untouched
    assert len(body["lines"]) == 1  # untouched


def test_update_immutable_identity_ignored(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    created = _create(client, admin_headers, client_id)
    resp = client.put(
        f"/api/v1/factures/{created['id']}",
        json={
            "number": "FAC-1999-9999",
            "doc_type": "BL",
            "year": 1999,
            "document_date": "1999-01-01",
            "notes": "date and number never change",
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["number"] == "FAC-2026-0001"
    assert body["doc_type"] == "FAC"
    assert body["year"] == YEAR
    assert body["document_date"] == DAY
    assert body["notes"] == "date and number never change"


def test_update_explicit_null_client_422(client, admin_headers, db):
    created = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = client.put(
        f"/api/v1/factures/{created['id']}",
        json={"client_id": None},
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_update_explicit_null_lines_422(client, admin_headers, db):
    created = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = client.put(
        f"/api/v1/factures/{created['id']}", json={"lines": None}, headers=admin_headers
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"


def test_update_empty_body_is_noop_200(client, admin_headers, db):
    created = _create(client, admin_headers, str(_invoice_client(db).id))
    resp = client.put(f"/api/v1/factures/{created['id']}", json={}, headers=admin_headers)
    assert resp.status_code == 200, resp.text
    assert resp.json() == created  # byte-for-byte no change


def test_update_unknown_document_404(client, admin_headers):
    resp = client.put(
        "/api/v1/factures/00000000-0000-0000-0000-000000000000",
        json={"notes": "x"},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_update_replaces_lines(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    created = _create(client, admin_headers, client_id)
    resp = client.put(
        f"/api/v1/factures/{created['id']}",
        json={
            "lines": [
                {"description": "A", "quantity": "1", "unit_price_ht": "10", "tva_rate": "0"},
                {"description": "B", "quantity": "2", "unit_price_ht": "20", "tva_rate": "9"},
            ]
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [line["description"] for line in body["lines"]] == ["A", "B"]
    assert body["totals"]["net_a_payer"] == "53.60"  # 10 + 40*1.09


# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------


def test_preview_returns_calculation_and_persists_nothing(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures/preview",
        json=_payload(client_id),
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["number"] == "FAC-2026-0001"  # proposal, not consumed
    assert body["year"] == YEAR
    assert body["totals"]["net_a_payer"] == "481.00"
    assert body["amount_in_words"]
    assert "id" not in body["lines"][0]  # unpersisted line rows
    assert body["client"]["name"] == "Fiscal Client"

    assert db.execute(select(InvoiceDocument)).scalars().all() == []
    assert db.execute(select(InvoiceDocumentCounter)).scalars().all() == []


def test_preview_proposal_becomes_the_next_number(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    payload = _payload(client_id)
    proposed = client.post("/api/v1/factures/preview", json=payload, headers=admin_headers).json()[
        "number"
    ]
    created = _create(client, admin_headers, client_id)
    assert created["number"] == proposed
    assert proposed == "FAC-2026-0001"


def test_preview_invalid_doc_type_422(client, admin_headers, db):
    client_id = str(_invoice_client(db).id)
    resp = client.post(
        "/api/v1/factures/preview",
        json=_payload(client_id, doc_type="XYZ"),
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_ERROR"
    assert db.execute(select(InvoiceDocumentCounter)).scalars().all() == []
