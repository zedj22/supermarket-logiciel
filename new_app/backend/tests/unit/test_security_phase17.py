"""Phase 17 §17.7 — security audit fixes.

Locks in every defect the audit located and this pass fixed:

1. ``POST /auth/verify`` read a *query* parameter (422 without one) and
   answered ``valid: false`` unconditionally.
2. ``POST /auth/logout`` returned success without revoking anything (D-13).
3. ``POST /auth/verify-token`` swallowed every exception as ``valid: false``.
4. ``AuthService.is_setup_needed()`` counted all users while
   ``setup_first_admin`` only guards on an admin-role user.
5. SQL ``echo`` printed ``pin_hash`` / ``token_hash`` bound parameters.
6. Repository placeholder secrets booted production silently.
7. Silent ``except OSError`` paths (server identity, pg tool discovery,
   discovery socket close).
8. A ``db.commit()`` on EVERY authenticated request (last_seen heartbeat).
9. No app-wide rate limiting (roadmap Phase 3 / D-08).
"""

from __future__ import annotations

import logging
import pathlib
import time as time_module
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.api import dependencies as api_dependencies
from app.core import db_dump, rate_limit
from app.core.config import PLACEHOLDER_SECRETS, Settings, settings
from app.core.security import hash_token
from app.core.server_identity import _read_file, _write_file
from app.db.base import Base
from app.db.engine import create_db_engine
from app.db.session import get_db
from app.main import app
from app.models.user import AuthSession, User
from app.services.auth import AuthService

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


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
def TestingSession(engine):
    return sessionmaker(bind=engine, autoflush=False)


@pytest.fixture()
def db(engine, TestingSession):
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    service = AuthService(session)
    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    service.create_user(name="Manager Mo", pin="2222", role_names=["manager"])
    yield session
    session.close()


@pytest.fixture()
def bare_db(engine, TestingSession):
    """Seeded roles/permissions but NO user at all (first-run state)."""
    session = TestingSession()
    from app.core.seed import seed_roles_and_permissions

    seed_roles_and_permissions(session)
    yield session
    session.close()


def _make_client(TestingSession):
    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture()
def client(engine, TestingSession, db):
    """TestClient whose server-side faults come back as 500 responses.

    ``raise_server_exceptions=False`` lets §17.7 assert that an unexpected
    fault *surfaces* (500) instead of being swallowed as a normal answer.
    """
    with _make_client(TestingSession) as c:
        yield c
    app.dependency_overrides.clear()


@pytest.fixture()
def bare_client(engine, TestingSession, bare_db):
    """TestClient over a first-run database (no users yet)."""
    with _make_client(TestingSession) as c:
        yield c
    app.dependency_overrides.clear()


def _login(client: TestClient, full_name: str, pin: str) -> dict:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    user_id = next(i["id"] for i in items if i["full_name"] == full_name)
    resp = client.post("/api/v1/auth/login", json={"user_id": user_id, "pin": pin})
    assert resp.status_code == 200, resp.text
    return {"Authorization": f"Bearer {resp.json()['access_token']}"}


# ---------------------------------------------------------------------------
# 1. POST /auth/verify — header bearer token, blueprint 200/401 contract
# ---------------------------------------------------------------------------


def test_verify_without_a_token_is_401(client):
    resp = client.post("/api/v1/auth/verify")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


def test_verify_ignores_a_query_parameter(client):
    """The old implementation read ``?authorization=`` and 422'd without it."""
    headers = _login(client, "Admin", "1234")
    token = headers["Authorization"].split(" ", 1)[1]
    resp = client.post(f"/api/v1/auth/verify?authorization={token}")
    assert resp.status_code == 401, resp.text


def test_verify_with_a_bad_token_is_401(client):
    resp = client.post(
        "/api/v1/auth/verify", headers={"Authorization": "Bearer not-a-jwt"}
    )
    assert resp.status_code == 401


def test_verify_with_a_valid_token_returns_the_user(client):
    headers = _login(client, "Admin", "1234")
    resp = client.post("/api/v1/auth/verify", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["valid"] is True
    assert body["user"]["full_name"] == "Admin"
    assert body["session_id"]


# ---------------------------------------------------------------------------
# 2. POST /auth/logout — actually revokes (D-13)
# ---------------------------------------------------------------------------


def test_logout_requires_authentication(client):
    assert client.post("/api/v1/auth/logout").status_code == 401


def test_logout_revokes_the_session(client, db):
    headers = _login(client, "Admin", "1234")
    token = headers["Authorization"].split(" ", 1)[1]
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200

    resp = client.post("/api/v1/auth/logout", headers=headers)
    assert resp.status_code == 200, resp.text

    db.expire_all()
    row = db.scalar(select(AuthSession).where(AuthSession.token_hash == hash_token(token)))
    assert row is not None, "session row must survive logout"
    assert row.revoked_at is not None, "logout must revoke the session"

    # The revoked token is dead for every verifier.
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401
    assert client.post("/api/v1/auth/verify", headers=headers).status_code == 401
    verify = client.post("/api/v1/auth/verify-token", params={"token": token})
    assert verify.status_code == 200
    assert verify.json()["valid"] is False


# ---------------------------------------------------------------------------
# 3. POST /auth/verify-token — no blanket `except Exception`
# ---------------------------------------------------------------------------


def test_verify_token_still_answers_valid_false_for_a_bad_token(client):
    resp = client.post("/api/v1/auth/verify-token", params={"token": "nope"})
    assert resp.status_code == 200
    assert resp.json() == {"valid": False, "user": None, "session_id": None}


def test_verify_token_does_not_swallow_unexpected_faults(client, monkeypatch):
    def boom(self, token):
        raise RuntimeError("database gone")

    monkeypatch.setattr(AuthService, "verify_token", boom)
    resp = client.post("/api/v1/auth/verify-token", params={"token": "x"})
    assert resp.status_code == 500, resp.text
    assert resp.json()["error"]["code"] == "INTERNAL_ERROR"


def test_verify_token_accepts_the_flutter_json_body(client):
    """The Flutter client posts {"token": …}; it must not be a 422.

    Session restore (auth_provider._initialize) uses the body form, so a
    422 here silently dropped every saved session on app boot.
    """
    headers = _login(client, "Admin", "1234")
    token = headers["Authorization"].split(" ", 1)[1]
    resp = client.post("/api/v1/auth/verify-token", json={"token": token})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["valid"] is True
    assert body["user"]["full_name"] == "Admin"
    assert body["session_id"]


def test_verify_token_body_with_a_bad_token_is_valid_false(client):
    resp = client.post("/api/v1/auth/verify-token", json={"token": "nope"})
    assert resp.status_code == 200
    assert resp.json() == {"valid": False, "user": None, "session_id": None}


def test_verify_token_without_any_token_is_401(client):
    """Neither query nor body = missing credential, like /auth/verify."""
    resp = client.post("/api/v1/auth/verify-token")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "UNAUTHORIZED"


# ---------------------------------------------------------------------------
# 4. is_setup_needed() agrees with setup_first_admin
# ---------------------------------------------------------------------------


def test_setup_stays_open_until_an_admin_exists(bare_db):
    service = AuthService(bare_db)
    assert service.is_setup_needed() is True

    service.create_user(name="Cashier Only", pin="3333", role_names=["cashier"])
    assert service.is_setup_needed() is True, "a non-admin must not close setup"

    service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
    assert service.is_setup_needed() is False


def test_setup_check_endpoint_agrees_with_the_setup_endpoint(bare_client):
    # First run: setup is offered.
    assert bare_client.get("/api/v1/auth/setup/check").json() == {"setup_needed": True}

    created = bare_client.post(
        "/api/v1/auth/setup",
        json={"name": "Admin", "pin": "1234", "pin_confirm": "1234"},
    )
    assert created.status_code == 200, created.text
    assert bare_client.get("/api/v1/auth/setup/check").json() == {"setup_needed": False}

    # The endpoint's guard and the check now agree: setup is closed.
    again = bare_client.post(
        "/api/v1/auth/setup",
        json={"name": "Admin2", "pin": "5678", "pin_confirm": "5678"},
    )
    assert again.status_code == 409


# ---------------------------------------------------------------------------
# 5. SQL echo / statement logging never prints parameters
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("env", ["development", "testing", "production"])
def test_engine_echo_is_disabled_everywhere(monkeypatch, env):
    monkeypatch.setattr(settings, "APP_ENV", env)
    assert create_db_engine("sqlite://").echo is False


def test_development_statement_log_excludes_parameters(monkeypatch):
    monkeypatch.setattr(settings, "APP_ENV", "development")
    seen: list[str] = []
    monkeypatch.setattr("app.db.engine._log_sql_statement", seen.append)

    eng = create_db_engine("sqlite://")
    with eng.connect() as conn:
        conn.execute(text("SELECT :secret AS s"), {"secret": "sup3r-secret"})

    assert seen, "development runs must still show SQL"
    assert any("SELECT" in stmt for stmt in seen)
    assert all("sup3r-secret" not in stmt for stmt in seen)


def test_statement_log_is_off_outside_development(monkeypatch):
    monkeypatch.setattr(settings, "APP_ENV", "testing")
    seen: list[str] = []
    monkeypatch.setattr("app.db.engine._log_sql_statement", seen.append)

    eng = create_db_engine("sqlite://")
    with eng.connect() as conn:
        conn.execute(text("SELECT 1"))

    assert seen == []


# ---------------------------------------------------------------------------
# 6. Placeholder secrets
# ---------------------------------------------------------------------------


def test_production_refuses_the_repository_placeholder_secret():
    with pytest.raises(Exception) as excinfo:
        Settings(
            APP_ENV="production",
            DATABASE_URL="sqlite://",
            APP_SECRET_KEY=PLACEHOLDER_SECRETS["APP_SECRET_KEY"],
            JWT_SECRET_KEY="a-real-jwt-secret-value-at-least-32-chars",
        )
    assert "placeholder" in str(excinfo.value)


def test_production_accepts_configured_secrets():
    cfg = Settings(
        APP_ENV="production",
        DATABASE_URL="sqlite://",
        APP_SECRET_KEY="a-real-app-secret-value-at-least-32-chars",
        JWT_SECRET_KEY="a-real-jwt-secret-value-at-least-32-chars",
    )
    assert cfg.APP_ENV == "production"


def test_development_warns_about_the_placeholder_secret():
    with pytest.warns(UserWarning, match="APP_SECRET_KEY"):
        Settings(
            APP_ENV="development",
            DATABASE_URL="sqlite://",
            APP_SECRET_KEY=PLACEHOLDER_SECRETS["APP_SECRET_KEY"],
            JWT_SECRET_KEY="a-real-jwt-secret-value-at-least-32-chars",
        )


# ---------------------------------------------------------------------------
# 7. Silent OSError paths are logged
# ---------------------------------------------------------------------------


def test_server_id_read_failure_is_logged(tmp_path, monkeypatch, caplog):
    path = tmp_path / "server_id"
    path.write_text("abc", encoding="utf-8")

    def denied(self, *args, **kwargs):
        raise OSError("permission denied")

    monkeypatch.setattr(pathlib.Path, "read_text", denied)
    with caplog.at_level(logging.WARNING):
        assert _read_file(path) is None
    assert "server_id_read_failed" in caplog.text


def test_server_id_write_failure_is_logged(tmp_path, caplog):
    blocker = tmp_path / "blocker.txt"
    blocker.write_text("x", encoding="utf-8")
    path = blocker / "server_id"  # parent is a FILE -> mkdir raises OSError

    with caplog.at_level(logging.WARNING):
        assert _write_file(path, "value") is False
    assert "server_id_write_failed" in caplog.text


def test_discovery_socket_close_failure_is_logged(caplog):
    from app.discovery.responder import DiscoveryResponder

    class _StubSocket:
        def close(self):
            raise OSError("already closed")

    responder = DiscoveryResponder(port=0, host="127.0.0.1")
    responder._sock = _StubSocket()  # simulate a socket that refuses to close
    responder._thread = None

    with caplog.at_level(logging.WARNING):
        responder.stop()
    assert "discovery_socket_close_failed" in caplog.text


def test_pg_tool_glob_failure_is_logged(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr(db_dump, "_PG_TOOL_ROOTS", (tmp_path,))
    monkeypatch.setattr(db_dump.shutil, "which", lambda name: None)

    def denied(self, pattern):
        raise OSError("unreadable install dir")

    monkeypatch.setattr(pathlib.Path, "glob", denied)
    with caplog.at_level(logging.DEBUG):
        assert db_dump.find_pg_tool("pg_dump") is None
    assert "pg_tool_glob_failed" in caplog.text


# ---------------------------------------------------------------------------
# 8. Throttled session heartbeat (no commit on every request)
# ---------------------------------------------------------------------------


class _FailingDB:
    """Stub session whose commit always fails."""

    def __init__(self):
        self.rolled_back = 0

    def commit(self):
        raise RuntimeError("database gone")

    def rollback(self):
        self.rolled_back += 1


def _utc(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def test_heartbeat_skips_a_fresh_session(db):
    user = db.scalar(select(User).where(User.full_name == "Admin"))
    now = datetime.now(timezone.utc)
    row = AuthSession(
        user_id=user.id,
        token_hash="hash",
        expires_at=now + timedelta(hours=1),
        last_seen_at=now,
    )
    db.add(row)
    db.commit()

    fresh = row.last_seen_at
    api_dependencies._touch_session(db, row)
    assert row.last_seen_at == fresh, "a fresh heartbeat must not write"


def test_heartbeat_refreshes_a_stale_session(db):
    user = db.scalar(select(User).where(User.full_name == "Admin"))
    now = datetime.now(timezone.utc)
    stale = now - timedelta(seconds=api_dependencies.SESSION_HEARTBEAT_SECONDS + 30)
    row = AuthSession(
        user_id=user.id,
        token_hash="hash",
        expires_at=now + timedelta(hours=1),
        last_seen_at=stale,
    )
    db.add(row)
    db.commit()

    was = row.last_seen_at
    api_dependencies._touch_session(db, row)
    assert _utc(row.last_seen_at) - _utc(was) > timedelta(seconds=30)


def test_heartbeat_failure_never_fails_the_request(caplog):
    past = datetime.now(timezone.utc) - timedelta(
        seconds=api_dependencies.SESSION_HEARTBEAT_SECONDS + 5
    )
    session_row = type("Row", (), {"last_seen_at": past})()
    failing_db = _FailingDB()

    with caplog.at_level(logging.WARNING):
        api_dependencies._touch_session(failing_db, session_row)  # must not raise

    assert failing_db.rolled_back == 1
    assert "session_heartbeat_failed" in caplog.text


# ---------------------------------------------------------------------------
# 9. App-wide rate limiting (roadmap Phase 3 / D-08)
# ---------------------------------------------------------------------------


def test_rate_limit_defaults_are_sane():
    assert settings.RATE_WINDOW_SECONDS == 60
    assert settings.AUTH_RATE_LIMIT_PER_MINUTE >= 1
    assert settings.API_RATE_LIMIT_PER_MINUTE > settings.AUTH_RATE_LIMIT_PER_MINUTE


def test_sliding_window_allows_up_to_the_limit_only():
    limiter = rate_limit.SlidingWindowLimiter(3, 60)
    assert [limiter.allow("ip") for _ in range(3)] == [True, True, True]
    assert limiter.allow("ip") is False
    assert limiter.allow("another-ip") is True


def test_retry_after_counts_down_and_clear_resets(monkeypatch):
    limiter = rate_limit.SlidingWindowLimiter(1, 60)
    assert limiter.allow("ip") is True
    assert limiter.allow("ip") is False
    assert 1 <= limiter.retry_after("ip") <= 60

    # Age the hit so only a moment of the window is left.
    limiter._hits["ip"][0] = time_module.monotonic() - 59
    assert limiter.retry_after("ip") <= 2

    limiter.clear()
    assert limiter.allow("ip") is True
    assert limiter.retry_after("unknown-key") == limiter.window_seconds


def test_api_backstop_returns_the_standard_429_envelope(client, monkeypatch):
    monkeypatch.setattr(rate_limit.api_limiter, "limit", 2)

    assert client.get("/api/v1/health/live").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 200

    resp = client.get("/api/v1/health/live")
    assert resp.status_code == 429
    error = resp.json()["error"]
    assert error["code"] == "RATE_LIMITED"
    assert error["message_key"] == "errors.rateLimited"
    assert error["details"]["retry_seconds"] >= 1
    assert error["details"]["scope"] == "api"
    assert error["request_id"]


def test_clearing_the_window_lifts_the_limit(client, monkeypatch):
    monkeypatch.setattr(rate_limit.api_limiter, "limit", 1)

    assert client.get("/api/v1/health/live").status_code == 200
    assert client.get("/api/v1/health/live").status_code == 429

    rate_limit.reset_rate_limiters()
    assert client.get("/api/v1/health/live").status_code == 200


def test_login_attempts_are_rate_limited_per_client_ip(client, monkeypatch):
    monkeypatch.setattr(rate_limit.auth_limiter, "limit", 2)
    body = {"user_id": str(uuid.uuid4()), "pin": "1234"}

    assert client.post("/api/v1/auth/login", json=body).status_code == 401
    assert client.post("/api/v1/auth/login", json=body).status_code == 401

    resp = client.post("/api/v1/auth/login", json=body)
    assert resp.status_code == 429
    error = resp.json()["error"]
    assert error["code"] == "RATE_LIMITED"
    assert error["details"]["scope"] == "login"


def test_first_admin_setup_is_rate_limited(client, monkeypatch):
    monkeypatch.setattr(rate_limit.auth_limiter, "limit", 2)
    body = {"name": "Admin", "pin": "1234", "pin_confirm": "1234"}

    assert client.post("/api/v1/auth/setup", json=body).status_code == 409
    assert client.post("/api/v1/auth/setup", json=body).status_code == 409
    assert client.post("/api/v1/auth/setup", json=body).status_code == 429
