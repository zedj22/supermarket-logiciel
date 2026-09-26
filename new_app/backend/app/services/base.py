"""Service base class and transaction management.

Services handle application/business orchestration:
- Transaction boundaries (commit/rollback)
- Coordinating multiple repositories
- Enforcing business rules
- Mapping domain errors

Services do NOT:
- Return FastAPI Response objects
- Depend on HTTP Request
- Directly manipulate response headers

Transaction policy:
- Services own the transaction boundary.
- The service creates a session, performs operations, and commits.
- On failure, the service rolls back and raises an appropriate AppError.
"""

from __future__ import annotations

from collections.abc import Callable, Generator
from contextlib import contextmanager
from typing import Any

import structlog
from sqlalchemy.orm import Session

from sqlalchemy.exc import SQLAlchemyError

from app.core.exceptions import AppError, DatabaseError, translate_db_error

logger = structlog.get_logger(__name__)


class BaseService:
    """Base class for application services.

    Provides transaction management and common patterns.
    Domain services should extend this class.
    """

    def __init__(self, db: Session):
        self.db = db

    @contextmanager
    def transaction(self) -> Generator[Session, None, None]:
        """Context manager that provides transactional behavior.

        Yields the session. On success, commits. On failure, rolls back
        and translates the database exception into an AppError.

        Usage:
            with self.transaction() as tx:
                repo.create(entity)
                # auto-commits on exit, auto-rolls-back on exception
        """
        try:
            yield self.db
            self.db.commit()
        except AppError:
            self.db.rollback()
            raise
        except SQLAlchemyError as exc:
            self.db.rollback()
            logger.error(
                "transaction_failed",
                exc_type=type(exc).__name__,
                exc_message=str(exc),
            )
            raise translate_db_error(exc) from exc
        except Exception:
            self.db.rollback()
            raise

    def run_in_transaction(self, fn: Callable[[Session], Any]) -> Any:
        """Execute a callable within a transaction boundary.

        Commits on success, rolls back on failure.

        Args:
            fn: A callable that takes a Session and returns a result.

        Returns:
            The return value of fn.

        Raises:
            AppError: Translated from any database error.
        """
        try:
            result = fn(self.db)
            self.db.commit()
            return result
        except AppError:
            self.db.rollback()
            raise
        except SQLAlchemyError as exc:
            self.db.rollback()
            logger.error(
                "transaction_failed",
                exc_type=type(exc).__name__,
                exc_message=str(exc),
            )
            raise translate_db_error(exc) from exc
        except Exception:
            self.db.rollback()
            raise
        return result
