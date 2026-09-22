"""Database session management for FastAPI.

Provides a request-scoped database session dependency.
Each request gets its own session that is automatically
closed after the request completes.
"""

from collections.abc import Generator

from sqlalchemy.orm import Session

from app.db.engine import _factory


def get_db() -> Generator[Session, None, None]:
    """Yield a database session for the current request.

    The session is automatically closed after the request completes.
    Commit/rollback is handled at the service layer.
    """
    SessionLocal = _factory.session_factory
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
