"""Phase 8 tests — ``/api/v1/invoice-clients`` REST layer.

Same TestClient harness as ``test_facturation_documents_api``: one
shared StaticPool SQLite engine, seeded roles + admin + role-less
guest, real login for bearer tokens, ``get_db`` overridden per request.

The router is a thin HTTP layer over the existing Phase 2
``InvoiceClientService`` — these tests pin the WIRE contract only
(service-level validation/audit behaviour is already covered by
``test_facturation.py``):

- RBAC: 401 without a token on every route; a role-less guest and a
  Cashier are 403 on every route with the ``required_permission``
  envelope; Admin and Manager are allowed subject to normal validation.
- Create: 201 + full body (embedded client-ref shape), name trimming,
  blank / missing / over-length name → structured 422, blank optional
  fields become NULL.
- List: pagination envelope, deterministic name ordering, ``q``
  substring on name AND phone, archived rows hidden unless
  ``include_archived``.
- Get: 200 detail, structured 404, archived rows still retrievable.
- Update: partial PUT (absent fields untouched), explicit null clears
  an optional field, explicit null name → 422, empty body is a no-op.
- Archive: DELETE-as-soft-archive (suppliers convention), idempotent,
  archived client refused for NEW documents by ``POST /factures``
  (422 ``INVOICE_CLIENT_ARCHIVED``) while its historical documents stay
  listable and valid.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.facturation import InvoiceClient, InvoiceDocument
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


def _create(client, headers, **payload) -> dict:
    body = {"name": "SARL Demo"}
    body.update(payload)
    resp = client.post("/api/v1/invoice-clients", json=body, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# Auth / RBAC
# ---------------------------------------------------------------------------

UNAUTH_CASES = [
    ("get", "/api/v1/invoice-clients"),
    ("post", "/api/v1/invoice-clients"),
    ("get", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000"),
    ("put", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000"),
    ("delete", "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000"),
]


@pytest.mark.parametrize("method,path", UNAUTH_CASES)
def test_every_route_requires_authentication(client, method, path):
    kwargs = {"json": {}} if method in ("post", "put") else {}
    resp = getattr(client, method)(path, **kwargs)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


@pytest.mark.parametrize(
    "fixture_name", ["cashier_headers", "guest_headers"]
)
def test_denied_roles_get_403_envelope(
    client, request, fixture_name, db
):
    """Cashier and role-less guest are 403 on every invoice-client route."""
    headers = request.getfixturevalue(fixture_name)
    assert (
        client.get("/api/v1/invoice-clients", headers=headers).status_code
        == 403
    )
    create = client.post(
        "/api/v1/invoice-clients", json={"name": "Denied"}, headers=headers
    )
    assert create.status_code == 403
    assert (
        create.json()["error"]["details"]["required_permission"]
        == "facturation_manage"
    )
    assert (
        client.get(
            "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000",
            headers=headers,
        ).status_code
        == 403
    )
    assert (
        client.put(
            "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000",
            json={"name": "Denied"},
            headers=headers,
        ).status_code
        == 403
    )
    assert (
        client.delete(
            "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000",
            headers=headers,
        ).status_code
        == 403
    )


def test_role_less_guest_is_denied_invoice_clients(client, guest_headers):
    """Facturation scopes are admin+manager only — guest can never create."""
    resp = client.post(
        "/api/v1/invoice-clients",
        json={"name": "Guest Created"},
        headers=guest_headers,
    )
    assert resp.status_code == 403
    assert (
        resp.json()["error"]["details"]["required_permission"]
        == "facturation_manage"
    )


def test_manager_can_use_invoice_clients(client, manager_headers):
    """Manager holds both facturation scopes (seeded) — allowed end to end."""
    body = _create(client, manager_headers, name="Manager Client")
    assert body["name"] == "Manager Client"


def test_cashier_is_denied_invoice_clients(client, cashier_headers):
    resp = client.post(
        "/api/v1/invoice-clients",
        json={"name": "Cashier Client"},
        headers=cashier_headers,
    )
    assert resp.status_code == 403
    assert (
        resp.json()["error"]["details"]["required_permission"]
        == "facturation_manage"
    )


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------


def test_create_returns_201_with_full_body(client, admin_headers, db):
    body = _create(
        client,
        admin_headers,
        name="SARL Alpha",
        address="12 Rue Didouche Mourad",
        wilaya="Alger",
        phone="0550123456",
        nif="0002213400067",
        rc="16/00-1234567 B 24",
        ai="16-00-1234567 B 24",
        nis="160012345678901",
    )
    assert uuid.UUID(body["id"])
    assert body["name"] == "SARL Alpha"
    assert body["address"] == "12 Rue Didouche Mourad"
    assert body["wilaya"] == "Alger"
    assert body["phone"] == "0550123456"
    assert body["nif"] == "0002213400067"
    assert body["rc"] == "16/00-1234567 B 24"
    assert body["ai"] == "16-00-1234567 B 24"
    assert body["nis"] == "160012345678901"
    assert body["is_archived"] is False
    assert body["created_at"] is not None

    stored = db.get(InvoiceClient, uuid.UUID(body["id"]))
    assert stored is not None
    assert stored.name == "SARL Alpha"


def test_create_name_only_defaults_optional_null(client, admin_headers):
    body = _create(client, admin_headers)
    assert body["name"] == "SARL Demo"
    assert body["address"] is None
    assert body["wilaya"] is None
    assert body["phone"] is None
    assert body["nif"] is None
    assert body["rc"] is None
    assert body["ai"] is None
    assert body["nis"] is None


def test_create_trims_name_and_optional_fields(client, admin_headers):
    body = _create(client, admin_headers, name="  Trimmed  ", phone=" 0550 111 ", nif=" ")
    assert body["name"] == "Trimmed"
    assert body["phone"] == "0550 111"
    assert body["nif"] is None  # blank becomes NULL


def test_create_blank_name_structured_422(client, admin_headers):
    resp = client.post(
        "/api/v1/invoice-clients", json={"name": "   "}, headers=admin_headers
    )
    assert resp.status_code == 422


def test_create_missing_name_structured_422(client, admin_headers):
    resp = client.post("/api/v1/invoice-clients", json={}, headers=admin_headers)
    assert resp.status_code == 422


def test_create_over_length_name_structured_422(client, admin_headers):
    resp = client.post(
        "/api/v1/invoice-clients",
        json={"name": "x" * 201},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_create_extra_unknown_keys_are_ignored(client, admin_headers):
    """Pydantic default: unknown keys never reach the service."""
    body = _create(client, admin_headers, is_archived=True, customer_id="nope")
    assert body["is_archived"] is False


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------


def test_list_envelope_and_deterministic_name_order(client, admin_headers):
    _create(client, admin_headers, name="Charlie")
    _create(client, admin_headers, name="Alpha")
    _create(client, admin_headers, name="Bravo")
    resp = client.get("/api/v1/invoice-clients", headers=admin_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 3
    assert body["page"] == 1
    assert body["page_size"] == 20
    assert body["pages"] == 1
    assert [i["name"] for i in body["items"]] == ["Alpha", "Bravo", "Charlie"]


def test_list_q_matches_name_and_phone(client, admin_headers):
    _create(client, admin_headers, name="SARL Delta", phone="0550000001")
    _create(client, admin_headers, name="EURL Sigma", phone="0770999999")
    resp = client.get(
        "/api/v1/invoice-clients", params={"q": "delta"}, headers=admin_headers
    )
    assert [i["name"] for i in resp.json()["items"]] == ["SARL Delta"]
    resp = client.get(
        "/api/v1/invoice-clients", params={"q": "07709"}, headers=admin_headers
    )
    assert [i["name"] for i in resp.json()["items"]] == ["EURL Sigma"]


def test_list_pagination(client, admin_headers):
    for n in range(1, 4):
        _create(client, admin_headers, name=f"Client {n:02d}")
    resp = client.get(
        "/api/v1/invoice-clients",
        params={"page": 2, "page_size": 2},
        headers=admin_headers,
    )
    body = resp.json()
    assert body["total"] == 3
    assert body["pages"] == 2
    assert [i["name"] for i in body["items"]] == ["Client 03"]


def test_list_hides_archived_unless_requested(client, admin_headers):
    _create(client, admin_headers, name="Active Co")
    archived = _create(client, admin_headers, name="Old Co")
    resp = client.delete(
        f"/api/v1/invoice-clients/{archived['id']}", headers=admin_headers
    )
    assert resp.status_code == 200

    resp = client.get("/api/v1/invoice-clients", headers=admin_headers)
    assert [i["name"] for i in resp.json()["items"]] == ["Active Co"]

    resp = client.get(
        "/api/v1/invoice-clients",
        params={"include_archived": True},
        headers=admin_headers,
    )
    names = [i["name"] for i in resp.json()["items"]]
    assert names == ["Active Co", "Old Co"]


# ---------------------------------------------------------------------------
# Get
# ---------------------------------------------------------------------------


def test_get_detail_200(client, admin_headers):
    created = _create(client, admin_headers, name="Detail Co", nif="111")
    resp = client.get(
        f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Detail Co"
    assert resp.json()["nif"] == "111"


def test_get_unknown_id_structured_404(client, admin_headers):
    resp = client.get(
        "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000",
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


def test_get_archived_client_still_retrievable(client, admin_headers):
    created = _create(client, admin_headers, name="Archived Co")
    client.delete(f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers)
    resp = client.get(
        f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True


def test_get_invalid_uuid_is_422_not_500(client, admin_headers):
    resp = client.get("/api/v1/invoice-clients/not-a-uuid", headers=admin_headers)
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------


def test_update_partial_only_supplied_fields_change(client, admin_headers, db):
    created = _create(
        client, admin_headers, name="Partial Co", phone="0550111222", nif="42"
    )
    resp = client.put(
        f"/api/v1/invoice-clients/{created['id']}",
        json={"name": "Renamed Co"},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["name"] == "Renamed Co"
    assert body["phone"] == "0550111222"  # untouched
    assert body["nif"] == "42"  # untouched

    stored = db.get(InvoiceClient, uuid.UUID(created["id"]))
    assert stored.name == "Renamed Co"
    assert stored.phone == "0550111222"


def test_update_explicit_null_clears_optional_field(client, admin_headers):
    created = _create(client, admin_headers, name="Clear Co", nif="99")
    resp = client.put(
        f"/api/v1/invoice-clients/{created['id']}",
        json={"nif": None},
        headers=admin_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["nif"] is None


def test_update_explicit_null_name_structured_422(client, admin_headers):
    created = _create(client, admin_headers, name="Null Name")
    resp = client.put(
        f"/api/v1/invoice-clients/{created['id']}",
        json={"name": None},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_update_blank_name_structured_422(client, admin_headers):
    created = _create(client, admin_headers, name="Blank Name")
    resp = client.put(
        f"/api/v1/invoice-clients/{created['id']}",
        json={"name": "  "},
        headers=admin_headers,
    )
    assert resp.status_code == 422


def test_update_empty_body_is_noop(client, admin_headers, db):
    created = _create(client, admin_headers, name="Noop Co", phone="0550")
    resp = client.put(
        f"/api/v1/invoice-clients/{created['id']}", json={}, headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Noop Co"
    assert resp.json()["phone"] == "0550"


def test_update_unknown_id_structured_404(client, admin_headers):
    resp = client.put(
        "/api/v1/invoice-clients/00000000-0000-0000-0000-000000000000",
        json={"name": "Ghost"},
        headers=admin_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


# ---------------------------------------------------------------------------
# Archive (DELETE-as-archive) + facturation regressions
# ---------------------------------------------------------------------------


def test_delete_soft_archives_idempotent(client, admin_headers, db):
    created = _create(client, admin_headers, name="Archive Me")
    resp = client.delete(
        f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True

    # Idempotent second archive — no error, still archived.
    resp = client.delete(
        f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers
    )
    assert resp.status_code == 200
    assert resp.json()["is_archived"] is True

    stored = db.get(InvoiceClient, uuid.UUID(created["id"]))
    assert stored is not None  # soft archive — the row never disappears
    assert stored.archived_at is not None


def test_archived_client_refused_for_new_documents(client, admin_headers, db):
    """Cross-domain regression: factures create honours the archive flag."""
    created = _create(client, admin_headers, name="No New Docs")
    client.delete(f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers)

    resp = client.post(
        "/api/v1/factures",
        json={
            "doc_type": "FAC",
            "client_id": created["id"],
            "lines": [
                {
                    "description": "Prestation",
                    "quantity": "1",
                    "unit_price_ht": "100",
                    "tva_rate": "19",
                }
            ],
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "INVOICE_CLIENT_ARCHIVED"


def test_historical_documents_survive_client_archive(client, admin_headers, db):
    """Archiving a client never hides or invalidates its documents."""
    created = _create(client, admin_headers, name="Has History")
    doc = client.post(
        "/api/v1/factures",
        json={
            "doc_type": "FAC",
            "client_id": created["id"],
            "lines": [
                {
                    "description": "Prestation",
                    "quantity": "2",
                    "unit_price_ht": "50",
                    "tva_rate": "9",
                }
            ],
        },
        headers=admin_headers,
    )
    assert doc.status_code == 201, doc.text
    doc_id = doc.json()["id"]

    client.delete(f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers)

    # Document detail stays valid and keeps its embedded client reference.
    resp = client.get(f"/api/v1/factures/{doc_id}", headers=admin_headers)
    assert resp.status_code == 200
    assert resp.json()["client"]["name"] == "Has History"
    assert resp.json()["client"]["is_archived"] is True
    assert resp.json()["totals"]["net_a_payer"]

    # And the client row is still in the document list (never hidden).
    resp = client.get("/api/v1/factures", headers=admin_headers)
    assert resp.json()["total"] == 1

    stored = db.get(InvoiceDocument, uuid.UUID(doc_id))
    assert stored is not None
    assert stored.client_id == uuid.UUID(created["id"])


def test_archived_client_can_still_be_referenced_by_uid(client, admin_headers, db):
    """Preview also honours the archive flag (same create validation)."""
    created = _create(client, admin_headers, name="Preview Refused")
    client.delete(f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers)
    resp = client.post(
        "/api/v1/factures/preview",
        json={
            "doc_type": "FAC",
            "client_id": created["id"],
            "lines": [
                {
                    "description": "Prestation",
                    "quantity": "1",
                    "unit_price_ht": "10",
                    "tva_rate": "0",
                }
            ],
        },
        headers=admin_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "INVOICE_CLIENT_ARCHIVED"


def test_client_ref_shape_matches_document_payload(client, admin_headers, db):
    """The standalone response IS the shape embedded in document payloads."""
    created = _create(client, admin_headers, name="Shape Co", nif="777")
    doc = client.post(
        "/api/v1/factures",
        json={
            "doc_type": "BC",
            "client_id": created["id"],
            "lines": [
                {
                    "description": "Service",
                    "quantity": "1",
                    "unit_price_ht": "1000",
                    "tva_rate": "19",
                }
            ],
        },
        headers=admin_headers,
    )
    assert doc.status_code == 201, doc.text
    embedded = doc.json()["client"]
    standalone = client.get(
        f"/api/v1/invoice-clients/{created['id']}", headers=admin_headers
    ).json()
    for key in (
        "id",
        "name",
        "address",
        "wilaya",
        "phone",
        "nif",
        "rc",
        "ai",
        "nis",
        "is_archived",
    ):
        assert embedded[key] == standalone[key]


def test_decimal_free_domain_no_money_fields(client, admin_headers):
    """Invoice clients carry no money — nothing serializes as Decimal."""
    body = _create(client, admin_headers, name="No Money")
    for value in body.values():
        assert not isinstance(value, float)
