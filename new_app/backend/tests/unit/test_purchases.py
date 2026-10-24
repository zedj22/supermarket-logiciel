"""Phase 11 tests — purchase documents (create/receive/cancel/delete).

Covers:
- atomic create+receive: stock, PMP, nominal cost, movements, payable
- draft creation with zero side effects, later receive
- packaging receipt (whole boxes -> base stock + sealed packages)
- variant receipt (variant.quantity only, product avg untouched)
- PMP blend on receipt; PMP NEVER recomputed on cancellation (GATE 12)
- idempotent create replay via client_request_id (no double receive)
- double receive -> 409 PURCHASE_ALREADY_RECEIVED (state guard)
- cancellation reversal + payable capped at balance (shortfall in note)
- draft-only edit/delete; received/cancelled immutable
- structured line validation (PURCHASE_LINE_INVALID, 404 for unknown)
- ledger reconciliation: suppliers.balance == supplier_ledger_entries
- RBAC: purchase_view for reads, purchase_create/purchase_delete for writes
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.audit import AuditLog
from app.models.catalog import Product, ProductStockPackage, ProductVariant
from app.models.enums import AuditAction
from app.models.inventory import InventoryMovement
from app.models.party import Supplier
from app.models.purchase import Purchase
from app.models.supplier_ledger import SupplierLedgerEntry
from app.repositories.purchase import PurchaseRepository
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
def cashier_headers(client):
    return _login(client, "Cashier Ali", "3333")


_seq = {"n": 0}


def _next() -> int:
    _seq["n"] += 1
    return _seq["n"]


def _create_product(client, headers, **overrides) -> dict:
    n = _next()
    payload = {
        "name": overrides.pop("name", f"Purchase Product {n}"),
        "barcode": overrides.pop("barcode", f"PRCH{n:06d}"),
        "price": overrides.pop("price", "150.000"),
        "cost": overrides.pop("cost", "100.000"),
        "quantity": overrides.pop("quantity", "0.000"),
        "unit": "piece",
    }
    payload.update(overrides)
    resp = client.post("/api/v1/products", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _create_purchase_unit(
    client, headers, product_id: str, **overrides
) -> dict:
    payload = {"name": "Box", "multiplier": "24"}
    payload.update(overrides)
    resp = client.post(
        f"/api/v1/products/{product_id}/purchase-units",
        json=payload,
        headers=headers,
    )
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


def _create_supplier(client, headers, **overrides) -> dict:
    payload = {"name": overrides.pop("name", f"Supplier {_next()}")}
    payload.update(overrides)
    resp = client.post("/api/v1/suppliers", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


def _purchase_payload(supplier_id: str, lines: list, **overrides) -> dict:
    payload = {"supplier_id": supplier_id, "lines": lines}
    payload.update(overrides)
    return payload


def _create_purchase(client, headers, payload: dict) -> tuple[int, dict]:
    resp = client.post("/api/v1/purchases", json=payload, headers=headers)
    return resp.status_code, resp.json() if resp.content else {}


def _stock(db, product_id: str) -> Product:
    db.expire_all()
    return db.get(Product, uuid.UUID(product_id))


def _movements(db, product_id: str) -> list[InventoryMovement]:
    db.expire_all()
    return list(
        db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == uuid.UUID(product_id)
            )
        ).scalars()
    )


def _ledger_entries(db, supplier_id: str) -> list[SupplierLedgerEntry]:
    db.expire_all()
    return list(
        db.execute(
            select(SupplierLedgerEntry).where(
                SupplierLedgerEntry.supplier_id == uuid.UUID(supplier_id)
            )
        ).scalars()
    )


def _balance(db, supplier_id: str) -> Decimal:
    db.expire_all()
    supplier = db.get(Supplier, uuid.UUID(supplier_id))
    return Decimal(str(supplier.balance))


def _ledger_sum(entries: list[SupplierLedgerEntry]) -> Decimal:
    """Authoritative projection: purchase +, payment -, purchase_cancel -."""
    total = Decimal("0")
    for e in entries:
        amount = Decimal(str(e.amount))
        if e.entry_type == "purchase":
            total += amount
        elif e.entry_type in ("payment", "purchase_cancel"):
            total -= amount
    return total


# ── Atomic create + receive ─────────────────────────────────────────────


def test_receive_base_line_full_payment(client, admin_headers, db):
    product = _create_product(client, admin_headers, quantity="0.000")
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="500",
        ),
    )
    assert code == 201, body
    assert body["status"] == "received"
    assert body["received_at"] is not None
    assert body["invoice_number"].startswith("PUR-")
    assert Decimal(str(body["subtotal"])) == Decimal("500")
    assert Decimal(str(body["total"])) == Decimal("500")

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(10.0)
    assert Decimal(str(p.avg_cost)) == Decimal("50.000")
    assert Decimal(str(p.cost)) == Decimal("50.000")

    moves = _movements(db, product["id"])
    purchase_moves = [m for m in moves if m.movement_type == "purchase"]
    assert len(purchase_moves) == 1
    m = purchase_moves[0]
    assert float(m.quantity_change) == pytest.approx(10.0)
    assert float(m.quantity_before) == pytest.approx(0.0)
    assert float(m.quantity_after) == pytest.approx(10.0)
    assert str(m.source_document_id) == body["id"]
    assert m.source_document_type == "purchase"

    # Fully paid: payable untouched, no ledger entry.
    assert _balance(db, supplier["id"]) == Decimal("0")
    assert _ledger_entries(db, supplier["id"]) == []

    audits = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == uuid.UUID(body["id"])
        )
    ).scalars().all()
    actions = {a.action for a in audits}
    assert AuditAction.CREATE.value in actions
    assert AuditAction.RECEIVE.value in actions


def test_receive_partial_payment_creates_payable(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="200",
        ),
    )
    assert code == 201, body
    assert body["invoice_number"].startswith("PUR-")

    entries = _ledger_entries(db, supplier["id"])
    assert len(entries) == 1
    assert entries[0].entry_type == "purchase"
    assert Decimal(str(entries[0].amount)) == Decimal("300")
    assert str(entries[0].reference_purchase_id) == body["id"]

    balance = _balance(db, supplier["id"])
    assert balance == Decimal("300")
    assert _ledger_sum(entries) == balance


def test_draft_create_then_receive(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "7", "unit_cost": "30"}],
            paid="0",
            receive=False,
        ),
    )
    assert code == 201, body
    assert body["status"] == "draft"
    assert body["received_at"] is None

    # Draft: zero side effects.
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(0.0)
    assert _movements(db, product["id"]) == []
    assert _balance(db, supplier["id"]) == Decimal("0")
    assert _ledger_entries(db, supplier["id"]) == []

    resp = client.post(
        f"/api/v1/purchases/{body['id']}/receive", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "received"

    assert float(_stock(db, product["id"]).quantity) == pytest.approx(7.0)
    assert len(_ledger_entries(db, supplier["id"])) == 1


def test_receive_package_line(client, admin_headers, db):
    product = _create_product(client, admin_headers, quantity="0.000")
    unit = _create_purchase_unit(
        client, admin_headers, product["id"], name="Box", multiplier="24"
    )
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [
                {
                    "product_id": product["id"],
                    "purchase_unit_id": unit["id"],
                    "quantity": "5",
                    "unit_cost": "240",
                }
            ],
            paid="1200",
        ),
    )
    assert code == 201, body
    assert body["status"] == "received"

    # Document stays in boxes; stock grows in base units; PMP = 240/24.
    line = body["lines"][0]
    assert Decimal(str(line["quantity"])) == Decimal("5")
    assert Decimal(str(line["unit_cost"])) == Decimal("240.000")
    assert Decimal(str(line["base_qty_equivalent"])) == Decimal("120")
    assert line["purchase_unit_name"] == "Box"

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(120.0)
    assert Decimal(str(p.avg_cost)) == Decimal("10.000")
    assert Decimal(str(p.cost)) == Decimal("10.000")

    db.expire_all()
    pack = db.execute(
        select(ProductStockPackage).where(
            ProductStockPackage.product_id == uuid.UUID(product["id"])
        )
    ).scalar_one()
    assert float(pack.full_packages) == pytest.approx(5.0)
    assert str(pack.purchase_unit_id) == unit["id"]


def test_receive_variant_line(client, admin_headers, db):
    product = _create_product(client, admin_headers, quantity="0.000")
    avg_before = Decimal(str(_stock(db, product["id"]).avg_cost))
    variant = _create_variant(client, admin_headers, product["id"])
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [
                {
                    "product_id": product["id"],
                    "variant_id": variant["id"],
                    "quantity": "7",
                    "unit_cost": "20",
                }
            ],
            paid="140",
        ),
    )
    assert code == 201, body

    # Variant stock moves; the product row (and its PMP) does not.
    db.expire_all()
    v = db.get(ProductVariant, uuid.UUID(variant["id"]))
    assert float(v.quantity) == pytest.approx(7.0)
    assert Decimal(str(v.cost)) == Decimal("20.000")
    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(0.0)
    # Product avg_cost is untouched by variant receipts (Phase 7 deferral).
    assert Decimal(str(p.avg_cost)) == avg_before

    line = body["lines"][0]
    assert line["product_name"].endswith(f"({v.name})")


def test_receive_blends_pmp_and_updates_nominal_cost(client, admin_headers, db):
    # 10 units already in stock at avg 100 (seeded on product create).
    product = _create_product(
        client, admin_headers, quantity="10.000", cost="100.000"
    )
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "200"}],
            paid="2000",
        ),
    )
    assert code == 201, body

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(20.0)
    # (10×100 + 10×200) / 20 = 150 — document discount never feeds PMP.
    assert Decimal(str(p.avg_cost)) == Decimal("150.000")
    # Nominal cost = latest receipt base unit cost.
    assert Decimal(str(p.cost)) == Decimal("200.000")


# ── Idempotency / state guards ──────────────────────────────────────────


def test_create_idempotent_replay_never_receives_twice(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    payload = _purchase_payload(
        supplier["id"],
        [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
        paid="500",
        client_request_id="purchase-dup-001",
    )

    first_code, first = _create_purchase(client, admin_headers, payload)
    second_code, second = _create_purchase(client, admin_headers, payload)
    assert first_code == 201
    assert second_code == 201
    assert first["id"] == second["id"]
    assert second["idempotent_replay"] is True

    assert float(_stock(db, product["id"]).quantity) == pytest.approx(10.0)
    assert (
        len(
            [
                m
                for m in _movements(db, product["id"])
                if m.movement_type == "purchase"
            ]
        )
        == 1
    )
    listing = client.get("/api/v1/purchases", headers=admin_headers).json()
    assert listing["total"] == 1


def test_double_receive_rejected(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="0",
            receive=False,
        ),
    )

    first = client.post(
        f"/api/v1/purchases/{body['id']}/receive", headers=admin_headers
    )
    second = client.post(
        f"/api/v1/purchases/{body['id']}/receive", headers=admin_headers
    )
    assert first.status_code == 200, first.text
    assert second.status_code == 409, second.text
    assert second.json()["error"]["code"] == "PURCHASE_ALREADY_RECEIVED"

    # Stock and payable applied exactly once.
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(10.0)
    entries = _ledger_entries(db, supplier["id"])
    assert len(entries) == 1
    assert _balance(db, supplier["id"]) == _ledger_sum(entries)


def test_receive_cancelled_purchase_rejected(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "5", "unit_cost": "10"}],
            paid="50",
        ),
    )
    cancel = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert cancel.status_code == 200, cancel.text

    again = client.post(
        f"/api/v1/purchases/{body['id']}/receive", headers=admin_headers
    )
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "PURCHASE_ALREADY_CANCELLED"
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(0.0)


def test_state_guards_on_edit_delete_cancel(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, received = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "5", "unit_cost": "10"}],
            paid="50",
        ),
    )
    _, draft = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            receive=False,
        ),
    )

    # Received is immutable.
    put = client.put(
        f"/api/v1/purchases/{received['id']}",
        json={"note": "nope"},
        headers=admin_headers,
    )
    assert put.status_code == 409
    assert put.json()["error"]["code"] == "INVALID_PURCHASE_STATE"

    delete = client.delete(
        f"/api/v1/purchases/{received['id']}", headers=admin_headers
    )
    assert delete.status_code == 409
    assert delete.json()["error"]["code"] == "INVALID_PURCHASE_STATE"

    # Cancelling a draft is rejected (delete instead).
    cancel_draft = client.post(
        f"/api/v1/purchases/{draft['id']}/cancel", headers=admin_headers
    )
    assert cancel_draft.status_code == 409
    assert cancel_draft.json()["error"]["code"] == "INVALID_PURCHASE_STATE"

    # Received -> cancelled -> terminal.
    cancel = client.post(
        f"/api/v1/purchases/{received['id']}/cancel", headers=admin_headers
    )
    assert cancel.status_code == 200, cancel.text
    cancel_again = client.post(
        f"/api/v1/purchases/{received['id']}/cancel", headers=admin_headers
    )
    assert cancel_again.status_code == 409
    assert cancel_again.json()["error"]["code"] == "PURCHASE_ALREADY_CANCELLED"

    put_cancelled = client.put(
        f"/api/v1/purchases/{received['id']}",
        json={"note": "nope"},
        headers=admin_headers,
    )
    assert put_cancelled.status_code == 409
    assert put_cancelled.json()["error"]["code"] == "PURCHASE_ALREADY_CANCELLED"


def test_delete_draft_hard_deletes_with_audit(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "3", "unit_cost": "10"}],
            receive=False,
        ),
    )
    purchase_id = body["id"]

    resp = client.delete(
        f"/api/v1/purchases/{purchase_id}", headers=admin_headers
    )
    assert resp.status_code == 204

    assert (
        client.get(
            f"/api/v1/purchases/{purchase_id}", headers=admin_headers
        ).status_code
        == 404
    )
    db.expire_all()
    assert db.get(Purchase, uuid.UUID(purchase_id)) is None

    audits = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == uuid.UUID(purchase_id)
        )
    ).scalars().all()
    assert any(a.action == AuditAction.DELETE.value for a in audits)


# ── Cancellation ────────────────────────────────────────────────────────


def test_cancel_reverses_stock_payable_and_keeps_pmp(
    client, admin_headers, db
):
    product = _create_product(
        client, admin_headers, quantity="10.000", cost="100.000"
    )
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "200"}],
            paid="0",
        ),
    )
    # After receive: 20 units, avg 150, payable 2000.
    assert Decimal(str(_stock(db, product["id"]).avg_cost)) == Decimal(
        "150.000"
    )

    resp = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    cancelled = resp.json()
    assert cancelled["status"] == "cancelled"
    assert cancelled["cancelled_at"] is not None

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(10.0)
    # GATE 12: cancellation never recomputes PMP or nominal cost.
    assert Decimal(str(p.avg_cost)) == Decimal("150.000")
    assert Decimal(str(p.cost)) == Decimal("200.000")

    moves = _movements(db, product["id"])
    deletes = [m for m in moves if m.movement_type == "purchase_delete"]
    assert len(deletes) == 1
    assert float(deletes[0].quantity_change) == pytest.approx(-10.0)

    entries = _ledger_entries(db, supplier["id"])
    assert [e.entry_type for e in entries] == ["purchase", "purchase_cancel"]
    balance = _balance(db, supplier["id"])
    assert balance == Decimal("0")
    assert _ledger_sum(entries) == balance

    audits = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == uuid.UUID(body["id"]),
            AuditLog.action == AuditAction.VOID.value,
        )
    ).scalars().all()
    assert len(audits) == 1


def test_cancel_payable_capped_at_balance_with_shortfall_note(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers, quantity="50.000")
    supplier = _create_supplier(client, admin_headers)
    line = lambda: [  # noqa: E731
        {"product_id": product["id"], "quantity": "10", "unit_cost": "10"}
    ]
    _, p1 = _create_purchase(
        client, admin_headers,
        _purchase_payload(supplier["id"], line(), paid="0"),
    )
    _create_purchase(
        client, admin_headers,
        _purchase_payload(supplier["id"], line(), paid="0"),
    )
    assert _balance(db, supplier["id"]) == Decimal("200")

    # Settle 150 of the pooled balance (supplier-level payments).
    pay = client.post(
        f"/api/v1/suppliers/{supplier['id']}/payments",
        json={"amount": "150", "client_request_id": "conc-pay-1"},
        headers=admin_headers,
    )
    assert pay.status_code == 200, pay.text
    assert _balance(db, supplier["id"]) == Decimal("50")

    # Cancel P1 (its own unpaid = 100) — reversal capped at balance 50.
    resp = client.post(
        f"/api/v1/purchases/{p1['id']}/cancel", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text

    entries = _ledger_entries(db, supplier["id"])
    cancel_entries = [
        e for e in entries if e.entry_type == "purchase_cancel"
    ]
    assert len(cancel_entries) == 1
    assert Decimal(str(cancel_entries[0].amount)) == Decimal("50")
    assert "shortfall" in cancel_entries[0].note

    balance = _balance(db, supplier["id"])
    assert balance == Decimal("0")
    assert _ledger_sum(entries) == balance


def test_cancel_fully_paid_purchase_writes_no_ledger_entry(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "4", "unit_cost": "25"}],
            paid="100",
        ),
    )
    assert _ledger_entries(db, supplier["id"]) == []

    resp = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert resp.status_code == 200, resp.text
    assert _ledger_entries(db, supplier["id"]) == []
    assert _balance(db, supplier["id"]) == Decimal("0")


def test_cancel_negative_stock_conflict_rolls_back(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="0",
        ),
    )
    # Someone already sold most of the received stock.
    p = _stock(db, product["id"])
    p.quantity = 3.0
    db.commit()

    resp = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert resp.status_code == 409, resp.text
    assert resp.json()["error"]["code"] == "CONFLICT"
    # A genuine stock conflict keeps its own explanation — it is never
    # the generic database-constraint message.
    message = resp.json()["error"]["message"]
    assert message == "Purchase cancellation would make stock negative"
    assert message != "A database constraint was violated"

    # Whole reversal rolled back: still received, stock/payable untouched.
    fresh = client.get(
        f"/api/v1/purchases/{body['id']}", headers=admin_headers
    ).json()
    assert fresh["status"] == "received"
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(3.0)
    entries = _ledger_entries(db, supplier["id"])
    assert len(entries) == 1
    assert _balance(db, supplier["id"]) == _ledger_sum(entries)


# ── Draft editing ───────────────────────────────────────────────────────


def test_draft_edit_replaces_lines_and_recomputes_totals(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)
    _, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            discount="50",
            paid="450",
            receive=False,
        ),
    )
    assert Decimal(str(body["total"])) == Decimal("450")

    resp = client.put(
        f"/api/v1/purchases/{body['id']}",
        json={
            "lines": [
                {"product_id": product["id"], "quantity": "20", "unit_cost": "60"}
            ]
        },
        headers=admin_headers,
    )
    assert resp.status_code == 200, resp.text
    updated = resp.json()
    assert Decimal(str(updated["subtotal"])) == Decimal("1200")
    assert Decimal(str(updated["discount"])) == Decimal("50")
    assert Decimal(str(updated["total"])) == Decimal("1150")
    assert len(updated["lines"]) == 1
    assert Decimal(str(updated["lines"][0]["quantity"])) == Decimal("20")

    # Editing a draft never touches stock.
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(0.0)

    audits = db.execute(
        select(AuditLog).where(
            AuditLog.entity_id == uuid.UUID(body["id"]),
            AuditLog.action == AuditAction.UPDATE.value,
        )
    ).scalars().all()
    assert len(audits) == 1


# ── Validation ──────────────────────────────────────────────────────────


def test_line_validation_errors(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    supplier = _create_supplier(client, admin_headers)

    unknown_product = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": str(uuid.uuid4()), "quantity": "1", "unit_cost": "1"}],
        ),
    )
    assert unknown_product[0] == 404
    assert unknown_product[1]["error"]["code"] == "NOT_FOUND"

    archived = _create_product(client, admin_headers)
    client.delete(
        f"/api/v1/products/{archived['id']}", headers=admin_headers
    )
    archived_line = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": archived["id"], "quantity": "1", "unit_cost": "1"}],
        ),
    )
    assert archived_line[0] == 422
    assert archived_line[1]["error"]["code"] == "PURCHASE_LINE_INVALID"

    unknown_supplier = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            str(uuid.uuid4()),
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "1"}],
        ),
    )
    assert unknown_supplier[0] == 404

    discount_too_big = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            discount="999",
        ),
    )
    assert discount_too_big[0] == 422

    paid_too_big = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            paid="999",
        ),
    )
    assert paid_too_big[0] == 422


def test_fractional_package_quantity_rejected_at_draft_time(
    client, admin_headers, db
):
    product = _create_product(client, admin_headers)
    unit = _create_purchase_unit(client, admin_headers, product["id"])
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [
                {
                    "product_id": product["id"],
                    "purchase_unit_id": unit["id"],
                    "quantity": "2.5",
                    "unit_cost": "100",
                }
            ],
        ),
    )
    assert code == 422
    assert body["error"]["code"] == "PURCHASE_LINE_INVALID"


# ── List filters ────────────────────────────────────────────────────────


def test_list_filters(client, admin_headers, db):
    product = _create_product(client, admin_headers)
    s1 = _create_supplier(client, admin_headers, name="Filter Sup One")
    s2 = _create_supplier(client, admin_headers, name="Filter Sup Two")

    _, draft = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            s1["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            receive=False,
            note="first draft",
        ),
    )
    _, received = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            s2["id"],
            [{"product_id": product["id"], "quantity": "2", "unit_cost": "10"}],
            paid="20",
        ),
    )

    by_draft = client.get(
        "/api/v1/purchases?status=draft", headers=admin_headers
    ).json()
    assert [i["id"] for i in by_draft["items"]] == [draft["id"]]

    by_received = client.get(
        "/api/v1/purchases?status=received", headers=admin_headers
    ).json()
    assert [i["id"] for i in by_received["items"]] == [received["id"]]

    by_supplier = client.get(
        f"/api/v1/purchases?supplier_id={s1['id']}", headers=admin_headers
    ).json()
    assert [i["id"] for i in by_supplier["items"]] == [draft["id"]]

    by_q = client.get(
        f"/api/v1/purchases?q={received['invoice_number']}",
        headers=admin_headers,
    ).json()
    assert [i["id"] for i in by_q["items"]] == [received["id"]]

    invalid = client.get(
        "/api/v1/purchases?status=bogus", headers=admin_headers
    )
    assert invalid.status_code == 422


# ── RBAC ────────────────────────────────────────────────────────────────


def test_unauthenticated_purchase_endpoints_401(client):
    assert client.get("/api/v1/purchases").status_code == 401


def test_cashier_denied_purchase_scopes(client, cashier_headers):
    assert (
        client.get("/api/v1/purchases", headers=cashier_headers).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/purchases",
            json={"supplier_id": str(uuid.uuid4()), "lines": []},
            headers=cashier_headers,
        ).status_code
        == 403
    )


def test_get_unknown_purchase_404(client, admin_headers):
    resp = client.get(
        f"/api/v1/purchases/{uuid.uuid4()}", headers=admin_headers
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "NOT_FOUND"


# ── QA fix round: supplier detail balance contract ────────────────────


def test_supplier_detail_balance_tracks_purchase_flow(client, admin_headers):
    """GET /suppliers/{id}.balance must mirror the payable exactly.

    Regression for the human-QA Bug 1: the Flutter Supplier Detail
    screen renders this field verbatim, so the API contract pins
    receive -> payment -> cancel, list/detail agreement, and the
    no-negative-balance guarantee.
    """
    product = _create_product(client, admin_headers, quantity="0.000")
    supplier = _create_supplier(client, admin_headers)
    sid = supplier["id"]

    # Receive 10 x 50 = 500 payable, nothing paid.
    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            sid,
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="0.000",
        ),
    )
    assert code == 201, body

    def _detail_balance() -> Decimal:
        resp = client.get(f"/api/v1/suppliers/{sid}", headers=admin_headers)
        assert resp.status_code == 200, resp.text
        return Decimal(str(resp.json()["balance"]))

    assert _detail_balance() == Decimal("500.000")

    # Partial payment 200 -> 300 outstanding.
    pay = client.post(
        f"/api/v1/suppliers/{sid}/payments",
        json={"amount": "200.000"},
        headers=admin_headers,
    )
    assert pay.status_code in (200, 201), pay.text
    assert _detail_balance() == Decimal("300.000")

    # Cancel: payable capped at current balance -> 0, never negative.
    cancel = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert cancel.status_code == 200, cancel.text
    assert _detail_balance() == Decimal("0.000")

    # The list projection agrees with the detail projection.
    lst = client.get(
        "/api/v1/suppliers", params={"q": "Supplier"}, headers=admin_headers
    )
    assert lst.status_code == 200
    item = next(i for i in lst.json()["items"] if i["id"] == sid)
    assert Decimal(str(item["balance"])) == Decimal("0.000")


# ── Optional supplier ──────────────────────────────────────────────────


def test_create_without_supplier_is_allowed(client, admin_headers, db):
    """supplier_id may be omitted — the purchase records NULL, not a
    placeholder supplier, and stock still posts on receive."""
    product = _create_product(client, admin_headers, quantity="0.000")

    code, body = _create_purchase(
        client,
        admin_headers,
        {
            "lines": [
                {"product_id": product["id"], "quantity": "4", "unit_cost": "25"}
            ],
            "paid": "100",
            "receive": True,
        },
    )
    assert code == 201, body
    assert body["supplier_id"] is None
    assert body["supplier_name"] is None
    assert body["status"] == "received"

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(4.0)


def test_integrity_error_on_save_reports_database_constraint_not_stock_conflict(
    client, admin_headers, db, monkeypatch
):
    """Regression: a DB constraint failure on purchase save must NOT be
    reported as a stock conflict.

    Production failure: the live database was still at migration 0035
    (purchases.supplier_id NOT NULL) while a purchase was saved without
    a supplier (sport, qty 10 @ 1500). Postgres raised SQLSTATE 23502 on
    purchases_supplier_id_not_null, and the generic IntegrityError ->
    ConflictError mapping handed clients code CONFLICT — which Flutter
    renders as the stock-conflict copy on a purchase screen. The wire
    contract now is: integrity failure -> DATABASE_CONSTRAINT, never
    CONFLICT, and the whole transaction rolls back untouched.
    """
    def _raise_supplier_not_null(self, obj):
        raise IntegrityError(
            "INSERT INTO purchases (id, invoice_number, supplier_id, ...) "
            "VALUES (?, ?, NULL, ...)",
            {"supplier_id": None},
            Exception(
                'null value in column "supplier_id" of relation '
                '"purchases" violates not-null constraint'
            ),
        )

    monkeypatch.setattr(PurchaseRepository, "create", _raise_supplier_not_null)

    product = _create_product(client, admin_headers, quantity="0.000")
    code, body = _create_purchase(
        client,
        admin_headers,
        {
            # No supplier — exactly what the editor sends for this invoice.
            "lines": [
                {"product_id": product["id"], "quantity": "10", "unit_cost": "1500"}
            ],
            "paid": "0",
            "receive": True,
        },
    )

    assert code == 409, body
    error = body["error"]
    assert error["code"] == "DATABASE_CONSTRAINT"
    assert error["code"] != "CONFLICT"
    assert error["message"] == "A database constraint was violated"
    assert error["details"]["kind"] == "not_null"

    # Atomicity: the failed transaction committed nothing — no purchase
    # document and no stock movement (receive would have added 10).
    listing = client.get("/api/v1/purchases", headers=admin_headers).json()
    assert listing["total"] == 0
    assert float(_stock(db, product["id"]).quantity) == pytest.approx(0.0)
    assert _movements(db, product["id"]) == []


def test_create_with_explicit_null_supplier(client, admin_headers):
    product = _create_product(client, admin_headers, quantity="0.000")
    code, body = _create_purchase(
        client,
        admin_headers,
        {
            "supplier_id": None,
            "lines": [
                {"product_id": product["id"], "quantity": "1", "unit_cost": "10"}
            ],
            "receive": False,
        },
    )
    assert code == 201, body
    assert body["supplier_id"] is None
    assert body["status"] == "draft"


def test_create_with_unknown_supplier_still_404(client, admin_headers):
    product = _create_product(client, admin_headers, quantity="0.000")
    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            str(uuid.uuid4()),
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            receive=False,
        ),
    )
    assert code == 404
    assert body["error"]["code"] == "NOT_FOUND"


def test_no_supplier_unpaid_creates_no_ledger_entry(
    client, admin_headers, db
):
    """A no-supplier purchase with unpaid remainder receives stock but
    never posts a payable — there is no supplier account to post to."""
    product = _create_product(client, admin_headers, quantity="0.000")

    code, body = _create_purchase(
        client,
        admin_headers,
        {
            "lines": [
                {"product_id": product["id"], "quantity": "10", "unit_cost": "50"}
            ],
            "paid": "0",
            "receive": True,
        },
    )
    assert code == 201, body
    assert body["supplier_id"] is None

    db.expire_all()
    entries = list(db.execute(select(SupplierLedgerEntry)).scalars())
    assert entries == []


def test_no_supplier_cancel_reverses_stock_only(client, admin_headers, db):
    product = _create_product(client, admin_headers, quantity="0.000")
    code, body = _create_purchase(
        client,
        admin_headers,
        {
            "lines": [
                {"product_id": product["id"], "quantity": "5", "unit_cost": "20"}
            ],
            "paid": "100",
            "receive": True,
        },
    )
    assert code == 201, body

    cancel = client.post(
        f"/api/v1/purchases/{body['id']}/cancel", headers=admin_headers
    )
    assert cancel.status_code == 200, cancel.text
    assert cancel.json()["status"] == "cancelled"

    p = _stock(db, product["id"])
    assert float(p.quantity) == pytest.approx(0.0)


def test_draft_update_can_clear_supplier(client, admin_headers):
    product = _create_product(client, admin_headers, quantity="0.000")
    supplier = _create_supplier(client, admin_headers)
    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            receive=False,
        ),
    )
    assert code == 201, body
    assert body["supplier_id"] == supplier["id"]

    put = client.put(
        f"/api/v1/purchases/{body['id']}",
        json={"supplier_id": None},
        headers=admin_headers,
    )
    assert put.status_code == 200, put.text
    assert put.json()["supplier_id"] is None


def test_draft_update_omitting_supplier_keeps_it(client, admin_headers):
    product = _create_product(client, admin_headers, quantity="0.000")
    supplier = _create_supplier(client, admin_headers)
    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "1", "unit_cost": "10"}],
            receive=False,
        ),
    )
    assert code == 201, body

    put = client.put(
        f"/api/v1/purchases/{body['id']}",
        json={"note": "supplier untouched"},
        headers=admin_headers,
    )
    assert put.status_code == 200, put.text
    assert put.json()["supplier_id"] == supplier["id"]


def test_existing_purchase_with_supplier_still_works(
    client, admin_headers, db
):
    """Backward-compat: a supplied supplier_id behaves exactly as before
    (payable posted, balance increased)."""
    product = _create_product(client, admin_headers, quantity="0.000")
    supplier = _create_supplier(client, admin_headers)

    code, body = _create_purchase(
        client,
        admin_headers,
        _purchase_payload(
            supplier["id"],
            [{"product_id": product["id"], "quantity": "10", "unit_cost": "50"}],
            paid="0",
        ),
    )
    assert code == 201, body
    assert body["supplier_id"] == supplier["id"]
    assert body["supplier_name"] == supplier["name"]
    assert _balance(db, supplier["id"]) == Decimal("500.000")
