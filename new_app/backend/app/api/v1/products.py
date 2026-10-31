"""Product, variant, selling unit & barcode API endpoints (Phase 5 + 6).

Endpoints:
- GET    /api/v1/products                      — List products (paginated, search, filter, sort)
- GET    /api/v1/products/search               — Bounded search (text + exact barcode)
- GET    /api/v1/products/low-stock            — Active products at/below low-stock threshold
- GET    /api/v1/products/barcode-lookup       — Unified barcode scan (Phase 8 ready)
- GET    /api/v1/products/{id}                 — Get product by ID
- POST   /api/v1/products                      — Create product
- PUT    /api/v1/products/{id}                 — Update product (partial)
- DELETE /api/v1/products/{id}                 — Archive product (soft-delete)
- GET    /api/v1/products/{id}/variants        — List variants (on demand)
- POST   /api/v1/products/{id}/variants        — Create variant
- PUT    /api/v1/products/{id}/variants/{vid}  — Update variant
- DELETE /api/v1/products/{id}/variants/{vid}  — Archive variant (?permanent=true hard-deletes)
- GET    /api/v1/products/{id}/selling-units   — List selling units (on demand)
- POST   /api/v1/products/{id}/selling-units   — Create selling unit
- PUT    /api/v1/products/{id}/selling-units/{uid}  — Update selling unit
- DELETE /api/v1/products/{id}/selling-units/{uid}  — Archive selling unit (?permanent=true hard-deletes)
- GET    /api/v1/products/{id}/purchase-units  — List purchase units (on demand)
- POST   /api/v1/products/{id}/purchase-units  — Create purchase unit
- PUT    /api/v1/products/{id}/purchase-units/{uid} — Update purchase unit
- DELETE /api/v1/products/{id}/purchase-units/{uid} — Archive purchase unit (?permanent=true hard-deletes)
- GET    /api/v1/products/{id}/packaging-state — Full packages + loose base
- POST   /api/v1/products/{id}/packaging-state/receive — Receive sealed packages
- POST   /api/v1/products/{id}/packaging-state/sell     — Consume base (may break)
- POST   /api/v1/products/{id}/packaging-state/sell-packages — Sell sealed packages

Authorization uses the Phase 4 permission infrastructure
(require_permission + PermissionScope). Variants/selling/purchase units reuse
product_view / product_create / product_update / product_archive.
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.db.session import get_db
from app.models.catalog import Product
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.catalog import (
    BarcodeLookupResponse,
    PackagingStateResponse,
    ProductCreateRequest,
    ProductListResponse,
    ProductResponse,
    ProductSearchResponse,
    ProductUpdateRequest,
    ProductVariantCreateRequest,
    ProductVariantListResponse,
    ProductVariantResponse,
    ProductVariantUpdateRequest,
    PurchaseUnitCreateRequest,
    PurchaseUnitListResponse,
    PurchaseUnitResponse,
    PurchaseUnitUpdateRequest,
    SellingUnitCreateRequest,
    SellingUnitListResponse,
    SellingUnitResponse,
    SellingUnitUpdateRequest,
)
from app.schemas.common import StrictBaseModel
from app.services.catalog import (
    BarcodeLookupService,
    ProductService,
    ProductVariantService,
    PurchaseUnitService,
    SellingUnitService,
)
from app.services.promotions import PromotionService

router = APIRouter()


def _get_product_service(db: Session = Depends(get_db)) -> ProductService:
    return ProductService(db)


def _get_variant_service(db: Session = Depends(get_db)) -> ProductVariantService:
    return ProductVariantService(db)


def _get_selling_unit_service(db: Session = Depends(get_db)) -> SellingUnitService:
    return SellingUnitService(db)


def _get_purchase_unit_service(db: Session = Depends(get_db)) -> PurchaseUnitService:
    return PurchaseUnitService(db)


def _get_barcode_service(db: Session = Depends(get_db)) -> BarcodeLookupService:
    return BarcodeLookupService(db)


def to_product_response(product: Product) -> ProductResponse:
    """Map a Product model to its API response (includes category name)."""
    response = ProductResponse.model_validate(product)
    response.category_name = product.category.name if product.category else None
    return response


def attach_promotions(db: Session, responses: list[ProductResponse]) -> list[ProductResponse]:
    """Phase 18 — attach each product's ACTIVE promotion (ONE query).

    The effective promotional price comes from the same domain function
    the checkout uses (``promotional_unit_price``), so POS, catalog and
    sale resolution always agree on one number. ``products.price`` stays
    untouched — the retail price remains the original value.
    """
    if not responses:
        return responses
    infos = PromotionService(db).promotion_info_for(
        {r.id: r.price for r in responses}
    )
    for response in responses:
        response.promotion = infos.get(response.id)
    return responses


def _pages(total: int, page_size: int) -> int:
    return math.ceil(total / page_size) if total > 0 and page_size > 0 else 1


# ---------------------------------------------------------------------------
# Barcode lookup (Phase 6 → Phase 8 ready) — MUST precede /{product_id}
# ---------------------------------------------------------------------------


@router.get(
    "/barcode-lookup",
    response_model=BarcodeLookupResponse,
    summary="Barcode lookup",
    tags=["products"],
)
def barcode_lookup(
    barcode: str = Query(
        ..., min_length=1, max_length=50, description="Exact barcode to resolve"
    ),
    include_archived: bool = Query(
        False, description="Include archived records (default: active only)"
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: BarcodeLookupService = Depends(_get_barcode_service),
) -> BarcodeLookupResponse:
    """Resolve a scanned barcode to product, variant, or selling unit.

    Lookup order: selling unit → variant → product (exact match).
    Used by POS scan flows in Phase 8; no sale mutation here.
    """
    return service.lookup(barcode, include_archived=include_archived)


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
        items=attach_promotions(
            service.db, [to_product_response(p) for p in items]
        ),
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
        items=attach_promotions(
            service.db, [to_product_response(p) for p in items]
        ),
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
        items=attach_promotions(
            service.db, [to_product_response(p) for p in items]
        ),
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
    return attach_promotions(service.db, [to_product_response(product)])[0]


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
    return attach_promotions(service.db, [to_product_response(product)])[0]


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
    return attach_promotions(service.db, [to_product_response(product)])[0]


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
    return attach_promotions(service.db, [to_product_response(product)])[0]


# ---------------------------------------------------------------------------
# Variants (Phase 6)
# ---------------------------------------------------------------------------


def _variant_response(variant) -> ProductVariantResponse:
    return ProductVariantResponse.model_validate(variant)


@router.get(
    "/{product_id}/variants",
    response_model=ProductVariantListResponse,
    summary="List product variants",
    tags=["products", "variants"],
)
def list_variants(
    product_id: uuid.UUID,
    include_archived: bool = Query(False, description="Include archived variants"),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductVariantService = Depends(_get_variant_service),
) -> ProductVariantListResponse:
    """List variants for one product (on demand — not with product list)."""
    items = service.list_for_product(
        product_id, include_archived=include_archived
    )
    return ProductVariantListResponse(
        items=[_variant_response(v) for v in items],
        total=len(items),
    )


@router.post(
    "/{product_id}/variants",
    response_model=ProductVariantResponse,
    status_code=201,
    summary="Create product variant",
    tags=["products", "variants"],
)
def create_variant(
    product_id: uuid.UUID,
    request: ProductVariantCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: ProductVariantService = Depends(_get_variant_service),
) -> ProductVariantResponse:
    """Create a variant. barcode unique when provided; price NULL = inherit."""
    variant = service.create(product_id, request)
    return _variant_response(variant)


@router.put(
    "/{product_id}/variants/{variant_id}",
    response_model=ProductVariantResponse,
    summary="Update product variant",
    tags=["products", "variants"],
)
def update_variant(
    product_id: uuid.UUID,
    variant_id: uuid.UUID,
    request: ProductVariantUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_UPDATE)),
    service: ProductVariantService = Depends(_get_variant_service),
) -> ProductVariantResponse:
    """Partial update of a variant."""
    # Ensure variant belongs to the path product.
    variant = service.get(variant_id)
    if str(variant.product_id) != str(product_id):
        from app.core.exceptions import NotFoundError

        raise NotFoundError(
            message="Variant not found for this product",
            details={"variant_id": str(variant_id)},
        )
    variant = service.update(variant_id, request)
    return _variant_response(variant)


@router.delete(
    "/{product_id}/variants/{variant_id}",
    response_model=ProductVariantResponse,
    summary="Archive or permanently delete a product variant",
    tags=["products", "variants"],
)
def archive_variant(
    product_id: uuid.UUID,
    variant_id: uuid.UUID,
    permanent: bool = Query(
        False,
        description=(
            "Physically delete the variant (204 No Content) instead of "
            "archiving. Rejected with 409 when any sale, purchase, "
            "return, inventory, pack, or invoice record references it."
        ),
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_ARCHIVE)),
    service: ProductVariantService = Depends(_get_variant_service),
) -> ProductVariantResponse:
    """Archive (soft-delete) a variant, or permanently delete it.

    Default (``permanent=false``): archive — 200, history untouched.
    ``permanent=true``: hard delete — 204 when no record references the
    variant; 409 with structured ``details.references`` when blocked.
    """
    variant = service.get(variant_id)
    if str(variant.product_id) != str(product_id):
        from app.core.exceptions import NotFoundError

        raise NotFoundError(
            message="Variant not found for this product",
            details={"variant_id": str(variant_id)},
        )
    if permanent:
        service.delete_permanently(variant_id)
        return Response(status_code=204)
    variant = service.archive(variant_id)
    return _variant_response(variant)


# ---------------------------------------------------------------------------
# Selling units (Phase 6)
# ---------------------------------------------------------------------------


@router.get(
    "/{product_id}/selling-units",
    response_model=SellingUnitListResponse,
    summary="List selling units",
    tags=["products", "selling-units"],
)
def list_selling_units(
    product_id: uuid.UUID,
    include_archived: bool = Query(False, description="Include archived units"),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: SellingUnitService = Depends(_get_selling_unit_service),
) -> SellingUnitListResponse:
    """List selling units for one product with derived availability."""
    items = service.list_for_product(
        product_id, include_archived=include_archived
    )
    return SellingUnitListResponse(items=items, total=len(items))


@router.post(
    "/{product_id}/selling-units",
    response_model=SellingUnitResponse,
    status_code=201,
    summary="Create selling unit",
    tags=["products", "selling-units"],
)
def create_selling_unit(
    product_id: uuid.UUID,
    request: SellingUnitCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: SellingUnitService = Depends(_get_selling_unit_service),
) -> SellingUnitResponse:
    """Create a selling unit (piece ×1 / box ×24 / …). Exactly one base unit."""
    return service.create(product_id, request)


@router.put(
    "/{product_id}/selling-units/{unit_id}",
    response_model=SellingUnitResponse,
    summary="Update selling unit",
    tags=["products", "selling-units"],
)
def update_selling_unit(
    product_id: uuid.UUID,
    unit_id: uuid.UUID,
    request: SellingUnitUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_UPDATE)),
    service: SellingUnitService = Depends(_get_selling_unit_service),
) -> SellingUnitResponse:
    """Partial update of a selling unit."""
    unit = service.get(unit_id)
    if str(unit.product_id) != str(product_id):
        from app.core.exceptions import NotFoundError

        raise NotFoundError(
            message="Selling unit not found for this product",
            details={"unit_id": str(unit_id)},
        )
    return service.update(unit_id, request)


@router.delete(
    "/{product_id}/selling-units/{unit_id}",
    response_model=SellingUnitResponse,
    summary="Archive or permanently delete a selling unit",
    tags=["products", "selling-units"],
)
def archive_selling_unit(
    product_id: uuid.UUID,
    unit_id: uuid.UUID,
    permanent: bool = Query(
        False,
        description=(
            "Physically delete the selling unit (204 No Content) instead "
            "of archiving. Rejected with 409 when any pack item or "
            "invoice document line references it."
        ),
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_ARCHIVE)),
    service: SellingUnitService = Depends(_get_selling_unit_service),
) -> SellingUnitResponse:
    """Archive (soft-delete) a selling unit, or permanently delete it.

    Default (``permanent=false``): archive — 200 (cannot archive the sole
    base unit). ``permanent=true``: hard delete — 204 when unreferenced
    (409 with structured ``details.references`` when blocked).
    """
    unit = service.get(unit_id)
    if str(unit.product_id) != str(product_id):
        from app.core.exceptions import NotFoundError

        raise NotFoundError(
            message="Selling unit not found for this product",
            details={"unit_id": str(unit_id)},
        )
    if permanent:
        service.delete_permanently(unit_id)
        return Response(status_code=204)
    return service.archive(unit_id)


# ---------------------------------------------------------------------------
# Purchase units + packaging state (Phase 6 architectural correction)
# ---------------------------------------------------------------------------


class PackagingReceiveRequest(StrictBaseModel):
    purchase_unit_id: uuid.UUID
    quantity: Decimal
    reason: str | None = None
    unit_cost: Decimal | None = None  # Phase 7: cost per package → PMP


class PackagingSellRequest(StrictBaseModel):
    base_quantity: Decimal
    reason: str | None = None


class PackagingSellPackagesRequest(StrictBaseModel):
    purchase_unit_id: uuid.UUID
    quantity: Decimal
    reason: str | None = None


@router.get(
    "/{product_id}/purchase-units",
    response_model=PurchaseUnitListResponse,
    summary="List purchase units",
    tags=["products", "purchase-units"],
)
def list_purchase_units(
    product_id: uuid.UUID,
    include_archived: bool = Query(False, description="Include archived units"),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PurchaseUnitListResponse:
    """List purchase packaging units for one product with full-package counts."""
    items = service.list_units(product_id, include_archived=include_archived)
    return PurchaseUnitListResponse(items=items, total=len(items))


@router.post(
    "/{product_id}/purchase-units",
    response_model=PurchaseUnitResponse,
    status_code=201,
    summary="Create purchase unit",
    tags=["products", "purchase-units"],
)
def create_purchase_unit(
    product_id: uuid.UUID,
    request: PurchaseUnitCreateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PurchaseUnitResponse:
    """Create a purchase packaging unit (Box ×24, Carton ×48, …). No selling price."""
    return service.create_unit(product_id, request)


@router.put(
    "/{product_id}/purchase-units/{unit_id}",
    response_model=PurchaseUnitResponse,
    summary="Update purchase unit",
    tags=["products", "purchase-units"],
)
def update_purchase_unit(
    product_id: uuid.UUID,
    unit_id: uuid.UUID,
    request: PurchaseUnitUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_UPDATE)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PurchaseUnitResponse:
    """Partial update of a purchase unit."""
    return service.update_unit(product_id, unit_id, request)


@router.delete(
    "/{product_id}/purchase-units/{unit_id}",
    status_code=204,
    response_class=Response,
    summary="Archive or permanently delete a purchase unit",
    tags=["products", "purchase-units"],
)
def archive_purchase_unit(
    product_id: uuid.UUID,
    unit_id: uuid.UUID,
    permanent: bool = Query(
        False,
        description=(
            "Physically delete the purchase unit (204 No Content) instead "
            "of archiving. Rejected with 409 when purchase lines, "
            "inventory movements, or sealed stock packages reference it."
        ),
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_ARCHIVE)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> Response:
    """Archive (soft-delete) a purchase unit, or permanently delete it.

    Default (``permanent=false``): archive — 204 (blocked while full
    packages remain). ``permanent=true``: hard delete — 204 when
    unreferenced (409 with structured ``details.references`` when
    blocked).
    """
    if permanent:
        service.delete_unit_permanently(product_id, unit_id)
    else:
        service.archive_unit(product_id, unit_id)
    return Response(status_code=204)


@router.get(
    "/{product_id}/packaging-state",
    response_model=PackagingStateResponse,
    summary="Get packaging state",
    tags=["products", "packaging"],
)
def get_packaging_state(
    product_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PackagingStateResponse:
    """Full packages + loose base + total base for one product."""
    return service.packaging_state(product_id)


@router.post(
    "/{product_id}/packaging-state/receive",
    response_model=PackagingStateResponse,
    summary="Receive sealed packages",
    tags=["products", "packaging"],
)
def receive_packages(
    product_id: uuid.UUID,
    request: PackagingReceiveRequest,
    user: User = Depends(require_permission(PermissionScope.INVENTORY_ADJUST)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PackagingStateResponse:
    """Receive N sealed packages in document unit; base qty increases by N×mult.

    Optional `unit_cost` (cost per package) updates product.avg_cost (PMP).
    """
    return service.receive(
        product_id,
        request.purchase_unit_id,
        request.quantity,
        reason=request.reason,
        unit_cost=request.unit_cost,
    )


@router.post(
    "/{product_id}/packaging-state/sell",
    response_model=PackagingStateResponse,
    summary="Consume base quantity (may break packages)",
    tags=["products", "packaging"],
)
def sell_base(
    product_id: uuid.UUID,
    request: PackagingSellRequest,
    user: User = Depends(require_permission(PermissionScope.INVENTORY_ADJUST)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PackagingStateResponse:
    """Consume base units; may open sealed packages (explicit PACKAGE_BREAK events)."""
    return service.sell(
        product_id,
        request.base_quantity,
        reason=request.reason,
    )


@router.post(
    "/{product_id}/packaging-state/sell-packages",
    response_model=PackagingStateResponse,
    summary="Sell sealed packages",
    tags=["products", "packaging"],
)
def sell_sealed_packages(
    product_id: uuid.UUID,
    request: PackagingSellPackagesRequest,
    user: User = Depends(require_permission(PermissionScope.INVENTORY_ADJUST)),
    service: PurchaseUnitService = Depends(_get_purchase_unit_service),
) -> PackagingStateResponse:
    """Sell N sealed packages of a purchase unit without breaking others."""
    return service.sell_packages(
        product_id,
        request.purchase_unit_id,
        request.quantity,
        reason=request.reason,
    )
