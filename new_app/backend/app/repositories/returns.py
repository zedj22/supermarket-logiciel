"""Return document repository (Phase 12).

Persistence-only queries for the ``returns`` / ``return_lines`` documents
(decision record §5). The service owns every business rule; this module
only reads and aggregates.

Additive Phase 12 capabilities:
- idempotency replay lookup (``client_request_id``)
- cumulative per-source-line cap aggregates (§11)
- void/return mutual exclusion lookup (§16)
- filtered history search (§22)
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import func, select

from app.domain.unit_conversions import to_decimal
from app.models.return_doc import Return, ReturnLine
from app.models.sale import Sale
from app.repositories.base import BaseRepository


class ReturnRepository(BaseRepository[Return]):
    """Persistence for return headers."""

    model = Return

    def find_by_client_request_id(self, client_request_id: str) -> Return | None:
        stmt = select(Return).where(
            Return.client_request_id == client_request_id
        )
        return self.db.execute(stmt).scalar_one_or_none()

    def return_numbers_for_sale(self, sale_id: uuid.UUID) -> list[str]:
        """Return numbers referencing a sale (GATE 10 mutual exclusion)."""
        rows = self.db.execute(
            select(Return.return_number)
            .where(Return.sale_id == sale_id)
            .order_by(Return.return_date.asc())
        ).all()
        return [row[0] for row in rows]

    def returned_quantities_for_lines(
        self, sale_line_ids: list[uuid.UUID]
    ) -> dict[uuid.UUID, tuple[Decimal, Decimal]]:
        """Cumulative (returned quantity, refunded amount) per source line.

        The cap (GATE 4) and the pro-rata refund (GATE 14) both need the
        already-returned state of every source line named by the request.
        Evaluated inside the posting transaction with the sale row locked,
        so two racing returns of the same last unit serialize (§19).
        """
        if not sale_line_ids:
            return {}
        rows = self.db.execute(
            select(
                ReturnLine.sale_line_id,
                func.coalesce(func.sum(ReturnLine.quantity), 0),
                func.coalesce(func.sum(ReturnLine.line_total), 0),
            )
            .where(ReturnLine.sale_line_id.in_(sale_line_ids))
            .group_by(ReturnLine.sale_line_id)
        ).all()
        return {
            sale_line_id: (to_decimal(qty), to_decimal(refunded))
            for sale_line_id, qty, refunded in rows
        }

    def search(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        sale_id: uuid.UUID | None = None,
        invoice_number: str | None = None,
        date_from=None,
        date_to=None,
        reason: str | None = None,
    ) -> tuple[list[Return], int]:
        """Paginated history (newest first) with §22 filters."""
        stmt = select(Return)
        if sale_id is not None:
            stmt = stmt.where(Return.sale_id == sale_id)
        if reason is not None:
            stmt = stmt.where(Return.reason == reason)
        if date_from is not None:
            stmt = stmt.where(Return.return_date >= date_from)
        if date_to is not None:
            stmt = stmt.where(Return.return_date <= date_to)
        if invoice_number:
            stmt = stmt.join(Sale, Sale.id == Return.sale_id).where(
                Sale.invoice_number == invoice_number
            )

        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = (
            self.db.execute(
                stmt.order_by(
                    Return.return_date.desc(), Return.id.desc()
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), int(total)
