"""Promotion application service (Phase 18).

Operations:
- ``list``   GET  /promotions             — filtered, paginated
- ``get``    GET  /promotions/{id}
- ``create`` POST /promotions             — idempotent, BULK (one
  transactional request applies the promotion to every selected product)
- ``update`` PUT  /promotions/{id}        — partial, membership replace
- ``toggle`` POST /promotions/{id}/toggle — active ⇄ inactive
- ``promotion_info_for`` — active-promotion lookup used by the product
  responses (POS/catalog display)

Hard rules:
- ``products.price`` is NEVER written; deactivation restores retail
  instantly because the discount is computed at resolution time.
- MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED — a fixed price cannot target a
  set of products (422, also guarded in the Flutter form).
- INVALID_PROMOTION_VALUE — percentage must satisfy 0 < value <= 100.
- Overlap: a product may belong to at most ONE ACTIVE promotion. Every
  write that could make a promotion active locks the involved product
  rows first, then checks — conflicts are 409 PROMOTION_PRODUCT_CONFLICT.
- Bulk create is ALL-OR-NOTHING: validation, insert and membership rows
  share one transaction; any failure rolls everything back.
"""

from __future__ import annotations

import math
import uuid

import structlog
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError, NotFoundError, ValidationError
from app.domain.promotion import promotional_unit_price
from app.domain.unit_conversions import to_decimal
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.enums import AuditAction, PromotionType
from app.models.promotion import Promotion
from app.repositories.promotion import PromotionRepository
from app.schemas.common import PaginatedResponse
from app.schemas.promotion import (
    ProductPromotionInfo,
    PromotionCreateRequest,
    PromotionProductRef,
    PromotionResponse,
    PromotionUpdateRequest,
)
from app.services.base import BaseService

logger = structlog.get_logger(__name__)

DEFAULT_PAGE_SIZE = 40


class PromotionService(BaseService):
    """Application service for promotions."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = PromotionRepository(db)

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = DEFAULT_PAGE_SIZE,
        q: str | None = None,
        is_active: bool | None = None,
    ) -> PaginatedResponse[PromotionResponse]:
        rows, total = self.repo.search(
            page=page, page_size=page_size, q=q, is_active=is_active
        )
        pages = max(1, math.ceil(total / page_size)) if total else 1
        names = self.repo.products_by_promotion({p.id for p in rows})
        return PaginatedResponse[PromotionResponse](
            items=[to_response(p, names.get(p.id, [])) for p in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=pages,
        )

    def get(self, promotion_id: uuid.UUID) -> PromotionResponse:
        promotion = self._get(promotion_id)
        names = self.repo.products_by_promotion({promotion.id})
        return to_response(promotion, names.get(promotion.id, []))

    def _get(self, promotion_id: uuid.UUID) -> Promotion:
        promotion = self.repo.get_by_id(promotion_id)
        if promotion is None:
            raise NotFoundError(
                message="Promotion not found",
                code="PROMOTION_NOT_FOUND",
                details={"promotion_id": str(promotion_id)},
            )
        return promotion

    def promotion_info_for(
        self, prices: dict[uuid.UUID, object]
    ) -> dict[uuid.UUID, ProductPromotionInfo]:
        """Active promotion + server-computed promo price per product.

        ``prices`` maps product id → retail unit price, so the effective
        promotional price is derived with the SAME domain function the
        checkout uses — one source of truth for every surface.
        """
        if not prices:
            return {}
        memberships = self.repo.active_memberships(set(prices))
        info: dict[uuid.UUID, ProductPromotionInfo] = {}
        for product_id, promotion in memberships.items():
            retail = prices[product_id]
            info[product_id] = ProductPromotionInfo(
                id=promotion.id,
                name=promotion.name,
                promotion_type=promotion.promotion_type,
                value=to_decimal(promotion.value),
                price=promotional_unit_price(
                    retail_price=retail,
                    promotion_type=promotion.promotion_type,
                    value=promotion.value,
                ),
            )
        return info

    # ------------------------------------------------------------------
    # Create (idempotent, bulk, atomic)
    # ------------------------------------------------------------------

    def create(
        self, request: PromotionCreateRequest, *, user=None
    ) -> PromotionResponse:
        """Create one promotion over MANY products in ONE transaction.

        Idempotency follows the Phase 13 expenses pattern: a repeat with
        the same key AND payload returns the original row with
        ``idempotent_replay=true``; a different payload is 409
        IDEMPOTENCY_CONFLICT; a unique-key race re-fetches the winner.
        """
        actor_id = user.id if user is not None else None
        key = request.client_request_id

        existing = self.repo.find_by_client_request_id(key)
        if existing is not None:
            self._assert_same_payload(existing, request)
            logger.info(
                "promotion_idempotent_replay",
                client_request_id=key,
                promotion_id=str(existing.id),
            )
            names = self.repo.products_by_promotion({existing.id})
            return to_response(
                existing, names.get(existing.id, []), idempotent_replay=True
            )

        try:
            created_id = self._insert(request, actor_id=actor_id)
        except ConflictError as exc:
            if exc.code == "PROMOTION_PRODUCT_CONFLICT":
                raise  # business-rule conflict, not an idempotency race
            winner = self.repo.find_by_client_request_id(key)
            if winner is not None:
                self._assert_same_payload(winner, request)
                logger.info(
                    "promotion_idempotent_race_replay",
                    client_request_id=key,
                    promotion_id=str(winner.id),
                )
                names = self.repo.products_by_promotion({winner.id})
                return to_response(
                    winner,
                    names.get(winner.id, []),
                    idempotent_replay=True,
                )
            raise

        saved = self.repo.get_by_id(created_id)
        if saved is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Promotion committed but could not be re-read",
                details={"promotion_id": str(created_id)},
            )
        logger.info(
            "promotion_created",
            promotion_id=str(saved.id),
            name=saved.name,
            promotion_type=saved.promotion_type,
            value=str(to_decimal(saved.value)),
            is_active=bool(saved.is_active),
            product_count=len(request.product_ids),
        )
        names = self.repo.products_by_promotion({saved.id})
        return to_response(saved, names.get(saved.id, []))

    def _insert(
        self, request: PromotionCreateRequest, *, actor_id: uuid.UUID | None
    ) -> uuid.UUID:
        product_ids = list(request.product_ids)
        self._validate_rule(request.promotion_type, request.value, product_ids)

        with self.transaction():
            missing = self._missing_products(product_ids)
            if missing:
                raise ValidationError(
                    message="Some products do not exist",
                    code="UNKNOWN_PRODUCT",
                    details={"product_ids": [str(m) for m in missing]},
                )
            # Lock BEFORE the overlap check so two concurrent promotions
            # targeting the same product serialize here. Only an ACTIVE
            # promotion claims the product — an inactive create may
            # overlap freely (it cannot win any price until activated).
            if request.is_active:
                self.repo.lock_products(set(product_ids))
                self._assert_no_active_overlap(product_ids)

            promotion = Promotion(
                name=request.name,
                promotion_type=request.promotion_type,
                value=request.value,
                is_active=request.is_active,
                client_request_id=request.client_request_id,
                created_by=actor_id,
            )
            self.repo.create(promotion)
            if product_ids:
                self.repo.add_products(promotion.id, product_ids)
            self._audit(
                AuditAction.CREATE,
                entity_id=promotion.id,
                actor_id=actor_id,
                details=(
                    f"created promotion '{promotion.name}' "
                    f"[{promotion.promotion_type} {to_decimal(promotion.value)}] "
                    f"for {len(product_ids)} product(s), "
                    f"active={bool(promotion.is_active)}"
                ),
            )
            return promotion.id

    # ------------------------------------------------------------------
    # Update (partial)
    # ------------------------------------------------------------------

    def update(
        self,
        promotion_id: uuid.UUID,
        request: PromotionUpdateRequest,
        *,
        user=None,
    ) -> PromotionResponse:
        """Partial update. ``product_ids`` replaces the whole membership."""
        actor_id = user.id if user is not None else None
        promotion = self._get(promotion_id)
        # An explicit JSON null means "no opinion" on this API (the schema
        # keeps the key optional), so drop it — otherwise `name: null`
        # would overwrite NOT NULL columns with None.
        updates = {
            k: v
            for k, v in request.model_dump(exclude_unset=True).items()
            if v is not None
        }

        name = updates.get("name", promotion.name)
        promotion_type = updates.get("promotion_type", promotion.promotion_type)
        value = updates.get("value", promotion.value)
        is_active = updates.get("is_active", promotion.is_active)
        replaces_products = "product_ids" in updates
        product_ids = (
            list(updates["product_ids"]) if replaces_products else self._product_ids(promotion)
        )

        self._validate_rule(promotion_type, value, product_ids)

        with self.transaction():
            missing = self._missing_products(product_ids)
            if missing:
                raise ValidationError(
                    message="Some products do not exist",
                    code="UNKNOWN_PRODUCT",
                    details={"product_ids": [str(m) for m in missing]},
                )
            if is_active:
                # Activating (or staying active while the set changes)
                # must not collide with another ACTIVE promotion.
                self.repo.lock_products(set(product_ids))
                self._assert_no_active_overlap(
                    product_ids, exclude_promotion_id=promotion.id
                )

            promotion.name = name
            promotion.promotion_type = promotion_type
            promotion.value = value
            promotion.is_active = is_active
            if replaces_products:
                self.repo.replace_products(promotion.id, product_ids)
            self.db.flush()
            self._audit(
                AuditAction.UPDATE,
                entity_id=promotion.id,
                actor_id=actor_id,
                details=(
                    f"updated promotion '{promotion.name}' "
                    f"[{promotion.promotion_type} {to_decimal(promotion.value)}], "
                    f"active={bool(is_active)}, "
                    f"products={len(product_ids)}"
                ),
            )

        self.db.expire_all()
        saved = self._get(promotion_id)
        names = self.repo.products_by_promotion({saved.id})
        return to_response(saved, names.get(saved.id, []))

    # ------------------------------------------------------------------
    # Toggle (active ⇄ inactive)
    # ------------------------------------------------------------------

    def toggle(
        self, promotion_id: uuid.UUID, *, user=None
    ) -> PromotionResponse:
        """Flip ``is_active`` atomically.

        Activating takes the same product locks + overlap check as
        create/update; deactivating is always safe (retail restores on
        the next price resolution, nothing is rewritten).
        """
        actor_id = user.id if user is not None else None
        promotion = self._get(promotion_id)

        with self.transaction():
            if promotion.is_active:
                promotion.is_active = False
                self.db.flush()
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=promotion.id,
                    actor_id=actor_id,
                    details=f"deactivated promotion '{promotion.name}'",
                )
                logger.info(
                    "promotion_deactivated",
                    promotion_id=str(promotion.id),
                    name=promotion.name,
                )
            else:
                product_ids = self._product_ids(promotion)
                self.repo.lock_products(set(product_ids))
                self._assert_no_active_overlap(
                    product_ids, exclude_promotion_id=promotion.id
                )
                promotion.is_active = True
                self.db.flush()
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=promotion.id,
                    actor_id=actor_id,
                    details=f"activated promotion '{promotion.name}'",
                )
                logger.info(
                    "promotion_activated",
                    promotion_id=str(promotion.id),
                    name=promotion.name,
                )

        self.db.expire_all()
        saved = self._get(promotion_id)
        names = self.repo.products_by_promotion({saved.id})
        return to_response(saved, names.get(saved.id, []))

    # ------------------------------------------------------------------
    # Validation / helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _validate_rule(
        promotion_type: str,
        value,
        product_ids: list[uuid.UUID],
    ) -> None:
        """Type/value range + the multi-product × fixed-price ban."""
        amount = to_decimal(value)
        if not amount.is_finite():
            raise ValidationError(
                message="value must be a finite decimal",
                code="INVALID_PROMOTION_VALUE",
                details={"value": str(value)},
            )
        if promotion_type == PromotionType.PERCENTAGE.value:
            if amount <= 0 or amount > 100:
                raise ValidationError(
                    message="percentage must be greater than 0 and at most 100",
                    code="INVALID_PROMOTION_VALUE",
                    details={"promotion_type": promotion_type, "value": str(amount)},
                )
        elif promotion_type == PromotionType.FIXED_PRICE.value:
            if amount < 0:
                raise ValidationError(
                    message="fixed price must be >= 0",
                    code="INVALID_PROMOTION_VALUE",
                    details={"promotion_type": promotion_type, "value": str(amount)},
                )
        else:  # pragma: no cover — schema validates the type
            raise ValidationError(
                message="promotion_type must be one of: percentage, fixed_price",
                details={"promotion_type": promotion_type},
            )

        if (
            promotion_type == PromotionType.FIXED_PRICE.value
            and len(product_ids) > 1
        ):
            raise ValidationError(
                message=(
                    "A fixed-price promotion can only target a single product"
                ),
                code="MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED",
                details={
                    "promotion_type": promotion_type,
                    "product_count": len(product_ids),
                },
            )

    def _missing_products(self, product_ids: list[uuid.UUID]) -> list[uuid.UUID]:
        if not product_ids:
            return []
        found = set(
            self.db.execute(
                select(Product.id).where(Product.id.in_(product_ids))
            )
            .scalars()
            .all()
        )
        return [pid for pid in product_ids if pid not in found]

    def _assert_no_active_overlap(
        self,
        product_ids: list[uuid.UUID],
        *,
        exclude_promotion_id: uuid.UUID | None = None,
    ) -> None:
        if not product_ids:
            return
        if exclude_promotion_id is None:
            conflicts = self.repo.active_memberships(set(product_ids))
        else:
            conflicts = self.repo.active_memberships_excluding(
                set(product_ids), exclude_promotion_id
            )
        if not conflicts:
            return
        raise ConflictError(
            message=(
                "A product can only belong to one ACTIVE promotion "
                "(deactivate the other promotion first)"
            ),
            code="PROMOTION_PRODUCT_CONFLICT",
            details={
                "products": [
                    {
                        "product_id": str(product_id),
                        "promotion_id": str(promotion.id),
                        "promotion_name": promotion.name,
                    }
                    for product_id, promotion in sorted(
                        conflicts.items(), key=lambda kv: str(kv[0])
                    )
                ]
            },
        )

    @staticmethod
    def _product_ids(promotion: Promotion) -> list[uuid.UUID]:
        return [row.product_id for row in promotion.products]

    # ------------------------------------------------------------------
    # Idempotency signature (mirrors the expenses pattern)
    # ------------------------------------------------------------------

    @staticmethod
    def _money_key(value) -> str:
        return format(to_decimal(value).normalize(), "f")

    @classmethod
    def _request_signature(cls, request: PromotionCreateRequest) -> tuple:
        return (
            request.name,
            request.promotion_type,
            cls._money_key(request.value),
            tuple(sorted(str(p) for p in request.product_ids)),
            bool(request.is_active),
        )

    @classmethod
    def _document_signature(cls, promotion: Promotion) -> tuple:
        return (
            promotion.name,
            promotion.promotion_type,
            cls._money_key(promotion.value),
            tuple(sorted(str(p) for p in cls._product_ids(promotion))),
            bool(promotion.is_active),
        )

    @classmethod
    def _assert_same_payload(
        cls, existing: Promotion, request: PromotionCreateRequest
    ) -> None:
        if cls._document_signature(existing) != cls._request_signature(request):
            raise ConflictError(
                message=(
                    "client_request_id was already used with a different "
                    "promotion payload"
                ),
                code="IDEMPOTENCY_CONFLICT",
                details={
                    "client_request_id": request.client_request_id,
                    "promotion_id": str(existing.id),
                },
            )

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="promotion",
                entity_id=entity_id,
                details=details,
            )
        )


def to_response(
    promotion: Promotion,
    products: list[tuple[uuid.UUID, str]] | None = None,
    *,
    idempotent_replay: bool = False,
) -> PromotionResponse:
    """Map an ORM promotion to its API shape (money stays Decimal)."""
    refs = [
        PromotionProductRef(id=product_id, name=name)
        for product_id, name in (products or [])
    ]
    return PromotionResponse(
        id=promotion.id,
        name=promotion.name,
        promotion_type=promotion.promotion_type,
        value=to_decimal(promotion.value),
        is_active=bool(promotion.is_active),
        products=refs,
        product_ids=[ref.id for ref in refs],
        product_count=len(refs),
        client_request_id=promotion.client_request_id,
        created_by=promotion.created_by,
        created_at=promotion.created_at,
        updated_at=promotion.updated_at,
        idempotent_replay=idempotent_replay,
    )
