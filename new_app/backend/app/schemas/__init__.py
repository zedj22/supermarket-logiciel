"""Schemas package -- Pydantic request/response schemas.

Common schemas are defined here. Domain-specific schemas are
in their respective feature modules.
"""

from app.schemas.catalog import (
    CategoryCreateRequest,
    CategoryListResponse,
    CategoryResponse,
    CategoryUpdateRequest,
    ProductCreateRequest,
    ProductListResponse,
    ProductResponse,
    ProductSearchResponse,
    ProductUpdateRequest,
)
from app.schemas.common import (
    ErrorResponse,
    IDResponse,
    PaginatedResponse,
    PaginationParams,
    StrictBaseModel,
    SuccessResponse,
    TimestampMixin,
)
from app.schemas.inventory import (
    InventoryAdjustRequest,
    InventoryItemResponse,
    InventoryListResponse,
    InventoryMovementListResponse,
    InventoryMovementResponse,
    InventoryProductDetailResponse,
)

__all__ = [
    "CategoryCreateRequest",
    "CategoryListResponse",
    "CategoryResponse",
    "CategoryUpdateRequest",
    "ErrorResponse",
    "IDResponse",
    "InventoryAdjustRequest",
    "InventoryItemResponse",
    "InventoryListResponse",
    "InventoryMovementListResponse",
    "InventoryMovementResponse",
    "InventoryProductDetailResponse",
    "PaginatedResponse",
    "PaginationParams",
    "ProductCreateRequest",
    "ProductListResponse",
    "ProductResponse",
    "ProductSearchResponse",
    "ProductUpdateRequest",
    "StrictBaseModel",
    "SuccessResponse",
    "TimestampMixin",
]
