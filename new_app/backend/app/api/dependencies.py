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

from datetime import datetime, timezone
from typing import Annotated

import structlog
from fastapi import Depends, Header, Request
from sqlalchemy.orm import Session

from app.core.exceptions import AuthenticationError, ForbiddenError, UnauthorizedError
from app.core.security import decode_access_token, hash_token
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import AuthSession, User

logger = structlog.get_logger(__name__)

#: Minimum gap between two liveness writes for the same session (§17.7).
SESSION_HEARTBEAT_SECONDS = 60


def _touch_session(db: Session, session: AuthSession) -> None:
    """Refresh ``last_seen_at`` at most once per SESSION_HEARTBEAT_SECONDS.

    A liveness write must never turn an otherwise valid request into an
    error, so a failed commit rolls back and is logged instead of raised.
    """
    now = datetime.now(timezone.utc)
    last_seen = session.last_seen_at
    if last_seen is not None and last_seen.tzinfo is None:
        # SQLite returns naive values for DateTime(timezone=True); they are UTC.
        last_seen = last_seen.replace(tzinfo=timezone.utc)
    if last_seen is not None and (now - last_seen).total_seconds() < SESSION_HEARTBEAT_SECONDS:
        return
    session.last_seen_at = now
    try:
        db.commit()
    except Exception as exc:  # pragma: no cover - liveness must not fail the request
        db.rollback()
        logger.warning("session_heartbeat_failed", error=str(exc))


def get_bearer_token(authorization: str | None = Header(None)) -> str | None:
    """Extract Bearer token from Authorization header."""
    if not authorization:
        return None
    parts = authorization.split(" ", 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    return None


def get_current_user(
    request: Request,
    token: str | None = Depends(get_bearer_token),
    db: Session = Depends(get_db),
) -> User:
    """Extract and verify the current user from JWT.

    This dependency:
    1. Extracts the Bearer token from the Authorization header
    2. Decodes and verifies the JWT
    3. Validates the session exists and is not revoked
    4. Returns the User object

    Uses the request-scoped session from `get_db` so FastAPI dependency
    overrides (used by tests) apply to authentication as well.

    Raises UnauthorizedError if authentication fails.
    """
    if not token:
        raise UnauthorizedError(message="Missing authentication token")

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

    # Liveness heartbeat. Throttled (§17.7): committing on EVERY authenticated
    # request meant two transactions and one write per read-only GET, and a
    # transient DB fault in this write could 500 a perfectly valid request.
    _touch_session(db, session)

    # Store user on request state for other dependencies
    request.state.user = user
    request.state.user_id = str(user.id)
    request.state.session_id = str(session.id)

    return user


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
