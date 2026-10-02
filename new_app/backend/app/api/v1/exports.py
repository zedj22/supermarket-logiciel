"""Export API endpoint (Phase 15 §12.1).

``POST /api/v1/exports`` renders one report as XLSX or PDF bytes behind
the existing ``export_data`` scope. The service decides the bytes; this
handler only wraps them in the download ``Response`` (services never
return Response objects).

Errors use the documented envelope: ``EXPORT_FORMAT_UNSUPPORTED`` (422,
unknown format/report), ``EXPORT_ROW_LIMIT`` (422), ``EXPORT_TOO_LARGE``
(413), ``EXPORT_RENDER_FAILED`` / ``MISSING_FONT`` (500), plus the
existing ``REPORT_*`` validation codes from the shared fetch path.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Header, Request, Response
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.export import ExportRequest
from app.services.export import ExportService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ExportService:
    return ExportService(db)


def _client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


@router.post(
    "",
    summary="Export a report as XLSX or PDF",
    tags=["exports"],
    response_class=Response,
)
def export_report(
    body: ExportRequest,
    request: Request,
    user: User = Depends(require_permission(PermissionScope.EXPORT_DATA)),
    service: ExportService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> Response:
    """Render the same payload as ``GET /reports/{report}`` to bytes."""
    result = service.export(
        body,
        user_id=user.id,
        ip_address=_client_ip(request),
        device_id=x_device_id,
    )
    return Response(
        content=result.data,
        media_type=result.media_type,
        headers={"Content-Disposition": f'attachment; filename="{result.filename}"'},
    )
