"""Audit trail API schemas (slice A).

Read-only contract for ``GET /api/v1/audit`` — list, detail and summary.
The screen's five questions map to fields as follows:

* who           → actor_id + actor_name (snapshotted, survives deletion)
* what          → action + module + entity_type / entity_id / entity_ref
* when          → occurred_at (action_at) + recorded_at (created_at)
* which PC      → device_id + device_name + device_verified + ip_address
* what changed  → before / after snapshots + computed field-level diff
* why           → reason (operator-given) + details (structured context)
* outcome       → outcome (success / failure / denied / unknown)
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import Field

from app.schemas.common import PaginatedResponse, StrictBaseModel


class AuditEventResponse(StrictBaseModel):
    """One audit trail entry."""

    id: uuid.UUID
    occurred_at: datetime = Field(description="When the action happened (action_at)")
    recorded_at: datetime | None = Field(
        default=None,
        description="When the row was written (created_at); exposed as recorded_at",
    )
    outcome: str = Field(
        description="success | failure | denied | unknown (NULL legacy rows)"
    )
    module: str | None = Field(default=None, description="Functional module filter key")
    action: str
    actor_id: uuid.UUID | None = None
    actor_name: str | None = Field(
        default=None,
        description="Snapshotted name; falls back to the joined user, "
        "then 'deleted user' when the FK was SET NULL",
    )
    device_id: str | None = None
    device_name: str | None = Field(
        default=None,
        description="Registry display name — only when device_verified is true",
    )
    device_verified: bool | None = Field(
        default=None,
        description="true = validated by device_guard; false = unvalidated "
        "header claim; null = no device offered",
    )
    session_id: str | None = None
    request_id: str | None = None
    ip_address: str | None = None
    entity_type: str | None = None
    entity_id: uuid.UUID | None = None
    entity_ref: str | None = Field(
        default=None, description="Human business reference (invoice number...)"
    )
    reason: str | None = None
    details: str | None = Field(
        default=None, description="Structured context (JSON text) or prose"
    )
    before: dict[str, Any] | None = None
    after: dict[str, Any] | None = None
    diff: dict[str, Any] | None = Field(
        default=None,
        description="Computed field-level diff {field: {before, after}}",
    )
    metadata: dict[str, Any] | None = None


class AuditEventListResponse(PaginatedResponse[AuditEventResponse]):
    """Paginated audit trail page."""


class AuditGroupCount(StrictBaseModel):
    key: str | None
    count: int


class AuditSummaryResponse(StrictBaseModel):
    """Aggregate counts for the filtered window."""

    total: int
    success: int
    failure: int
    denied: int
    unknown: int
    distinct_users: int
    distinct_devices: int
    by_action: list[AuditGroupCount]
    by_module: list[AuditGroupCount]
