"""Tests for repository base layer.

Verifies:
- Create and retrieve by ID
- List with pagination
- List with ordering
- Count
- Delete
- Missing record behavior
"""

import uuid

from app.db.base import BaseModel
from app.repositories.base import BaseRepository
from sqlalchemy import String, func
from sqlalchemy.orm import Mapped, mapped_column


# ---------------------------------------------------------------------------
# Test model (defined at module level so SQLAlchemy can create the table)
# ---------------------------------------------------------------------------


class RepoTestItem(BaseModel):
    """Minimal test entity for repository testing."""

    __tablename__ = "test_items"

    name: Mapped[str] = mapped_column(String(100), nullable=False)
    value: Mapped[int] = mapped_column(default=0)

    def __repr__(self) -> str:
        return f"<RepoTestItem id={self.id} name={self.name}>"


# ---------------------------------------------------------------------------
# Test repository
# ---------------------------------------------------------------------------


class RepoTestItemRepository(BaseRepository[RepoTestItem]):
    model = RepoTestItem


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_create_and_get_by_id(db_session):
    repo = RepoTestItemRepository(db_session)
    item = RepoTestItem(name="Widget", value=42)
    repo.create(item)
    db_session.flush()

    retrieved = repo.get_by_id(item.id)
    assert retrieved is not None
    assert retrieved.name == "Widget"
    assert retrieved.value == 42


def test_get_by_id_returns_none_for_missing(db_session):
    repo = RepoTestItemRepository(db_session)
    result = repo.get_by_id(uuid.uuid4())
    assert result is None


def test_get_by_id_or_none_raises_for_missing(db_session):
    from app.core.exceptions import NotFoundError

    repo = RepoTestItemRepository(db_session)
    try:
        repo.get_by_id_or_none(uuid.uuid4())
        assert False, "Should have raised NotFoundError"
    except NotFoundError:
        pass


def test_list_with_pagination(db_session):
    repo = RepoTestItemRepository(db_session)
    from app.schemas.common import PaginationParams

    # Create 5 items
    for i in range(5):
        repo.create(RepoTestItem(name=f"Item {i}", value=i))
    db_session.flush()

    # Page 1, size 2
    params = PaginationParams(page=1, page_size=2)
    items, total = repo.list(pagination=params)
    assert len(items) == 2
    assert total == 5

    # Page 3, size 2 (last page, 1 item)
    params = PaginationParams(page=3, page_size=2)
    items, total = repo.list(pagination=params)
    assert len(items) == 1
    assert total == 5


def test_list_with_ordering(db_session):
    repo = RepoTestItemRepository(db_session)
    from app.schemas.common import OrderingParams, PaginationParams

    repo.create(RepoTestItem(name="Charlie", value=3))
    repo.create(RepoTestItem(name="Alpha", value=1))
    repo.create(RepoTestItem(name="Bravo", value=2))
    db_session.flush()

    params = PaginationParams(page=1, page_size=10)
    ordering = OrderingParams(field="name", direction="asc")
    items, total = repo.list(pagination=params, ordering=ordering)
    assert [i.name for i in items] == ["Alpha", "Bravo", "Charlie"]
    assert total == 3


def test_list_with_filters(db_session):
    repo = RepoTestItemRepository(db_session)
    from app.schemas.common import PaginationParams

    repo.create(RepoTestItem(name="Keep", value=1))
    repo.create(RepoTestItem(name="Skip", value=0))
    repo.create(RepoTestItem(name="Keep2", value=1))
    db_session.flush()

    params = PaginationParams(page=1, page_size=10)
    filters = [RepoTestItem.value == 1]
    items, total = repo.list(pagination=params, filters=filters)
    assert total == 2
    assert all(i.value == 1 for i in items)


def test_count(db_session):
    repo = RepoTestItemRepository(db_session)
    assert repo.count() == 0

    repo.create(RepoTestItem(name="A", value=1))
    repo.create(RepoTestItem(name="B", value=2))
    db_session.flush()
    assert repo.count() == 2


def test_count_with_filters(db_session):
    repo = RepoTestItemRepository(db_session)
    repo.create(RepoTestItem(name="A", value=1))
    repo.create(RepoTestItem(name="B", value=2))
    db_session.flush()
    assert repo.count(filters=[RepoTestItem.value == 1]) == 1


def test_delete(db_session):
    repo = RepoTestItemRepository(db_session)
    item = RepoTestItem(name="ToDelete", value=0)
    repo.create(item)
    db_session.flush()

    repo.delete(item)
    db_session.flush()

    assert repo.get_by_id(item.id) is None


def test_refresh(db_session):
    repo = RepoTestItemRepository(db_session)
    item = RepoTestItem(name="Original", value=0)
    repo.create(item)
    db_session.flush()

    # Modify in-memory
    item.name = "Modified"
    # Refresh from DB (should revert since not committed)
    refreshed = repo.refresh(item)
    assert refreshed.name == "Original"
