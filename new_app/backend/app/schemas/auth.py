"""Pydantic schemas for authentication and user management.

Request/response schemas for:
- First-admin setup
- Login / logout
- Token verification / reauthentication
- User CRUD
- Role/permission responses
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import StrictBaseModel


# ---------------------------------------------------------------------------
# Role / Permission responses (defined first for forward references)
# ---------------------------------------------------------------------------


class PermissionResponse(StrictBaseModel):
    """Permission response."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    scope: str
    description: str | None = None


class RoleResponse(StrictBaseModel):
    """Role response with permissions."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    description: str | None = None
    permissions: list[PermissionResponse] = []


# ---------------------------------------------------------------------------
# User management
# ---------------------------------------------------------------------------


class UserResponse(StrictBaseModel):
    """User response (never includes pin_hash)."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    is_active: bool
    last_login_at: datetime | None = None
    last_logout_at: datetime | None = None
    failed_login_attempts: int = 0
    locked_until: datetime | None = None
    created_at: datetime
    roles: list[RoleResponse] = []


class UserCreateRequest(StrictBaseModel):
    """Create a new user."""

    name: str = Field(..., min_length=1, max_length=150)
    pin: str = Field(..., min_length=4, max_length=6)
    role_names: list[str] = Field(
        default=["cashier"],
        description="Role names to assign (e.g. admin, manager, cashier)",
    )


class UserUpdateRequest(StrictBaseModel):
    """Update user fields."""

    name: str | None = Field(None, min_length=1, max_length=150)
    is_active: bool | None = None
    role_names: list[str] | None = None


class UserListResponse(StrictBaseModel):
    """Paginated user list."""

    items: list[UserResponse]
    total: int
    page: int
    page_size: int
    pages: int


# ---------------------------------------------------------------------------
# First-admin setup
# ---------------------------------------------------------------------------


class SetupRequest(StrictBaseModel):
    """First-admin setup request."""

    name: str = Field(..., min_length=1, max_length=150, description="Admin full name")
    pin: str = Field(..., min_length=4, max_length=6, description="PIN (4-6 digits)")
    pin_confirm: str = Field(..., min_length=4, max_length=6, description="Confirm PIN")


class SetupResponse(StrictBaseModel):
    """First-admin setup response.

    Carries the freshly created administrator's session so first-run setup
    lands on the dashboard already logged in.  Subsequent launches still
    require the PIN: the client never restores a session across restarts.
    """

    user_id: UUID
    name: str
    message: str = "Admin account created successfully"
    access_token: str
    token_type: str = "bearer"
    expires_in: int = Field(description="Token lifetime in seconds")
    user: UserResponse


# ---------------------------------------------------------------------------
# Public login user discovery
# ---------------------------------------------------------------------------


class LoginUserRoleResponse(StrictBaseModel):
    """Role name exposed on the public login selector."""

    name: str


class LoginUserResponse(StrictBaseModel):
    """Minimum-property user for the login screen.

    Deliberately excludes security-sensitive fields (pin_hash,
    failed_login_attempts, locked_until, sessions, audit data, timestamps).
    Built manually from the User model — never via model_validate — so new
    User fields cannot leak through by accident.
    """

    id: UUID
    full_name: str
    is_active: bool
    roles: list[LoginUserRoleResponse] = []


class LoginUserListResponse(StrictBaseModel):
    """List of active users for the login selector."""

    items: list[LoginUserResponse]
    total: int


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------


class LoginRequest(StrictBaseModel):
    """Login request — user selection + PIN."""

    user_id: UUID = Field(..., description="User UUID")
    pin: str = Field(..., min_length=4, max_length=6, description="PIN (4-6 digits)")
    device_name: str | None = Field(None, max_length=255, description="Client device name")


class LoginResponse(StrictBaseModel):
    """Login response with token and user info."""

    access_token: str
    token_type: str = "bearer"
    expires_in: int = Field(description="Token lifetime in seconds")
    user: UserResponse


# ---------------------------------------------------------------------------
# Token verification
# ---------------------------------------------------------------------------


class VerifyResponse(StrictBaseModel):
    """Token verification response."""

    valid: bool
    user: UserResponse | None = None
    session_id: UUID | None = None


class VerifyTokenRequest(StrictBaseModel):
    """``POST /auth/verify-token`` body form.

    The Flutter client posts the token as JSON; the documented query
    form (``?token=…``) stays supported. The endpoint accepts either.
    """

    token: str = Field(..., description="JWT to verify")


# ---------------------------------------------------------------------------
# Reauthentication
# ---------------------------------------------------------------------------


class ReauthRequest(StrictBaseModel):
    """Reauthentication request — verify PIN for sensitive actions."""

    pin: str = Field(..., min_length=4, max_length=6, description="PIN (4-6 digits)")


class ReauthResponse(StrictBaseModel):
    """Reauthentication response."""

    verified: bool
    message: str = ""


class PINChangeRequest(StrictBaseModel):
    """Change a user's PIN."""

    new_pin: str = Field(..., min_length=4, max_length=6)
    new_pin_confirm: str = Field(..., min_length=4, max_length=6)


class PINChangeResponse(StrictBaseModel):
    """PIN change response."""

    message: str = "PIN changed successfully"
    sessions_invalidated: int = 0


class CurrentUserResponse(StrictBaseModel):
    """Authenticated user context response."""

    id: UUID
    full_name: str
    is_active: bool
    roles: list[RoleResponse]
    permissions: list[str]
