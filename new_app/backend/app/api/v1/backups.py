"""Backup API endpoints (Phase 17, §17.2 + Objective 2).

- ``GET    /api/v1/backups``                list (any authenticated user —
  the screen needs it before an admin can act, and filenames are not
  secret)
- ``POST   /api/v1/backups``                create — **``backup_restore``**
- ``GET    /api/v1/backups/{id}/inspect``   pre-restore summary —
  **``backup_restore``** (integrity + compatibility, shown in the confirm
  dialog)
- ``GET    /api/v1/backups/{id}/download``  portable ZIP (dump +
  manifest) — **``backup_restore``**
- ``POST   /api/v1/backups/upload``         stage an uploaded archive /
  raw dump — **``backup_restore``**
- ``POST   /api/v1/backups/{id}/restore``   restore — **``backup_restore``**
  and an explicit ``{"confirm": true}`` body (422
  ``RESTORE_CONFIRMATION_REQUIRED`` without it).  The service snapshots
  the current database once more before replaying (safety backup) and
  reports a post-restore connectivity check.

``backup_restore`` is admin-only in the role matrix
(``PHASE_0_BUSINESS_RULES.md:41``).  Every mutating endpoint is audited
(``AuditAction.BACKUP`` / ``RESTORE`` / ``BACKUP_UPLOAD``).

The device guard applies as for every other route in LAN mode: these are
not bootstrap endpoints.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, File, Path, UploadFile, status
from fastapi.responses import Response
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user, require_permission
from app.core.exceptions import ValidationError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.backup import (
    BackupInfo,
    BackupInspect,
    BackupListResponse,
    BackupRestoreResponse,
    RestoreRequest,
)
from app.services.backup import MAX_UPLOAD_BYTES, BackupService

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


@router.get(
    "/{backup_id}/inspect",
    response_model=BackupInspect,
    summary="Inspect a backup before restoring",
    tags=["backups"],
)
def inspect_backup(
    backup_id: int = Path(ge=_MIN_BACKUP_ID, description="Backup id"),
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> BackupInspect:
    """Integrity (hash) + compatibility (schema revision) summary."""
    return service.inspect(backup_id)


@router.get(
    "/{backup_id}/download",
    summary="Download a portable backup archive",
    tags=["backups"],
    response_class=Response,
)
def download_backup(
    backup_id: int = Path(ge=_MIN_BACKUP_ID, description="Backup id"),
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> Response:
    """ZIP containing ``dump.sql`` + ``manifest.json`` (one file to move)."""
    data, filename = service.download(backup_id)
    return Response(
        content=data,
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.post(
    "/upload",
    response_model=BackupInfo,
    status_code=status.HTTP_201_CREATED,
    summary="Upload a portable archive or raw dump",
    tags=["backups"],
)
def upload_backup(
    file: UploadFile = File(...),
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> BackupInfo:
    """Stage an uploaded ZIP (dump + manifest) or ``.sql`` as a backup."""
    content = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(content) > MAX_UPLOAD_BYTES:
        raise ValidationError(
            "The uploaded backup exceeds the size limit.",
            details={"limit": MAX_UPLOAD_BYTES},
            code="BACKUP_UPLOAD_TOO_LARGE",
        )
    return service.upload(
        content=content,
        filename=file.filename or "upload.sql",
        actor_id=user.id,
    )


@router.post(
    "/{backup_id}/restore",
    response_model=BackupRestoreResponse,
    summary="Restore from a backup",
    tags=["backups"],
)
def restore_backup(
    body: RestoreRequest | None = None,
    backup_id: int = Path(ge=_MIN_BACKUP_ID, description="Backup id"),
    user: User = Depends(
        require_permission(PermissionScope.BACKUP_RESTORE)
    ),
    service: BackupService = Depends(_get_backup_service),
) -> BackupRestoreResponse:
    """Replay a backup over the live database (all-or-nothing).

    Requires ``{"confirm": true}``; without it the request is refused
    with 422 ``RESTORE_CONFIRMATION_REQUIRED`` before anything touches
    the database.
    """
    confirm = bool(body and body.confirm)
    return service.restore(backup_id, confirm=confirm, actor_id=user.id)
