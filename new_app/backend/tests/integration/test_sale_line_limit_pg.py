"""PostgreSQL integration for the MAX_SALE_LINES (10 000) contract.

The unit layer (tests/unit/test_sale_line_limit.py) proves the boundary
(9 999 / 10 000 / 10 001), the 422-before-any-write guarantee, the full
rollback at line 501 of 1 000 and idempotent replay on SQLite.

This file re-runs the SAME large checkout (1 000 / 5 000 / 10 000 distinct
lines) against the real PostgreSQL test database — the only place where
the PostgreSQL-specific parts of the path are exercised end to end:

- the guarded ``UPDATE ... WHERE quantity >= x RETURNING`` decrement
  (row lock + conditional update semantics, NUMERIC(18,3) arithmetic)
- batched executemany inserts of sale lines and inventory movements
- the selectin re-read that builds a 10 000 line checkout response

Products are seeded with one raw bulk insert (10 000 API creates would be
10 000 round trips); the SALE itself always goes through the real
``POST /api/v1/sales`` endpoint.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import uuid
from decimal import Decimal

import httpx
import pytest
from psycopg2.extras import execute_values
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.core.security import hash_pin
from app.core.seed import seed_roles_and_permissions
from app.db.session import get_db
from app.main import app
from app.models.user import Role, User, UserRole
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

LINES_SIZES = [1000, 5000, 10000]
UNIT_PRICE = Decimal("100.000")
SEEDED_STOCK = "10.000"
EXPECT_STOCK_AFTER = Decimal("9.000")


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


def _post_sale(token: str, payload: dict) -> httpx.Response:
    """POST a checkout through the real endpoint (ASGI, no live server)."""

    async def _run() -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=120.0
        ) as ac:
            return await ac.post(
                "/api/v1/sales",
                json=payload,
                headers={"Authorization": f"Bearer {token}"},
            )

    return asyncio.run(_run())


@pytest.fixture()
def pg_limit_env():
    """Schema at head + seeded admin + login token + routes over PG."""
    _run_alembic("upgrade head")

    engine = create_engine(
        PG_TEST_URL,
        connect_args={
            "options": "-c statement_timeout=60000 -c lock_timeout=15000"
        },
    )
    session_local = sessionmaker(bind=engine)

    suffix = uuid.uuid4().hex[:8]
    admin_id = uuid.uuid4()

    db = session_local()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-limit-admin-{suffix}",
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
        session = session_local()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = _override_get_db

    try:
        token = asyncio.run(_login(admin_id))
        yield {
            "engine": engine,
            "sessionmaker": session_local,
            "admin_id": admin_id,
            "suffix": suffix,
            "token": token,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        # ── Cleanup: everything this test created, by the unique suffix ──
        cleanup = session_local()
        try:
            cleanup.execute(
                text(
                    "DELETE FROM inventory_movements WHERE product_id IN ("
                    "  SELECT id FROM products WHERE name LIKE :prefix)"
                ),
                {"prefix": f"pgl-{suffix}-%"},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_payments WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE client_request_id LIKE :crid)"
                ),
                {"crid": f"pgl-{suffix}-%"},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_lines WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE client_request_id LIKE :crid)"
                ),
                {"crid": f"pgl-{suffix}-%"},
            )
            cleanup.execute(
                text("DELETE FROM sales WHERE client_request_id LIKE :crid"),
                {"crid": f"pgl-{suffix}-%"},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE name LIKE :prefix"),
                {"prefix": f"pgl-{suffix}-%"},
            )
            cleanup.execute(
                text("DELETE FROM audit_logs WHERE user_id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
            )
            cleanup.execute(
                text("DELETE FROM auth_sessions WHERE user_id = CAST(:u AS uuid)"),
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


def _seed_products(env, suffix: str, size: int) -> list[str]:
    """Bulk-insert `size` sellable products (stock 10) through one statement.

    Returns the product ids in creation order (i.e. line order).
    """
    rows = [
        (
            f"pgl-{suffix}-{i:06d}",
            f"PGLIM{suffix}{i:06d}",
            "piece",
            "100.000",
            "60.000",
            SEEDED_STOCK,
        )
        for i in range(size)
    ]
    with env["engine"].raw_connection() as raw:
        with raw.cursor() as cur:
            execute_values(
                cur,
                "INSERT INTO products "
                "(name, barcode, unit, price, cost, quantity) VALUES %s",
                rows,
                page_size=1000,
            )
        raw.commit()

    with env["engine"].connect() as conn:
        result = conn.execute(
            text(
                "SELECT id FROM products WHERE name LIKE :prefix ORDER BY name"
            ),
            {"prefix": f"pgl-{suffix}-%"},
        )
        pids = [str(row.id) for row in result]
    assert len(pids) == size, len(pids)
    return pids


@pytest.mark.parametrize("size", LINES_SIZES)
def test_large_sale_checkout_on_postgresql(pg_limit_env, size):
    """A 1 000 / 5 000 / 10 000 line checkout commits as ONE atomic sale."""
    env = pg_limit_env
    suffix = env["suffix"]
    pids = _seed_products(env, suffix, size)

    expected_total = UNIT_PRICE * size
    payload = {
        "client_request_id": f"pgl-{suffix}-{uuid.uuid4().hex}",
        "items": [
            {
                "product_id": pid,
                "quantity": "1.000",
                "unit_price": "100.000",
                "line_discount": "0.000",
            }
            for pid in pids
        ],
        "invoice_discount": "0.000",
        "payment_method": "cash",
        "paid": f"{expected_total:.3f}",
        "device_id": "POS-PG",
    }

    resp = _post_sale(env["token"], payload)
    assert resp.status_code == 201, resp.text[:2000]
    body = resp.json()
    sale_id = str(body["id"])

    # ── Response contract at scale ──
    assert body["idempotent_replay"] is False
    assert len(body["lines"]) == size
    assert len(body["payments"]) == 1
    assert Decimal(str(body["total"])) == expected_total
    assert Decimal(str(body["paid"])) == expected_total
    assert Decimal(str(body["change"])) == Decimal("0.000")
    assert Decimal(str(body["debt"])) == Decimal("0.000")
    assert Decimal(str(body["payments"][0]["amount"])) == expected_total

    # ── Persisted books on PostgreSQL ──
    db = env["sessionmaker"]()
    try:
        sale_rows = db.execute(
            text(
                "SELECT id, total, paid FROM sales "
                "WHERE client_request_id LIKE :crid"
            ),
            {"crid": f"pgl-{suffix}-%"},
        ).all()
        assert len(sale_rows) == 1, len(sale_rows)
        assert str(sale_rows[0].id) == sale_id
        assert sale_rows[0].total == expected_total
        assert sale_rows[0].paid == expected_total

        counts = {}
        for table in ("sale_lines", "sale_payments"):
            counts[table] = db.execute(
                text(
                    f"SELECT count(*) FROM {table} "
                    "WHERE sale_id = CAST(:s AS uuid)"
                ),
                {"s": sale_id},
            ).scalar_one()
        counts["movements"] = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id IN (SELECT id FROM products "
                "  WHERE name LIKE :prefix) AND movement_type = 'sale'"
            ),
            {"prefix": f"pgl-{suffix}-%"},
        ).scalar_one()
        counts["debt"] = db.execute(
            text(
                "SELECT count(*) FROM debt_ledger_entries "
                "WHERE reference_sale_id = CAST(:s AS uuid)"
            ),
            {"s": sale_id},
        ).scalar_one()
        assert counts == {
            "sale_lines": size,
            "sale_payments": 1,
            "movements": size,
            "debt": 0,
        }, counts

        # Every seeded product decremented 10 -> 9; no exceptions anywhere.
        wrong_stock = db.execute(
            text(
                "SELECT count(*) FROM products WHERE name LIKE :prefix "
                "AND quantity <> :expected"
            ),
            {"prefix": f"pgl-{suffix}-%", "expected": str(EXPECT_STOCK_AFTER)},
        ).scalar_one()
        assert wrong_stock == 0, wrong_stock
        product_count = db.execute(
            text("SELECT count(*) FROM products WHERE name LIKE :prefix"),
            {"prefix": f"pgl-{suffix}-%"},
        ).scalar_one()
        assert product_count == size
    finally:
        db.close()
