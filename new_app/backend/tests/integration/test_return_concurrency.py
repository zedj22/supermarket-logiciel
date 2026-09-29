"""PostgreSQL concurrency gate for Phase 12 (returns / voids).

SQLite physically cannot prove what these three tests prove: PostgreSQL
``SELECT ... FOR UPDATE`` serialization of two writers racing for the SAME
sale row. The decision record §19 fixes the locking order (sale row ->
customer row -> product/variant rows in ascending id) precisely so that
these three races serialize instead of double-restoring stock or double-
forgiving debt.

Test 1 — cumulative ceiling race (GATE 4/11/19)
    Two returns of the whole sold quantity, same sale line, different
    ``client_request_id``. Both clear the idempotency fast path together,
    then race for the sale row lock. Exactly one commits; the loser must
    re-read the winner's committed return rows under the lock and reject
    with RETURN_EXCEEDS_SOLD (details show already_returned = 4).
    Final state: stock restored exactly once, one return document, one
    RETURN movement.

Test 2 — void vs linked return (GATE 10/19)
    Both operations take the sale row lock first. Exactly one wins: if the
    void wins the return sees SALE_ALREADY_VOID, if the return wins the
    void sees SALE_HAS_RETURNS. Either way stock is restored exactly once
    and the sale ends in exactly one of the two legal end states.

Test 3 — duplicate client_request_id race (GATE 16/19)
    Two identical posts with one key. Both must return 201 (one replay),
    and the database must hold exactly ONE return document with exactly
    one stock restoration.
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
from app.core.security import hash_pin
from app.core.seed import seed_roles_and_permissions
from app.db.session import get_db
from app.main import app
from app.models.sale import SaleLine
from app.models.user import Role, User, UserRole
from app.repositories.returns import ReturnRepository
from app.repositories.sale import SaleRepository
from app.schemas.returns import ReturnCreateRequest, ReturnLineRequest, VoidRequest
from app.schemas.sale import CreateSaleRequest, SaleLineRequest
from app.services.returns import ReturnService
from app.services.sale import SaleService
from app.services.void import VoidService
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

SOLD_QTY = Decimal("4.000")
INITIAL_STOCK = Decimal("100.000")
UNIT_PRICE = Decimal("100.000")


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


async def _create_product(token: str, suffix: str) -> str:
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        resp = await ac.post(
            "/api/v1/products",
            json={
                "name": f"pg-return-product-{suffix}",
                "barcode": f"PGRET{suffix}",
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
    """Schema at head + seeded admin + product + one committed sale."""
    _run_alembic("upgrade head")

    engine = create_engine(
        PG_TEST_URL,
        connect_args={
            "options": "-c statement_timeout=30000 -c lock_timeout=15000"
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
            full_name=f"pg-return-admin-{suffix}",
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
        product_id = uuid.UUID(asyncio.run(_create_product(token, suffix)))
        yield {
            "engine": engine,
            "sessionmaker": session_local,
            "admin_id": admin_id,
            "product_id": product_id,
            "token": token,
            "suffix": suffix,
            "device_id": f"pg-return-{suffix}",
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        device = f"pg-return-{suffix}"
        cleanup = session_local()
        try:
            # Audit first (its rows point at the sale and its returns).
            cleanup.execute(
                text(
                    "DELETE FROM audit_logs WHERE entity_type IN ('sale', 'return')"
                    " AND (entity_id IN (SELECT id FROM sales "
                    "     WHERE device_id = CAST(:d AS text))"
                    "  OR entity_id IN (SELECT r.id FROM returns r "
                    "     JOIN sales s ON s.id = r.sale_id "
                    "     WHERE s.device_id = CAST(:d AS text)))"
                ),
                {"d": device},
            )
            cleanup.execute(
                text(
                    "DELETE FROM return_lines WHERE return_id IN ("
                    "  SELECT id FROM returns WHERE sale_id IN ("
                    "    SELECT id FROM sales WHERE device_id = CAST(:d AS text)))"
                ),
                {"d": device},
            )
            cleanup.execute(
                text(
                    "DELETE FROM returns WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = CAST(:d AS text))"
                ),
                {"d": device},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_payments WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = CAST(:d AS text))"
                ),
                {"d": device},
            )
            cleanup.execute(
                text(
                    "DELETE FROM sale_lines WHERE sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = CAST(:d AS text))"
                ),
                {"d": device},
            )
            cleanup.execute(
                text(
                    "DELETE FROM debt_ledger_entries WHERE reference_sale_id IN ("
                    "  SELECT id FROM sales WHERE device_id = CAST(:d AS text))"
                ),
                {"d": device},
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
                    "DELETE FROM sales WHERE device_id = CAST(:d AS text)"
                ),
                {"d": device},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
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


def _sell_all(pg_env) -> dict:
    """One cash sale of SOLD_QTY units; returns the committed sale body."""
    session_local = pg_env["sessionmaker"]
    device_id = f"pg-return-{pg_env['suffix']}"
    session = session_local()
    try:
        response = SaleService(session).create_sale(
            CreateSaleRequest(
                client_request_id=str(uuid.uuid4()),
                items=[
                    SaleLineRequest(
                        product_id=pg_env["product_id"],
                        quantity=SOLD_QTY,
                        unit_price=UNIT_PRICE,
                        line_discount=Decimal("0"),
                    )
                ],
                invoice_discount=Decimal("0"),
                payment_method="cash",
                paid=SOLD_QTY * UNIT_PRICE,
                device_id=device_id,
            ),
            user=None,
        )
        sale_id = response.id
        invoice_number = response.invoice_number
    finally:
        session.close()

    db = session_local()
    try:
        sale_line_id = db.execute(
            select(SaleLine.id).where(SaleLine.sale_id == sale_id)
        ).scalar_one()
    finally:
        db.close()
    return {
        "sale_id": sale_id,
        "sale_line_id": sale_line_id,
        "device_id": device_id,
        "invoice_number": invoice_number,
    }


def _stock_of(pg_env) -> Decimal:
    db = pg_env["sessionmaker"]()
    try:
        return Decimal(
            db.execute(
                text("SELECT quantity FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(pg_env["product_id"])},
            ).scalar_one()
        )
    finally:
        db.close()


def _return_request(sale_info: dict, quantity: Decimal, key: str | None = None):
    return ReturnCreateRequest(
        client_request_id=key or str(uuid.uuid4()),
        sale_id=sale_info["sale_id"],
        reason="defective",
        lines=[
            ReturnLineRequest(sale_line_id=sale_info["sale_line_id"], quantity=quantity)
        ],
    )


def _sync_on_first_call(original, barrier):
    """Patch a repository method so each thread waits at ``barrier`` on its
    FIRST call only.

    The under-lock idempotency re-check calls the same method a second
    time. If that call also waited, the thread holding the sale row lock
    would wait for a thread that is itself blocked on that lock — a
    self-inflicted deadlock the lock timeout would eventually break.
    """
    seen: set[int] = set()
    seen_lock = threading.Lock()

    def _patched(self, *args, **kwargs):
        result = original(self, *args, **kwargs)
        with seen_lock:
            first = threading.get_ident() not in seen
            if first:
                seen.add(threading.get_ident())
        if first:
            barrier.wait()
        return result

    return _patched


def _run_threads(workers: dict) -> dict:
    outcomes: dict = {}

    def wrap(tag, fn):
        try:
            outcomes[tag] = fn()
        except Exception as exc:  # noqa: BLE001 - recorded, asserted below
            outcomes[tag] = exc

    threads = [
        threading.Thread(target=wrap, args=(tag, fn)) for tag, fn in workers.items()
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=45)
    assert all(not t.is_alive() for t in threads), "worker thread hung"
    assert set(outcomes) == set(workers), outcomes
    return outcomes


def test_concurrent_returns_cannot_pass_the_line_ceiling(
    pg_env, monkeypatch
):
    """Two returns of the full sold quantity: one commits, one is capped."""
    sale_info = _sell_all(pg_env)
    assert _stock_of(pg_env) == INITIAL_STOCK - SOLD_QTY

    # Both requests clear the idempotency fast path together, then race
    # for the sale row lock (§19). Test-only instrumentation of a read.
    barrier = threading.Barrier(2, timeout=20)
    monkeypatch.setattr(
        ReturnRepository,
        "find_by_client_request_id",
        _sync_on_first_call(ReturnRepository.find_by_client_request_id, barrier),
    )

    session_local = pg_env["sessionmaker"]

    def worker(tag: str):
        def _run():
            session = session_local()
            try:
                request = _return_request(sale_info, SOLD_QTY)
                return ReturnService(session).post(request, user=None)
            finally:
                session.close()

        return _run

    outcomes = _run_threads({tag: worker(tag) for tag in ("a", "b")})

    successes = [o for o in outcomes.values() if not isinstance(o, Exception)]
    failures = [o for o in outcomes.values() if isinstance(o, Exception)]
    assert len(successes) == 1 and len(failures) == 1, outcomes

    winner = successes[0]
    assert winner.idempotent_replay is False
    assert Decimal(winner.refund_total) == SOLD_QTY * UNIT_PRICE

    loser = failures[0]
    assert isinstance(loser, ConflictError), loser
    assert loser.code == "RETURN_EXCEEDS_SOLD"
    # The loser re-read the winner's committed rows under the row lock:
    # 4 already returned, 4 sold -> 4 + 4 > 4.
    assert loser.details["already_returned"] == str(SOLD_QTY)
    assert loser.details["sold"] == str(SOLD_QTY)
    assert loser.details["requested"] == str(SOLD_QTY)

    # ── Final state: stock restored exactly once, one document ──
    assert _stock_of(pg_env) == INITIAL_STOCK

    db = session_local()
    try:
        returns = db.execute(
            text(
                "SELECT count(*) FROM returns WHERE sale_id = CAST(:s AS uuid)"
            ),
            {"s": str(sale_info["sale_id"])},
        ).scalar_one()
        assert returns == 1, returns

        returned_qty = db.execute(
            text(
                "SELECT coalesce(sum(quantity), 0) FROM return_lines "
                "WHERE sale_line_id = CAST(:l AS uuid)"
            ),
            {"l": str(sale_info["sale_line_id"])},
        ).scalar_one()
        assert Decimal(str(returned_qty)) == SOLD_QTY

        movements = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) AND movement_type = 'return'"
            ),
            {"p": str(pg_env["product_id"])},
        ).scalar_one()
        assert movements == 1, movements
    finally:
        db.close()


def test_void_and_linked_return_are_mutually_exclusive_under_race(
    pg_env, monkeypatch
):
    """Exactly one of {void, return} wins; stock is restored exactly once."""
    sale_info = _sell_all(pg_env)
    assert _stock_of(pg_env) == INITIAL_STOCK - SOLD_QTY

    # Both operations take the sale row lock FIRST (§19); sync them at the
    # door so they hit FOR UPDATE at the same moment.
    barrier = threading.Barrier(2, timeout=20)
    original_lock = SaleRepository.get_for_update

    def _sync_point(self, sale_id):
        barrier.wait()
        return original_lock(self, sale_id)

    monkeypatch.setattr(SaleRepository, "get_for_update", _sync_point)

    session_local = pg_env["sessionmaker"]

    def void_worker():
        session = session_local()
        try:
            return VoidService(session).void_sale(
                sale_info["sale_id"],
                VoidRequest(reason="race void"),
                user=None,
            )
        finally:
            session.close()

    def return_worker():
        session = session_local()
        try:
            return ReturnService(session).post(
                _return_request(sale_info, SOLD_QTY), user=None
            )
        finally:
            session.close()

    outcomes = _run_threads({"void": void_worker, "return": return_worker})

    successes = {t: o for t, o in outcomes.items() if not isinstance(o, Exception)}
    failures = {t: o for t, o in outcomes.items() if isinstance(o, Exception)}
    assert len(successes) == 1 and len(failures) == 1, outcomes

    (winner_tag, winner_result), = successes.items()
    loser_tag, loser = next(iter(failures.items()))
    assert winner_tag != loser_tag
    assert isinstance(loser, ConflictError), loser
    if winner_tag == "void":
        # The return found an already-void sale.
        assert loser.code == "SALE_ALREADY_VOID"
        assert winner_result.sale.status == "void"
    else:
        # The void found a sale that already carries a return.
        assert loser.code == "SALE_HAS_RETURNS"
        assert loser.details["returns"] == [winner_result.return_.return_number]

    # ── Exactly one restoration, in exactly one legal end state ──
    assert _stock_of(pg_env) == INITIAL_STOCK

    db = session_local()
    try:
        status = db.execute(
            text("SELECT status FROM sales WHERE id = CAST(:s AS uuid)"),
            {"s": str(sale_info["sale_id"])},
        ).scalar_one()
        returns = db.execute(
            text(
                "SELECT count(*) FROM returns WHERE sale_id = CAST(:s AS uuid)"
            ),
            {"s": str(sale_info["sale_id"])},
        ).scalar_one()
        assert (status, returns) in (("void", 0), ("completed", 1)), (
            status,
            returns,
        )

        restorations = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) "
                "AND movement_type IN ('sale_void', 'return')"
            ),
            {"p": str(pg_env["product_id"])},
        ).scalar_one()
        assert restorations == 1, restorations
    finally:
        db.close()


def test_duplicate_client_request_id_race_creates_one_return(
    pg_env, monkeypatch
):
    """Two identical posts, one key -> both 201, ONE document, one restore."""
    sale_info = _sell_all(pg_env)
    key = str(uuid.uuid4())

    barrier = threading.Barrier(2, timeout=20)
    monkeypatch.setattr(
        ReturnRepository,
        "find_by_client_request_id",
        _sync_on_first_call(ReturnRepository.find_by_client_request_id, barrier),
    )

    session_local = pg_env["sessionmaker"]

    def worker():
        def _run():
            session = session_local()
            try:
                return ReturnService(session).post(
                    _return_request(sale_info, SOLD_QTY, key=key), user=None
                )
            finally:
                session.close()

        return _run

    outcomes = _run_threads({"a": worker(), "b": worker()})

    # Both callers succeed: one original, one idempotent replay.
    assert not any(isinstance(o, Exception) for o in outcomes.values()), outcomes
    results = list(outcomes.values())
    assert sorted(r.idempotent_replay for r in results) == [False, True]
    assert len({r.return_.id for r in results}) == 1
    assert all(Decimal(r.refund_total) == SOLD_QTY * UNIT_PRICE for r in results)

    assert _stock_of(pg_env) == INITIAL_STOCK

    db = session_local()
    try:
        returns = db.execute(
            text(
                "SELECT count(*) FROM returns WHERE client_request_id = :k"
            ),
            {"k": key},
        ).scalar_one()
        assert returns == 1, returns

        movements = db.execute(
            text(
                "SELECT count(*) FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) AND movement_type = 'return'"
            ),
            {"p": str(pg_env["product_id"])},
        ).scalar_one()
        assert movements == 1, movements

        restock = db.execute(
            text(
                "SELECT coalesce(sum(quantity_change), 0) "
                "FROM inventory_movements "
                "WHERE product_id = CAST(:p AS uuid) AND movement_type = 'return'"
            ),
            {"p": str(pg_env["product_id"])},
        ).scalar_one()
        assert Decimal(str(restock)) == SOLD_QTY
    finally:
        db.close()
