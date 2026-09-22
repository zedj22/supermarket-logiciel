"""Regression tests — public login user discovery endpoint.

Phase 4 bug fix: the Flutter login screen previously loaded users from the
admin-protected GET /api/v1/users before any JWT existed, producing 401s and
a misleading "connection error". This suite locks in the corrected contract:

- GET /api/v1/auth/login-users works WITHOUT any JWT / admin permission
- login-users returns only active users
- login-users exposes only safe fields (never pin/security data)
- GET /api/v1/users still requires authentication
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.security import hash_pin
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.user import User
from app.services.auth import AuthService

SENSITIVE_SUBSTRINGS = (
    "pin_hash",
    "failed_login_attempts",
    "locked_until",
    "last_login_at",
    "last_logout_at",
    "created_at",
    "updated_at",
    "token_hash",
    "auth_sessions",
    "audit",
)


@pytest.fixture()
def client():
    """TestClient with a shared in-memory DB pre-seeded with active users."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    TestingSession = sessionmaker(bind=engine, autoflush=False)

    # Seed: roles/permissions, an active admin, an active cashier, an inactive user
    db = TestingSession()
    try:
        from app.core.seed import seed_roles_and_permissions

        seed_roles_and_permissions(db)
        service = AuthService(db)
        service.setup_first_admin(name="Admin", pin="1234", pin_confirm="1234")
        service.create_user(name="Cashier Ali", pin="5678", role_names=["cashier"])
        db.add(
            User(
                full_name="Disabled User",
                pin_hash=hash_pin("1234"),
                is_active=False,
            )
        )
        db.commit()
    finally:
        db.close()

    def override_get_db():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as c:
            yield c
    finally:
        app.dependency_overrides.clear()


def _item_roles(raw_items: list[dict], full_name: str) -> list[str]:
    for item in raw_items:
        if item["full_name"] == full_name:
            return [role["name"] for role in item.get("roles", [])]
    return []


# ---------------------------------------------------------------------------
# Public discovery contract
# ---------------------------------------------------------------------------


def test_login_users_works_without_jwt(client):
    """The endpoint must be reachable with NO Authorization header."""
    response = client.get("/api/v1/auth/login-users")
    assert response.status_code == 200
    body = response.json()
    assert "items" in body
    assert body["total"] >= 2


def test_login_users_with_bogus_jwt_still_works(client):
    """Even a garbage token on a public endpoint must not block discovery."""
    response = client.get(
        "/api/v1/auth/login-users",
        headers={"Authorization": "Bearer not.a.real.token"},
    )
    assert response.status_code == 200


def test_login_users_returns_only_active_users(client):
    response = client.get("/api/v1/auth/login-users")
    assert response.status_code == 200
    names = {item["full_name"] for item in response.json()["items"]}
    assert "Admin" in names
    assert "Cashier Ali" in names
    assert "Disabled User" not in names


def test_login_users_includes_role_names(client):
    response = client.get("/api/v1/auth/login-users")
    assert response.status_code == 200
    items = response.json()["items"]
    assert "admin" in _item_roles(items, "Admin")
    assert "cashier" in _item_roles(items, "Cashier Ali")


def test_login_users_does_not_expose_sensitive_fields(client):
    response = client.get("/api/v1/auth/login-users")
    assert response.status_code == 200
    body = response.json()
    for item in body["items"]:
        # Exactly the minimum safe keys — nothing else
        assert set(item.keys()) == {"id", "full_name", "is_active", "roles"}
    response_text = str(body).lower()
    for token in SENSITIVE_SUBSTRINGS:
        assert token not in response_text, f"leaked sensitive field: {token}"


# ---------------------------------------------------------------------------
# Admin user management stays protected
# ---------------------------------------------------------------------------


def test_users_list_requires_authentication(client):
    response = client.get("/api/v1/users")
    assert response.status_code == 401
    assert "error" in response.json()


def test_users_list_rejects_invalid_token(client):
    response = client.get(
        "/api/v1/users",
        headers={"Authorization": "Bearer invalid.token.value"},
    )
    assert response.status_code == 401


def test_login_users_endpoint_does_not_include_admin_permission_scope(client):
    """The public endpoint must not depend on user_manage permission."""
    response = client.get("/api/v1/auth/login-users")
    assert response.status_code == 200
    body = response.json()
    serialized = str(body)
    assert "user_manage" not in serialized


# ---------------------------------------------------------------------------
# Login response carries permission scopes (nested under roles)
# ---------------------------------------------------------------------------


def test_login_response_user_roles_include_permission_scopes(client):
    """Login user payload has NO top-level permissions; scopes nest under roles.

    The Flutter shell gates the Users navigation on user_manage. That scope
    must be present in the login response (roles[].permissions[].scope) so
    the client can authorize UI without an extra /auth/me round-trip.
    """
    response = client.post(
        "/api/v1/auth/login",
        json={"user_id": _user_id(client, "Admin"), "pin": "1234"},
    )
    assert response.status_code == 200
    user = response.json()["user"]
    # UserResponse contract: no top-level permissions field
    assert "permissions" not in user
    role = next(r for r in user["roles"] if r["name"] == "admin")
    scopes = {p["scope"] for p in role.get("permissions", [])}
    assert "user_manage" in scopes


def _user_id(client: TestClient, full_name: str) -> str:
    items = client.get("/api/v1/auth/login-users").json()["items"]
    return next(i["id"] for i in items if i["full_name"] == full_name)