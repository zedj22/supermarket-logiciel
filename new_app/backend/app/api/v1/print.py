"""Print API endpoints (Phase 15 §12.1, §16 + barcode labels).

``POST /api/v1/print`` renders sale / return documents as PDF bytes
(80 mm receipt or A4). The permission is body-dependent and reuses
existing scopes — no new scope was introduced:

    sale   -> pos_sale
    return -> pos_return

Purchase printing is deferred (Phase 15 Step A scope): ``document_type``
is an allowlisted literal, so ``purchase`` is rejected with a 422
VALIDATION_ERROR before any scope lookup or render.

``POST /api/v1/print/labels`` renders product price / barcode labels as
one PDF batch (A4 sheet or 80 mm roll). It reuses the existing
``product_view`` scope — a user allowed to read the catalog may print
its shelf labels; no ``print_*`` scope exists (STOP condition resolved
by reuse, same pattern as the document endpoint above).

Both endpoints own the ``Response``; the service only returns bytes.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Header, Request, Response
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user
from app.core.exceptions import ForbiddenError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.export import LabelPrintRequest, PrintRequest
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


def _assert_scope(user: User, scope: PermissionScope) -> None:
    if not user.has_permission(scope):
        raise ForbiddenError(
            message=f"Permission denied: {scope.value}",
            details={"required_permission": scope.value},
        )


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
    _assert_scope(user, scope)
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


@router.post(
    "/labels",
    summary="Render product price labels as PDF",
    tags=["print"],
    response_class=Response,
)
def print_labels(
    body: LabelPrintRequest,
    request: Request,
    user: User = Depends(get_current_user),
    service: PrintService = Depends(_get_service),
    x_device_id: str | None = Header(default=None, alias="X-Device-ID"),
) -> Response:
    """Batch-render price / barcode labels for the selected products.

    Permission reuses ``product_view`` (document endpoint pattern: the
    scope lives here, not in the service). Body validation — batch caps,
    duplicate ids, layout fit — happens at schema level (422) before any
    scope lookup, DB read or render, exactly like ``print_document``.
    Effective prices are resolved server-side; clients never send prices.
    """
    _assert_scope(user, PermissionScope.PRODUCT_VIEW)
    result = service.render_labels(
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
