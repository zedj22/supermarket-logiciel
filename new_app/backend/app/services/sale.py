"""POS SaleService — atomic checkout, holds, favorites (Phase 8).

Transaction policy:
- create_sale runs ALL of: sales header, sale_lines, stock decrement,
  inventory_movements, sale_payments, customer balance + debt ledger
  inside ONE transaction. Any failure rolls back completely.
- No silent exception handling; every failure is logged and re-raised
  as a structured AppError.
- Sales never modify products.avg_cost (PMP).
- Variant sales decrement variant.quantity ONLY (no parent double-decrement).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any

import structlog
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from sqlalchemy.orm.attributes import set_committed_value

from app.core.config import settings
from app.core.exceptions import (
    AuthorizationError,
    BusinessRuleError,
    ConflictError,
    NotFoundError,
    ValidationError,
)
from app.domain.unit_conversions import QTY_QUANTUM, effective_unit_price, selling_to_base, to_decimal
from app.domain.valuation import quantize_money
from app.domain.promotion import promotional_unit_price
from app.domain.wholesale import resolve_wholesale_unit_price
from app.models.catalog import Pack, Product, ProductSellingUnit, ProductVariant
from app.models.debt import DebtLedgerEntry
from app.models.enums import (
    PaymentMethod,
    PermissionScope,
    ProductUnit,
    StockMovementType,
)
from app.models.inventory import InventoryMovement
from app.models.party import Customer
from app.models.pos import PosHold, ProductFavorite
from app.models.promotion import Promotion, PromotionProduct
from app.models.sale import Sale, SaleLine, SalePayment
from app.models.user import User
from app.repositories.catalog import (
    ProductRepository,
    ProductVariantRepository,
    SellingUnitRepository,
)
from app.repositories.pack import PackRepository
from app.repositories.sale import (
    PosHoldRepository,
    ProductFavoriteRepository,
    SaleRepository,
)
from app.schemas.sale import (
    CartLineValidation,
    CartValidateRequest,
    CartValidateResponse,
    CreateSaleRequest,
    FavoriteListResponse,
    FavoriteResponse,
    FavoriteToggleResponse,
    HoldCartItem,
    HoldCreateRequest,
    HoldListResponse,
    HoldRestoreResponse,
    HoldResponse,
    PriceOverride,
    SaleCreateResponse,
    SaleLineResponse,
    SalePaymentResponse,
    SaleResponse,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

MONEY_QUANTUM = Decimal("0.001")


def _money(value: Decimal | int | float | str) -> Decimal:
    return to_decimal(value).quantize(MONEY_QUANTUM, rounding=ROUND_HALF_UP)


def _generate_invoice_number() -> str:
    """INV-YYYYMMDD-HHMMSS-mmm-xxxx (xxxx = 4 hex chars to reduce collisions)."""
    now = datetime.now(timezone.utc)
    suffix = uuid.uuid4().hex[:4]
    return (
        f"INV-{now.strftime('%Y%m%d-%H%M%S')}-"
        f"{now.microsecond // 1000:03d}-{suffix}"
    )


def _display_qty(value: Decimal) -> str:
    """Plain decimal text for a quantity (`48.000` → `48`, `2.500` → `2.5`)."""
    text = format(value.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def unit_summary_from_lines(lines: list[dict[str, Any]]) -> str | None:
    """Compact sold-units line for sale-history rows (UX FIX #12 — FIX #1).

    Groups line quantities by sold unit (selling-unit name when the line
    had one, else the base product unit), keeps first-seen order and caps
    the list at three groups (``2 Box · 48 piece +1``). Built purely from
    the persisted line snapshots — informational only, never feeds totals
    or stock. Returns None when no line carries a usable unit.
    """
    order: list[str] = []
    totals: dict[str, Decimal] = {}
    for line in lines:
        # Phase 10 (GATE 6): pack component rows are not charged — they would
        # otherwise double-report the sale ("1 pack" AND "6 piece").
        if line.get("pack_id") is not None and line.get("product_id") is not None:
            continue
        label = str(
            line.get("selling_unit_name") or line.get("product_unit") or ""
        ).strip()
        if not label:
            continue
        raw_qty = line.get("quantity", 0)
        qty = raw_qty if isinstance(raw_qty, Decimal) else Decimal(str(raw_qty or 0))
        if label not in totals:
            order.append(label)
            totals[label] = Decimal("0")
        totals[label] += qty
    if not order:
        return None
    groups = [f"{_display_qty(totals[label])} {label}" for label in order[:3]]
    summary = " · ".join(groups)
    if len(order) > 3:
        summary = f"{summary} +{len(order) - 3}"
    return summary


class _ResolvedLine:
    """Internal: one validated cart line ready for persistence.

    Phase 10 (GATE 6) line shapes:
      * product line  — ``product`` set, ``pack`` None,     ``charged=True``
      * pack summary  — ``product`` None, ``pack`` set,     ``charged=True``
      * pack component— ``product`` set, ``pack`` set,      ``charged=False``
    Component lines never contribute to money totals; their ``line_gross`` /
    ``line_discount`` / ``line_total`` are all 0 while ``unit_price`` keeps a
    catalog snapshot and ``unit_cost`` carries the COGS snapshot.
    """

    __slots__ = (
        "index",
        "product",
        "variant",
        "selling_unit",
        "quantity_base",
        "quantity_line",
        "unit_price",
        "unit_cost",
        "line_discount",
        "line_total",
        "line_gross",
        "price_override",
        "stock_quantity",
        "stock_before",
        "stock_after",
        "decrement_variant",
        "pack",
        "pack_summary",
        "charged",
    )

    def __init__(self) -> None:
        self.index: int = 0
        self.product: Product | None = None
        self.variant: ProductVariant | None = None
        self.selling_unit: ProductSellingUnit | None = None
        self.quantity_base: Decimal = Decimal("0")
        self.quantity_line: Decimal = Decimal("0")
        self.unit_price: Decimal = Decimal("0")
        self.unit_cost: Decimal = Decimal("0")
        self.line_discount: Decimal = Decimal("0")
        self.line_total: Decimal = Decimal("0")
        self.line_gross: Decimal = Decimal("0")
        self.price_override: PriceOverride | None = None
        self.stock_quantity: Decimal = Decimal("0")
        self.stock_before: Decimal | None = None
        self.stock_after: Decimal | None = None
        self.decrement_variant: bool = False
        self.pack: Pack | None = None
        self.pack_summary: bool = False
        self.charged: bool = True


class SaleService(BaseService):
    """Application service for POS checkout, holds, and favorites."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.sales = SaleRepository(db)
        self.products = ProductRepository(db)
        self.variants = ProductVariantRepository(db)
        self.selling_units = SellingUnitRepository(db)
        self.holds = PosHoldRepository(db)
        self.favorites = ProductFavoriteRepository(db)
        # Phase 18 — active promotion per product for THIS request
        # (None value = "checked, no active promotion"). Filled in bulk by
        # _prefetch_catalog; _promotion_for lazily fills any missed id.
        self._promotion_cache: dict[uuid.UUID, Promotion | None] = {}

    # ------------------------------------------------------------------
    # Line resolution / validation helpers
    # ------------------------------------------------------------------

    def _get_product(self, product_id: uuid.UUID, *, allow_archived: bool = False) -> Product:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        if not allow_archived and product.archived_at is not None:
            raise BusinessRuleError(
                message="Archived product cannot be sold",
                details={"product_id": str(product_id)},
            )
        return product

    def _get_customer(self, customer_id: uuid.UUID) -> Customer:
        customer = self.db.get(Customer, customer_id)
        if customer is None:
            raise NotFoundError(
                message="Customer not found",
                details={"customer_id": str(customer_id)},
            )
        if customer.archived_at is not None:
            raise BusinessRuleError(
                message="Archived customer cannot be used for credit sales",
                details={"customer_id": str(customer_id)},
            )
        return customer

    def _enforce_debt_ceiling(
        self, customer: Customer, new_debt: Decimal
    ) -> None:
        """Authoritative debt-ceiling gate (PHASE 9 BUG FIX).

        Re-reads the customer row under a FOR UPDATE row lock inside the
        sale transaction, so two concurrent credit sales cannot both read
        a stale balance and slip past the ceiling together.

        Semantics (existing app-wide): ``debt_ceiling == 0`` means NO
        ceiling (unlimited) — matches Flutter clients_screen over-limit
        logic and report §2.1. A ceiling is enforced only when > 0.

        Raises BusinessRuleError(code=DEBT_CEILING_EXCEEDED, 422) BEFORE
        any mutation; the transaction rolls back and nothing is written.
        """
        self.db.refresh(customer, with_for_update=True)
        ceiling = _money(to_decimal(customer.debt_ceiling))
        if ceiling <= 0:
            return
        current = _money(to_decimal(customer.balance))
        projected = _money(current + new_debt)
        if projected > ceiling:
            raise BusinessRuleError(
                message="Customer debt ceiling exceeded",
                code="DEBT_CEILING_EXCEEDED",
                details={
                    "customer_id": str(customer.id),
                    "current_balance": str(current),
                    "new_debt": str(new_debt),
                    "projected_balance": str(projected),
                    "debt_ceiling": str(ceiling),
                },
            )

    def _prefetch_catalog(self, items) -> list[Any]:
        """Bulk-load the catalog rows a cart references (one query per chunk).

        Loads products / variants / selling units up front so the per-line
        lookups in ``_resolve_line`` are served from the session identity
        map instead of one SELECT per cart line — a 10 000 line cart would
        otherwise issue 10 000 round trips before the sale transaction even
        starts.  Resolution logic is untouched: a missing or archived id
        still raises exactly the same error from the same code path, and
        pack components (loaded with their pack) are unaffected.

        The loaded instances are RETURNED and the caller must keep them
        referenced until resolution finishes: the identity map stores weak
        references, so without a strong ref the rows would be collected and
        every lookup would fall back to a SELECT.
        """
        product_ids: set[uuid.UUID] = set()
        variant_ids: set[uuid.UUID] = set()
        unit_ids: set[uuid.UUID] = set()
        for item in items:
            if item.product_id is not None:
                product_ids.add(item.product_id)
            if item.variant_id is not None:
                variant_ids.add(item.variant_id)
            if item.selling_unit_id is not None:
                unit_ids.add(item.selling_unit_id)

        loaded: list[Any] = []

        def _load(model, ids: set[uuid.UUID]) -> None:
            ordered = list(ids)
            for start in range(0, len(ordered), 1000):
                chunk = ordered[start : start + 1000]
                loaded.extend(self.db.scalars(select(model).where(model.id.in_(chunk))))

        _load(Product, product_ids)
        _load(ProductVariant, variant_ids)
        _load(ProductSellingUnit, unit_ids)
        self._prefetch_promotions(product_ids)
        return loaded

    def _prefetch_promotions(self, product_ids: set[uuid.UUID]) -> None:
        """Bulk-load the ACTIVE promotion of every cart product (1 query).

        Same purpose as ``_prefetch_catalog``: keep a 10 000-line cart at
        one query per request instead of one per line. The rows are kept
        in ``self._promotion_cache`` (strong refs), and a product with no
        active promotion is cached as None so it is never re-queried.
        """
        if not product_ids:
            return
        rows = self.db.execute(
            select(PromotionProduct.product_id, Promotion)
            .join(Promotion, Promotion.id == PromotionProduct.promotion_id)
            .where(
                PromotionProduct.product_id.in_(product_ids),
                Promotion.is_active.is_(True),
            )
            .order_by(Promotion.id)
        ).all()
        for product_id, promotion in rows:
            # First row wins (lowest promotion id) — mirrors the LIMIT 1
            # ordering in _promotion_for; the overlap rule keeps this to
            # one active promotion per product anyway.
            self._promotion_cache.setdefault(product_id, promotion)
        for product_id in product_ids:
            self._promotion_cache.setdefault(product_id, None)

    def _promotion_for(self, product_id: uuid.UUID) -> Promotion | None:
        """Active promotion covering [product_id], or None (cached)."""
        if product_id in self._promotion_cache:
            return self._promotion_cache[product_id]
        promotion = self.db.execute(
            select(Promotion)
            .join(Promotion, Promotion.id == PromotionProduct.promotion_id)
            .where(
                PromotionProduct.product_id == product_id,
                Promotion.is_active.is_(True),
            )
            .order_by(Promotion.id)
            .limit(1)
        ).scalar_one_or_none()
        self._promotion_cache[product_id] = promotion
        return promotion

    def _resolve_line(self, item, index: int, *, validate_stock: bool = True) -> _ResolvedLine:
        """Load product/variant/selling unit, resolve price, convert quantity."""
        line = _ResolvedLine()
        line.index = index

        if item.product_id is None:  # pragma: no cover — schema guarantees
            # SaleLineRequest requires exactly one of product_id/pack_id, so
            # a None here can only come from a caller bypassing the schema.
            raise ValidationError(
                message="product_id is required for a product line",
                details={"line_index": index},
            )

        product = self._get_product(item.product_id)
        line.product = product

        variant: ProductVariant | None = None
        if item.variant_id is not None:
            variant = self.variants.get_by_id(item.variant_id)
            if variant is None:
                raise NotFoundError(
                    message="Variant not found",
                    details={"variant_id": str(item.variant_id)},
                )
            if variant.product_id != product.id:
                raise ValidationError(
                    message="Variant does not belong to product",
                    details={
                        "variant_id": str(variant.id),
                        "product_id": str(product.id),
                    },
                )
            if variant.archived_at is not None:
                raise BusinessRuleError(
                    message="Archived variant cannot be sold",
                    details={"variant_id": str(variant.id)},
                )
            line.variant = variant
            line.decrement_variant = True

        selling_unit: ProductSellingUnit | None = None
        if item.selling_unit_id is not None:
            if item.variant_id is not None:
                raise ValidationError(
                    message="selling_unit_id cannot be combined with variant_id",
                    details={
                        "variant_id": str(item.variant_id),
                        "selling_unit_id": str(item.selling_unit_id),
                    },
                )
            selling_unit = self.selling_units.get_by_id(item.selling_unit_id)
            if selling_unit is None or selling_unit.product_id != product.id:
                raise ValidationError(
                    message="Selling unit does not belong to product",
                    details={
                        "selling_unit_id": str(item.selling_unit_id),
                        "product_id": str(product.id),
                    },
                )
            if selling_unit.archived_at is not None:
                raise BusinessRuleError(
                    message="Archived selling unit cannot be sold",
                    details={"selling_unit_id": str(selling_unit.id)},
                )
            line.selling_unit = selling_unit

        qty = to_decimal(item.quantity)
        if qty <= 0:
            raise ValidationError(
                message="quantity must be > 0",
                details={"line_index": index, "quantity": str(qty)},
            )

        # Phase 17/18 price precedence (see app/domain/wholesale.py and
        # app/domain/promotion.py):
        #   selling-unit price > variant price > product retail price
        #   (promotion may discount it, then the wholesale threshold may
        #   replace the discounted price) > pack price.
        # `line_uses_product_retail` is True only when the price came from
        # products.price on a BASE-unit line — the single case promotion
        # and wholesale pricing may touch.
        line_uses_product_retail = False
        if selling_unit is not None:
            line.quantity_line = qty
            line.quantity_base = selling_to_base(qty, selling_unit.multiplier)
            server_price = effective_unit_price(
                selling_unit.selling_price, product.price
            )
            # Wholesale belongs ONLY to the product's base/default unit.
            # A custom selling unit (Box/Carton/Pack) prices from its own
            # configured selling_price — or from the retail price when none
            # is configured — and NEVER from the product's wholesale rule.
            # Its multiplier only converts qty into quantity_base for stock;
            # it can never qualify the line for wholesale_min_qty.
            line_uses_product_retail = bool(
                selling_unit.is_base_unit and selling_unit.selling_price is None
            )
        else:
            line.quantity_line = qty
            line.quantity_base = qty.quantize(QTY_QUANTUM)
            if variant is not None and variant.price is not None:
                server_price = to_decimal(variant.price)
            else:
                line_uses_product_retail = True
                server_price = to_decimal(product.price)

        if line_uses_product_retail:
            # Phase 18 promotion — an ACTIVE promotion may only discount
            # the price this line takes from products.price (retail
            # branch). products.price itself is never written, so
            # deactivation restores retail on the next resolution.
            promotion = self._promotion_for(product.id)
            if promotion is not None:
                server_price = promotional_unit_price(
                    retail_price=server_price,
                    promotion_type=promotion.promotion_type,
                    value=promotion.value,
                )
            # Wholesale threshold, measured on the line's BASE quantity
            # (product units) — always equal to qty here, because only a
            # base-unit line reaches this branch. It evaluates against the
            # (possibly promoted) price, so the configured wholesale price
            # wins at/above the threshold exactly as it does versus retail.
            # Disabled wholesale returns the price unchanged. The server
            # computes this on its own — a client unit_price can never
            # invent a cheaper line.
            server_price = resolve_wholesale_unit_price(
                retail_price=server_price,
                wholesale_price=product.wholesale_price,
                wholesale_min_qty=product.wholesale_min_qty,
                quantity_base=line.quantity_base,
            )

        # Price policy: server authoritative price always wins.
        # Client unit_price is a display hint; mismatch is reported, not fatal.
        requested = to_decimal(item.unit_price)
        line.unit_price = _money(server_price)
        if requested != line.unit_price:
            line.price_override = PriceOverride(
                line_index=index,
                product_id=product.id,
                requested_unit_price=_money(requested),
                applied_unit_price=line.unit_price,
            )

        # Cost snapshot: variant cost if set, else product.avg_cost (PMP).
        # Never used to recompute PMP.
        if variant is not None and variant.cost is not None:
            line.unit_cost = _money(variant.cost)
        else:
            line.unit_cost = _money(product.avg_cost)

        # Stock availability
        if variant is not None:
            line.stock_quantity = to_decimal(variant.quantity)
        else:
            line.stock_quantity = to_decimal(product.quantity)

        if validate_stock:
            # Note: for packaging-aware products, stock packages are NOT
            # auto-broken here (Phase 10 / packaging sell path owns that).
            # Base quantity guard still applies.
            if line.quantity_base > line.stock_quantity:
                # allow_negative_stock is a product-level escape hatch
                if not product.allow_negative_stock:
                    raise BusinessRuleError(
                        message="Insufficient stock",
                        details={
                            "line_index": index,
                            "product_id": str(product.id),
                            "variant_id": str(variant.id) if variant else None,
                            "available": str(line.stock_quantity),
                            "required": str(line.quantity_base),
                        },
                    )

        line.line_gross = _money(line.unit_price * line.quantity_line)
        self._apply_line_discount(line, item, index)
        return line

    def _apply_line_discount(self, line: _ResolvedLine, item, index: int) -> None:
        """Validate and store the line discount (shared by product + pack)."""
        line_discount = _money(item.line_discount)
        if line_discount < 0:
            raise ValidationError(
                message="line_discount must be >= 0",
                details={"line_index": index},
            )
        if line_discount > line.line_gross:
            raise ValidationError(
                message="line_discount cannot exceed line gross",
                details={
                    "line_index": index,
                    "line_discount": str(line_discount),
                    "line_gross": str(line.line_gross),
                },
            )
        line.line_discount = line_discount
        line.line_total = _money(line.line_gross - line_discount)

    # ------------------------------------------------------------------
    # Pack lines (Phase 10)
    # ------------------------------------------------------------------

    def _get_pack(self, pack_id: uuid.UUID) -> Pack:
        """Load a pack for sale and enforce the saleable gate (GATE 8)."""
        pack = PackRepository(self.db).get_with_components(pack_id)
        if pack is None:
            raise NotFoundError(
                message="Pack not found",
                details={"pack_id": str(pack_id)},
            )
        if not pack.is_active or pack.archived_at is not None:
            raise BusinessRuleError(
                message="Pack is not active and cannot be sold",
                code="PACK_INACTIVE",
                details={
                    "pack_id": str(pack.id),
                    "pack_name": pack.name,
                    "is_active": bool(pack.is_active),
                    "is_archived": pack.archived_at is not None,
                },
            )
        return pack

    def _resolve_item(
        self,
        item,
        index: int,
        *,
        validate_stock: bool = True,
        demand: dict[tuple[uuid.UUID, uuid.UUID | None], Decimal] | None = None,
    ) -> list[_ResolvedLine]:
        """Resolve one request line into the persisted line set.

        A product line yields exactly one resolved line; a pack line yields
        the pack summary line first, followed by one line per component.
        ``demand`` accumulates component requirements across pack lines in
        this request (GATE 4 — "aggregate component quantities").
        """
        if item.pack_id is not None:
            return self._resolve_pack_line(
                item,
                index,
                validate_stock=validate_stock,
                demand=demand if demand is not None else {},
            )
        return [
            self._resolve_line(item, index, validate_stock=validate_stock)
        ]

    def _resolve_pack_line(
        self,
        item,
        index: int,
        *,
        validate_stock: bool = True,
        demand: dict[tuple[uuid.UUID, uuid.UUID | None], Decimal],
    ) -> list[_ResolvedLine]:
        """Resolve a pack cart line into [pack summary, component...].

        Raises BusinessRuleError(code="PACK_INACTIVE") for a non-saleable
        pack and BusinessRuleError(code="PACK_STOCK_INSUFFICIENT") listing
        EVERY shortage when aggregate component stock cannot cover demand.
        """
        pack = self._get_pack(item.pack_id)

        qty = to_decimal(item.quantity)
        if qty <= 0:
            raise ValidationError(
                message="quantity must be > 0",
                details={"line_index": index, "quantity": str(qty)},
            )

        components = PackRepository.component_rows(pack)
        if not components:
            raise BusinessRuleError(
                message="Pack has no components and cannot be sold",
                details={"pack_id": str(pack.id), "pack_name": pack.name},
            )

        # --- pack summary line (charged) -----------------------------------
        summary = _ResolvedLine()
        summary.index = index
        summary.pack = pack
        summary.pack_summary = True
        summary.charged = True
        summary.quantity_line = qty
        summary.quantity_base = qty.quantize(QTY_QUANTUM)
        summary.unit_cost = Decimal("0")  # GATE 9 — no pack-level COGS
        summary.stock_quantity = Decimal("999999")

        server_price = _money(to_decimal(pack.price))
        requested = to_decimal(item.unit_price)
        summary.unit_price = server_price
        if requested != server_price:
            summary.price_override = PriceOverride(
                line_index=index,
                product_id=None,
                pack_id=pack.id,
                requested_unit_price=_money(requested),
                applied_unit_price=server_price,
            )

        # --- component lines (not charged) + aggregate stock check ---------
        shortages: list[dict[str, Any]] = []
        component_lines: list[_ResolvedLine] = []
        max_packs: Decimal | None = None

        for component in components:
            product = component.component_product
            if product is None:
                product = self.db.get(Product, component.product_id)
            if product is None:
                raise NotFoundError(
                    message="Component product not found",
                    details={
                        "pack_id": str(pack.id),
                        "product_id": str(component.product_id),
                    },
                )
            if product.archived_at is not None:
                raise BusinessRuleError(
                    message="Pack component product is archived",
                    details={
                        "pack_id": str(pack.id),
                        "product_id": str(product.id),
                        "product_name": product.name,
                    },
                )

            per_pack = to_decimal(component.quantity)
            if per_pack <= 0:
                raise ValidationError(
                    message="Pack component quantity must be > 0",
                    details={
                        "pack_id": str(pack.id),
                        "product_id": str(product.id),
                        "quantity": str(per_pack),
                    },
                )

            key = (product.id, None)
            already = demand.get(key, Decimal("0"))
            need = _money(per_pack * qty)
            total_need = _money(already + need)
            stock = to_decimal(product.quantity)

            if validate_stock and not product.allow_negative_stock:
                if total_need > stock:
                    shortages.append(
                        {
                            "product_id": str(product.id),
                            "product_name": product.name,
                            "required": str(need),
                            "already_requested": str(_money(already)),
                            "available": str(stock),
                        }
                    )
                fits = int((stock - already) // per_pack) if per_pack > 0 else 0
                fits_dec = Decimal(max(0, fits))
                max_packs = (
                    fits_dec if max_packs is None else min(max_packs, fits_dec)
                )
            demand[key] = total_need

            line = _ResolvedLine()
            line.index = index
            line.pack = pack
            line.pack_summary = False
            line.charged = False  # GATE 6 — components are not charged
            line.product = product
            line.quantity_line = need
            line.quantity_base = need.quantize(QTY_QUANTUM)
            # Informational catalog snapshots: never feed totals or PMP.
            line.unit_price = _money(to_decimal(product.price))
            line.unit_cost = _money(to_decimal(product.avg_cost))
            line.stock_quantity = stock
            line.decrement_variant = False
            line.line_gross = Decimal("0")
            line.line_discount = Decimal("0")
            line.line_total = Decimal("0")
            component_lines.append(line)

        if shortages:
            raise BusinessRuleError(
                message="Insufficient stock for pack components",
                code="PACK_STOCK_INSUFFICIENT",
                details={
                    "line_index": index,
                    "pack_id": str(pack.id),
                    "pack_name": pack.name,
                    "requested_packs": str(qty),
                    "shortages": shortages,
                },
            )

        if max_packs is not None:
            summary.stock_quantity = max_packs

        # The summary is the only charged line: its gross is the pack price
        # times the number of packs (GATE 6 / GATE 10).
        summary.line_gross = _money(summary.unit_price * summary.quantity_line)
        self._apply_line_discount(summary, item, index)
        return [summary, *component_lines]

    # ------------------------------------------------------------------
    # Totals / payment validation
    # ------------------------------------------------------------------

    def _compute_totals(
        self,
        lines: list[_ResolvedLine],
        invoice_discount: Decimal,
        payment_method: str,
        paid: Decimal,
        customer_id: uuid.UUID | None,
    ) -> dict[str, Any]:
        invoice_discount = _money(invoice_discount)
        if invoice_discount < 0:
            raise ValidationError(message="invoice_discount must be >= 0")

        # Phase 10 (GATE 6): pack component lines are not charged — their
        # gross/discount are already 0, and filtering keeps the invariant
        # explicit rather than incidental.
        charged = [ln for ln in lines if ln.charged]
        subtotal = _money(sum((ln.line_gross for ln in charged), Decimal("0")))
        line_discounts = _money(
            sum((ln.line_discount for ln in charged), Decimal("0"))
        )
        if invoice_discount > subtotal:
            raise ValidationError(
                message="invoice_discount cannot exceed subtotal",
                details={
                    "invoice_discount": str(invoice_discount),
                    "subtotal": str(subtotal),
                },
            )

        # final = subtotal - line_discounts - invoice_discount
        # (line discounts already excluded from line_total; invoice applies to remaining)
        after_line_discounts = _money(subtotal - line_discounts)
        if invoice_discount > after_line_discounts:
            raise ValidationError(
                message="invoice_discount cannot exceed remaining amount after line discounts",
                details={
                    "invoice_discount": str(invoice_discount),
                    "remaining": str(after_line_discounts),
                },
            )
        total = _money(after_line_discounts - invoice_discount)
        paid = _money(paid)
        if paid < 0:
            raise ValidationError(message="paid must be >= 0")

        debt = _money(max(Decimal("0"), total - paid))
        change = _money(max(Decimal("0"), paid - total))

        method = PaymentMethod(payment_method)
        if method == PaymentMethod.CASH or method == PaymentMethod.CARD:
            if paid < total:
                raise ValidationError(
                    message=f"{method.value} payment requires paid >= total",
                    details={"paid": str(paid), "total": str(total)},
                )
            debt = Decimal("0")
            change = _money(paid - total)
        elif method == PaymentMethod.PARTIAL:
            if paid >= total and total > 0:
                raise ValidationError(
                    message="partial payment requires paid < total",
                    details={"paid": str(paid), "total": str(total)},
                )
            if debt <= 0:
                raise ValidationError(
                    message="partial payment with no remaining debt is invalid",
                    details={"paid": str(paid), "total": str(total)},
                )
            change = Decimal("0")
        elif method == PaymentMethod.CREDIT:
            if paid != 0:
                raise ValidationError(
                    message="credit payment requires paid = 0",
                    details={"paid": str(paid)},
                )
            debt = total
            change = Decimal("0")
        else:  # pragma: no cover — schema restricts to known methods
            raise ValidationError(
                message="unsupported payment method",
                details={"payment_method": payment_method},
            )

        if debt > 0:
            if customer_id is None:
                raise ValidationError(
                    message="customer_id is required when debt > 0",
                    details={"debt": str(debt)},
                )
            if total == 0:
                raise BusinessRuleError(
                    message="credit/partial not applicable to zero-total sale",
                    details={"total": str(total)},
                )

        return {
            "invoice_discount": invoice_discount,
            "subtotal": subtotal,
            "line_discounts": line_discounts,
            "total": total,
            "paid": paid if method != PaymentMethod.CREDIT else Decimal("0"),
            "change": change,
            "debt": debt,
            "payment_method": method,
        }

    # ------------------------------------------------------------------
    # Create sale (THE transaction)
    # ------------------------------------------------------------------

    def create_sale(
        self,
        request: CreateSaleRequest,
        *,
        user: User | None = None,
        device_id: str | None = None,
        require_pos_discount: bool = False,
        require_pos_credit: bool = False,
    ) -> SaleCreateResponse:
        """Create a sale atomically.

        Idempotency: if client_request_id already exists, return the original
        sale with idempotent_replay=True and do NOT create a second sale.
        """
        user_id = user.id if user is not None else None
        effective_device = device_id or request.device_id

        # --- Idempotency fast path (outside transaction) ---
        existing = self.sales.find_by_client_request_id(request.client_request_id)
        if existing is not None:
            logger.info(
                "sale_idempotent_replay",
                client_request_id=request.client_request_id,
                sale_id=str(existing.id),
            )
            return self._to_create_response(
                existing, idempotent_replay=True, price_overrides=[]
            )

        if not request.items:
            raise ValidationError(message="items must not be empty")

        # --- Resolve + validate all lines (read-only; raises before tx) ---
        # Demand map aggregates component requirements across pack lines in
        # this request only (GATE 4); plain product lines are unchanged.
        prefetched = self._prefetch_catalog(request.items)
        lines: list[_ResolvedLine] = []
        demand: dict[tuple[uuid.UUID, uuid.UUID | None], Decimal] = {}
        for idx, item in enumerate(request.items):
            lines.extend(
                self._resolve_item(item, idx, validate_stock=True, demand=demand)
            )
        del prefetched  # strong refs only needed while resolving (see helper)

        customer: Customer | None = None
        if request.customer_id is not None:
            customer = self._get_customer(request.customer_id)

        totals = self._compute_totals(
            lines,
            request.invoice_discount,
            request.payment_method,
            request.paid,
            request.customer_id,
        )

        if require_pos_discount:
            has_discount = totals["invoice_discount"] > 0 or any(
                ln.line_discount > 0 for ln in lines
            )
            if has_discount and (
                user is None or not user.has_permission(PermissionScope.POS_DISCOUNT)
            ):
                raise AuthorizationError(
                    message="Permission denied: pos_discount required for discounts",
                    details={"required_permission": "pos_discount"},
                )

        if require_pos_credit and totals["debt"] > 0:
            if user is None or not user.has_permission(PermissionScope.POS_CREDIT_SALE):
                raise AuthorizationError(
                    message="Permission denied: pos_credit_sale required for credit sales",
                    details={"required_permission": "pos_credit_sale"},
                )

        invoice_number = _generate_invoice_number()
        price_overrides = [
            ln.price_override for ln in lines if ln.price_override is not None
        ]

        # --- ONE transaction: everything or nothing ---
        try:
            with self.transaction() as tx:
                # PHASE 9 BUG FIX: debt-ceiling gate FIRST — authoritative
                # FOR UPDATE re-read of the customer row; raises before any
                # stock/sale mutation so a rejected checkout leaves zero
                # residue.
                if totals["debt"] > 0 and customer is not None:
                    self._enforce_debt_ceiling(customer, totals["debt"])

                # Guarded stock decrements first (rowcount = concurrency safety).
                # Pack summary lines own no stock (product is None) and are
                # skipped; their component lines are decremented here.
                for ln in lines:
                    if ln.product is None:
                        continue
                    self._decrement_stock(ln)

                sale = Sale(
                    invoice_number=invoice_number,
                    customer_id=request.customer_id,
                    user_id=user_id,
                    subtotal=float(totals["subtotal"]),
                    discount=float(totals["invoice_discount"]),
                    total=float(totals["total"]),
                    paid=float(totals["paid"]),
                    change=float(totals["change"]),
                    payment_method=totals["payment_method"].value,
                    client_request_id=request.client_request_id,
                    note=request.note,
                    device_id=effective_device,
                )
                tx.add(sale)
                tx.flush()  # assign sale.id for FKs

                for ln in lines:
                    tx.add(self._build_sale_line(sale_id=sale.id, line=ln))

                    if ln.product is None:
                        # Pack summary row: it charges the sale but owns no
                        # stock, so it writes no inventory movement.
                        continue

                    # Inventory movement (sale / pack_component) — atomic
                    # with the sale.
                    self._record_sale_movement(
                        tx,
                        line=ln,
                        sale_id=sale.id,
                        user_id=user_id,
                        device_id=effective_device,
                        invoice_number=invoice_number,
                    )

                # Payment row
                tx.add(
                    SalePayment(
                        sale_id=sale.id,
                        method=totals["payment_method"].value,
                        amount=float(totals["paid"]),
                    )
                )

                # Debt: balance + ledger in SAME transaction
                if totals["debt"] > 0 and customer is not None:
                    customer.balance = float(
                        _money(to_decimal(customer.balance) + totals["debt"])
                    )
                    tx.add(
                        DebtLedgerEntry(
                            customer_id=customer.id,
                            entry_type="sale",
                            amount=float(totals["debt"]),
                            reference_sale_id=sale.id,
                            note=f"Sale {invoice_number}",
                            user_id=user_id,
                        )
                    )

                tx.flush()
                sale_id = sale.id

            # After commit — re-read for response relationships
            sale = self.sales.get_by_id(sale_id)
            if sale is None:  # pragma: no cover — commit succeeded
                raise ConflictError(
                    message="Sale committed but could not be re-read",
                    details={"sale_id": str(sale_id)},
                )
            logger.info(
                "sale_created",
                sale_id=str(sale.id),
                invoice_number=invoice_number,
                total=str(totals["total"]),
                debt=str(totals["debt"]),
                payment_method=totals["payment_method"].value,
                lines=len(lines),
            )
            return self._to_create_response(
                sale, idempotent_replay=False, price_overrides=price_overrides
            )

        except IntegrityError as exc:
            # Unique client_request_id race: another request won — return theirs.
            self.db.rollback()
            winner = self.sales.find_by_client_request_id(request.client_request_id)
            if winner is not None:
                logger.info(
                    "sale_idempotent_race_replay",
                    client_request_id=request.client_request_id,
                    sale_id=str(winner.id),
                )
                return self._to_create_response(
                    winner, idempotent_replay=True, price_overrides=[]
                )
            logger.error(
                "sale_integrity_error",
                exc_message=str(exc),
                client_request_id=request.client_request_id,
            )
            raise ConflictError(
                message="Sale could not be saved due to a conflict",
                details={"client_request_id": request.client_request_id},
            ) from exc

    def _build_sale_line(self, *, sale_id: uuid.UUID, line: _ResolvedLine) -> SaleLine:
        """Map a resolved line onto its persisted SaleLine row (GATE 6).

        * product line  — product_id set, pack_id null, money charged
        * pack summary  — product_id NULL, pack_id set, money charged,
                          ``product_unit`` snapshotted as ``pack``
        * pack component— product_id set, pack_id set, line_total 0
        """
        if line.pack_summary:
            pack = line.pack
            assert pack is not None
            return SaleLine(
                sale_id=sale_id,
                product_id=None,
                pack_id=pack.id,
                product_name=pack.name,
                product_sku=None,
                product_barcode=pack.barcode,
                product_unit=ProductUnit.PACK.value,
                variant_name=None,
                selling_unit_name=None,
                selling_unit_multiplier=None,
                unit_price=float(line.unit_price),
                unit_cost=float(line.unit_cost),
                quantity=float(line.quantity_line),
                line_discount=float(line.line_discount),
                line_total=float(line.line_total),
            )

        product = line.product
        assert product is not None
        if line.pack is not None:
            # Component row: base product only (GATE 1) — no variant and no
            # selling unit can ever appear on a pack component line.
            return SaleLine(
                sale_id=sale_id,
                product_id=product.id,
                pack_id=line.pack.id,
                product_name=product.name,
                product_sku=product.sku,
                product_barcode=product.barcode,
                product_unit=product.unit,
                variant_name=None,
                selling_unit_name=None,
                selling_unit_multiplier=None,
                unit_price=float(line.unit_price),
                unit_cost=float(line.unit_cost),
                quantity=float(line.quantity_line),
                line_discount=0.0,
                line_total=0.0,
            )

        return SaleLine(
            sale_id=sale_id,
            product_id=product.id,
            pack_id=None,
            variant_id=line.variant.id if line.variant else None,
            product_name=product.name,
            product_sku=product.sku,
            product_barcode=(
                line.variant.barcode
                if line.variant and line.variant.barcode
                else product.barcode
            ),
            product_unit=product.unit,
            # UX FIX #11: historical display snapshots resolved
            # from the authoritative catalog inside this same
            # transaction (client never sends names).
            variant_name=line.variant.name if line.variant else None,
            selling_unit_name=(
                line.selling_unit.name if line.selling_unit else None
            ),
            selling_unit_multiplier=(
                float(line.selling_unit.multiplier) if line.selling_unit else None
            ),
            unit_price=float(line.unit_price),
            unit_cost=float(line.unit_cost),
            quantity=float(line.quantity_line),
            line_discount=float(line.line_discount),
            line_total=float(line.line_total),
        )

    def _decrement_stock(self, ln: _ResolvedLine) -> None:
        """Guarded stock decrement inside the open transaction.

        Captures stock_before / stock_after on the line for movement rows
        so multi-line sales of the same product stay correct.

        The guarded UPDATE carries ``RETURNING`` so the new quantity comes
        back with the same statement: one round trip per line instead of
        UPDATE + ``refresh`` SELECT, and the identity map is updated
        committed (never dirty) via ``set_committed_value`` — the follow-up
        flush therefore issues no extra UPDATE.  Zero rows returned still
        means "lost the concurrency race / insufficient stock" and raises
        exactly the same ConflictError as before.
        """
        assert ln.product is not None
        product = ln.product
        qty = ln.quantity_base

        if ln.decrement_variant:
            assert ln.variant is not None
            before = to_decimal(ln.variant.quantity)
            # DECIDED: variant sale decrements variant.quantity ONLY.
            # Parent products.quantity is NOT touched (no double decrement).
            # Use Decimal (not float) so ORM post-sync evaluation succeeds.
            stmt = (
                update(ProductVariant)
                .where(ProductVariant.id == ln.variant.id)
                .values(quantity=ProductVariant.quantity - qty)
                .returning(ProductVariant.quantity)
            )
            if not product.allow_negative_stock:
                stmt = stmt.where(ProductVariant.quantity >= qty)
            result = self.db.execute(
                stmt.execution_options(synchronize_session=False)
            )
            row = result.first()
            if row is None:
                raise ConflictError(
                    message="Insufficient variant stock (concurrent sale)",
                    details={
                        "variant_id": str(ln.variant.id),
                        "product_id": str(product.id),
                        "required": str(qty),
                        "available": str(ln.stock_quantity),
                    },
                )
            set_committed_value(ln.variant, "quantity", row[0])
            ln.stock_before = before
            ln.stock_after = to_decimal(ln.variant.quantity)
            return

        before = to_decimal(product.quantity)
        stmt = (
            update(Product)
            .where(Product.id == product.id)
            .values(quantity=Product.quantity - qty)
            .returning(Product.quantity)
        )
        if not product.allow_negative_stock:
            stmt = stmt.where(Product.quantity >= qty)
        result = self.db.execute(
            stmt.execution_options(synchronize_session=False)
        )
        row = result.first()
        if row is None:
            raise ConflictError(
                message="Insufficient stock (concurrent sale)",
                details={
                    "product_id": str(product.id),
                    "required": str(qty),
                    "available": str(ln.stock_quantity),
                },
            )
        set_committed_value(product, "quantity", row[0])
        ln.stock_before = before
        ln.stock_after = to_decimal(product.quantity)

    def _record_sale_movement(
        self,
        tx: Session,
        *,
        line: _ResolvedLine,
        sale_id: uuid.UUID,
        user_id: uuid.UUID | None,
        device_id: str | None,
        invoice_number: str,
    ) -> None:
        assert line.product is not None
        product = line.product
        variant = line.variant

        if line.stock_before is None or line.stock_after is None:
            # Fallback if movement is recorded without a prior decrement.
            if variant is not None:
                after = to_decimal(variant.quantity)
                before = after + line.quantity_base
            else:
                after = to_decimal(product.quantity)
                before = after + line.quantity_base
        else:
            before = line.stock_before
            after = line.stock_after

        # PMP snapshot: avg_cost is authoritative and MUST remain unchanged.
        avg_after = quantize_money(to_decimal(product.avg_cost))

        # GATE 5: component deductions are typed PACK_COMPONENT so pack-driven
        # stock drops stay distinguishable from plain sales in reports.
        is_component = line.pack is not None
        movement = InventoryMovement(
            product_id=product.id,
            variant_id=variant.id if variant else None,
            movement_type=(
                StockMovementType.PACK_COMPONENT.value
                if is_component
                else StockMovementType.SALE.value
            ),
            quantity_change=float(-line.quantity_base),
            quantity_before=float(before),
            quantity_after=float(after),
            unit_cost=float(line.unit_cost),
            avg_cost_after=float(avg_after),
            reason=(
                f"Pack sale {invoice_number}"
                if is_component
                else f"Sale {invoice_number}"
            ),
            user_id=user_id,
            device_id=device_id,
            source_document_type="sale",
            source_document_id=sale_id,
        )
        tx.add(movement)

    # ------------------------------------------------------------------
    # Response mapping
    # ------------------------------------------------------------------

    def _to_create_response(
        self,
        sale: Sale,
        *,
        idempotent_replay: bool,
        price_overrides: list[PriceOverride],
    ) -> SaleCreateResponse:
        debt = _money(max(Decimal("0"), to_decimal(sale.total) - to_decimal(sale.paid)))
        if sale.payment_method == PaymentMethod.CREDIT.value:
            debt = to_decimal(sale.total)
            paid = Decimal("0")
            change = Decimal("0")
        else:
            paid = to_decimal(sale.paid)
            change = to_decimal(sale.change)
            if sale.payment_method in (
                PaymentMethod.CASH.value,
                PaymentMethod.CARD.value,
            ):
                debt = Decimal("0")

        lines = [
            SaleLineResponse(
                id=ln.id,
                product_id=ln.product_id,
                pack_id=ln.pack_id,
                variant_id=ln.variant_id,
                product_name=ln.product_name,
                product_sku=ln.product_sku,
                product_barcode=ln.product_barcode,
                product_unit=ln.product_unit,
                variant_name=ln.variant_name,
                selling_unit_name=ln.selling_unit_name,
                selling_unit_multiplier=(
                    to_decimal(ln.selling_unit_multiplier)
                    if ln.selling_unit_multiplier is not None
                    else None
                ),
                unit_price=to_decimal(ln.unit_price),
                unit_cost=to_decimal(ln.unit_cost),
                quantity=to_decimal(ln.quantity),
                line_discount=to_decimal(ln.line_discount),
                line_total=to_decimal(ln.line_total),
            )
            for ln in sale.lines
        ]
        payments = [
            SalePaymentResponse(
                id=p.id,
                method=p.method,
                amount=to_decimal(p.amount),
            )
            for p in sale.payments
        ]
        return SaleCreateResponse(
            id=sale.id,
            invoice_number=sale.invoice_number,
            client_request_id=sale.client_request_id,
            customer_id=sale.customer_id,
            status=sale.status,
            subtotal=to_decimal(sale.subtotal),
            discount=to_decimal(sale.discount),
            total=to_decimal(sale.total),
            paid=paid,
            change=change,
            debt=debt,
            payment_method=sale.payment_method,
            device_id=sale.device_id,
            note=sale.note,
            sale_date=sale.sale_date,
            lines=lines,
            payments=payments,
            idempotent_replay=idempotent_replay,
            price_overrides=price_overrides,
        )

    def _to_sale_response(self, sale: Sale, *, with_header: bool = False) -> SaleResponse:
        created = self._to_create_response(
            sale, idempotent_replay=False, price_overrides=[]
        )
        payload = created.model_dump(exclude={"price_overrides"})
        # Computed, additive: history rows can show what was sold without
        # opening Sale Detail (UX FIX #12 — FIX #1).
        payload["unit_summary"] = unit_summary_from_lines(payload.get("lines") or [])
        # Phase 12: void attribution on the frozen snapshot (GATE 9).
        payload["voided_at"] = sale.voided_at
        payload["voided_by"] = sale.voided_by
        payload["void_reason"] = sale.void_reason
        # G19 (Phase 15): display names only on the detail/print path —
        # sale.customer / sale.user are selectin-loaded, so at most the
        # eager join is touched, never an N+1 over list rows.
        if with_header:
            customer = sale.customer if sale.customer_id is not None else None
            payload["customer_name"] = customer.name if customer is not None else None
            payload["cashier_name"] = sale.user.full_name if sale.user is not None else None
            payload["store"] = {"name": settings.STORE_NAME}
        return SaleResponse.model_validate(payload)

    # ------------------------------------------------------------------
    # Sale history (minimal — pos_sale)
    # ------------------------------------------------------------------

    def get_sale(self, sale_id: uuid.UUID) -> SaleResponse:
        sale = self.sales.get_by_id(sale_id)
        if sale is None:
            raise NotFoundError(
                message="Sale not found",
                details={"sale_id": str(sale_id)},
            )
        return self._to_sale_response(sale, with_header=True)

    def get_sale_by_invoice(self, invoice_number: str) -> SaleResponse:
        sale = self.sales.find_by_invoice_number(invoice_number)
        if sale is None:
            raise NotFoundError(
                message="Sale not found",
                details={"invoice_number": invoice_number},
            )
        return self._to_sale_response(sale, with_header=True)

    def list_sales(
        self, *, page: int = 1, page_size: int = 50, user_id: uuid.UUID | None = None
    ) -> dict[str, Any]:
        page = max(1, page)
        page_size = max(1, min(page_size, 100))
        total = self.sales.count_sales()
        items = self.sales.list_recent(
            limit=page_size, offset=(page - 1) * page_size, user_id=user_id
        )
        import math

        pages = math.ceil(total / page_size) if total > 0 else 1
        return {
            "items": [self._to_sale_response(s) for s in items],
            "total": total,
            "page": page,
            "page_size": page_size,
            "pages": pages,
        }

    # ------------------------------------------------------------------
    # Cart validate (stateless revalidation before payment)
    # ------------------------------------------------------------------

    def validate_cart(self, request: CartValidateRequest) -> CartValidateResponse:
        lines_out: list[CartLineValidation] = []
        errors: list[str] = []
        resolved: list[_ResolvedLine] = []
        subtotal = Decimal("0")
        line_discounts = Decimal("0")
        demand: dict[tuple[uuid.UUID, uuid.UUID | None], Decimal] = {}
        prefetched = self._prefetch_catalog(request.items)

        for idx, item in enumerate(request.items):
            try:
                resolved_lines = self._resolve_item(
                    item, idx, validate_stock=True, demand=demand
                )
                resolved.extend(resolved_lines)
                for ln in resolved_lines:
                    if not ln.charged:
                        continue  # pack component rows never feed totals
                    subtotal += ln.line_gross
                    line_discounts += ln.line_discount
                # The first resolved line is always the charged one: the pack
                # summary for a pack line, the product line otherwise.
                primary = resolved_lines[0]
                lines_out.append(
                    CartLineValidation(
                        line_index=idx,
                        product_id=(
                            primary.product.id if primary.product else None
                        ),
                        pack_id=primary.pack.id if primary.pack else None,
                        variant_id=primary.variant.id if primary.variant else None,
                        ok=True,
                        available_stock=primary.stock_quantity,
                        required_quantity=primary.quantity_base,
                        unit_price=primary.unit_price,
                        is_archived=False,
                    )
                )
            except (NotFoundError, BusinessRuleError, ValidationError) as exc:
                errors.append(f"line {idx}: {exc.message}")
                lines_out.append(
                    CartLineValidation(
                        line_index=idx,
                        product_id=item.product_id,
                        pack_id=item.pack_id,
                        variant_id=item.variant_id,
                        ok=False,
                        message=exc.message,
                        is_archived=isinstance(exc, BusinessRuleError)
                        and "Archived" in exc.message,
                    )
                )

        del prefetched  # strong refs only needed while resolving (see helper)
        ok = not errors and bool(resolved)
        discount = Decimal("0")
        total = Decimal("0")
        paid = request.paid
        change = Decimal("0")
        debt = Decimal("0")
        if ok:
            try:
                totals = self._compute_totals(
                    resolved,
                    request.invoice_discount,
                    request.payment_method,
                    request.paid,
                    request.customer_id,
                )
                discount = totals["invoice_discount"]
                total = totals["total"]
                paid = totals["paid"]
                change = totals["change"]
                debt = totals["debt"]
            except (ValidationError, BusinessRuleError) as exc:
                ok = False
                errors.append(exc.message)

        return CartValidateResponse(
            ok=ok,
            lines=lines_out,
            subtotal=_money(subtotal),
            discount=_money(discount),
            total=_money(total),
            paid=_money(paid),
            change=_money(change),
            debt=_money(debt),
            errors=errors,
        )

    # ------------------------------------------------------------------
    # Holds (snapshots only — no stock reservation)
    # ------------------------------------------------------------------

    def create_hold(
        self,
        request: HoldCreateRequest,
        *,
        user: User | None = None,
    ) -> HoldResponse:
        user_id = user.id if user is not None else None
        snapshot = {
            "items": [i.model_dump(mode="json") for i in request.items],
        }
        hold = PosHold(
            user_id=user_id,
            device_id=request.device_id,
            customer_id=request.customer_id,
            cart_snapshot=snapshot,
            invoice_discount=float(_money(request.invoice_discount)),
            note=request.note,
        )
        with self.transaction() as tx:
            tx.add(hold)
            tx.flush()
            hold_id = hold.id
        hold = self.holds.get_by_id(hold_id)
        assert hold is not None
        return self._to_hold_response(hold)

    def list_holds(
        self,
        *,
        user: User | None = None,
        device_id: str | None = None,
    ) -> HoldListResponse:
        items = self.holds.list_for_user(
            user_id=user.id if user else None,
            device_id=device_id,
        )
        return HoldListResponse(
            items=[self._to_hold_response(h) for h in items],
            total=len(items),
        )

    def get_hold(self, hold_id: uuid.UUID) -> HoldResponse:
        hold = self.holds.get_by_id(hold_id)
        if hold is None:
            raise NotFoundError(
                message="Hold not found",
                details={"hold_id": str(hold_id)},
            )
        return self._to_hold_response(hold)

    def delete_hold(self, hold_id: uuid.UUID) -> None:
        hold = self.holds.get_by_id(hold_id)
        if hold is None:
            raise NotFoundError(
                message="Hold not found",
                details={"hold_id": str(hold_id)},
            )
        with self.transaction() as tx:
            tx.delete(hold)

    def restore_hold(self, hold_id: uuid.UUID) -> HoldRestoreResponse:
        """Return snapshot + revalidate current stock/prices. Does NOT reserve stock."""
        hold = self.holds.get_by_id(hold_id)
        if hold is None:
            raise NotFoundError(
                message="Hold not found",
                details={"hold_id": str(hold_id)},
            )
        hold_resp = self._to_hold_response(hold)
        from app.schemas.sale import SaleLineRequest

        lines_out: list[CartLineValidation] = []
        errors: list[str] = []
        demand: dict[tuple[uuid.UUID, uuid.UUID | None], Decimal] = {}
        prefetched = self._prefetch_catalog(hold_resp.items)
        for idx, raw in enumerate(hold_resp.items):
            item = SaleLineRequest.model_validate(raw.model_dump())
            try:
                resolved_lines = self._resolve_item(
                    item, idx, validate_stock=True, demand=demand
                )
                primary = resolved_lines[0]
                lines_out.append(
                    CartLineValidation(
                        line_index=idx,
                        product_id=(
                            primary.product.id if primary.product else None
                        ),
                        pack_id=primary.pack.id if primary.pack else None,
                        variant_id=(
                            primary.variant.id if primary.variant else None
                        ),
                        ok=True,
                        available_stock=primary.stock_quantity,
                        required_quantity=primary.quantity_base,
                        unit_price=primary.unit_price,
                    )
                )
            except (NotFoundError, BusinessRuleError, ValidationError) as exc:
                errors.append(f"line {idx}: {exc.message}")
                lines_out.append(
                    CartLineValidation(
                        line_index=idx,
                        product_id=item.product_id,
                        pack_id=item.pack_id,
                        variant_id=item.variant_id,
                        ok=False,
                        message=exc.message,
                    )
                )
        del prefetched  # strong refs only needed while resolving (see helper)
        # FIX #5: successful restore removes the hold (atomic from user view).
        # Validation errors keep the hold so the client can retry.
        if not errors:
            with self.transaction() as tx:
                tx.delete(hold)
        return HoldRestoreResponse(
            hold=hold_resp,
            lines=lines_out,
            ok=not errors,
            errors=errors,
        )

    def _to_hold_response(self, hold: PosHold) -> HoldResponse:
        raw_items = (hold.cart_snapshot or {}).get("items", [])
        items = [HoldCartItem.model_validate(i) for i in raw_items]
        return HoldResponse(
            id=hold.id,
            user_id=hold.user_id,
            device_id=hold.device_id,
            customer_id=hold.customer_id,
            items=items,
            invoice_discount=to_decimal(hold.invoice_discount),
            note=hold.note,
            created_at=hold.created_at,
        )

    # ------------------------------------------------------------------
    # Favorites (minimal manual pins)
    # ------------------------------------------------------------------

    def list_favorites(self, *, user: User | None = None) -> FavoriteListResponse:
        rows = self.favorites.list_for_user(user_id=user.id if user else None)
        items: list[FavoriteResponse] = []
        for row in rows:
            product = self.products.get_by_id(row.product_id)
            if product is None:
                continue
            items.append(
                FavoriteResponse(
                    id=row.id,
                    product_id=product.id,
                    product_name=product.name,
                    barcode=product.barcode,
                    price=to_decimal(product.price),
                    quantity=to_decimal(product.quantity),
                    is_archived=product.archived_at is not None,
                    created_at=row.created_at,
                )
            )
        return FavoriteListResponse(items=items, total=len(items))

    def add_favorite(
        self, product_id: uuid.UUID, *, user: User | None = None
    ) -> FavoriteToggleResponse:
        product = self.products.get_by_id(product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(product_id)},
            )
        user_id = user.id if user else None
        existing = self.favorites.find(product_id=product_id, user_id=user_id)
        if existing is None:
            with self.transaction() as tx:
                tx.add(ProductFavorite(product_id=product_id, user_id=user_id))
        return FavoriteToggleResponse(favorited=True, product_id=product_id)

    def remove_favorite(
        self, product_id: uuid.UUID, *, user: User | None = None
    ) -> FavoriteToggleResponse:
        user_id = user.id if user else None
        existing = self.favorites.find(product_id=product_id, user_id=user_id)
        if existing is None:
            # Idempotent delete — already not favorited
            return FavoriteToggleResponse(favorited=False, product_id=product_id)
        with self.transaction() as tx:
            tx.delete(existing)
        return FavoriteToggleResponse(favorited=False, product_id=product_id)
