"""PostgreSQL concurrency gate for Phase D loyalty settlement.

This is the only PostgreSQL integration test for the Phase D settlement
rules (debt earn, return clawback/restoration, void clawback/restoration).
The unit suite stays on SQLite in-memory by design; these four tests
verify the guarantees SQLite physically cannot reproduce: row-level
``SELECT ... FOR UPDATE`` serialization around the loyalty account and
the append-only ledger's unique ``source_event_key``.

Why SQLite cannot verify this
------------------------------
Every Phase D write happens under the same lock order
(sale/customer -> loyalty account -> stock) and is guarded by:

- the customer row lock in ``DebtService._record`` (distinct payments
  must serialize so each award posts once against the balance it saw);
- the sale row lock in ``ReturnService._post`` / ``VoidService._void``
  (a second concurrent operation must observe the first one's committed
  state before planning its entitlement or hitting the void gate);
- UNIQUE ``source_event_key`` as the final backstop for replays.

SQLite has no row-level locks (``FOR UPDATE`` is silently ignored), so
two writers would both read the pre-race state and both write.

Scenarios (real supermarket_pro_test database, one test each):
1. Two concurrent debt payments with DISTINCT keys both succeed, each
   awards exactly once (2 earn entries, +4 +4, balance == ledger).
2. Two concurrent debt payments with the SAME key: one fresh commit,
   one idempotent replay — one payment row, ONE earn entry.
3. Two concurrent voids of one sale: one 200, one 409 SALE_ALREADY_VOID,
   exactly one clawback entry, stock restored once.
4. Two concurrent partial returns of one sale (3 + 4 of 10): both 201,
   clawbacks sum to the cumulative entitlement of 7/10 of the earn
   (floor applied once at entitlement level), never negative.
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

from app.core.security import hash_pin
from app.core.seed import seed_roles_and_permissions
from app.db.session import get_db
from app.main import app
from app.models.debt import DebtLedgerEntry
from app.models.party import Customer
from app.models.user import Role, User, UserRole
from app.repositories.party import CustomerRepository
from app.repositories.sale import SaleRepository
from app.services.loyalty import LoyaltyEngine
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

INITIAL_DEBT = Decimal("1000.000")
PAY_AMOUNT = Decimal("400.000")       # valid alone and in pair (800 <= 1000)
EACH_EARNED = Decimal("4")            # floor(400 x 0.01)
SELL_QTY = Decimal("10")              # 10 x 100 = 1000.000 gross
UNIT_PRICE = Decimal("100.000")
SEED_POINTS = Decimal("500")
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
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/products",
            json={
                "name": f"pg-settlement-product-{suffix}",
                "barcode": f"PGSET{suffix}",
                "price": str(UNIT_PRICE),
                "cost": "60.000",
                "quantity": str(INITIAL_STOCK),
                "unit": "piece",
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()["id"]


async def _create_cash_sale(
    token: str, product_id: uuid.UUID, customer_id: uuid.UUID
) -> dict:
    """One 1000.000 cash sale (earns floor(1000 x 0.01) = 10 points)."""
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/sales",
            json={
                "client_request_id": str(uuid.uuid4()),
                "items": [
                    {
                        "product_id": str(product_id),
                        "quantity": str(SELL_QTY),
                        "unit_price": str(UNIT_PRICE),
                        "line_discount": "0.000",
                    }
                ],
                "invoice_discount": "0.000",
                "payment_method": "cash",
                "paid": "1000.000",
                "customer_id": str(customer_id),
                "device_id": "POS-PG",
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()


async def _pay_concurrently(
    customer_id: uuid.UUID, token: str, *, same_key: bool = False
) -> list[httpx.Response]:
    """Two simultaneous payment attempts against the same customer."""

    shared_key = str(uuid.uuid4())

    async def attempt(tag: str) -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            crid = shared_key if same_key else (
                f"pg-settle-{tag}-{uuid.uuid4().hex[:8]}"
            )
            return await ac.post(
                f"/api/v1/customers/{customer_id}/pay",
                json={"amount": str(PAY_AMOUNT), "client_request_id": crid},
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt("a"), attempt("b"))


async def _void_concurrently(
    sale_id: uuid.UUID, token: str
) -> list[httpx.Response]:
    async def attempt() -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                f"/api/v1/sales/{sale_id}/void",
                json={"reason": "pg settlement race"},
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt(), attempt())


async def _return_concurrently(
    sale_id: uuid.UUID,
    line_id: uuid.UUID,
    token: str,
    qty_a: str,
    qty_b: str,
) -> list[httpx.Response]:
    async def attempt(quantity: str) -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                "/api/v1/returns",
                json={
                    "client_request_id": str(uuid.uuid4()),
                    "reason": "defective",
                    "sale_id": str(sale_id),
                    "lines": [
                        {"sale_line_id": str(line_id), "quantity": quantity}
                    ],
                    "device_id": "POS-PG",
                },
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt(qty_a), attempt(qty_b))


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/customer (debt 1000)/product/token.

    Loyalty settings are reset to the documented defaults so a leftover
    mutation from an earlier test can never change the award math here.
    """
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

    # ── Deterministic loyalty rules for the assertions below ──
    reset = SessionLocal()
    try:
        reset.execute(
            text(
                "UPDATE loyalty_settings "
                "SET points_rate = 0.01, cashback_enabled = false, "
                "  cashback_rate = 1.000, earn_on_debt_settlement = true, "
                "  point_value = 1.000"
            )
        )
        reset.commit()
    finally:
        reset.close()

    # ── Seed roles/permissions, admin, customer with debt 1000 ──
    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-settlement-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        customer = Customer(
            id=customer_id,
            name=f"pg-settlement-customer-{suffix}",
            balance=INITIAL_DEBT,
        )
        db.add(customer)
        db.flush()
        db.add(
            DebtLedgerEntry(
                customer_id=customer_id,
                entry_type="sale",
                amount=INITIAL_DEBT,
                note="phase D settlement gate seed",
            )
        )
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
            "suffix": suffix,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        # ── Cleanup: remove everything this test created ──
        cleanup = SessionLocal()
        try:
            customer_ref = "CAST(:c AS uuid)"
            cleanup.execute(
                text(
                    "DELETE FROM loyalty_ledger_entries WHERE account_id IN ("
                    "  SELECT id FROM loyalty_accounts "
                    f"  WHERE customer_id = {customer_ref})"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM loyalty_accounts "
                    f"WHERE customer_id = {customer_ref}"
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
                    "DELETE FROM return_lines WHERE return_id IN ("
                    "  SELECT id FROM returns "
                    f"  WHERE customer_id = {customer_ref} "
                    "  OR sale_id IN (SELECT id FROM sales "
                    f"  WHERE customer_id = {customer_ref}))"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    f"DELETE FROM returns WHERE customer_id = {customer_ref} "
                    "OR sale_id IN (SELECT id FROM sales "
                    f"WHERE customer_id = {customer_ref})"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM debt_ledger_entries "
                    f"WHERE customer_id = {customer_ref}"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_payments "
                    "WHERE sale_id IN ("
                    "  SELECT id FROM sales "
                    f"  WHERE customer_id = {customer_ref})"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_lines "
                    "WHERE sale_id IN ("
                    "  SELECT id FROM sales "
                    f"  WHERE customer_id = {customer_ref})"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sales "
                    f"WHERE customer_id = {customer_ref}"
                ),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text(f"DELETE FROM customers WHERE id = {customer_ref}"),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text("DELETE FROM audit_logs WHERE user_id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
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


def _loyalty_rows(db, customer_id, event_type: str | None = None):
    sql = (
        "SELECT event_type, points_delta, balance_after_points, "
        "  source_event_key "
        "FROM loyalty_ledger_entries WHERE account_id IN ("
        "  SELECT id FROM loyalty_accounts "
        "  WHERE customer_id = CAST(:c AS uuid))"
    )
    params: dict = {"c": str(customer_id)}
    if event_type is not None:
        sql += " AND event_type = :e"
        params["e"] = event_type
    sql += " ORDER BY created_at"
    return db.execute(text(sql), params).all()


def _points_balance(db, customer_id) -> Decimal:
    row = db.execute(
        text(
            "SELECT points_balance FROM loyalty_accounts "
            "WHERE customer_id = CAST(:c AS uuid)"
        ),
        {"c": str(customer_id)},
    ).scalar_one_or_none()
    return Decimal(str(row)) if row is not None else Decimal("0")


def test_concurrent_distinct_debt_payments_award_once_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent 400.000 payments, distinct keys: both award once.

    The customer row lock serializes them; the loser re-reads the
    winner's committed debt balance before its own overpayment check.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    token = pg_env["token"]

    # ── Barrier at the ENTRY of the customer row lock: both payments
    #    pass their idempotency fast paths first (distinct keys), then
    #    race into FOR UPDATE together.  (Test-only instrumentation.)
    barrier = threading.Barrier(2, timeout=15)
    original_lock = CustomerRepository.get_for_update

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_lock(self, *args, **kwargs)

    monkeypatch.setattr(CustomerRepository, "get_for_update", _sync_point)

    responses = asyncio.run(_pay_concurrently(customer_id, token))
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    assert sorted(r.status_code for r in responses) == [200, 200], bodies

    db = SessionLocal()
    try:
        debt_balance = db.execute(
            text(
                "SELECT balance FROM customers "
                "WHERE id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).scalar_one()
        assert debt_balance == Decimal("200.000"), debt_balance

        payment_rows = db.execute(
            text(
                "SELECT amount FROM debt_ledger_entries "
                "WHERE customer_id = CAST(:c AS uuid) "
                "AND entry_type = 'payment'"
            ),
            {"c": str(customer_id)},
        ).all()
        assert len(payment_rows) == 2, payment_rows

        # Exactly one award per payment, distinct stable source keys.
        earn_rows = _loyalty_rows(db, customer_id, "debt_settlement_earn")
        assert len(earn_rows) == 2, earn_rows
        keys = {r.source_event_key for r in earn_rows}
        assert len(keys) == 2, keys
        assert all(k.startswith("debt_settle:") for k in keys), keys
        assert sorted(r.points_delta for r in earn_rows) == [
            EACH_EARNED,
            EACH_EARNED,
        ]
        assert sorted(r.balance_after_points for r in earn_rows) == [
            EACH_EARNED,
            EACH_EARNED * 2,
        ]

        assert _points_balance(db, customer_id) == EACH_EARNED * 2

        # Ledger-authoritative reconciliation passes on the final state.
        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == EACH_EARNED * 2
        )
    finally:
        db.close()


def test_same_key_debt_payment_race_awards_once_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent payments with the SAME key: one commit, one replay.

    The unique client_request_id backstop routes the loser to the
    winner's entry WITHOUT ever running its own award post — exactly one
    debt_settlement_earn row exists.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    token = pg_env["token"]

    # ── Same barrier: both fast paths see nothing, then both enter the
    #    customer row lock; the loser hits the unique key and replays.
    barrier = threading.Barrier(2, timeout=15)
    original_lock = CustomerRepository.get_for_update

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_lock(self, *args, **kwargs)

    monkeypatch.setattr(CustomerRepository, "get_for_update", _sync_point)

    responses = asyncio.run(
        _pay_concurrently(customer_id, token, same_key=True)
    )
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    assert sorted(r.status_code for r in responses) == [200, 200], bodies

    flags = sorted(r.json()["idempotent_replay"] for r in responses)
    assert flags == [False, True], bodies

    db = SessionLocal()
    try:
        # One payment applied: 1000 - 400.
        debt_balance = db.execute(
            text(
                "SELECT balance FROM customers "
                "WHERE id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).scalar_one()
        assert debt_balance == Decimal("600.000"), debt_balance

        payment_rows = db.execute(
            text(
                "SELECT count(*) FROM debt_ledger_entries "
                "WHERE customer_id = CAST(:c AS uuid) "
                "AND entry_type = 'payment'"
            ),
            {"c": str(customer_id)},
        ).scalar_one()
        assert payment_rows == 1, payment_rows

        # The replay path must never post a second award.
        earn_rows = _loyalty_rows(db, customer_id, "debt_settlement_earn")
        assert len(earn_rows) == 1, earn_rows
        assert earn_rows[0].points_delta == EACH_EARNED
        assert earn_rows[0].source_event_key.startswith("debt_settle:")

        assert _points_balance(db, customer_id) == EACH_EARNED
        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == EACH_EARNED
        )
    finally:
        db.close()


def test_concurrent_double_void_restores_once_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent voids of one sale: one 200, one 409, one clawback.

    The loser of the sale row lock observes the winner's committed
    ``void`` status at the gate BEFORE any loyalty write, so the clawback
    posts exactly once and stock is restored exactly once.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    product_id = pg_env["product_id"]
    token = pg_env["token"]
    suffix = pg_env["suffix"]

    # ── Seed 500 points through the engine, then create the sale
    #    (earns 10 -> balance 510). ──
    seed_db = SessionLocal()
    try:
        LoyaltyEngine(seed_db).post(
            customer_id=customer_id,
            event_type="adjustment",
            source_event_key=f"pg-settle-seed-{suffix}",
            points_delta=SEED_POINTS,
        )
        seed_db.commit()
    finally:
        seed_db.close()

    sale = asyncio.run(_create_cash_sale(token, product_id, customer_id))
    sale_id = uuid.UUID(sale["id"])

    # ── Barrier at the ENTRY of the sale row lock (before FOR UPDATE):
    #    both requests rendezvous, then race for the lock. ──
    barrier = threading.Barrier(2, timeout=15)
    original_lock = SaleRepository.get_for_update

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_lock(self, *args, **kwargs)

    monkeypatch.setattr(SaleRepository, "get_for_update", _sync_point)

    responses = asyncio.run(_void_concurrently(sale_id, token))
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    statuses = sorted(r.status_code for r in responses)
    assert statuses == [200, 409], bodies

    loser = next(r for r in responses if r.status_code == 409)
    assert loser.json()["error"]["code"] == "SALE_ALREADY_VOID", bodies

    db = SessionLocal()
    try:
        # Exactly one clawback of the 10 earned; 500 + 10 - 10 = 500.
        claw_rows = _loyalty_rows(db, customer_id, "void_clawback")
        assert len(claw_rows) == 1, claw_rows
        assert claw_rows[0].points_delta == Decimal("-10")
        assert claw_rows[0].source_event_key == f"void_clawback:{sale_id}"

        assert _points_balance(db, customer_id) == SEED_POINTS

        status = db.execute(
            text(
                "SELECT status FROM sales WHERE id = CAST(:s AS uuid)"
            ),
            {"s": str(sale_id)},
        ).scalar_one()
        assert status == "void", status

        stock = db.execute(
            text(
                "SELECT quantity FROM products "
                "WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert stock == INITIAL_STOCK, stock  # restored exactly once

        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == SEED_POINTS
        )
    finally:
        db.close()


def test_concurrent_partial_returns_settle_exactly_once_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent partial returns (3 + 4 of 10) of one cash sale.

    Serialized by the sale row lock, each return plans its clawback from
    the OTHER's committed cumulative quantity, so the two entries sum to
    the single entitlement of the returned share: 7/10 of the 10 earned
    points.  Totals are order-independent (floor at entitlement level,
    not per entry).
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    product_id = pg_env["product_id"]
    token = pg_env["token"]
    suffix = pg_env["suffix"]

    # ── Seed 500 points, then the sale (earns 10 -> balance 510). ──
    seed_db = SessionLocal()
    try:
        LoyaltyEngine(seed_db).post(
            customer_id=customer_id,
            event_type="adjustment",
            source_event_key=f"pg-settle-seed-{suffix}",
            points_delta=SEED_POINTS,
        )
        seed_db.commit()
    finally:
        seed_db.close()

    sale = asyncio.run(_create_cash_sale(token, product_id, customer_id))
    sale_id = uuid.UUID(sale["id"])
    line_id = uuid.UUID(sale["lines"][0]["id"])
    pre_db = SessionLocal()
    try:
        assert _points_balance(pre_db, customer_id) == Decimal(510)
    finally:
        pre_db.close()

    # ── Barrier at the ENTRY of the sale row lock: both requests pass
    #    their distinct-key idempotency fast paths, then race. ──
    barrier = threading.Barrier(2, timeout=15)
    original_lock = SaleRepository.get_for_update

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_lock(self, *args, **kwargs)

    monkeypatch.setattr(SaleRepository, "get_for_update", _sync_point)

    responses = asyncio.run(
        _return_concurrently(sale_id, line_id, token, "3.000", "4.000")
    )
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    assert sorted(r.status_code for r in responses) == [201, 201], bodies

    db = SessionLocal()
    try:
        return_rows = db.execute(
            text(
                "SELECT id FROM returns "
                "WHERE sale_id = CAST(:s AS uuid)"
            ),
            {"s": str(sale_id)},
        ).all()
        assert len(return_rows) == 2, return_rows

        # Clawbacks sum to the cumulative entitlement of 7/10 of the
        # earn: floor(10 x 7/10) = 7 — never the sum of two independent
        # floors, never negative.
        claw_rows = _loyalty_rows(db, customer_id, "return_clawback")
        assert len(claw_rows) == 2, claw_rows
        assert len({r.source_event_key for r in claw_rows}) == 2
        assert sum(r.points_delta for r in claw_rows) == Decimal("-7")

        # 510 - 7 = 503; balance never went negative mid-flight.
        assert _points_balance(db, customer_id) == Decimal(503)

        # Stock: -10 sold + 7 returned = 997.
        stock = db.execute(
            text(
                "SELECT quantity FROM products "
                "WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert stock == INITIAL_STOCK - SELL_QTY + Decimal("7"), stock

        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == Decimal(503)
        )
    finally:
        db.close()
