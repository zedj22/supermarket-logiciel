"""Authentication service.

Handles first-admin setup, login, logout, token verification,
reauthentication, user management, and audit logging.

Transaction policy:
- Setup and user operations are transactional.
- Login/logout modify session state atomically.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import structlog
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.constants import PIN_MAX_LENGTH, PIN_MIN_LENGTH
from app.core.exceptions import (
    AuthenticationError,
    AuthorizationError,
    BusinessRuleError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    UnauthorizedError,
)
from app.core.security import (
    create_access_token,
    decode_access_token,
    hash_pin,
    hash_token,
    verify_pin,
)
from app.models.audit import AuditLog
from app.models.enums import AuditAction, PermissionScope
from app.models.user import AuthSession, Role, User, UserRole
from app.services.base import BaseService

logger = structlog.get_logger(__name__)


class AuthService(BaseService):
    """Service for authentication and user management operations."""

    # ── First-admin setup ──────────────────────────────────────────────

    def setup_first_admin(self, name: str, pin: str, pin_confirm: str) -> User:
        """Create the first admin account.

        Rules:
        - Only allowed when no active admin exists.
        - Transactional: user + admin role + audit.
        - PIN must be 4-6 digits.
        - PINs must match.
        """
        # Validate PIN
        if not pin.isdigit() or len(pin) < PIN_MIN_LENGTH or len(pin) > PIN_MAX_LENGTH:
            raise BusinessRuleError(
                message=f"PIN must be {PIN_MIN_LENGTH}-{PIN_MAX_LENGTH} digits",
                details={"min": PIN_MIN_LENGTH, "max": PIN_MAX_LENGTH},
            )

        if pin != pin_confirm:
            raise BusinessRuleError(message="PINs do not match")

        if not name.strip():
            raise BusinessRuleError(message="Name is required")

        # Check if admin already exists (race condition protection)
        existing_admin = self.db.execute(
            select(User).join(UserRole).join(Role).where(Role.name == "admin")
        ).scalar_one_or_none()

        if existing_admin is not None:
            raise ConflictError(
                message="Admin account already exists",
                details={"admin_id": str(existing_admin.id)},
            )

        # Create user with admin role in a transaction
        with self.transaction():
            # Find or create admin role
            admin_role = self.db.execute(
                select(Role).where(Role.name == "admin")
            ).scalar_one_or_none()

            if admin_role is None:
                admin_role = Role(name="admin", description="Full system access")
                self.db.add(admin_role)
                self.db.flush()

            # Create user
            user = User(
                full_name=name.strip(),
                pin_hash=hash_pin(pin),
                is_active=True,
            )
            self.db.add(user)
            self.db.flush()

            # Assign admin role
            user_role = UserRole(user_id=user.id, role_id=admin_role.id)
            self.db.add(user_role)
            self.db.flush()

            # Audit
            self._audit(
                action=AuditAction.CREATE,
                entity_type="user",
                entity_id=user.id,
                details=f"First admin created: {name}",
                user_id=user.id,
            )

        logger.info("first_admin_setup", user_id=str(user.id), name=name)
        return user

    def is_setup_needed(self) -> bool:
        """Check if first-admin setup is needed."""
        count = self.db.scalar(
            select(func.count()).select_from(User)
        ) or 0
        return count == 0

    def list_active_users_for_login(self) -> list[User]:
        """Return active users for the public login user-discovery screen.

        Read-only, no session created. Callers are responsible for serializing
        only the minimum safe fields (id, full_name, is_active, roles).
        """
        return list(
            self.db.scalars(
                select(User)
                .where(User.is_active.is_(True))
                .order_by(User.full_name)
            ).all()
        )

    # ── Login ──────────────────────────────────────────────────────────

    def login(
        self,
        user_id: uuid.UUID,
        pin: str,
        device_name: str | None = None,
    ) -> tuple[str, User]:
        """Authenticate a user with PIN.

        Returns (access_token, user).
        Raises AuthenticationError on failure.
        """
        # Find user
        user = self.db.get(User, user_id)
        if user is None:
            # Use generic error to prevent user enumeration
            raise AuthenticationError(message="Invalid credentials")

        if not user.is_active:
            raise AuthenticationError(
                message="Account is disabled",
                details={"code": "ACCOUNT_DISABLED"},
            )

        # Check lockout
        if user.locked_until and user.locked_until > datetime.now(timezone.utc):
            remaining = (user.locked_until - datetime.now(timezone.utc)).seconds // 60
            raise AuthenticationError(
                message="Account is temporarily locked",
                details={"code": "ACCOUNT_LOCKED", "retry_minutes": remaining},
            )

        # Verify PIN
        if not verify_pin(pin, user.pin_hash):
            self._handle_failed_login(user)
            raise AuthenticationError(message="Invalid credentials")

        # Login successful — reset failed attempts and create session
        with self.transaction():
            user.failed_login_attempts = 0
            user.locked_until = None
            user.last_login_at = datetime.now(timezone.utc)

            # Create session
            now = datetime.now(timezone.utc)
            session = AuthSession(
                user_id=user.id,
                token_hash="",  # Will be set after token creation
                device_name=device_name,
                expires_at=now + timedelta(minutes=settings.SESSION_LIFETIME_MINUTES),
                last_seen_at=now,
            )
            self.db.add(session)
            self.db.flush()

            # Create JWT
            token = create_access_token(
                user_id=user.id,
                session_id=session.id,
                expires_delta=timedelta(minutes=settings.SESSION_LIFETIME_MINUTES),
            )

            # Store token hash in session
            session.token_hash = hash_token(token)

            # Audit
            self._audit(
                action=AuditAction.LOGIN,
                entity_type="session",
                entity_id=session.id,
                details=f"User {user.full_name} logged in",
                user_id=user.id,
            )

        logger.info("login_success", user_id=str(user.id), name=user.full_name)
        return token, user

    def _handle_failed_login(self, user: User) -> None:
        """Increment failed attempts and apply lockout if needed."""
        user.failed_login_attempts += 1
        if user.failed_login_attempts >= settings.LOCKOUT_THRESHOLD:
            user.locked_until = datetime.now(timezone.utc) + timedelta(
                minutes=settings.LOCKOUT_DURATION_MINUTES
            )
            logger.warning(
                "account_locked",
                user_id=str(user.id),
                attempts=user.failed_login_attempts,
            )

        self.db.commit()

        self._audit(
            action=AuditAction.LOGIN,
            entity_type="session",
            entity_id=user.id,
            details=f"Failed login for {user.full_name}",
            user_id=user.id,
        )

    # ── Token verification ─────────────────────────────────────────────

    def verify_token(self, token: str) -> tuple[User, AuthSession]:
        """Verify a JWT token and return (user, session).

        Validates: signature, expiration, session existence, session not revoked, user active.
        """
        payload = decode_access_token(token)
        if payload is None:
            raise UnauthorizedError(message="Invalid or expired token")

        user_id = payload.get("sub")
        session_id = payload.get("sid")

        if not user_id or not session_id:
            raise UnauthorizedError(message="Invalid token claims")

        # Find session
        session = self.db.get(AuthSession, uuid.UUID(session_id))
        if session is None:
            raise UnauthorizedError(message="Session not found")

        if session.revoked_at is not None:
            raise UnauthorizedError(message="Session has been revoked")

        if session.is_expired:
            raise UnauthorizedError(message="Session has expired")

        # Verify token hash
        if session.token_hash != hash_token(token):
            raise UnauthorizedError(message="Invalid token")

        # Find user
        user = self.db.get(User, uuid.UUID(user_id))
        if user is None:
            raise UnauthorizedError(message="User not found")

        if not user.is_active:
            raise UnauthorizedError(message="Account is disabled")

        # Update last_seen_at
        session.last_seen_at = datetime.now(timezone.utc)
        self.db.commit()

        return user, session

    # ── Logout ─────────────────────────────────────────────────────────

    def logout(self, token: str) -> None:
        """Revoke the current session."""
        payload = decode_access_token(token)
        if payload is None:
            return  # Already invalid, nothing to do

        session_id = payload.get("sid")
        if not session_id:
            return

        session = self.db.get(AuthSession, uuid.UUID(session_id))
        if session is None or session.revoked_at is not None:
            return

        with self.transaction():
            session.revoked_at = datetime.now(timezone.utc)

            # Update user last_logout_at
            user = self.db.get(User, session.user_id)
            if user:
                user.last_logout_at = datetime.now(timezone.utc)

            self._audit(
                action=AuditAction.LOGOUT,
                entity_type="session",
                entity_id=session.id,
                details=f"User {user.full_name} logged out" if user else "Session revoked",
                user_id=session.user_id,
            )

        logger.info("logout", session_id=session_id)

    # ── Reauthentication ───────────────────────────────────────────────

    def reauth(self, user_id: uuid.UUID, pin: str) -> bool:
        """Verify a user's PIN for sensitive action reauthentication.

        Returns True if PIN is valid.
        """
        user = self.db.get(User, user_id)
        if user is None or not user.is_active:
            raise AuthenticationError(message="Authentication failed")

        if not verify_pin(pin, user.pin_hash):
            self._audit(
                action=AuditAction.LOGIN,
                entity_type="security",
                entity_id=user.id,
                details="Reauthentication failed",
                user_id=user.id,
            )
            raise AuthenticationError(message="Invalid PIN")

        self._audit(
            action=AuditAction.LOGIN,
            entity_type="security",
            entity_id=user.id,
            details="Reauthentication successful",
            user_id=user.id,
        )
        return True

    # ── User management ────────────────────────────────────────────────

    def create_user(
        self,
        name: str,
        pin: str,
        role_names: list[str] | None = None,
    ) -> User:
        """Create a new user with role assignments."""
        if role_names is None:
            role_names = ["cashier"]

        if not pin.isdigit() or len(pin) < PIN_MIN_LENGTH or len(pin) > PIN_MAX_LENGTH:
            raise BusinessRuleError(
                message=f"PIN must be {PIN_MIN_LENGTH}-{PIN_MAX_LENGTH} digits"
            )

        # Check duplicate name
        existing = self.db.execute(
            select(User).where(func.lower(User.full_name) == name.strip().lower())
        ).scalar_one_or_none()
        if existing:
            raise ConflictError(
                message="A user with this name already exists",
                details={"name": name},
            )

        with self.transaction():
            user = User(
                full_name=name.strip(),
                pin_hash=hash_pin(pin),
                is_active=True,
            )
            self.db.add(user)
            self.db.flush()

            # Assign roles
            for role_name in role_names:
                role = self.db.execute(
                    select(Role).where(Role.name == role_name)
                ).scalar_one_or_none()
                if role is None:
                    raise NotFoundError(
                        message=f"Role not found: {role_name}",
                        details={"role": role_name},
                    )
                self.db.add(UserRole(user_id=user.id, role_id=role.id))

            self.db.flush()

            self._audit(
                action=AuditAction.CREATE,
                entity_type="user",
                entity_id=user.id,
                details=f"User created: {name}, roles: {', '.join(role_names)}",
            )

        return user

    def update_user(
        self,
        user_id: uuid.UUID,
        name: str | None = None,
        is_active: bool | None = None,
        role_names: list[str] | None = None,
    ) -> User:
        """Update user fields."""
        user = self.db.get(User, user_id)
        if user is None:
            raise NotFoundError(message="User not found")

        with self.transaction():
            if name is not None:
                # Check duplicate name
                existing = self.db.execute(
                    select(User).where(
                        func.lower(User.full_name) == name.strip().lower(),
                        User.id != user_id,
                    )
                ).scalar_one_or_none()
                if existing:
                    raise ConflictError(message="A user with this name already exists")
                user.full_name = name.strip()

            if is_active is not None:
                user.is_active = is_active
                # If deactivating, revoke all sessions
                if not is_active:
                    self._revoke_all_sessions(user_id)

            if role_names is not None:
                # Remove existing role assignments
                for ur in list(user.user_roles):
                    self.db.delete(ur)
                # Add new roles
                for role_name in role_names:
                    role = self.db.execute(
                        select(Role).where(Role.name == role_name)
                    ).scalar_one_or_none()
                    if role is None:
                        raise NotFoundError(message=f"Role not found: {role_name}")
                    self.db.add(UserRole(user_id=user.id, role_id=role.id))

            self.db.flush()

            self._audit(
                action=AuditAction.UPDATE,
                entity_type="user",
                entity_id=user.id,
                details=f"User updated: {user.full_name}",
            )

        return user

    def change_pin(
        self,
        user_id: uuid.UUID,
        new_pin: str,
        new_pin_confirm: str,
    ) -> int:
        """Change a user's PIN. Returns number of sessions invalidated."""
        if new_pin != new_pin_confirm:
            raise BusinessRuleError(message="PINs do not match")

        if not new_pin.isdigit() or len(new_pin) < PIN_MIN_LENGTH or len(new_pin) > PIN_MAX_LENGTH:
            raise BusinessRuleError(
                message=f"PIN must be {PIN_MIN_LENGTH}-{PIN_MAX_LENGTH} digits"
            )

        user = self.db.get(User, user_id)
        if user is None:
            raise NotFoundError(message="User not found")

        with self.transaction():
            user.pin_hash = hash_pin(new_pin)
            invalidated = self._revoke_all_sessions(user_id)

            self._audit(
                action=AuditAction.UPDATE,
                entity_type="user",
                entity_id=user.id,
                details=f"PIN changed for {user.full_name}, {invalidated} sessions invalidated",
            )

        return invalidated

    def delete_user(self, user_id: uuid.UUID) -> None:
        """Delete a user. Cannot delete the last active admin."""
        user = self.db.get(User, user_id)
        if user is None:
            raise NotFoundError(message="User not found")

        # Check if this is the last admin
        is_admin = any(ur.role.name == "admin" for ur in user.user_roles)
        if is_admin:
            admin_count = self.db.scalar(
                select(func.count())
                .select_from(User)
                .join(UserRole)
                .join(Role)
                .where(Role.name == "admin", User.is_active == True)
            ) or 0
            if admin_count <= 1:
                raise ForbiddenError(message="Cannot delete the last active admin")

        with self.transaction():
            self._revoke_all_sessions(user_id)

            self._audit(
                action=AuditAction.DELETE,
                entity_type="user",
                entity_id=user.id,
                details=f"User deleted: {user.full_name}",
            )

            self.db.delete(user)

    def _revoke_all_sessions(self, user_id: uuid.UUID) -> int:
        """Revoke all active sessions for a user. Returns count revoked."""
        now = datetime.now(timezone.utc)
        sessions = self.db.scalars(
            select(AuthSession).where(
                AuthSession.user_id == user_id,
                AuthSession.revoked_at.is_(None),
            )
        ).all()
        for s in sessions:
            s.revoked_at = now
        return len(sessions)

    # ── Audit helper ───────────────────────────────────────────────────

    def _audit(
        self,
        action: AuditAction,
        entity_type: str = "",
        entity_id: uuid.UUID | None = None,
        details: str = "",
        user_id: uuid.UUID | None = None,
    ) -> None:
        """Create an audit log entry. Never fails the main operation.

        ``user_id`` is the actor (the authenticated user performing the
        action). Never store PINs, PIN hashes, JWTs, or raw tokens here.
        """
        try:
            log = AuditLog(
                user_id=user_id,
                action=action.value,
                entity_type=entity_type,
                entity_id=entity_id,
                details=details,
            )
            self.db.add(log)
        except Exception as exc:
            logger.error("audit_log_failed", error=str(exc))
