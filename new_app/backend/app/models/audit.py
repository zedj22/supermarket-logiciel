"""Audit log model: audit_logs.

Table: audit_logs

Design principles:
- Immutable audit trail for all sensitive actions.
- Captures actor, action, entity, before/after state, device, IP.
- Slice A additions (0031) are additive nullable columns: every existing
  writer keeps working unchanged, and legacy rows stay honest (NULL =
  "unknown", never backfilled or invented).
"""

import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin
from app.models.enums import AuditOutcome


class AuditLog(Base, UUIDMixin, TimestampMixin):
    """Immutable audit trail entry."""

    __tablename__ = "audit_logs"

    __table_args__ = (
        # Read-API query patterns (audit screen: time-desc listing, per
        # actor / module / device / outcome filters, entity history).
        Index("ix_audit_logs_action_at", "action_at"),
        Index("ix_audit_logs_user_action_at", "user_id", "action_at"),
        Index("ix_audit_logs_module_action_at", "module", "action_at"),
        Index("ix_audit_logs_device_id_action_at", "device_id", "action_at"),
        Index("ix_audit_logs_outcome_action_at", "outcome", "action_at"),
        Index("ix_audit_logs_entity_type_entity_id", "entity_type", "entity_id"),
    )

    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    action: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    entity_type: Mapped[str | None] = mapped_column(String(50), index=True)
    entity_id: Mapped[uuid.UUID | None] = mapped_column(index=True)
    details: Mapped[str | None] = mapped_column(Text)
    before_state: Mapped[str | None] = mapped_column(Text)  # JSON snapshot
    after_state: Mapped[str | None] = mapped_column(Text)   # JSON snapshot
    ip_address: Mapped[str | None] = mapped_column(String(45))
    device_id: Mapped[str | None] = mapped_column(String(100))
    action_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False,
        server_default=func.now(),
    )

    # ── Slice A (0031_audit_trail_context) — additive, nullable ─────────
    # outcome: success/failure/denied. NULL on legacy rows = "unknown".
    # Python-side default so every ORM writer that does not override it
    # records "success" (the legacy _audit helpers only run on success
    # paths); NO server default, so pre-migration rows stay NULL/unknown.
    outcome: Mapped[str | None] = mapped_column(
        String(10), index=True, default=AuditOutcome.SUCCESS.value
    )
    # module: AuditModule vocabulary for filtering; NULL = "unknown".
    module: Mapped[str | None] = mapped_column(String(30), index=True)
    # Actor display name snapshotted at write time so deleting the user
    # (users.id FK is SET NULL) never rewrites history.
    actor_name: Mapped[str | None] = mapped_column(String(120))
    # Device display name, set ONLY when the device_guard validated the
    # machine against the registry (device_verified=True).
    device_name: Mapped[str | None] = mapped_column(String(150))
    # False = unvalidated free-text header claim; None = not offered.
    device_verified: Mapped[bool | None] = mapped_column(Boolean, default=None)
    # Opaque JWT-session id / X-Request-ID correlation id (no FKs: the
    # trail must survive session or request cleanup).
    session_id: Mapped[str | None] = mapped_column(String(64), index=True)
    request_id: Mapped[str | None] = mapped_column(String(64))
    # Business reason the operator gave (void reason, adjustment reason...).
    reason: Mapped[str | None] = mapped_column(Text)
    # Human business reference (invoice number, purchase number, settings
    # singleton...) so the trail is readable without joining entities.
    entity_ref: Mapped[str | None] = mapped_column(String(100))
    # Allowlisted extra context as JSON (never secrets — AuditService
    # redacts before serializing). Named metadata_json because the
    # declarative base already owns the ``metadata`` attribute.
    metadata_json: Mapped[str | None] = mapped_column(Text)

    # Relationships
    user: Mapped["User | None"] = relationship(  # noqa: F821
        "User",
        lazy="selectin",
    )
