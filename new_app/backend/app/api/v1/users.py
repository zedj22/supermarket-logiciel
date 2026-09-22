"""User management API endpoints.

Endpoints:
- GET    /api/v1/users          — List users (paginated)
- POST   /api/v1/users          — Create user (admin)
- GET    /api/v1/users/{id}     — Get user by ID
- PUT    /api/v1/users/{id}     — Update user (admin)
- DELETE /api/v1/users/{id}     — Delete user (admin)
- POST   /api/v1/users/{id}/pin — Change PIN
"""

from __future__ import annotations

import math
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.dependencies import CurrentUser, require_permission
from app.core.constants import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
from app.core.exceptions import NotFoundError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import Role, User
from app.schemas.auth import (
    PINChangeRequest,
    PINChangeResponse,
    UserCreateRequest,
    UserListResponse,
    UserResponse,
    UserUpdateRequest,
)
from app.services.auth import AuthService

router = APIRouter()


def _get_auth_service(db: Session = Depends(get_db)) -> AuthService:
    return AuthService(db)


@router.get("", response_model=UserListResponse, tags=["users"])
def list_users(
    page: int = Query(1, ge=1),
    page_size: int = Query(DEFAULT_PAGE_SIZE, ge=1, le=MAX_PAGE_SIZE),
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> UserListResponse:
    """List all users with pagination. Admin-only."""
    from sqlalchemy import func, select

    total = service.db.scalar(select(func.count()).select_from(User)) or 0
    pages = math.ceil(total / page_size) if total > 0 else 1
    offset = (page - 1) * page_size

    users = service.db.scalars(
        select(User).order_by(User.full_name).offset(offset).limit(page_size)
    ).all()

    return UserListResponse(
        items=[UserResponse.model_validate(u) for u in users],
        total=total,
        page=page,
        page_size=page_size,
        pages=pages,
    )


@router.post("", response_model=UserResponse, tags=["users"])
def create_user(
    request: UserCreateRequest,
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> UserResponse:
    """Create a new user. Admin-only."""
    new_user = service.create_user(
        name=request.name,
        pin=request.pin,
        role_names=request.role_names,
    )
    return UserResponse.model_validate(new_user)


@router.get("/roles", tags=["users"])
def list_roles(
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> list[dict]:
    """List all available roles."""
    from sqlalchemy import select
    from app.models.user import Role

    roles = service.db.scalars(select(Role).order_by(Role.name)).all()
    return [
        {
            "id": str(r.id),
            "name": r.name,
            "description": r.description,
        }
        for r in roles
    ]


@router.get("/{user_id}", response_model=UserResponse, tags=["users"])
def get_user(
    user_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> UserResponse:
    """Get a user by ID. Admin-only."""
    target = service.db.get(User, user_id)
    if target is None:
        raise NotFoundError(message="User not found")
    return UserResponse.model_validate(target)


@router.put("/{user_id}", response_model=UserResponse, tags=["users"])
def update_user(
    user_id: uuid.UUID,
    request: UserUpdateRequest,
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> UserResponse:
    """Update a user. Admin-only."""
    updated = service.update_user(
        user_id=user_id,
        name=request.name,
        is_active=request.is_active,
        role_names=request.role_names,
    )
    return UserResponse.model_validate(updated)


@router.delete("/{user_id}", tags=["users"])
def delete_user(
    user_id: uuid.UUID,
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> dict:
    """Delete a user. Admin-only. Cannot delete the last admin."""
    service.delete_user(user_id)
    return {"message": "User deleted successfully"}


@router.post("/{user_id}/pin", response_model=PINChangeResponse, tags=["users"])
def change_pin(
    user_id: uuid.UUID,
    request: PINChangeRequest,
    user: User = Depends(require_permission(PermissionScope.USER_MANAGE)),
    service: AuthService = Depends(_get_auth_service),
) -> PINChangeResponse:
    """Change a user's PIN. Admin-only."""
    invalidated = service.change_pin(
        user_id=user_id,
        new_pin=request.new_pin,
        new_pin_confirm=request.new_pin_confirm,
    )
    return PINChangeResponse(sessions_invalidated=invalidated)
