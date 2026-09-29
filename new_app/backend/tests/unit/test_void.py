"""Phase 12 tests — invoice void.

Covers the decision-record gates:

- GATE  1  one-way terminal transition; SALE_ALREADY_VOID, no unvoid
- GATE  7  SALE_VOID movements with source_document_type/id
- GATE  8  debt reversal (min(credit, balance)) + shortfall note
- GATE  9  voided_at / voided_by / void_reason recorded, totals FROZEN
- GATE 10  mutual exclusion: a sale with returns cannot be voided
- GATE 11/12/13 pack components, variant-only and selling-unit restores
- GATE 19  idempotency by state (a second restore cannot happen)
- GATE 21  pos_void permission (manager/admin yes, cashier no)
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
from app.models.catalog import Product, ProductVariant
from app.models.debt import DebtLedgerEntry
from app.models.inventory import InventoryMovement
from app.models.party import Customer
from app.models.return_doc import Return
from app.services.auth import AuthService

# ── Fixtures ──────────────────────────────────────────────────────────────


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
def manager_headers(client):
    return _login(client, "Manager Mo", "2222")


@pytest.fixture()
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


_seq = {"n": 0}


def _next() -> int:
    _seq["n"] += 1
    return _seq["n"]


def _create_product(client, headers, **overrides) -> dict:
    n = _next()
    payload = {
        "name": overrides.pop("name", f"Void Product {n}"),
        "barcode": overrides.pop("barcode", f"VD{n:06d}"),
        "price": overrides.pop("price", "100.000"),
        "cost": overrides.pop("cost", "60.000"),
        "quantity": overrides.pop("quantity", "10.000"),
        "unit": overrides.pop("unit", "piece"),
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_variant(client, headers, product_id: str, **overrides) -> dict:
    payload = {"name": overrides.pop("name", f"Var {_next()}")}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/variants",
        json=payload,
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_selling_unit(client, headers, product_id: str, **overrides) -> dict:
    payload = {
        "name": overrides.pop("name", f"Unit {_next()}"),
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


def _create_customer(client, headers, name: str) -> dict:
    resp = client.post("/api/v1/customers", json={"name": name}, headers=headers)
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


def _sell(client, headers, product_id: str, quantity: str, **overrides) -> dict:
    payload = _sale_payload(
        [
            {
                "product_id": product_id,
                "quantity": quantity,
                "unit_price": overrides.pop("unit_price", "100.000"),
            }
        ],
        **overrides,
    )
    resp = _post_sale(client, headers, payload)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _void(client, headers, sale_id: str, reason: str = "wrong barcode scanned"):
    return client.post(
        f"/api/v1/sales/{sale_id}/void",
        json={"reason": reason},
        headers=headers,
    )


def _stock(client, headers, product_id: str) -> Decimal:
    resp = client.get(f"/api/v1/products/{product_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return Decimal(resp.json()["quantity"])


def _sale(client, headers, sale_id: str) -> dict:
    resp = client.get(f"/api/v1/sales/{sale_id}", headers=headers)
    assert resp.status_code == 200, resp.text
    return resp.json()


def _product_line(sale: dict) -> dict:
    return next(ln for ln in sale["lines"] if ln["product_id"] is not None)


def _movements(db, **filters) -> list[InventoryMovement]:
    db.expire_all()
    stmt = select(InventoryMovement)
    for attr, value in filters.items():
        stmt = stmt.where(getattr(InventoryMovement, attr) == value)
    return list(db.execute(stmt).scalars().all())


# ── GATE 1/7/9: the void itself ───────────────────────────────────────────


class TestVoidBasics:
    def test_void_restores_stock_and_records_attribution(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "3.000")
        assert _stock(client, admin_headers, p["id"]) == Decimal("7.000")
        snapshot = dict(sale)

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text
        body = resp.json()

        # stock comes back in full
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

        # GATE 9: attribution on the response, snapshot frozen
        voided = body["sale"]
        assert voided["status"] == "void"
        assert voided["voided_at"] is not None
        assert voided["voided_by"] is not None
        assert voided["void_reason"] == "wrong barcode scanned"
        for field in (
            "subtotal",
            "discount",
            "total",
            "paid",
            "change",
            "payment_method",
        ):
            assert voided[field] == snapshot[field], field

        # refund base is the ORIGINAL invoice total (§18)
        assert Decimal(body["refund_due"]) == Decimal(snapshot["total"])
        assert Decimal(body["credit_reversed"]) == Decimal("0.000")
        assert Decimal(body["cash_pending"]) == Decimal(snapshot["total"])

        # GATE 7: sale_void journal rows pointing at the sale
        moves = _movements(
            db,
            product_id=uuid.UUID(p["id"]),
            movement_type="sale_void",
        )
        assert len(moves) == 1
        assert moves[0].source_document_type == "sale"
        assert moves[0].source_document_id == uuid.UUID(sale["id"])
        assert Decimal(str(moves[0].quantity_change)) == Decimal("3.000")
        assert moves[0].reason == f"Void {sale['invoice_number']}"

        # GATE 21: exactly one audit row, typed as a void of this sale
        db.expire_all()
        audits = list(
            db.execute(
                select(AuditLog).where(
                    AuditLog.action == "void",
                    AuditLog.entity_type == "sale",
                    AuditLog.entity_id == uuid.UUID(sale["id"]),
                )
            ).scalars().all()
        )
        assert len(audits) == 1
        assert "wrong barcode scanned" in audits[0].details

        # the sale is still visible in history — never deleted
        after = _sale(client, admin_headers, sale["id"])
        assert after["status"] == "void"

    def test_void_is_terminal(self, client, admin_headers, db):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "2.000")

        first = _void(client, admin_headers, sale["id"])
        assert first.status_code == 200, first.text

        second = _void(client, admin_headers, sale["id"], reason="again")
        assert second.status_code == 409
        assert second.json()["error"]["code"] == "SALE_ALREADY_VOID"

        # stock was restored exactly once
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")
        moves = _movements(
            db, product_id=uuid.UUID(p["id"]), movement_type="sale_void"
        )
        assert len(moves) == 1

    def test_reason_is_mandatory(self, client, admin_headers):
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, p["id"], "1.000")

        resp = client.post(
            f"/api/v1/sales/{sale['id']}/void",
            json={"reason": "   "},
            headers=admin_headers,
        )
        assert resp.status_code == 422

        resp = client.post(
            f"/api/v1/sales/{sale['id']}/void", json={}, headers=admin_headers
        )
        assert resp.status_code == 422

        # sale untouched by the rejected attempts
        assert _sale(client, admin_headers, sale["id"])["status"] == "completed"

    def test_unknown_sale_is_404(self, client, admin_headers):
        resp = _void(client, admin_headers, str(uuid.uuid4()))
        assert resp.status_code == 404


# ── GATE 8: debt reversal ─────────────────────────────────────────────────


class TestVoidDebt:
    def test_credit_void_forgives_the_sale_debt(
        self, client, admin_headers, db
    ):
        c = _create_customer(client, admin_headers, "Void Debt")
        p = _create_product(client, admin_headers, quantity="20.000")
        sale = _sell(
            client,
            admin_headers,
            p["id"],
            "4.000",
            payment_method="credit",
            paid="0.000",
            customer_id=c["id"],
        )
        db.expire_all()
        assert Decimal(str(db.get(Customer, uuid.UUID(c["id"])).balance)) == Decimal(
            "400.000"
        )

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text
        body = resp.json()

        assert Decimal(body["refund_due"]) == Decimal("400.000")
        assert Decimal(body["credit_reversed"]) == Decimal("400.000")
        assert Decimal(body["cash_pending"]) == Decimal("0.000")

        db.expire_all()
        customer = db.get(Customer, uuid.UUID(c["id"]))
        assert Decimal(str(customer.balance)) == Decimal("0.000")

        entries = list(
            db.execute(
                select(DebtLedgerEntry).where(
                    DebtLedgerEntry.reference_sale_id == uuid.UUID(sale["id"])
                )
            ).scalars().all()
        )
        types = sorted(e.entry_type for e in entries)
        assert types == ["sale", "sale_void"]
        void_entry = next(e for e in entries if e.entry_type == "sale_void")
        assert Decimal(str(void_entry.amount)) == Decimal("400.000")
        assert void_entry.client_request_id is None

    def test_reversal_never_exceeds_the_remaining_balance(
        self, client, admin_headers, db
    ):
        # 100.000 invoice, 60.000 already paid in cash -> 40.000 of credit
        c = _create_customer(client, admin_headers, "Partial Void")
        p = _create_product(client, admin_headers, quantity="20.000")
        sale = _sell(
            client,
            admin_headers,
            p["id"],
            "1.000",
            payment_method="partial",
            paid="60.000",
            customer_id=c["id"],
        )
        db.expire_all()
        assert Decimal(str(db.get(Customer, uuid.UUID(c["id"])).balance)) == Decimal(
            "40.000"
        )

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text
        body = resp.json()

        assert Decimal(body["refund_due"]) == Decimal("100.000")
        assert Decimal(body["credit_reversed"]) == Decimal("40.000")
        assert Decimal(body["cash_pending"]) == Decimal("60.000")

        db.expire_all()
        customer = db.get(Customer, uuid.UUID(c["id"]))
        assert Decimal(str(customer.balance)) == Decimal("0.000")

        entry = next(
            e
            for e in db.execute(select(DebtLedgerEntry)).scalars().all()
            if e.entry_type == "sale_void"
        )
        assert "shortfall 60.000" in entry.note


# ── GATE 10: mutual exclusion ─────────────────────────────────────────────


class TestMutualExclusion:
    def test_sale_with_returns_cannot_be_voided(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, admin_headers, p["id"], "2.000")
        line = _product_line(sale)

        ret = client.post(
            "/api/v1/returns",
            json={
                "client_request_id": str(uuid.uuid4()),
                "reason": "defective",
                "sale_id": sale["id"],
                "lines": [{"sale_line_id": line["id"], "quantity": "1.000"}],
            },
            headers=admin_headers,
        )
        assert ret.status_code == 201, ret.text

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 409
        error = resp.json()["error"]
        assert error["code"] == "SALE_HAS_RETURNS"
        assert error["details"]["returns"] == [ret.json()["return"]["return_number"]]

        # nothing moved: stock still reflects the returned unit
        assert _stock(client, admin_headers, p["id"]) == Decimal("9.000")
        assert _sale(client, admin_headers, sale["id"])["status"] == "completed"

        db.expire_all()
        assert len(list(db.execute(select(Return)).scalars().all())) == 1


# ── GATE 11/12/13: restore shapes ─────────────────────────────────────────


class TestVoidRestoreShapes:
    @pytest.fixture()
    def pack_sale(self, client, admin_headers):
        a = _create_product(client, admin_headers, name=f"A {_next()}", quantity="20.000")
        b = _create_product(client, admin_headers, name=f"B {_next()}", quantity="20.000")
        resp = client.post(
            "/api/v1/packs",
            json={
                "name": f"Void Pack {_next()}",
                "barcode": f"VPK{_next():06d}",
                "price": "300.000",
                "components": [
                    {"product_id": a["id"], "quantity": "2.000"},
                    {"product_id": b["id"], "quantity": "1.000"},
                ],
            },
            headers=admin_headers,
        )
        assert resp.status_code == 201, resp.text
        pack = resp.json()

        sale_resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "pack_id": pack["id"],
                        "quantity": "1.000",
                        "unit_price": "300.000",
                    }
                ],
                paid="300.000",
            ),
        )
        assert sale_resp.status_code == 201, sale_resp.text
        return {"pack": pack, "a": a, "b": b, "sale": sale_resp.json()}

    def test_pack_void_restores_components_without_summary_movement(
        self, client, admin_headers, db, pack_sale
    ):
        a, b, sale = pack_sale["a"], pack_sale["b"], pack_sale["sale"]
        assert _stock(client, admin_headers, a["id"]) == Decimal("18.000")
        assert _stock(client, admin_headers, b["id"]) == Decimal("19.000")

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text

        assert _stock(client, admin_headers, a["id"]) == Decimal("20.000")
        assert _stock(client, admin_headers, b["id"]) == Decimal("20.000")

        # one movement per component product — never for the charged summary
        moves = _movements(db, movement_type="sale_void")
        assert {m.product_id for m in moves} == {
            uuid.UUID(a["id"]),
            uuid.UUID(b["id"]),
        }

    def test_variant_void_touches_the_variant_only(
        self, client, admin_headers, db
    ):
        p = _create_product(client, admin_headers, quantity="10.000")
        v = _create_variant(
            client, admin_headers, p["id"], price="150.000", quantity="5.000"
        )
        sale_resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "product_id": p["id"],
                        "variant_id": v["id"],
                        "quantity": "1.000",
                        "unit_price": "150.000",
                    }
                ],
                paid="150.000",
            ),
        )
        assert sale_resp.status_code == 201, sale_resp.text
        sale = sale_resp.json()

        db.expire_all()
        assert Decimal(str(db.get(ProductVariant, uuid.UUID(v["id"])).quantity)) == (
            Decimal("4.000")
        )

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text

        db.expire_all()
        assert Decimal(str(db.get(ProductVariant, uuid.UUID(v["id"])).quantity)) == (
            Decimal("5.000")
        )
        assert Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity)) == Decimal(
            "10.000"
        )
        moves = _movements(db, movement_type="sale_void")
        assert moves and moves[0].variant_id == uuid.UUID(v["id"])

    def test_selling_unit_void_restores_base_quantity(
        self, client, admin_headers
    ):
        p = _create_product(client, admin_headers, quantity="10.000", unit="kg")
        unit = _create_selling_unit(
            client, admin_headers, p["id"], multiplier="2.500"
        )
        sale_resp = _post_sale(
            client,
            admin_headers,
            _sale_payload(
                [
                    {
                        "product_id": p["id"],
                        "selling_unit_id": unit["id"],
                        "quantity": "1.000",
                        "unit_price": "100.000",
                    }
                ],
                paid="100.000",
            ),
        )
        assert sale_resp.status_code == 201, sale_resp.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("7.500")

        resp = _void(client, admin_headers, sale_resp.json()["id"])
        assert resp.status_code == 200, resp.text
        assert _stock(client, admin_headers, p["id"]) == Decimal("10.000")

    def test_pmp_is_unchanged_by_a_void(self, client, admin_headers, db):
        p = _create_product(
            client, admin_headers, cost="60.000", price="100.000", quantity="10.000"
        )
        sale = _sell(client, admin_headers, p["id"], "2.000")

        db.expire_all()
        cost_before = Decimal(str(db.get(Product, uuid.UUID(p["id"])).avg_cost))

        resp = _void(client, admin_headers, sale["id"])
        assert resp.status_code == 200, resp.text

        db.expire_all()
        product = db.get(Product, uuid.UUID(p["id"]))
        assert Decimal(str(product.avg_cost)) == cost_before

        moves = _movements(db, movement_type="sale_void")
        assert Decimal(str(moves[0].avg_cost_after)) == cost_before


# ── GATE 21: permissions ──────────────────────────────────────────────────


class TestVoidPermissions:
    def test_manager_with_pos_void_can_void(self, client, manager_headers):
        p = _create_product(client, manager_headers, quantity="10.000")
        sale = _sell(client, manager_headers, p["id"], "1.000")
        resp = _void(client, manager_headers, sale["id"])
        assert resp.status_code == 200, resp.text

    def test_cashier_without_pos_void_is_forbidden(
        self, client, admin_headers, cashier_headers
    ):
        # cashier creates nothing (product_create is admin/manager only):
        # admin makes the product, cashier sells it, cashier may NOT void
        p = _create_product(client, admin_headers, quantity="10.000")
        sale = _sell(client, cashier_headers, p["id"], "1.000")

        resp = _void(client, cashier_headers, sale["id"])
        assert resp.status_code == 403
        assert resp.json()["error"]["details"]["required_permission"] == "pos_void"

        # still completed, stock untouched
        assert _sale(client, admin_headers, sale["id"])["status"] == "completed"
        assert _stock(client, admin_headers, p["id"]) == Decimal("9.000")

        # admin can still do it
        ok = _void(client, admin_headers, sale["id"])
        assert ok.status_code == 200, ok.text

    def test_authentication_is_required(self, client):
        resp = client.post(
            f"/api/v1/sales/{uuid.uuid4()}/void", json={"reason": "x"}
        )
        assert resp.status_code == 401
