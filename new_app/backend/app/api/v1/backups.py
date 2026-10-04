"""Backup API endpoints (Phase 17, §17.2).

- ``GET  /api/v1/backups``              list (any authenticated user — the
  screen needs it before an admin can act, and filenames are not secret)
- ``POST /api/v1/backups``              create — **``backup_restore``**
- ``POST /api/v1/backups/{id}/restore`` restore — **``backup_restore``**

``backup_restore`` is admin-only in the role matrix
(``PHASE_0_BUSINESS_RULES.md:41``).  Both mutating endpoints are audited
(``AuditAction.BACKUP`` / ``RESTORE``).

The device guard applies as for every other route in LAN mode: these are
not bootstrap endpoints.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Path, status
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user, require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.backup import (
    BackupInfo,
    BackupListResponse,
    BackupRestoreResponse,
)
from app.services.backup import BackupService

router = APIRouter()

_MIN_BACKUP_ID = 1


def _get_backup_service(db: Session = Depends(get_db)) -> BackupService:
    return BackupService(db)


@router.get(
    "",
    response_model=BackupListResponse,
    summary="List backups",
    tags=["backups"],
)
def list_backups(
    user: User = Depends(get_current_user),
    service: BackupService = Depends(_get_backup_service),
) -> BackupListResponse:
    """Newest first."""
    return service.list()


@router.post(
    "",
    response_model=BackupInfo,
    status_code=status.HTTP_201_CREATED,
    summary="Create a backup",
    tags=["backups"],
)
def create_backup(
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> BackupInfo:
    """Take a full ``pg_dump`` of the database."""
    return service.create(actor_id=user.id)


@router.post(
    "/{backup_id}/restore",
    response_model=BackupRestoreResponse,
    summary="Restore from a backup",
    tags=["backups"],
)
def restore_backup(
    backup_id: int = Path(ge=_MIN_BACKUP_ID, description="Backup id"),
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> BackupRestoreResponse:
    """Replay a backup over the live database (all-or-nothing)."""
    return service.restore(backup_id, actor_id=user.id)
