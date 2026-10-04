"""Database engine and session factory.

Provides create_engine and sessionmaker configured from application settings.
Uses connection pooling appropriate for the target database.

The engine is lazily initialized to allow test configuration overrides.

Security (§17.7): ``echo`` is off in every environment. SQL echo prints the
bound parameters, and our INSERTs carry ``pin_hash``, ``token_hash`` and
secret columns. Development keeps SQL visibility through a statement-only
log — the text of the query, never its values.
"""

from typing import Generator

import structlog
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings

logger = structlog.get_logger(__name__)


def _log_sql_statement(statement: str) -> None:
    """Emit one development SQL statement (parameters deliberately absent)."""
    logger.info("sql_statement", statement=statement)


def _enable_dev_statement_log(engine) -> None:
    """Log statement text for development runs — never the parameters."""

    @event.listens_for(engine, "before_cursor_execute")
    def _log(conn, cursor, statement, parameters, context, executemany):
        _log_sql_statement(statement)


def create_db_engine(database_url: str | None = None):
    """Create a SQLAlchemy engine with connection pooling.

    Args:
        database_url: Override database URL (useful for testing).

    Returns:
        Configured SQLAlchemy Engine.
    """
    url = database_url or settings.DATABASE_URL

    # Only use connection pool settings for non-SQLite databases
    if url.startswith("sqlite"):
        engine = create_engine(
            url,
            connect_args={"check_same_thread": False},
            echo=False,
        )
    else:
        engine = create_engine(
            url,
            pool_size=5,
            max_overflow=10,
            pool_pre_ping=True,
            pool_recycle=3600,
            echo=False,
        )

    if settings.APP_ENV == "development":
        _enable_dev_statement_log(engine)
    return engine


class _EngineFactory:
    """Lazy engine factory to avoid import-time database connections."""

    def __init__(self):
        self._engine = None

    @property
    def engine(self):
        if self._engine is None:
            self._engine = create_db_engine()
        return self._engine

    @property
    def session_factory(self):
        return sessionmaker(
            autocommit=False,
            autoflush=False,
            bind=self.engine,
        )


_factory = _EngineFactory()


def get_engine():
    """Get the database engine."""
    return _factory.engine


def get_session_factory():
    """Get the database session factory."""
    return _factory.session_factory


def get_db() -> Generator[Session, None, None]:
    """Yield a database session for the current request.

    The session is automatically closed after the request completes.
    Commit/rollback is handled at the service layer.
    """
    SessionLocal = sessionmaker(
        autocommit=False,
        autoflush=False,
        bind=_factory.engine,
    )
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
