"""PostgreSQL concurrency gate for Phase 9 debt payments.

This is the only PostgreSQL integration test for debt payments. The rest of
the suite stays on SQLite in-memory by design; this single test exists to
verify the one guarantee SQLite physically cannot reproduce: row-level
``SELECT ... FOR UPDATE`` serialization of concurrent payments.

Why SQLite cannot verify FOR UPDATE
-----------------------------------
``DebtService._record`` serializes concurrent payments with
``SELECT ... FOR UPDATE`` on the customer row
(``CustomerRepository.get_for_update``). The guarantee depends on
PostgreSQL READ COMMITTED semantics: the loser of the row-lock race blocks,
then re-reads the row version committed by the winner and sees the reduced
balance before applying the overpayment check.

SQLite cannot reproduce that behavior:
- SQLite has no row-level locks and no ``FOR UPDATE``. A second writer gets
  SQLITE_BUSY / database-level serialization instead of blocking on one row
  and re-evaluating after the winner commits.
- There is no "wait for the row lock, then re-read the latest committed
  row version" step, so the exact interleaving that must be proven (winner
  commits balance 300.000 -> loser re-reads 300.000 -> rejects with
  PAYMENT_EXCEEDS_BALANCE) is unverifiable on SQLite.

Scenario (one test, real supermarket_pro_test database):
1. Seed one customer with balance 1000.000 plus a matching sale ledger
   entry (baseline projection == balance == 1000.000).
2. Fire two concurrent POST /api/v1/customers/{id}/pay attempts of
   700.000 each (each individually valid; combined 1400.000 > 1000.000),
   synchronized by a barrier at the idempotency fast-path so both threads
   reach the customer row lock together.
3. Exactly one 200; the other must be the existing structured business
   error: 422 envelope with code PAYMENT_EXCEEDS_BALANCE (no contract or
   error-code changes).
4. Final state invariants: balance == 300.000 (>= 0, no duplicate
   deduction), exactly one immutable payment ledger entry for the one
   success, balance == ledger projection, exactly one audit row with the
   correct actor and balance transition.
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

from app.core.seed import seed_roles_and_permissions
from app.core.security import hash_pin
from app.db.session import get_db
from app.main import app
from app.models.debt import DebtLedgerEntry
from app.models.party import Customer
from app.models.user import Role, User, UserRole
from app.repositories.debt import DebtLedgerEntryRepository

from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

INITIAL_BALANCE = Decimal("1000.000")
PAY_AMOUNT = Decimal("700.000")       # valid alone, overdraws in pair
EXPECTED_FINAL_BALANCE = Decimal("300.000")


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


async def _pay_concurrently(
    customer_id: uuid.UUID, token: str
) -> list[httpx.Response]:
    """Two simultaneous payment attempts against the same customer."""

    async def attempt(tag: str) -> httpx.Response:
        transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test", timeout=30.0
        ) as ac:
            return await ac.post(
                f"/api/v1/customers/{customer_id}/pay",
                json={
                    "amount": str(PAY_AMOUNT),
                    "client_request_id": (
                        f"pg-conc-{tag}-{uuid.uuid4().hex[:8]}"
                    ),
                },
                headers={"Authorization": f"Bearer {token}"},
            )

    return await asyncio.gather(attempt("a"), attempt("b"))


@pytest.fixture()
def pg_env():
    """Schema at head + seeded admin/customer + login token; cleanup after."""
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
    customer_id = uuid.uuid4()

    # ── Seed roles/permissions, admin user, customer with balance 1000 ──
    db = SessionLocal()
    try:
        seed_roles_and_permissions(db)
        role = db.execute(
            select(Role).where(Role.name == "admin")
        ).scalar_one()
        admin = User(
            id=admin_id,
            full_name=f"pg-conc-admin-{suffix}",
            pin_hash=hash_pin("1234"),
        )
        db.add(admin)
        db.flush()
        db.add(UserRole(user_id=admin.id, role_id=role.id))

        customer = Customer(
            id=customer_id,
            name=f"pg-conc-customer-{suffix}",
            balance=INITIAL_BALANCE,
        )
        db.add(customer)
        db.flush()
        db.add(
            DebtLedgerEntry(
                customer_id=customer_id,
                entry_type="sale",
                amount=INITIAL_BALANCE,
                note="phase 9 concurrency gate seed",
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
        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "admin_id": admin_id,
            "customer_id": customer_id,
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
                    "OR entity_id = CAST(:c AS uuid)"
                ),
                {"u": str(admin_id), "c": str(customer_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM debt_ledger_entries "
                    "WHERE customer_id = CAST(:c AS uuid)"
                ),
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
                text(
                    "DELETE FROM user_roles "
                    "WHERE user_id = CAST(:u AS uuid)"
                ),
                {"u": str(admin_id)},
            )
            cleanup.execute(
                text("DELETE FROM customers WHERE id = CAST(:c AS uuid)"),
                {"c": str(customer_id)},
            )
            cleanup.execute(
                text("DELETE FROM users WHERE id = CAST(:u AS uuid)"),
                {"u": str(admin_id)},
            )
            cleanup.commit()
        finally:
            cleanup.close()
            engine.dispose()


def test_concurrent_debt_payments_serialize_on_postgresql(pg_env, monkeypatch):
    """Two concurrent 700.000 payments against a 1000.000 balance on PG.

    Exactly one succeeds; the other is rejected with the existing
    PAYMENT_EXCEEDS_BALANCE structured error; final state satisfies the
    balance/ledger/audit invariants.
    """
    SessionLocal = pg_env["sessionmaker"]
    customer_id = pg_env["customer_id"]
    admin_id = pg_env["admin_id"]
    token = pg_env["token"]

    # ── Barrier: both requests must pass the idempotency fast-path
    #    together so they race into the customer row lock simultaneously.
    #    (Test-only instrumentation on a read path; no production change.)
    barrier = threading.Barrier(2, timeout=15)
    original_find = DebtLedgerEntryRepository.find_by_client_request_id

    def _sync_point(self, client_request_id):
        result = original_find(self, client_request_id)
        barrier.wait()
        return result

    monkeypatch.setattr(
        DebtLedgerEntryRepository,
        "find_by_client_request_id",
        _sync_point,
    )

    # ── Pre-state: balance == projection == 1000.000 ──
    pre = SessionLocal()
    try:
        pre_balance = pre.execute(
            text("SELECT balance FROM customers WHERE id = CAST(:c AS uuid)"),
            {"c": str(customer_id)},
        ).scalar_one()
        pre_projection = DebtLedgerEntryRepository(
            pre
        ).ledger_sum_for_customer(customer_id)
    finally:
        pre.close()
    assert pre_balance == INITIAL_BALANCE
    assert pre_projection == INITIAL_BALANCE

    # ── The race ──
    responses = asyncio.run(_pay_concurrently(customer_id, token))
    bodies = [f"{r.status_code}: {r.text}" for r in responses]

    statuses = sorted(r.status_code for r in responses)
    assert statuses == [200, 422], f"expected one 200 + one 422: {bodies}"

    winner = next(r for r in responses if r.status_code == 200)
    loser = next(r for r in responses if r.status_code == 422)
    w_body = winner.json()
    l_body = loser.json()

    # ── Winner: fresh payment, balance after deduction ──
    assert w_body["entry_type"] == "payment"
    assert Decimal(str(w_body["amount"])) == PAY_AMOUNT
    assert Decimal(str(w_body["balance"])) == EXPECTED_FINAL_BALANCE
    assert w_body["idempotent_replay"] is False
    assert w_body["client_request_id"]

    # ── Loser: the existing structured business error, contract unchanged ──
    err = l_body["error"]
    assert err["code"] == "PAYMENT_EXCEEDS_BALANCE"
    assert err["details"]["amount"] == str(PAY_AMOUNT)
    # Re-read under the row lock: the loser saw the winner's committed
    # balance, proving FOR UPDATE serialization on PostgreSQL.
    assert err["details"]["balance"] == str(EXPECTED_FINAL_BALANCE)

    # ── Final DB state ──
    db = SessionLocal()
    try:
        balance = db.execute(
            text("SELECT balance FROM customers WHERE id = CAST(:c AS uuid)"),
            {"c": str(customer_id)},
        ).scalar_one()
        assert balance == EXPECTED_FINAL_BALANCE, balance
        assert balance >= 0, "balance must never go negative"

        payment_rows = db.execute(
            text(
                "SELECT id, amount, entry_date, created_at, updated_at "
                "FROM debt_ledger_entries "
                "WHERE customer_id = CAST(:c AS uuid) "
                "AND entry_type = 'payment'"
            ),
            {"c": str(customer_id)},
        ).all()
        # One entry per successful payment: the single 200 -> one row.
        assert len(payment_rows) == 1, payment_rows
        row = payment_rows[0]
        assert str(row.id) == str(w_body["id"])
        assert row.amount == PAY_AMOUNT
        # Immutable append-only entry: server defaults present, never UPDATEd.
        assert row.entry_date is not None
        assert row.created_at == row.updated_at

        projection = DebtLedgerEntryRepository(
            db
        ).ledger_sum_for_customer(customer_id)
        assert projection == EXPECTED_FINAL_BALANCE
        assert balance == projection, "balance must equal ledger projection"

        audit_rows = db.execute(
            text(
                "SELECT user_id, action, details FROM audit_logs "
                "WHERE entity_id = CAST(:c AS uuid) AND action = 'payment'"
            ),
            {"c": str(customer_id)},
        ).all()
        assert len(audit_rows) == 1, audit_rows
        assert str(audit_rows[0].user_id) == str(admin_id)
        assert (
            f"balance {INITIAL_BALANCE} -> {EXPECTED_FINAL_BALANCE}"
            in audit_rows[0].details
        )
    finally:
        db.close()
