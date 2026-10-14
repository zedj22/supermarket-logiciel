"""Central audit service (audit trail slice A).

One recorder for every NEW or upgraded audit writer. Design rules:

* **In-transaction** — :meth:`AuditService.record` only ``db.add``s the
  row; the caller's transaction (``BaseService.transaction``) commits or
  rolls back business change + audit row together. A change that cannot
  be audited is never reported as committed, and a rolled-back change
  never leaves an orphan "success" row.
* **Redaction first** — details / before / after / metadata payloads pass
  through :func:`redact` before serialization; PINs, passwords, tokens,
  secrets and credential hashes are replaced with ``[REDACTED]`` and are
  never logged.
* **No fabrication** — device identity comes from the validated
  ``request.state`` (device_guard) when available; an unvalidated
  ``X-Device-ID`` header claim is stored only as ``device_verified=False``
  and never gets a display name. Missing outcomes on legacy rows stay
  NULL ("unknown"), never upgraded to "success".
* **Structured diffs** — :func:`build_diff` compares only an explicit
  field allowlist so a snapshot can never dump an entire ORM object.

Legacy note: the ~15 pre-existing private ``_audit`` helpers keep their
call sites for now (slice C converges them). New code and the upgraded
auth/void/settings/inventory writers use this service.
"""

from __future__ import annotations

import json
import re
import uuid
from typing import Any

import structlog
from fastapi import Request
from sqlalchemy import Select, func, or_, select
from sqlalchemy.orm import Session

from app.core.constants import DEVICE_ID_HEADER
from app.models.audit import AuditLog
from app.models.enums import AuditAction, AuditModule, AuditOutcome
from app.models.user import User

logger = structlog.get_logger(__name__)

#: Replacement text for redacted values. Visible so an auditor knows a
#: secret existed and was deliberately withheld — never the secret itself.
REDACTED = "[REDACTED]"

# Keys whose VALUES are secrets and must never be persisted in an audit
# payload (matched case-insensitively against dict keys, whole segments).
_SENSITIVE_KEY_RE = re.compile(
    r"(^|_)(pin|password|passwd|token|secret|credential|credentials|"
    r"api_key|apikey|authorization|auth_token|access_token|refresh_token|"
    r"pin_hash|token_hash|hash|salt)($|_)",
    re.IGNORECASE,
)

_JSON_DEFAULT = str  # Decimal / datetime / UUID → stable string form


def is_sensitive_key(key: str) -> bool:
    """True when a dict key names a secret (PIN, token, hash, ...)."""
    return bool(_SENSITIVE_KEY_RE.search(key))


def redact(value: Any) -> Any:
    """Return a deep copy of ``value`` with secret values masked.

    Recurses through dicts/lists/tuples; sensitive KEYS keep their name
    but their value becomes ``[REDACTED]``. Non-container values pass
    through unchanged.
    """
    if isinstance(value, dict):
        return {
            key: (REDACTED if is_sensitive_key(str(key)) else redact(item))
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [redact(item) for item in value]
    return value


def sanitize_details(details: Any) -> str | None:
    """Normalize ``details`` into the TEXT column form.

    dicts/lists are redacted then JSON-serialized; strings are kept as-is
    (the caller is responsible for not embedding secrets in prose); None
    stays None.
    """
    if details is None:
        return None
    if isinstance(details, str):
        return details
    return json.dumps(redact(details), default=_JSON_DEFAULT, ensure_ascii=True)


def dumps_snapshot(snapshot: Any) -> str | None:
    """Redact + JSON-serialize a before/after snapshot for storage."""
    if snapshot is None:
        return None
    return json.dumps(redact(snapshot), default=_JSON_DEFAULT, ensure_ascii=True)


def build_diff(
    before: Any,
    after: Any,
    fields: list[str] | None = None,
) -> dict[str, dict[str, Any]]:
    """Field-level diff restricted to an allowlist.

    ``fields`` names the keys to compare (the caller's explicit allowlist —
    never "dump the whole object"). When None, the union of both mappings'
    keys is compared. Values are redacted. The result maps each CHANGED
    field to ``{"before": ..., "after": ...}``; unchanged fields are omitted.
    """
    before_map = before if isinstance(before, dict) else {}
    after_map = after if isinstance(after, dict) else {}
    keys = fields if fields is not None else sorted(set(before_map) | set(after_map))
    diff: dict[str, dict[str, Any]] = {}
    for key in keys:
        if is_sensitive_key(str(key)):
            # Mask both sides BEFORE comparison: a secret "change" is
            # never observable in a diff.
            old, new = REDACTED, REDACTED
        else:
            old = redact(before_map.get(key))
            new = redact(after_map.get(key))
        if old != new:
            diff[key] = {"before": old, "after": new}
    return diff


def loads_json(raw: str | None) -> Any:
    """Best-effort JSON parse for the read API; None on empty/invalid."""
    if not raw:
        return None
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return None


class AuditService:
    """Append-only audit recorder + read/query API."""

    def __init__(self, db: Session):
        self.db = db

    # ── Write ──────────────────────────────────────────────────────────

    def record(
        self,
        *,
        action: AuditAction | str,
        module: AuditModule | str | None = None,
        entity_type: str | None = None,
        entity_id: uuid.UUID | str | None = None,
        entity_ref: str | None = None,
        user_id: uuid.UUID | str | None = None,
        actor_name: str | None = None,
        device_id: str | None = None,
        device_name: str | None = None,
        device_verified: bool | None = None,
        session_id: uuid.UUID | str | None = None,
        request_id: str | None = None,
        ip_address: str | None = None,
        outcome: AuditOutcome | str | None = AuditOutcome.SUCCESS,
        reason: str | None = None,
        details: Any = None,
        before: Any = None,
        after: Any = None,
        metadata: dict[str, Any] | None = None,
    ) -> AuditLog:
        """Append one audit row to the CURRENT transaction (no commit).

        Everything user-supplied (details / before / after / metadata) is
        redacted before serialization. Callers own the transaction: wrap
        in ``BaseService.transaction()`` so the business change and this
        row commit or roll back together.
        """
        row = AuditLog(
            user_id=_as_uuid_or_none(user_id),
            action=_enum_value(action),
            module=_enum_value(module),
            outcome=_enum_value(outcome),
            entity_type=entity_type,
            entity_id=_as_uuid_or_none(entity_id),
            entity_ref=str(entity_ref)[:100] if entity_ref else None,
            actor_name=actor_name,
            device_id=device_id,
            device_name=device_name,
            device_verified=device_verified,
            session_id=_as_uuid_str(session_id),
            request_id=request_id,
            ip_address=ip_address,
            reason=reason,
            details=sanitize_details(details),
            before_state=dumps_snapshot(before),
            after_state=dumps_snapshot(after),
            metadata_json=dumps_snapshot(metadata),
        )
        self.db.add(row)
        return row

    def record_from_request(
        self,
        request: Request | None,
        **kwargs: Any,
    ) -> AuditLog:
        """Record with actor/device/request context captured from ``request``.

        Context precedence — an explicit ``kwargs`` value always wins over
        the captured one:

        * actor: ``request.state.user`` / ``user_id`` / ``session_id``
          (set by ``get_current_user``);
        * device: ``request.state.device_id`` / ``device_name`` /
          ``device_verified`` (set by ``device_guard``); when the guard
          never ran but the client sent ``X-Device-ID``, the raw header is
          stored UNVERIFIED (no display name — never fabricate identity);
        * ip / request_id: peer address and ``request.state.request_id``
          (set by the correlation-id middleware).
        """
        context = capture_request_audit_context(request)
        context.update(
            {key: value for key, value in kwargs.items() if value is not None}
        )
        return self.record(**context)

    # ── Query (read API) ───────────────────────────────────────────────

    def list_events(
        self,
        *,
        date_from: Any = None,
        date_to: Any = None,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        module: str | None = None,
        action: str | None = None,
        outcome: str | None = None,
        entity_type: str | None = None,
        entity_id: uuid.UUID | None = None,
        q: str | None = None,
        page: int = 1,
        page_size: int = 40,
    ) -> tuple[list[AuditLog], int]:
        """Filtered, time-descending page of audit events + total count."""
        stmt = self._filtered(
            date_from, date_to, user_id, device_id, module,
            action, outcome, entity_type, entity_id, q,
        )
        total = self.db.scalar(
            select(func.count()).select_from(stmt.subquery())
        ) or 0
        rows = list(
            self.db.scalars(
                stmt.order_by(AuditLog.action_at.desc(), AuditLog.id.desc())
                .offset((page - 1) * page_size)
                .limit(page_size)
            ).all()
        )
        return rows, total

    def summary(
        self,
        *,
        date_from: Any = None,
        date_to: Any = None,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        module: str | None = None,
        action: str | None = None,
        outcome: str | None = None,
        entity_type: str | None = None,
        entity_id: uuid.UUID | None = None,
        q: str | None = None,
    ) -> dict[str, Any]:
        """Aggregate counts for the audit screen header."""
        stmt = self._filtered(
            date_from, date_to, user_id, device_id, module,
            action, outcome, entity_type, entity_id, q,
        )

        def _count(extra: Any = None) -> int:
            inner = stmt if extra is None else stmt.where(extra)
            return self.db.scalar(
                select(func.count()).select_from(inner.subquery())
            ) or 0

        def _group(column: Any) -> list[dict[str, Any]]:
            rows = self.db.execute(
                stmt.with_only_columns(column, func.count().label("cnt"))
                .group_by(column)
                .order_by(func.count().label("cnt").desc())
            ).all()
            return [{"key": key, "count": cnt} for key, cnt in rows]

        return {
            "total": _count(),
            "success": _count(AuditLog.outcome == AuditOutcome.SUCCESS.value),
            "failure": _count(AuditLog.outcome == AuditOutcome.FAILURE.value),
            "denied": _count(AuditLog.outcome == AuditOutcome.DENIED.value),
            "unknown": _count(AuditLog.outcome.is_(None)),
            "distinct_users": _count_distinct(self.db, stmt, AuditLog.user_id),
            "distinct_devices": _count_distinct(self.db, stmt, AuditLog.device_id),
            "by_action": _group(AuditLog.action),
            "by_module": _group(AuditLog.module),
        }

    def get_event(self, event_id: uuid.UUID) -> AuditLog | None:
        return self.db.get(AuditLog, event_id)

    # ── Internals ──────────────────────────────────────────────────────

    def _filtered(
        self,
        date_from: Any,
        date_to: Any,
        user_id: uuid.UUID | None,
        device_id: str | None,
        module: str | None,
        action: str | None,
        outcome: str | None,
        entity_type: str | None,
        entity_id: uuid.UUID | None,
        q: str | None,
    ) -> Select:
        stmt = select(AuditLog)
        if date_from is not None:
            stmt = stmt.where(AuditLog.action_at >= date_from)
        if date_to is not None:
            stmt = stmt.where(AuditLog.action_at <= date_to)
        if user_id is not None:
            stmt = stmt.where(AuditLog.user_id == user_id)
        if device_id:
            stmt = stmt.where(AuditLog.device_id == device_id)
        if module:
            stmt = stmt.where(AuditLog.module == module)
        if action:
            stmt = stmt.where(AuditLog.action == action)
        if outcome:
            stmt = stmt.where(AuditLog.outcome == outcome)
        if entity_type:
            stmt = stmt.where(AuditLog.entity_type == entity_type)
        if entity_id is not None:
            stmt = stmt.where(AuditLog.entity_id == entity_id)
        if q:
            pattern = f"%{q}%"
            stmt = stmt.where(
                or_(
                    AuditLog.details.ilike(pattern),
                    AuditLog.reason.ilike(pattern),
                    AuditLog.entity_ref.ilike(pattern),
                    AuditLog.actor_name.ilike(pattern),
                    AuditLog.user.has(User.full_name.ilike(pattern)),
                )
            )
        return stmt


def _count_distinct(db: Session, stmt: Select, column: Any) -> int:
    inner = stmt.with_only_columns(func.count(func.distinct(column))).subquery()
    return db.scalar(select(func.count()).select_from(inner)) or 0


def _enum_value(value: AuditAction | AuditModule | AuditOutcome | str | None) -> str | None:
    if value is None:
        return None
    if hasattr(value, "value"):
        return str(value.value)
    return str(value)


def capture_request_audit_context(request: Request | None) -> dict[str, Any]:
    """Extract actor/device/ip/request-id context from a FastAPI request."""
    if request is None:
        return {}
    context: dict[str, Any] = {}

    client = getattr(request, "client", None)
    if client is not None and getattr(client, "host", None):
        context["ip_address"] = client.host

    request_id = getattr(request.state, "request_id", None)
    if request_id:
        context["request_id"] = str(request_id)

    state_device_id = getattr(request.state, "device_id", None)
    if state_device_id:
        context["device_id"] = state_device_id
        context["device_verified"] = bool(
            getattr(request.state, "device_verified", False)
        )
        device_name = getattr(request.state, "device_name", None)
        if device_name:
            context["device_name"] = device_name
    else:
        # Guard never validated this peer (LAN off / loopback / allowlist)
        # but the client still claimed an identity — keep the claim,
        # clearly unverified, with NO display name.
        headers = getattr(request, "headers", None)
        header_device_id = headers.get(DEVICE_ID_HEADER) if headers else None
        if header_device_id:
            context["device_id"] = header_device_id
            context["device_verified"] = False

    user = getattr(request.state, "user", None)
    if user is not None:
        context["user_id"] = getattr(user, "id", None)
        context["actor_name"] = getattr(user, "full_name", None)
    else:
        user_id = getattr(request.state, "user_id", None)
        if user_id:
            context["user_id"] = _as_uuid_or_none(user_id)

    session_id = getattr(request.state, "session_id", None)
    if session_id:
        context["session_id"] = session_id

    return context


def _as_uuid_or_none(value: Any) -> uuid.UUID | None:
    if value is None:
        return None
    if isinstance(value, uuid.UUID):
        return value
    try:
        return uuid.UUID(str(value))
    except (TypeError, ValueError, AttributeError):
        return None


def _as_uuid_str(value: Any) -> str | None:
    """Opaque id → fixed-length string (session/request ids)."""
    if value is None:
        return None
    return str(value)[:64]
