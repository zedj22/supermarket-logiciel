"""Reports / Dashboard ``GROUP BY`` validated by real PostgreSQL.

The unit suite runs on SQLite, which accepts a target-list expression that does
not structurally match its ``GROUP BY``. PostgreSQL does not: it raises

    psycopg2.errors.GroupingError: column "products.name" must appear in the
    GROUP BY clause or be used in an aggregate function

for ``SELECT coalesce(products.name, ...) ... GROUP BY coalesce(products.name)``
as soon as the expression text differs. That is exactly how the §5.8
products/categories aggregation could pass every unit test and still return 500
on the installed backend for ``GET /reports/products``,
``GET /reports/categories`` and ``GET /dashboard``.

These tests execute the real repository statements — no fixtures needed, the
failure is in the SQL shape and PostgreSQL validates it at parse time even with
zero rows — against the guarded ``supermarket_pro_test`` database. Nothing is
written and the production database is never touched.
"""

from __future__ import annotations

from datetime import date, timedelta

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.repositories.report import ReportRepository
from tests.conftest import PG_IS_AVAILABLE, PG_TEST_URL

pytestmark = pytest.mark.skipif(
    not PG_IS_AVAILABLE,
    reason="PostgreSQL test database (supermarket_pro_test) not available",
)


@pytest.fixture(scope="module")
def pg_session():
    engine = create_engine(PG_TEST_URL)
    session = sessionmaker(bind=engine)()
    try:
        yield session
    finally:
        session.rollback()
        session.close()
        engine.dispose()


def _windows():
    today = date(2026, 11, 18)
    return {
        "single day": (today, today),
        "wide range": (today - timedelta(days=365), today),
        "empty future range": (today + timedelta(days=30), today + timedelta(days=60)),
    }


def test_category_rows_execute_on_postgres(pg_session):
    """§5.8 category aggregation must not raise GroupingError on PostgreSQL."""
    repo = ReportRepository(pg_session)
    for label, (date_from, date_to) in _windows().items():
        rows, totals = repo.category_rows(date_from=date_from, date_to=date_to)
        assert isinstance(rows, list), label
        assert "items_sold" in totals, label


def test_product_rows_execute_on_postgres(pg_session):
    """§5.8 product aggregation (Dashboard ``top_products``) on PostgreSQL."""
    repo = ReportRepository(pg_session)
    for label, (date_from, date_to) in _windows().items():
        rows, total, totals = repo.product_rows(date_from=date_from, date_to=date_to)
        assert isinstance(rows, list), label
        assert total >= len(rows), label
        assert "items_sold" in totals, label
