"""Facturation persistence (Phase 3 invoice clients + Phase 5 documents).

InvoiceClientRepository mirrors CustomerRepository / SupplierRepository:
``q`` searches name + phone, archived rows are hidden unless
``include_archived``, and ordering is deterministic (name ASC, id
tie-break) so pagination never repeats or skips rows.

InvoiceDocumentRepository (Phase 5) adds the two document concerns:
filtered/searchable listing (deterministic date ordering) and the
concurrency-safe ``(doc_type, year)`` number allocation described in
``allocate_number``.

The invoice client is the fiscal/document identity (factura_simple
``Client``) — a SEPARATE domain from the POS ``Customer``: this
repository never joins, filters or touches the ``customers`` table, and
document numbering never touches ``sales.invoice_number``.
"""

from __future__ import annotations

from datetime import date

from sqlalchemy import false, func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import noload

from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
)
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


class InvoiceDocumentRepository(BaseRepository[InvoiceDocument]):
    """Invoice document persistence: filtered listing + safe numbering.

    Numbering is a SEPARATE domain from POS sales — this repository
    never reads ``sales.invoice_number`` or any POS counter.
    """

    model = InvoiceDocument

    #: Bounded retries for the counter seed-row INSERT race (the loser
    #: of a concurrent first-ever allocation sees IntegrityError, then
    #: re-reads the winner's committed row under FOR UPDATE).
    ALLOCATE_ATTEMPTS = 10

    def allocate_number(self, doc_type: str, year: int) -> str:
        """Allocate the next ``{doc_type}-{year}-{n:04d}`` for the pair.

        Concurrency contract (PostgreSQL, READ COMMITTED):

        1. ``SELECT ... FOR UPDATE`` on the counter row serializes
           concurrent allocators on ``(doc_type, year)`` — the loser
           blocks, then re-reads the winner's committed ``last_number``
           (EvalPlanQual), so two requests can never receive the same
           serial. Unit tests run on SQLite, where ``FOR UPDATE`` is
           silently ignored and the single-writer engine serializes
           writers anyway.
        2. Insert-if-missing happens through a SAVEPOINT: two first-ever
           allocations race on UNIQUE(doc_type, year), the loser gets a
           clean ``IntegrityError``, the savepoint rolls back only its
           own seed row, and the loop retries to lock the winner's row.
        3. The increment is flushed but NOT committed here — it rides
           the caller's transaction (``BaseService.transaction`` in
           ``InvoiceDocumentService.create``). A rolled-back document
           creation therefore rolls back the counter increment too:
           failed creates never consume a number, never leave a gap,
           and the document's UNIQUE(doc_type, year, number) remains
           the final backstop.

        Raises 409 CONFLICT only after ``ALLOCATE_ATTEMPTS`` lost races
        (indicates an abnormally contended allocator, not data loss).
        """
        from app.core.exceptions import ConflictError

        for _ in range(self.ALLOCATE_ATTEMPTS):
            counter = self.db.execute(
                select(InvoiceDocumentCounter)
                .where(
                    InvoiceDocumentCounter.doc_type == doc_type,
                    InvoiceDocumentCounter.year == year,
                )
                .with_for_update()
            ).scalar_one_or_none()
            if counter is None:
                # Portability shim: the seed must ride inside an ALREADY
                # OPEN write transaction. SAVEPOINT semantics differ per
                # backend when it is the very first statement: with
                # pysqlite's implicit-BEGIN mode a savepoint started in
                # autocommit state gets COMMITTED by its RELEASE, so a
                # later rollback could no longer undo a failed create —
                # leaving a number gap on SQLite. A zero-row UPDATE opens
                # the write transaction there; on PostgreSQL (real BEGIN
                # already open from the SELECT) it matches no rows and
                # locks nothing.
                self.db.execute(
                    update(InvoiceDocumentCounter)
                    .where(false())
                    .values(last_number=InvoiceDocumentCounter.last_number)
                )
                seed = InvoiceDocumentCounter(doc_type=doc_type, year=year, last_number=0)
                try:
                    with self.db.begin_nested():
                        self.db.add(seed)
                        self.db.flush()
                except IntegrityError:
                    continue  # concurrent seed won — lock its row next pass
                counter = seed
            counter.last_number += 1
            self.db.flush()
            return f"{doc_type}-{year}-{counter.last_number:04d}"
        raise ConflictError(
            message="Could not allocate a document number, please retry",
            details={"doc_type": doc_type, "year": year},
        )

    def peek_next_number(self, doc_type: str, year: int) -> str:
        """Read-only ``{doc_type}-{year}-{n:04d}`` proposal (preview).

        Never locks and never increments: the value is advisory — a
        concurrent create may consume it first (factura_simple preview
        reads its counter the same way).
        """
        counter = self.db.execute(
            select(InvoiceDocumentCounter).where(
                InvoiceDocumentCounter.doc_type == doc_type,
                InvoiceDocumentCounter.year == year,
            )
        ).scalar_one_or_none()
        serial = (counter.last_number if counter is not None else 0) + 1
        return f"{doc_type}-{year}-{serial:04d}"

    def search(
        self,
        *,
        doc_type: str | None = None,
        year: int | None = None,
        client_id=None,
        date_from: date | None = None,
        date_to: date | None = None,
        q: str | None = None,
        page: int = 1,
        page_size: int = 20,
    ) -> tuple[list[InvoiceDocument], int]:
        """Filtered, paginated document listing.

        Filters are conjunctive and optional. ``q`` matches the stored
        formatted ``number`` (``FAC-2026-00…`` substring search). Every
        document stays listable forever — there is no archive flag on
        documents, and an archived invoice client does not hide its
        historical documents. Ordering is deterministic (document_date
        DESC, created_at DESC, id DESC): UUID primary keys are not
        monotonic, so ``id DESC`` is only a stable tie-break.
        """
        stmt = select(InvoiceDocument).options(noload(InvoiceDocument.lines))
        if doc_type is not None:
            stmt = stmt.where(InvoiceDocument.doc_type == doc_type)
        if year is not None:
            stmt = stmt.where(InvoiceDocument.year == year)
        if client_id is not None:
            stmt = stmt.where(InvoiceDocument.client_id == client_id)
        if date_from is not None:
            stmt = stmt.where(InvoiceDocument.document_date >= date_from)
        if date_to is not None:
            stmt = stmt.where(InvoiceDocument.document_date <= date_to)
        if q and q.strip():
            stmt = stmt.where(InvoiceDocument.number.ilike(f"%{q.strip()}%"))
        total = self.db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
        rows = (
            self.db.execute(
                stmt.order_by(
                    InvoiceDocument.document_date.desc(),
                    InvoiceDocument.created_at.desc(),
                    InvoiceDocument.id.desc(),
                )
                .offset((page - 1) * page_size)
                .limit(page_size)
            )
            .scalars()
            .all()
        )
        return list(rows), total
