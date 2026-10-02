"""Export / print request schemas (Phase 15 §12, §17).

Format and report slugs are plain strings here — an unknown value is the
documented ``EXPORT_FORMAT_UNSUPPORTED`` (its own error code), not a
generic validation error. ``paper`` / ``locale`` / ``document_type`` are
allowlisted literals, so a bad value stays a standard 422
``VALIDATION_ERROR`` (§19.1). Filter shapes mirror the ``GET /reports/*``
query parameters exactly.
"""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Literal

from pydantic import Field

from app.schemas.common import StrictBaseModel

ExportLocale = Literal["ar", "fr", "en"]


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
