"""Phase 10 tests - Packs / Bundles (CRUD, availability, POS pack sale).

Covers the Phase 10 acceptance criteria from PHASE_0_ROADMAP.md:466-469:
- Packs can be created/edited/deleted
- Stock validation works
- Pack sales deduct component stock

Plus the decision gates recorded in docs/PHASE_10_PACKS_ANALYSIS.md:
GATE 1 (base-product components), GATE 3 (price/sum_of_parts),
GATE 4 (aggregate component stock), GATE 5 (PACK_COMPONENT movements),
GATE 6 (pack summary + uncharged component rows), GATE 7 (history intact),
GATE 8 (saleable = active + not archived), GATE 9 (PMP untouched),
GATE 10 (discounts on the summary line), GATE 11 (no new scopes).
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.catalog import Pack, PackItem, Product
from app.models.inventory import InventoryMovement
from app.models.sale import Sale, SaleLine
from app.services.auth import AuthService


# ----------------------------------------------------------------------
# Fixtures (mirror tests/unit/test_pos_sale.py)
# ----------------------------------------------------------------------


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
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


_seq = {"n": 0}


def _create_product(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Pack Product {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"PP{_seq['n']:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "10.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _pack_payload(client, headers, **overrides) -> dict:
    _seq["n"] += 1
    components = overrides.pop("components", None)
    payload = {
        "name": overrides.pop("name", f"Family Pack {_seq['n']}"),
        "barcode": overrides.pop("barcode", f"PK{_seq['n']:06d}"),
        "price": overrides.pop("price", "500.000"),
        "is_active": overrides.pop("is_active", True),
    }
    payload.update(overrides)
    if components is None:
        raise ValueError("components required")
    payload["components"] = components
    resp = client.post("/api/v1/packs", json=payload, headers=headers)
    return resp


def _post_pack(client, headers, products, **overrides):
    """POST a pack with one component per product; returns the raw Response."""
    quantities = overrides.pop("quantities", None)
    if quantities is None:
        quantities = ["1.000"] * len(products)
    components = [
        {"product_id": p["id"], "quantity": q}
        for p, q in zip(products, quantities)
    ]
    return _pack_payload(client, headers, components=components, **overrides)


def _create_pack(client, headers, products, **overrides) -> dict:
    """Create a pack and return its response body."""
    resp = _post_pack(client, headers, products, **overrides)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _sale_payload(items, **overrides) -> dict:
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": items,
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": "100000.000",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_sale(client, headers, payload: dict):
    return client.post("/api/v1/sales", json=payload, headers=headers)


def _stock(client, headers, product_id: str) -> Decimal:
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return Decimal(resp.json()["quantity"])


def _create_selling_unit(client, headers, product_id: str, **overrides) -> dict:
    """POST /products/{id}/selling-units (Phase 6 model, no pack specifics)."""
    _seq["n"] += 1
    payload = {
        "name": overrides.pop("name", f"Unit {_seq['n']}"),
        "multiplier": overrides.pop("multiplier", "1"),
        "is_base_unit": overrides.pop("is_base_unit", False),
    }
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/selling-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _product_with_units(
    client,
    headers,
    *,
    quantity: str = "100.000",
    cost: str = "120.000",
    price: str = "250.000",
) -> tuple[dict, dict, dict]:
    """Product with Piece x1 (base) + Box x24 selling units."""
    product = _create_product(
        client, headers, quantity=quantity, cost=cost, price=price
    )
    base = _create_selling_unit(
        client, headers, product["id"],
        name="Piece", multiplier="1", is_base_unit=True,
    )
    box = _create_selling_unit(
        client, headers, product["id"],
        name="Box", multiplier="24", is_base_unit=False,
    )
    return product, base, box


# ======================================================================
# A. Pack CRUD
# ======================================================================


class TestPackCrud:
    def test_create_pack_returns_201_with_components(self, client, admin_headers):
        p1 = _create_product(client, admin_headers, name="Rice 1kg", price="50.000")
        p2 = _create_product(client, admin_headers, name="Oil 1L", price="200.000")
        resp = _post_pack(client, admin_headers, [p1, p2], price="300.000")
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["name"].startswith("Family Pack")
        assert body["is_active"] is True
        assert body["is_archived"] is False
        assert body["components_count"] == 2
        assert Decimal(body["price"]) == Decimal("300.000")
        # GATE 3: sum_of_parts is 1*50 + 1*200 = 250 (informational only)
        assert Decimal(body["sum_of_parts"]) == Decimal("250.000")
        assert len(body["components"]) == 2
        assert {c["product_id"] for c in body["components"]} == {
            p1["id"],
            p2["id"],
        }

    def test_create_pack_requires_component_quantity_positive(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            components=[{"product_id": p["id"], "quantity": "0"}],
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_create_pack_rejects_negative_price(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            price="-1.000",
            components=[{"product_id": p["id"], "quantity": "1"}],
        )
        assert resp.status_code == 422

    def test_zero_price_pack_is_allowed(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        resp = _post_pack(client, admin_headers, [p], price="0.000")
        assert resp.status_code == 201, resp.text
        assert Decimal(resp.json()["price"]) == Decimal("0.000")

    def test_duplicate_component_rejected(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {"product_id": p["id"], "quantity": "1"},
                {"product_id": p["id"], "quantity": "2"},
            ],
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "PACK_COMPONENT_DUPLICATE"

    def test_variant_component_rejected_gate1(self, client, admin_headers):
        """GATE 1 - variant-in-pack stays an unresolved Phase 0 decision."""
        p = _create_product(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {"product_id": p["id"], "quantity": "1", "variant_id": str(uuid.uuid4())}
            ],
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_unknown_component_product_404(self, client, admin_headers):
        resp = _pack_payload(
            client,
            admin_headers,
            components=[{"product_id": str(uuid.uuid4()), "quantity": "1"}],
        )
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "NOT_FOUND"

    def test_archived_component_product_rejected(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        assert (
            client.delete(f"/api/v1/products/{p['id']}", headers=admin_headers).status_code
            == 200
        )
        resp = _pack_payload(
            client,
            admin_headers,
            components=[{"product_id": p["id"], "quantity": "1"}],
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "BUSINESS_RULE_ERROR"

    def test_duplicate_pack_barcode_409(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        assert _post_pack(
            client, admin_headers, [p], barcode="DUPPK001"
        ).status_code == 201
        resp = _pack_payload(
            client,
            admin_headers,
            barcode="DUPPK001",
            components=[{"product_id": p["id"], "quantity": "1"}],
        )
        assert resp.status_code == 409

    def test_pack_barcode_may_not_shadow_product_barcode(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, barcode="SHARED123")
        resp = _pack_payload(
            client,
            admin_headers,
            barcode="SHARED123",
            components=[{"product_id": p["id"], "quantity": "1"}],
        )
        assert resp.status_code == 409
        assert "product" in resp.json()["error"]["message"]

    def test_list_envelope_and_filters(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        _create_pack(client, admin_headers, [p], name="Alpha Pack")
        resp = client.get("/api/v1/packs", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert set(body) >= {"items", "total", "page", "page_size", "pages"}
        assert body["total"] == 1
        assert body["page_size"] == 40
        assert body["items"][0]["name"] == "Alpha Pack"

        found = client.get(
            "/api/v1/packs", params={"search": "Alpha"}, headers=admin_headers
        ).json()
        assert found["total"] == 1
        miss = client.get(
            "/api/v1/packs", params={"search": "zzz"}, headers=admin_headers
        ).json()
        assert miss["total"] == 0

    def test_get_unknown_pack_404_details_pack_id(self, client, admin_headers):
        resp = client.get(f"/api/v1/packs/{uuid.uuid4()}", headers=admin_headers)
        assert resp.status_code == 404
        assert resp.json()["error"]["code"] == "NOT_FOUND"
        assert "pack_id" in resp.json()["error"]["details"]

    def test_update_pack_price_and_replace_components(
        self, client, admin_headers
    ):
        p1 = _create_product(client, admin_headers)
        p2 = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p1])

        resp = client.put(
            f"/api/v1/packs/{pack['id']}",
            json={"price": "450.000", "components": [{"product_id": p2["id"], "quantity": "3"}]},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert Decimal(body["price"]) == Decimal("450.000")
        assert body["components_count"] == 1
        assert body["components"][0]["product_id"] == p2["id"]
        assert Decimal(body["components"][0]["quantity"]) == Decimal("3.000")

        # component replacement really swapped the rows
        pack_row = client.get(f"/api/v1/packs/{pack['id']}", headers=admin_headers).json()
        assert [c["product_id"] for c in pack_row["components"]] == [p2["id"]]

    def test_update_partial_keeps_unset_fields(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p], name="Keep Me")
        resp = client.put(
            f"/api/v1/packs/{pack['id']}",
            json={"price": "10.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["name"] == "Keep Me"
        assert resp.json()["components_count"] == 1

    def test_delete_is_soft_archive(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p])
        resp = client.delete(f"/api/v1/packs/{pack['id']}", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        assert resp.json()["is_archived"] is True
        assert resp.json()["is_active"] is False

        # gone from the default list, visible with status=all / archived
        assert client.get("/api/v1/packs", headers=admin_headers).json()["total"] == 0
        archived = client.get(
            "/api/v1/packs", params={"status": "archived"}, headers=admin_headers
        ).json()
        assert archived["total"] == 1
        everything = client.get(
            "/api/v1/packs", params={"status": "all"}, headers=admin_headers
        ).json()
        assert everything["total"] == 1

        # GATE 8: reactivating via PUT clears the archive flag
        resp = client.put(
            f"/api/v1/packs/{pack['id']}", json={"is_active": True}, headers=admin_headers
        )
        assert resp.status_code == 200
        assert resp.json()["is_archived"] is False
        assert client.get("/api/v1/packs", headers=admin_headers).json()["total"] == 1

    def test_audit_rows_written(self, client, admin_headers, db):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p])
        client.put(
            f"/api/v1/packs/{pack['id']}", json={"price": "1.000"}, headers=admin_headers
        )
        client.delete(f"/api/v1/packs/{pack['id']}", headers=admin_headers)
        db.expire_all()
        actions = [
            row.action
            for row in db.scalars(
                select(AuditLog).where(AuditLog.entity_type == "pack")
            ).all()
        ]
        assert actions == ["create", "update", "delete"]


# ======================================================================
# B. RBAC (GATE 11 - no new scopes)
# ======================================================================


class TestPackPermissions:
    def test_cashier_can_read_but_not_write(self, client, admin_headers, cashier_headers):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p])

        assert (
            client.get("/api/v1/packs", headers=cashier_headers).status_code == 200
        )
        assert (
            client.get(
                f"/api/v1/packs/{pack['id']}/availability", headers=cashier_headers
            ).status_code
            == 200
        )

        assert (
            client.post(
                "/api/v1/packs",
                json={
                    "name": "Nope",
                    "price": "1.000",
                    "components": [{"product_id": p["id"], "quantity": "1"}],
                },
                headers=cashier_headers,
            ).status_code
            == 403
        )
        assert (
            client.put(
                f"/api/v1/packs/{pack['id']}",
                json={"price": "2.000"},
                headers=cashier_headers,
            ).status_code
            == 403
        )
        assert (
            client.delete(f"/api/v1/packs/{pack['id']}", headers=cashier_headers).status_code
            == 403
        )

    def test_manager_can_write(self, client, admin_headers, manager_headers):
        p = _create_product(client, admin_headers)
        resp = _post_pack(client, manager_headers, [p])
        assert resp.status_code == 201, resp.text

    def test_unauthenticated_401(self, client):
        assert client.get("/api/v1/packs").status_code == 401


# ======================================================================
# C. Availability (read-only)
# ======================================================================


class TestPackAvailability:
    def test_availability_reports_max_packs(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p], quantities=["3.000"])
        resp = client.get(
            f"/api/v1/packs/{pack['id']}/availability", headers=admin_headers
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["saleable"] is True
        assert Decimal(body["max_pack_quantity"]) == Decimal("3")  # floor(10/3)
        assert Decimal(body["components"][0]["required_per_pack"]) == Decimal("3.000")
        assert Decimal(body["components"][0]["required_quantity"]) == Decimal("3.000")
        assert body["errors"] == []
        # read-only: stock untouched
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

    def test_availability_requested_quantity(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p], quantities=["3.000"])
        body = client.get(
            f"/api/v1/packs/{pack['id']}/availability",
            params={"quantity": "4"},
            headers=admin_headers,
        ).json()
        assert body["saleable"] is False
        assert Decimal(body["components"][0]["required_quantity"]) == Decimal("12.000")
        assert Decimal(body["components"][0]["available_quantity"]) == Decimal("10.000")
        assert any("need 12" in e for e in body["errors"])

    def test_availability_inactive_pack_not_saleable(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p])
        client.put(
            f"/api/v1/packs/{pack['id']}", json={"is_active": False}, headers=admin_headers
        )
        body = client.get(
            f"/api/v1/packs/{pack['id']}/availability", headers=admin_headers
        ).json()
        assert body["saleable"] is False
        assert any("not active" in e for e in body["errors"])

    def test_availability_rejects_non_positive_quantity(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers)
        pack = _create_pack(client, admin_headers, [p])
        resp = client.get(
            f"/api/v1/packs/{pack['id']}/availability",
            params={"quantity": "0"},
            headers=admin_headers,
        )
        assert resp.status_code == 422


# ======================================================================
# D. Pack sale (GATE 6 - summary + uncharged components)
# ======================================================================


class TestPackSale:
    @pytest.fixture()
    def pack_setup(self, client, admin_headers):
        """Two components: 2x Rice (100) + 1x Oil (200), pack price 500."""
        rice = _create_product(
            client, admin_headers, name="Rice", price="100.000", cost="60.000",
            quantity="20.000",
        )
        oil = _create_product(
            client, admin_headers, name="Oil", price="200.000", cost="150.000",
            quantity="20.000",
        )
        pack = _create_pack(
            client,
            admin_headers,
            [rice, oil],
            quantities=["2.000", "1.000"],
            price="500.000",
        )
        return {"rice": rice, "oil": oil, "pack": pack}

    def _pack_item(self, pack, **overrides) -> dict:
        item = {
            "pack_id": pack["id"],
            "quantity": "1.000",
            "unit_price": "500.000",
            "line_discount": "0.000",
        }
        item.update(overrides)
        return item

    def test_pack_sale_persists_summary_plus_components(
        self, client, admin_headers, pack_setup
    ):
        pack = pack_setup["pack"]
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload([self._pack_item(pack)], paid="500.000"),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # header money comes from the pack price only
        assert Decimal(body["subtotal"]) == Decimal("500.000")
        assert Decimal(body["total"]) == Decimal("500.000")

        lines = body["lines"]
        assert len(lines) == 3  # 1 summary + 2 components

        summary = next(ln for ln in lines if ln["product_id"] is None)
        assert summary["pack_id"] == pack["id"]
        assert Decimal(summary["quantity"]) == Decimal("1.000")
        assert Decimal(summary["unit_price"]) == Decimal("500.000")
        assert Decimal(summary["unit_cost"]) == Decimal("0.000")
        assert Decimal(summary["line_total"]) == Decimal("500.000")
        assert summary["product_name"] == pack["name"]
        assert summary["product_unit"] == "pack"

        components = [ln for ln in lines if ln["product_id"] is not None]
        assert len(components) == 2
        for comp in components:
            assert comp["pack_id"] == pack["id"]
            assert Decimal(comp["line_total"]) == Decimal("0.000")
            assert Decimal(comp["line_discount"]) == Decimal("0.000")

        # GATE 6 aggregate integrity
        assert sum(Decimal(ln["line_total"]) for ln in lines) == (
            Decimal(body["subtotal"]) - Decimal(body["discount"])
        )
        # COGS falls out of the component rows (summary unit_cost is 0)
        cogs = sum(
            Decimal(ln["unit_cost"]) * Decimal(ln["quantity"]) for ln in lines
        )
        assert cogs == Decimal("60.000") * 2 + Decimal("150.000") * 1

    def test_component_stock_deducted_by_pack_quantity(
        self, client, admin_headers, pack_setup
    ):
        pack, rice, oil = pack_setup["pack"], pack_setup["rice"], pack_setup["oil"]
        assert _stock(client, admin_headers, rice["id"]) == Decimal("20.000")
        assert _stock(client, admin_headers, oil["id"]) == Decimal("20.000")

        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload([self._pack_item(pack, quantity="3")], paid="1500.000"),
        )
        assert resp.status_code == 201, resp.text

        # 3 packs -> 6 rice + 3 oil
        assert _stock(client, admin_headers, rice["id"]) == Decimal("14.000")
        assert _stock(client, admin_headers, oil["id"]) == Decimal("17.000")

    def test_component_movements_are_pack_component_typed(
        self, client, admin_headers, pack_setup, db
    ):
        pack, rice = pack_setup["pack"], pack_setup["rice"]
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload([self._pack_item(pack)], paid="500.000"),
        )
        assert resp.status_code == 201
        sale_id = uuid.UUID(resp.json()["id"])

        db.expire_all()
        movements = db.scalars(
            select(InventoryMovement).where(
                InventoryMovement.source_document_id == sale_id
            )
        ).all()
        assert len(movements) == 2  # one per component
        assert {m.movement_type for m in movements} == {"pack_component"}
        assert {m.source_document_type for m in movements} == {"sale"}
        rice_move = next(m for m in movements if m.product_id == uuid.UUID(rice["id"]))
        assert Decimal(str(rice_move.quantity_change)) == Decimal("-2.000")
        assert "Pack sale" in rice_move.reason

    def test_sale_never_changes_pmp(
        self, client, admin_headers, pack_setup, db
    ):
        rice = pack_setup["rice"]
        _post_sale(
            client,
            admin_headers,
            _sale_payload([self._pack_item(pack_setup["pack"])], paid="500.000"),
        )
        db.expire_all()
        product = db.get(Product, uuid.UUID(rice["id"]))
        assert Decimal(str(product.avg_cost)) == Decimal("60.000")

    def test_unit_summary_shows_packs_only(
        self, client, admin_headers, pack_setup
    ):
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload([self._pack_item(pack_setup["pack"])], paid="500.000"),
        )
        assert resp.status_code == 201
        # SaleCreateResponse has no unit_summary (Phase 8 contract) — the
        # computed field lives on SaleResponse (history / detail).
        detail = client.get(
            f"/api/v1/sales/{resp.json()['id']}", headers=admin_headers
        ).json()
        assert detail["unit_summary"] == "1 pack"

    def test_pack_line_discount_and_invoice_discount(
        self, client, admin_headers, pack_setup
    ):
        pack = pack_setup["pack"]
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [self._pack_item(pack, line_discount="50.000")],
                invoice_discount="0.000",
                paid="450.000",
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["subtotal"]) == Decimal("500.000")
        assert Decimal(body["discount"]) == Decimal("0.000")
        assert Decimal(body["total"]) == Decimal("450.000")
        summary = next(ln for ln in body["lines"] if ln["product_id"] is None)
        assert Decimal(summary["line_discount"]) == Decimal("50.000")
        assert Decimal(summary["line_total"]) == Decimal("450.000")

    def test_line_discount_cannot_exceed_pack_gross(
        self, client, admin_headers, pack_setup
    ):
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [self._pack_item(pack_setup["pack"], line_discount="5000.000")],
                paid="0.000",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_mixed_cart_pack_and_product(self, client, admin_headers, pack_setup):
        pack, rice = pack_setup["pack"], pack_setup["rice"]
        loose = _create_product(client, admin_headers, price="10.000", quantity="5.000")
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    self._pack_item(pack),
                    {
                        "product_id": loose["id"],
                        "quantity": "2.000",
                        "unit_price": "10.000",
                        "line_discount": "0.000",
                    },
                ],
                paid="520.000",
            ),
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["subtotal"]) == Decimal("520.000")
        assert _stock(client, admin_headers, loose["id"]) == Decimal("3.000")
        assert _stock(client, admin_headers, rice["id"]) == Decimal("18.000")

    def test_pack_price_override_reported(self, client, admin_headers, pack_setup):
        pack = pack_setup["pack"]
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [self._pack_item(pack, unit_price="1.000")], paid="500.000"
            ),
        )
        assert resp.status_code == 201, resp.text
        overrides = resp.json()["price_overrides"]
        assert len(overrides) == 1
        assert overrides[0]["product_id"] is None
        assert overrides[0]["pack_id"] == pack["id"]
        assert Decimal(overrides[0]["applied_unit_price"]) == Decimal("500.000")

    def test_idempotent_replay_of_pack_sale(
        self, client, admin_headers, pack_setup
    ):
        pack = pack_setup["pack"]
        payload = _sale_payload(
            [self._pack_item(pack)], paid="500.000", client_request_id="pack-idem-1"
        )
        first = _post_sale(client, admin_headers, payload)
        second = _post_sale(client, admin_headers, payload)
        assert first.status_code == 201
        assert second.status_code == 201
        assert second.json()["id"] == first.json()["id"]
        assert second.json()["idempotent_replay"] is True
        # stock deducted exactly once
        assert _stock(client, admin_headers, pack_setup["rice"]["id"]) == Decimal(
            "18.000"
        )

    def test_hold_roundtrip_with_pack_line(
        self, client, admin_headers, pack_setup
    ):
        pack = pack_setup["pack"]
        snapshot = {
            "pack_id": pack["id"],
            "product_name": pack["name"],
            "product_unit": "pack",
            "quantity": "2.000",
            "unit_price": "500.000",
            "line_discount": "0.000",
            "available_stock": "10.000",
        }
        created = client.post(
            "/api/v1/pos/holds",
            json={"items": [snapshot], "device_id": "POS-1"},
            headers=admin_headers,
        )
        assert created.status_code == 201, created.text
        hold_id = created.json()["id"]

        restored = client.post(
            f"/api/v1/pos/holds/{hold_id}/restore", headers=admin_headers
        )
        assert restored.status_code == 200, restored.text
        body = restored.json()
        assert body["ok"] is True
        assert body["lines"][0]["product_id"] is None
        assert body["lines"][0]["pack_id"] == pack["id"]
        assert Decimal(body["lines"][0]["available_stock"]) == Decimal("10")

    def test_hold_with_pack_still_does_not_reserve_stock(
        self, client, admin_headers, pack_setup
    ):
        pack, rice = pack_setup["pack"], pack_setup["rice"]
        client.post(
            "/api/v1/pos/holds",
            json={"items": [{"pack_id": pack["id"], "quantity": "1"}]},
            headers=admin_headers,
        )
        assert _stock(client, admin_headers, rice["id"]) == Decimal("20.000")


# ======================================================================
# E. Stock validation / rejections (GATE 4 + GATE 8)
# ======================================================================


class TestPackStockValidation:
    def _pack(self, client, headers, *, quantity, qty_per_pack="3.000", **kw):
        p = _create_product(client, headers, quantity=quantity, price="100.000")
        pack = _create_pack(
            client, headers, [p], quantities=[qty_per_pack], price="250.000", **kw
        )
        return p, pack

    def _item(self, pack, qty="1.000"):
        return {
            "pack_id": pack["id"],
            "quantity": qty,
            "unit_price": "250.000",
            "line_discount": "0.000",
        }

    def test_insufficient_component_stock_rejected_zero_residue(
        self, client, admin_headers, db
    ):
        p, pack = self._pack(client, admin_headers, quantity="5.000")
        before_sale = len(db.scalars(select(Sale)).all())
        before_lines = len(db.scalars(select(SaleLine)).all())
        before_moves = len(db.scalars(select(InventoryMovement)).all())

        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload([self._item(pack, qty="2.000")], paid="500.000"),
        )
        assert resp.status_code == 422, resp.text
        err = resp.json()["error"]
        assert err["code"] == "PACK_STOCK_INSUFFICIENT"
        assert err["details"]["pack_id"] == pack["id"]
        assert err["details"]["shortages"][0]["product_id"] == p["id"]
        # need 2*3 = 6, have 5
        assert Decimal(err["details"]["shortages"][0]["required"]) == Decimal("6.000")
        assert Decimal(err["details"]["shortages"][0]["available"]) == Decimal("5.000")

        assert _stock(client, admin_headers, p["id"]) == Decimal("5.000")
        assert len(db.scalars(select(Sale)).all()) == before_sale
        assert len(db.scalars(select(SaleLine)).all()) == before_lines
        assert len(db.scalars(select(InventoryMovement)).all()) == before_moves

    def test_aggregate_across_two_pack_lines_gate4(
        self, client, admin_headers
    ):
        """Two cart lines of the same pack must aggregate (GATE 4)."""
        p = _create_product(client, admin_headers, quantity="5.000", price="100.000")
        pack = _create_pack(
            client, admin_headers, [p], quantities=["3.000"], price="250.000"
        )
        item = {
            "pack_id": pack["id"],
            "quantity": "1.000",
            "unit_price": "250.000",
            "line_discount": "0.000",
        }
        resp = _post_sale(
            client, admin_headers, _sale_payload([item, dict(item)], paid="500.000")
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "PACK_STOCK_INSUFFICIENT"
        shortages = resp.json()["error"]["details"]["shortages"]
        assert len(shortages) == 1
        assert Decimal(shortages[0]["required"]) == Decimal("3.000")
        assert Decimal(shortages[0]["already_requested"]) == Decimal("3.000")
        assert _stock(client, admin_headers, p["id"]) == Decimal("5.000")

    def test_aggregate_all_shortages_reported_at_once(
        self, client, admin_headers
    ):
        a = _create_product(client, admin_headers, quantity="1.000")
        b = _create_product(client, admin_headers, quantity="1.000")
        pack = _create_pack(
            client, admin_headers, [a, b], quantities=["5.000", "5.000"]
        )
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "pack_id": pack["id"],
                        "quantity": "1",
                        "unit_price": pack["price"],
                        "line_discount": "0",
                    }
                ],
                paid="0",
            ),
        )
        assert resp.status_code == 422
        assert len(resp.json()["error"]["details"]["shortages"]) == 2

    def test_inactive_pack_rejected_gate8(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p])
        client.put(
            f"/api/v1/packs/{pack['id']}", json={"is_active": False}, headers=admin_headers
        )
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "1", "unit_price": "500"}],
                paid="500",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "PACK_INACTIVE"

    def test_archived_pack_rejected_gate8(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p])
        assert (
            client.delete(f"/api/v1/packs/{pack['id']}", headers=admin_headers).status_code
            == 200
        )
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "1", "unit_price": "500"}],
                paid="500",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "PACK_INACTIVE"

    def test_unknown_pack_404(self, client, admin_headers):
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": str(uuid.uuid4()), "quantity": "1", "unit_price": "500"}],
                paid="500",
            ),
        )
        assert resp.status_code == 404

    def test_archived_component_product_makes_pack_unsellable(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p])
        client.delete(f"/api/v1/products/{p['id']}", headers=admin_headers)
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "1", "unit_price": "500"}],
                paid="500",
            ),
        )
        assert resp.status_code == 422
        assert "archived" in resp.json()["error"]["message"]

    def test_allow_negative_stock_component_is_not_blocked(
        self, client, admin_headers
    ):
        p = _create_product(
            client, admin_headers, quantity="1.000", allow_negative_stock=True
        )
        pack = _create_pack(client, admin_headers, [p], quantities=["5.000"])
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "1", "unit_price": "500"}],
                paid="500",
            ),
        )
        assert resp.status_code == 201, resp.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("-4.000")


# ======================================================================
# F. Request contract / validation
# ======================================================================


class TestPackSaleRequestContract:
    @pytest.fixture()
    def pack_and_product(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="10.000")
        pack = _create_pack(client, admin_headers, [p])
        return p, pack

    def test_both_targets_rejected(self, client, admin_headers, pack_and_product):
        p, pack = pack_and_product
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "product_id": p["id"],
                        "pack_id": pack["id"],
                        "quantity": "1",
                        "unit_price": "1",
                    }
                ],
                paid="1",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "VALIDATION_ERROR"

    def test_neither_target_rejected(self, client, admin_headers):
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"quantity": "1", "unit_price": "1"}], paid="1"
            ),
        )
        assert resp.status_code == 422

    def test_variant_on_pack_line_rejected(self, client, admin_headers, pack_and_product):
        _, pack = pack_and_product
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "pack_id": pack["id"],
                        "variant_id": str(uuid.uuid4()),
                        "quantity": "1",
                        "unit_price": "1",
                    }
                ],
                paid="1",
            ),
        )
        assert resp.status_code == 422

    def test_validate_cart_with_pack_line(self, client, admin_headers, pack_and_product):
        _, pack = pack_and_product
        resp = client.post(
            "/api/v1/pos/cart/validate",
            json={
                "items": [
                    {"pack_id": pack["id"], "quantity": "2", "unit_price": "500"}
                ],
                "payment_method": "cash",
                "paid": "1000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["ok"] is True
        assert Decimal(body["subtotal"]) == Decimal("1000.000")
        line = body["lines"][0]
        assert line["product_id"] is None
        assert line["pack_id"] == pack["id"]
        assert Decimal(line["available_stock"]) == Decimal("10")

    def test_validate_cart_reports_pack_shortage(self, client, admin_headers):
        p = _create_product(client, admin_headers, quantity="1.000")
        pack = _create_pack(client, admin_headers, [p], quantities=["4.000"])
        resp = client.post(
            "/api/v1/pos/cart/validate",
            json={
                "items": [{"pack_id": pack["id"], "quantity": "2", "unit_price": "500"}],
                "payment_method": "cash",
                "paid": "1000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is False
        assert body["errors"]
        assert body["lines"][0]["ok"] is False


# ======================================================================
# G. Debt ceiling still applies to pack credit sales (Phase 9 gate)
# ======================================================================


class TestPackCreditSale:
    def test_ceiling_still_enforced_and_leaves_no_residue(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="100.000")
        # 3 base units per pack: 2 packs must consume 6 units.
        pack = _create_pack(
            client, admin_headers, [p], quantities=["3.000"], price="500.000"
        )
        customer = client.post(
            "/api/v1/customers",
            json={"name": "Ceiling", "phone": None, "debt_ceiling": "1000.000"},
            headers=admin_headers,
        )
        assert customer.status_code == 201, customer.text
        cid = customer.json()["id"]

        db.expire_all()
        before_sales = len(db.scalars(select(Sale)).all())

        # 3 packs = 1500 > ceiling 1000
        resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "3", "unit_price": "500"}],
                customer_id=cid,
                payment_method="credit",
                paid="0",
            ),
        )
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "DEBT_CEILING_EXCEEDED"
        assert _stock(client, admin_headers, p["id"]) == Decimal("100.000")
        assert len(db.scalars(select(Sale)).all()) == before_sales

        # inside the ceiling still works
        ok = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "2", "unit_price": "500"}],
                customer_id=cid,
                payment_method="credit",
                paid="0",
            ),
        )
        assert ok.status_code == 201, ok.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("94.000")
        balance = client.get(
            f"/api/v1/customers/{cid}", headers=admin_headers
        ).json()["balance"]
        assert Decimal(balance) == Decimal("1000.000")


# ======================================================================
# H. GATE 7 - editing a pack never rewrites a historical sale
# ======================================================================


class TestPackHistoryIsImmutable:
    def test_editing_pack_components_does_not_change_past_sale(
        self, client, admin_headers
    ):
        old = _create_product(
            client, admin_headers, name="Old Component", price="100.000", cost="40.000",
            quantity="50.000",
        )
        new = _create_product(
            client, admin_headers, name="New Component", price="999.000", cost="900.000",
            quantity="50.000",
        )
        pack = _create_pack(
            client, admin_headers, [old], quantities=["1.000"], price="300.000"
        )

        sold = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "2", "unit_price": "300"}],
                paid="600",
            ),
        )
        assert sold.status_code == 201, sold.text
        sale_id = sold.json()["id"]

        # rename the pack, change price, swap the component
        resp = client.put(
            f"/api/v1/packs/{pack['id']}",
            json={
                "name": "Renamed Pack",
                "price": "9999.000",
                "components": [{"product_id": new["id"], "quantity": "7"}],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text

        detail = client.get(f"/api/v1/sales/{sale_id}", headers=admin_headers).json()
        summary = next(ln for ln in detail["lines"] if ln["product_id"] is None)
        components = [ln for ln in detail["lines"] if ln["product_id"] is not None]
        assert summary["product_name"] == pack["name"]  # snapshot, not renamed
        assert Decimal(summary["unit_price"]) == Decimal("300.000")
        assert Decimal(detail["total"]) == Decimal("600.000")
        assert len(components) == 1
        assert components[0]["product_name"] == "Old Component"
        assert Decimal(components[0]["quantity"]) == Decimal("2.000")

    def test_archived_pack_still_referenced_by_history(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="50.000")
        pack = _create_pack(client, admin_headers, [p], price="123.000")
        sold = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "1", "unit_price": "123"}],
                paid="123",
            ),
        )
        assert sold.status_code == 201
        # RESTRICT FK: archive, never hard delete
        assert (
            client.delete(f"/api/v1/packs/{pack['id']}", headers=admin_headers).status_code
            == 200
        )
        detail = client.get(
            f"/api/v1/sales/{sold.json()['id']}", headers=admin_headers
        ).json()
        summary = next(ln for ln in detail["lines"] if ln["pack_id"] is not None)
        assert summary["pack_id"] == pack["id"]


# ======================================================================
# I. Model-level facts
# ======================================================================


class TestPackModelFacts:
    def test_pack_item_declares_unique_component_constraint(self):
        """pack_items carries the Phase 2 UNIQUE (pack_id, product_id, variant_id).

        PostgreSQL treats NULLs as distinct, so this constraint alone does not
        stop two base-product (variant_id IS NULL) rows; the API-level
        PACK_COMPONENT_DUPLICATE guard in PackService is what rejects those.
        """
        from sqlalchemy import UniqueConstraint

        names = {
            c.name
            for c in PackItem.__table__.constraints
            if isinstance(c, UniqueConstraint)
        }
        assert "uq_pack_item_component" in names

    def test_fractional_component_quantity_allowed(self, client, admin_headers):
        p = _create_product(client, admin_headers, unit="kg", quantity="10.000")
        resp = _post_pack(
            client, admin_headers, [p], quantities=["0.500"], price="500.000"
        )
        assert resp.status_code == 201, resp.text
        assert Decimal(resp.json()["components"][0]["quantity"]) == Decimal("0.500")

        sold = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": resp.json()["id"], "quantity": "3", "unit_price": "500"}],
                paid="1500",
            ),
        )
        assert sold.status_code == 201, sold.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("8.500")


# ======================================================================
# Phase 10 fix round - selling units on components, edit hydration,
# informational profitability estimate
# ======================================================================


class TestPackComponentSellingUnits:
    """Issue 1: a component may name one of the product's EXISTING selling
    units; the quantity is converted to base stock with the Phase 6 rule
    ``base = quantity x multiplier`` and stored as base units (GATE 2)."""

    def test_component_without_unit_is_stored_in_base_units(
        self, client, admin_headers
    ):
        """No selling_unit_id -> quantity already means base units (legacy)."""
        product, _, _ = _product_with_units(client, admin_headers)
        resp = _post_pack(
            client, admin_headers, [product], quantities=["3.000"]
        )
        assert resp.status_code == 201, resp.text

        component = resp.json()["components"][0]
        assert Decimal(component["quantity"]) == Decimal("3.000")
        assert Decimal(component["base_quantity"]) == Decimal("3.000")
        assert component["selling_unit_id"] is None
        assert component["selling_unit_name"] is None
        assert component["selling_unit_multiplier"] is None
        assert Decimal(component["unit_quantity"]) == Decimal("3.000")

    def test_component_with_selling_unit_is_converted_to_base(
        self, client, admin_headers
    ):
        """2 Box x24 -> 48 base pieces stored (not 2)."""
        product, _, box = _product_with_units(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )
        assert resp.status_code == 201, resp.text

        component = resp.json()["components"][0]
        assert Decimal(component["quantity"]) == Decimal("48.000")
        assert Decimal(component["base_quantity"]) == Decimal("48.000")
        assert Decimal(component["unit_quantity"]) == Decimal("2.000")
        assert component["selling_unit_id"] == box["id"]
        assert component["selling_unit_name"] == "Box"
        assert Decimal(component["selling_unit_multiplier"]) == Decimal("24")

    def test_selling_unit_conversion_drives_stock_deduction(
        self, client, admin_headers, db
    ):
        """POS regression: a pack with a Box component deducts BASE stock."""
        product, _, box = _product_with_units(
            client, admin_headers, quantity="100.000"
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )
        assert _stock(client, admin_headers, product["id"]) == Decimal(
            "100.000"
        )

        sold = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [{"pack_id": pack["id"], "quantity": "2", "unit_price": "500"}],
                paid="1000",
            ),
        )
        assert sold.status_code == 201, sold.text
        # 2 packs x 2 Box x 24 = 96 pieces consumed.
        assert _stock(client, admin_headers, product["id"]) == Decimal(
            "4.000"
        )

        # PACK_COMPONENT movements still written, one per component, typed.
        sale_id = uuid.UUID(sold.json()["id"])
        db.expire_all()
        movements = db.scalars(
            select(InventoryMovement).where(
                InventoryMovement.source_document_id == sale_id
            )
        ).all()
        assert len(movements) == 1
        assert {m.movement_type for m in movements} == {"pack_component"}
        assert (
            Decimal(str(movements[0].quantity_change)) == Decimal("-96.000")
        )

    @pytest.mark.parametrize("stock", ["40.000", "48.000", "100.000"])
    def test_availability_uses_converted_base_quantity(
        self, client, admin_headers, stock
    ):
        """Box x24, pack needs 2 -> required 48 base pieces.

        stock 40 -> not saleable; 48 -> saleable; 100 -> saleable.
        """
        product, _, box = _product_with_units(
            client, admin_headers, quantity=stock
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )

        resp = client.get(
            f"/api/v1/packs/{pack['id']}/availability",
            params={"quantity": 1},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        component = body["components"][0]

        assert Decimal(component["required_per_pack"]) == Decimal("48.000")
        assert Decimal(component["required_quantity"]) == Decimal("48.000")
        assert Decimal(component["available_quantity"]) == Decimal(stock)
        assert component["selling_unit_name"] == "Box"
        assert Decimal(component["unit_quantity"]) == Decimal("2.000")
        assert Decimal(component["required_unit_quantity"]) == Decimal("2.000")

        expected_saleable = Decimal(stock) >= Decimal("48.000")
        assert body["saleable"] is expected_saleable
        assert component["ok"] is expected_saleable

    def test_availability_converts_for_requested_pack_quantity(
        self, client, admin_headers
    ):
        """3 packs x 2 Box = 6 Box = 144 base pieces."""
        product, _, box = _product_with_units(
            client, admin_headers, quantity="144.000"
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )
        resp = client.get(
            f"/api/v1/packs/{pack['id']}/availability",
            params={"quantity": 3},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        component = resp.json()["components"][0]
        assert Decimal(component["required_quantity"]) == Decimal("144.000")
        assert Decimal(component["required_unit_quantity"]) == Decimal("6.000")
        assert resp.json()["saleable"] is True

    def test_legacy_pack_without_unit_identity_loads_as_base_unit(
        self, client, admin_headers
    ):
        """A component saved before the fix round keeps its base meaning."""
        product, _, box = _product_with_units(client, admin_headers)
        # No selling_unit_id on the wire -> stored exactly like Phase 10 GA.
        pack = _create_pack_objects(
            client,
            admin_headers,
            [{"product_id": product["id"], "quantity": "5.000"}],
        )
        # The product HAS units now — still nothing to hydrate from.
        assert box["id"]

        resp = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        )
        assert resp.status_code == 200, resp.text
        component = resp.json()["components"][0]
        assert component["selling_unit_id"] is None
        assert component["selling_unit_name"] is None
        assert Decimal(component["quantity"]) == Decimal("5.000")
        assert Decimal(component["unit_quantity"]) == Decimal("5.000")
        assert component["product_name"] == product["name"]

    def test_detail_returns_hydrated_product_names(
        self, client, admin_headers
    ):
        """Issue 3: GET /packs/{id} renders every component row by name."""
        first = _create_product(client, admin_headers, name="Rice")
        second = _create_product(client, admin_headers, name="Lentils")
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {"product_id": first["id"], "quantity": "2.000"},
                {"product_id": second["id"], "quantity": "1.000"},
            ],
        )

        resp = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        )
        assert resp.status_code == 200, resp.text
        components = resp.json()["components"]
        names = {c["product_name"] for c in components}
        assert names == {"Rice", "Lentils"}
        for component in components:
            assert component["product_id"]
            assert component["product_unit"]
            assert "avg_cost" in component
            assert "unit_quantity" in component
            assert "base_quantity" in component
            # Never a bare UUID standing in for a name.
            assert "-" not in component["product_name"]

    def test_detail_returns_selected_unit_after_update(
        self, client, admin_headers
    ):
        """Issue 3: switching a component to Carton round-trips."""
        product, base, box = _product_with_units(client, admin_headers)
        carton = _create_selling_unit(
            client, admin_headers, product["id"],
            name="Carton", multiplier="120",
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )

        resp = client.put(
            f"/api/v1/packs/{pack['id']}",
            json={
                "components": [
                    {
                        "product_id": product["id"],
                        "selling_unit_id": carton["id"],
                        "quantity": "1",
                    }
                ]
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        component = resp.json()["components"][0]
        assert component["selling_unit_id"] == carton["id"]
        assert component["selling_unit_name"] == "Carton"
        assert Decimal(component["selling_unit_multiplier"]) == Decimal("120")
        assert Decimal(component["quantity"]) == Decimal("120.000")
        assert Decimal(component["unit_quantity"]) == Decimal("1.000")
        # Base unit stays available as an option (identity preserved).
        assert base["id"]

        # ...and selecting the base unit explicitly stores multiplier 1.
        resp = client.put(
            f"/api/v1/packs/{pack['id']}",
            json={
                "components": [
                    {
                        "product_id": product["id"],
                        "selling_unit_id": base["id"],
                        "quantity": "7",
                    }
                ]
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        component = resp.json()["components"][0]
        assert component["selling_unit_id"] == base["id"]
        assert Decimal(component["quantity"]) == Decimal("7.000")
        assert Decimal(component["unit_quantity"]) == Decimal("7.000")

    def test_archived_selling_unit_rejected(self, client, admin_headers):
        product, _, box = _product_with_units(client, admin_headers)
        archived = client.delete(
            f"/api/v1/products/{product['id']}/selling-units/{box['id']}",
            headers=admin_headers,
        )
        assert archived.status_code in (200, 204), archived.text

        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "BUSINESS_RULE_ERROR"

    def test_selling_unit_of_another_product_rejected(
        self, client, admin_headers
    ):
        product, _, _ = _product_with_units(client, admin_headers)
        other, _, other_box = _product_with_units(client, admin_headers)

        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {
                    "product_id": product["id"],
                    "selling_unit_id": other_box["id"],
                    "quantity": "2",
                }
            ],
        )
        assert resp.status_code == 422, resp.text
        assert other["id"]

    def test_unknown_selling_unit_is_404(self, client, admin_headers):
        product, _, _ = _product_with_units(client, admin_headers)
        resp = _pack_payload(
            client,
            admin_headers,
            components=[
                {
                    "product_id": product["id"],
                    "selling_unit_id": str(uuid.uuid4()),
                    "quantity": "2",
                }
            ],
        )
        assert resp.status_code == 404, resp.text

    def test_historical_pack_meaning_survives_multiplier_change(
        self, client, admin_headers
    ):
        """Issue 11: editing the catalog must not rewrite an existing pack."""
        product, _, box = _product_with_units(
            client, admin_headers, quantity="1000.000"
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
        )
        assert Decimal(
            client.get(
                f"/api/v1/packs/{pack['id']}", headers=admin_headers
            ).json()["components"][0]["quantity"]
        ) == Decimal("48.000")

        # The catalog now says 1 Box = 12 pieces (was 24).
        changed = client.put(
            f"/api/v1/products/{product['id']}/selling-units/{box['id']}",
            json={"multiplier": "12"},
            headers=admin_headers,
        )
        assert changed.status_code == 200, changed.text

        detail = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        ).json()["components"][0]
        assert Decimal(detail["quantity"]) == Decimal("48.000")
        assert Decimal(detail["unit_quantity"]) == Decimal("2.000")
        assert Decimal(detail["selling_unit_multiplier"]) == Decimal("24")

        availability = client.get(
            f"/api/v1/packs/{pack['id']}/availability",
            params={"quantity": 1},
            headers=admin_headers,
        ).json()
        assert Decimal(
            availability["components"][0]["required_quantity"]
        ) == Decimal("48.000")
        assert availability["saleable"] is True


class TestPackEstimatedProfit:
    """Issue 2: informational profitability preview from the live PMP."""

    def test_estimated_cost_uses_avg_cost(self, client, admin_headers):
        """2 x 120 + 3 x 60 = 420 DA of component cost."""
        a = _create_product(
            client, admin_headers, name="Cost A", cost="120.000",
            price="150.000",
        )
        b = _create_product(
            client, admin_headers, name="Cost B", cost="60.000",
            price="80.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="500.000",
            components=[
                {"product_id": a["id"], "quantity": "2"},
                {"product_id": b["id"], "quantity": "3"},
            ],
        )
        assert resp.status_code == 201, resp.text

        assert Decimal(resp.json()["estimated_cost"]) == Decimal("420.000")
        for component in resp.json()["components"]:
            expected = (
                Decimal("120.000")
                if component["product_id"] == a["id"]
                else Decimal("60.000")
            )
            assert Decimal(component["avg_cost"]) == expected

    def test_estimated_profit_and_margin(self, client, admin_headers):
        a = _create_product(
            client, admin_headers, name="Profit A", cost="120.000",
            price="150.000",
        )
        b = _create_product(
            client, admin_headers, name="Profit B", cost="60.000",
            price="80.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="500.000",
            components=[
                {"product_id": a["id"], "quantity": "2"},
                {"product_id": b["id"], "quantity": "3"},
            ],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["estimated_cost"]) == Decimal("420.000")
        assert Decimal(body["estimated_profit"]) == Decimal("80.000")
        assert Decimal(body["estimated_margin_percent"]) == Decimal("16")

    def test_zero_price_omits_margin_without_dividing_by_zero(
        self, client, admin_headers
    ):
        a = _create_product(
            client, admin_headers, name="Freebie", cost="120.000",
            price="150.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="0",
            components=[{"product_id": a["id"], "quantity": "1"}],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["estimated_cost"]) == Decimal("120.000")
        assert Decimal(body["estimated_profit"]) == Decimal("-120.000")
        assert body["estimated_margin_percent"] is None

    def test_estimate_follows_live_avg_cost_and_ignores_stock(
        self, client, admin_headers, db
    ):
        """Component cost is the CURRENT PMP — recomputed on every read.

        Nothing about the estimate is persisted (no packs.cost column).
        """
        a = _create_product(
            client, admin_headers, name="Live cost", cost="100.000",
            price="150.000",
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [{"product_id": a["id"], "quantity": "2"}],
            price="500.000",
        )
        detail = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        ).json()
        assert Decimal(detail["estimated_cost"]) == Decimal("200.000")

        # A receipt moved the PMP to 150 (Phase 7 writes product.avg_cost).
        product = db.get(Product, uuid.UUID(a["id"]))
        product.avg_cost = 150.0
        db.commit()

        detail = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        ).json()
        assert Decimal(detail["estimated_cost"]) == Decimal("300.000")
        assert Decimal(detail["estimated_profit"]) == Decimal("200.000")
        assert Decimal(detail["estimated_margin_percent"]) == Decimal("40")


class TestPackProfitabilityBugfix:
    """Bugfix: the profitability preview reported a 100% margin.

    The estimate keeps reading the authoritative Phase 7 PMP
    (``products.avg_cost``) - never ``products.cost``, never a selling
    price, never a stock quantity. Every assertion below is the display
    contract only: nothing here feeds POS pricing, stock or checkout.
    """

    def test_estimate_is_420_cost_80_profit_16_percent_margin(
        self, client, admin_headers
    ):
        """A: avg_cost 240 x1 + avg_cost 180 x1, pack price 500."""
        a = _create_product(
            client, admin_headers, name="Bugfix A", cost="240.000",
            price="300.000",
        )
        b = _create_product(
            client, admin_headers, name="Bugfix B", cost="180.000",
            price="260.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="500.000",
            components=[
                {"product_id": a["id"], "quantity": "1"},
                {"product_id": b["id"], "quantity": "1"},
            ],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["estimated_cost"]) == Decimal("420.00")
        assert Decimal(body["estimated_profit"]) == Decimal("80.00")
        assert Decimal(body["estimated_margin_percent"]) == Decimal("16.00")
        for component in body["components"]:
            expected = (
                Decimal("240.000")
                if component["product_id"] == a["id"]
                else Decimal("180.000")
            )
            assert Decimal(component["avg_cost"]) == expected

    def test_estimate_negative_margin_is_not_hidden(
        self, client, admin_headers
    ):
        """B: avg_cost 240 x2 + avg_cost 180 x3, pack price 1000."""
        a = _create_product(
            client, admin_headers, name="Loss A", cost="240.000",
            price="300.000",
        )
        b = _create_product(
            client, admin_headers, name="Loss B", cost="180.000",
            price="260.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="1000.000",
            components=[
                {"product_id": a["id"], "quantity": "2"},
                {"product_id": b["id"], "quantity": "3"},
            ],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["estimated_cost"]) == Decimal("1020.00")
        assert Decimal(body["estimated_profit"]) == Decimal("-20.00")
        assert Decimal(body["estimated_margin_percent"]) == Decimal("-2.00")

    def test_free_pack_keeps_cost_but_omits_margin(
        self, client, admin_headers
    ):
        """C: price 0 must never divide by zero - margin is null."""
        a = _create_product(
            client, admin_headers, name="Free A", cost="240.000",
            price="300.000",
        )
        b = _create_product(
            client, admin_headers, name="Free B", cost="180.000",
            price="260.000",
        )
        resp = _pack_payload(
            client,
            admin_headers,
            price="0",
            components=[
                {"product_id": a["id"], "quantity": "1"},
                {"product_id": b["id"], "quantity": "1"},
            ],
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(body["estimated_cost"]) == Decimal("420.00")
        assert Decimal(body["estimated_profit"]) == Decimal("-420.00")
        assert body["estimated_margin_percent"] is None

    def test_legacy_component_without_unit_costs_base_quantity(
        self, client, admin_headers
    ):
        """D: selling_unit_id null - quantity already means base units."""
        product = _create_product(
            client, admin_headers, name="Legacy Component",
            cost="240.000", price="300.000", quantity="50.000",
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [{"product_id": product["id"], "quantity": "2"}],
            price="500.000",
        )
        component = pack["components"][0]
        assert component["selling_unit_id"] is None
        assert Decimal(component["quantity"]) == Decimal("2.000")
        assert Decimal(pack["estimated_cost"]) == Decimal("480.00")
        assert Decimal(pack["estimated_profit"]) == Decimal("20.00")
        assert Decimal(pack["estimated_margin_percent"]) == Decimal("4.00")

    def test_multiplier_change_never_double_counts_component_cost(
        self, client, admin_headers
    ):
        """E: a catalog edit must not reprice an existing pack."""
        product, _, box = _product_with_units(
            client, admin_headers, quantity="1000.000",
            cost="5.000", price="50.000",
        )
        pack = _create_pack_objects(
            client,
            admin_headers,
            [
                {
                    "product_id": product["id"],
                    "selling_unit_id": box["id"],
                    "quantity": "2",
                }
            ],
            price="500.000",
        )
        assert Decimal(pack["components"][0]["quantity"]) == Decimal("48.000")
        assert Decimal(pack["estimated_cost"]) == Decimal("240.00")
        assert Decimal(pack["estimated_profit"]) == Decimal("260.00")
        assert Decimal(pack["estimated_margin_percent"]) == Decimal("52.00")

        changed = client.put(
            f"/api/v1/products/{product['id']}/selling-units/{box['id']}",
            json={"multiplier": "12"},
            headers=admin_headers,
        )
        assert changed.status_code == 200, changed.text

        detail = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        ).json()
        assert Decimal(detail["components"][0]["quantity"]) == Decimal("48.000")
        assert Decimal(detail["components"][0]["avg_cost"]) == Decimal("5.000")
        # 48 base x 5 - once, never 2 x 48 x 5 and never 96 x 5
        assert Decimal(detail["estimated_cost"]) == Decimal("240.00")
        assert Decimal(detail["estimated_profit"]) == Decimal("260.00")
        assert Decimal(detail["estimated_margin_percent"]) == Decimal("52.00")

    def test_estimate_reads_pmp_and_never_nominal_cost(
        self, client, admin_headers, db
    ):
        """The PMP is authoritative even when it differs from `cost`."""
        product = _create_product(
            client, admin_headers, name="PMP Owner", cost="60.000",
            price="150.000", quantity="10.000",
        )
        assert Decimal(product["avg_cost"]) == Decimal("60.000")

        row = db.get(Product, uuid.UUID(product["id"]))
        row.avg_cost = 150.0
        db.commit()

        pack = _create_pack_objects(
            client,
            admin_headers,
            [{"product_id": product["id"], "quantity": "1"}],
            price="500.000",
        )
        assert Decimal(pack["components"][0]["avg_cost"]) == Decimal("150.000")
        assert Decimal(pack["estimated_cost"]) == Decimal("150.00")
        assert Decimal(pack["estimated_profit"]) == Decimal("350.00")
        assert Decimal(pack["estimated_margin_percent"]) == Decimal("70.00")
        # never product.cost
        assert Decimal(pack["estimated_cost"]) != Decimal("60.00")

    def test_cost_edit_repairs_a_zero_pmp_so_margin_is_not_100_percent(
        self, client, admin_headers
    ):
        """The reported bug, end to end.

        A component with a real cost whose PMP was still 0 made the preview
        read cost 0 -> profit == price -> margin exactly 100%. Saving the
        product (the app form always resends `cost`) now reseeds a PMP that
        still mirrors the nominal cost, and the preview follows.
        """
        product = _create_product(
            client, admin_headers, name="ZeroPMP Component",
            cost="0", price="300.000", quantity="10.000",
        )
        assert Decimal(product["avg_cost"]) == Decimal("0.000")

        pack = _create_pack_objects(
            client,
            admin_headers,
            [{"product_id": product["id"], "quantity": "1"}],
            price="500.000",
        )
        # reproduces the bug before the cost is known
        assert Decimal(pack["estimated_cost"]) == Decimal("0.000")
        assert Decimal(pack["estimated_margin_percent"]) == Decimal("100.00")

        saved = client.put(
            f"/api/v1/products/{product['id']}",
            json={"cost": "240.000"},
            headers=admin_headers,
        )
        assert saved.status_code == 200, saved.text
        assert Decimal(saved.json()["avg_cost"]) == Decimal("240.000")

        detail = client.get(
            f"/api/v1/packs/{pack['id']}", headers=admin_headers
        ).json()
        assert Decimal(detail["estimated_cost"]) == Decimal("240.00")
        assert Decimal(detail["estimated_profit"]) == Decimal("260.00")
        assert Decimal(detail["estimated_margin_percent"]) == Decimal("52.00")
        assert Decimal(detail["estimated_margin_percent"]) != Decimal("100.00")

        # the form preview reads /products/search - same repaired PMP
        search = client.get(
            "/api/v1/products/search",
            params={"q": "ZeroPMP Component"},
            headers=admin_headers,
        ).json()
        assert Decimal(search["items"][0]["avg_cost"]) == Decimal("240.000")


def _create_pack_objects(
    client, headers, components: list[dict], **overrides
) -> dict:
    """POST a pack with explicit component dicts and return the body."""
    resp = _pack_payload(
        client, headers, components=components, **overrides
    )
    assert resp.status_code == 201, resp.text
    return resp.json()
