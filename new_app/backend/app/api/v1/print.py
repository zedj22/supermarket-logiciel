"""Print API endpoint (Phase 15 §12.1, §16).

``POST /api/v1/print`` renders sale / return documents as PDF bytes
(80 mm receipt or A4). The permission is body-dependent and reuses
existing scopes — no new scope was introduced:

    sale   -> pos_sale
    return -> pos_return

Purchase printing is deferred (Phase 15 Step A scope): ``document_type``
is an allowlisted literal, so ``purchase`` is rejected with a 422
VALIDATION_ERROR before any scope lookup or render.

The endpoint owns the ``Response``; the service only returns bytes.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Header, Request, Response
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user
from app.core.exceptions import ForbiddenError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.export import PrintRequest
from app.services.print import PrintService

router = APIRouter()

_DOCUMENT_SCOPES = {
    "sale": PermissionScope.POS_SALE,
    "return": PermissionScope.POS_RETURN,
}


def _get_service(db: Session = Depends(get_db)) -> PrintService:
    return PrintService(db)


def _client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


@router.post(
    "",
    summary="Render a sale/return as PDF",
    tags=["print"],
    response_class=Response,
)
def print_document(
    body: PrintRequest,
    request: Request,
    user: User = Depends(get_current_user),
    service: PrintService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> Response:
    scope = _DOCUMENT_SCOPES[body.document_type]
    if not user.has_permission(scope):
        raise ForbiddenError(
            message=f"Permission denied: {scope.value}",
            details={"required_permission": scope.value},
        )
    result = service.render(
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
