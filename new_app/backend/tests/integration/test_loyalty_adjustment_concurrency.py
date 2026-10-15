"""PostgreSQL concurrency gate for the Phase E loyalty adjustment API.

Two tests on the real ``supermarket_pro_test`` database — the guarantees
SQLite physically cannot reproduce (row-level ``SELECT ... FOR UPDATE``
and the append-only ledger's UNIQUE ``source_event_key``):

1. Two concurrent administrative adjustments with DISTINCT idempotency
   keys both apply exactly once — the loser adopts the winner's
   committed account row before doing its own arithmetic, so the balance
   ends at the sum of both (no lost update), with two ledger rows and
   two audit rows.
2. Two concurrent adjustments with the SAME key: one fresh commit, one
   idempotent replay — exactly ONE ledger row, ONE audit row, and the
   balance moves once.  The replay path must never write a second audit
   row either.

The unit suite stays on SQLite in-memory by design; these tests verify
the server-authoritative guarantees behind the /loyalty/adjustment
contract.
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
from app.models.party import Customer
from app.models.user import Role, User, UserRole
from app.repositories.loyalty import LoyaltySettingsRepository
from app.services.loyalty import LoyaltyEngine
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

EACH_POINTS = 25


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


async def _adjust_concurrently(
    customer_id: uuid.UUID, token: str, *, same_key: bool
) -> list[httpx.Response]:
    """Two simultaneous adjustment attempts against the same customer."""
    shared_key = str(uuid.uuid4())

    async def attempt(tag: str) -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            key = shared_key if same_key else (
                f"pg-adjust-{tag}-{uuid.uuid4().hex[:8]}"
            )
            return await ac.post(
                f"/api/v1/customers/{customer_id}/loyalty/adjustment",
                json={
                    "reason": "pg phase E adjustment gate",
                    "client_request_id": key,
                    "points_delta": EACH_POINTS,
                },
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt("a"), attempt("b"))


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/customer/token (no product needed)."""
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

    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-adjust-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        db.add(
            Customer(id=customer_id, name=f"pg-adjust-customer-{suffix}")
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
            "customer_id": customer_id,
            "token": token,
            "suffix": suffix,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

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


def _adjustment_rows(db, customer_id):
    return db.execute(
        text(
            "SELECT points_delta, balance_after_points, source_event_key "
            "FROM loyalty_ledger_entries WHERE event_type = 'adjustment' "
            "AND account_id IN (SELECT id FROM loyalty_accounts "
            "WHERE customer_id = CAST(:c AS uuid)) "
            "ORDER BY created_at"
        ),
        {"c": str(customer_id)},
    ).all()


def _points_balance(db, customer_id) -> Decimal:
    row = db.execute(
        text(
            "SELECT points_balance FROM loyalty_accounts "
            "WHERE customer_id = CAST(:c AS uuid)"
        ),
        {"c": str(customer_id)},
    ).scalar_one_or_none()
    return Decimal(str(row)) if row is not None else Decimal("0")


def _audit_adjustment_count(db, customer_id: uuid.UUID) -> int:
    return db.execute(
        text(
            "SELECT count(*) FROM audit_logs "
            "WHERE action = 'adjustment' "
            "AND entity_type = 'customer' "
            "AND entity_id = CAST(:c AS uuid)"
        ),
        {"c": str(customer_id)},
    ).scalar_one()


def test_concurrent_distinct_adjustments_apply_once_each_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent adjustments, distinct keys: both apply exactly once.

    Both requests pass their idempotency fast path, then race into the
    account row: the loser ADOPTS the winner's committed account before
    its own arithmetic, so the final balance is the sum of both — no
    lost update, two ledger rows, two audit rows.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    token = pg_env["token"]

    # ── Barrier in ensure_settings: both requests have already passed
    #    their distinct-key fast path, then race for the account row.
    #    (Test-only instrumentation.)
    barrier = threading.Barrier(2, timeout=15)
    original_get = LoyaltySettingsRepository.get_singleton

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_get(self, *args, **kwargs)

    monkeypatch.setattr(
        LoyaltySettingsRepository, "get_singleton", _sync_point
    )

    responses = asyncio.run(
        _adjust_concurrently(customer_id, token, same_key=False)
    )
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    assert sorted(r.status_code for r in responses) == [200, 200], bodies
    assert all(r.json()["idempotent_replay"] is False for r in responses)

    db = SessionLocal()
    try:
        rows = _adjustment_rows(db, customer_id)
        assert len(rows) == 2, rows
        assert sorted(r.points_delta for r in rows) == [
            Decimal(str(EACH_POINTS)),
            Decimal(str(EACH_POINTS)),
        ]
        # Serialized application: running balances are 25 then 50.
        assert sorted(r.balance_after_points for r in rows) == [
            Decimal(str(EACH_POINTS)),
            Decimal(str(EACH_POINTS * 2)),
        ]
        assert len({r.source_event_key for r in rows}) == 2

        assert _points_balance(db, customer_id) == Decimal(
            str(EACH_POINTS * 2)
        )
        assert _audit_adjustment_count(db, customer_id) == 2

        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == Decimal(str(EACH_POINTS * 2))
        )
    finally:
        db.close()


def test_same_key_adjustment_race_applies_once_on_postgresql(
    pg_env, monkeypatch
):
    """Two concurrent adjustments with the SAME key: one commit, one replay.

    Both see nothing at the fast path, then race; the unique
    ``source_event_key`` backstop routes the loser to the winner's entry
    — one ledger row, ONE audit row (the replay must not double-audit),
    and the balance moves exactly once.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    token = pg_env["token"]

    barrier = threading.Barrier(2, timeout=15)
    original_get = LoyaltySettingsRepository.get_singleton

    def _sync_point(self, *args, **kwargs):
        barrier.wait()
        return original_get(self, *args, **kwargs)

    monkeypatch.setattr(
        LoyaltySettingsRepository, "get_singleton", _sync_point
    )

    responses = asyncio.run(
        _adjust_concurrently(customer_id, token, same_key=True)
    )
    bodies = [f"{r.status_code}: {r.text}" for r in responses]
    assert sorted(r.status_code for r in responses) == [200, 200], bodies

    flags = sorted(r.json()["idempotent_replay"] for r in responses)
    assert flags == [False, True], bodies

    db = SessionLocal()
    try:
        rows = _adjustment_rows(db, customer_id)
        assert len(rows) == 1, rows
        assert rows[0].points_delta == Decimal(str(EACH_POINTS))
        assert rows[0].source_event_key.startswith("admin_adjust:")

        assert _points_balance(db, customer_id) == Decimal(str(EACH_POINTS))
        assert _audit_adjustment_count(db, customer_id) == 1

        assert (
            LoyaltyEngine(db).reconcile_account(customer_id).points
            == Decimal(str(EACH_POINTS))
        )
    finally:
        db.close()
