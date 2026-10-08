"""Export / print request schemas (Phase 15 §12, §17).

Format and report slugs are plain strings here — an unknown value is the
documented ``EXPORT_FORMAT_UNSUPPORTED`` (its own error code), not a
generic validation error. ``paper`` / ``locale`` / ``document_type`` are
allowlisted literals, so a bad value stays a standard 422
``VALIDATION_ERROR`` (§19.1). Filter shapes mirror the ``GET /reports/*``
query parameters exactly.

Product price labels (§ barcode labels): ``LabelPrintRequest`` carries the
selected products (id + copies), an optional sheet layout and the same
paper/locale literals as ``PrintRequest``. Fit checks (label fits paper,
explicit cols/rows fit, batch caps) run at schema level so a bad layout is
a 422 VALIDATION_ERROR before any DB read or render.
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Literal

from pydantic import Field, model_validator

from app.schemas.common import StrictBaseModel

ExportLocale = Literal["ar", "fr", "en"]

# Label batch caps — a shelf run is a few hundred labels; 5000 keeps one
# request bounded (render time) without limiting any realistic batch.
LABEL_MAX_ITEMS = 500
LABEL_MAX_TOTAL = 5000

# Paper footprints in mm (label sheets are physical templates — mm only).
A4_WIDTH_MM = 210.0
A4_HEIGHT_MM = 297.0
ROLL_WIDTH_MM = 80.0
# Default roll segment length when rows are not pinned (≈ one A4 sheet).
ROLL_DEFAULT_HEIGHT_MM = 297.0


class ExportRequest(StrictBaseModel):
    """POST /api/v1/exports — render one report as XLSX or PDF."""

    report: str = Field(..., min_length=1, max_length=40)
    format: str = Field(..., min_length=1, max_length=10)
    locale: ExportLocale = "ar"
    date_from: date | None = None
    date_to: date | None = None
    device_id: str | None = Field(default=None, max_length=100)
    status: str | None = Field(default=None, pattern="^(completed|void|all)$")
    payment_method: str | None = Field(default=None, pattern="^(cash|card|credit|partial)$")
    user_id: uuid.UUID | None = None
    sort: str | None = Field(default=None, max_length=40)
    days: int | None = Field(default=None, ge=1, le=365)
    threshold: Decimal | None = Field(default=None, ge=0)
    lookback_days: int | None = Field(default=None, ge=1, le=90)


class PrintRequest(StrictBaseModel):
    """POST /api/v1/print — render sale / return as PDF bytes.

    ``purchase`` is intentionally NOT in the allowlist: purchase printing
    is deferred out of Phase 15 (Step A scope), so an attempt is a
    standard 422 VALIDATION_ERROR — never a render or a scope check.
    """

    document_type: Literal["sale", "return"]
    document_id: uuid.UUID
    paper: Literal["80mm", "A4"] = "80mm"
    locale: ExportLocale = "ar"
    device_id: str | None = Field(default=None, max_length=100)


class LabelItem(StrictBaseModel):
    """One product and how many label copies to print for it."""

    product_id: uuid.UUID
    quantity: int = Field(default=1, ge=1, le=999)


class LabelLayout(StrictBaseModel):
    """Physical label sheet geometry (mm) — all optional, sane defaults.

    ``columns`` / ``rows`` of ``None`` mean "auto-fit": the renderer
    computes how many labels fit on the chosen paper. An explicit value
    that does not fit the paper is rejected here (422) — never silently
    clipped.
    """

    label_width_mm: float = Field(default=50.0, ge=30.0, le=100.0)
    label_height_mm: float = Field(default=30.0, ge=20.0, le=100.0)
    gap_x_mm: float = Field(default=2.0, ge=0.0, le=20.0)
    gap_y_mm: float = Field(default=2.0, ge=0.0, le=20.0)
    margin_x_mm: float = Field(default=5.0, ge=0.0, le=50.0)
    margin_y_mm: float = Field(default=5.0, ge=0.0, le=50.0)
    columns: int | None = Field(default=None, ge=1, le=30)
    rows: int | None = Field(default=None, ge=1, le=100)


class LabelPrintRequest(StrictBaseModel):
    """POST /api/v1/print/labels — render product price labels as PDF.

    The effective price printed per label is resolved server-side (promo
    price when an active promotion applies, retail otherwise) — the
    client never sends prices. Barcodes are printed verbatim from
    ``products.barcode``; a product without a barcode still gets a price
    label (no barcode block), never an invented one.
    """

    items: list[LabelItem] = Field(..., min_length=1, max_length=LABEL_MAX_ITEMS)
    layout: LabelLayout = Field(default_factory=LabelLayout)
    paper: Literal["80mm", "A4"] = "A4"
    locale: ExportLocale = "ar"
    device_id: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def _validate_batch_and_fit(self) -> "LabelPrintRequest":
        ids = [item.product_id for item in self.items]
        if len(set(ids)) != len(ids):
            raise ValueError("duplicate product_id in items")

        total = sum(item.quantity for item in self.items)
        if total > LABEL_MAX_TOTAL:
            raise ValueError(
                f"too many labels: {total} > {LABEL_MAX_TOTAL} maximum"
            )

        layout = self.layout
        paper_w = A4_WIDTH_MM if self.paper == "A4" else ROLL_WIDTH_MM
        paper_h = A4_HEIGHT_MM if self.paper == "A4" else None

        def _width_fit(columns: int) -> bool:
            used = (
                2 * layout.margin_x_mm
                + columns * layout.label_width_mm
                + (columns - 1) * layout.gap_x_mm
            )
            return used <= paper_w + 1e-9

        def _height_fit(rows: int) -> bool:
            assert paper_h is not None  # A4 only (roll height is derived)
            used = (
                2 * layout.margin_y_mm
                + rows * layout.label_height_mm
                + (rows - 1) * layout.gap_y_mm
            )
            return used <= paper_h + 1e-9

        if not _width_fit(1):
            raise ValueError("label_width_mm does not fit the paper width")
        if paper_h is not None and not _height_fit(1):
            raise ValueError("label_height_mm does not fit the paper height")
        if layout.columns is not None and not _width_fit(layout.columns):
            raise ValueError("columns do not fit the paper width")
        if (
            paper_h is not None
            and layout.rows is not None
            and not _height_fit(layout.rows)
        ):
            raise ValueError("rows do not fit the paper height")
        return self
