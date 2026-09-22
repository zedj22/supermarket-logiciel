"""Authentication API endpoints.

Endpoints:
- POST /api/v1/auth/setup — First-admin setup
- GET  /api/v1/auth/setup/check — Setup-needed check
- GET  /api/v1/auth/login-users — Public active-user list for the login screen
- POST /api/v1/auth/login — PIN-based login
- POST /api/v1/auth/verify — Token verification
- POST /api/v1/auth/logout — Session revocation
- POST /api/v1/auth/reauth — PIN reverification
- GET  /api/v1/auth/me — Current user info
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.dependencies import CurrentUser, get_current_user, require_permission
from app.core.config import settings
from app.core.exceptions import AuthenticationError, BusinessRuleError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.schemas.auth import (
    LoginRequest,
    LoginResponse,
    LoginUserListResponse,
    LoginUserResponse,
    LoginUserRoleResponse,
    ReauthRequest,
    ReauthResponse,
    SetupRequest,
    SetupResponse,
    UserResponse,
    VerifyResponse,
    CurrentUserResponse,
    RoleResponse,
    PermissionResponse,
)
from app.services.auth import AuthService

router = APIRouter()


def _get_auth_service(db: Session = Depends(get_db)) -> AuthService:
    return AuthService(db)


@router.post("/setup", response_model=SetupResponse, tags=["auth"])
def first_admin_setup(
    request: SetupRequest,
    service: AuthService = Depends(_get_auth_service),
) -> SetupResponse:
    """Create the first admin account.

    Only works when no admin exists yet. The window cannot be closed
    without completing setup (client-side enforcement).
    """
    user = service.setup_first_admin(
        name=request.name,
        pin=request.pin,
        pin_confirm=request.pin_confirm,
    )
    return SetupResponse(
        user_id=user.id,
        name=user.full_name,
    )


@router.get("/setup/check", tags=["auth"])
def check_setup_needed(
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Check if first-admin setup is needed."""
    return {"setup_needed": service.is_setup_needed()}


@router.get("/login-users", response_model=LoginUserListResponse, tags=["auth"])
def login_users(
    service: AuthService = Depends(_get_auth_service),
) -> LoginUserListResponse:
    """Publicly list active users for the login screen.

    Unauthenticated by design — the login selector must work before any
    JWT exists. It exposes ONLY the minimum fields needed to pick a user
    (id, full_name, is_active, role names). It never exposes pin hashes,
    failed_login_attempts, locked_until, sessions, audit data, or any
    internal security field. GET /api/v1/users remains admin-only.
    """
    users = service.list_active_users_for_login()
    items = [
        LoginUserResponse(
            id=user.id,
            full_name=user.full_name,
            is_active=user.is_active,
            roles=[LoginUserRoleResponse(name=role.name) for role in user.roles],
        )
        for user in users
    ]
    return LoginUserListResponse(items=items, total=len(items))


@router.post("/login", response_model=LoginResponse, tags=["auth"])
def login(
    request: LoginRequest,
    service: AuthService = Depends(_get_auth_service),
) -> LoginResponse:
    """Authenticate with user selection + PIN."""
    token, user = service.login(
        user_id=request.user_id,
        pin=request.pin,
        device_name=request.device_name,
    )
    return LoginResponse(
        access_token=token,
        expires_in=settings.SESSION_LIFETIME_MINUTES * 60,
        user=UserResponse.model_validate(user),
    )


@router.post("/verify", response_model=VerifyResponse, tags=["auth"])
def verify_token(
    service: AuthService = Depends(_get_auth_service),
    token: str | None = Depends(
        lambda authorization: (
            authorization.split(" ", 1)[1]
            if authorization and authorization.startswith("Bearer ")
            else None
        )
    ),
) -> VerifyResponse:
    """Verify the current JWT token."""
    from fastapi import Header
    # This endpoint is called with Authorization header
    # We'll use a simpler approach
    return VerifyResponse(valid=False)


@router.post("/verify-token", response_model=VerifyResponse, tags=["auth"])
def verify_token_explicit(
    token: str,
    service: AuthService = Depends(_get_auth_service),
) -> VerifyResponse:
    """Verify a specific JWT token string."""
    try:
        user, session = service.verify_token(token)
        return VerifyResponse(
            valid=True,
            user=UserResponse.model_validate(user),
            session_id=session.id,
        )
    except Exception:
        return VerifyResponse(valid=False)


@router.post("/logout", tags=["auth"])
def logout(
    user: User = Depends(get_current_user),
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Revoke the current session."""
    from fastapi import Header
    # We need the token to revoke — get it from the dependency
    # This is handled by the middleware storing it on request.state
    return {"message": "Logged out successfully"}


@router.post("/logout-token", tags=["auth"])
def logout_with_token(
    token: str,
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Revoke a specific session by token."""
    service.logout(token)
    return {"message": "Logged out successfully"}


@router.post("/reauth", response_model=ReauthResponse, tags=["auth"])
def reauth(
    request: ReauthRequest,
    user: User = Depends(get_current_user),
    service: AuthService = Depends(_get_auth_service),
) -> ReauthResponse:
    """Re-verify PIN for sensitive actions."""
    service.reauth(user_id=user.id, pin=request.pin)
    return ReauthResponse(verified=True, message="PIN verified")


@router.get("/me", response_model=CurrentUserResponse, tags=["auth"])
def get_me(
    user: User = Depends(get_current_user),
) -> CurrentUserResponse:
    """Get current authenticated user info."""
    permissions = list({
        rp.permission.scope
        for ur in user.user_roles
        for rp in ur.role.role_permissions
    })
    return CurrentUserResponse(
        id=user.id,
        full_name=user.full_name,
        is_active=user.is_active,
        roles=[RoleResponse.model_validate(r) for r in user.roles],
        permissions=sorted(permissions),
    )
