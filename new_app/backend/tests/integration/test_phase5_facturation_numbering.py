"""PostgreSQL concurrency gate for Phase 5 document numbering.

This is the only PostgreSQL integration test for facturation numbering.
The rest of the suite stays on SQLite in-memory by design; these tests
exist to verify the guarantees SQLite physically cannot reproduce:

- ``SELECT ... FOR UPDATE`` serialization of concurrent first-ever and
  incremental allocations on the same ``(doc_type, year)`` counter row
  (SQLite silently ignores FOR UPDATE and its single-writer engine
  serializes writers anyway, so a lost-update race never occurs there).
- The DB-level backstops under real foreign keys:
  UNIQUE(doc_type, year, number), UNIQUE(doc_type, year) on the counter,
  client FK RESTRICT, line FK CASCADE, product FK SET NULL.
- A rolled-back create leaves NO consumed number on PostgreSQL (the
  savepoint + rollback path where pysqlite behaves differently).

Scenarios (real supermarket_pro_test database, alembic at head):

1. N threads create documents simultaneously behind a barrier at the
   allocation point -> every thread commits, the numbers are exactly
   ``FAC-2026-0001 .. 000N`` (unique, sequential, no gaps) and the
   counter's ``last_number`` equals N.
2. A create that fails AFTER allocation rolls the counter increment
   back with it — the retry receives ``0001`` (no gap).
3. The schema guarantees hold on PG: duplicate number / duplicate
   counter are rejected, an invoice client with documents cannot be
   deleted (RESTRICT), deleting a document cascades its lines, deleting
   a product SETs its historical lines' ``product_id`` to NULL.
"""

from __future__ import annotations

import os
import subprocess
import threading
import uuid
from datetime import date
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker

from app.db.session import get_db
from app.main import app
from app.models.catalog import Product
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
    InvoiceDocumentLine,
)
from app.repositories.facturation import InvoiceDocumentRepository
from app.schemas.facturation import (
    InvoiceDocumentCreateRequest,
    InvoiceLineRequest,
)
from app.services.facturation import InvoiceDocumentService
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)

DOC_DATE = date(2026, 3, 15)
YEAR = 2026
THREADS = 6


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


@pytest.fixture()
def pg_env():
    """Schema at head + one invoice client + one product + cleanup."""
    _run_alembic("upgrade head")

    engine = create_engine(
        PG_TEST_URL,
        connect_args={"options": "-c statement_timeout=30000 -c lock_timeout=15000"},
    )
    SessionLocal = sessionmaker(bind=engine, autoflush=False)

    suffix = uuid.uuid4().hex[:8]
    db = SessionLocal()
    try:
        client = InvoiceClient(name=f"pg-facture-client-{suffix}")
        product = Product(
            name=f"pg-facture-product-{suffix}",
            price=Decimal("100.000"),
            vat_rate=19,
        )
        db.add_all([client, product])
        db.commit()
        client_id = client.id
        product_id = product.id
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
        yield {
            "engine": engine,
            "sessionmaker": SessionLocal,
            "client_id": client_id,
            "product_id": product_id,
        }
    finally:
        app.dependency_overrides.clear()
        app.dependency_overrides.update(saved_overrides)

        # ── Cleanup: remove everything this test created ────────────────
        cleanup = SessionLocal()
        try:
            cleanup.execute(
                text(
                    "DELETE FROM audit_logs WHERE entity_id IN "
                    "("
                    "  SELECT id FROM invoice_documents "
                    "  WHERE client_id = CAST(:c AS uuid)"
                    ")"
                ),
                {"c": str(client_id)},
            )
            cleanup.execute(
                text(
                    "DELETE FROM invoice_document_lines "
                    "WHERE document_id IN "
                    "(SELECT id FROM invoice_documents "
                    " WHERE client_id = CAST(:c AS uuid))"
                ),
                {"c": str(client_id)},
            )
            cleanup.execute(
                text("DELETE FROM invoice_documents WHERE client_id = CAST(:c AS uuid)"),
                {"c": str(client_id)},
            )
            cleanup.execute(
                text("DELETE FROM invoice_document_counters WHERE doc_type = 'FAC' AND year = 2026")
            )
            cleanup.execute(
                text("DELETE FROM invoice_clients WHERE id = CAST(:c AS uuid)"),
                {"c": str(client_id)},
            )
            cleanup.execute(
                text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
                {"p": str(product_id)},
            )
            cleanup.commit()
        finally:
            cleanup.close()
            engine.dispose()


def _request(client_id: uuid.UUID, product_id: uuid.UUID):
    return InvoiceDocumentCreateRequest(
        doc_type="FAC",
        client_id=client_id,
        document_date=DOC_DATE,
        payment_method="cash",
        notes="pg numbering",
        lines=[InvoiceLineRequest(product_id=product_id, quantity=1)],
    )


def _serial(number: str) -> int:
    return int(number.rsplit("-", 1)[1])


def test_concurrent_creates_allocate_unique_sequential_numbers(pg_env, monkeypatch):
    """N racing creates -> exactly FAC-2026-0001..000N, counter == N.

    The barrier sits at the very top of ``allocate_number`` so every
    thread enters the ``SELECT ... FOR UPDATE`` race together — the
    loser of each row-lock race must block, re-read the winner's
    committed ``last_number`` (EvalPlanQual) and continue from it.
    """
    SessionLocal = pg_env["sessionmaker"]
    client_id = pg_env["client_id"]
    product_id = pg_env["product_id"]

    barrier = threading.Barrier(THREADS, timeout=30)
    original_allocate = InvoiceDocumentRepository.allocate_number

    def synced_allocate(self, doc_type, year):  # noqa: ANN001
        barrier.wait()
        return original_allocate(self, doc_type, year)

    monkeypatch.setattr(InvoiceDocumentRepository, "allocate_number", synced_allocate)

    numbers: dict[int, str] = {}
    errors: dict[int, str] = {}

    def worker(index: int) -> None:
        session = SessionLocal()
        try:
            document = InvoiceDocumentService(session).create(_request(client_id, product_id))
            numbers[index] = document.number
        except Exception as exc:  # noqa: BLE001
            errors[index] = f"{type(exc).__name__}: {exc}"
        finally:
            session.close()

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(THREADS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)
    assert all(not t.is_alive() for t in threads), "worker thread hung"
    assert not errors, errors
    assert len(numbers) == THREADS

    received = sorted(numbers.values())
    assert received == [f"FAC-2026-{i:04d}" for i in range(1, THREADS + 1)]

    db = SessionLocal()
    try:
        counter = db.execute(
            select(InvoiceDocumentCounter).where(
                InvoiceDocumentCounter.doc_type == "FAC",
                InvoiceDocumentCounter.year == YEAR,
            )
        ).scalar_one()
        assert counter.last_number == THREADS

        stored = (
            db.execute(
                select(InvoiceDocument.number)
                .where(InvoiceDocument.client_id == client_id)
                .order_by(InvoiceDocument.number)
            )
            .scalars()
            .all()
        )
        assert stored == received  # unique, gapless, matches the counter
    finally:
        db.close()


def test_failed_create_never_consumes_a_number(pg_env, monkeypatch):
    """Rollback after allocation: the retry gets 0001 (no gap).

    Exercises the SAVEPOINT + outer-rollback path on PostgreSQL — the
    backend where the seed race path and ``BEGIN`` semantics actually
    differ from SQLite.
    """
    SessionLocal = pg_env["sessionmaker"]
    client_id = pg_env["client_id"]
    product_id = pg_env["product_id"]

    original_create = InvoiceDocumentRepository.create
    calls = {"n": 0}

    def flaky(self, instance):  # noqa: ANN001
        if calls["n"] == 0:
            calls["n"] += 1
            raise RuntimeError("simulated persist failure")
        return original_create(self, instance)

    monkeypatch.setattr(InvoiceDocumentRepository, "create", flaky)

    failing = SessionLocal()
    try:
        with pytest.raises(RuntimeError, match="simulated persist failure"):
            InvoiceDocumentService(failing).create(_request(client_id, product_id))
    finally:
        failing.close()

    db = SessionLocal()
    try:
        assert (
            db.execute(
                select(InvoiceDocumentCounter).where(
                    InvoiceDocumentCounter.doc_type == "FAC",
                    InvoiceDocumentCounter.year == YEAR,
                )
            ).scalar_one_or_none()
            is None
        )  # increment rolled back with the create
        assert (
            db.execute(select(InvoiceDocument).where(InvoiceDocument.client_id == client_id))
            .scalars()
            .all()
            == []
        )
    finally:
        db.close()

    retrying = SessionLocal()
    try:
        document = InvoiceDocumentService(retrying).create(_request(client_id, product_id))
        assert document.number == "FAC-2026-0001"
    finally:
        retrying.close()


def test_db_constraints_hold_on_postgresql(pg_env):
    """UNIQUE number, UNIQUE counter, FK RESTRICT / CASCADE / SET NULL."""
    SessionLocal = pg_env["sessionmaker"]
    client_id = pg_env["client_id"]
    product_id = pg_env["product_id"]

    db = SessionLocal()
    try:
        # ── Two documents: one for CASCADE / SET NULL, one that must
        #    survive everything (RESTRICT + final cleanup) ──────────────
        document = InvoiceDocumentService(db).create(_request(client_id, product_id))
        assert document.number == "FAC-2026-0001"
        kept = InvoiceDocumentService(db).create(_request(client_id, product_id))
        assert kept.number == "FAC-2026-0002"

        # ── UNIQUE(doc_type, year, number) ─────────────────────────────
        db.add(
            InvoiceDocument(
                doc_type="FAC",
                year=YEAR,
                number="FAC-2026-0001",
                document_date=DOC_DATE,
                client_id=client_id,
                payment_method="cash",
            )
        )
        with pytest.raises(IntegrityError):
            db.flush()
        db.rollback()

        # ── UNIQUE(doc_type, year) on the counter ──────────────────────
        db.add(InvoiceDocumentCounter(doc_type="FAC", year=YEAR, last_number=0))
        with pytest.raises(IntegrityError):
            db.flush()
        db.rollback()

        # ── Product FK: ON DELETE SET NULL keeps the historical lines ──
        db.execute(
            text("DELETE FROM products WHERE id = CAST(:p AS uuid)"),
            {"p": str(product_id)},
        )
        lines = db.execute(
            select(InvoiceDocumentLine).where(InvoiceDocumentLine.document_id == document.id)
        ).scalar_one()
        assert lines.product_id is None  # snapshot values keep it valid

        # ── Document FK: ON DELETE CASCADE removes its lines ───────────
        db.execute(
            text("DELETE FROM invoice_documents WHERE id = CAST(:d AS uuid)"),
            {"d": str(document.id)},
        )
        remaining_lines = (
            db.execute(
                select(InvoiceDocumentLine).where(InvoiceDocumentLine.document_id == document.id)
            )
            .scalars()
            .all()
        )
        assert remaining_lines == []

        # ── Client FK: ON DELETE RESTRICT keeps the surviving document ─
        with pytest.raises(IntegrityError):
            db.execute(
                text("DELETE FROM invoice_clients WHERE id = CAST(:c AS uuid)"),
                {"c": str(client_id)},
            )
        db.rollback()

        surviving = db.execute(
            select(InvoiceDocument).where(InvoiceDocument.id == kept.id)
        ).scalar_one_or_none()
        assert surviving is not None
        assert surviving.number == "FAC-2026-0002"
    finally:
        db.close()
