"""Purchase without a supplier vs the purchases.supplier_id constraint.

Regression for the production save failure (sport, qty 10 @ 1500,
no supplier): the live database was still at migration 0035 while the
API, models and editor all treat the supplier as optional, so saving a
no-supplier purchase raised Postgres SQLSTATE 23502 on
``purchases_supplier_id_not_null``. The generic IntegrityError ->
ConflictError mapping then handed the client code CONFLICT, which
Flutter renders as the stock-conflict copy ("Stock conflict — review
quantities") on a purchase screen.

These tests run against the dedicated supermarket_pro_test database —
the production database is NEVER touched — and everything they do is
rolled back:

1. reproduce the exact failing constraint (supplier_id NOT NULL) and
   assert the translated error is DATABASE_CONSTRAINT, never CONFLICT;
2. verify head (migration 0036) makes supplier_id nullable and a
   NULL-supplier purchase insert succeeds — schema matches the code.
"""

import psycopg2
import pytest
from sqlalchemy.exc import IntegrityError

from app.core.exceptions import translate_db_error
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)


def _connect():
    return psycopg2.connect(PG_TEST_URL)


def _supplier_id_is_nullable(conn) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT is_nullable FROM information_schema.columns "
            "WHERE table_name = 'purchases' AND column_name = 'supplier_id'"
        )
        row = cur.fetchone()
    return row is not None and row[0] == "YES"


def test_head_schema_lets_a_purchase_commit_without_a_supplier():
    """Migration 0036 contract: supplier_id is nullable at head and a
    NULL-supplier purchase insert succeeds (rolled back afterwards)."""
    conn = _connect()
    try:
        assert _supplier_id_is_nullable(conn), (
            "purchases.supplier_id is NOT NULL — migration "
            "0036_purchase_supplier_optional is not applied to the test "
            "database (run: alembic upgrade head)"
        )
        with conn.cursor() as cur:
            # psycopg2 starts the transaction implicitly (autocommit off).
            cur.execute(
                "INSERT INTO purchases (id, invoice_number, supplier_id, "
                "subtotal, discount, total, paid, status, purchase_date, "
                "version, created_at, updated_at) VALUES "
                "('33333333-3333-3333-3333-333333333333', 'PUR-SUPPLIER-OPTIONAL-1', "
                "NULL, 15000.000, 0.000, 15000.000, 0.000, 'draft', now(), 0, "
                "now(), now())"
            )
            cur.execute(
                "SELECT supplier_id FROM purchases WHERE invoice_number = %s",
                ("PUR-SUPPLIER-OPTIONAL-1",),
            )
            assert cur.fetchone()[0] is None
            conn.rollback()  # nothing persists
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM purchases "
                "WHERE invoice_number = 'PUR-SUPPLIER-OPTIONAL-1'"
            )
            assert cur.fetchone()[0] == 0, "verification insert must not persist"
    finally:
        conn.rollback()
        conn.close()


def test_pre_0036_not_null_violation_maps_to_database_constraint_not_conflict():
    """Reproduce the exact failing constraint on the live-schema copy.

    Temporarily restores the pre-0036 state (supplier_id NOT NULL)
    inside a rolled-back transaction, performs the insert the purchase
    editor sends, and asserts:

    * Postgres raises SQLSTATE 23502 on the supplier_id NOT NULL
      constraint (the real failing constraint, not a translated guess);
    * translate_db_error returns DATABASE_CONSTRAINT — so clients can
      never render it as a stock conflict (the production bug).
    """
    conn = _connect()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM purchases WHERE supplier_id IS NULL")
            nulls = cur.fetchone()[0]
        assert nulls == 0, (
            "test DB has NULL-supplier purchases; the temporary "
            "SET NOT NULL would fail — clean the test database first"
        )

        with conn.cursor() as cur:
            # Pre-0036 state (transactional DDL — rolled back below).
            cur.execute("ALTER TABLE purchases ALTER COLUMN supplier_id SET NOT NULL")
            cur.execute("SAVEPOINT before_insert")
            caught = None
            try:
                cur.execute(
                    "INSERT INTO purchases (id, invoice_number, supplier_id, "
                    "subtotal, discount, total, paid, status, purchase_date, "
                    "version, created_at, updated_at) VALUES "
                    "('44444444-4444-4444-4444-444444444444', "
                    "'PUR-SUPPLIER-OPTIONAL-FAIL', NULL, 15000.000, 0.000, "
                    "15000.000, 0.000, 'draft', now(), 0, now(), now())"
                )
            except psycopg2.errors.NotNullViolation as exc:
                caught = exc
            assert caught is not None, (
                "the pre-0036 schema must reject a NULL supplier_id"
            )
            assert caught.pgcode == "23502"
            primary = caught.diag.message_primary or str(caught)
            assert "supplier_id" in primary
            assert "violates not-null constraint" in primary
            cur.execute("ROLLBACK TO SAVEPOINT before_insert")

            # Exact exception object the service pipeline would translate.
            wrapped = IntegrityError(cur.query or "INSERT INTO purchases", {}, caught)
            app_error = translate_db_error(wrapped)
            assert app_error.code == "DATABASE_CONSTRAINT"
            assert app_error.code != "CONFLICT"
            assert app_error.status_code == 409
            assert app_error.message == "A database constraint was violated"
            assert app_error.details["kind"] == "not_null"
        conn.rollback()  # undoes the temporary SET NOT NULL too
    finally:
        conn.rollback()
        conn.close()

    # Nothing leaked: the column is still nullable after the test.
    conn = _connect()
    try:
        assert _supplier_id_is_nullable(conn)
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM purchases "
                "WHERE invoice_number = 'PUR-SUPPLIER-OPTIONAL-FAIL'"
            )
            assert cur.fetchone()[0] == 0
    finally:
        conn.close()
