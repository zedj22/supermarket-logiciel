"""Authorization dependencies for FastAPI.

Provides reusable dependencies for:
- Extracting and verifying the current user from JWT
- Checking permission scopes
- Requiring specific permissions

Usage in routers:
    from app.api.dependencies import get_current_user, require_permission
    from app.models.enums import PermissionScope

    @router.get("/users")
    async def list_users(user = Depends(require_permission(PermissionScope.USER_MANAGE))):
        ...
"""

from __future__ import annotations

from typing import Annotated

import structlog
from fastapi import Depends, Header, Request
from sqlalchemy.orm import Session

from app.core.exceptions import AuthenticationError, ForbiddenError, UnauthorizedError
from app.core.security import decode_access_token, hash_token
from app.models.enums import PermissionScope
from app.models.user import AuthSession, User

logger = structlog.get_logger(__name__)


def _get_token_from_header(authorization: str | None = Header(None)) -> str | None:
    """Extract Bearer token from Authorization header."""
    if not authorization:
        return None
    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    return None


def get_current_user(
    request: Request,
    token: str | None = Depends(_get_token_from_header),
    db: Session = Depends(lambda: None),  # Overridden by router
) -> User:
    """Extract and verify the current user from JWT.

    This dependency:
    1. Extracts the Bearer token from the Authorization header
    2. Decodes and verifies the JWT
    3. Validates the session exists and is not revoked
    4. Returns the User object

    Raises UnauthorizedError if authentication fails.
    """
    if not token:
        raise UnauthorizedError(message="Missing authentication token")

    # We need the DB session — get it from the request state or override
    from app.db.session import get_db as _get_db
    from app.db.engine import _factory

    SessionLocal = _factory.session_factory
    db = SessionLocal()

    try:
        payload = decode_access_token(token)
        if payload is None:
            raise UnauthorizedError(message="Invalid or expired token")

        user_id = payload.get("sub")
        session_id = payload.get("sid")

        if not user_id or not session_id:
            raise UnauthorizedError(message="Invalid token claims")

        import uuid
        session = db.get(AuthSession, uuid.UUID(session_id))
        if session is None or session.revoked_at is not None:
            raise UnauthorizedError(message="Session revoked or not found")

        if session.is_expired:
            raise UnauthorizedError(message="Session expired")

        if session.token_hash != hash_token(token):
            raise UnauthorizedError(message="Invalid token")

        user = db.get(User, uuid.UUID(user_id))
        if user is None or not user.is_active:
            raise UnauthorizedError(message="User not found or inactive")

        # Update last_seen_at
        from datetime import datetime, timezone
        session.last_seen_at = datetime.now(timezone.utc)
        db.commit()

        # Store user on request state for other dependencies
        request.state.user = user
        request.state.user_id = str(user.id)
        request.state.session_id = str(session.id)

        return user
    except Exception:
        db.close()
        raise


CurrentUser = Annotated[User, Depends(get_current_user)]


def require_permission(scope: PermissionScope):
    """Factory dependency that requires a specific permission scope.

    Usage:
        @router.get("/users")
        async def list_users(user = Depends(require_permission(PermissionScope.USER_MANAGE))):
            ...
    """

    def _check(user: User = Depends(get_current_user)) -> User:
        if not user.has_permission(scope):
            logger.warning(
                "permission_denied",
                user_id=str(user.id),
                required_scope=scope.value,
            )
            raise ForbiddenError(
                message=f"Permission denied: {scope.value}",
                details={"required_permission": scope.value},
            )
        return user

    return _check


def require_any_permission(*scopes: PermissionScope):
    """Factory dependency that requires any one of the given permission scopes."""

    def _check(user: User = Depends(get_current_user)) -> User:
        for scope in scopes:
            if user.has_permission(scope):
                return user
        required = [s.value for s in scopes]
        raise ForbiddenError(
            message=f"Permission denied: one of {required} required",
            details={"required_permissions": required},
        )

    return _check
