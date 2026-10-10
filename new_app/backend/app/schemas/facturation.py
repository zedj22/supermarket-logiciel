"""Facturation document schemas (Phase 5 — REST API).

Request/response models for ``/api/v1/factures`` (FAC / DEV / PRO / BC /
BL) plus the client reference embedded in document payloads.

Conventions (Phase 8 sale + Phase 9 customer schemas)
-----------------------------------------------------
- Money fields are ``Decimal`` — never float (Phase 0 money rule): JSON
  serialization therefore emits decimal strings, matching every other
  money-bearing response in this API.
- Create and update are separate models. The update model deliberately
  OMITS the immutable numbering identity (``doc_type`` / ``year`` /
  ``number``) and ``document_date``: those columns can never change
  after creation, so a client cannot even express such a change (extra
  keys are ignored, Pydantic default).
- ``year`` is never a client-supplied field: the service derives it from
  ``document_date`` (source parity ``data.date or date.today()``).

Validation split
----------------
Pydantic owns shape / types / basic bounds (line count >= 1, qty > 0,
price >= 0, discount 0..100). The Phase 1 domain
(``app.domain.facturation``) remains the single authority for doc_type
and payment-method membership and the ``tva_rate ∈ {0, 9, 19}`` set —
those checks are NOT duplicated here. The conditional line rules
(free-text lines need description/unit_price_ht/tva_rate) are enforced
here AND in the service so direct service calls stay safe too.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from pydantic import Field, field_validator, model_validator

from app.schemas.common import StrictBaseModel

# ---------------------------------------------------------------------------
# Client reference (embedded in document responses)
# ---------------------------------------------------------------------------


class InvoiceClientRefResponse(StrictBaseModel):
    """Invoice (fiscal) client as embedded in document payloads.

    Live reference, not a snapshot: the Phase 2 schema keeps only
    ``invoice_documents.client_id`` (FK RESTRICT). Historical documents
    always keep their client row (hard delete is blocked), but renamed /
    re-fiscalised fields reflect the client's CURRENT state.
    """

    id: uuid.UUID
    name: str
    address: str | None = None
    wilaya: str | None = None
    phone: str | None = None
    nif: str | None = None
    rc: str | None = None
    ai: str | None = None
    nis: str | None = None
    is_archived: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------


class InvoiceLineRequest(StrictBaseModel):
    """One requested invoice line.

    product_id present  -> description / unit_price_ht / tva_rate are
    optional and prefill from the Product when omitted (Phase 4
    prefill); any value the client DOES send wins — ``products.price``
    and ``products.vat_rate`` are the INITIAL values, never a live
    price source.

    Stage 3A option identity (all optional, additive):
    - ``variant_id`` (+ ``product_id``): initial price is
      ``variant.price`` when set, else ``products.price``; description
      prefills to ``"{product} · {variant}"``.
    - ``selling_unit_id`` (+ ``product_id``): initial price is
      ``effective_unit_price(unit.selling_price, product.price)``
      (selling-unit price wins when present, else the product price
      AS-IS — the multiplier never multiplies the price); description
      prefills to ``"{product} · {unit}"``. Cannot combine with
      ``variant_id`` (SaleService parity).
    - ``pack_id`` (alone — no product/variant/unit): initial price is
      ``pack.price``, description prefills to the pack name, and
      ``tva_rate`` prefills to 0 (a pack spans products, so it has no
      single authoritative VAT rate; the client may send any {0,9,19}).

    product_id absent (free-text line, ``product_id = NULL``) ->
    description, unit_price_ht and tva_rate are all REQUIRED.
    """

    product_id: uuid.UUID | None = None
    variant_id: uuid.UUID | None = None
    selling_unit_id: uuid.UUID | None = None
    pack_id: uuid.UUID | None = None
    description: str | None = Field(default=None)
    quantity: Decimal = Field(..., gt=0)
    unit_price_ht: Decimal | None = Field(default=None, ge=0)
    tva_rate: Decimal | None = None  # membership {0,9,19} = Phase 1 domain
    discount_pct: Decimal = Field(default=Decimal("0"), ge=0, le=100)
    position: int | None = None  # defaults to the line's index when omitted

    @model_validator(mode="after")
    def _free_text_lines_need_identity(self) -> InvoiceLineRequest:
        # A line carrying any identity (product / variant / unit / pack)
        # is not free-text — the combination validator below owns the
        # "option without product" errors.
        if (
            self.product_id is None
            and self.pack_id is None
            and self.variant_id is None
            and self.selling_unit_id is None
        ):
            if not self.description:
                raise ValueError("description is required for free-text lines")
            if self.unit_price_ht is None:
                raise ValueError("unit_price_ht is required for free-text lines")
            if self.tva_rate is None:
                raise ValueError("tva_rate is required for free-text lines")
        return self

    @model_validator(mode="after")
    def _option_combinations(self) -> InvoiceLineRequest:
        if self.pack_id is not None:
            if (
                self.product_id is not None
                or self.variant_id is not None
                or self.selling_unit_id is not None
            ):
                raise ValueError(
                    "pack_id cannot be combined with product_id, "
                    "variant_id or selling_unit_id"
                )
        if self.variant_id is not None and self.selling_unit_id is not None:
            raise ValueError(
                "selling_unit_id cannot be combined with variant_id"
            )
        if self.variant_id is not None and self.product_id is None:
            raise ValueError("variant_id requires product_id")
        if self.selling_unit_id is not None and self.product_id is None:
            raise ValueError("selling_unit_id requires product_id")
        return self


class InvoiceDocumentCreateRequest(StrictBaseModel):
    """POST /api/v1/factures — create one document.

    ``year`` is intentionally absent: the service derives it from
    ``document_date`` (or today, exactly like the source's
    ``data.date or date.today()``). Number allocation happens inside
    the create transaction.

    ``register_as_sale`` (optional, default False): when true the
    service attempts to post the created FAC as a POS sale through
    SaleService (stock + sales + reports + financials). Only FAC is
    eligible; if the post fails the document is still created and
    returned with ``sale_id = null`` so the client can retry via
    ``POST /factures/{id}/post``.
    """

    doc_type: str = "FAC"  # domain membership {FAC,DEV,PRO,BC,BL}
    client_id: uuid.UUID
    document_date: date | None = None
    payment_method: str = "cash"  # domain {cash, transfer, cheque}
    notes: str | None = None
    show_discount: bool = True
    show_tva: bool = True
    show_timbre: bool = True
    show_payment_method: bool = True
    show_amount_words: bool = True
    register_as_sale: bool = False
    lines: list[InvoiceLineRequest] = Field(..., min_length=1)


class InvoiceDocumentUpdateRequest(StrictBaseModel):
    """PUT /api/v1/factures/{id} — partial update.

    Only fields present in the body change (Phase 9 convention,
    ``model_dump(exclude_unset=True)`` in the service). ``lines``,
    when present, atomically REPLACES every existing line.

    Immutable and therefore absent from this model: id, doc_type,
    year, number, document_date. Explicit ``null`` is rejected for
    ``client_id`` / ``payment_method`` / ``lines`` (NOT NULL columns /
    a line list that must stay non-empty); ``notes: null`` clears the
    note. A body with no fields is a no-op.
    """

    client_id: uuid.UUID | None = None
    payment_method: str | None = None
    notes: str | None = None
    show_discount: bool = True
    show_tva: bool = True
    show_timbre: bool = True
    show_payment_method: bool = True
    show_amount_words: bool = True
    register_as_sale: bool = False
    lines: list[InvoiceLineRequest] | None = Field(default=None, min_length=1)

    @field_validator("client_id", "payment_method", "lines")
    @classmethod
    def _explicit_null_not_allowed(cls, v):
        if v is None:
            raise ValueError("must not be null (omit the field instead)")
        return v


# ---------------------------------------------------------------------------
# Responses
# ---------------------------------------------------------------------------


class InvoiceLineResponse(StrictBaseModel):
    """One persisted line: the Phase 2 snapshot + Phase 1 line totals."""

    id: uuid.UUID
    product_id: uuid.UUID | None = None
    variant_id: uuid.UUID | None = None
    selling_unit_id: uuid.UUID | None = None
    pack_id: uuid.UUID | None = None
    description: str
    quantity: Decimal
    unit_price_ht: Decimal
    tva_rate: Decimal
    discount_pct: Decimal
    position: int
    total_ht: Decimal
    total_tva: Decimal


class InvoiceDocumentTotalsResponse(StrictBaseModel):
    """Phase 1 ``DocumentTotals`` (centime precision, Decimal strings)."""

    total_ht: Decimal
    total_tva: Decimal
    total_ttc: Decimal
    timbre: Decimal
    net_a_payer: Decimal


class InvoiceDocumentResponse(StrictBaseModel):
    """Full document: identity + editable fields + lines + totals."""

    id: uuid.UUID
    doc_type: str
    year: int
    number: str
    document_date: date
    client_id: uuid.UUID
    client: InvoiceClientRefResponse | None = None
    payment_method: str
    notes: str | None = None
    show_discount: bool = True
    show_tva: bool = True
    show_timbre: bool = True
    show_payment_method: bool = True
    show_amount_words: bool = True
    lines: list[InvoiceLineResponse]
    totals: InvoiceDocumentTotalsResponse
    amount_in_words: str
    sale_id: uuid.UUID | None = None
    posted_at: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class InvoiceDocumentSummaryResponse(StrictBaseModel):
    """List row: identity + client reference only (no lines / totals).

    The source list endpoint materialised full documents (lines +
    totals) for every row; SP's paginated list convention returns lean
    rows and the detail endpoint carries the calculation.
    """

    id: uuid.UUID
    doc_type: str
    year: int
    number: str
    document_date: date
    client_id: uuid.UUID
    client: InvoiceClientRefResponse | None = None
    payment_method: str
    notes: str | None = None
    sale_id: uuid.UUID | None = None
    posted_at: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None


class InvoiceDocumentListResponse(StrictBaseModel):
    items: list[InvoiceDocumentSummaryResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class InvoiceLinePreviewResponse(StrictBaseModel):
    """One RESOLVED but unpersisted line (preview only — no ``id``).

    Same snapshot fields as ``InvoiceLineResponse`` plus the Phase 1
    per-line totals; nothing was written, so there is no row id.
    """

    product_id: uuid.UUID | None = None
    variant_id: uuid.UUID | None = None
    selling_unit_id: uuid.UUID | None = None
    pack_id: uuid.UUID | None = None
    description: str
    quantity: Decimal
    unit_price_ht: Decimal
    tva_rate: Decimal
    discount_pct: Decimal
    position: int
    total_ht: Decimal
    total_tva: Decimal


class InvoiceDocumentPreviewResponse(StrictBaseModel):
    """POST /api/v1/factures/preview — dry-run calculation result.

    Nothing is persisted and no number is consumed; ``number`` is the
    read-only PROPOSAL for today's counter (source parity — advisory
    only under concurrency, like the source's preview).
    """

    document_date: date
    year: int
    number: str
    client_id: uuid.UUID
    client: InvoiceClientRefResponse | None = None
    lines: list[InvoiceLinePreviewResponse]
    totals: InvoiceDocumentTotalsResponse
    amount_in_words: str
