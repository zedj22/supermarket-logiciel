"""Minimal customer schemas for POS customer picker (Phase 8 Step 3).

Full customer management is Phase 9 — only search/list fields needed
for partial/credit sales are defined here.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import Field

from app.schemas.common import StrictBaseModel


class CustomerResponse(StrictBaseModel):
    """Customer summary returned to the POS picker."""

    id: uuid.UUID
    name: str
    phone: str | None = None
    address: str | None = None
    balance: float = 0
    debt_ceiling: float = 0
    is_archived: bool = False
    created_at: datetime | None = None
    updated_at: datetime | None = None


class CustomerListResponse(StrictBaseModel):
    items: list[CustomerResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1
