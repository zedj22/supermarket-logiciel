"""Product import / export schemas (Objective 1).

One vocabulary for both directions: the export columns and the import
target fields are the same names, so an exported file can be edited and
imported back without a translation layer.

Field vocabulary (``IMPORTABLE_FIELDS`` are writable on import;
``INFORMATIONAL_FIELDS`` are exported for reference and explicitly
ignored on import — stock is never product master data here, it only
changes through the inventory service):

* ``product_id``      UUID assigned by this database (match key on import)
* ``name``            required on create, optional on update
* ``barcode``         unique when present
* ``sku``             supplier reference
* ``category``        category NAME (never an id: files travel between DBs)
* ``unit``            ProductUnit code (piece, kg, ...)
* ``sale_price``      products.price  (required on create)
* ``purchase_price``  products.cost   (nominal / last-purchase reference)
* ``wholesale_price`` / ``wholesale_min_qty``   NULL = wholesale not configured
* ``vat_rate``        strict set {0, 9, 19}
* ``low_stock_threshold`` / ``allow_negative_stock`` / ``expiry_date``
* ``description`` / ``image_path`` / ``is_active``
* ``current_stock``   INFORMATIONAL — exported, never written by import
"""

from __future__ import annotations

import uuid
from typing import Literal

from pydantic import Field, model_validator

from app.schemas.common import StrictBaseModel

ExportFormat = Literal["csv", "xlsx"]
ExportScope = Literal["all", "filtered", "selected"]
ImportStatus = Literal["active", "archived", "all"]
OnConflict = Literal["skip", "update", "reject"]

#: Hard caps so one request can never exhaust memory (§Objective 5).
MAX_IMPORT_BYTES = 20 * 1024 * 1024
MAX_IMPORT_ROWS = 50_000
MAX_EXPORT_ROWS = 50_000
MAX_SELECTED_IDS = 50_000

#: Rows echoed back in one report. Counts are always exact; the row list
#: is capped (failures first) so a 50 000-row apply cannot reply with a
#: multi-megabyte payload.
MAX_REPORT_ROWS = 5_000

#: Writable on import.
IMPORTABLE_FIELDS: tuple[str, ...] = (
    "product_id",
    "name",
    "barcode",
    "sku",
    "category",
    "unit",
    "sale_price",
    "purchase_price",
    "wholesale_price",
    "wholesale_min_qty",
    "vat_rate",
    "low_stock_threshold",
    "allow_negative_stock",
    "expiry_date",
    "description",
    "image_path",
    "is_active",
)

#: Exported for reference, ignored on import (stock stays in the
#: inventory ledger — see ``POST /api/v1/inventory/adjust``).
INFORMATIONAL_FIELDS: tuple[str, ...] = ("current_stock",)

#: Full export column order (also the template header order).
EXPORT_FIELDS: tuple[str, ...] = IMPORTABLE_FIELDS + INFORMATIONAL_FIELDS

#: Fields that are never blank on a *create* row.
REQUIRED_ON_CREATE: tuple[str, ...] = ("name", "sale_price")


class ProductExportRequest(StrictBaseModel):
    """``POST /api/v1/products/export`` — which products, which format.

    ``scope`` is the operator-facing promise shown before the download:
    ``all`` = the whole catalogue for ``status``; ``filtered`` = the same
    plus ``search`` / ``category_id``; ``selected`` = exactly
    ``product_ids`` (explicit id list, never a hidden filter).
    """

    format: ExportFormat = "csv"
    scope: ExportScope = "all"
    search: str | None = Field(default=None, max_length=200)
    category_id: uuid.UUID | None = None
    status: ImportStatus = "active"
    product_ids: list[uuid.UUID] = Field(default_factory=list)

    @model_validator(mode="after")
    def _check_scope(self) -> ProductExportRequest:
        if self.scope == "selected":
            if not self.product_ids:
                raise ValueError("scope 'selected' requires at least one product_id")
            if len(self.product_ids) > MAX_SELECTED_IDS:
                raise ValueError(
                    f"scope 'selected' accepts at most {MAX_SELECTED_IDS} ids"
                )
            if len(set(self.product_ids)) != len(self.product_ids):
                raise ValueError("duplicate product_id in product_ids")
        return self


class ImportRow(StrictBaseModel):
    """One data row of an import, as reported to the client."""

    row: int
    action: Literal["create", "update", "skip", "failed"]
    name: str | None = None
    barcode: str | None = None
    messages: list[str] = Field(default_factory=list)


class ImportReport(StrictBaseModel):
    """Preview (dry run) or final report of an import run."""

    dry_run: bool
    applied: bool
    filename: str
    format: Literal["csv", "xlsx"]
    total_rows: int
    created: int
    updated: int
    skipped: int
    failed: int
    mapping: dict[str, int]
    unmapped_columns: list[str] = Field(default_factory=list)
    ignored_fields: list[str] = Field(default_factory=list)
    blank_rows_ignored: int = 0
    rows: list[ImportRow] = Field(default_factory=list)
    rows_truncated: bool = False
    warnings: list[str] = Field(default_factory=list)


