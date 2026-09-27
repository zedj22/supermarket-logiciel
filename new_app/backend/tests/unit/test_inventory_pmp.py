"""Phase 7 tests — inventory, stock adjustments, PMP (WAC), valuation.

Covers:
- PMP acceptance examples A/B (authoritative)
- Packaging + PMP (package receive → base cost → weighted average)
- Sales/decreases never change PMP
- Variant stock adjustments (variant qty only, product qty untouched)
- Inventory list valuation + movement journal
- Permissions (cashier denied inventory_adjust)
- Authentication required (401)
- ProductUpdateRequest no longer accepts quantity
- Product create seeds ADJUSTMENT movement + avg_cost
- Structured error contract
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
from app.domain.valuation import (
    ValuationError,
    base_unit_cost_from_package,
    inventory_value,
    weighted_average_cost,
)
from app.main import app
from app.models.catalog import Product, ProductVariant
from app.models.inventory import InventoryMovement
from app.schemas.catalog import ProductUpdateRequest
from app.services.auth import AuthService
from app.services.inventory import InventoryService


# ── Domain-level PMP tests (pure Decimal, no DB) ───────────────────────


class TestPMPFormula:
    """Authoritative weighted-average examples."""

    def test_example_a_receive_costs(self):
        # 1×100 + 3×200 → qty 4, value 700, PMP 175
        avg = weighted_average_cost(
            Decimal("1"), Decimal("100"), Decimal("3"), Decimal("200")
        )
        assert avg == Decimal("175")

    def test_example_b_batch_receive(self):
        # 10×1000 + 10×1400 → PMP 1200
        avg1 = weighted_average_cost(
            Decimal("0"), Decimal("0"), Decimal("10"), Decimal("1000")
        )
        assert avg1 == Decimal("1000")
        avg2 = weighted_average_cost(
            Decimal("10"), avg1, Decimal("10"), Decimal("1400")
        )
        assert avg2 == Decimal("1200")

    def test_receive_into_zero_stock_seeds_cost(self):
        avg = weighted_average_cost(
            Decimal("0"), Decimal("0"), Decimal("5"), Decimal("50")
        )
        assert avg == Decimal("50")

    def test_negative_unit_cost_rejected(self):
        with pytest.raises(ValuationError):
            weighted_average_cost(
                Decimal("1"), Decimal("10"), Decimal("1"), Decimal("-1")
            )

    def test_zero_receipt_qty_rejected(self):
        with pytest.raises(ValuationError):
            weighted_average_cost(
                Decimal("1"), Decimal("10"), Decimal("0"), Decimal("5")
            )

    def test_inventory_value(self):
        assert inventory_value(Decimal("4"), Decimal("175")) == Decimal("700.000")

    def test_package_base_unit_cost(self):
        # 10 Box ×24 @200 DA/package → base unit cost = 200/24
        base = base_unit_cost_from_package(Decimal("200"), Decimal("24"))
        assert base == Decimal("200") / Decimal("24")


# ── Fixtures ───────────────────────────────────────────────────────────


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


def _create_product(client, headers, **overrides) -> dict:
    payload = {
        "name": "PMP Product",
        "barcode": "PMP000001",
        "price": "150.000",
        "cost": "100.000",
        "quantity": "1.000",
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _adjust(client, headers, **overrides) -> dict:
    payload = {
        "operation": "increase",
        "quantity": "1.000",
        "reason": "test adjustment",
    }
    payload.update(overrides)
    resp = client.post(
        "/api/v1/inventory/adjust", json=payload, headers=headers
    )
    return {"status": resp.status_code, "body": resp.json()}


# ── Product create → seed movement + avg_cost ──────────────────────────


class TestProductCreateSeedsStock:
    def test_create_with_quantity_seeds_adjustment_movement(
        self, client, admin_headers, db
    ):
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="100.000"
        )
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(product["id"])
            )
        ).scalars().all()
        assert len(movements) == 1
        m = movements[0]
        assert m.movement_type == "adjustment"
        assert float(m.quantity_change) == 10.0
        assert float(m.quantity_before) == 0.0
        assert float(m.quantity_after) == 10.0
        # avg_cost seeded from nominal cost
        assert float(product["avg_cost"]) == 100.0

    def test_create_without_quantity_no_movement(self, client, admin_headers, db):
        product = _create_product(
            client, admin_headers, quantity="0.000", barcode="PMP000002"
        )
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(product["id"])
            )
        ).scalars().all()
        assert len(movements) == 0


# ── PMP stays in sync with the nominal cost until receipts own it ──────


class TestPMPFollowsNominalCost:
    """Bugfix: a `cost` edit must not leave a zero/stale PMP behind.

    The pack profitability preview reads `products.avg_cost` only. While
    the average still mirrors the nominal cost no receipt has priced this
    stock, so saving a new `cost` reseeds it - the same rule `create`
    applies. Once a receipt with an explicit unit cost owns the average, a
    cost edit never rewrites it.
    """

    def test_cost_edit_reseeds_pmp_while_it_mirrors_nominal_cost(
        self, client, admin_headers
    ):
        product = _create_product(
            client, admin_headers, barcode="PMPSYNC001",
            quantity="10.000", cost="60.000",
        )
        assert Decimal(product["avg_cost"]) == Decimal("60.000")

        resp = client.put(
            f"/api/v1/products/{product['id']}",
            json={"cost": "240.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert Decimal(resp.json()["cost"]) == Decimal("240.000")
        assert Decimal(resp.json()["avg_cost"]) == Decimal("240.000")

    def test_cost_filled_in_after_create_seeds_the_pmp(
        self, client, admin_headers
    ):
        product = _create_product(
            client, admin_headers, barcode="PMPSYNC002",
            quantity="0.000", cost="0",
        )
        assert Decimal(product["avg_cost"]) == Decimal("0.000")

        resp = client.put(
            f"/api/v1/products/{product['id']}",
            json={"cost": "240.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert Decimal(resp.json()["avg_cost"]) == Decimal("240.000")

    def test_cost_edit_never_rewrites_a_receipt_owned_pmp(
        self, client, admin_headers
    ):
        product = _create_product(
            client, admin_headers, barcode="PMPSYNC003",
            quantity="1.000", cost="100.000",
        )
        # 1 x 100 + 3 x 200 -> PMP 175 (acceptance example A)
        result = _adjust(
            client,
            admin_headers,
            product_id=product["id"],
            quantity="3.000",
            unit_cost="200.000",
        )
        assert result["status"] == 200, result["body"]
        assert Decimal(result["body"]["avg_cost"]) == Decimal("175.000")

        resp = client.put(
            f"/api/v1/products/{product['id']}",
            json={"cost": "50.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert Decimal(resp.json()["cost"]) == Decimal("50.000")
        assert Decimal(resp.json()["avg_cost"]) == Decimal("175.000")


# ── ProductUpdateRequest no longer accepts quantity ────────────────────


class TestProductUpdateRejectsQuantity:
    def test_quantity_field_removed_from_schema(self):
        req = ProductUpdateRequest(name="X")
        assert "quantity" not in req.model_fields

    def test_api_ignores_quantity_field(self, client, admin_headers):
        product = _create_product(client, admin_headers, barcode="PMP000003")
        resp = client.put(
            f"/api/v1/products/{product['id']}",
            json={"name": "Renamed", "quantity": "999.000"},
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        # quantity unchanged (field stripped by Pydantic)
        assert float(resp.json()["quantity"]) == float(product["quantity"])
        assert resp.json()["name"] == "Renamed"


# ── Inventory adjust + PMP via API ─────────────────────────────────────


class TestInventoryAdjustPMP:
    def test_increase_with_unit_cost_updates_pmp(self, client, admin_headers):
        # Start: qty 1 @ cost/avg 100 (seeded)
        product = _create_product(
            client, admin_headers, quantity="1.000", cost="100.000",
            barcode="PMP000010",
        )
        pid = product["id"]
        # Receive 3 @200 → PMP = (1*100 + 3*200)/4 = 175
        result = _adjust(
            client, admin_headers,
            product_id=pid,
            operation="increase",
            quantity="3.000",
            unit_cost="200.000",
            reason="purchase receipt",
        )
        assert result["status"] == 200, result["body"]
        detail = result["body"]
        assert float(detail["quantity"]) == 4.0
        assert float(detail["avg_cost"]) == 175.0
        assert float(detail["stock_value"]) == 700.0

    def test_decrease_does_not_change_pmp(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="1200.000",
            barcode="PMP000011",
        )
        pid = product["id"]
        result = _adjust(
            client, admin_headers,
            product_id=pid,
            operation="decrease",
            quantity="5.000",
            reason="sale",
        )
        assert result["status"] == 200, result["body"]
        detail = result["body"]
        assert float(detail["quantity"]) == 5.0
        assert float(detail["avg_cost"]) == 1200.0  # unchanged

    def test_increase_without_unit_cost_keeps_pmp(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="50.000",
            barcode="PMP000012",
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="5.000",
            reason="found stock",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["avg_cost"]) == 50.0
        assert float(result["body"]["quantity"]) == 15.0

    def test_set_operation_absolute(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="20.000",
            barcode="PMP000013",
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="set",
            quantity="7.000",
            reason="stocktake",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["quantity"]) == 7.0

    def test_decrease_below_zero_rejected(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="2.000", barcode="PMP000014"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="decrease",
            quantity="5.000",
            reason="too much",
        )
        assert result["status"] == 422, result["body"]
        assert result["body"]["error"]["code"] == "BUSINESS_RULE_ERROR"

    def test_movement_journal_written(self, client, admin_headers, db):
        product = _create_product(
            client, admin_headers, quantity="1.000", cost="100.000",
            barcode="PMP000015",
        )
        _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="3.000",
            unit_cost="200.000",
            reason="receipt",
        )
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(product["id"])
            )
        ).scalars().all()
        # 1 seed + 1 adjust
        assert len(movements) == 2
        adj = [m for m in movements if m.movement_type == "adjustment"]
        assert len(adj) == 2
        # Adjust movement carries unit_cost + avg_cost_after (seed also has unit_cost=100)
        adjust_mv = next(
            m for m in adj if m.unit_cost is not None and float(m.unit_cost) == 200.0
        )
        assert float(adjust_mv.avg_cost_after) == 175.0
        assert float(adjust_mv.quantity_change) == 3.0
        assert float(adjust_mv.quantity_after) == 4.0


# ── Variant adjustments ────────────────────────────────────────────────


class TestVariantAdjustments:
    def _create_with_variant(self, client, headers) -> tuple[str, str]:
        product = _create_product(
            client, headers, quantity="0.000", barcode="PMP000020"
        )
        resp = client.post(
            f"/api/v1/products/{product['id']}/variants",
            json={"name": "Red", "quantity": "5.000"},
            headers=headers,
        )
        assert resp.status_code == 201, resp.text
        return product["id"], resp.json()["id"]

    def test_variant_increase_changes_only_variant_qty(
        self, client, admin_headers, db
    ):
        pid, vid = self._create_with_variant(client, admin_headers)
        result = _adjust(
            client, admin_headers,
            product_id=pid,
            variant_id=vid,
            operation="increase",
            quantity="3.000",
            reason="variant restock",
        )
        assert result["status"] == 200, result["body"]
        detail = result["body"]
        # Product qty untouched
        assert float(detail["quantity"]) == 0.0
        # Variant qty updated
        variant_row = next(
            v for v in detail["variants"] if v["id"] == vid
        )
        assert float(variant_row["quantity"]) == 8.0

    def test_variant_movement_has_variant_id(self, client, admin_headers, db):
        pid, vid = self._create_with_variant(client, admin_headers)
        _adjust(
            client, admin_headers,
            product_id=pid,
            variant_id=vid,
            operation="increase",
            quantity="1.000",
            reason="vr",
        )
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid),
                InventoryMovement.variant_id == uuid.UUID(vid),
            )
        ).scalars().all()
        assert len(movements) >= 1

    def test_variant_decrease_below_zero_rejected(
        self, client, admin_headers
    ):
        pid, vid = self._create_with_variant(client, admin_headers)
        result = _adjust(
            client, admin_headers,
            product_id=pid,
            variant_id=vid,
            operation="decrease",
            quantity="99.000",
            reason="too much",
        )
        assert result["status"] == 422, result["body"]


# ── Inventory list / movements / detail endpoints ──────────────────────


class TestInventoryEndpoints:
    def test_list_inventory(self, client, admin_headers):
        _create_product(client, admin_headers, barcode="PMP000030")
        resp = client.get("/api/v1/inventory", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["total"] >= 1
        assert "total_stock_value" in body
        assert len(body["items"]) >= 1
        item = body["items"][0]
        for key in (
            "product_id", "name", "quantity", "avg_cost",
            "stock_value", "cost", "price",
        ):
            assert key in item

    def test_list_movements_global(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="5.000", barcode="PMP000031"
        )
        resp = client.get("/api/v1/inventory/movements", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["total"] >= 1

    def test_list_movements_for_product(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="5.000", barcode="PMP000032"
        )
        resp = client.get(
            f"/api/v1/inventory/movements/{product['id']}",
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        assert resp.json()["total"] >= 1

    def test_product_detail(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="100.000",
            barcode="PMP000033",
        )
        resp = client.get(
            f"/api/v1/inventory/{product['id']}", headers=admin_headers
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert float(body["quantity"]) == 10.0
        assert float(body["avg_cost"]) == 100.0
        assert float(body["stock_value"]) == 1000.0
        assert "packaging" in body
        assert "variants" in body
        assert "purchase_units" in body
        assert "recent_movements" in body

    def test_detail_404_structured(self, client, admin_headers):
        resp = client.get(
            "/api/v1/inventory/00000000-0000-0000-0000-000000000099",
            headers=admin_headers,
        )
        assert resp.status_code == 404
        body = resp.json()
        assert body["error"]["code"] == "NOT_FOUND"
        assert "message_key" in body["error"]


# ── Packaging + PMP ────────────────────────────────────────────────────


class TestPackagingWithPMP:
    def test_package_receive_updates_pmp(self, client, admin_headers):
        # Product starts empty; receive 10 Box ×24 @200/package → base cost 200/24
        product = _create_product(
            client, admin_headers, quantity="0.000", cost="0.000",
            barcode="PMP000040",
        )
        pid = product["id"]
        # Create purchase unit
        resp = client.post(
            f"/api/v1/products/{pid}/purchase-units",
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        unit_id = resp.json()["id"]

        # Receive with unit_cost via packaging endpoint
        resp = client.post(
            f"/api/v1/products/{pid}/packaging-state/receive",
            json={
                "purchase_unit_id": unit_id,
                "quantity": "10",
                "unit_cost": "200.000",
                "reason": "purchase",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text

        # Check PMP on product detail
        detail = client.get(
            f"/api/v1/inventory/{pid}", headers=admin_headers
        ).json()
        assert float(detail["quantity"]) == 240.0
        # base cost = 200/24 ≈ 8.333333 → quantized 8.333
        expected = (Decimal("200") / Decimal("24")).quantize(Decimal("0.001"))
        assert Decimal(str(detail["avg_cost"])) == expected

    def test_packaging_sequence_preserves_pmp_on_sales(
        self, client, admin_headers
    ):
        """Sales sequence must leave PMP unchanged (Fromage packaging path)."""
        product = _create_product(
            client, admin_headers, quantity="0.000", cost="0.000",
            barcode="PMP000041",
        )
        pid = product["id"]
        resp = client.post(
            f"/api/v1/products/{pid}/purchase-units",
            json={"name": "Box", "unit_type": "piece", "multiplier": "24"},
            headers=admin_headers,
        )
        unit_id = resp.json()["id"]

        # Receive 10 Box @200 → PMP = 200/24
        client.post(
            f"/api/v1/products/{pid}/packaging-state/receive",
            json={
                "purchase_unit_id": unit_id,
                "quantity": "10",
                "unit_cost": "200.000",
            },
            headers=admin_headers,
        )
        pmp_before = Decimal(
            str(client.get(f"/api/v1/inventory/{pid}", headers=admin_headers).json()["avg_cost"])
        )

        # Sell 3 pieces (may break)
        client.post(
            f"/api/v1/products/{pid}/packaging-state/sell",
            json={"base_quantity": "3"},
            headers=admin_headers,
        )
        pmp_after_sale = Decimal(
            str(client.get(f"/api/v1/inventory/{pid}", headers=admin_headers).json()["avg_cost"])
        )
        assert pmp_after_sale == pmp_before

        # Sell 1 sealed box
        client.post(
            f"/api/v1/products/{pid}/packaging-state/sell-packages",
            json={"purchase_unit_id": unit_id, "quantity": "1"},
            headers=admin_headers,
        )
        pmp_after_pkg_sale = Decimal(
            str(client.get(f"/api/v1/inventory/{pid}", headers=admin_headers).json()["avg_cost"])
        )
        assert pmp_after_pkg_sale == pmp_before


# ── Security ───────────────────────────────────────────────────────────


class TestInventorySecurity:
    def test_unauthenticated_401(self, client):
        resp = client.get("/api/v1/inventory")
        assert resp.status_code == 401
        assert resp.json()["error"]["code"] == "UNAUTHORIZED"

    def test_cashier_cannot_adjust(self, client, admin_headers, cashier_headers):
        product = _create_product(client, admin_headers, barcode="PMP000050")
        result = _adjust(
            client, cashier_headers,
            product_id=product["id"],
            operation="increase",
            quantity="1.000",
            reason="cashier try",
        )
        assert result["status"] == 403, result["body"]
        assert result["body"]["error"]["code"] == "FORBIDDEN"

    def test_cashier_can_view_inventory(
        self, client, admin_headers, cashier_headers
    ):
        # cashier does NOT have inventory_view in seed → 403
        # (cashier permissions: pos_*, product_view, category_view, customer_*)
        resp = client.get("/api/v1/inventory", headers=cashier_headers)
        assert resp.status_code == 403

    def test_manager_can_adjust(self, client, admin_headers, manager_headers):
        product = _create_product(client, admin_headers, barcode="PMP000051")
        result = _adjust(
            client, manager_headers,
            product_id=product["id"],
            operation="increase",
            quantity="1.000",
            reason="manager adjust",
        )
        assert result["status"] == 200, result["body"]

    def test_increase_without_reason_succeeds_with_default(
        self, client, admin_headers, db
    ):
        """INCREASE: reason optional → 200 + neutral default on journal."""
        product = _create_product(client, admin_headers, barcode="PMP000052")
        pid = product["id"]
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "1.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid)
            )
        ).scalars().all()
        # seed (create) + this increase
        assert len(movements) >= 2
        increases = [
            m
            for m in movements
            if m.movement_type == "adjustment"
            and m.reason != "Initial stock on product create"
        ]
        assert len(increases) == 1, [m.reason for m in movements]
        assert increases[0].reason == "Manual stock increase"
        assert bool(increases[0].reason and increases[0].reason.strip())

    def test_increase_with_reason_succeeds(self, client, admin_headers, db):
        """INCREASE: provided reason is stored as-is."""
        product = _create_product(
            client, admin_headers, barcode="PMP000054"
        )
        pid = product["id"]
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "2.000",
                "reason": "Found stock in backroom",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid)
            )
        ).scalars().all()
        increases = [
            m
            for m in movements
            if m.movement_type == "adjustment"
            and m.reason != "Initial stock on product create"
        ]
        assert len(increases) == 1, [m.reason for m in movements]
        assert increases[0].reason == "Found stock in backroom"

    def test_decrease_without_reason_422(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, barcode="PMP000055"
        )
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "decrease",
                "quantity": "1.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422
        body = resp.json()
        assert "error" in body, body
        assert body["error"]["code"] == "VALIDATION_ERROR"
        assert "reason" in body["error"]["message"].lower()
        assert "request_id" in body["error"]

    def test_decrease_blank_reason_422(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, barcode="PMP000056"
        )
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "decrease",
                "quantity": "1.000",
                "reason": "   ",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422
        body = resp.json()
        assert body["error"]["code"] == "VALIDATION_ERROR"

    def test_set_without_reason_422(self, client, admin_headers):
        product = _create_product(client, admin_headers, barcode="PMP000057")
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "set",
                "quantity": "0.000",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422
        body = resp.json()
        assert body["error"]["code"] == "VALIDATION_ERROR"
        assert "reason" in body["error"]["message"].lower()

    def test_increase_empty_reason_succeeds_with_default(
        self, client, admin_headers, db
    ):
        """Scenario B: INCREASE with empty-string reason → 200 + default."""
        product = _create_product(
            client, admin_headers, barcode="PMP000059"
        )
        pid = product["id"]
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "1.000",
                "reason": "",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid)
            )
        ).scalars().all()
        increases = [
            m for m in movements
            if m.movement_type == "adjustment"
            and m.reason != "Initial stock on product create"
        ]
        assert increases[0].reason == "Manual stock increase"

    def test_increase_null_reason_and_unit_cost_succeeds(
        self, client, admin_headers, db
    ):
        """Scenario A/B: INCREASE with reason=null, unit_cost=null → 200,
        PMP unchanged, movement unit_cost null."""
        product = _create_product(
            client, admin_headers, quantity="50.000", cost="40.000",
            barcode="PMP000070",
        )
        pid = product["id"]
        avg_before = product["avg_cost"]
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": pid,
                "operation": "increase",
                "quantity": "10.000",
                "reason": None,
                "unit_cost": None,
                "note": None,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert float(body["quantity"]) == 60.0
        assert float(body["avg_cost"]) == float(avg_before)

        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid)
            )
        ).scalars().all()
        increases = [
            m for m in movements
            if m.movement_type == "adjustment"
            and m.reason != "Initial stock on product create"
        ]
        assert len(increases) == 1
        assert increases[0].reason == "Manual stock increase"
        assert increases[0].unit_cost is None
        assert float(increases[0].avg_cost_after) == float(avg_before)

    def test_increase_with_note_null_succeeds(
        self, client, admin_headers
    ):
        """Scenario F: note=null, reason provided, unit_cost null → 200."""
        product = _create_product(
            client, admin_headers, quantity="10.000", cost="40.000",
            barcode="PMP000071",
        )
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "increase",
                "quantity": "5.000",
                "reason": "Restock",
                "unit_cost": None,
                "note": None,
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text

    def test_successful_increase_always_stores_non_empty_reason(
        self, client, admin_headers, db
    ):
        """Regression: every successful increase has a non-empty journal reason."""
        product = _create_product(
            client, admin_headers, barcode="PMP000058"
        )
        pid = product["id"]
        for payload in (
            {"operation": "increase", "quantity": "1.000"},
            {
                "operation": "increase",
                "quantity": "1.000",
                "reason": "Custom increase",
            },
            {"operation": "increase", "quantity": "1.000", "reason": "  "},
        ):
            body = {"product_id": pid, **payload}
            resp = client.post(
                "/api/v1/inventory/adjust",
                json=body,
                headers=admin_headers,
            )
            assert resp.status_code == 200, resp.text
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(pid)
            )
        ).scalars().all()
        increases = [
            m
            for m in movements
            if m.movement_type == "adjustment"
            and float(m.quantity_change) > 0
            and m.quantity_before != 0  # exclude create-seed if any; ours all increase from seed qty 1
        ]
        # At least the three manual increases above
        manual = [
            m
            for m in movements
            if m.movement_type == "adjustment" and float(m.quantity_change) == 1.0
        ]
        assert len(manual) >= 3
        for m in manual:
            assert m.reason is not None and m.reason.strip(), m.reason

    def test_invalid_operation_422(self, client, admin_headers):
        product = _create_product(client, admin_headers, barcode="PMP000053")
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "destroy",
                "quantity": "1.000",
                "reason": "x",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 422


# ── Base-unit inventory adjustments (Phase 7 final scope) ──────────────
# Inventory AdjustDialog sends ONLY base quantity (no unit selector).
# purchase_unit_id remains available on the API for packaging workflows.


def _create_purchase_unit(client, headers, product_id, **overrides) -> dict:
    payload = {
        "name": "Fardeau",
        "unit_type": "piece",
        "multiplier": "6",
    }
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/purchase-units",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


class TestBaseUnitAdjustments:
    """Inventory operates on base units only (no selling_unit_id path)."""

    def test_a_base_unit_15_plus_5_equals_20(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="15.000", barcode="UNIT000001"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="5.000",
            reason="base increase",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["quantity"]) == 20.0

    def test_base_decrease(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="45.000", barcode="UNIT000003"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="decrease",
            quantity="12.000",
            reason="ship",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["quantity"]) == 33.0

    def test_base_set(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="10.000", barcode="UNIT000008"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="set",
            quantity="30.000",
            reason="stocktake",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["quantity"]) == 30.0

    def test_insufficient_stock_rejected(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, quantity="20.000", barcode="UNIT000004"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="decrease",
            quantity="50.000",
            reason="too much",
        )
        assert result["status"] == 422, result["body"]
        assert result["body"]["error"]["code"] == "BUSINESS_RULE_ERROR"
        detail = client.get(
            f"/api/v1/inventory/{product['id']}", headers=admin_headers
        ).json()
        assert float(detail["quantity"]) == 20.0

    def test_selling_unit_id_not_accepted(self, client, admin_headers):
        """Phase 7 final: selling_unit_id was removed from InventoryAdjustRequest."""
        product = _create_product(
            client, admin_headers, barcode="UNIT000014"
        )
        resp = client.post(
            "/api/v1/inventory/adjust",
            json={
                "product_id": product["id"],
                "operation": "increase",
                "quantity": "1.000",
                "reason": "no selector",
                "selling_unit_id": "00000000-0000-0000-0000-000000000099",
            },
            headers=admin_headers,
        )
        # Strict schema rejects the unknown field (422) or ignores extras;
        # either way the adjustment must not convert via a selling unit.
        if resp.status_code == 200:
            assert float(resp.json()["quantity"]) == float(
                product["quantity"]
            ) + 1.0
        else:
            assert resp.status_code == 422

    def test_e_package_aware_receive_from_zero(
        self, client, admin_headers
    ):
        # 5 Fardeau × 6 = 30 base pieces + 5 full packages, 0 loose
        product = _create_product(
            client, admin_headers, quantity="0.000", barcode="UNIT000005"
        )
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="5.000",
            purchase_unit_id=unit["id"],
            reason="receive sealed fardeaux",
        )
        assert result["status"] == 200, result["body"]
        detail = result["body"]
        assert float(detail["quantity"]) == 30.0
        packaging = detail["packaging"]
        assert float(packaging["total_base_qty"]) == 30.0
        assert float(packaging["loose_base_qty"]) == 0.0
        full = packaging["full_packages"]
        assert len(full) == 1
        assert float(full[0]["full_packages"]) == 5.0

    def test_e2_package_aware_receive_preserves_existing_loose(
        self, client, admin_headers
    ):
        # Existing 15 loose + receive 5 Fardeau → 5 packages, 15 loose, 45 total
        product = _create_product(
            client, admin_headers, quantity="15.000", barcode="UNIT000006"
        )
        unit = _create_purchase_unit(client, admin_headers, product["id"])
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="5.000",
            purchase_unit_id=unit["id"],
            reason="receive 5 fardeau over loose",
        )
        assert result["status"] == 200, result["body"]
        packaging = result["body"]["packaging"]
        assert float(packaging["total_base_qty"]) == 45.0
        assert float(packaging["loose_base_qty"]) == 15.0
        assert float(packaging["full_packages"][0]["full_packages"]) == 5.0

    def test_purchase_unit_decrease_fardeau(self, client, admin_headers):
        # 45 total (5 sealed ×6 + 15 loose) − 2 Fardeau × 6 = 33
        product = _create_product(
            client, admin_headers, quantity="15.000", barcode="UNIT000013"
        )
        pu = _create_purchase_unit(client, admin_headers, product["id"])
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="5.000",
            purchase_unit_id=pu["id"],
            reason="seed",
        )
        assert result["status"] == 200, result["body"]
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="decrease",
            quantity="2.000",
            purchase_unit_id=pu["id"],
            reason="return 2 fardeau",
        )
        assert result["status"] == 200, result["body"]
        assert float(result["body"]["quantity"]) == 33.0
        packaging = result["body"]["packaging"]
        assert float(packaging["full_packages"][0]["full_packages"]) == 3.0
        assert float(packaging["loose_base_qty"]) == 15.0

    def test_unknown_purchase_unit_404(self, client, admin_headers):
        product = _create_product(
            client, admin_headers, barcode="UNIT000010"
        )
        result = _adjust(
            client, admin_headers,
            product_id=product["id"],
            operation="increase",
            quantity="1.000",
            purchase_unit_id="00000000-0000-0000-0000-000000000099",
            reason="bad unit",
        )
        assert result["status"] == 404, result["body"]


# ── Service-level persistence ──────────────────────────────────────────


class TestInventoryServicePersistence:
    def test_adjust_persists_across_sessions(self, engine, TestingSession, db):
        """Mutation via one session is visible in a fresh session."""
        from app.models.catalog import Product

        session1 = TestingSession()
        product = Product(
            name="Persist Test",
            barcode="PMP000060",
            price=10,
            cost=50,
            avg_cost=50,  # seeded PMP (as ProductService.create would)
            quantity=1,
            unit="piece",
        )
        session1.add(product)
        session1.commit()
        pid = product.id

        from app.schemas.inventory import InventoryAdjustRequest

        svc = InventoryService(session1)
        req = InventoryAdjustRequest(
            product_id=pid,
            operation="increase",
            quantity=Decimal("3"),
            unit_cost=Decimal("100"),
            reason="persist test",
        )
        detail = svc.adjust(req)
        expected_avg = (
            (Decimal("1") * Decimal("50") + Decimal("3") * Decimal("100")) / 4
        )
        assert Decimal(str(detail.avg_cost)) == expected_avg
        session1.close()

        session2 = TestingSession()
        p = session2.get(Product, pid)
        assert p is not None
        assert float(p.quantity) == 4.0
        assert float(p.avg_cost) == 87.5
        movs = session2.execute(
            select(InventoryMovement).where(InventoryMovement.product_id == pid)
        ).scalars().all()
        assert len(movs) == 1
        session2.close()