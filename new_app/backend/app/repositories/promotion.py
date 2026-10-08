"""Promotion repository (Phase 18).

Persistence-only queries for ``promotions`` / ``promotion_products``.
The service owns every business rule (validation, overlap, idempotency);
this module only reads, filters, locks and applies writes the service
drives inside one transaction.
"""

from __future__ import annotations

import uuid

from sqlalchemy import func, select

from app.models.catalog import Product
from app.models.promotion import Promotion, PromotionProduct
from app.repositories.base import BaseRepository


class PromotionRepository(BaseRepository[Promotion]):
    """Persistence for promotion records."""

    model = Promotion

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def search(
        self,
        *,
        page: int = 1,
        page_size: int = 40,
        q: str | None = None,
        is_active: bool | None = None,
    ) -> tuple[list[Promotion], int]:
        """Paginated promotion list, newest first.

        ``Promotion.products`` is lazy="selectin", so membership rows are
        fetched with the same round trips.
        """
        conditions = []
        if q:
            pattern = f"%{q.strip()}%"
            conditions.append(Promotion.name.ilike(pattern))
        if is_active is not None:
            conditions.append(Promotion.is_active.is_(is_active))

        stmt = select(self.model)
        if conditions:
            stmt = stmt.where(*conditions)

        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(Promotion.created_at.desc(), Promotion.id.desc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), int(total)

    def find_by_client_request_id(
        self, client_request_id: str
    ) -> Promotion | None:
        stmt = select(self.model).where(
            self.model.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def product_names(
        self, product_ids: set[uuid.UUID]
    ) -> dict[uuid.UUID, str]:
        """id → name for the given products (existence + display)."""
        if not product_ids:
            return {}
        rows = self.db.execute(
            select(Product.id, Product.name).where(Product.id.in_(product_ids))
        ).all()
        return {row[0]: row[1] for row in rows}

    def products_by_promotion(
        self, promotion_ids: set[uuid.UUID]
    ) -> dict[uuid.UUID, list[tuple[uuid.UUID, str]]]:
        """promotion_id → [(product_id, product_name), ...] (one query)."""
        if not promotion_ids:
            return {}
        rows = self.db.execute(
            select(
                PromotionProduct.promotion_id,
                PromotionProduct.product_id,
                Product.name,
            )
            .join(Product, Product.id == PromotionProduct.product_id)
            .where(PromotionProduct.promotion_id.in_(promotion_ids))
        ).all()
        mapping: dict[uuid.UUID, list[tuple[uuid.UUID, str]]] = {
            pid: [] for pid in promotion_ids
        }
        for promotion_id, product_id, name in rows:
            mapping.setdefault(promotion_id, []).append((product_id, name))
        return mapping

    def active_memberships(
        self, product_ids: set[uuid.UUID]
    ) -> dict[uuid.UUID, Promotion]:
        """product_id → ACTIVE promotion containing it (overlap rule).

        The service guarantees at most one active promotion per product,
        so a dict is enough; if data ever violates that the LAST row wins
        deterministically (ordered by promotion id).
        """
        if not product_ids:
            return {}
        rows = self.db.execute(
            select(PromotionProduct.product_id, Promotion)
            .join(Promotion, Promotion.id == PromotionProduct.promotion_id)
            .where(
                PromotionProduct.product_id.in_(product_ids),
                Promotion.is_active.is_(True),
            )
            .order_by(Promotion.id)
        ).all()
        return {product_id: promotion for product_id, promotion in rows}

    def active_memberships_excluding(
        self, product_ids: set[uuid.UUID], exclude_promotion_id: uuid.UUID
    ) -> dict[uuid.UUID, Promotion]:
        """Same as :meth:`active_memberships` but skips one promotion.

        Used by update/toggle to check the OTHER active promotions a
        product already belongs to.
        """
        if not product_ids:
            return {}
        rows = self.db.execute(
            select(PromotionProduct.product_id, Promotion)
            .join(Promotion, Promotion.id == PromotionProduct.promotion_id)
            .where(
                PromotionProduct.product_id.in_(product_ids),
                Promotion.is_active.is_(True),
                Promotion.id != exclude_promotion_id,
            )
            .order_by(Promotion.id)
        ).all()
        return {product_id: promotion for product_id, promotion in rows}

    def lock_products(self, product_ids: set[uuid.UUID]) -> None:
        """Row-lock the products a write is about to touch (FOR UPDATE).

        Every write path locks the same product rows (sorted input is not
        required — a single IN() statement takes them in one place) BEFORE
        checking the active-overlap rule, so two concurrent promotions
        cannot both slip past the check on PostgreSQL. SQLite ignores
        FOR UPDATE (writes are serialized there anyway).
        """
        if not product_ids:
            return
        self.db.execute(
            select(Product.id)
            .where(Product.id.in_(product_ids))
            .order_by(Product.id)
            .with_for_update()
        )

    # ------------------------------------------------------------------
    # Writes (the service drives them inside one transaction)
    # ------------------------------------------------------------------

    def add_products(
        self, promotion_id: uuid.UUID, product_ids: list[uuid.UUID]
    ) -> None:
        for product_id in product_ids:
            self.db.add(
                PromotionProduct(
                    promotion_id=promotion_id, product_id=product_id
                )
            )
        self.db.flush()

    def replace_products(
        self, promotion_id: uuid.UUID, product_ids: list[uuid.UUID]
    ) -> None:
        """Replace the membership set of one promotion (update path)."""
        existing = list(
            self.db.scalars(
                select(PromotionProduct).where(
                    PromotionProduct.promotion_id == promotion_id
                )
            )
        )
        keep = set(product_ids)
        for row in existing:
            if row.product_id not in keep:
                self.db.delete(row)
        present = {row.product_id for row in existing}
        for product_id in product_ids:
            if product_id not in present:
                self.db.add(
                    PromotionProduct(
                        promotion_id=promotion_id, product_id=product_id
                    )
                )
        self.db.flush()
