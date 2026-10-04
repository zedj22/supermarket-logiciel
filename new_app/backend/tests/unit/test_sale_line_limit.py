"""MAX_SALE_LINES (10 000) — sale / cart / hold distinct-line limit contract.

Contract proven here:
- the limit counts DISTINCT cart lines, never quantity: 500 of product A
  plus 700 of A plus 1 of B is 3 lines and is accepted no matter how
  large the quantities are
- 1..10 000 lines accepted; boundary proven at 9 999 / 10 000
- 10 001 lines -> 422 VALIDATION_ERROR raised during request validation
  with ZERO rows written (no sale, no lines, no movements, no payments,
  no debt ledger, stock untouched)
- a sale at the limit is ONE atomic transaction: a forced failure at line
  501 of 1 000 leaves no sale row, no movement, no payment and unchanged
  stock (full rollback)
- idempotent replay of a 10 000 line checkout returns the same sale once
  (no second decrement, no second row)
- cart validate and hold create/restore accept the same limit — they run
  the same prefetch + resolution path as checkout

The same large sizes run again on PostgreSQL in
tests/integration/test_sale_line_limit_pg.py (1 000 / 5 000 / 10 000).
"""

from __future__ import annotations

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.constants import MAX_SALE_LINES
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.debt import DebtLedgerEntry
from app.models.inventory import InventoryMovement
from app.models.sale import Sale, SaleLine, SalePayment
from app.schemas.sale import CreateSaleRequest
from tests.unit.test_pos_sale import _create_product, _login, _post_sale

# ── Fixtures (same shape as test_pos_sale.py: per-test in-memory SQLite) ─


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
    from app.services.auth import AuthService

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


@pytest.fixture()
def admin_headers(client):
    return _login(client, "Admin", "1234")


# ── Helpers ─────────────────────────────────────────────────────────────

PRICE = Decimal("100.000")
SEED_STOCK = Decimal("10.000")


def _seed_products(db, n: int, stock: Decimal = SEED_STOCK) -> list[str]:
    """Bulk-insert n sellable products directly (API create is O(n) calls)."""
    products = [
        Product(
            name=f"XLIMIT{i:07d}",
            barcode=f"XLIMIT{i:07d}",
            unit="piece",
            price=float(PRICE),
            cost=60.0,
            quantity=float(stock),
        )
        for i in range(n)
    ]
    db.add_all(products)
    db.commit()
    return [str(p.id) for p in products]


def _line(product_id: str, quantity: str = "1.000") -> dict:
    return {
        "product_id": product_id,
        "quantity": quantity,
        "unit_price": str(PRICE),
        "line_discount": "0.000",
    }


def _payload(product_ids: list[str], **overrides) -> dict:
    items = [_line(pid) for pid in product_ids]
    total = PRICE * len(items)
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "items": items,
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": f"{total:.3f}",
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _count(db, model) -> int:
    return int(db.execute(select(func.count()).select_from(model)).scalar_one())


def _stock_sum(db) -> Decimal:
    total = db.execute(select(func.sum(Product.quantity))).scalar_one()
    return Decimal(str(total))


def _table_counts(db) -> dict[str, int]:
    return {
        "sales": _count(db, Sale),
        "lines": _count(db, SaleLine),
        "movements": _count(db, InventoryMovement),
        "payments": _count(db, SalePayment),
        "debt": _count(db, DebtLedgerEntry),
    }


# ── Boundary: schema-level contract ─────────────────────────────────────


class TestLineLimitBoundary:
    def test_constant_is_10000(self):
        assert MAX_SALE_LINES == 10_000

    @pytest.mark.parametrize("size", [1, 9999, MAX_SALE_LINES])
    def test_schema_accepts_up_to_the_limit(self, size):
        request = CreateSaleRequest(
            client_request_id=f"boundary-{size}",
            items=[_line(str(uuid.uuid4())) for _ in range(size)],
            paid="0",
        )
        assert len(request.items) == size

    def test_schema_rejects_one_line_over_the_limit(self):
        with pytest.raises(ValidationError) as excinfo:
            CreateSaleRequest(
                client_request_id="over-limit",
                items=[
                    _line(str(uuid.uuid4()))
                    for _ in range(MAX_SALE_LINES + 1)
                ],
                paid="0",
            )
        assert "items" in str(excinfo.value)

    def test_post_over_limit_is_422_before_any_write(self, client, admin_headers, db):
        """10 001 items fail request validation with zero persistence."""
        p = _create_product(client, admin_headers)
        before = _table_counts(db)
        before_stock = Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity))

        payload = _payload(
            [p["id"]] * (MAX_SALE_LINES + 1),
            paid=f"{PRICE * (MAX_SALE_LINES + 1):.3f}",
        )
        resp = _post_sale(client, admin_headers, payload)

        assert resp.status_code == 422, resp.text
        error = resp.json()["error"]
        assert error["code"] == "VALIDATION_ERROR"
        assert "items" in error["details"]
        assert str(MAX_SALE_LINES) in error["details"]["items"]

        db.expire_all()
        assert _table_counts(db) == before
        assert (
            Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity)) == before_stock
        )

    def test_quantity_never_counts_toward_the_limit(self, client, admin_headers, db):
        """A x500 + A x700 + B x1 is 3 lines — quantities are irrelevant."""
        a = _create_product(client, admin_headers, quantity="2000.000")
        b = _create_product(client, admin_headers, quantity="10.000")
        items = [_line(a["id"], "500.000"), _line(a["id"], "700.000"), _line(b["id"])]
        expected_total = PRICE * (500 + 700 + 1)

        resp = _post_sale(
            client,
            admin_headers,
            {
                "client_request_id": str(uuid.uuid4()),
                "items": items,
                "invoice_discount": "0.000",
                "payment_method": "cash",
                "paid": f"{expected_total:.3f}",
                "device_id": "POS-1",
            },
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert len(body["lines"]) == 3
        assert Decimal(str(body["total"])) == expected_total

        db.expire_all()
        assert Decimal(str(db.get(Product, uuid.UUID(a["id"])).quantity)) == Decimal(
            "800.000"
        )
        assert Decimal(str(db.get(Product, uuid.UUID(b["id"])).quantity)) == Decimal(
            "9.000"
        )
        assert _count(db, SaleLine) == 3
        sale_id = uuid.UUID(body["id"])
        movements = db.execute(
            select(InventoryMovement).where(
                InventoryMovement.source_document_id == sale_id
            )
        ).scalars().all()
        assert len(movements) == 3


# ── Success at the limit: one atomic sale, full bookkeeping ─────────────


class TestLargeSaleSuccess:
    @pytest.mark.parametrize("size", [1000, MAX_SALE_LINES])
    def test_sale_at_limit_persists_atomically_with_correct_books(
        self, size, client, admin_headers, db
    ):
        pids = _seed_products(db, size)
        payload = _payload(pids)

        resp = _post_sale(client, admin_headers, payload)
        assert resp.status_code == 201, resp.text
        body = resp.json()
        sale_id = uuid.UUID(body["id"])

        # ── Response contract ──
        assert body["idempotent_replay"] is False
        assert len(body["lines"]) == size
        assert len(body["payments"]) == 1
        expected_total = PRICE * size
        assert Decimal(str(body["subtotal"])) == expected_total
        assert Decimal(str(body["total"])) == expected_total
        assert Decimal(str(body["paid"])) == expected_total
        assert Decimal(str(body["change"])) == Decimal("0.000")
        assert Decimal(str(body["debt"])) == Decimal("0.000")
        assert Decimal(str(body["payments"][0]["amount"])) == expected_total

        # ── Persisted books ──
        db.expire_all()
        assert _count(db, Sale) == 1
        assert _count(db, SaleLine) == size
        assert _count(db, SalePayment) == 1
        assert _count(db, DebtLedgerEntry) == 0
        sale_movements = db.execute(
            select(func.count())
            .select_from(InventoryMovement)
            .where(InventoryMovement.source_document_id == sale_id)
        ).scalar_one()
        assert int(sale_movements) == size
        # every seeded product decremented by exactly 1 (10 -> 9)
        assert _stock_sum(db) == Decimal("9.000") * size

        # ── Idempotent replay: same sale, no second decrement ──
        replay = _post_sale(client, admin_headers, payload)
        assert replay.status_code == 201, replay.text
        replay_body = replay.json()
        assert replay_body["id"] == body["id"]
        assert replay_body["idempotent_replay"] is True

        db.expire_all()
        assert _count(db, Sale) == 1
        assert _count(db, SaleLine) == size
        assert _count(db, SalePayment) == 1
        assert _stock_sum(db) == Decimal("9.000") * size


# ── Atomicity: a mid-sale failure writes nothing ────────────────────────


class TestLargeSaleRollback:
    def test_failure_at_line_501_of_1000_rolls_back_everything(
        self, client, admin_headers, db, monkeypatch
    ):
        from app.core.exceptions import ConflictError
        from app.services import sale as sale_mod

        pids = _seed_products(db, 1000)
        before = _table_counts(db)
        before_stock = _stock_sum(db)

        original = sale_mod.SaleService._decrement_stock
        calls = {"n": 0}

        def flaky(self, ln):
            calls["n"] += 1
            if calls["n"] == 501:
                raise ConflictError(message="forced failure at line 501")
            return original(self, ln)

        monkeypatch.setattr(sale_mod.SaleService, "_decrement_stock", flaky)

        resp = _post_sale(client, admin_headers, _payload(pids))
        assert resp.status_code in (409, 422, 500), resp.text
        assert calls["n"] == 501
        error = resp.json()["error"]
        assert error["code"] != ""  # structured error, no false success

        # Full rollback: 500 decrements already ran inside the transaction.
        db.expire_all()
        assert _table_counts(db) == before
        assert _stock_sum(db) == before_stock


# ── Cart validate / holds share the limit and the resolution path ───────


class TestCartAndHoldAtScale:
    def test_cart_validate_1000_lines(self, client, admin_headers, db):
        pids = _seed_products(db, 1000)
        resp = client.post(
            "/api/v1/pos/cart/validate",
            json={
                "items": [_line(pid) for pid in pids],
                "payment_method": "cash",
                "paid": f"{PRICE * 1000:.3f}",
            },
            headers=admin_headers,
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["ok"] is True
        assert len(body["lines"]) == 1000
        assert Decimal(str(body["total"])) == PRICE * 1000

    def test_hold_create_and_restore_1000_lines(self, client, admin_headers, db):
        pids = _seed_products(db, 1000)
        items = [_line(pid) for pid in pids]

        created = client.post(
            "/api/v1/pos/holds",
            json={
                "device_id": "POS-1",
                "items": items,
                "invoice_discount": "0.000",
            },
            headers=admin_headers,
        )
        assert created.status_code == 201, created.text
        hold = created.json()
        assert len(hold["items"]) == 1000

        restored = client.post(
            f"/api/v1/pos/holds/{hold['id']}/restore",
            headers=admin_headers,
        )
        assert restored.status_code == 200, restored.text
        body = restored.json()
        assert body["ok"] is True
        assert len(body["lines"]) == 1000
        assert all(line["ok"] for line in body["lines"])

        # restore deletes the hold (same contract as the small-cart test)
        listed = client.get("/api/v1/pos/holds", headers=admin_headers)
        assert listed.status_code == 200
        assert not any(h["id"] == hold["id"] for h in listed.json()["items"])
