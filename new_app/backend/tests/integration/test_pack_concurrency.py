"""PostgreSQL concurrency gate for the Phase 10 pack component decrement.

This is the only PostgreSQL integration test for pack sales. The rest of
the suite stays on SQLite in-memory by design; this single test exists to
verify the one guarantee SQLite physically cannot reproduce: two
concurrent pack sales racing on ONE guarded ``UPDATE ... WHERE quantity
>= ?`` of the same component row.

Why SQLite cannot verify it
---------------------------
``SaleService`` resolves every cart line READ-ONLY *before* opening the
sale transaction (both threads therefore observe component stock = 10),
then inside the transaction calls ``_decrement_stock`` per component,
which issues::

    UPDATE products SET quantity = quantity - 6
      WHERE id = :id AND quantity >= 6

and raises ``ConflictError`` (409) when ``rowcount != 1``. On PostgreSQL
the loser's UPDATE blocks on the row lock, re-evaluates the predicate
against the version committed by the winner and finds ``4 >= 6`` false,
so the whole losing sale rolls back with zero residue. SQLite has no
row-level locks, so the interleaving that must be proven (winner commits
10 -> 4, loser re-reads 4 and loses the row race) is unverifiable there.

Scenario (one test, real supermarket_pro_test database):
1. Seed one product with 10 units of stock and a pack requiring
   6 base units of it (so one pack fits twice, never three times).
2. Fire two concurrent CASH sales of one pack each, synchronized by
   (a) the existing idempotency fast-path barrier (both threads start
   resolution together) and (b) a test-only barrier placed immediately
   BEFORE the guarded decrement, so both threads have already resolved
   stock = 10 and both enter the row race with the same snapshot.
3. Exactly one commits; the other must be rejected with the existing
   CONFLICT envelope (409) produced by the guarded decrement.
4. Final state invariants: stock == 4.000, exactly one sale carrying
   the pack summary row (product_id IS NULL, pack_id set) plus its
   component row (line_total 0), exactly one PACK_COMPONENT movement,
   and zero residue from the loser.
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

from app.core.exceptions import ConflictError
from app.core.seed import seed_roles_and_permissions
from app.core.security import hash_pin
from app.db.session import get_db
from app.main import app
from app.models.catalog import Pack
from app.models.sale import Sale
from app.models.user import Role, User, UserRole
from app.repositories.sale import SaleRepository
from app.schemas.sale import CreateSaleRequest, SaleLineRequest
from app.services.sale import SaleService

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

INITIAL_STOCK = Decimal("10.000")
UNITS_PER_PACK = Decimal("6.000")
PACK_PRICE = Decimal("100.000")
DEVICE_ID = "POS-PG-PACK"
EXPECTED_FINAL_STOCK = Decimal("4.000")


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
                "name": f"pg-pack-product-{suffix}",
                "barcode": f"PGPACK{suffix}",
                "price": "50.000",
                "cost": "30.000",
                "quantity": str(INITIAL_STOCK),
                "unit": "piece",
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()["id"]


async def _create_pack(token: str, suffix: str, product_id: str) -> str:
    """Seed one pack whose single component needs 6 base units."""
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/packs",
            json={
                "name": f"pg-pack-{suffix}",
                "barcode": f"PGP{suffix}",
                "price": str(PACK_PRICE),
                "components": [
                    {"product_id": product_id, "quantity": str(UNITS_PER_PACK)}
                ],
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 201, resp.text
        return resp.json()["id"]


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/product/pack + login token."""
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

    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-pack-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))
        db.commit()
    finally:
        db.close()

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
        pack_id = uuid.UUID(asyncio.run(_create_pack(token, suffix, str(product_id))))
        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "admin_id": admin_id,
            "product_id": product_id,
            "pack_id": pack_id,
            "token": token,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        cleanup = SessionLocal()
        try:
            cleanup.execute(
                text(
                    "DELETE FROM audit_logs "
                    "WHERE user_id = CAST(:u AS uuid) "
                    "OR entity_id = CAST(:u AS uuid) "
                    "OR entity_id = CAST(:p AS uuid) "
                    "OR entity_id = CAST(:k AS uuid)"
                ),
                {
                    "u": str(admin_id),
                    "p": str(product_id),
                    "k": str(pack_id),
                },
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_payments WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = :d)"
                ),
                {"d": DEVICE_ID},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_lines WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = :d)"
                ),
                {"d": DEVICE_ID},
            )
            cleanup.execute(
                text(
                    "DELETE FROM inventory_movements "
                    "WHERE product_id = CAST(:p AS uuid)"
                ),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text("DELETE FROM sales WHERE device_id = :d"), {"d": DEVICE_ID}
            )
            cleanup.execute(
                text("DELETE FROM pack_items WHERE pack_id = CAST(:k AS uuid)"),
                {"k": str(pack_id)},
            )
            cleanup.execute(
                text("DELETE FROM packs WHERE id = CAST(:k AS uuid)"),
                {"k": str(pack_id)},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
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


def test_concurrent_pack_sales_cannot_overdraw_component_stock_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent pack sales racing on one component row on PG.

    Exactly one commits; the other loses the guarded row race and gets the
    existing CONFLICT envelope; final state proves the loser rolled back
    with zero residue (stock, sale rows and inventory movements).
    """
    SessionLocal = pg_env["sessionmaker"]
    product_id = pg_env["product_id"]
    pack_id = pg_env["pack_id"]

    # (1) Idempotency fast path — both threads start line resolution
    #     together, so both observe component stock = 10.000.
    start_barrier = threading.Barrier(2, timeout=15)
    original_find = SaleRepository.find_by_client_request_id

    def _sync_start(self, client_request_id):
        result = original_find(self, client_request_id)
        start_barrier.wait()
        return result

    monkeypatch.setattr(
        SaleRepository, "find_by_client_request_id", _sync_start
    )

    # (2) Test-only barrier immediately BEFORE the guarded decrement:
    #     both threads have resolved stock = 10.000 and are inside their
    #     own transaction, then race on the single UPDATE.
    decrement_barrier = threading.Barrier(2, timeout=15)
    original_decrement = SaleService._decrement_stock

    def _sync_decrement(self, line):
        decrement_barrier.wait()
        return original_decrement(self, line)

    monkeypatch.setattr(SaleService, "_decrement_stock", _sync_decrement)

    outcomes: dict[str, tuple] = {}

    def worker(tag: str) -> None:
        session = SessionLocal()
        try:
            request = CreateSaleRequest(
                client_request_id=f"pg-pack-{tag}-{uuid.uuid4().hex[:8]}",
                items=[
                    SaleLineRequest(
                        pack_id=pack_id,
                        quantity=Decimal("1"),
                        unit_price=PACK_PRICE,
                        line_discount=Decimal("0"),
                    )
                ],
                payment_method="cash",
                paid=PACK_PRICE,
                device_id=DEVICE_ID,
            )
            try:
                response = SaleService(session).create_sale(request, user=None)
                outcomes[tag] = ("committed", response)
            except ConflictError as exc:
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

    # ── Exactly one commits; the loser lost the guarded row race ───────
    kinds = sorted(kind for kind, _ in outcomes.values())
    assert kinds == ["committed", "rejected"], outcomes

    rejected = next(
        exc for kind, exc in outcomes.values() if kind == "rejected"
    )
    assert rejected.code == "CONFLICT"
    assert rejected.status_code == 409
    assert str(product_id) == rejected.details["product_id"]

    # ── Final DB state ─────────────────────────────────────────────────
    db = SessionLocal()
    try:
        stock = db.execute(
            text(
                "SELECT quantity FROM products WHERE id = CAST(:p AS uuid)"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert stock == EXPECTED_FINAL_STOCK, stock

        sales = db.scalars(
            select(Sale).where(Sale.device_id == DEVICE_ID)
        ).all()
        assert len(sales) == 1, sales

        lines = [
            (line.product_id, line.pack_id, line.quantity, line.line_total)
            for line in sales[0].lines
        ]
        assert len(lines) == 2, lines

        summary = [ln for ln in lines if ln[0] is None]
        components = [ln for ln in lines if ln[0] is not None]
        assert len(summary) == 1 and len(components) == 1, lines
        # Charged pack summary: target is the pack itself (product_id NULL).
        assert summary[0][1] == pack_id
        assert Decimal(str(summary[0][2])) == Decimal("1.000")
        assert Decimal(str(summary[0][3])) == PACK_PRICE
        # Component row carries the exploded demand and is NOT charged.
        assert components[0][0] == product_id
        assert components[0][1] == pack_id
        assert Decimal(str(components[0][2])) == UNITS_PER_PACK
        assert Decimal(str(components[0][3])) == Decimal("0.000")

        movement_types = db.execute(
            text(
                "SELECT movement_type FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) ORDER BY movement_type"
            ),
            {"p": str(product_id)},
        ).all()
        # Product create seeds one ADJUSTMENT; the winner adds exactly one
        # PACK_COMPONENT row — the loser's decrement rolled back entirely.
        assert [row[0] for row in movement_types] == [
            "adjustment",
            "pack_component",
        ], movement_types

        pack = db.get(Pack, pack_id)
        assert pack is not None
        stock_after_pack = db.execute(
            text("SELECT count(*) FROM sale_lines WHERE pack_id = CAST(:k AS uuid)"),
            {"k": str(pack_id)},
        ).scalar_one()
        assert stock_after_pack == 2, stock_after_pack
    finally:
        db.close()
