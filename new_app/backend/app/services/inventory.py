"""Inventory application service (Phase 7).

Authoritative stock mutations, PMP (moving weighted average cost),
valuation, movement journal, and packaging-aware adjustments.

Transaction policy: all mutations run inside self.transaction().
Repositories stay persistence-only.
"""

from __future__ import annotations

import math
import uuid
from decimal import Decimal

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import (
    BusinessRuleError,
    NotFoundError,
    ValidationError,
)
from app.domain.packaging import (
    PackagingError,
    PackagingState,
    PurchaseUnitDef,
    receive_packages,
)
from app.domain.unit_conversions import (
    QTY_QUANTUM,
    to_decimal,
)
from app.domain.valuation import (
    ValuationError,
    base_unit_cost_from_package,
    inventory_value,
    quantize_money,
    weighted_average_cost,
)
from app.models.catalog import (
    Product,
    ProductPurchaseUnit,
    ProductVariant,
)
from app.models.enums import StockMovementType
from app.models.inventory import InventoryMovement
from app.models.user import User
from app.repositories.catalog import (
    ProductRepository,
    ProductVariantRepository,
    PurchaseUnitRepository,
    StockPackageRepository,
)
from app.repositories.inventory import InventoryMovementRepository
from app.schemas.catalog import PackagingStateResponse
from app.schemas.inventory import (
    InventoryAdjustRequest,
    InventoryItemResponse,
    InventoryListResponse,
    InventoryMovementListResponse,
    InventoryMovementResponse,
    InventoryProductDetailResponse,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

VALID_OPERATIONS = frozenset({"increase", "decrease", "set"})


def _pages(total: int, page_size: int) -> int:
    return math.ceil(total / page_size) if total > 0 and page_size > 0 else 1


class InventoryService(BaseService):
    """Application service for inventory / stock / PMP."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.products = ProductRepository(db)
        self.variants = ProductVariantRepository(db)
        self.movements = InventoryMovementRepository(db)
        self.purchase_units = PurchaseUnitRepository(db)
        self.packages = StockPackageRepository(db)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _get_product(self, product_id: uuid.UUID) -> Product:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        return product

    def _get_variant(self, variant_id: uuid.UUID) -> ProductVariant:
        variant = self.variants.get_by_id(variant_id)
        if variant is None:
            raise NotFoundError(
                message="Variant not found",
                details={"variant_id": str(variant_id)},
            )
        return variant

    def _get_purchase_unit(
        self, unit_id: uuid.UUID, product_id: uuid.UUID
    ) -> ProductPurchaseUnit:
        unit = self.purchase_units.get_by_id(unit_id)
        if unit is None or unit.product_id != product_id:
            raise NotFoundError(
                message="Purchase unit not found",
                details={"purchase_unit_id": str(unit_id)},
            )
        if unit.archived_at is not None:
            raise ValidationError(
                message="Purchase unit is archived",
                details={"purchase_unit_id": str(unit_id)},
            )
        return unit

    def _unit_defs(self, product_id: uuid.UUID) -> dict[str, PurchaseUnitDef]:
        defs: dict[str, PurchaseUnitDef] = {}
        for u in self.purchase_units.list_for_product(product_id):
            defs[str(u.id)] = PurchaseUnitDef(
                id=str(u.id),
                name=u.name,
                multiplier=u.multiplier,
            )
        return defs

    def _load_packaging_state(self, product: Product) -> PackagingState:
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

    def _save_packaging_state(
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
                    from app.models.catalog import ProductStockPackage

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
        *,
        product_id: uuid.UUID,
        movement_type: StockMovementType,
        quantity_change: Decimal,
        quantity_before: Decimal,
        quantity_after: Decimal,
        variant_id: uuid.UUID | None = None,
        document_quantity: Decimal | None = None,
        document_unit: str | None = None,
        purchase_unit_id: uuid.UUID | None = None,
        packages_change: Decimal | None = None,
        unit_cost: Decimal | None = None,
        avg_cost_after: Decimal | None = None,
        reason: str | None = None,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        source_document_type: str | None = None,
        source_document_id: uuid.UUID | None = None,
    ) -> InventoryMovement:
        movement = InventoryMovement(
            product_id=product_id,
            variant_id=variant_id,
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
            user_id=user_id,
            device_id=device_id,
            source_document_type=source_document_type,
            source_document_id=source_document_id,
        )
        self.db.add(movement)
        return movement

    # ------------------------------------------------------------------
    # Read endpoints
    # ------------------------------------------------------------------

    def list_inventory(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        search: str | None = None,
        status: str = "active",
        low_stock_only: bool = False,
        sort_by: str = "name",
        sort_order: str = "asc",
    ) -> InventoryListResponse:
        items, total = self.movements.list_products_with_stock(
            page=page,
            page_size=page_size,
            search=search,
            status=status,
            low_stock_only=low_stock_only,
            sort_by=sort_by,
            sort_order=sort_order,
        )
        total_value = Decimal(str(self.movements.total_stock_value()))
        rows = [self._to_item(p) for p in items]
        return InventoryListResponse(
            items=rows,
            total=total,
            page=page,
            page_size=page_size,
            pages=_pages(total, page_size),
            total_stock_value=quantize_money(total_value),
        )

    def _to_item(self, product: Product) -> InventoryItemResponse:
        qty = to_decimal(product.quantity)
        avg = to_decimal(product.avg_cost)
        return InventoryItemResponse(
            product_id=product.id,
            name=product.name,
            barcode=product.barcode,
            unit=product.unit,
            quantity=qty,
            low_stock_threshold=to_decimal(product.low_stock_threshold),
            allow_negative_stock=product.allow_negative_stock,
            cost=to_decimal(product.cost),
            avg_cost=avg,
            stock_value=inventory_value(qty, avg),
            price=to_decimal(product.price),
            is_archived=product.archived_at is not None,
            category_id=product.category_id,
            category_name=product.category.name if product.category else None,
            updated_at=product.updated_at,
        )

    def list_movements(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        product_id: uuid.UUID | None = None,
        variant_id: uuid.UUID | None = None,
        movement_type: str | None = None,
        search: str | None = None,
        sort_by: str = "movement_date",
        sort_order: str = "desc",
    ) -> InventoryMovementListResponse:
        items, total = self.movements.list_movements(
            page=page,
            page_size=page_size,
            product_id=product_id,
            variant_id=variant_id,
            movement_type=movement_type,
            search=search,
            sort_by=sort_by,
            sort_order=sort_order,
        )
        return InventoryMovementListResponse(
            items=[self._to_movement(m) for m in items],
            total=total,
            page=page,
            page_size=page_size,
            pages=_pages(total, page_size),
        )

    def list_movements_for_product(
        self,
        product_id: uuid.UUID,
        *,
        page: int = 1,
        page_size: int = 40,
        movement_type: str | None = None,
    ) -> InventoryMovementListResponse:
        self._get_product(product_id)
        return self.list_movements(
            page=page,
            page_size=page_size,
            product_id=product_id,
            movement_type=movement_type,
        )

    def _to_movement(self, m: InventoryMovement) -> InventoryMovementResponse:
        return InventoryMovementResponse(
            id=m.id,
            product_id=m.product_id,
            product_name=m.product.name if m.product else None,
            variant_id=m.variant_id,
            variant_name=m.variant.name if m.variant else None,
            movement_type=m.movement_type,
            quantity_change=to_decimal(m.quantity_change),
            quantity_before=to_decimal(m.quantity_before),
            quantity_after=to_decimal(m.quantity_after),
            document_quantity=(
                to_decimal(m.document_quantity)
                if m.document_quantity is not None
                else None
            ),
            document_unit=m.document_unit,
            purchase_unit_id=m.purchase_unit_id,
            packages_change=(
                to_decimal(m.packages_change)
                if m.packages_change is not None
                else None
            ),
            unit_cost=(
                to_decimal(m.unit_cost) if m.unit_cost is not None else None
            ),
            avg_cost_after=(
                to_decimal(m.avg_cost_after)
                if m.avg_cost_after is not None
                else None
            ),
            reason=m.reason,
            source_document_type=m.source_document_type,
            source_document_id=m.source_document_id,
            user_id=m.user_id,
            user_name=m.user.full_name if m.user else None,
            device_id=m.device_id,
            movement_date=m.movement_date,
            created_at=m.created_at,
        )

    def get_product_detail(
        self, product_id: uuid.UUID
    ) -> InventoryProductDetailResponse:
        product = self._get_product(product_id)
        item = self._to_item(product)

        # Packaging state
        state = self._load_packaging_state(product)
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
        packaging = PackagingStateResponse(
            product_id=product.id,
            total_base_qty=state.total_base,
            loose_base_qty=state.loose_base,
            full_packages=full_rows,
        )

        # Variants (on demand)
        variants = self.variants.list_for_product(product_id, include_archived=True)
        variant_rows = [
            {
                "id": v.id,
                "name": v.name,
                "quantity": to_decimal(v.quantity),
                "price": v.price,
                "cost": v.cost,
                "is_archived": v.archived_at is not None,
            }
            for v in variants
        ]

        # Purchase units
        pu_rows = []
        for u in self.purchase_units.list_for_product(
            product_id, include_archived=True
        ):
            pu_rows.append(
                {
                    "id": u.id,
                    "name": u.name,
                    "multiplier": u.multiplier,
                    "unit_type": u.unit_type,
                    "is_default": u.is_default,
                    "is_archived": u.archived_at is not None,
                }
            )

        # Recent movements
        recent = self.movements.list_recent_for_product(product_id, limit=20)
        recent_rows = [self._to_movement(m) for m in recent]

        return InventoryProductDetailResponse(
            product_id=item.product_id,
            name=item.name,
            barcode=item.barcode,
            unit=item.unit,
            quantity=item.quantity,
            cost=item.cost,
            avg_cost=item.avg_cost,
            stock_value=item.stock_value,
            price=item.price,
            low_stock_threshold=item.low_stock_threshold,
            allow_negative_stock=item.allow_negative_stock,
            is_archived=item.is_archived,
            packaging=packaging.model_dump(),
            variants=variant_rows,
            purchase_units=pu_rows,
            recent_movements=recent_rows,
        )

    # ------------------------------------------------------------------
    # Adjust (authoritative mutation)
    # ------------------------------------------------------------------

    def adjust(
        self,
        request: InventoryAdjustRequest,
        *,
        user: User | None = None,
        device_id: str | None = None,
    ) -> InventoryProductDetailResponse:
        """Apply a stock adjustment and update PMP when applicable."""
        if request.operation not in VALID_OPERATIONS:
            raise ValidationError(
                message="operation must be increase, decrease, or set",
                details={"operation": request.operation},
            )
        if request.quantity < 0:
            raise ValidationError(
                message="quantity cannot be negative",
                details={"quantity": str(request.quantity)},
            )

        product = self._get_product(request.product_id)
        user_id = user.id if user is not None else None

        # ---- Variant path: adjusts variant.quantity only ----
        if request.variant_id is not None:
            return self._adjust_variant(
                product,
                request,
                user_id=user_id,
                device_id=device_id,
            )

        # ---- Package path (product-level, whole packages) ----
        if request.purchase_unit_id is not None:
            return self._adjust_packages(
                product,
                request,
                user_id=user_id,
                device_id=device_id,
            )

        # ---- Base-unit product path (Inventory UI) ----
        return self._adjust_base(
            product,
            request,
            user_id=user_id,
            device_id=device_id,
        )

    def _adjust_base(
        self,
        product: Product,
        request: InventoryAdjustRequest,
        *,
        user_id: uuid.UUID | None,
        device_id: str | None,
    ) -> InventoryProductDetailResponse:
        before = to_decimal(product.quantity)
        qty = to_decimal(request.quantity)

        if request.operation == "increase":
            delta = qty
        elif request.operation == "decrease":
            delta = -qty
        else:  # set
            delta = qty - before

        after = (before + delta).quantize(QTY_QUANTUM)

        if after < 0 and not product.allow_negative_stock:
            raise BusinessRuleError(
                message="Adjustment would make stock negative",
                details={
                    "product_id": str(product.id),
                    "before": str(before),
                    "delta": str(delta),
                    "after": str(after),
                },
            )

        old_avg = to_decimal(product.avg_cost)
        new_avg = old_avg
        unit_cost = (
            to_decimal(request.unit_cost)
            if request.unit_cost is not None
            else None
        )

        # PMP: only receipts (positive delta) with a unit_cost update the average.
        if delta > 0 and unit_cost is not None:
            try:
                new_avg = weighted_average_cost(
                    before, old_avg, delta, unit_cost
                )
            except ValuationError as exc:
                raise ValidationError(str(exc)) from exc
        elif delta > 0 and unit_cost is None and before <= 0:
            # Seed PMP from nominal cost when receiving into empty stock
            # without an explicit cost (keeps valuation non-zero when possible).
            nominal = to_decimal(product.cost)
            if nominal > 0:
                new_avg = nominal

        reason = self._resolve_reason(request)

        with self.transaction():
            product.quantity = float(after)
            product.avg_cost = float(quantize_money(new_avg))
            self._record_movement(
                product_id=product.id,
                movement_type=StockMovementType.ADJUSTMENT,
                quantity_change=delta,
                quantity_before=before,
                quantity_after=after,
                unit_cost=unit_cost,
                avg_cost_after=quantize_money(new_avg),
                reason=reason,
                user_id=user_id,
                device_id=device_id,
            )
            self.db.flush()

        logger.info(
            "inventory_adjusted",
            product_id=str(product.id),
            operation=request.operation,
            delta=str(delta),
            before=str(before),
            after=str(after),
            avg_cost=str(quantize_money(new_avg)),
        )
        return self.get_product_detail(product.id)

    @staticmethod
    def _resolve_reason(request: InventoryAdjustRequest) -> str:
        """Return a non-empty journal reason for every adjustment path.

        increase + blank/None → INCREASE_DEFAULT_REASON (neutral English).
        decrease/set blank is rejected by InventoryAdjustRequest (422).
        note is appended when present.
        """
        from app.schemas.inventory import INCREASE_DEFAULT_REASON

        reason = (request.reason or "").strip()
        if not reason:
            if request.operation == "increase":
                reason = INCREASE_DEFAULT_REASON
            else:
                # Defensive: schema already rejects blank decrease/set.
                raise ValidationError(
                    message="reason is required for decrease and set",
                    details={"operation": request.operation},
                )
        if request.note:
            reason = f"{reason} — {request.note}"
        return reason

    def _adjust_packages(
        self,
        product: Product,
        request: InventoryAdjustRequest,
        *,
        user_id: uuid.UUID | None,
        device_id: str | None,
    ) -> InventoryProductDetailResponse:
        unit = self._get_purchase_unit(
            request.purchase_unit_id, product.id  # type: ignore[arg-type]
        )
        pkg_qty = to_decimal(request.quantity)
        if pkg_qty <= 0:
            raise ValidationError(
                message="package quantity must be > 0",
                details={"quantity": str(pkg_qty)},
            )
        if pkg_qty != pkg_qty.to_integral_value():
            raise ValidationError(
                message="package quantity must be whole packages",
                details={"quantity": str(pkg_qty)},
            )

        multiplier = to_decimal(unit.multiplier)
        base_delta = (pkg_qty * multiplier).quantize(QTY_QUANTUM)

        if request.operation == "decrease":
            base_delta = -base_delta
        elif request.operation == "set":
            # set with package unit = set absolute base to pkg_qty × mult
            before = to_decimal(product.quantity)
            target = (pkg_qty * multiplier).quantize(QTY_QUANTUM)
            base_delta = target - before

        before = to_decimal(product.quantity)
        after = (before + base_delta).quantize(QTY_QUANTUM)

        if after < 0 and not product.allow_negative_stock:
            raise BusinessRuleError(
                message="Adjustment would make stock negative",
                details={
                    "product_id": str(product.id),
                    "before": str(before),
                    "delta": str(base_delta),
                    "after": str(after),
                },
            )

        old_avg = to_decimal(product.avg_cost)
        new_avg = old_avg
        unit_cost = (
            to_decimal(request.unit_cost)
            if request.unit_cost is not None
            else None
        )
        base_unit_cost: Decimal | None = None
        if unit_cost is not None:
            # document unit_cost is per PACKAGE → convert to base unit cost
            base_unit_cost = base_unit_cost_from_package(unit_cost, multiplier)

        if base_delta > 0 and base_unit_cost is not None:
            try:
                new_avg = weighted_average_cost(
                    before, old_avg, base_delta, base_unit_cost
                )
            except ValuationError as exc:
                raise ValidationError(str(exc)) from exc

        # Packaging-aware receive: open sealed packages so full_packages grows.
        state = self._load_packaging_state(product)
        state.total_base = after
        state.sync_loose()
        if base_delta > 0 and request.operation in ("increase",):
            unit_def = PurchaseUnitDef(
                id=str(unit.id),
                name=unit.name,
                multiplier=unit.multiplier,
            )
            # receive_packages already applied to a fresh state loaded at `before`
            # — rebuild from before then receive.
            state_before = PackagingState(
                full_packages=dict(
                    (str(r.purchase_unit_id), to_decimal(r.full_packages))
                    for r in self.packages.list_for_product(product.id)
                    if r.full_packages != 0
                ),
                total_base=before,
                units=self._unit_defs(product.id),
            )
            state_before.sync_loose()
            try:
                state = receive_packages(state_before, unit_def, pkg_qty)
            except PackagingError as exc:
                raise ValidationError(str(exc)) from exc
            after = state.total_base
        elif base_delta < 0 and request.operation == "decrease":
            # Decrease: reduce full packages first when possible.
            state_before = PackagingState(
                full_packages=dict(
                    (str(r.purchase_unit_id), to_decimal(r.full_packages))
                    for r in self.packages.list_for_product(product.id)
                    if r.full_packages != 0
                ),
                total_base=before,
                units=self._unit_defs(product.id),
            )
            state_before.sync_loose()
            available = state_before.full_packages.get(str(unit.id), Decimal("0"))
            if available >= pkg_qty:
                state_before.full_packages[str(unit.id)] = available - pkg_qty
                if state_before.full_packages[str(unit.id)] == 0:
                    del state_before.full_packages[str(unit.id)]
                state_before.total_base = after
                state_before.sync_loose()
                state = state_before
            else:
                # Not enough sealed packages — just drop total (loose covers rest).
                state = PackagingState(
                    full_packages=dict(state_before.full_packages),
                    total_base=after,
                    units=state_before.units,
                )
                # If still packed > total, packaging state would be invalid.
                packed = state.packed_base()
                if packed > after:
                    raise BusinessRuleError(
                        message="Cannot decrease below sealed package stock without breaking packages first",
                        details={
                            "product_id": str(product.id),
                            "packed_base": str(packed),
                            "target_total": str(after),
                        },
                    )
                state.sync_loose()

        reason = self._resolve_reason(request)

        with self.transaction():
            self._save_packaging_state(product, state, total_base=state.total_base)
            product.avg_cost = float(quantize_money(new_avg))
            self._record_movement(
                product_id=product.id,
                movement_type=StockMovementType.ADJUSTMENT,
                quantity_change=base_delta,
                quantity_before=before,
                quantity_after=state.total_base,
                document_quantity=pkg_qty,
                document_unit=unit.name,
                purchase_unit_id=unit.id,
                packages_change=(
                    pkg_qty if base_delta > 0 else -pkg_qty
                    if request.operation == "decrease"
                    else None
                ),
                unit_cost=unit_cost,
                avg_cost_after=quantize_money(new_avg),
                reason=reason,
                user_id=user_id,
                device_id=device_id,
            )
            self.db.flush()

        logger.info(
            "inventory_adjusted_packages",
            product_id=str(product.id),
            purchase_unit_id=str(unit.id),
            operation=request.operation,
            packages=str(pkg_qty),
            base_delta=str(base_delta),
            after=str(state.total_base),
        )
        return self.get_product_detail(product.id)

    def _adjust_variant(
        self,
        product: Product,
        request: InventoryAdjustRequest,
        *,
        user_id: uuid.UUID | None,
        device_id: str | None,
    ) -> InventoryProductDetailResponse:
        variant = self._get_variant(request.variant_id)  # type: ignore[arg-type]
        if variant.product_id != product.id:
            raise ValidationError(
                message="Variant does not belong to this product",
                details={
                    "variant_id": str(variant.id),
                    "product_id": str(product.id),
                },
            )

        before = to_decimal(variant.quantity)
        qty = to_decimal(request.quantity)

        if request.operation == "increase":
            delta = qty
        elif request.operation == "decrease":
            delta = -qty
        else:
            delta = qty - before

        after = (before + delta).quantize(QTY_QUANTUM)
        if after < 0:
            raise BusinessRuleError(
                message="Adjustment would make variant stock negative",
                details={
                    "variant_id": str(variant.id),
                    "before": str(before),
                    "after": str(after),
                },
            )

        reason = self._resolve_reason(request)

        # Variant PMP deferred: product.avg_cost is the authoritative PMP;
        # variant adjustments do not recompute product PMP (documented).
        avg_after = to_decimal(product.avg_cost)
        unit_cost = (
            to_decimal(request.unit_cost)
            if request.unit_cost is not None
            else None
        )

        with self.transaction():
            variant.quantity = float(after)
            self._record_movement(
                product_id=product.id,
                variant_id=variant.id,
                movement_type=StockMovementType.ADJUSTMENT,
                quantity_change=delta,
                quantity_before=before,
                quantity_after=after,
                unit_cost=unit_cost,
                avg_cost_after=quantize_money(avg_after),
                reason=reason,
                user_id=user_id,
                device_id=device_id,
            )
            self.db.flush()

        logger.info(
            "inventory_adjusted_variant",
            product_id=str(product.id),
            variant_id=str(variant.id),
            operation=request.operation,
            delta=str(delta),
            after=str(after),
        )
        return self.get_product_detail(product.id)

    # ------------------------------------------------------------------
    # Called by ProductService.create — seed initial stock movement + PMP
    # ------------------------------------------------------------------

    def seed_initial_stock(
        self,
        product: Product,
        *,
        user: User | None = None,
        reason: str = "Initial stock on product create",
    ) -> None:
        """Record an ADJUSTMENT movement for create-with-quantity and seed PMP."""
        qty = to_decimal(product.quantity)
        if qty <= 0:
            return
        cost = to_decimal(product.cost)
        with self.transaction():
            product.avg_cost = float(quantize_money(cost))
            self._record_movement(
                product_id=product.id,
                movement_type=StockMovementType.ADJUSTMENT,
                quantity_change=qty,
                quantity_before=Decimal("0"),
                quantity_after=qty,
                unit_cost=cost if cost > 0 else None,
                avg_cost_after=quantize_money(cost),
                reason=reason,
                user_id=user.id if user else None,
            )
            self.db.flush()
