"""Repository base class and foundation.

Provides common database query, persistence, and pagination helpers
that domain-specific repositories can extend.

Repositories handle persistence concerns only. They do NOT:
- Contain HTTP logic
- Know about FastAPI Request/Response
- Raise HTTPException
- Implement business workflows

Usage:
    class ProductRepository(BaseRepository[Product]):
        model = Product
"""

from __future__ import annotations

from typing import Any, Generic, Sequence, Type, TypeVar

import structlog
from sqlalchemy import Select, asc, desc, func, select
from sqlalchemy.orm import Session

from app.db.base import Base
from app.schemas.common import OrderingParams, PaginationParams

logger = structlog.get_logger(__name__)

ModelT = TypeVar("ModelT", bound=Base)


class BaseRepository(Generic[ModelT]):
    """Generic repository providing common persistence operations.

    Subclass this for domain-specific repositories. Set `model` to the
    SQLAlchemy model class.
    """

    model: Type[ModelT]

    def __init__(self, db: Session):
        self.db = db

    def get_by_id(self, id: Any) -> ModelT | None:
        """Retrieve a single record by primary key."""
        return self.db.get(self.model, id)

    def get_by_id_or_none(self, id: Any) -> ModelT:
        """Retrieve a single record by primary key, or raise NotFoundError.

        Note: This method raises app.core.exceptions.NotFoundError,
        which is an AppError subclass. Import is deferred to avoid
        circular imports at module level.
        """
        from app.core.exceptions import NotFoundError

        record = self.db.get(self.model, id)
        if record is None:
            raise NotFoundError(
                message=f"{self.model.__name__} not found",
                details={"id": str(id)},
            )
        return record

    def list(
        self,
        *,
        pagination: PaginationParams,
        ordering: OrderingParams | None = None,
        filters: list | None = None,
    ) -> tuple[Sequence[ModelT], int]:
        """List records with pagination, ordering, and optional filters.

        Returns:
            Tuple of (items, total_count).
        """
        stmt = select(self.model)
        count_stmt = select(func.count()).select_from(self.model)

        # Apply filters
        if filters:
            for f in filters:
                stmt = stmt.where(f)
                count_stmt = count_stmt.where(f)

        # Get total count before pagination
        total = self.db.scalar(count_stmt) or 0

        # Apply ordering
        if ordering:
            order_col = getattr(self.model, ordering.field, None)
            if order_col is not None:
                order_func = asc if ordering.direction == "asc" else desc
                stmt = stmt.order_by(order_func(order_col))

        # Apply pagination
        stmt = stmt.offset(pagination.offset).limit(pagination.limit)

        items = self.db.scalars(stmt).all()
        return items, total

    def create(self, instance: ModelT) -> ModelT:
        """Persist a new record."""
        self.db.add(instance)
        self.db.flush()
        return instance

    def delete(self, instance: ModelT) -> None:
        """Delete a record. Prefer soft-delete (archive) over hard delete."""
        self.db.delete(instance)
        self.db.flush()

    def refresh(self, instance: ModelT) -> ModelT:
        """Refresh an instance from the database."""
        self.db.refresh(instance)
        return instance

    def count(self, filters: list | None = None) -> int:
        """Count records, optionally with filters."""
        stmt = select(func.count()).select_from(self.model)
        if filters:
            for f in filters:
                stmt = stmt.where(f)
        return self.db.scalar(stmt) or 0
