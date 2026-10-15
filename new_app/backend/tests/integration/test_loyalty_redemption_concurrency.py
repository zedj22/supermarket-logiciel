"""PostgreSQL concurrency gate for the Phase C loyalty reward revalidation lock.

This is the only PostgreSQL integration test for the redemption
revalidation.  The unit suite stays on SQLite in-memory by design; this
single test verifies the one guarantee SQLite physically cannot
reproduce: row-level ``SELECT ... FOR UPDATE`` serialization of two
CONCURRENT redemptions that both fully spend the same points balance.

Why SQLite cannot verify FOR UPDATE
-----------------------------------
``LoyaltyEngine.revalidate_reward`` re-reads the loyalty account with
``get_or_create_account(for_update=True)`` inside the sale transaction
and evaluates the redemption caps against the CURRENT balance.  The
guarantee depends on PostgreSQL READ COMMITTED semantics: the loser of
the row-lock race blocks, then re-reads the account version committed by
the winner (balance already spent) before applying the caps — so the
second sale can never double-spend points that no longer exist.

SQLite has no row-level locks (``FOR UPDATE`` is silently ignored), so
two writers would both read the pre-spend balance and both redeem.

Scenario (one test, real supermarket_pro_test database):
1. Seed one customer with a loyalty balance of exactly 100 points (ONE
   available reward), plus one product with 1000 units of stock (all
   through the real services).
2. Fire two concurrent cash sales of 10 x 100 = 1000.000, EACH selecting
   a 10% reward (each individually fully valid: 100 points available,
   10% within the default 20% cap), synchronized by a barrier at the
   ENTRY of the in-transaction revalidation — after both previews
   (which both correctly saw one available reward) but before either
   takes the account row lock, so the race is deterministic and the
   loser cannot fail at the unlocked preview.
3. Exactly one commits; the other must fail with a ValidationError whose
   details prove the loser re-read the winner's committed balance under
   the row lock (points_balance = 9, i.e. 100 - 100 + 9 earned, not the
   pre-race 100).
4. Final state invariants: exactly one sale / redeem entry / earn entry,
   account balance == 9 == ledger projection (reconciliation passes),
   stock == 990 (loser's decrement rolled back — zero residue).
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

from app.core.exceptions import ValidationError
from app.core.security import hash_pin
from app.core.seed import seed_roles_and_permissions
from app.db.session import get_db
from app.main import app
from app.models.party import Customer
from app.models.user import Role, User, UserRole
from app.schemas.sale import CreateSaleRequest, SaleLineRequest
from app.services.loyalty import LoyaltyEngine
from app.services.sale import SaleService
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

SEED_POINTS = Decimal("100")
REWARD_PERCENT = Decimal("10")           # each attempt selects one 10% reward
POINTS_COST = Decimal("100")             # ONE reward always costs 100 points
SELL_QTY = Decimal("10")                # 10 x 100 = 1000.000 gross
UNIT_PRICE = Decimal("100.000")
REWARD_DISCOUNT = Decimal("100.000")     # 10% of 1000.000
AMOUNT_DUE = Decimal("900.000")         # 1000 - 100 reward discount
EARNED = Decimal("9")                   # floor(900 x 0.01)
EXPECTED_FINAL_POINTS = Decimal("9")    # 100 - 100 + 9
INITIAL_STOCK = Decimal("1000.000")


def _run_alembic(command: str) -> None:
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
                "name": f"pg-loyalty-product-{suffix}",
                "barcode": f"PGLOY{suffix}",
                "price": str(UNIT_PRICE),
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
    """Schema at head + seeded admin/customer (100 pts)/product + token."""
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

    # ── Seed roles/permissions, admin, customer ─────────────────────────
    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-loyalty-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        customer = Customer(
            id=customer_id,
            name=f"pg-loyalty-customer-{suffix}",
            balance=0.0,
            debt_ceiling=0.0,
        )
        db.add(customer)
        db.flush()
        # Seed the balance through the engine itself (settings singleton +
        # account + adjustment entry, committed).
        LoyaltyEngine(db).post(
            customer_id=customer_id,
            event_type="adjustment",
            source_event_key=f"pg-loyalty-seed-{suffix}",
            points_delta=SEED_POINTS,
        )
        db.commit()
    finally:
        db.close()

    # ── Route every request through the PG-backed sessions ──────────────
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
            "suffix": suffix,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        # ── Cleanup: remove everything this test created ────────────────
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
                    "DELETE FROM inventory_movements "
                    "WHERE product_id = CAST(:p AS uuid)"
                ),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sales "
                    f"WHERE customer_id = {customer_ref}"
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


def test_concurrent_rewards_cannot_double_spend_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent 10% rewards vs a 100-point balance on PG.

    Exactly one commits; the other is rejected by the locked in-transaction
    revalidation whose details prove it re-read the winner's committed
    balance (9) under the row lock; final state satisfies the
    balance/ledger/stock invariants with zero residue from the loser.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    product_id = pg_env["product_id"]

    # ── Barrier at revalidate ENTRY: both previews already ran (both saw
    #    100 points — no post can happen before the barrier releases), and
    #    neither thread holds the account lock yet.  Deterministic race,
    #    no lock-ordering hazard.  (Test-only instrumentation.)
    barrier = threading.Barrier(2, timeout=15)
    original_revalidate = LoyaltyEngine.revalidate_reward

    def _sync_point(self, **kwargs):
        barrier.wait()
        return original_revalidate(self, **kwargs)

    monkeypatch.setattr(
        LoyaltyEngine, "revalidate_reward", _sync_point
    )

    outcomes: dict[str, tuple] = {}

    def worker(tag: str) -> None:
        session = SessionLocal()
        try:
            request = CreateSaleRequest(
                client_request_id=f"pg-loyalty-{tag}-{uuid.uuid4().hex[:8]}",
                items=[
                    SaleLineRequest(
                        product_id=product_id,
                        quantity=SELL_QTY,
                        unit_price=UNIT_PRICE,
                        line_discount=Decimal("0"),
                    )
                ],
                payment_method="cash",
                paid=AMOUNT_DUE,
                customer_id=customer_id,
                loyalty_reward_percent=REWARD_PERCENT,
                device_id="POS-PG",
            )
            try:
                response = SaleService(session).create_sale(
                    request, user=None
                )
                outcomes[tag] = ("committed", response)
            except ValidationError as exc:
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

    # ── Exactly one commits, one is rejected by the locked revalidation ──
    kinds = sorted(kind for kind, _ in outcomes.values())
    assert kinds == ["committed", "rejected"], outcomes

    committed_tag = next(t for t, (k, _) in outcomes.items() if k == "committed")
    rejected_tag = next(t for t, (k, _) in outcomes.items() if k == "rejected")
    committed = outcomes[committed_tag][1]
    rejected = outcomes[rejected_tag][1]

    # ── Winner: the numbers are exactly the approved rules ──
    assert committed.idempotent_replay is False
    assert Decimal(str(committed.total)) == AMOUNT_DUE + REWARD_DISCOUNT
    assert Decimal(str(committed.amount_due)) == AMOUNT_DUE
    assert Decimal(str(committed.loyalty_points_redeemed)) == POINTS_COST
    assert Decimal(str(committed.loyalty_redeemed_value)) == REWARD_DISCOUNT
    assert Decimal(str(committed.loyalty_points_earned)) == EARNED
    assert Decimal(str(committed.debt)) == Decimal("0.000")

    # ── Loser: blocked on the account row lock, then re-read the winner's
    #    committed balance (9 = 100 - 100 + 9), NOT the pre-race 100 —
    #    proving FOR UPDATE serialization on PostgreSQL. ──
    assert rejected.status_code == 422
    assert rejected.details["selected_percent"] == str(REWARD_PERCENT)
    assert rejected.details["points_balance"] == str(EXPECTED_FINAL_POINTS)
    assert rejected.details["available_rewards"] == "0"

    # ── Final DB state ──
    db = SessionLocal()
    try:
        balance = db.execute(
            text(
                "SELECT points_balance FROM loyalty_accounts "
                "WHERE customer_id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).scalar_one()
        assert balance == EXPECTED_FINAL_POINTS, balance

        sale_rows = db.execute(
            text(
                "SELECT id, total, paid, amount_due, loyalty_points_redeemed, "
                "  loyalty_points_earned "
                "FROM sales WHERE customer_id = CAST(:c AS uuid)"
            ),
            {"c": str(customer_id)},
        ).all()
        assert len(sale_rows) == 1, sale_rows
        sale_row = sale_rows[0]
        assert str(sale_row.id) == str(committed.id)
        assert sale_row.total == AMOUNT_DUE + REWARD_DISCOUNT
        assert sale_row.paid == AMOUNT_DUE
        assert sale_row.amount_due == AMOUNT_DUE
        assert sale_row.loyalty_points_redeemed == POINTS_COST
        assert sale_row.loyalty_points_earned == EARNED

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
        counts["sale_movements"] = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) "
                "AND movement_type = 'sale'"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert counts == {
            "sale_lines": 1,
            "sale_payments": 1,
            "sale_movements": 1,
        }, counts

        ledger_rows = db.execute(
            text(
                "SELECT event_type, points_delta, balance_after_points, "
                "  source_event_key, sale_id "
                "FROM loyalty_ledger_entries WHERE account_id IN ("
                "  SELECT id FROM loyalty_accounts "
                "  WHERE customer_id = CAST(:c AS uuid)) "
                "ORDER BY created_at"
            ),
            {"c": str(customer_id)},
        ).all()
        by_type = {r.event_type: r for r in ledger_rows}
        assert set(by_type) == {"adjustment", "redeem", "sale_earn"}, by_type
        assert by_type["adjustment"].points_delta == SEED_POINTS
        assert by_type["redeem"].points_delta == -POINTS_COST
        assert by_type["sale_earn"].points_delta == EARNED
        assert str(by_type["redeem"].sale_id) == str(committed.id)
        assert (
            by_type["redeem"].source_event_key == f"redeem:{committed.id}"
        )
        assert (
            by_type["sale_earn"].source_event_key
            == f"sale_earn:{committed.id}"
        )
        assert (
            by_type["sale_earn"].balance_after_points == EXPECTED_FINAL_POINTS
        )

        # Zero residue from the loser: only the winner's 10 units left.
        stock = db.execute(
            text(
                "SELECT quantity FROM products WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert stock == INITIAL_STOCK - SELL_QTY, stock

        # Ledger-authoritative reconciliation passes on the final state.
        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == EXPECTED_FINAL_POINTS
        )
    finally:
        db.close()
