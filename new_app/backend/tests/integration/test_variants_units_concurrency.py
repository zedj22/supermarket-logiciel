"""PostgreSQL concurrency gate for TASK 5 variants/units exclusivity.

Why SQLite cannot verify this
-----------------------------
``ProductVariantService.create`` and ``SellingUnitService.create``
serialize child creation with ``SELECT … FOR UPDATE`` on the product
row (``app.services.catalog._lock_product_row``). The guarantee depends
on PostgreSQL READ COMMITTED semantics: the loser of the row-lock race
blocks, then re-counts the winner's committed child rows before applying
the XOR check. SQLite has no row-level locks / FOR UPDATE, so the exact
interleaving (winner inserts a unit → loser re-counts 1 unit → loser
rejected with PRODUCT_VARIANTS_EXCLUSIVE) is unverifiable there.

Scenario (one test, real supermarket_pro_test database):
1. Seed one plain product (no children).
2. Fire two concurrent POSTs on the same product — one creates a
   variant, one creates a selling unit — synchronized by a barrier at
   the product-row lock so both requests reach it together.
3. Exactly one 201; the other must be 422 with code
   PRODUCT_VARIANTS_EXCLUSIVE.
4. Final state: exactly ONE active child kind on the product.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import uuid

import httpx
import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.core.seed import seed_roles_and_permissions
from app.core.security import hash_pin
from app.db.session import get_db
from app.main import app
from app.models.user import Role, User, UserRole
from app.services import catalog as catalog_module

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

CODE = "PRODUCT_VARIANTS_EXCLUSIVE"


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


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/product + login token; cleanup after."""
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
    product_id = uuid.uuid4()

    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-xor-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        from app.models.catalog import Product

        db.add(
            Product(
                id=product_id,
                name=f"pg-xor-product-{suffix}",
                barcode=f"PGXOR{suffix.upper()}",
                price=10,
                cost=6,
                quantity=50,
            )
        )
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
        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "admin_id": admin_id,
            "product_id": product_id,
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
                    "OR entity_id = CAST(:p AS uuid)"
                ),
                {"u": str(admin_id), "p": str(product_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM auth_sessions "
                    "WHERE user_id = CAST(:u AS uuid)"
                ),
                {"u": str(admin_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM user_roles "
                    "WHERE user_id = CAST(:u AS uuid)"
                ),
                {"u": str(admin_id)},
            )
            # Product delete cascades variants / selling units (FK CASCADE).
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
            )
            cleanup.execute(
                text("DELETE FROM users WHERE id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
            )
            cleanup.commit()
        finally:
            cleanup.close()
            engine.dispose()


async def _race_creates(product_id: uuid.UUID, token: str):
    """One variant create + one selling-unit create, in flight together."""

    async def create_variant() -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                f"/api/v1/products/{product_id}/variants",
                json={"name": "Large"},
                headers={"Authorization": f"Bearer {token}"},
            )

    async def create_unit() -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                f"/api/v1/products/{product_id}/selling-units",
                json={"name": "Box", "multiplier": "12"},
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(create_variant(), create_unit())


def test_concurrent_variant_and_unit_create_serialize_on_postgresql(
    pg_env, monkeypatch
):
    """First variant vs first unit on the same product, simultaneously.

    Exactly one 201; the loser is rejected with PRODUCT_VARIANTS_EXCLUSIVE
    after re-counting the winner's committed row under the product lock.
    """
    SessionLocal = pg_env["sessionmaker"]
    product_id = pg_env["product_id"]
    token = pg_env["token"]

    # ── Barrier: both requests reach the product-row lock together ──
    import threading

    barrier = threading.Barrier(2, timeout=15)
    original_lock = catalog_module._lock_product_row

    def _sync_lock(db, lock_product_id):
        barrier.wait()
        original_lock(db, lock_product_id)

    monkeypatch.setattr(catalog_module, "_lock_product_row", _sync_lock)

    responses = asyncio.run(_race_creates(product_id, token))
    bodies = [f"{r.status_code}: {r.text}" for r in responses]

    statuses = sorted(r.status_code for r in responses)
    assert statuses == [201, 422], f"expected one 201 + one 422: {bodies}"

    loser = next(r for r in responses if r.status_code == 422)
    err = loser.json()["error"]
    assert err["code"] == CODE, bodies

    # ── Final state: exactly one active child kind ──
    db = SessionLocal()
    try:
        active_variants = db.execute(
            text(
                "SELECT COUNT(*) FROM product_variants "
                "WHERE product_id = CAST(:p AS uuid) AND archived_at IS NULL"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        active_units = db.execute(
            text(
                "SELECT COUNT(*) FROM product_selling_units "
                "WHERE product_id = CAST(:p AS uuid) AND archived_at IS NULL"
            ),
            {"p": str(product_id)},
        ).scalar_one()
        assert (active_variants, active_units) in {(1, 0), (0, 1)}, (
            f"exactly one active child kind expected, got "
            f"variants={active_variants} units={active_units}: {bodies}"
        )
    finally:
        db.close()
