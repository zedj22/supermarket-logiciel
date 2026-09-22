"""Common Pydantic schema conventions.

Provides base schemas, pagination, error responses, and ordering/filtering
foundations used across the API.
"""

from datetime import datetime
from typing import Any, Generic, TypeVar
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


# ---------------------------------------------------------------------------
# Base schema
# ---------------------------------------------------------------------------


class StrictBaseModel(BaseModel):
    """Base model with ORM mode and strict configuration."""

    model_config = ConfigDict(
        from_attributes=True,
        str_strip_whitespace=True,
    )


# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------


class PaginationParams(BaseModel):
    """Pagination query parameters with safe defaults and limits."""

    page: int = Field(default=1, ge=1, description="Page number (1-indexed)")
    page_size: int = Field(
        default=40,
        ge=1,
        le=100,
        description="Items per page (max 100)",
    )

    @property
    def offset(self) -> int:
        """Calculate SQL OFFSET from page and page_size."""
        return (self.page - 1) * self.page_size

    @property
    def limit(self) -> int:
        """Alias for page_size (SQL LIMIT)."""
        return self.page_size


class PaginatedResponse(StrictBaseModel, Generic[T]):
    """Standard paginated response envelope."""

    items: list[T]
    total: int = Field(description="Total number of items matching the query")
    page: int = Field(description="Current page number")
    page_size: int = Field(description="Items per page")
    pages: int = Field(description="Total number of pages")


# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------


class OrderingParams(BaseModel):
    """Ordering query parameters.

    Sort fields must be provided by the endpoint via `allowed_fields`.
    The `field` is the column name; `direction` is asc or desc.
    """

    field: str = Field(default="created_at", description="Field to sort by")
    direction: str = Field(
        default="desc",
        pattern="^(asc|desc)$",
        description="Sort direction: asc or desc",
    )


# ---------------------------------------------------------------------------
# Error response
# ---------------------------------------------------------------------------


class ErrorDetail(StrictBaseModel):
    """Structured error detail."""

    code: str
    message_key: str
    message: str = ""
    details: dict[str, Any] = Field(default_factory=dict)
    request_id: str | None = None


class ErrorResponse(StrictBaseModel):
    """Standard API error response envelope."""

    error: ErrorDetail


# ---------------------------------------------------------------------------
# Success response
# ---------------------------------------------------------------------------


class SuccessResponse(StrictBaseModel):
    """Generic success response for operations that return a message."""

    message: str
    details: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# ID response
# ---------------------------------------------------------------------------


class IDResponse(StrictBaseModel):
    """Response containing just a UUID (for create operations)."""

    id: UUID


# ---------------------------------------------------------------------------
# Timestamp mixin (for response schemas)
# ---------------------------------------------------------------------------


class TimestampMixin(BaseModel):
    """Mixin that adds timestamp fields to response schemas."""

    created_at: datetime
    updated_at: datetime
