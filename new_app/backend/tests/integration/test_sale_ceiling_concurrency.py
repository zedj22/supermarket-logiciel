"""PostgreSQL concurrency gate for the Phase 9 debt-ceiling fix.

This is the only PostgreSQL integration test for the debt-ceiling gate.
The rest of the suite stays on SQLite in-memory by design; this single
test exists to verify the one guarantee SQLite physically cannot
reproduce: row-level ``SELECT ... FOR UPDATE`` serialization of two
concurrent credit sales against the same customer.

Why SQLite cannot verify FOR UPDATE
-----------------------------------
``SaleService._enforce_debt_ceiling`` re-reads the customer row with
``refresh(..., with_for_update=True)`` inside the sale transaction and
evaluates ``current_balance + new_debt > debt_ceiling`` on that locked
row. The guarantee depends on PostgreSQL READ COMMITTED semantics: the
loser of the row-lock race blocks, then re-reads the row version
committed by the winner and sees the raised balance before applying the
ceiling check.

SQLite cannot reproduce that behavior:
- SQLite has no row-level locks and no ``FOR UPDATE`` (the clause is
  silently ignored), so two writers never serialize on one row.
- There is no "wait for the row lock, then re-read the latest committed
  row version" step, so the exact interleaving that must be proven
  (winner commits balance 600 -> loser re-reads 600 -> rejects with
  DEBT_CEILING_EXCEEDED) is unverifiable on SQLite.

Scenario (one test, real supermarket_pro_test database):
1. Seed one customer with balance 0.000 and debt_ceiling 1000.000, plus
   one product with 1000 units of stock.
2. Fire two concurrent credit sales of 6 units x 100 = 600.000 debt each
   (each individually valid: 0 + 600 <= 1000; combined 1200 > 1000),
   synchronized by a barrier at the idempotency fast path so both threads
   race into the customer row lock together.
3. Exactly one commits (201-equivalent success); the other must fail with
   BusinessRuleError code DEBT_CEILING_EXCEEDED whose details prove the
   loser re-read the winner's committed balance (current_balance =
   600.000) under the row lock.
4. Final state invariants: balance == 600.000, exactly one sale /
   sale line / sale payment / inventory movement / debt ledger entry,
   product stock == 994.000 (loser's decrement rolled back — zero
   residue), balance == ledger projection.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import threading
import uuid
from decimal import Decimal

import httpx
import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.core.exceptions import BusinessRuleError
from app.core.seed import seed_roles_and_permissions
from app.core.security import hash_pin
from app.db.session import get_db
from app.main import app
from app.models.party import Customer
from app.models.user import Role, User, UserRole
from app.repositories.sale import SaleRepository
from app.schemas.sale import CreateSaleRequest, SaleLineRequest
from app.services.sale import SaleService

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

CEILING = Decimal("1000.000")
SELL_QTY = Decimal("6")            # 6 x 100 = 600.000 debt each attempt
UNIT_PRICE = Decimal("100.000")
DEBT_EACH = Decimal("600.000")     # valid alone, over-ceiling in pair
EXPECTED_FINAL_BALANCE = Decimal("600.000")
INITIAL_STOCK = Decimal("1000.000")


def _run_alembic(command: str) -> None:
    """Run an alembic command against the test database."""
    env = {**os.environ, "DATABASE_URL": PG_TEST_URL}
    result = subprocess.run(
        f"python -m alembic {command}",
        shell=True,
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.dirname(__file__), "..", ".."),
        env=env,
    )
    assert result.returncode == 0, f"alembic {command} failed: {result.stderr}"


async def _login(user_id: uuid.UUID) -> str:
    """Authenticate through the real /auth/login endpoint (PG-backed)."""
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/auth/login",
            json={"user_id": str(user_id), "pin": "1234"},
        )
        assert resp.status_code == 200, resp.text
        return resp.json()["access_token"]


async def _create_product(token: str, suffix: str) -> str:
    """Seed one sellable product through the real catalog API."""
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/products",
            json={
                "name": f"pg-ceiling-product-{suffix}",
                "barcode": f"PGCEIL{suffix}",
                "price": "100.000",
                "cost": "60.000",
                "quantity": str(INITIAL_STOCK),
                "unit": "piece",
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()["id"]


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/customer/product + login token."""
    _run_alembic("upgrade head")

    engine = create_engine(
        PG_TEST_URL,
        connect_args={
            "options": "-c statement_timeout=30000 -c lock_timeout=15000"
        },
    )
    SessionLocal = sessionmaker(bind=engine)

    suffix = uuid.uuid4().hex[:8]
    admin_id = uuid.uuid4()
    customer_id = uuid.uuid4()

    # ── Seed roles/permissions, admin, customer (0 / ceiling 1000) ──────
    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-ceiling-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        customer = Customer(
            id=customer_id,
            name=f"pg-ceiling-customer-{suffix}",
            balance=0.0,
            debt_ceiling=float(CEILING),
        )
        db.add(customer)
        db.commit()
    finally:
        db.close()

    # ── Route every request through the PG-backed sessions ──
    saved_overrides = dict(app.dependency_overrides)

    def _override_get_db():
        session = SessionLocal()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = _override_get_db

    try:
        token = asyncio.run(_login(admin_id))
        product_id = uuid.UUID(asyncio.run(_create_product(token, suffix)))
        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "admin_id": admin_id,
            "customer_id": customer_id,
            "product_id": product_id,
            "token": token,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        # ── Cleanup: remove everything this test created ──
        cleanup = SessionLocal()
        try:
            cleanup.execute(
                text(
                    "DELETE FROM audit_logs "
                    "WHERE user_id = CAST(:u AS uuid) "
                    "OR entity_id = CAST(:u AS uuid) "
                    "OR entity_id = CAST(:c AS uuid) "
                    "OR entity_id = CAST(:p AS uuid)"
                ),
                {
                    "u": str(admin_id),
                    "c": str(customer_id),
                    "p": str(product_id),
                },
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_payments "
                    "WHERE sale_id IN ("
                    "  SELECT id FROM sales "
                    "  WHERE customer_id = CAST(:c AS uuid))"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_lines "
                    "WHERE sale_id IN ("
                    "  SELECT id FROM sales "
                    "  WHERE customer_id = CAST(:c AS uuid))"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM inventory_movements "
                    "WHERE product_id = CAST(:p AS uuid)"
                ),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sales "
                    "WHERE customer_id = CAST(:c AS uuid)"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM debt_ledger_entries "
                    "WHERE customer_id = CAST(:c AS uuid)"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text("DELETE FROM customers WHERE id = CAST(:c AS uuid)"),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM auth_sessions "
                    "WHERE user_id = CAST(:u AS uuid)"
                ),
                {"u": str(admin_id)},
            )
            cleanup.execute(
                text("DELETE FROM user_roles WHERE user_id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
            )
            cleanup.execute(
                text("DELETE FROM users WHERE id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
            )
            cleanup.commit()
        finally:
            cleanup.close()
            engine.dispose()


def test_concurrent_credit_sales_cannot_cross_debt_ceiling_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent 600.000-credit sales vs a 1000.000 ceiling on PG.

    Exactly one commits; the other is rejected with DEBT_CEILING_EXCEEDED
    whose details prove the loser re-read the winner's balance under the
    row lock; final state satisfies the balance/ledger/stock invariants
    with zero residue from the loser.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    product_id = pg_env["product_id"]

    # ── Barrier: both attempts must pass the idempotency fast path
    #    together so they race into the customer row lock simultaneously.
    #    (Test-only instrumentation on a read path; no production change.)
    barrier = threading.Barrier(2, timeout=15)
    original_find = SaleRepository.find_by_client_request_id

    def _sync_point(self, client_request_id):
        result = original_find(self, client_request_id)
        barrier.wait()
        return result

    monkeypatch.setattr(
        SaleRepository, "find_by_client_request_id", _sync_point
    )

    request_ids: dict[str, str] = {}
    outcomes: dict[str, tuple] = {}

    def worker(tag: str) -> None:
        session = SessionLocal()
        try:
            request = CreateSaleRequest(
                client_request_id=f"pg-ceiling-{tag}-{uuid.uuid4().hex[:8]}",
                items=[
                    SaleLineRequest(
                        product_id=product_id,
                        quantity=SELL_QTY,
                        unit_price=UNIT_PRICE,
                        line_discount=Decimal("0"),
                    )
                ],
                payment_method="credit",
                paid=Decimal("0"),
                customer_id=customer_id,
                device_id="POS-PG",
            )
            request_ids[tag] = request.client_request_id
            try:
                response = SaleService(session).create_sale(
                    request, user=None
                )
                outcomes[tag] = ("committed", response)
            except BusinessRuleError as exc:
                outcomes[tag] = ("rejected", exc)
        finally:
            session.close()

    threads = [
        threading.Thread(target=worker, args=(tag,)) for tag in ("a", "b")
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)
    assert all(not t.is_alive() for t in threads), "worker thread hung"
    assert set(outcomes) == {"a", "b"}, outcomes

    # ── Exactly one commits, one is rejected by the ceiling gate ──
    kinds = sorted(kind for kind, _ in outcomes.values())
    assert kinds == ["committed", "rejected"], outcomes

    committed_tag = next(t for t, (k, _) in outcomes.items() if k == "committed")
    rejected_tag = next(t for t, (k, _) in outcomes.items() if k == "rejected")
    committed = outcomes[committed_tag][1]
    rejected = outcomes[rejected_tag][1]

    assert committed.idempotent_replay is False
    assert Decimal(str(committed.debt)) == DEBT_EACH

    # ── Loser: the structured business error, contract unchanged ──
    assert rejected.code == "DEBT_CEILING_EXCEEDED"
    assert rejected.status_code == 422
    # Re-read under the row lock: the loser saw the winner's committed
    # balance (600, not 0), proving FOR UPDATE serialization on PostgreSQL.
    assert rejected.details == {
        "customer_id": str(customer_id),
        "current_balance": str(EXPECTED_FINAL_BALANCE),
        "new_debt": str(DEBT_EACH),
        "projected_balance": str(EXPECTED_FINAL_BALANCE + DEBT_EACH),
        "debt_ceiling": str(CEILING),
    }

    # ── Final DB state ──
    db = SessionLocal()
    try:
        balance, ceiling = db.execute(
            text(
                "SELECT balance, debt_ceiling FROM customers "
                "WHERE id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).one()
        assert balance == EXPECTED_FINAL_BALANCE, balance
        assert ceiling == CEILING, ceiling

        sale_rows = db.execute(
            text(
                "SELECT id, client_request_id, total, paid, user_id "
                "FROM sales WHERE customer_id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).all()
        assert len(sale_rows) == 1, sale_rows
        sale_row = sale_rows[0]
        assert str(sale_row.id) == str(committed.id)
        assert sale_row.client_request_id == request_ids[committed_tag]
        assert sale_row.client_request_id != request_ids[rejected_tag]
        assert sale_row.total == DEBT_EACH
        assert sale_row.paid == Decimal("0.000")  # debt = total - paid
        assert sale_row.user_id is None

        counts = {}
        for table in ("sale_lines", "sale_payments"):
            counts[table] = db.execute(
                text(
                    f"SELECT count(*) FROM {table} "
                    "WHERE sale_id IN (SELECT id FROM sales "
                    "WHERE customer_id = CAST(:c AS uuid))"
                ),
                {"c": str(customer_id)},
            ).scalar_one()
        # Product create seeds one ADJUSTMENT movement (create-with-quantity);
        # only the winner's sale may add a SALE movement — the loser's
        # rolled-back decrement must leave no trace.
        counts["sale_movements"] = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) "
                "AND movement_type = 'sale'"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        counts["all_movements"] = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert counts == {
            "sale_lines": 1,
            "sale_payments": 1,
            "sale_movements": 1,
            "all_movements": 2,
        }, counts

        ledger_rows = db.execute(
            text(
                "SELECT entry_type, amount, reference_sale_id "
                "FROM debt_ledger_entries "
                "WHERE customer_id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).all()
        assert len(ledger_rows) == 1, ledger_rows
        assert ledger_rows[0].entry_type == "sale"
        assert ledger_rows[0].amount == DEBT_EACH
        assert str(ledger_rows[0].reference_sale_id) == str(committed.id)

        # Zero residue from the loser: only the winner's 6 units left stock.
        stock = db.execute(
            text(
                "SELECT quantity FROM products WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert stock == INITIAL_STOCK - SELL_QTY, stock
    finally:
        db.close()
