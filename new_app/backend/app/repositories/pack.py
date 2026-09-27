"""Pack repository (Phase 10) — persistence only.

No business rules here (Phase 7 non-negotiable #9): this module only
talks to the database. Validation, audit and archive semantics live in
``app.services.pack``.
"""

from __future__ import annotations

import uuid
from decimal import Decimal
from typing import NamedTuple

from sqlalchemy import func, or_, select
from sqlalchemy.orm import selectinload

from app.models.catalog import Pack, PackItem, Product
from app.repositories.base import BaseRepository


class PackListRow(NamedTuple):
    """One paginated list row: the pack plus its live aggregates."""

    pack: Pack
    components_count: int
    sum_of_parts: Decimal


def to_money(value) -> Decimal:
    return Decimal(str(value if value is not None else 0))


class PackRepository(BaseRepository[Pack]):
    """Persistence for ``packs`` / ``pack_items``."""

    model = Pack

    # -- reads -----------------------------------------------------------

    def get_with_components(self, pack_id: uuid.UUID) -> Pack | None:
        """Load a pack with its components (and their products) eagerly."""
        stmt = (
            select(Pack)
            .where(Pack.id == pack_id)
            .options(
                selectinload(Pack.pack_items).selectinload(
                    PackItem.component_product
                )
            )
        )
        return self.db.scalars(stmt).first()

    def find_by_barcode(
        self, barcode: str | None, *, exclude_id: uuid.UUID | None = None
    ) -> Pack | None:
        if not barcode:
            return None
        stmt = select(Pack).where(Pack.barcode == barcode)
        if exclude_id is not None:
            stmt = stmt.where(Pack.id != exclude_id)
        return self.db.scalars(stmt).first()

    def find_by_name(
        self, name: str, *, exclude_id: uuid.UUID | None = None
    ) -> Pack | None:
        stmt = select(Pack).where(func.lower(Pack.name) == name.lower())
        if exclude_id is not None:
            stmt = stmt.where(Pack.id != exclude_id)
        return self.db.scalars(stmt).first()

    def list_with_stats(
        self,
        *,
        search: str | None = None,
        status: str = "active",
        page: int = 1,
        page_size: int = 40,
    ) -> tuple[list[PackListRow], int]:
        """Paginated pack list with ``components_count`` / ``sum_of_parts``.

        Both aggregates are computed in SQL (LEFT JOIN + GROUP BY) so a
        page costs one query, not 1 + N. ``sum_of_parts`` is informational
        only (GATE 3): ``SUM(component.quantity * products.price)``.
        """
        aggregates = (
            select(
                Pack.id.label("pack_id"),
                func.count(PackItem.id).label("components_count"),
                func.coalesce(
                    func.sum(PackItem.quantity * Product.price), Decimal("0")
                ).label("sum_of_parts"),
            )
            .select_from(Pack)
            .outerjoin(PackItem, PackItem.pack_id == Pack.id)
            .outerjoin(Product, PackItem.product_id == Product.id)
            .group_by(Pack.id)
            .subquery()
        )

        stmt = select(
            Pack,
            aggregates.c.components_count,
            aggregates.c.sum_of_parts,
        ).join(aggregates, aggregates.c.pack_id == Pack.id)
        count_stmt = select(func.count()).select_from(Pack)

        conditions = self._filters(search=search, status=status)
        for condition in conditions:
            stmt = stmt.where(condition)
            count_stmt = count_stmt.where(condition)

        total = self.db.scalar(count_stmt) or 0

        stmt = stmt.order_by(Pack.name.asc(), Pack.id.asc())
        stmt = stmt.offset((max(1, page) - 1) * page_size).limit(page_size)

        rows = self.db.execute(stmt).all()
        items = [
            PackListRow(
                pack=row[0],
                components_count=int(row[1] or 0),
                sum_of_parts=to_money(row[2]),
            )
            for row in rows
        ]
        return items, int(total)

    @staticmethod
    def _filters(*, search: str | None, status: str) -> list:
        conditions: list = []
        if status == "active":
            conditions.append(Pack.is_active.is_(True))
            conditions.append(Pack.archived_at.is_(None))
        elif status == "archived":
            conditions.append(
                or_(Pack.archived_at.is_not(None), Pack.is_active.is_(False))
            )
        # status == "all" -> no status filter
        term = (search or "").strip()
        if term:
            like = f"%{term}%"
            conditions.append(
                or_(
                    Pack.name.ilike(like),
                    Pack.barcode.ilike(like),
                )
            )
        return conditions

    # -- component helpers ----------------------------------------------

    @staticmethod
    def component_rows(pack: Pack) -> list[PackItem]:
        """Components of a pack, ordered deterministically for responses."""
        return sorted(
            list(pack.pack_items or []),
            key=lambda item: (str(item.product_id), str(item.id)),
        )

    @staticmethod
    def components_with_products(pack: Pack) -> list[tuple[PackItem, Product | None]]:
        """Component rows paired with their (already loaded) product."""
        out: list[tuple[PackItem, Product | None]] = []
        for item in PackRepository.component_rows(pack):
            out.append((item, item.component_product))
        return out

    @staticmethod
    def sum_of_parts(pack: Pack) -> Decimal:
        """Live informational sum of component prices (never persisted)."""
        total = Decimal("0")
        for item in PackRepository.component_rows(pack):
            product = item.component_product
            if product is None:
                continue
            total += to_money(item.quantity) * to_money(product.price)
        return total
