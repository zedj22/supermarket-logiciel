"""Storage & data usage — real PostgreSQL size query (integration).

Uses the guarded ``supermarket_pro_test`` database only. The query is
``SELECT pg_database_size(current_database())`` — read-only, never a
migration, and the production database is never touched.
"""

from __future__ import annotations

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from app.schemas.storage import DATABASE
from app.services.storage import (
    PG_DATABASE_SIZE_SQL,
    assert_read_only_sql,
    measure_database,
)
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
        session.close()
        engine.dispose()


def test_pg_database_size_is_measured_not_estimated(pg_session):
    category = measure_database(pg_session)
    assert category.key == DATABASE
    assert category.available is True, category.reason
    assert category.bytes is not None
    assert category.bytes > 0

    # Cross-check against PostgreSQL's own view of the database size.
    from_view = pg_session.execute(
        text("SELECT pg_database_size(datname) FROM pg_database WHERE datname = current_database()")
    ).scalar()
    assert category.bytes == from_view


def test_pg_size_query_is_a_read_only_select():
    assert_read_only_sql(PG_DATABASE_SIZE_SQL)


def test_pg_measure_is_stable_across_repeated_reads(pg_session):
    """Repeated read-only measurements return the same number."""
    first = measure_database(pg_session)
    second = measure_database(pg_session)
    assert first.available and second.available
    assert first.bytes == second.bytes
