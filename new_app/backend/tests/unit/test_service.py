"""Tests for service base and transaction management.

Verifies:
- Successful transaction commits data
- Failed transaction rolls back
- AppError within transaction rolls back
- Database error translation in transactions
"""

import uuid

import pytest

from app.db.base import BaseModel
from app.core.exceptions import AppError, ConflictError, DatabaseError, NotFoundError
from app.services.base import BaseService
from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column


# ---------------------------------------------------------------------------
# Test model
# ---------------------------------------------------------------------------


class SvcTestItem(BaseModel):
    """Minimal test entity for service/transaction testing."""

    __tablename__ = "service_test_items"

    name: Mapped[str] = mapped_column(String(100), nullable=False)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_successful_transaction_commits(db_session):
    """A successful transaction should commit data to the database."""
    service = BaseService(db_session)

    with service.transaction():
        item = SvcTestItem(name="Committed Item")
        db_session.add(item)
        db_session.flush()

    # After context manager, data should be committed
    from sqlalchemy import select
    result = db_session.execute(
        select(SvcTestItem).where(SvcTestItem.name == "Committed Item")
    ).scalar_one_or_none()
    assert result is not None
    assert result.name == "Committed Item"


def test_failed_transaction_rolls_back(db_session):
    """An exception in a transaction should roll back all changes.

    Non-SQLAlchemy exceptions (e.g. RuntimeError) are re-raised as-is
    (not mislabeled as DATABASE_ERROR); rollback still happens.
    """
    service = BaseService(db_session)

    with pytest.raises(RuntimeError, match="Intentional failure"):
        with service.transaction():
            item = SvcTestItem(name="Will Be Rolled Back")
            db_session.add(item)
            db_session.flush()
            raise RuntimeError("Intentional failure")

    # Data should not exist
    from sqlalchemy import select
    result = db_session.execute(
        select(SvcTestItem).where(SvcTestItem.name == "Will Be Rolled Back")
    ).scalar_one_or_none()
    assert result is None


def test_app_error_in_transaction_rolls_back(db_session):
    """An AppError in a transaction should roll back and re-raise."""
    service = BaseService(db_session)

    try:
        with service.transaction():
            item = SvcTestItem(name="Should Not Persist")
            db_session.add(item)
            db_session.flush()
            raise ConflictError(message="Business conflict")
    except ConflictError as e:
        assert e.code == "CONFLICT"

    from sqlalchemy import select
    result = db_session.execute(
        select(SvcTestItem).where(SvcTestItem.name == "Should Not Persist")
    ).scalar_one_or_none()
    assert result is None


def test_run_in_transaction_success(db_session):
    """run_in_transaction should commit on success."""
    service = BaseService(db_session)

    def create_item(tx_db):
        item = SvcTestItem(name="Via run_in_transaction")
        tx_db.add(item)
        tx_db.flush()
        return item.id

    item_id = service.run_in_transaction(create_item)
    assert item_id is not None

    from sqlalchemy import select
    result = db_session.get(SvcTestItem, item_id)
    assert result is not None
    assert result.name == "Via run_in_transaction"


def test_run_in_transaction_rollback_on_failure(db_session):
    """run_in_transaction should rollback on exception."""
    service = BaseService(db_session)

    def failing_fn(tx_db):
        item = SvcTestItem(name="Will Fail")
        tx_db.add(item)
        tx_db.flush()
        raise NotFoundError(message="Not found")

    try:
        service.run_in_transaction(failing_fn)
    except NotFoundError:
        pass

    from sqlalchemy import select
    count = db_session.execute(
        select(SvcTestItem).where(SvcTestItem.name == "Will Fail")
    ).scalar_one_or_none()
    assert count is None


def test_multiple_operations_in_one_transaction(db_session):
    """Multiple repository operations in one transaction should all commit."""
    service = BaseService(db_session)

    with service.transaction():
        item1 = SvcTestItem(name="First")
        item2 = SvcTestItem(name="Second")
        db_session.add_all([item1, item2])
        db_session.flush()

    from sqlalchemy import select
    results = db_session.execute(
        select(SvcTestItem).order_by(SvcTestItem.name)
    ).scalars().all()
    assert len(results) == 2
    assert results[0].name == "First"
    assert results[1].name == "Second"
