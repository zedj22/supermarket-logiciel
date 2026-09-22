"""SQLAlchemy base model and common mixins.

All models inherit from this base. Provides:
- id (UUID, primary key, client-side generated)
- created_at / updated_at timestamps
- Version field for optimistic concurrency
- Soft-archive fields where appropriate
"""

import uuid
from datetime import datetime

from sqlalchemy import DateTime, Integer, Numeric, String, Text, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base class for all SQLAlchemy models."""

    pass


class UUIDMixin:
    """Mixin that adds a UUID primary key."""

    id: Mapped[uuid.UUID] = mapped_column(
        primary_key=True,
        default=uuid.uuid4,
        index=True,
    )


class TimestampMixin:
    """Mixin that adds created_at and updated_at columns."""

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class VersionMixin:
    """Mixin for optimistic concurrency control."""

    version: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=1,
        server_default="1",
    )


class ArchiveMixin:
    """Mixin for soft-archive (logical deletion)."""

    archived_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
        default=None,
        server_default=None,
    )

    @property
    def is_archived(self) -> bool:
        return self.archived_at is not None


class BaseModel(Base, UUIDMixin, TimestampMixin):
    """Base model with UUID id and timestamps for all application entities."""

    __abstract__ = True


class DocumentModel(Base, UUIDMixin, TimestampMixin, VersionMixin):
    """Base for business documents (sales, purchases, returns, etc.)."""

    __abstract__ = True


class MasterModel(Base, UUIDMixin, TimestampMixin, ArchiveMixin):
    """Base for master data entities (products, customers, suppliers, etc.)."""

    __abstract__ = True


# ---------------------------------------------------------------------------
# Reusable column types for common field patterns
# ---------------------------------------------------------------------------

def numeric_money(**kwargs):
    """MappedColumn for monetary values: NUMERIC(18,3)."""
    kwargs.setdefault("nullable", False)
    kwargs.setdefault("default", 0)
    kwargs.setdefault("server_default", "0")
    return mapped_column(Numeric(18, 3), **kwargs)


def numeric_quantity(**kwargs):
    """MappedColumn for stock quantities: NUMERIC(18,3)."""
    kwargs.setdefault("nullable", False)
    kwargs.setdefault("default", 0)
    kwargs.setdefault("server_default", "0")
    return mapped_column(Numeric(18, 3), **kwargs)


def string_column(max_length: int = 255, **kwargs):
    """Short string MappedColumn."""
    return mapped_column(String(max_length), **kwargs)


def text_column(**kwargs):
    """Unlimited text MappedColumn."""
    return mapped_column(Text, **kwargs)
