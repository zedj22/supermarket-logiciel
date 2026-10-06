"""MAX_SALE_LINES (10 000) — return line limit contract.

Contract proven here:
- ``ReturnCreateRequest.lines`` counts DISTINCT return lines
  1..``MAX_SALE_LINES`` — the SAME cap as ``CreateSaleRequest.items``, so
  every sale the POS can create can be returned in full in ONE return
  document (quantity never counts toward the limit)
- the pre-Phase-17 request cap is gone: 200, 201 and 261 line returns all
  post 201 (nothing stops at 200 anymore)
- 10 001 lines -> 422 VALIDATION_ERROR raised during request validation with
  ZERO rows written (no return, no return lines, no movements, no audit,
  stock untouched)
- a large return restores stock on EVERY requested line and journals one
  RETURN movement per line, with the refund equal to the sum of the lines
- a return is ONE atomic transaction: a forced failure while restoring
  line 151 of 261 leaves no return row, no return lines, no movements and
  unchanged stock (full rollback)
- idempotent replay of a large return returns the same document once
  (no second restore, no second row)
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
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.debt import DebtLedgerEntry
from app.models.inventory import InventoryMovement
from app.models.return_doc import Return, ReturnLine
from app.models.sale import Sale, SaleLine, SalePayment
from app.schemas.returns import ReturnCreateRequest
from tests.unit.test_pos_sale import _create_product, _login, _post_sale

# ── Fixtures (same shape as test_sale_line_limit.py: per-test SQLite) ────


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
            name=f"RLIMIT{i:07d}",
            barcode=f"RLIMIT{i:07d}",
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


def _sale_payload(product_ids: list[str], **overrides) -> dict:
    items = [
        {
            "product_id": pid,
            "quantity": "1.000",
            "unit_price": str(PRICE),
            "line_discount": "0.000",
        }
        for pid in product_ids
    ]
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


def _sell(client, headers, product_ids: list[str]) -> dict:
    """One cash sale over `product_ids` (1 line each, qty 1)."""
    resp = _post_sale(client, headers, _sale_payload(product_ids))
    assert resp.status_code == 201, resp.text
    return resp.json()


def _return_payload(sale: dict, **overrides) -> dict:
    lines = [
        {"sale_line_id": ln["id"], "quantity": "1.000"}
        for ln in sale["lines"]
        if ln.get("product_id")
    ]
    payload = {
        "client_request_id": str(uuid.uuid4()),
        "sale_id": sale["id"],
        "reason": "defective",
        "lines": lines,
        "device_id": "POS-1",
    }
    payload.update(overrides)
    return payload


def _post_return(client, headers, payload: dict):
    return client.post("/api/v1/returns", json=payload, headers=headers)


def _count(db, model) -> int:
    return int(db.execute(select(func.count()).select_from(model)).scalar_one())


def _stock_sum(db) -> Decimal:
    total = db.execute(select(func.sum(Product.quantity))).scalar_one()
    return Decimal(str(total))


def _return_movements(db) -> int:
    return int(
        db.execute(
            select(func.count())
            .select_from(InventoryMovement)
            .where(InventoryMovement.movement_type == "return")
        ).scalar_one()
    )


def _table_counts(db) -> dict[str, int]:
    return {
        "returns": _count(db, Return),
        "return_lines": _count(db, ReturnLine),
        "movements": _count(db, InventoryMovement),
        "audit": _count(db, AuditLog),
        "sales": _count(db, Sale),
        "sale_lines": _count(db, SaleLine),
        "payments": _count(db, SalePayment),
        "debt": _count(db, DebtLedgerEntry),
    }


# ── Boundary: schema-level contract ─────────────────────────────────────


class TestReturnLineLimitBoundary:
    @pytest.mark.parametrize("size", [1, 200, 201, 9999, MAX_SALE_LINES])
    def test_schema_accepts_up_to_the_limit(self, size):
        request = ReturnCreateRequest(
            client_request_id=f"boundary-{size}",
            sale_id=uuid.uuid4(),
            lines=[
                {"sale_line_id": str(uuid.uuid4()), "quantity": "1.000"}
                for _ in range(size)
            ],
        )
        assert len(request.lines) == size

    def test_schema_rejects_one_line_over_the_limit(self):
        with pytest.raises(ValidationError) as excinfo:
            ReturnCreateRequest(
                client_request_id="over-limit",
                sale_id=uuid.uuid4(),
                lines=[
                    {"sale_line_id": str(uuid.uuid4()), "quantity": "1.000"}
                    for _ in range(MAX_SALE_LINES + 1)
                ],
            )
        assert "lines" in str(excinfo.value)

    def test_post_over_limit_is_422_before_any_write(
        self, client, admin_headers, db
    ):
        """10 001 return lines fail request validation with zero persistence."""
        p = _create_product(client, admin_headers)
        sale = _sell(client, admin_headers, [p["id"]])
        line_id = next(ln["id"] for ln in sale["lines"] if ln.get("product_id"))

        before = _table_counts(db)
        before_stock = Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity))

        payload = _return_payload(
            sale,
            lines=[
                {"sale_line_id": line_id, "quantity": "1.000"}
                for _ in range(MAX_SALE_LINES + 1)
            ],
        )
        resp = _post_return(client, admin_headers, payload)

        assert resp.status_code == 422, resp.text
        error = resp.json()["error"]
        assert error["code"] == "VALIDATION_ERROR"
        assert "lines" in error["details"]
        assert str(MAX_SALE_LINES) in error["details"]["lines"]

        db.expire_all()
        assert _table_counts(db) == before
        assert (
            Decimal(str(db.get(Product, uuid.UUID(p["id"])).quantity))
            == before_stock
        )


# ── Success: many lines in ONE return, every line restored ──────────────


class TestLargeReturnSuccess:
    @pytest.mark.parametrize("size", [200, 201, 261, 1000])
    def test_return_of_many_lines_restores_every_line(
        self, size, client, admin_headers, db
    ):
        pids = _seed_products(db, size)
        sale = _sell(client, admin_headers, pids)
        assert len([ln for ln in sale["lines"] if ln.get("product_id")]) == size

        resp = _post_return(client, admin_headers, _return_payload(sale))
        assert resp.status_code == 201, resp.text
        body = resp.json()

        # ── Response contract: one document, N lines, exact refund ──
        assert body["idempotent_replay"] is False
        assert Decimal(str(body["refund_total"])) == PRICE * size
        assert Decimal(str(body["credit_reversed"])) == Decimal("0.000")
        assert Decimal(str(body["cash_pending"])) == PRICE * size

        # ── Persisted books ──
        db.expire_all()
        assert _count(db, Return) == 1
        assert _count(db, ReturnLine) == size
        assert _return_movements(db) == size
        # every seeded product back to its seed stock (10 - 1 + 1)
        assert _stock_sum(db) == SEED_STOCK * size
        # sale snapshot untouched, sale lines untouched
        assert _count(db, Sale) == 1
        assert _count(db, SaleLine) == size

        # ── Detail endpoint renders every line ──
        detail = client.get(
            f"/api/v1/returns/{body['return']['id']}", headers=admin_headers
        )
        assert detail.status_code == 200, detail.text
        assert len(detail.json()["lines"]) == size

    def test_return_at_the_sale_line_limit_end_to_end(
        self, client, admin_headers, db
    ):
        """A sale at MAX_SALE_LINES can be returned in full, one document."""
        pids = _seed_products(db, MAX_SALE_LINES)
        sale = _sell(client, admin_headers, pids)

        resp = _post_return(client, admin_headers, _return_payload(sale))
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert Decimal(str(body["refund_total"])) == PRICE * MAX_SALE_LINES

        db.expire_all()
        assert _count(db, Return) == 1
        assert _count(db, ReturnLine) == MAX_SALE_LINES
        assert _return_movements(db) == MAX_SALE_LINES
        assert _stock_sum(db) == SEED_STOCK * MAX_SALE_LINES

    def test_idempotent_replay_of_a_large_return_restores_once(
        self, client, admin_headers, db
    ):
        pids = _seed_products(db, 261)
        sale = _sell(client, admin_headers, pids)
        payload = _return_payload(sale)

        first = _post_return(client, admin_headers, payload)
        assert first.status_code == 201, first.text
        replay = _post_return(client, admin_headers, payload)
        assert replay.status_code == 201, replay.text
        replay_body = replay.json()
        assert replay_body["return"]["id"] == first.json()["return"]["id"]
        assert replay_body["idempotent_replay"] is True

        db.expire_all()
        assert _count(db, Return) == 1
        assert _count(db, ReturnLine) == 261
        assert _return_movements(db) == 261
        assert _stock_sum(db) == SEED_STOCK * 261


# ── Atomicity: a mid-restore failure writes nothing ─────────────────────


class TestLargeReturnRollback:
    def test_failure_while_restoring_line_151_of_261_rolls_back_everything(
        self, client, admin_headers, db, monkeypatch
    ):
        from app.core.exceptions import ConflictError
        from app.services import returns as returns_mod

        pids = _seed_products(db, 261)
        sale = _sell(client, admin_headers, pids)

        before = _table_counts(db)
        before_stock = _stock_sum(db)

        original = returns_mod.apply_restore
        calls = {"n": 0}

        def flaky(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 151:
                raise ConflictError(message="forced failure at line 151")
            return original(*args, **kwargs)

        monkeypatch.setattr(returns_mod, "apply_restore", flaky)

        resp = _post_return(client, admin_headers, _return_payload(sale))
        assert resp.status_code in (409, 422, 500), resp.text
        assert calls["n"] == 151
        error = resp.json()["error"]
        assert error["code"] != ""  # structured error, no false success

        # Full rollback: the return header + 261 lines were already flushed
        # and 150 stock restores had already run inside the transaction.
        db.expire_all()
        assert _table_counts(db) == before
        assert _stock_sum(db) == before_stock
