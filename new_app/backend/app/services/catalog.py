"""Catalog services: products and categories (Phase 5).

Business orchestration, validation beyond schema constraints, and
transaction boundaries. Archive (soft-delete) is the only removal
path — master data with historical references is never hard-deleted.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Sequence

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import (
    BusinessRuleError,
    ConflictError,
    NotFoundError,
    ValidationError,
)
from app.domain.packaging import (
    PackagingError,
    PackagingState,
    PurchaseUnitDef,
    receive_packages,
    sell_base_units,
)
from app.domain.packaging import sell_packages as sell_pkg
from app.domain.unit_conversions import (
    base_to_selling_available,
    effective_unit_price,
    to_decimal,
)
from app.models.catalog import (
    Category,
    Product,
    ProductPurchaseUnit,
    ProductSellingUnit,
    ProductStockPackage,
    ProductVariant,
)
from app.models.enums import StockMovementType
from app.models.inventory import InventoryMovement
from app.repositories.catalog import (
    DEFAULT_SEARCH_LIMIT,
    CategoryRepository,
    ProductRepository,
    ProductVariantRepository,
    PurchaseUnitRepository,
    SellingUnitRepository,
    StockPackageRepository,
)
from app.schemas.catalog import (
    BarcodeLookupResponse,
    CategoryCreateRequest,
    CategoryUpdateRequest,
    PackagingStateResponse,
    ProductCreateRequest,
    ProductUpdateRequest,
    ProductVariantCreateRequest,
    ProductVariantUpdateRequest,
    PurchaseUnitCreateRequest,
    PurchaseUnitResponse,
    PurchaseUnitUpdateRequest,
    SellingUnitCreateRequest,
    SellingUnitUpdateRequest,
    SellingUnitResponse,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

VALID_STATUS_FILTERS = frozenset({"active", "archived", "all"})


def _normalize_status(status: str) -> str:
    normalized = (status or "active").strip().lower()
    if normalized not in VALID_STATUS_FILTERS:
        raise ValidationError(
            message="status must be one of: active, archived, all",
            details={"status": status},
        )
    return normalized


class CategoryService(BaseService):
    """Application service for category master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = CategoryRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 100,
        search: str | None = None,
        status: str = "all",
        sort_by: str = "sort_order",
        sort_order: str = "asc",
    ) -> tuple[list[tuple[Category, int]], int]:
        status = _normalize_status(status)
        return self.repo.list_with_counts(
            page=page,
            page_size=page_size,
            search=search,
            status=status,
            sort_by=sort_by,
            sort_order=sort_order,
        )

    def get(self, category_id: uuid.UUID) -> Category:
        return self.repo.get_by_id_or_none(category_id)

    def _ensure_name_available(
        self, name: str, exclude_id: uuid.UUID | None = None
    ) -> None:
        if self.repo.name_exists(name, exclude_id=exclude_id):
            raise ConflictError(
                message="A category with this name already exists",
                details={"name": name},
            )

    def _ensure_parent_valid(
        self,
        parent_id: uuid.UUID | None,
        exclude_id: uuid.UUID | None = None,
    ) -> None:
        if parent_id is None:
            return
        if exclude_id is not None and parent_id == exclude_id:
            raise ValidationError(
                message="A category cannot be its own parent",
                details={"parent_id": str(parent_id)},
            )
        parent = self.repo.get_by_id(parent_id)
        if parent is None:
            raise ValidationError(
                message="Parent category not found",
                details={"parent_id": str(parent_id)},
            )

    def create(self, request: CategoryCreateRequest) -> Category:
        self._ensure_name_available(request.name)
        self._ensure_parent_valid(request.parent_id)

        with self.transaction():
            category = Category(
                name=request.name,
                parent_id=request.parent_id,
                sort_order=request.sort_order,
            )
            self.repo.create(category)
        logger.info("category_created", category_id=str(category.id), name=category.name)
        return category

    def update(
        self, category_id: uuid.UUID, request: CategoryUpdateRequest
    ) -> Category:
        category = self.get(category_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "name" in updates and updates["name"] != category.name:
            self._ensure_name_available(updates["name"], exclude_id=category_id)
        if "parent_id" in updates:
            self._ensure_parent_valid(
                updates["parent_id"], exclude_id=category_id
            )

        with self.transaction():
            for key, value in updates.items():
                setattr(category, key, value)
        logger.info("category_updated", category_id=str(category.id))
        return category

    def archive(self, category_id: uuid.UUID) -> Category:
        """Soft-archive a category. Product links are preserved."""
        category = self.get(category_id)
        if category.archived_at is None:
            with self.transaction():
                category.archived_at = datetime.now(timezone.utc)
            logger.info("category_archived", category_id=str(category.id))
        return category


class ProductService(BaseService):
    """Application service for product master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ProductRepository(db)
        self.categories = CategoryRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        search: str | None = None,
        category_id: uuid.UUID | None = None,
        status: str = "active",
        sort_by: str = "name",
        sort_order: str = "asc",
    ) -> tuple[Sequence[Product], int]:
        status = _normalize_status(status)
        return self.repo.list_products(
            page=page,
            page_size=page_size,
            search=search,
            category_id=category_id,
            status=status,
            sort_by=sort_by,
            sort_order=sort_order,
        )

    def get(self, product_id: uuid.UUID) -> Product:
        return self.repo.get_by_id_or_none(product_id)

    def search(
        self,
        *,
        text: str | None = None,
        barcode: str | None = None,
        include_archived: bool = False,
        limit: int = DEFAULT_SEARCH_LIMIT,
    ) -> tuple[Sequence[Product], int]:
        return self.repo.search(
            text=text,
            barcode=barcode,
            include_archived=include_archived,
            limit=limit,
        )

    def list_low_stock(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        threshold: Decimal | None = None,
    ) -> tuple[Sequence[Product], int]:
        return self.repo.list_low_stock(
            page=page, page_size=page_size, threshold=threshold
        )

    def _ensure_barcode_available(
        self, barcode: str | None, exclude_id: uuid.UUID | None = None
    ) -> None:
        if not barcode:
            return
        if self.repo.barcode_exists(barcode, exclude_id=exclude_id):
            raise ConflictError(
                message="A product with this barcode already exists",
                details={"barcode": barcode},
            )

    def _ensure_category_usable(self, category_id: uuid.UUID | None) -> None:
        """Category must exist; archived categories reject new products."""
        if category_id is None:
            return
        category = self.categories.get_by_id(category_id)
        if category is None:
            raise ValidationError(
                message="Category not found",
                details={"category_id": str(category_id)},
            )
        if category.archived_at is not None:
            raise BusinessRuleError(
                message="Cannot assign a product to an archived category",
                details={"category_id": str(category_id)},
            )

    def create(self, request: ProductCreateRequest) -> Product:
        """Create a product, optionally with staged children, atomically.

        Children (variants / selling units / purchase units) are created in
        the SAME transaction as the product. Any child validation failure
        rolls back the product — never a half-created catalog entry.
        """
        self._ensure_barcode_available(request.barcode)
        self._ensure_category_usable(request.category_id)

        product_fields = request.model_dump(
            exclude={"variants", "selling_units", "purchase_units"}
        )
        variants = list(request.variants or [])
        selling_units = list(request.selling_units or [])
        purchase_units = list(request.purchase_units or [])

        # Validate staged children BEFORE opening the transaction so clear
        # 4xx errors surface without touching the DB.
        self._validate_staged_children(variants, selling_units, purchase_units)

        with self.transaction():
            product = Product(**product_fields)
            # Phase 7: seed PMP from nominal cost at create (updated by receipts).
            product.avg_cost = float(request.cost or 0)
            self.repo.create(product)
            self.db.flush()  # assign product.id for child FKs

            for v in variants:
                self.db.add(
                    ProductVariant(
                        product_id=product.id,
                        name=v.name,
                        barcode=v.barcode,
                        sku=v.sku,
                        price=v.price,
                        cost=v.cost,
                        quantity=v.quantity,
                    )
                )

            base_seen = False
            for su in selling_units:
                is_base = su.is_base_unit
                if not is_base and su.multiplier == 1 and not base_seen:
                    # First unit with multiplier 1 becomes base implicitly
                    # (matches SellingUnitService.create).
                    is_base = True
                if is_base:
                    if su.multiplier != 1:
                        raise ValidationError(
                            message="Base unit multiplier must be 1",
                            details={"multiplier": str(su.multiplier)},
                        )
                    if base_seen:
                        raise ConflictError(
                            message="Product already has a base selling unit",
                            details={"product_id": str(product.id)},
                        )
                    base_seen = True
                self.db.add(
                    ProductSellingUnit(
                        product_id=product.id,
                        name=su.name,
                        unit_type=su.unit_type,
                        multiplier=su.multiplier,
                        barcode=su.barcode,
                        selling_price=su.selling_price,
                        is_base_unit=is_base,
                    )
                )

            default_seen = False
            for pu in purchase_units:
                is_default = pu.is_default
                if is_default and default_seen:
                    # Only the first staged default wins (matches service).
                    is_default = False
                if is_default:
                    default_seen = True
                self.db.add(
                    ProductPurchaseUnit(
                        product_id=product.id,
                        name=pu.name,
                        unit_type=pu.unit_type,
                        multiplier=pu.multiplier,
                        barcode=pu.barcode,
                        is_default=is_default,
                    )
                )

        logger.info(
            "product_created",
            product_id=str(product.id),
            name=product.name,
            barcode=product.barcode,
            variants=len(variants),
            selling_units=len(selling_units),
            purchase_units=len(purchase_units),
        )

        # Phase 7: seed an ADJUSTMENT movement for create-with-quantity so
        # stock is movement-audited from the first write (PMP already seeded).
        if product.quantity and float(product.quantity) > 0:
            from app.services.inventory import InventoryService

            InventoryService(self.db).seed_initial_stock(product)

        return product

    def _validate_staged_children(
        self,
        variants: list[Any],
        selling_units: list[Any],
        purchase_units: list[Any],
    ) -> None:
        """Raise 4xx for duplicate names/barcodes among staged children."""
        v_names = [v.name for v in variants]
        if len(v_names) != len(set(v_names)):
            raise ConflictError(
                message="Duplicate variant name in staged children",
                details={"field": "variants"},
            )
        v_barcodes = [v.barcode for v in variants if v.barcode]
        if len(v_barcodes) != len(set(v_barcodes)):
            raise ConflictError(
                message="Duplicate variant barcode in staged children",
                details={"field": "variants"},
            )

        su_names = [s.name for s in selling_units]
        if len(su_names) != len(set(su_names)):
            raise ConflictError(
                message="Duplicate selling unit name in staged children",
                details={"field": "selling_units"},
            )
        su_barcodes = [s.barcode for s in selling_units if s.barcode]
        if len(su_barcodes) != len(set(su_barcodes)):
            raise ConflictError(
                message="Duplicate selling unit barcode in staged children",
                details={"field": "selling_units"},
            )
        # At most one explicit base flag among staged units.
        explicit_bases = sum(1 for s in selling_units if s.is_base_unit)
        if explicit_bases > 1:
            raise ConflictError(
                message="Only one base selling unit is allowed",
                details={"field": "selling_units"},
            )

        pu_names = [p.name for p in purchase_units]
        if len(pu_names) != len(set(pu_names)):
            raise ConflictError(
                message="Duplicate purchase unit name in staged children",
                details={"field": "purchase_units"},
            )
        pu_barcodes = [p.barcode for p in purchase_units if p.barcode]
        if len(pu_barcodes) != len(set(pu_barcodes)):
            raise ConflictError(
                message="Duplicate purchase unit barcode in staged children",
                details={"field": "purchase_units"},
            )

    def update(
        self, product_id: uuid.UUID, request: ProductUpdateRequest
    ) -> Product:
        product = self.get(product_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "barcode" in updates:
            new_barcode = updates["barcode"]
            if new_barcode != product.barcode:
                self._ensure_barcode_available(
                    new_barcode, exclude_id=product_id
                )
        if "category_id" in updates and updates["category_id"] != product.category_id:
            self._ensure_category_usable(updates["category_id"])

        # Phase 7 PMP: while the average still MIRRORS the nominal cost no
        # receipt has ever priced this stock, so editing `cost` reseeds it —
        # the same rule `create` applies. Once receipts own the average a
        # cost edit never rewrites it (that would invent a new PMP).
        pmp_still_nominal = to_decimal(product.avg_cost) == to_decimal(
            product.cost
        )

        with self.transaction():
            for key, value in updates.items():
                setattr(product, key, value)
            if "cost" in updates and pmp_still_nominal:
                product.avg_cost = float(to_decimal(product.cost))
        logger.info("product_updated", product_id=str(product.id))
        return product

    def archive(self, product_id: uuid.UUID) -> Product:
        """Soft-archive a product (DELETE endpoint — never a hard delete)."""
        product = self.get(product_id)
        if product.archived_at is None:
            with self.transaction():
                product.archived_at = datetime.now(timezone.utc)
            logger.info("product_archived", product_id=str(product.id))
        return product


class ProductVariantService(BaseService):
    """Application service for product variants (Phase 6)."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ProductVariantRepository(db)
        self.products = ProductRepository(db)

    def _get_product(self, product_id: uuid.UUID) -> Product:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        return product

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[ProductVariant]:
        self._get_product(product_id)
        return self.repo.list_for_product(
            product_id, include_archived=include_archived
        )

    def get(self, variant_id: uuid.UUID) -> ProductVariant:
        return self.repo.get_by_id_or_none(variant_id)

    def _ensure_barcode_available(
        self, barcode: str | None, exclude_id: uuid.UUID | None = None
    ) -> None:
        if not barcode:
            return
        if self.repo.barcode_exists(barcode, exclude_id=exclude_id):
            raise ConflictError(
                message="A variant with this barcode already exists",
                details={"barcode": barcode},
            )

    def create(
        self, product_id: uuid.UUID, request: ProductVariantCreateRequest
    ) -> ProductVariant:
        self._get_product(product_id)
        if self.repo.name_exists_for_product(product_id, request.name):
            raise ConflictError(
                message="A variant with this name already exists for the product",
                details={"name": request.name},
            )
        self._ensure_barcode_available(request.barcode)

        with self.transaction():
            variant = ProductVariant(
                product_id=product_id,
                name=request.name,
                barcode=request.barcode,
                sku=request.sku,
                price=request.price,
                cost=request.cost,
                quantity=request.quantity,
            )
            self.repo.create(variant)
        logger.info(
            "variant_created",
            product_id=str(product_id),
            variant_id=str(variant.id),
            name=variant.name,
        )
        return variant

    def update(
        self, variant_id: uuid.UUID, request: ProductVariantUpdateRequest
    ) -> ProductVariant:
        variant = self.get(variant_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "name" in updates and updates["name"] != variant.name:
            if self.repo.name_exists_for_product(
                variant.product_id, updates["name"], exclude_id=variant_id
            ):
                raise ConflictError(
                    message="A variant with this name already exists for the product",
                    details={"name": updates["name"]},
                )
        if "barcode" in updates and updates["barcode"] != variant.barcode:
            self._ensure_barcode_available(
                updates["barcode"], exclude_id=variant_id
            )

        with self.transaction():
            for key, value in updates.items():
                setattr(variant, key, value)
        logger.info("variant_updated", variant_id=str(variant.id))
        return variant

    def archive(self, variant_id: uuid.UUID) -> ProductVariant:
        variant = self.get(variant_id)
        if variant.archived_at is None:
            with self.transaction():
                variant.archived_at = datetime.now(timezone.utc)
            logger.info("variant_archived", variant_id=str(variant.id))
        return variant


class SellingUnitService(BaseService):
    """Application service for commercial selling units (Phase 6).

    Business rules:
    - Exactly one active base unit per product (multiplier must be 1).
    - Base unit cannot be archived while it is the only active unit.
    - selling_price is independent — never computed from multiplier.
    - Stock availability uses base product.quantity via domain calcs.
    """

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = SellingUnitRepository(db)
        self.products = ProductRepository(db)

    def _get_product(self, product_id: uuid.UUID) -> Product:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        return product

    def _to_response(
        self,
        unit: ProductSellingUnit,
        product: Product,
    ) -> SellingUnitResponse:
        """Map model → response with derived availability (from base stock)."""
        response = SellingUnitResponse.model_validate(unit)
        response.available_base_qty = product.quantity
        response.available_selling_qty = base_to_selling_available(
            product.quantity, unit.multiplier
        )
        response.effective_price = effective_unit_price(
            unit.selling_price, product.price
        )
        return response

    def list_for_product(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[SellingUnitResponse]:
        product = self._get_product(product_id)
        units = self.repo.list_for_product(
            product_id, include_archived=include_archived
        )
        return [self._to_response(u, product) for u in units]

    def get(self, unit_id: uuid.UUID) -> ProductSellingUnit:
        return self.repo.get_by_id_or_none(unit_id)

    def get_with_availability(
        self, unit_id: uuid.UUID
    ) -> SellingUnitResponse:
        unit = self.get(unit_id)
        product = self._get_product(unit.product_id)
        return self._to_response(unit, product)

    def _ensure_barcode_available(
        self, barcode: str | None, exclude_id: uuid.UUID | None = None
    ) -> None:
        if not barcode:
            return
        # Unique across selling units AND products (global scan namespace).
        product_bar = self.products.barcode_exists(barcode)
        if product_bar or self.repo.barcode_exists(
            barcode, exclude_id=exclude_id
        ):
            raise ConflictError(
                message="A barcode is already used by a product or selling unit",
                details={"barcode": barcode},
            )

    def create(
        self, product_id: uuid.UUID, request: SellingUnitCreateRequest
    ) -> SellingUnitResponse:
        product = self._get_product(product_id)
        if self.repo.name_exists_for_product(product_id, request.name):
            raise ConflictError(
                message="A selling unit with this name already exists for the product",
                details={"name": request.name},
            )
        self._ensure_barcode_available(request.barcode)

        if request.is_base_unit:
            if request.multiplier != 1:
                raise ValidationError(
                    message="Base unit multiplier must be 1",
                    details={"multiplier": str(request.multiplier)},
                )
            existing_base = self.repo.get_base_unit(product_id)
            if existing_base is not None:
                raise ConflictError(
                    message="Product already has a base selling unit",
                    details={"product_id": str(product_id)},
                )
        elif request.multiplier == 1 and self.repo.get_base_unit(product_id) is None:
            # First unit with multiplier 1 becomes the base unit implicitly.
            request = request.model_copy(update={"is_base_unit": True})

        with self.transaction():
            unit = ProductSellingUnit(
                product_id=product_id,
                name=request.name,
                unit_type=request.unit_type,
                multiplier=request.multiplier,
                barcode=request.barcode,
                selling_price=request.selling_price,
                is_base_unit=request.is_base_unit,
            )
            self.repo.create(unit)
        logger.info(
            "selling_unit_created",
            product_id=str(product_id),
            unit_id=str(unit.id),
            name=unit.name,
            multiplier=str(unit.multiplier),
        )
        return self._to_response(unit, product)

    def update(
        self, unit_id: uuid.UUID, request: SellingUnitUpdateRequest
    ) -> SellingUnitResponse:
        unit = self.get(unit_id)
        product = self._get_product(unit.product_id)
        updates: dict[str, Any] = request.model_dump(exclude_unset=True)

        if "name" in updates and updates["name"] != unit.name:
            if self.repo.name_exists_for_product(
                unit.product_id, updates["name"], exclude_id=unit_id
            ):
                raise ConflictError(
                    message="A selling unit with this name already exists for the product",
                    details={"name": updates["name"]},
                )
        if "barcode" in updates and updates["barcode"] != unit.barcode:
            self._ensure_barcode_available(
                updates["barcode"], exclude_id=unit_id
            )
        if "multiplier" in updates:
            new_mult = updates["multiplier"]
            if unit.is_base_unit and new_mult != 1:
                raise ValidationError(
                    message="Base unit multiplier must stay 1",
                    details={"multiplier": str(new_mult)},
                )

        with self.transaction():
            for key, value in updates.items():
                setattr(unit, key, value)
        logger.info("selling_unit_updated", unit_id=str(unit.id))
        return self._to_response(unit, product)

    def archive(self, unit_id: uuid.UUID) -> SellingUnitResponse:
        unit = self.get(unit_id)
        product = self._get_product(unit.product_id)

        if unit.is_base_unit:
            # Cannot archive the only active base unit — product would have none.
            others = [
                u
                for u in self.repo.list_for_product(unit.product_id)
                if u.id != unit_id
            ]
            if not others:
                raise BusinessRuleError(
                    message="Cannot archive the only selling unit (base unit)",
                    details={"unit_id": str(unit_id)},
                )

        if unit.archived_at is None:
            with self.transaction():
                unit.archived_at = datetime.now(timezone.utc)
            logger.info("selling_unit_archived", unit_id=str(unit.id))
        return self._to_response(unit, product)


class BarcodeLookupService(BaseService):
    """Unified barcode resolution for POS scan / Phase 8 checkout.

    Lookup order: selling unit → variant → product. Exact match only.
    """

    def __init__(self, db: Session):
        super().__init__(db)
        self.products = ProductRepository(db)
        self.variants = ProductVariantRepository(db)
        self.selling_units = SellingUnitRepository(db)

    def lookup(
        self, barcode: str, *, include_archived: bool = False
    ) -> BarcodeLookupResponse:
        code = (barcode or "").strip()
        if not code:
            return BarcodeLookupResponse(found=False)

        unit = self.selling_units.find_by_barcode(
            code, include_archived=include_archived
        )
        if unit is not None:
            product = self.products.get_by_id(unit.product_id)
            if product is None:
                return BarcodeLookupResponse(found=False)
            return BarcodeLookupResponse(
                found=True,
                kind="selling_unit",
                product_id=product.id,
                product_name=product.name,
                product_price=product.price,
                product_quantity=product.quantity,
                product_unit=product.unit,
                selling_unit_id=unit.id,
                selling_unit_name=unit.name,
                selling_unit_multiplier=unit.multiplier,
                selling_unit_price=effective_unit_price(
                    unit.selling_price, product.price
                ),
                is_archived=unit.archived_at is not None,
            )

        variant = self.variants.find_by_barcode(
            code, include_archived=include_archived
        )
        if variant is not None:
            product = self.products.get_by_id(variant.product_id)
            if product is None:
                return BarcodeLookupResponse(found=False)
            price = (
                variant.price if variant.price is not None else product.price
            )
            return BarcodeLookupResponse(
                found=True,
                kind="variant",
                product_id=product.id,
                product_name=product.name,
                product_price=product.price,
                product_quantity=product.quantity,
                product_unit=product.unit,
                variant_id=variant.id,
                variant_name=variant.name,
                variant_price=price,
                is_archived=variant.archived_at is not None,
            )

        products, _ = self.products.search(
            barcode=code, include_archived=include_archived, limit=1
        )
        if products:
            product = products[0]
            return BarcodeLookupResponse(
                found=True,
                kind="product",
                product_id=product.id,
                product_name=product.name,
                product_price=product.price,
                product_quantity=product.quantity,
                product_unit=product.unit,
                is_archived=product.archived_at is not None,
            )
        return BarcodeLookupResponse(found=False)


class PurchaseUnitService(BaseService):
    """Purchase packaging units + packaging state (Phase 6 correction).

    Purchase units are separate from selling units. Stock packages store
    sealed full-package counts; loose base is derived and never negative.
    """

    def __init__(self, db: Session) -> None:
        super().__init__(db)
        self.units = PurchaseUnitRepository(db)
        self.packages = StockPackageRepository(db)
        self.products = ProductRepository(db)
        self._log = structlog.get_logger("purchase_unit_service")

    # -- helpers ------------------------------------------------------------

    def _get_product(self, product_id: uuid.UUID, *, include_archived: bool = False) -> Product:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        return product

    def _get_unit(
        self, unit_id: uuid.UUID, *, include_archived: bool = False
    ) -> ProductPurchaseUnit | None:
        unit = self.units.get_by_id(unit_id)
        if unit is None:
            return None
        if not include_archived and unit.archived_at is not None:
            return None
        return unit

    def _unit_to_response(self, unit: ProductPurchaseUnit) -> PurchaseUnitResponse:
        row = self.packages.get_for_unit(unit.product_id, unit.id)
        full = to_decimal(row.full_packages) if row else Decimal("0")
        return PurchaseUnitResponse(
            id=unit.id,
            product_id=unit.product_id,
            name=unit.name,
            unit_type=unit.unit_type,
            multiplier=unit.multiplier,
            barcode=unit.barcode,
            is_default=unit.is_default,
            is_archived=unit.archived_at is not None,
            archived_at=unit.archived_at,
            created_at=unit.created_at,
            updated_at=unit.updated_at,
            full_packages=full,
            base_equivalent_available=full * unit.multiplier,
        )

    def _unit_defs(self, product_id: uuid.UUID) -> dict[str, PurchaseUnitDef]:
        defs: dict[str, PurchaseUnitDef] = {}
        for u in self.units.list_for_product(product_id):
            defs[str(u.id)] = PurchaseUnitDef(
                id=str(u.id),
                name=u.name,
                multiplier=u.multiplier,
            )
        return defs

    def _get_unit_def(self, unit: ProductPurchaseUnit) -> PurchaseUnitDef:
        return PurchaseUnitDef(
            id=str(unit.id),
            name=unit.name,
            multiplier=unit.multiplier,
        )

    def _load_state(self, product: Product) -> PackagingState:
        full: dict[str, Decimal] = {}
        for row in self.packages.list_for_product(product.id):
            if row.full_packages != 0:
                full[str(row.purchase_unit_id)] = to_decimal(row.full_packages)
        state = PackagingState(
            full_packages=full,
            total_base=to_decimal(product.quantity),
            units=self._unit_defs(product.id),
        )
        state.sync_loose()
        return state

    def _save_state(
        self,
        product: Product,
        state: PackagingState,
        *,
        total_base: Decimal | None = None,
    ) -> None:
        if total_base is not None:
            product.quantity = float(total_base)
        seen: set[uuid.UUID] = set()
        for unit_id_str, full in state.full_packages.items():
            unit_id = uuid.UUID(unit_id_str)
            seen.add(unit_id)
            row = self.packages.get_for_unit(product.id, unit_id)
            if row is None:
                if full != 0:
                    self.db.add(
                        ProductStockPackage(
                            product_id=product.id,
                            purchase_unit_id=unit_id,
                            full_packages=full,
                        )
                    )
            else:
                row.full_packages = full
        for row in self.packages.list_for_product(product.id):
            if row.purchase_unit_id not in seen and row.full_packages != 0:
                row.full_packages = Decimal("0")

    def _record_movement(
        self,
        product: Product,
        *,
        movement_type: StockMovementType,
        quantity_change: Decimal,
        quantity_before: Decimal,
        quantity_after: Decimal,
        document_quantity: Decimal | None = None,
        document_unit: str | None = None,
        purchase_unit_id: uuid.UUID | None = None,
        packages_change: Decimal | None = None,
        unit_cost: Decimal | None = None,
        avg_cost_after: Decimal | None = None,
        reason: str | None = None,
    ) -> None:
        self.db.add(
            InventoryMovement(
                product_id=product.id,
                movement_type=movement_type.value,
                quantity_change=float(quantity_change),
                quantity_before=float(quantity_before),
                quantity_after=float(quantity_after),
                document_quantity=(
                    float(document_quantity) if document_quantity is not None else None
                ),
                document_unit=document_unit,
                purchase_unit_id=purchase_unit_id,
                packages_change=(
                    float(packages_change) if packages_change is not None else None
                ),
                unit_cost=float(unit_cost) if unit_cost is not None else None,
                avg_cost_after=(
                    float(avg_cost_after) if avg_cost_after is not None else None
                ),
                reason=reason,
            )
        )

    # -- packaging state ----------------------------------------------------

    def packaging_state(self, product_id: uuid.UUID) -> PackagingStateResponse:
        product = self._get_product(product_id)
        state = self._load_state(product)
        defs = self._unit_defs(product_id)
        full_rows = []
        for uid_str, full in sorted(state.full_packages.items()):
            if full == 0:
                continue
            uid = uuid.UUID(uid_str)
            d = defs.get(uid_str)
            full_rows.append(
                {
                    "purchase_unit_id": uid,
                    "name": d.name if d else "",
                    "multiplier": d.multiplier if d else Decimal("1"),
                    "full_packages": full,
                }
            )
        return PackagingStateResponse(
            product_id=product.id,
            total_base_qty=state.total_base,
            loose_base_qty=state.loose_base,
            full_packages=full_rows,
        )

    # -- purchase unit CRUD -------------------------------------------------

    def list_units(
        self, product_id: uuid.UUID, *, include_archived: bool = False
    ) -> list[PurchaseUnitResponse]:
        self._get_product(product_id)
        return [
            self._unit_to_response(u)
            for u in self.units.list_for_product(
                product_id, include_archived=include_archived
            )
        ]

    def create_unit(
        self, product_id: uuid.UUID, data: PurchaseUnitCreateRequest
    ) -> PurchaseUnitResponse:
        product = self._get_product(product_id)
        if self.units.name_exists_for_product(product_id, data.name):
            raise ConflictError(f"Purchase unit name already exists: {data.name}")
        if data.barcode and self.units.barcode_exists(data.barcode):
            raise ConflictError(f"Barcode already registered: {data.barcode}")
        if data.is_default:
            existing_default = self.units.get_default(product_id)
            if existing_default is not None:
                existing_default.is_default = False
        unit = ProductPurchaseUnit(
            product_id=product_id,
            name=data.name,
            unit_type=data.unit_type,
            multiplier=data.multiplier,
            barcode=data.barcode,
            is_default=data.is_default,
        )
        with self.transaction():
            self.db.add(unit)
            self.db.flush()
        self._log.info(
            "purchase_unit_created",
            product_id=str(product_id),
            unit_id=str(unit.id),
            name=unit.name,
            multiplier=str(unit.multiplier),
        )
        return self._unit_to_response(unit)

    def update_unit(
        self, product_id: uuid.UUID, unit_id: uuid.UUID, data: PurchaseUnitUpdateRequest
    ) -> PurchaseUnitResponse:
        unit = self._get_unit(unit_id, include_archived=False)
        if unit is None or unit.product_id != product_id:
            raise NotFoundError(
                message="Purchase unit not found",
                details={"unit_id": str(unit_id)},
            )
        payload = data.model_dump(exclude_unset=True)
        with self.transaction():
            if "name" in payload and payload["name"] is not None:
                if self.units.name_exists_for_product(
                    product_id, payload["name"], exclude_id=unit_id
                ):
                    raise ConflictError(
                        f"Purchase unit name already exists: {payload['name']}"
                    )
                unit.name = payload["name"]
            if "barcode" in payload:
                barcode = payload["barcode"]
                if barcode and self.units.barcode_exists(barcode, exclude_id=unit_id):
                    raise ConflictError(f"Barcode already registered: {barcode}")
                unit.barcode = barcode
            if "unit_type" in payload and payload["unit_type"] is not None:
                unit.unit_type = payload["unit_type"]
            if "multiplier" in payload and payload["multiplier"] is not None:
                unit.multiplier = payload["multiplier"]
            if payload.get("is_default") is True:
                existing_default = self.units.get_default(product_id)
                if existing_default is not None and existing_default.id != unit_id:
                    existing_default.is_default = False
                unit.is_default = True
            elif payload.get("is_default") is False:
                unit.is_default = False
            self.db.flush()
        self._log.info(
            "purchase_unit_updated",
            product_id=str(product_id),
            unit_id=str(unit_id),
        )
        return self._unit_to_response(unit)

    def archive_unit(self, product_id: uuid.UUID, unit_id: uuid.UUID) -> None:
        unit = self._get_unit(unit_id, include_archived=False)
        if unit is None or unit.product_id != product_id:
            raise NotFoundError(
                message="Purchase unit not found",
                details={"unit_id": str(unit_id)},
            )
        state = self._load_state(self._get_product(product_id))
        if state.full_packages.get(str(unit_id), Decimal("0")) != 0:
            raise BusinessRuleError(
                "Cannot archive a purchase unit that still has full packages in stock"
            )
        with self.transaction():
            unit.archived_at = datetime.now(timezone.utc)
            unit.is_default = False
            self.db.flush()
        self._log.info(
            "purchase_unit_archived",
            product_id=str(product_id),
            unit_id=str(unit_id),
        )

    # -- packaging operations ------------------------------------------------

    def receive(
        self,
        product_id: uuid.UUID,
        purchase_unit_id: uuid.UUID,
        quantity: Decimal,
        *,
        reason: str | None = None,
        unit_cost: Decimal | None = None,
    ) -> PackagingStateResponse:
        """Receive sealed packages (purchase receipt in package units).

        Phase 7: optional `unit_cost` is the cost PER PACKAGE on the document.
        When provided, product.avg_cost (PMP) is updated via the weighted
        average using the BASE unit cost (unit_cost / multiplier).
        """
        product = self._get_product(product_id)
        unit = self._get_unit(purchase_unit_id, include_archived=False)
        if unit is None or unit.product_id != product_id:
            raise NotFoundError(
                message="Purchase unit not found",
                details={"unit_id": str(purchase_unit_id)},
            )
        state = self._load_state(product)
        before_total = state.total_base
        before_avg = to_decimal(product.avg_cost)
        try:
            new_state = receive_packages(state, self._get_unit_def(unit), quantity)
            added_base = new_state.total_base - before_total
        except PackagingError as exc:
            raise ValidationError(str(exc)) from exc

        new_avg = before_avg
        base_unit_cost: Decimal | None = None
        if unit_cost is not None:
            from app.domain.valuation import (
                base_unit_cost_from_package,
                quantize_money,
                weighted_average_cost,
            )

            if unit_cost < 0:
                raise ValidationError("unit_cost cannot be negative")
            base_unit_cost = base_unit_cost_from_package(
                unit_cost, unit.multiplier
            )
            try:
                new_avg = weighted_average_cost(
                    before_total, before_avg, added_base, base_unit_cost
                )
            except ValueError as exc:
                raise ValidationError(str(exc)) from exc
            new_avg = quantize_money(new_avg)

        with self.transaction():
            self._save_state(product, new_state, total_base=new_state.total_base)
            if unit_cost is not None:
                product.avg_cost = float(new_avg)
            self._record_movement(
                product,
                movement_type=StockMovementType.PACKAGE_RECEIVE,
                quantity_change=added_base,
                quantity_before=before_total,
                quantity_after=new_state.total_base,
                document_quantity=quantity,
                document_unit=unit.name,
                purchase_unit_id=unit.id,
                packages_change=quantity,
                unit_cost=unit_cost,
                avg_cost_after=float(new_avg) if unit_cost is not None else None,
                reason=reason or f"Received {quantity} {unit.name}",
            )
            self.db.flush()
        return self.packaging_state(product_id)

    def sell(
        self,
        product_id: uuid.UUID,
        base_qty: Decimal,
        *,
        reason: str | None = None,
    ) -> PackagingStateResponse:
        """Sell/consume base quantity; may break sealed packages explicitly."""
        product = self._get_product(product_id)
        state = self._load_state(product)
        before_total = state.total_base
        before_full = dict(state.full_packages)
        try:
            new_state = sell_base_units(state, base_qty)
        except PackagingError as exc:
            raise ValidationError(str(exc)) from exc
        with self.transaction():
            self._save_state(product, new_state, total_base=new_state.total_base)
            for uid_str, after in new_state.full_packages.items():
                broken = before_full.get(uid_str, Decimal("0")) - after
                if broken == 0:
                    continue
                unit_id = uuid.UUID(uid_str)
                unit = self._get_unit(unit_id, include_archived=True)
                name = unit.name if unit else uid_str
                self._record_movement(
                    product,
                    movement_type=StockMovementType.PACKAGE_BREAK,
                    quantity_change=Decimal("0"),
                    quantity_before=before_total,
                    quantity_after=new_state.total_base,
                    document_quantity=broken,
                    document_unit=name,
                    purchase_unit_id=unit_id,
                    packages_change=-broken,
                    reason=reason or f"Broke {broken} {name} to fulfill base sale",
                )
            for uid_str, before_qty in before_full.items():
                if before_qty > 0 and uid_str not in new_state.full_packages:
                    unit_id = uuid.UUID(uid_str)
                    unit = self._get_unit(unit_id, include_archived=True)
                    name = unit.name if unit else uid_str
                    self._record_movement(
                        product,
                        movement_type=StockMovementType.PACKAGE_BREAK,
                        quantity_change=Decimal("0"),
                        quantity_before=before_total,
                        quantity_after=new_state.total_base,
                        document_quantity=before_qty,
                        document_unit=name,
                        purchase_unit_id=unit_id,
                        packages_change=-before_qty,
                        reason=reason or f"Broke {before_qty} {name} to fulfill base sale",
                    )
            self.db.flush()
        return self.packaging_state(product_id)

    def sell_packages(
        self,
        product_id: uuid.UUID,
        purchase_unit_id: uuid.UUID,
        quantity: Decimal,
        *,
        reason: str | None = None,
    ) -> PackagingStateResponse:
        """Sell sealed packages without breaking them."""
        product = self._get_product(product_id)
        unit = self._get_unit(purchase_unit_id, include_archived=False)
        if unit is None or unit.product_id != product_id:
            raise NotFoundError(
                message="Purchase unit not found",
                details={"unit_id": str(purchase_unit_id)},
            )
        state = self._load_state(product)
        before_total = state.total_base
        try:
            new_state = sell_pkg(state, self._get_unit_def(unit), quantity)
            removed_base = before_total - new_state.total_base
        except PackagingError as exc:
            raise ValidationError(str(exc)) from exc
        with self.transaction():
            self._save_state(product, new_state, total_base=new_state.total_base)
            self._record_movement(
                product,
                movement_type=StockMovementType.SALE,
                quantity_change=-removed_base,
                quantity_before=before_total,
                quantity_after=new_state.total_base,
                document_quantity=quantity,
                document_unit=unit.name,
                purchase_unit_id=unit.id,
                packages_change=-quantity,
                reason=reason or f"Sold {quantity} {unit.name}",
            )
            self.db.flush()
        return self.packaging_state(product_id)
