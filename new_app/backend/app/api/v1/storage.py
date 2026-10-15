"""Storage & data usage endpoint (admin-only, read-only).

``GET /api/v1/storage`` reports how much disk the server software and
its accumulated data consume: database size (via PostgreSQL's own size
function), backend application files, backups, the server data folder,
cache/temporary files and the capacity of the server volume.

Authorization follows the established convention — ``settings_manage``
is admin-only under the seed role matrix, and the router-level rate
guard / device guard apply to this route like every other ``/api/v1``
route.  The endpoint takes no path parameters (there is no filesystem
scanning surface) and returns no paths, credentials or hostnames.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.storage import StorageUsageResponse
from app.services.storage import get_storage_usage

router = APIRouter()


@router.get(
    "",
    response_model=StorageUsageResponse,
    summary="Measure server storage usage",
    tags=["storage"],
)
def storage_usage(
    user: User = Depends(require_permission(PermissionScope.SETTINGS_MANAGE)),
    db: Session = Depends(get_db),
) -> StorageUsageResponse:
    """Return measured server-side storage usage (read-only, admin-only)."""
    return get_storage_usage(db)
