"""Invoice client + document services (Phases 3–5 — facturation domain).

Phase 3: business orchestration for the ``invoice_clients`` master:
create, get, list/search, update, archive, unarchive, plus the
new-document availability check the document workflow calls.

Domain isolation (Phase 0/2 integration decisions — hard rules)
----------------------------------------------------------------
- The invoice client is the fiscal/document identity of factura_simple
  (name + NIF / RC / AI / NIS). The POS ``Customer`` is the debt/ledger
  master. They are fully separate: no ``customer_id`` exists here,
  Customer rows are never read or written, and no polymorphic party
  abstraction is introduced.
- There is no delete method: hard deletion is a database decision
  (FK RESTRICT on ``invoice_documents.client_id``), never an application
  command. Archiving is the only removal path.

Scope (Phase 3): service/domain only — no FastAPI schemas, routers or
endpoints (those belong to the API phase). Callers pass keyword
arguments; validation therefore lives here, following the project's
structured-error conventions (``app.core.exceptions``):

- ``name`` is required (the only required factura_simple field), trimmed,
  blank rejected, length-guarded to the Phase 2 column (200).
- Every optional string is trimmed and blank becomes NULL. The source
  stores ``""``; the Phase 2 schema is nullable, so NULL is the SP form.
- Column length guards mirror the schema (wilaya 100, phone/nif/rc/ai/nis
  30, address TEXT unbounded) so PostgreSQL never turns an overlong value
  into a 500 (SQLite would silently accept it).
- Duplicates are ALLOWED — name, phone and fiscal identifiers: neither
  the source nor the Phase 2 schema has any unique constraint, and fiscal
  identifiers are stored exactly as given (after trimming).

Archive policy: soft archive only, idempotent in both directions.
Archiving a client that documents still reference is ALLOWED — the
relationship is kept (FK RESTRICT already blocks hard deletes) and
existing documents stay valid; only attaching the client to a NEW
document is refused (``ensure_usable_for_new_document`` → 422
``INVOICE_CLIENT_ARCHIVED``).

Transactions and audit follow CustomerService: the service owns the
transaction (``BaseService.transaction``) and every mutation appends one
``audit_logs`` row in the same transaction (entity_type
``invoice_client``).

Product integration (Phase 4)
-----------------------------
``InvoiceProductService`` resolves existing Supermarket Pro products for
invoice-line prefill — ``products`` stays the SINGLE product catalog (no
``invoice_products`` table ever exists). ``get_product_for_invoice``
reuses the existing ``ProductService`` read (structured 404) and returns
a frozen ``InvoiceLinePrefill(product_id, description, unit_price_ht,
tva_rate)`` built purely from ``products.price`` (the initial HT unit
price) and ``products.vat_rate`` (authoritative Phase 17 metadata, the
strict {0, 9, 19} set Phase 1 also supports). Promotion / wholesale /
selling-unit / pack / variant / inventory pricing is NEVER consulted,
the product row is never mutated, and stock is never touched. The
archived-product gate mirrors ``SaleService._get_product``: archived
products cannot be selected for NEW invoice lines, while historical
lines never re-resolve the product and stay valid regardless of the
product's current state.

Document workflow (Phase 5)
---------------------------
``InvoiceDocumentService`` creates / reads / lists / updates the five
document types (FAC, DEV, PRO, BC, BL) in one transaction each, with
factura_simple parity re-verified against ``backend/main.py``:

- NUMBERING: ``number`` stores the full formatted string
  ``{doc_type}-{year}-{n:04d}`` (source ``next_number`` stores exactly
  that); the counter row keeps the integer serial. Allocation is
  concurrency-safe (``InvoiceDocumentRepository.allocate_number``:
  FOR UPDATE + savepoint seed) and rides the SAME transaction as the
  document — a failed create rolls the increment back, so failed
  creates never consume numbers (source semantics: validation runs
  before ``next_number``; the source's single commit rolls counter and
  document back together).
- YEAR: ``year = document_date.year`` (source ``data.date or
  date.today()`` — when the request omits ``document_date`` it defaults
  to today, exactly like the source). The year is never derived from
  server "now" directly and is never client-writable as a column.
- LINES: every product line is resolved through the Phase 4 prefill
  (initial description/price/VAT the CLIENT may override — sent values
  always win, products.price is never a live price source); free-text
  lines (``product_id = NULL``) are first-class with required
  description/unit_price_ht/tva_rate. Positions default to list index.
- CALCULATION: Phase 1 only (``calculate_document_result`` is the ONE
  path used by create-validation, update-validation, GET detail and
  preview): position-ordered lines → ``calculate_document_totals`` →
  per-line totals + ``amount_in_words``. No second formula anywhere.
- IMMUTABLE after create: id, doc_type, year, number, document_date.
  EDITABLE: client, payment_method, notes, the five show_* flags,
  lines. Updates replace lines atomically (cascade delete-orphan) and
  never re-allocate a number. There is NO delete operation.
- PREVIEW: ``preview`` resolves client + products, validates exactly
  like create and computes exactly like detail — but persists nothing,
  allocates nothing (``peek_next_number`` is a read-only proposal).
- AUDIT: entity_type ``invoice_document``, AuditAction.CREATE/UPDATE,
  actor from the API layer, same transaction (no new enum values).

Company / fiscal settings (Phase 6)
------------------------------------
``get_facturation_company_settings(db)`` is the ONE read path future
rendering (PDF / DOCX / print) uses for the seller identity.  It is a
thin, non-persisting view over the existing ``app_settings`` row — no
``CompanySettings`` / ``FiscalSettings`` table and no second settings
API exist: ``name`` / ``address`` / ``phone`` are literally the
``store_name`` / ``store_address`` / ``store_phone`` columns the rest of
Supermarket Pro already edits through ``GET/PUT /api/v1/settings``.

Settings NEVER touch money: Phase 1 (``app.domain.facturation``) stays
the sole owner of TVA membership {0, 9, 19}, ROUND_HALF_UP centime
rounding, line/document totals, the Timbre Fiscal thresholds and the
cash-only rule.  Nothing in this phase reads a setting inside a
calculation, and Phase 5's ``calculate_document_result`` path is
untouched.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Any, TypeVar

import structlog
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.exceptions import BusinessRuleError, ValidationError
from app.domain.facturation import (
    DocumentTotals,
    FacturationError,
    FactureLine,
    LineTotals,
    amount_in_words,
    calculate_document_totals,
    calculate_line,
    validate_doc_type,
    validate_document_inputs,
    validate_payment_method,
)
from app.domain.unit_conversions import to_decimal
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.enums import AuditAction
from app.models.facturation import (
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentLine,
)
from app.repositories.facturation import (
    InvoiceClientRepository,
    InvoiceDocumentRepository,
)
from app.schemas.facturation import (
    InvoiceClientRefResponse,
    InvoiceDocumentCreateRequest,
    InvoiceDocumentResponse,
    InvoiceDocumentTotalsResponse,
    InvoiceDocumentUpdateRequest,
    InvoiceLineRequest,
    InvoiceLineResponse,
)
from app.services.base import BaseService
from app.services.catalog import ProductService
from app.services.settings import SettingsService

logger = structlog.get_logger(__name__)

_T = TypeVar("_T")

_NAME_MAX_LENGTH = 200

_OPTIONAL_FIELD_MAX_LENGTH: dict[str, int | None] = {
    "address": None,
    "wilaya": 100,
    "phone": 30,
    "nif": 30,
    "rc": 30,
    "ai": 30,
    "nis": 30,
}


class _Unset:
    """Sentinel type: a field was NOT supplied (vs an explicit None)."""

    def __repr__(self) -> str:
        return "UNSET"


_UNSET = _Unset()


def _clean_name(value: Any) -> str:
    """Validate and trim the required name (single required field)."""
    if value is None:
        raise ValidationError(
            message="name is required",
            details={"field": "name"},
        )
    if not isinstance(value, str):
        raise ValidationError(
            message="name must be a string",
            details={"field": "name"},
        )
    name = value.strip()
    if not name:
        raise ValidationError(
            message="name must not be blank",
            details={"field": "name"},
        )
    if len(name) > _NAME_MAX_LENGTH:
        raise ValidationError(
            message=f"name must be at most {_NAME_MAX_LENGTH} characters",
            details={"field": "name", "max_length": _NAME_MAX_LENGTH},
        )
    return name


def _clean_optional(value: Any, *, field: str, max_length: int | None) -> str | None:
    """Validate and trim one optional string; blank becomes NULL."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValidationError(
            message=f"{field} must be a string",
            details={"field": field},
        )
    stripped = value.strip()
    if not stripped:
        return None
    if max_length is not None and len(stripped) > max_length:
        raise ValidationError(
            message=f"{field} must be at most {max_length} characters",
            details={"field": field, "max_length": max_length},
        )
    return stripped


class InvoiceClientService(BaseService):
    """Application service for invoice (fiscal) client master data."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = InvoiceClientRepository(db)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        q: str | None = None,
        include_archived: bool = False,
    ) -> tuple[list[InvoiceClient], int]:
        """Paginated list; ``q`` searches name/phone (list doubles as search)."""
        return self.repo.search(
            q=q,
            include_archived=include_archived,
            page=page,
            page_size=page_size,
        )

    def get(self, client_id: uuid.UUID) -> InvoiceClient:
        """Fetch an invoice client or raise a structured 404."""
        return self.repo.get_by_id_or_none(client_id)

    def has_documents(self, client_id: uuid.UUID) -> bool:
        """True when at least one invoice document references the client."""
        client = self.get(client_id)
        count = (
            self.db.scalar(
                select(func.count())
                .select_from(InvoiceDocument)
                .where(InvoiceDocument.client_id == client.id)
            )
            or 0
        )
        return count > 0

    def ensure_usable_for_new_document(self, client_id: uuid.UUID) -> InvoiceClient:
        """Return a client usable for a NEW document.

        Unknown id → structured 404 (source parity: the source's document
        endpoints answer 404 for an unknown client_id). Archived client →
        422 ``INVOICE_CLIENT_ARCHIVED``: existing documents keep their
        relationship, only new attachments are refused.
        """
        client = self.get(client_id)
        if client.archived_at is not None:
            raise BusinessRuleError(
                message="Archived invoice clients cannot receive new documents",
                code="INVOICE_CLIENT_ARCHIVED",
                details={"client_id": str(client.id)},
            )
        return client

    def create(
        self,
        *,
        name: str | None = None,
        address: str | None = None,
        wilaya: str | None = None,
        phone: str | None = None,
        nif: str | None = None,
        rc: str | None = None,
        ai: str | None = None,
        nis: str | None = None,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceClient:
        """Create an invoice client (``name`` is the only required field)."""
        values: dict[str, Any] = {"name": _clean_name(name)}
        values.update(
            {
                field: _clean_optional(
                    value,
                    field=field,
                    max_length=_OPTIONAL_FIELD_MAX_LENGTH[field],
                )
                for field, value in (
                    ("address", address),
                    ("wilaya", wilaya),
                    ("phone", phone),
                    ("nif", nif),
                    ("rc", rc),
                    ("ai", ai),
                    ("nis", nis),
                )
            }
        )

        with self.transaction():
            client = InvoiceClient(**values)
            self.repo.create(client)
            self._audit(
                AuditAction.CREATE,
                entity_id=client.id,
                actor_id=actor_id,
                details=f"created invoice client {client.name!r}",
            )
        logger.info("invoice_client_created", client_id=str(client.id))
        return client

    def update(
        self,
        client_id: uuid.UUID,
        *,
        name: str | None | _Unset = _UNSET,
        address: str | None | _Unset = _UNSET,
        wilaya: str | None | _Unset = _UNSET,
        phone: str | None | _Unset = _UNSET,
        nif: str | None | _Unset = _UNSET,
        rc: str | None | _Unset = _UNSET,
        ai: str | None | _Unset = _UNSET,
        nis: str | None | _Unset = _UNSET,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceClient:
        """Partial update: only supplied fields change, unset stays put.

        An explicit ``None`` (or blank string) clears an optional field to
        NULL; an explicit ``None``/blank for ``name`` is rejected (name is
        required and NOT NULL). Supplying no fields is a no-op — the row
        is returned untouched and no audit row is written.
        """
        client = self.get(client_id)

        raw: dict[str, Any] = {
            "name": name,
            "address": address,
            "wilaya": wilaya,
            "phone": phone,
            "nif": nif,
            "rc": rc,
            "ai": ai,
            "nis": nis,
        }
        updates = {field: value for field, value in raw.items() if not isinstance(value, _Unset)}

        if "name" in updates:
            updates["name"] = _clean_name(updates["name"])
        for field, max_length in _OPTIONAL_FIELD_MAX_LENGTH.items():
            if field in updates:
                updates[field] = _clean_optional(
                    updates[field],
                    field=field,
                    max_length=max_length,
                )

        if updates:
            with self.transaction():
                for field, value in updates.items():
                    setattr(client, field, value)
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="updated fields: " + ", ".join(sorted(updates)),
                )
            logger.info(
                "invoice_client_updated",
                client_id=str(client.id),
                fields=sorted(updates),
            )
        return client

    def archive(self, client_id: uuid.UUID, *, actor_id: uuid.UUID | None = None) -> InvoiceClient:
        """Soft-archive an invoice client (data retention, never a delete).

        ALLOWED even while documents reference the client — the
        relationship is kept and existing documents stay valid; only new
        documents are refused (``ensure_usable_for_new_document``).
        Idempotent: archiving an archived client is a no-op.
        """
        client = self.get(client_id)
        if client.archived_at is None:
            with self.transaction():
                client.archived_at = datetime.now(timezone.utc)
                self._audit(
                    AuditAction.DELETE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="archived invoice client (soft delete)",
                )
            logger.info("invoice_client_archived", client_id=str(client.id))
        return client

    def unarchive(
        self, client_id: uuid.UUID, *, actor_id: uuid.UUID | None = None
    ) -> InvoiceClient:
        """Restore a soft-archived invoice client. Idempotent."""
        client = self.get(client_id)
        if client.archived_at is not None:
            with self.transaction():
                client.archived_at = None
                self._audit(
                    AuditAction.UPDATE,
                    entity_id=client.id,
                    actor_id=actor_id,
                    details="unarchived invoice client",
                )
            logger.info("invoice_client_unarchived", client_id=str(client.id))
        return client

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        Audit rows ride the same transaction as the mutation (the
        CustomerService contract): a committed mutation always has its
        audit entry, and a rolled-back mutation leaves no orphan audit.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="invoice_client",
                entity_id=entity_id,
                details=details,
            )
        )


@dataclass(frozen=True)
class InvoiceLinePrefill:
    """Product snapshot for prefilling one invoice line (Phase 4).

    Exactly the authoritative fields the future document workflow copies
    into ``invoice_document_lines``: ``product_id`` (traceability only),
    ``description`` (product-name snapshot), ``unit_price_ht`` (the
    ``products.price`` snapshot) and ``tva_rate`` (the
    ``products.vat_rate`` snapshot). Nothing else — wholesale /
    promotion / selling-unit prices, stock and catalog metadata are
    deliberately absent so no caller can leak them into a facturation
    line.
    """

    product_id: uuid.UUID
    description: str
    unit_price_ht: Decimal
    tva_rate: Decimal


def product_line_prefill(product: Product) -> InvoiceLinePrefill:
    """Pure Product → invoice-line prefill conversion.

    Deterministic and DB-free: the HT unit price is ALWAYS
    ``products.price`` and the TVA rate is ALWAYS the product's
    authoritative ``vat_rate`` metadata. No promotion, wholesale or
    selling-unit domain is consulted, and the product is never mutated.
    """
    return InvoiceLinePrefill(
        product_id=product.id,
        description=product.name,
        unit_price_ht=to_decimal(product.price),
        tva_rate=to_decimal(product.vat_rate),
    )


class InvoiceProductService(BaseService):
    """Resolves existing Supermarket Pro products for invoice use (V1).

    Product selection is PRODUCT-ROW based: one lookup reuses the
    existing ``ProductService.get`` read (structured 404 via
    ``BaseRepository.get_by_id_or_none``) and applies the established
    archived-product gate (SaleService / pack / purchase parity). There
    is no second product repository or catalog — ``products`` is the
    single source of truth, and this service never reads promotion
    state, wholesale fields, selling units, packs, variants or
    inventory, never mutates the product, and never touches stock.
    """

    def __init__(self, db: Session):
        super().__init__(db)
        self.products = ProductService(db)

    def get_product_for_invoice(self, product_id: uuid.UUID) -> InvoiceLinePrefill:
        """Load a product and return the invoice-line prefill snapshot.

        Raises structured 404 for an unknown id (the existing
        ProductService read) and 422 ``BUSINESS_RULE_ERROR`` for an
        archived product — the established rule for NEW transactions
        (SaleService: "Archived product cannot be sold"). Historical
        lines never re-resolve the product, so archiving or deleting a
        product never invalidates a stored snapshot.
        """
        product = self.products.get(product_id)
        if product.archived_at is not None:
            raise BusinessRuleError(
                message="Archived product cannot be used for new invoice lines",
                details={"product_id": str(product.id)},
            )
        return product_line_prefill(product)


# =========================================================================
# Phase 5 — invoice document workflow (create / read / list / update / preview)
# =========================================================================


def _facturation_call(fn: Callable[..., _T], *args: Any, **kwargs: Any) -> _T:
    """Run a Phase 1 domain call, mapping FacturationError → 422.

    Phase 1 raises the pure ``FacturationError(ValueError)``; the API
    layer only understands structured AppErrors, so every domain
    validation/entry call is funnelled through here.
    """
    try:
        return fn(*args, **kwargs)
    except FacturationError as exc:
        raise ValidationError(message=str(exc)) from exc


def _to_facture_line(line: InvoiceDocumentLine) -> FactureLine:
    """Persisted/request line → Phase 1 calculation input (Decimal only)."""
    return FactureLine(
        qty=to_decimal(line.quantity),
        unit_price_ht=to_decimal(line.unit_price_ht),
        tva_rate=to_decimal(line.tva_rate),
        discount_pct=to_decimal(line.discount_pct),
    )


@dataclass(frozen=True)
class DocumentCalculation:
    """Phase 1 result for one document's lines.

    Shared by create-validation, update-validation, GET detail and the
    preview endpoint — there is exactly ONE calculation path. The
    ``line_totals`` tuple aligns with the position-sorted line order.
    """

    totals: DocumentTotals
    line_totals: tuple[LineTotals, ...]
    amount_in_words: str


@dataclass(frozen=True)
class DocumentPreviewResult:
    """Non-persisting calculation result (source ``preview_document``).

    Nothing is written, no number is consumed (``proposed_number`` is a
    read-only peek), but client/product resolution and validation are
    identical to ``create`` — the UI sees exactly what submission would
    produce or reject.
    """

    document_date: date
    year: int
    proposed_number: str
    client: InvoiceClient
    lines: tuple[InvoiceDocumentLine, ...]
    calculation: DocumentCalculation


def calculate_document_result(
    doc_type: str,
    payment_method: str,
    show_timbre: bool,
    lines: Sequence[InvoiceDocumentLine],
) -> DocumentCalculation:
    """The ONE Phase 1 calculation path for document lines.

    Orders lines by ``position`` (authoring order), validates through
    ``calculate_document_totals`` (doc_type / payment_method /
    show_timbre wiring exactly like main.py ``document_out`` /
    ``preview_document``), then derives per-line totals and the French
    amount-in-words sentence. Decimal in, centime-quantized Decimal out.
    """
    ordered = sorted(lines, key=lambda line: line.position)
    facture_lines = [_to_facture_line(line) for line in ordered]
    totals = _facturation_call(
        calculate_document_totals,
        facture_lines,
        doc_type=doc_type,
        payment_method=payment_method,
        show_timbre=show_timbre,
    )
    line_totals = tuple(calculate_line(facture_line) for facture_line in facture_lines)
    return DocumentCalculation(
        totals=totals,
        line_totals=line_totals,
        amount_in_words=amount_in_words(totals.net_a_payer, doc_type),
    )


# ---------------------------------------------------------------------------
# Detail payload builders (Phase 7: ONE mapper for the API and the PDF)
# ---------------------------------------------------------------------------


def build_client_ref(client: InvoiceClient | None) -> InvoiceClientRefResponse | None:
    """``invoice_clients`` row → the embedded client reference payload."""
    if client is None:
        return None
    return InvoiceClientRefResponse(
        id=client.id,
        name=client.name,
        address=client.address,
        wilaya=client.wilaya,
        phone=client.phone,
        nif=client.nif,
        rc=client.rc,
        ai=client.ai,
        nis=client.nis,
        is_archived=client.archived_at is not None,
        created_at=client.created_at,
        updated_at=client.updated_at,
    )


def build_totals_response(totals: DocumentTotals) -> InvoiceDocumentTotalsResponse:
    """Phase 1 ``DocumentTotals`` → response (centime Decimals as-is)."""
    return InvoiceDocumentTotalsResponse(
        total_ht=totals.total_ht,
        total_tva=totals.total_tva,
        total_ttc=totals.total_ttc,
        timbre=totals.timbre,
        net_a_payer=totals.net_a_payer,
    )


def build_line_fields(line: InvoiceDocumentLine) -> dict[str, Any]:
    """The Phase 2 line snapshot (shared by detail and preview lines)."""
    return {
        "product_id": line.product_id,
        "description": line.description,
        "quantity": to_decimal(line.quantity),
        "unit_price_ht": to_decimal(line.unit_price_ht),
        "tva_rate": to_decimal(line.tva_rate),
        "discount_pct": to_decimal(line.discount_pct),
        "position": line.position,
    }


def build_line_response(
    line: InvoiceDocumentLine, line_totals: LineTotals
) -> InvoiceLineResponse:
    """Persisted line + its Phase 1 totals (position order supplied by caller)."""
    return InvoiceLineResponse(
        id=line.id,
        total_ht=line_totals.net_ht,
        total_tva=line_totals.tva,
        **build_line_fields(line),
    )


def build_document_response(document: InvoiceDocument) -> InvoiceDocumentResponse:
    """Full document + the shared Phase 1 calculation (single path).

    The ONE detail mapper: ``GET /factures/{id}``, the create and update
    responses AND the Phase 7 PDF printer all consume this payload, so a
    printed document can never disagree with the API it came from.
    """
    calculation = calculate_document_result(
        document.doc_type,
        document.payment_method,
        document.show_timbre,
        document.lines,
    )
    ordered = sorted(document.lines, key=lambda line: line.position)
    lines = [
        build_line_response(line, line_totals)
        for line, line_totals in zip(ordered, calculation.line_totals)
    ]
    return InvoiceDocumentResponse(
        id=document.id,
        doc_type=document.doc_type,
        year=document.year,
        number=document.number,
        document_date=document.document_date,
        client_id=document.client_id,
        client=build_client_ref(document.client),
        payment_method=document.payment_method,
        notes=document.notes,
        show_discount=document.show_discount,
        show_tva=document.show_tva,
        show_timbre=document.show_timbre,
        show_payment_method=document.show_payment_method,
        show_amount_words=document.show_amount_words,
        lines=lines,
        totals=build_totals_response(calculation.totals),
        amount_in_words=calculation.amount_in_words,
        created_at=document.created_at,
        updated_at=document.updated_at,
    )


def _clean_notes(value: Any) -> str | None:
    """Trim notes; blank becomes NULL (Phase 3 optional-string rule)."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValidationError(
            message="notes must be a string",
            details={"field": "notes"},
        )
    return value.strip() or None


class InvoiceDocumentService(BaseService):
    """Application service for facturation documents (Phase 5).

    Owns the transaction for create/update (number allocation + document
    + lines + audit commit or roll back together). Reads (get/list)
    are transaction-free. No delete operation exists — historical fiscal
    documents are never casually deleted.
    """

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = InvoiceDocumentRepository(db)
        self.clients = InvoiceClientService(db)
        self.products = InvoiceProductService(db)

    # ── Reads ────────────────────────────────────────────────────────

    def get(self, document_id: uuid.UUID) -> InvoiceDocument:
        """Fetch one document (lines + client via selectin) or 404."""
        return self.repo.get_by_id_or_none(document_id)

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        doc_type: str | None = None,
        year: int | None = None,
        client_id: uuid.UUID | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
        q: str | None = None,
    ) -> tuple[list[InvoiceDocument], int]:
        """Filtered, paginated document list (deterministic ordering).

        A ``doc_type`` filter runs through the Phase 1 authority (a
        typo is a 422, not a silently-empty list). Archived invoice
        clients keep their documents listable — documents have no
        archive flag at all.
        """
        if doc_type is not None:
            _facturation_call(validate_doc_type, doc_type)
        if date_from is not None and date_to is not None and date_from > date_to:
            raise ValidationError(
                message="date_from must be on or before date_to",
                details={"date_from": str(date_from), "date_to": str(date_to)},
            )
        return self.repo.search(
            doc_type=doc_type,
            year=year,
            client_id=client_id,
            date_from=date_from,
            date_to=date_to,
            q=q,
            page=page,
            page_size=page_size,
        )

    # ── Create ───────────────────────────────────────────────────────

    def create(
        self,
        request: InvoiceDocumentCreateRequest,
        *,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceDocument:
        """Create one document + lines + counter increment atomically.

        Every validation (doc_type, payment, client usability, product
        resolution, line domain rules) happens BEFORE the transaction so
        an invalid request never reaches the counter; inside the
        transaction the number allocation and the document insert share
        one commit — a failure after allocation rolls both back.
        """
        doc_type = _facturation_call(validate_doc_type, request.doc_type)
        payment_method = _facturation_call(validate_payment_method, request.payment_method)
        client = self.clients.ensure_usable_for_new_document(request.client_id)
        document_date = request.document_date or date.today()  # source: data.date or today
        year = document_date.year  # numbering year = document-date year (source)
        lines = self._resolve_lines(request.lines)
        _facturation_call(
            validate_document_inputs,
            doc_type,
            payment_method,
            [_to_facture_line(line) for line in lines],
        )
        notes = _clean_notes(request.notes)

        with self.transaction():
            number = self.repo.allocate_number(doc_type, year)
            document = InvoiceDocument(
                doc_type=doc_type,
                number=number,
                year=year,
                document_date=document_date,
                client_id=client.id,
                payment_method=payment_method,
                notes=notes,
                show_discount=request.show_discount,
                show_tva=request.show_tva,
                show_timbre=request.show_timbre,
                show_payment_method=request.show_payment_method,
                show_amount_words=request.show_amount_words,
            )
            document.lines = lines
            self.repo.create(document)
            self._audit(
                AuditAction.CREATE,
                entity_id=document.id,
                actor_id=actor_id,
                details=f"created {doc_type} document {number}",
            )
        logger.info(
            "invoice_document_created",
            document_id=str(document.id),
            number=number,
        )
        return document

    # ── Update ───────────────────────────────────────────────────────

    def update(
        self,
        document_id: uuid.UUID,
        request: InvoiceDocumentUpdateRequest,
        *,
        actor_id: uuid.UUID | None = None,
    ) -> InvoiceDocument:
        """Partial update — only supplied fields change (Phase 9 style).

        Immutable fields (id / doc_type / year / number /
        document_date) are not part of the update schema at all, so
        they can never be expressed, let alone applied. ``lines`` (when
        supplied) atomically replaces the whole line set through the
        cascade; when omitted, existing lines are untouched. No field
        change ever re-allocates a number. An empty body is a no-op
        (no audit row), matching InvoiceClientService.update.
        """
        document = self.get(document_id)
        data = request.model_dump(exclude_unset=True, exclude={"lines"})
        new_lines = list(request.lines) if "lines" in request.model_fields_set else None

        if "client_id" in data:
            data["client_id"] = self.clients.ensure_usable_for_new_document(data["client_id"]).id
        if "payment_method" in data:
            data["payment_method"] = _facturation_call(
                validate_payment_method, data["payment_method"]
            )
        if "notes" in data:
            data["notes"] = _clean_notes(data["notes"])

        if new_lines is not None:
            new_lines = self._resolve_lines(new_lines)
            _facturation_call(
                validate_document_inputs,
                document.doc_type,
                data.get("payment_method", document.payment_method),
                [_to_facture_line(line) for line in new_lines],
            )

        if not data and new_lines is None:
            return document  # nothing supplied — no-op, no audit

        with self.transaction():
            for field, value in data.items():
                setattr(document, field, value)
            if new_lines is not None:
                document.lines = new_lines  # delete-orphan: atomic replace
            changed = sorted(data) + (["lines"] if new_lines is not None else [])
            self._audit(
                AuditAction.UPDATE,
                entity_id=document.id,
                actor_id=actor_id,
                details="updated fields: " + ", ".join(changed),
            )
        logger.info(
            "invoice_document_updated",
            document_id=str(document.id),
            fields=changed,
        )
        return document

    # ── Preview (no persistence) ─────────────────────────────────────

    def preview(self, request: InvoiceDocumentCreateRequest) -> DocumentPreviewResult:
        """Dry-run: resolve client + products, validate, calculate.

        Identical inputs and validation to ``create`` (including the
        archived-client gate and Phase 1 line rules), but no
        transaction, no rows written, no number consumed. The returned
        ``proposed_number`` is a read-only peek at the counter —
        advisory under concurrency, exactly like the source preview.
        """
        doc_type = _facturation_call(validate_doc_type, request.doc_type)
        payment_method = _facturation_call(validate_payment_method, request.payment_method)
        client = self.clients.ensure_usable_for_new_document(request.client_id)
        document_date = request.document_date or date.today()
        year = document_date.year
        lines = self._resolve_lines(request.lines)
        calculation = calculate_document_result(
            doc_type, payment_method, request.show_timbre, lines
        )
        return DocumentPreviewResult(
            document_date=document_date,
            year=year,
            proposed_number=self.repo.peek_next_number(doc_type, year),
            client=client,
            lines=tuple(lines),
            calculation=calculation,
        )

    # ── Internals ────────────────────────────────────────────────────

    def _resolve_lines(self, lines: Sequence[InvoiceLineRequest]) -> list[InvoiceDocumentLine]:
        """Build snapshot line rows from request lines (Phase 4 prefill).

        Product lines resolve through ``InvoiceProductService`` (404 /
        archived 422) and take the prefill ONLY for fields the client
        omitted — an explicitly sent description / price / VAT always
        wins (``products.price`` is the INITIAL HT price, editable).
        Free-text lines carry ``product_id = NULL`` and must provide
        description + unit_price_ht + tva_rate (the Pydantic schema
        enforces this for API callers too). Positions default to the
        list index. Nothing here touches promotion / wholesale /
        selling-unit pricing, Customer, inventory or stock.
        """
        resolved: list[InvoiceDocumentLine] = []
        for index, line in enumerate(lines):
            if line.product_id is not None:
                prefill = self.products.get_product_for_invoice(line.product_id)
                description = (line.description or "").strip()
                product_id = prefill.product_id
                description = description or prefill.description
                unit_price_ht = (
                    line.unit_price_ht if line.unit_price_ht is not None else prefill.unit_price_ht
                )
                tva_rate = line.tva_rate if line.tva_rate is not None else prefill.tva_rate
            else:
                # Free-text line: mirror the schema rules at service level
                # so direct (non-API) callers are equally protected.
                if not (line.description or "").strip():
                    raise ValidationError(
                        message="description is required for free-text lines",
                        details={"field": "description"},
                    )
                if line.unit_price_ht is None:
                    raise ValidationError(
                        message="unit_price_ht is required for free-text lines",
                        details={"field": "unit_price_ht"},
                    )
                if line.tva_rate is None:
                    raise ValidationError(
                        message="tva_rate is required for free-text lines",
                        details={"field": "tva_rate"},
                    )
                product_id = None
                description = line.description.strip()
                unit_price_ht = line.unit_price_ht
                tva_rate = line.tva_rate
            resolved.append(
                InvoiceDocumentLine(
                    product_id=product_id,
                    description=description,
                    quantity=to_decimal(line.quantity),
                    unit_price_ht=to_decimal(unit_price_ht),
                    tva_rate=to_decimal(tva_rate),
                    discount_pct=to_decimal(line.discount_pct),
                    position=(line.position if line.position is not None else index),
                )
            )
        return resolved

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        Same contract as InvoiceClientService: a committed mutation
        always has its audit entry, a rolled-back one leaves no orphan.
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="invoice_document",
                entity_id=entity_id,
                details=details,
            )
        )


# =========================================================================
# Phase 6 — company / fiscal identity (read-only settings abstraction)
# =========================================================================


@dataclass(frozen=True)
class FacturationCompanySettings:
    """Seller identity a facturation document header renders.

    A READ VIEW over the existing ``app_settings`` singleton row, not a
    second settings system: ``name`` / ``address`` / ``phone`` ARE the
    ``store_name`` / ``store_address`` / ``store_phone`` columns every
    other feature already edits, and the remaining fields are the Phase 6
    company/fiscal columns (``store_wilaya`` / ``store_email`` /
    ``store_nif`` / ``store_nis`` / ``store_rc`` / ``store_ai`` /
    ``store_rib``).

    Values come back exactly as stored (``""`` when unset) so a future
    renderer can skip blank lines the way factura_simple does: ``_id_line``
    hides non-existent ids and PDF export refuses with ``companyMissing``
    when the company name is empty.
    """

    name: str
    address: str
    wilaya: str
    phone: str
    email: str
    nif: str
    nis: str
    rc: str
    ai: str
    rib: str


def get_facturation_company_settings(db: Session) -> FacturationCompanySettings:
    """Current company/fiscal identity for document rendering (Phase 6).

    Reads through :class:`SettingsService` — the single source of truth
    for settings: nothing is written here, a fresh install returns the
    documented defaults (``store_name`` from ``.env``), and the audited
    write path stays exactly where it is (``PUT /api/v1/settings``).
    """
    row = SettingsService(db).get()
    return FacturationCompanySettings(
        name=row.store_name,
        address=row.store_address,
        wilaya=row.store_wilaya,
        phone=row.store_phone,
        email=row.store_email,
        nif=row.store_nif,
        nis=row.store_nis,
        rc=row.store_rc,
        ai=row.store_ai,
        rib=row.store_rib,
    )
