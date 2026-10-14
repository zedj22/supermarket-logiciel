"""Audit trail slice A — AuditService unit tests.

Covers:
- redaction: PIN / password / token / secret / hash keys never persist
- build_diff: allowlist-scoped, only changed fields, redacted values
- record(): column defaults (outcome success, module passthrough), in-
  transaction semantics (rollback removes the row, no orphan success)
- capture_request_audit_context: validated vs unverified device claims
"""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.exceptions import AppError
from app.db.base import Base
from app.models.audit import AuditLog
from app.models.enums import AuditAction, AuditModule, AuditOutcome
from app.services.audit import (
    REDACTED,
    AuditService,
    build_diff,
    is_sensitive_key,
    redact,
)
from app.services.base import BaseService


@pytest.fixture()
def engine():
    eng = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=eng)
    yield eng
    eng.dispose()


@pytest.fixture()
def db(engine):
    session = sessionmaker(bind=engine, autoflush=False)()
    yield session
    session.rollback()
    session.close()


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "key",
    ["pin", "PIN", "password", "token", "secret", "api_key", "pin_hash",
     "token_hash", "access_token", "user_password", "x_secret_y"],
)
def test_sensitive_keys_are_detected(key):
    assert is_sensitive_key(key)


@pytest.mark.parametrize("key", ["name", "reason", "quantity", "hashrate_note", "thing"])
def test_non_sensitive_keys_pass(key):
    assert not is_sensitive_key(key)


def test_redact_masks_secret_values_only():
    payload = {
        "pin": "1234",
        "full_name": "Admin",
        "nested": {"password": "hunter2", "ok": 1},
        "items": [{"token": "abc"}, "plain"],
    }
    cleaned = redact(payload)
    assert cleaned["pin"] == REDACTED
    assert cleaned["full_name"] == "Admin"
    assert cleaned["nested"]["password"] == REDACTED
    assert cleaned["nested"]["ok"] == 1
    assert cleaned["items"][0]["token"] == REDACTED
    assert cleaned["items"][1] == "plain"
    # Original untouched.
    assert payload["pin"] == "1234"


# ---------------------------------------------------------------------------
# Diff builder
# ---------------------------------------------------------------------------


def test_build_diff_allowlist_and_changes_only():
    before = {"name": "A", "price": "1.000", "cost": "9.999", "pin": "1111"}
    after = {"name": "B", "price": "1.000", "cost": "8.000", "pin": "2222"}
    diff = build_diff(before, after, fields=["name", "price"])
    assert diff == {"name": {"before": "A", "after": "B"}}
    # price unchanged → omitted; cost/pin outside allowlist → never compared.
    assert "cost" not in diff and "pin" not in diff


def test_build_diff_redacts_sensitive_values():
    # Both sides redact to the same placeholder, so a secret "change" is
    # never observable in a diff — the values cannot leak, and the field
    # simply shows as unchanged.
    diff = build_diff({"pin": "1111"}, {"pin": "2222"})
    assert diff == {}
    assert build_diff({"pin": "1111", "name": "A"}, {"pin": "9999", "name": "B"}) == {
        "name": {"before": "A", "after": "B"}
    }


def test_build_diff_no_allowlist_compares_union():
    diff = build_diff({"a": 1}, {"a": 2, "b": 3})
    assert diff == {"a": {"before": 1, "after": 2}, "b": {"before": None, "after": 3}}


# ---------------------------------------------------------------------------
# record() semantics
# ---------------------------------------------------------------------------


def test_record_defaults_to_success_with_module(db):
    service = AuditService(db)
    service.record(action=AuditAction.UPDATE, module=AuditModule.SETTINGS,
                   entity_type="settings", details={"fields": ["store_name"]})
    db.commit()
    row = db.scalar(select(AuditLog))
    assert row.outcome == AuditOutcome.SUCCESS.value
    assert row.module == "settings"
    # recorded_at is exposed by the read API from created_at (no duplicate
    # column — TimestampMixin already is the recording time).
    assert row.created_at is not None


def test_record_redacts_snapshots_and_metadata(db):
    AuditService(db).record(
        action=AuditAction.UPDATE,
        module=AuditModule.SETTINGS,
        before={"store_name": "X", "pin_hash": "deadbeef"},
        after={"store_name": "Y", "pin_hash": "cafebabe"},
        metadata={"token": "jwt-goes-here"},
    )
    db.commit()
    row = db.scalar(select(AuditLog))
    assert "deadbeef" not in row.before_state
    assert REDACTED in row.before_state
    assert "jwt-goes-here" not in row.metadata_json


def test_rolled_back_transaction_leaves_no_audit_row(db):
    class _FailingService(BaseService):
        def run(self):
            with self.transaction():
                AuditService(self.db).record(
                    action=AuditAction.UPDATE,
                    module=AuditModule.SETTINGS,
                    details="about to fail",
                )
                raise AppError(message="business rule exploded")

    with pytest.raises(AppError):
        _FailingService(db).run()
    db.rollback()
    assert db.scalar(select(func.count()).select_from(AuditLog)) == 0


def test_committed_transaction_keeps_audit_row(db):
    class _OkService(BaseService):
        def run(self):
            with self.transaction():
                AuditService(self.db).record(
                    action=AuditAction.UPDATE,
                    module=AuditModule.SETTINGS,
                    details="committed",
                )

    _OkService(db).run()
    assert db.scalar(select(func.count()).select_from(AuditLog)) == 1


# ---------------------------------------------------------------------------
# Request-context capture
# ---------------------------------------------------------------------------


class _FakeState:
    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)


class _FakeClient:
    def __init__(self, host):
        self.host = host


class _FakeHeaders(dict):
    def get(self, key, default=None):
        return dict.get(self, key, default)


class _FakeRequest:
    def __init__(self, *, state=None, headers=None, host="10.0.0.5"):
        self.state = state or _FakeState()
        self.headers = _FakeHeaders(headers or {})
        self.client = _FakeClient(host) if host else None


def test_capture_unverified_header_claim():
    from app.services.audit import capture_request_audit_context

    ctx = capture_request_audit_context(
        _FakeRequest(headers={"X-Device-ID": "pos-front-desk"})
    )
    assert ctx["device_id"] == "pos-front-desk"
    assert ctx["device_verified"] is False
    assert "device_name" not in ctx  # never fabricate a display name


def test_capture_validated_device_wins():
    from app.services.audit import capture_request_audit_context

    ctx = capture_request_audit_context(
        _FakeRequest(
            state=_FakeState(
                device_id="pos-abc",
                device_name="Front PC",
                device_verified=True,
            )
        )
    )
    assert ctx["device_id"] == "pos-abc"
    assert ctx["device_name"] == "Front PC"
    assert ctx["device_verified"] is True


def test_capture_actor_and_request_id():
    from app.services.audit import capture_request_audit_context

    user = type("U", (), {"id": uuid.uuid4(), "full_name": "Admin"})()
    ctx = capture_request_audit_context(
        _FakeRequest(
            state=_FakeState(user=user, request_id="req-1", session_id="sess-1"),
        )
    )
    assert ctx["actor_name"] == "Admin"
    assert ctx["user_id"] == user.id
    assert ctx["request_id"] == "req-1"
    assert ctx["session_id"] == "sess-1"
    assert ctx["ip_address"] == "10.0.0.5"
