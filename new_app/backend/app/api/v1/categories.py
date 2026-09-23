"""Category management API endpoints (Phase 5).

Endpoints:
- GET    /api/v1/categories        — List categories (with product counts)
- GET    /api/v1/categories/{id}   — Get category by ID
- POST   /api/v1/categories        — Create category
- PUT    /api/v1/categories/{id}   — Update category (partial)
- DELETE /api/v1/categories/{id}   — Archive category (soft-delete)

Category management is a privileged operation (CATEGORY_MANAGE).
Listing requires CATEGORY_VIEW. Archiving keeps product references
intact — destructive removal never breaks historical records.
"""

from __future__ import annotations

import math
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.catalog import Category
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.catalog import (
    CategoryCreateRequest,
    CategoryListResponse,
    CategoryResponse,
    CategoryUpdateRequest,
)
from app.services.catalog import CategoryService

router = APIRouter()

DEFAULT_CATEGORY_PAGE_SIZE = 100


def _get_category_service(db: Session = Depends(get_db)) -> CategoryService:
    return CategoryService(db)


def to_category_response(
    category: Category, product_count: int = 0
) -> CategoryResponse:
    """Map a Category model to its API response."""
    response = CategoryResponse.model_validate(category)
    response.product_count = product_count
    response.is_archived = category.archived_at is not None
    return response


@router.get(
    "",
    response_model=CategoryListResponse,
    summary="List categories",
    tags=["categories"],
)
def list_categories(
    page: int = Query(1, ge=1),
    page_size: int = Query(
        DEFAULT_CATEGORY_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE
    ),
    search: str | None = Query(None, max_length=100),
    status: str = Query(
        "all",
        pattern="^(active|archived|all)$",
        description="Archive filter (default: all)",
    ),
    sort_by: str = Query(
        "sort_order",
        pattern="^(name|sort_order|created_at|updated_at)$",
    ),
    sort_order: str = Query("asc", pattern="^(asc|desc)$"),
    user: User = Depends(require_permission(PermissionScope.CATEGORY_VIEW)),
    service: CategoryService = Depends(_get_category_service),
) -> CategoryListResponse:
    """List categories with active product counts (single joined query)."""
    rows, total = service.list(
        page=page,
        page_size=page_size,
        search=search,
        status=status,
        sort_by=sort_by,
        sort_order=sort_order,
    )
    pages = math.ceil(total / page_size) if total > 0 else 1
    return CategoryListResponse(
        items=[to_category_response(c, count) for c, count in rows],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )


@router.get(
    "/{category_id}",
    response_model=CategoryResponse,
    summary="Get category",
    tags=["categories"],
)
def get_category(
    category_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.CATEGORY_VIEW)),
    service: CategoryService = Depends(_get_category_service),
) -> CategoryResponse:
    """Get a single category by ID."""
    category = service.get(category_id)
    return to_category_response(category)


@router.post(
    "",
    response_model=CategoryResponse,
    status_code=201,
    summary="Create category",
    tags=["categories"],
)
def create_category(
    request: CategoryCreateRequest,
    user: User = Depends(require_permission(PermissionScope.CATEGORY_MANAGE)),
    service: CategoryService = Depends(_get_category_service),
) -> CategoryResponse:
    """Create a category. Name must be unique."""
    category = service.create(request)
    return to_category_response(category)


@router.put(
    "/{category_id}",
    response_model=CategoryResponse,
    summary="Update category",
    tags=["categories"],
)
def update_category(
    category_id: uuid.UUID,
    request: CategoryUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.CATEGORY_MANAGE)),
    service: CategoryService = Depends(_get_category_service),
) -> CategoryResponse:
    """Partial update — only fields present in the body are changed."""
    category = service.update(category_id, request)
    return to_category_response(category)


@router.delete(
    "/{category_id}",
    response_model=CategoryResponse,
    summary="Archive category",
    tags=["categories"],
)
def archive_category(
    category_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.CATEGORY_MANAGE)),
    service: CategoryService = Depends(_get_category_service),
) -> CategoryResponse:
    """Archive (soft-delete) a category. Product links are preserved."""
    category = service.archive(category_id)
    return to_category_response(category)
