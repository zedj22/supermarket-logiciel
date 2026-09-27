"""PostgreSQL concurrency gate for Phase 11 purchase receiving.

This is the only PostgreSQL integration test for purchases. The rest of
the suite stays on SQLite in-memory by design; this single test exists
to verify the one guarantee SQLite physically cannot reproduce:
row-level ``SELECT ... FOR UPDATE`` serialization of concurrent receives.

Why SQLite cannot verify FOR UPDATE
-----------------------------------
``PurchaseService._lock`` serializes receive/cancel with
``SELECT ... FOR UPDATE`` on the purchase row
(``PurchaseRepository.get_for_update``). The guarantee depends on
PostgreSQL READ COMMITTED semantics: the loser of the row-lock race
blocks, then re-reads the row version committed by the winner and sees
``status='received'`` before applying the state guard.

SQLite cannot reproduce that behavior:
- SQLite has no row-level locks and no ``FOR UPDATE`` — a second writer
  gets SQLITE_BUSY / database-level serialization instead of blocking
  on one row and re-evaluating after the winner commits.
- There is no "wait for the row lock, then re-read the latest committed
  row version" step, so the exact interleaving that must be proven
  (winner commits received -> loser re-reads status -> 409
  PURCHASE_ALREADY_RECEIVED, never a second stock increase) is
  unverifiable on SQLite.

Scenario (one test, real supermarket_pro_test database):
1. Seed admin + supplier + product (stock 0) + a DRAFT purchase with one
   line (10 units @ 50, unpaid) so receive would bump stock and payable.
2. Fire two concurrent POST /api/v1/purchases/{id}/receive requests,
   synchronized by a barrier at the purchase row lock so both threads
   race for the FOR UPDATE together.
3. Exactly one 200; the other must be the existing structured business
   error: 409 envelope with code PURCHASE_ALREADY_RECEIVED (no contract
   or error-code changes).
4. Final state invariants: stock increased EXACTLY once, exactly one
   purchase inventory movement, supplier balance == unpaid exactly once,
   exactly one authoritative ledger entry, balance == ledger projection,
   exactly one audit receive row.
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
from app.models.catalog import Product
from app.models.party import Supplier
from app.models.user import Role, User, UserRole
from app.repositories.purchase import PurchaseRepository
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

QTY = Decimal("10")
UNIT_COST = Decimal("50")
UNPAID = QTY * UNIT_COST  # paid=0 -> payable == total == 500.000


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


async def _receive_concurrently(
    purchase_id: str, token: str
) -> list[httpx.Response]:
    """Two simultaneous receive attempts against the same purchase."""

    async def attempt() -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                f"/api/v1/purchases/{purchase_id}/receive",
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt(), attempt())


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/supplier/product/draft; cleanup after."""
    _run_alembic("upgrade head")

    engine = create_engine(
        PG_TEST_URL,
        connect_args={
            "options": (
                "-c statement_timeout=30000 -c lock_timeout=15000"
            )
        },
    )
    SessionLocal = sessionmaker(bind=engine)

    suffix = uuid.uuid4().hex[:8]
    admin_id = uuid.uuid4()
    supplier_id = uuid.uuid4()
    product_id = uuid.uuid4()

    # ── Seed roles/permissions, admin, supplier, product ──
    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-recv-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        db.add(
            Supplier(
                id=supplier_id,
                name=f"pg-recv-supplier-{suffix}",
                balance=0,
            )
        )
        db.add(
            Product(
                id=product_id,
                name=f"pg-recv-product-{suffix}",
                barcode=f"PGRCV{suffix}",
                unit="piece",
                price=100,
                cost=0,
                avg_cost=0,
                quantity=0,
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

        # Create the DRAFT purchase through the real API (receive=false)
        # so the document under race is exactly what production produces.
        async def _create_draft() -> tuple[int, dict]:
            transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
            async with httpx.AsyncClient(
                transport=transport, base_url="http://test", timeout=30.0
            ) as ac:
                resp = await ac.post(
                    "/api/v1/purchases",
                    json={
                        "supplier_id": str(supplier_id),
                        "lines": [
                            {
                                "product_id": str(product_id),
                                "quantity": str(QTY),
                                "unit_cost": str(UNIT_COST),
                            }
                        ],
                        "paid": "0",
                        "receive": False,
                        "client_request_id": f"pg-recv-{suffix}",
                    },
                    headers={"Authorization": f"Bearer {token}"},
                )
                return resp.status_code, resp.json()

        code, purchase = asyncio.run(_create_draft())
        assert code == 201, purchase
        assert purchase["status"] == "draft"

        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "admin_id": admin_id,
            "supplier_id": supplier_id,
            "product_id": product_id,
            "purchase_id": purchase["id"],
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
                    "OR entity_id IN ("
                    "  SELECT id FROM purchases WHERE supplier_id = CAST(:s AS uuid)"
                    ") "
                    "OR entity_id = CAST(:s AS uuid) "
                    "OR entity_id = CAST(:p AS uuid)"
                ),
                {"u": str(admin_id), "s": str(supplier_id), "p": str(product_id)},
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
                    "DELETE FROM purchase_lines "
                    "WHERE purchase_id IN ("
                    "  SELECT id FROM purchases WHERE supplier_id = CAST(:s AS uuid)"
                    ")"
                ),
                {"s": str(supplier_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM purchases WHERE supplier_id = CAST(:s AS uuid)"
                ),
                {"s": str(supplier_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM supplier_ledger_entries "
                    "WHERE supplier_id = CAST(:s AS uuid)"
                ),
                {"s": str(supplier_id)},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text("DELETE FROM suppliers WHERE id = CAST(:s AS uuid)"),
                {"s": str(supplier_id)},
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


def test_concurrent_purchase_receives_serialize_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent receives of one draft on PG: exactly one wins.

    The loser must observe the winner's committed status through the
    FOR UPDATE re-read and return PURCHASE_ALREADY_RECEIVED; stock and
    the supplier payable must move exactly once.
    """
    SessionLocal = pg_env["sessionmaker"]
    purchase_id = pg_env["purchase_id"]
    supplier_id = pg_env["supplier_id"]
    product_id = pg_env["product_id"]
    admin_id = pg_env["admin_id"]
    token = pg_env["token"]

    # ── Barrier: both requests must reach the purchase row lock
    #    together so they race into FOR UPDATE simultaneously.
    #    (Test-only instrumentation on the lock path itself; the barrier
    #    fires BEFORE the SELECT so neither thread holds the lock yet.)
    barrier = threading.Barrier(2, timeout=15)
    original_lock = PurchaseRepository.get_for_update

    def _sync_point(self, pid):
        barrier.wait()
        return original_lock(self, pid)

    monkeypatch.setattr(
        PurchaseRepository, "get_for_update", _sync_point
    )

    # ── The race ──
    responses = asyncio.run(_receive_concurrently(purchase_id, token))
    bodies = [f"{r.status_code}: {r.text}" for r in responses]

    statuses = sorted(r.status_code for r in responses)
    assert statuses == [200, 409], f"expected one 200 + one 409: {bodies}"

    winner = next(r for r in responses if r.status_code == 200)
    loser = next(r for r in responses if r.status_code == 409)
    w_body = winner.json()
    l_body = loser.json()

    # ── Winner: document posted once ──
    assert w_body["status"] == "received"
    assert w_body["received_at"] is not None

    # ── Loser: the existing structured business error, contract unchanged ──
    err = l_body["error"]
    assert err["code"] == "PURCHASE_ALREADY_RECEIVED"
    assert err["details"]["purchase_id"] == purchase_id

    # ── Final DB state ──
    db = SessionLocal()
    try:
        # Stock increased EXACTLY once (10 units, no doubling).
        qty = db.execute(
            text(
                "SELECT quantity FROM products WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert qty == 10, qty

        # Exactly one authoritative purchase movement.
        move_count = db.execute(
            text(
                "SELECT COUNT(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) "
                "AND movement_type = 'purchase'"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert move_count == 1, move_count

        # Payable recorded EXACTLY once; balance == ledger projection.
        entries = db.execute(
            text(
                "SELECT entry_type, amount FROM supplier_ledger_entries "
                "WHERE supplier_id = CAST(:s AS uuid)"
            ),
            {"s": str(supplier_id)},
        ).all()
        assert len(entries) == 1, entries
        assert entries[0][0] == "purchase"
        assert entries[0][1] == UNPAID

        balance = db.execute(
            text("SELECT balance FROM suppliers WHERE id = CAST(:s AS uuid)"),
            {"s": str(supplier_id)},
        ).scalar_one()
        assert balance == UNPAID, balance
        assert balance >= 0

        # Exactly one receive audit row with the correct actor.
        audit_rows = db.execute(
            text(
                "SELECT user_id, action FROM audit_logs "
                "WHERE entity_id = CAST(:i AS uuid) AND action = 'receive'"
            ),
            {"i": purchase_id},
        ).all()
        assert len(audit_rows) == 1, audit_rows
        assert str(audit_rows[0].user_id) == str(admin_id)
    finally:
        db.close()
