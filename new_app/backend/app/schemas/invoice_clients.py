"""Invoice (fiscal) client schemas (Phase 8 — Flutter facturation UI).

Wire models for ``/api/v1/invoice-clients`` — the master-data CRUD
surface over the Phase 2 ``InvoiceClientService``.

The response representation is intentionally the SAME
``InvoiceClientRefResponse`` embedded in document payloads
(``app.schemas.facturation``): one shape for an invoice client
everywhere in the API. Cleaning / blank / max-length rules stay in the
service (single business-rule authority) — these models only pin the
request shape and paginate the list.
"""

from __future__ import annotations

from pydantic import Field

from app.schemas.common import StrictBaseModel
from app.schemas.facturation import InvoiceClientRefResponse

#: Standalone alias of the embedded client reference — same fields,
#: same serialization; imported so callers keep one import site.
InvoiceClientResponse = InvoiceClientRefResponse


class InvoiceClientCreateRequest(StrictBaseModel):
    """POST /api/v1/invoice-clients — create one invoice client.

    ``name`` is the only required field (factura_simple parity); every
    fiscal identifier is optional. Blank-to-NULL cleaning and exact
    max-length rules are the service's authority.
    """

    name: str = Field(..., min_length=1, max_length=200)
    address: str | None = None
    wilaya: str | None = Field(default=None, max_length=100)
    phone: str | None = Field(default=None, max_length=30)
    nif: str | None = Field(default=None, max_length=30)
    rc: str | None = Field(default=None, max_length=30)
    ai: str | None = Field(default=None, max_length=30)
    nis: str | None = Field(default=None, max_length=30)


class InvoiceClientUpdateRequest(StrictBaseModel):
    """PUT /api/v1/invoice-clients/{id} — partial update.

    Only fields present in the body change (``exclude_unset`` at the
    router → the service ``_Unset`` sentinel). An explicit ``null``
    (or blank string) CLEARS an optional field; an explicit ``null``
    for ``name`` is rejected by the service (422). A body with no
    fields is a no-op.
    """

    name: str | None = Field(default=None, max_length=200)
    address: str | None = None
    wilaya: str | None = Field(default=None, max_length=100)
    phone: str | None = Field(default=None, max_length=30)
    nif: str | None = Field(default=None, max_length=30)
    rc: str | None = Field(default=None, max_length=30)
    ai: str | None = Field(default=None, max_length=30)
    nis: str | None = Field(default=None, max_length=30)


class InvoiceClientListResponse(StrictBaseModel):
    """Paginated invoice-client list (project envelope convention)."""

    items: list[InvoiceClientResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1
