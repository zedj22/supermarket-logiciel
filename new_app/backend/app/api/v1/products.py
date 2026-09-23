"""Product management API endpoints (Phase 5).

Endpoints:
- GET    /api/v1/products            — List products (paginated, search, filter, sort)
- GET    /api/v1/products/search     — Bounded search (text + exact barcode)
- GET    /api/v1/products/low-stock  — Active products at/below low-stock threshold
- GET    /api/v1/products/{id}       — Get product by ID
- POST   /api/v1/products            — Create product
- PUT    /api/v1/products/{id}       — Update product (partial)
- DELETE /api/v1/products/{id}       — Archive product (soft-delete)

Authorization uses the Phase 4 permission infrastructure
(require_permission + PermissionScope).
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.catalog import Product
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.catalog import (
    ProductCreateRequest,
    ProductListResponse,
    ProductResponse,
    ProductSearchResponse,
    ProductUpdateRequest,
)
from app.services.catalog import ProductService

router = APIRouter()


def _get_product_service(db: Session = Depends(get_db)) -> ProductService:
    return ProductService(db)


def to_product_response(product: Product) -> ProductResponse:
    """Map a Product model to its API response (includes category name)."""
    response = ProductResponse.model_validate(product)
    response.category_name = product.category.name if product.category else None
    return response


def _pages(total: int, page_size: int) -> int:
    return math.ceil(total / page_size) if total > 0 and page_size > 0 else 1


@router.get(
    "",
    response_model=ProductListResponse,
    summary="List products",
    tags=["products"],
)
def list_products(
    page: int = Query(1, ge=1, description="Page number (1-indexed)"),
    page_size: int = Query(
        DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE, description="Items per page"
    ),
    limit: int | None = Query(
        None,
        ge=1,
        le=MAX_PAGE_SIZE,
        description="Alias for page_size (API blueprint compatibility)",
    ),
    search: str | None = Query(
        None, max_length=200, description="Name or barcode substring"
    ),
    category_id: uuid.UUID | None = Query(None, description="Filter by category"),
    status: str = Query(
        "active",
        pattern="^(active|archived|all)$",
        description="Archive filter: active (default), archived, or all",
    ),
    sort_by: str = Query(
        "name",
        pattern="^(name|barcode|price|cost|quantity|created_at|updated_at)$",
        description="Sort field",
    ),
    sort_order: str = Query(
        "asc", pattern="^(asc|desc)$", description="Sort direction"
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductService = Depends(_get_product_service),
) -> ProductListResponse:
    """List products with pagination, search, category and archive filters."""
    effective_page_size = limit if limit is not None else page_size
    items, total = service.list(
        page=page,
        page_size=effective_page_size,
        search=search,
        category_id=category_id,
        status=status,
        sort_by=sort_by,
        sort_order=sort_order,
    )
    return ProductListResponse(
        items=[to_product_response(p) for p in items],
        total=total,
        page=page,
        page_size=effective_page_size,
        pages=_pages(total, effective_page_size),
    )


@router.get(
    "/search",
    response_model=ProductSearchResponse,
    summary="Search products",
    tags=["products"],
)
def search_products(
    q: str | None = Query(
        None, max_length=200, description="Search text (name or barcode)"
    ),
    barcode: str | None = Query(
        None, max_length=50, description="Exact barcode lookup (POS scan)"
    ),
    include_archived: bool = Query(
        False, description="Include archived products (default: active only)"
    ),
    limit: int = Query(20, ge=1, le=50, description="Bounded result size"),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductService = Depends(_get_product_service),
) -> ProductSearchResponse:
    """Efficient bounded catalog search. Exact barcode takes precedence."""
    items, total = service.search(
        text=q,
        barcode=barcode,
        include_archived=include_archived,
        limit=limit,
    )
    return ProductSearchResponse(
        items=[to_product_response(p) for p in items],
        total=total,
    )


@router.get(
    "/low-stock",
    response_model=ProductListResponse,
    summary="List low-stock products",
    tags=["products"],
)
def list_low_stock_products(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    threshold: Decimal | None = Query(
        None,
        ge=0,
        description="Optional override threshold (otherwise per-product "
        "low_stock_threshold is used)",
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductService = Depends(_get_product_service),
) -> ProductListResponse:
    """Active products whose quantity is at or below the low-stock threshold."""
    items, total = service.list_low_stock(
        page=page, page_size=page_size, threshold=threshold
    )
    return ProductListResponse(
        items=[to_product_response(p) for p in items],
        total=total,
        page=page,
        page_size=page_size,
        pages=_pages(total, page_size),
    )


@router.get(
    "/{product_id}",
    response_model=ProductResponse,
    summary="Get product",
    tags=["products"],
)
def get_product(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductService = Depends(_get_product_service),
) -> ProductResponse:
    """Get a single product by ID."""
    product = service.get(product_id)
    return to_product_response(product)


@router.post(
    "",
    response_model=ProductResponse,
    status_code=201,
    summary="Create product",
    tags=["products"],
)
def create_product(
    request: ProductCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: ProductService = Depends(_get_product_service),
) -> ProductResponse:
    """Create a new product. Barcode must be unique when provided."""
    product = service.create(request)
    return to_product_response(product)


@router.put(
    "/{product_id}",
    response_model=ProductResponse,
    summary="Update product",
    tags=["products"],
)
def update_product(
    product_id: uuid.UUID,
    request: ProductUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_UPDATE)),
    service: ProductService = Depends(_get_product_service),
) -> ProductResponse:
    """Partial update — only fields present in the body are changed."""
    product = service.update(product_id, request)
    return to_product_response(product)


@router.delete(
    "/{product_id}",
    response_model=ProductResponse,
    summary="Archive product",
    tags=["products"],
)
def archive_product(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_ARCHIVE)),
    service: ProductService = Depends(_get_product_service),
) -> ProductResponse:
    """Archive (soft-delete) a product. Never destroys historical data."""
    product = service.archive(product_id)
    return to_product_response(product)
