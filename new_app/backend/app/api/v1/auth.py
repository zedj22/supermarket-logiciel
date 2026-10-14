"""Authentication API endpoints.

Endpoints:
- POST /api/v1/auth/setup — First-admin setup
- GET  /api/v1/auth/setup/check — Setup-needed check
- GET  /api/v1/auth/login-users — Public active-user list for the login screen
- POST /api/v1/auth/login — PIN-based login
- POST /api/v1/auth/verify — Token verification (header bearer, blueprint contract)
- POST /api/v1/auth/verify-token — Token verification (explicit token string)
- POST /api/v1/auth/logout — Session revocation for the request's bearer token
- POST /api/v1/auth/logout-token — Session revocation for an explicit token string
- POST /api/v1/auth/reauth — PIN reverification
- GET  /api/v1/auth/me — Current user info
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from app.api.dependencies import CurrentUser, get_bearer_token, get_current_user, require_permission
from app.core.config import settings
from app.core.exceptions import AppError, AuthenticationError, BusinessRuleError, UnauthorizedError
from app.core.rate_limit import auth_limiter, enforce_rate_limit
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
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
    payload: SetupRequest,
    request: Request,
    service: AuthService = Depends(_get_auth_service),
) -> SetupResponse:
    """Create the first admin account.

    Only works when no admin exists yet. The window cannot be closed
    without completing setup (client-side enforcement).
    """
    enforce_rate_limit(request, auth_limiter, scope="setup")
    user = service.setup_first_admin(
        name=payload.name,
        pin=payload.pin,
        pin_confirm=payload.pin_confirm,
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
    payload: LoginRequest,
    request: Request,
    service: AuthService = Depends(_get_auth_service),
) -> LoginResponse:
    """Authenticate with user selection + PIN.

    Rate limited per client IP (§17.7) on top of the per-account lockout.
    """
    enforce_rate_limit(request, auth_limiter, scope="login")
    token, user = service.login(
        user_id=payload.user_id,
        pin=payload.pin,
        device_name=payload.device_name,
        ip_address=request.client.host if request.client else None,
        request_id=getattr(request.state, "request_id", None),
        device_id=getattr(request.state, "device_id", None),
        device_verified=getattr(request.state, "device_verified", None),
    )
    return LoginResponse(
        access_token=token,
        expires_in=settings.SESSION_LIFETIME_MINUTES * 60,
        user=UserResponse.model_validate(user),
    )


@router.post("/verify", response_model=VerifyResponse, tags=["auth"])
def verify_current_token(
    token: str | None = Depends(get_bearer_token),
    service: AuthService = Depends(_get_auth_service),
) -> VerifyResponse:
    """Verify the bearer token presented with this request.

    Blueprint contract for ``POST /api/v1/auth/verify``: 200 with the
    resolved user/session when the token is good, 401 when it is missing,
    malformed, expired or revoked. The token-string variant
    ``/verify-token`` keeps its ``valid: false`` answer for the client.
    """
    if not token:
        raise UnauthorizedError(message="Missing authentication token")
    user, session = service.verify_token(token)
    return VerifyResponse(
        valid=True,
        user=UserResponse.model_validate(user),
        session_id=session.id,
    )


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
    except AppError:
        # Only authentication-domain failures are an ordinary "not valid"
        # answer. Anything else (DB down, bug) must surface — §17.7 removed
        # the blanket `except Exception` that hid it.
        return VerifyResponse(valid=False)


@router.post("/logout", tags=["auth"])
def logout(
    request: Request,
    token: str | None = Depends(get_bearer_token),
    user: User = Depends(get_current_user),
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Revoke the session carried by this request's bearer token.

    ``get_current_user`` already rejected a missing/invalid token, so the
    token reaching this point is a live session that must be revoked.
    """
    if token:
        service.logout(
            token,
            ip_address=request.client.host if request.client else None,
            request_id=getattr(request.state, "request_id", None),
        )
    return {"message": "Logged out successfully"}


@router.post("/logout-token", tags=["auth"])
def logout_with_token(
    token: str,
    request: Request,
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Revoke a specific session by token."""
    service.logout(
        token,
        ip_address=request.client.host if request.client else None,
        request_id=getattr(request.state, "request_id", None),
    )
    return {"message": "Logged out successfully"}


@router.post("/reauth", response_model=ReauthResponse, tags=["auth"])
def reauth(
    payload: ReauthRequest,
    request: Request,
    user: User = Depends(get_current_user),
    service: AuthService = Depends(_get_auth_service),
) -> ReauthResponse:
    """Re-verify PIN for sensitive actions.

    Rate limited per client IP **and** user (§17.7), so one session cannot
    spray PINs any more than an anonymous caller can.
    """
    enforce_rate_limit(
        request,
        auth_limiter,
        key=f"{request.client.host if request.client else 'unknown'}:{user.id}",
        scope="reauth",
    )
    service.reauth(user_id=user.id, pin=payload.pin)
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
