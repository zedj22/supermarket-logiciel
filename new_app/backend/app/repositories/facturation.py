"""Facturation persistence (Phase 3 — invoice client domain).

InvoiceClientRepository mirrors CustomerRepository / SupplierRepository:
``q`` searches name + phone, archived rows are hidden unless
``include_archived``, and ordering is deterministic (name ASC, id
tie-break) so pagination never repeats or skips rows.

The invoice client is the fiscal/document identity (factura_simple
``Client``) — a SEPARATE domain from the POS ``Customer``: this
repository never joins, filters or touches the ``customers`` table.
"""

from __future__ import annotations

from sqlalchemy import func, or_, select

from app.models.facturation import InvoiceClient
from app.repositories.base import BaseRepository


class InvoiceClientRepository(BaseRepository[InvoiceClient]):
    """Invoice (fiscal) client master-data persistence."""

    model = InvoiceClient

    @staticmethod
    def _base_stmt(q: str | None, include_archived: bool):
        stmt = select(InvoiceClient)
        if not include_archived:
            stmt = stmt.where(InvoiceClient.archived_at.is_(None))
        if q:
            pattern = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(
                    InvoiceClient.name.ilike(pattern),
                    InvoiceClient.phone.ilike(pattern),
                )
            )
        return stmt

    def search(
        self,
        *,
        q: str | None = None,
        include_archived: bool = False,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[InvoiceClient], int]:
        """Paginated name/phone search (CustomerRepository parity)."""
        stmt = self._base_stmt(q, include_archived)
        total = self.db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
        rows = (
            self.db.execute(
                stmt.order_by(InvoiceClient.name, InvoiceClient.id)
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total
