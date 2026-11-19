"""Shared test fixtures for backend tests.

Unit tests use SQLite in-memory.
Integration tests use a dedicated PostgreSQL test database (supermarket_pro_test).
The production database (supermarket_pro) is NEVER touched by tests.
"""

import atexit
import os
import shutil
import tempfile
import warnings

# Suppress all deprecation warnings during test collection/import
# This must happen BEFORE any other imports
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=PendingDeprecationWarning)

# Set test environment before importing app
os.environ["APP_ENV"] = "testing"
os.environ["APP_SECRET_KEY"] = "test-secret-key"
os.environ["JWT_SECRET_KEY"] = "test-jwt-secret"

# The runtime .env enables LAN_MODE / DISCOVERY_ENABLED (device guard +
# UDP responder) for the live server, but the unit suite runs with both
# OFF so pre-Phase-16 behaviour stays bit-for-bit unchanged (see
# app/core/config.py). Device tests turn the guard back on explicitly with
# monkeypatch.setattr(settings, "LAN_MODE", True).
os.environ.setdefault("LAN_MODE", "0")
os.environ.setdefault("DISCOVERY_ENABLED", "0")

# Phase L0: the license guard must be a complete no-op for the whole
# existing suite (exit criterion of §12 L0).  Guard tests that need
# enforcement flip it explicitly with monkeypatch.setattr(settings,
# "LICENSE_ENFORCEMENT", "trial").
os.environ.setdefault("LICENSE_ENFORCEMENT", "off")

# Phase L1: the Free Trial is created on the first backend start (D5), so
# the suite must run against a throwaway state directory instead of the
# developer's real <backend>/data/license. The path keeps the
# ".../data/license" shape the config contract asserts (see
# test_license_state_dir_resolves_outside_postgres) and is removed at exit.
_LICENSE_STATE_TMP = tempfile.mkdtemp(prefix="supermarket_pro_license_test_")
atexit.register(shutil.rmtree, _LICENSE_STATE_TMP, ignore_errors=True)
os.environ.setdefault(
    "LICENSE_STATE_DIR", os.path.join(_LICENSE_STATE_TMP, "data", "license")
)

# SQLite for unit tests (default)
os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.db.session import get_db
from app.main import app


# ── PostgreSQL test database URL ───────────────────────────────────────

def _get_pg_test_url():
    """Build PostgreSQL test database URL from the original DATABASE_URL.

    Reads the original DATABASE_URL before conftest overrides it to SQLite,
    then replaces the database name with supermarket_pro_test.
    """
    # The original DATABASE_URL is in .env — read it directly
    import pathlib
    env_file = pathlib.Path(__file__).parent.parent / ".env"
    original_url = None
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("DATABASE_URL="):
                original_url = line.split("=", 1)[1].strip()
                break
    if not original_url:
        original_url = os.environ.get("DATABASE_URL", "")
    if "postgresql" not in original_url:
        return None
    return original_url.replace("/supermarket_pro", "/supermarket_pro_test")


PG_TEST_URL = _get_pg_test_url()


def _pg_available():
    """Check if PostgreSQL test database is reachable."""
    if not PG_TEST_URL:
        return False
    try:
        eng = create_engine(PG_TEST_URL)
        with eng.connect() as conn:
            conn.execute(text("SELECT 1"))
        eng.dispose()
        return True
    except Exception:
        return False


PG_IS_AVAILABLE = _pg_available()


# Phase 17 17.7 - reset process-global limiter/pairing state around every test

@pytest.fixture(autouse=True)
def _reset_process_state():
    """Drop every process-global in-memory singleton around each test.

    Sliding-window counters are keyed by client IP, and the TestClient is
    always the same peer, so without this reset one test's requests would
    consume the next test's budget.
    """
    from app.services.devices import reset_process_state

    reset_process_state()
    yield
    reset_process_state()


# ── SQLite fixtures (unit tests) ───────────────────────────────────────

@pytest.fixture(scope="session")
def db_engine():
    """Create an in-memory SQLite engine for unit testing."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)
    engine.dispose()


@pytest.fixture()
def db_session(db_engine):
    """Create a test database session with automatic rollback."""
    connection = db_engine.connect()
    transaction = connection.begin()
    session = sessionmaker(bind=connection)()

    yield session

    session.close()
    transaction.rollback()
    connection.close()


@pytest.fixture()
def client(db_engine):
    """Create a test client with overridden database dependency."""

    def override_get_db():
        connection = db_engine.connect()
        transaction = connection.begin()
        session = sessionmaker(bind=connection)()
        try:
            yield session
        finally:
            session.close()
            transaction.rollback()
            connection.close()

    app.dependency_overrides[get_db] = override_get_db
    with TestClient(app) as c:
        yield c
    app.dependency_overrides.clear()


# ── PostgreSQL fixtures (integration tests) ────────────────────────────
# Integration tests use Alembic CLI and raw psycopg2 — no SQLAlchemy fixtures needed.
# The pg_engine / _pg_setup_and_teardown fixtures are not used.
