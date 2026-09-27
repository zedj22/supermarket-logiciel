"""Pack service (Phase 10): CRUD, validation, archive, availability.

Business orchestration beyond schema constraints, transaction boundaries
and audit rows. Repositories stay persistence-only (Phase 7
non-negotiable #9).

Decisions applied (docs/PHASE_10_PACKS_ANALYSIS.md):
- GATE 1  components target base products only (no variants). A component
  may name one of the product's SELLING UNITS (Phase 10 fix round) — that
  only scales the entered quantity into base stock with the Phase 6 rule
  ``base = quantity × multiplier``; there is no pack-specific conversion.
- GATE 2  ``pack_items.quantity`` is always BASE units per pack. When a
  selling unit is selected the request quantity is converted exactly once,
  at write time, and the base figure is what every later reader (stock,
  availability, sale) uses.
- GATE 3  price >= 0, editable, no auto discount; sum_of_parts read-only.
- GATE 4  component stock = products.quantity (+ allow_negative_stock).
- GATE 8  saleable = is_active AND archived_at IS NULL; DELETE archives.
- GATE 11 no new permission scopes.

Fix-round additions:
- selling-unit snapshot on each component (id + name + multiplier) so a
  later catalog edit cannot silently change an existing pack;
- informational estimated cost/profit/margin on the detail response, from
  the components' live ``avg_cost`` (Phase 7 PMP) — never persisted.
"""

from __future__ import annotations

import math
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
from app.domain.unit_conversions import selling_to_base, to_decimal
from app.domain.valuation import quantize_money
from app.models.audit import AuditLog
from app.models.catalog import Pack, PackItem, Product, ProductSellingUnit
from app.models.enums import AuditAction
from app.repositories.pack import PackListRow, PackRepository, to_money
from app.schemas.pack import (
    PackAvailabilityResponse,
    PackComponentAvailability,
    PackComponentRequest,
    PackComponentResponse,
    PackCreateRequest,
    PackDetailResponse,
    PackListResponse,
    PackResponse,
    PackUpdateRequest,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

# Guard against absurd availability requests (never mutates anyway).
MAX_AVAILABILITY_QUANTITY = Decimal("999999")


class PackService(BaseService):
    """Application service for pack master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = PackRepository(db)

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        search: str | None = None,
        status: str = "active",
    ) -> tuple[list[PackListRow], int]:
        page = max(1, page)
        page_size = max(1, min(page_size, 100))
        status = status if status in ("active", "archived", "all") else "active"
        return self.repo.list_with_stats(
            search=search, status=status, page=page, page_size=page_size
        )

    def get(self, pack_id: uuid.UUID) -> Pack:
        pack = self.repo.get_with_components(pack_id)
        if pack is None:
            raise NotFoundError(
                message="Pack not found",
                details={"pack_id": str(pack_id)},
            )
        return pack

    # ------------------------------------------------------------------
    # Writes
    # ------------------------------------------------------------------

    def create(
        self, request: PackCreateRequest, *, actor_id: uuid.UUID | None
    ) -> Pack:
        self._ensure_barcode_available(request.barcode)
        self._ensure_name_available(request.name)
        self._ensure_components_unique(request.components)
        self._ensure_components_resolve(request.components)

        with self.transaction():
            pack = Pack(
                name=request.name,
                barcode=request.barcode,
                price=float(to_money(request.price)),
                is_active=request.is_active,
                image_path=request.image_path,
            )
            self.repo.create(pack)
            self._replace_components(pack, request.components)
            self._audit(
                AuditAction.CREATE,
                entity_id=pack.id,
                actor_id=actor_id,
                details=f"created pack {pack.name!r}",
            )
        logger.info("pack_created", pack_id=str(pack.id), name=pack.name)
        return self.get(pack.id)

    def update(
        self,
        pack_id: uuid.UUID,
        request: PackUpdateRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> Pack:
        pack = self.get(pack_id)
        updates: dict[str, Any] = request.model_dump(
            exclude_unset=True, exclude={"components"}
        )

        if "barcode" in updates and updates["barcode"] != pack.barcode:
            self._ensure_barcode_available(updates["barcode"], exclude_id=pack_id)
        if "name" in updates and updates["name"].lower() != pack.name.lower():
            self._ensure_name_available(updates["name"], exclude_id=pack_id)

        components = request.components
        if components is not None:
            self._ensure_components_unique(components)
            self._ensure_components_resolve(components)

        with self.transaction():
            for key, value in updates.items():
                setattr(pack, key, value)
            if components is not None:
                # Component rows are re-read from pack_items at sale time and
                # sale lines snapshot their own values, so replacing them can
                # never rewrite a historical invoice (GATE 7).
                self._replace_components(pack, components)
            if updates.get("is_active") is True:
                # Reactivating an archived pack is done through PUT
                # (GATE 8): is_active=true clears the archive flag.
                pack.archived_at = None
            self._audit(
                AuditAction.UPDATE,
                entity_id=pack.id,
                actor_id=actor_id,
                details=f"updated pack {pack.name!r}",
            )
        logger.info("pack_updated", pack_id=str(pack_id))
        return self.get(pack_id)

    def archive(
        self, pack_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> Pack:
        """Soft-archive (GATE 8). Never a hard delete: sale_lines.pack_id is
        RESTRICT, so history keeps the reference forever."""
        pack = self.get(pack_id)
        with self.transaction():
            pack.archived_at = datetime.now(timezone.utc)
            pack.is_active = False
            self._audit(
                AuditAction.DELETE,
                entity_id=pack.id,
                actor_id=actor_id,
                details=f"archived pack {pack.name!r}",
            )
        logger.info("pack_archived", pack_id=str(pack_id))
        return self.get(pack_id)

    # ------------------------------------------------------------------
    # Availability (read-only)
    # ------------------------------------------------------------------

    def availability(
        self, pack_id: uuid.UUID, quantity: Decimal = Decimal("1")
    ) -> PackAvailabilityResponse:
        """Component stock position for a requested pack quantity.

        Pure read: it never reserves stock, never opens a transaction and
        never mutates anything.
        """
        pack = self.get(pack_id)
        qty = to_decimal(quantity)
        if qty <= 0:
            raise ValidationError(
                message="quantity must be > 0",
                details={"quantity": str(qty)},
            )
        if qty > MAX_AVAILABILITY_QUANTITY:
            raise ValidationError(
                message=f"quantity must be <= {MAX_AVAILABILITY_QUANTITY}",
                details={"quantity": str(qty)},
            )

        is_archived = pack.archived_at is not None
        saleable_flag = bool(pack.is_active) and not is_archived
        errors: list[str] = []
        if not pack.is_active:
            errors.append("pack is not active")
        if is_archived:
            errors.append("pack is archived")

        rows = PackRepository.component_rows(pack)
        components: list[PackComponentAvailability] = []
        max_packs: Decimal | None = None

        for item in rows:
            product = item.component_product
            # BASE units per pack (GATE 2) — the same figure the sale will
            # deduct. When a selling unit was selected its multiplier was
            # snapshotted at definition time, so a later catalog change
            # cannot alter what this pack consumes.
            required_per_pack = to_money(item.quantity)
            required = required_per_pack * qty
            multiplier = (
                to_money(item.selling_unit_multiplier)
                if item.selling_unit_multiplier is not None
                else None
            )
            unit_quantity = self._unit_quantity(required_per_pack, multiplier)
            required_unit_quantity = self._unit_quantity(required, multiplier)

            if product is None:
                errors.append(f"component {item.product_id}: product missing")
                components.append(
                    PackComponentAvailability(
                        product_id=item.product_id,
                        product_name=str(item.product_id),
                        product_unit="",
                        required_per_pack=required_per_pack,
                        required_quantity=required,
                        available_quantity=Decimal("0"),
                        ok=False,
                        selling_unit_id=item.selling_unit_id,
                        selling_unit_name=item.selling_unit_name,
                        selling_unit_multiplier=multiplier,
                        unit_quantity=unit_quantity,
                        required_unit_quantity=required_unit_quantity,
                    )
                )
                max_packs = Decimal("0")
                continue

            available = to_decimal(product.quantity)
            ok = required <= available or bool(product.allow_negative_stock)
            if not ok:
                errors.append(
                    f"{product.name}: need {_display(required)}, "
                    f"have {_display(available)}"
                )

            if not product.allow_negative_stock:
                per_pack = required_per_pack
                fits = (
                    int(available // per_pack)
                    if per_pack > 0
                    else 0
                )
                fits_dec = Decimal(fits)
                max_packs = fits_dec if max_packs is None else min(max_packs, fits_dec)
            elif max_packs is None:
                max_packs = qty

            components.append(
                PackComponentAvailability(
                    product_id=product.id,
                    product_name=product.name,
                    product_unit=product.unit,
                    required_per_pack=required_per_pack,
                    required_quantity=required,
                    available_quantity=available,
                    ok=ok,
                    selling_unit_id=item.selling_unit_id,
                    selling_unit_name=item.selling_unit_name,
                    selling_unit_multiplier=multiplier,
                    unit_quantity=unit_quantity,
                    required_unit_quantity=required_unit_quantity,
                )
            )

        if not rows:
            errors.append("pack has no components")

        return PackAvailabilityResponse(
            pack_id=pack.id,
            pack_name=pack.name,
            price=to_money(pack.price),
            is_active=bool(pack.is_active),
            is_archived=is_archived,
            quantity=qty,
            saleable=saleable_flag and not errors,
            max_pack_quantity=max_packs if max_packs is not None else Decimal("0"),
            sum_of_parts=PackRepository.sum_of_parts(pack),
            components=components,
            errors=errors,
        )

    # ------------------------------------------------------------------
    # Response mapping
    # ------------------------------------------------------------------

    @staticmethod
    def to_response(row: PackListRow) -> PackResponse:
        pack = row.pack
        return PackResponse(
            id=pack.id,
            name=pack.name,
            barcode=pack.barcode,
            price=to_money(pack.price),
            is_active=bool(pack.is_active),
            is_archived=pack.archived_at is not None,
            archived_at=pack.archived_at,
            image_path=pack.image_path,
            components_count=row.components_count,
            sum_of_parts=row.sum_of_parts,
            created_at=pack.created_at,
            updated_at=pack.updated_at,
        )

    @staticmethod
    def to_detail_response(pack: Pack) -> PackDetailResponse:
        """Detail payload: hydrated components + informational estimate.

        Every field the edit form needs to re-render a component row
        WITHOUT re-selecting anything: product name/unit/price, the
        selected selling unit (identity + snapshot), the quantity in that
        unit, the resolved base quantity and the product's live ``avg_cost``.
        """
        components: list[PackComponentResponse] = []
        estimated_cost = Decimal("0")

        for item in PackRepository.component_rows(pack):
            product = item.component_product
            base = to_money(item.quantity)
            multiplier = (
                to_money(item.selling_unit_multiplier)
                if item.selling_unit_multiplier is not None
                else None
            )
            # Phase 7 authoritative PMP — default 0 when the product has no
            # cost history yet (same numeric default the rest of the app
            # uses; never a second cost source).
            avg_cost = (
                to_money(product.avg_cost)
                if product is not None
                else Decimal("0")
            )
            estimated_cost += quantize_money(base * avg_cost)

            components.append(
                PackComponentResponse(
                    product_id=item.product_id,
                    product_name=(
                        product.name if product is not None else ""
                    ),
                    product_unit=(
                        product.unit if product is not None else ""
                    ),
                    product_price=(
                        to_money(product.price)
                        if product is not None
                        else Decimal("0")
                    ),
                    quantity=base,
                    selling_unit_id=item.selling_unit_id,
                    selling_unit_name=item.selling_unit_name,
                    selling_unit_multiplier=multiplier,
                    unit_quantity=PackService._unit_quantity(base, multiplier),
                    base_quantity=base,
                    avg_cost=avg_cost,
                )
            )

        price = to_money(pack.price)
        estimated_cost = quantize_money(estimated_cost)
        estimated_profit = quantize_money(price - estimated_cost)
        # Margin is a RATIO: undefined for a free pack (price == 0) — it is
        # omitted (null) instead of divided by zero.
        estimated_margin = (
            (estimated_profit / price * Decimal("100")).quantize(
                Decimal("0.01")
            )
            if price != 0
            else None
        )

        return PackDetailResponse(
            id=pack.id,
            name=pack.name,
            barcode=pack.barcode,
            price=price,
            is_active=bool(pack.is_active),
            is_archived=pack.archived_at is not None,
            archived_at=pack.archived_at,
            image_path=pack.image_path,
            components_count=len(components),
            sum_of_parts=PackRepository.sum_of_parts(pack),
            created_at=pack.created_at,
            updated_at=pack.updated_at,
            components=components,
            estimated_cost=estimated_cost,
            estimated_profit=estimated_profit,
            estimated_margin_percent=estimated_margin,
        )

    @staticmethod
    def to_list_response(
        rows: Sequence[PackListRow], *, total: int, page: int, page_size: int
    ) -> PackListResponse:
        return PackListResponse(
            items=[PackService.to_response(row) for row in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=math.ceil(total / page_size) if total > 0 and page_size > 0 else 1,
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _ensure_barcode_available(
        self, barcode: str | None, exclude_id: uuid.UUID | None = None
    ) -> None:
        if not barcode:
            return
        existing = self.repo.find_by_barcode(barcode, exclude_id=exclude_id)
        if existing is not None:
            raise ConflictError(
                message="A pack with this barcode already exists",
                details={"barcode": barcode},
            )
        # Barcodes are scanned by the POS: a pack must never shadow a
        # product barcode (the product lookup would win and sell the
        # wrong thing).
        from app.repositories.catalog import ProductRepository

        if ProductRepository(self.db).barcode_exists(barcode, exclude_id=None):
            raise ConflictError(
                message="This barcode is already used by a product",
                details={"barcode": barcode},
            )

    def _ensure_name_available(
        self, name: str, exclude_id: uuid.UUID | None = None
    ) -> None:
        if self.repo.find_by_name(name, exclude_id=exclude_id) is not None:
            raise ConflictError(
                message="A pack with this name already exists",
                details={"name": name},
            )

    def _ensure_components_resolve(
        self, components: Sequence[PackComponentRequest]
    ) -> None:
        """Every component product must exist and be sellable (GATE 1/8).

        Also validates the optional selling unit: it must exist, belong to
        the very product it is used with and not be archived. The unit is
        loaded again inside the write transaction (cheap, and the row is
        authoritative there); this pass exists so a malformed request fails
        BEFORE any transaction is opened.
        """
        if not components:
            raise ValidationError(
                message="a pack must have at least one component"
            )
        for component in components:
            product = self.db.get(Product, component.product_id)
            if product is None:
                raise NotFoundError(
                    message="Component product not found",
                    details={
                        "product_id": str(component.product_id),
                    },
                )
            if product.archived_at is not None:
                raise BusinessRuleError(
                    message="Pack component product is archived",
                    details={
                        "product_id": str(product.id),
                        "product_name": product.name,
                    },
                )
            if component.selling_unit_id is not None:
                unit = self._resolve_selling_unit(component, product)
                if self._base_quantity(component, unit) <= 0:
                    raise ValidationError(
                        message=(
                            "component quantity must resolve to a base "
                            "quantity > 0"
                        ),
                        details={
                            "product_id": str(product.id),
                            "quantity": str(component.quantity),
                            "selling_unit_id": str(component.selling_unit_id),
                        },
                    )

    def _resolve_selling_unit(
        self, component: PackComponentRequest, product: Product
    ) -> ProductSellingUnit:
        """Load and validate the component's selected selling unit.

        Reuses the Phase 6 model untouched: no pack-specific unit table,
        no variant path. Failures reuse the existing envelopes
        (404 NOT_FOUND / 422 VALIDATION_ERROR / 422 BUSINESS_RULE_ERROR).
        """
        unit = self.db.get(ProductSellingUnit, component.selling_unit_id)
        if unit is None:
            raise NotFoundError(
                message="Selling unit not found",
                details={
                    "selling_unit_id": str(component.selling_unit_id),
                    "product_id": str(product.id),
                },
            )
        if unit.product_id != product.id:
            raise ValidationError(
                message="Selling unit does not belong to this product",
                details={
                    "selling_unit_id": str(unit.id),
                    "product_id": str(product.id),
                },
            )
        if unit.archived_at is not None:
            raise BusinessRuleError(
                message="Pack component selling unit is archived",
                details={
                    "selling_unit_id": str(unit.id),
                    "selling_unit_name": unit.name,
                    "product_id": str(product.id),
                },
            )
        return unit

    @staticmethod
    def _base_quantity(
        component: PackComponentRequest, unit: ProductSellingUnit | None
    ) -> Decimal:
        """Base units one pack consumes — the Phase 6 conversion, applied once.

        ``base = quantity x multiplier`` when a selling unit is selected,
        ``base = quantity`` otherwise (legacy / product base unit).
        """
        if unit is None:
            return to_money(component.quantity)
        return selling_to_base(component.quantity, to_money(unit.multiplier))

    @staticmethod
    def _unit_quantity(base: Decimal, multiplier: Decimal | None) -> Decimal:
        """Base units expressed in the selected unit (display only).

        Both inputs are the STORED snapshot values, so this never depends
        on the live catalog.
        """
        if multiplier is None or multiplier <= 0:
            return to_money(base)
        return quantize_money(to_decimal(base) / to_decimal(multiplier))

    def _ensure_components_unique(
        self, components: Sequence[PackComponentRequest]
    ) -> None:
        """Reject a component list naming the same product twice.

        Raised as its own 422 code so the client can tell a malformed
        component set apart from a generic validation failure; the DB
        unique constraint on pack_items is only a backstop.
        """
        seen: set[uuid.UUID] = set()
        for component in components:
            if component.product_id in seen:
                raise BusinessRuleError(
                    message="Duplicate pack component",
                    code="PACK_COMPONENT_DUPLICATE",
                    details={
                        "product_id": str(component.product_id),
                    },
                )
            seen.add(component.product_id)

    def _replace_components(
        self, pack: Pack, components: Sequence[PackComponentRequest]
    ) -> None:
        """Replace the whole component set inside the current transaction.

        Duplicates are rejected earlier with a structured 422
        (``PACK_COMPONENT_DUPLICATE``) so the DB unique constraint is a
        backstop, not the primary check.
        """
        self._ensure_components_unique(components)

        pack.pack_items.clear()
        for component in components:
            product = self.db.get(Product, component.product_id)
            unit: ProductSellingUnit | None = None
            if component.selling_unit_id is not None:
                # Re-resolved INSIDE the transaction: this row's multiplier
                # is the one snapshotted onto the component.
                if product is None:
                    raise NotFoundError(
                        message="Component product not found",
                        details={"product_id": str(component.product_id)},
                    )
                unit = self._resolve_selling_unit(component, product)
            base = self._base_quantity(component, unit)
            if base <= 0:
                raise ValidationError(
                    message=(
                        "component quantity must resolve to a base "
                        "quantity > 0"
                    ),
                    details={
                        "product_id": str(component.product_id),
                        "quantity": str(component.quantity),
                    },
                )
            pack.pack_items.append(
                PackItem(
                    product_id=component.product_id,
                    variant_id=None,
                    # BASE units per pack — GATE 2, unchanged semantics.
                    quantity=float(base),
                    # Selling-unit identity + snapshot (nullable).
                    selling_unit_id=unit.id if unit is not None else None,
                    selling_unit_name=(
                        unit.name if unit is not None else None
                    ),
                    selling_unit_multiplier=(
                        float(to_money(unit.multiplier))
                        if unit is not None
                        else None
                    ),
                )
            )
        self.db.flush()

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        Audit rows ride the same transaction as the mutation: a committed
        mutation always has its audit entry, and a rolled-back mutation
        leaves no orphan audit.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="pack",
                entity_id=entity_id,
                details=details,
            )
        )


def _display(value: Decimal) -> str:
    """Trim trailing zeros for human-readable availability messages."""
    normalized = to_money(value)
    text = format(normalized, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"
