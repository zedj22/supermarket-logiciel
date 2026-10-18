"""Product import / export API endpoints (Objective 1).

- GET  /api/v1/products/import/template — header-only CSV/XLSX template
- POST /api/v1/products/export          — download the catalogue (export_data)
- POST /api/v1/products/import          — preview (dry run) or apply a file

Mounted on the products prefix but declared as its own module; the
central router includes it BEFORE the ``/{product_id}`` routes so
``import`` / ``export`` are never swallowed by a path parameter.

An imported file cannot bypass any rule: the service replays every row
through the same Pydantic schemas and the same ``ProductService`` methods
the single-row API uses, and stock is never written (quantities move
only through ``POST /api/v1/inventory/adjust``).
"""

from __future__ import annotations

import json

from fastapi import APIRouter, Depends, File, Form, Query, Response, UploadFile
from sqlalchemy.orm import Session

from app.api.dependencies import require_permission
from app.core.exceptions import AppError, ForbiddenError, ValidationError
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.user import User
from app.schemas.product_transfer import (
    MAX_IMPORT_BYTES,
    ImportReport,
    OnConflict,
    ProductExportRequest,
)
from app.services.product_transfer import ProductTransferService

router = APIRouter()


def _get_service(db: Session = Depends(get_db)) -> ProductTransferService:
    return ProductTransferService(db)


@router.get(
    "/import/template",
    summary="Download an empty import template",
    tags=["products"],
    response_class=Response,
)
def import_template(
    format: str = Query(
        default="csv", pattern="^(csv|xlsx)$", description="csv or xlsx"
    ),
    locale: str = Query(
        default="en", pattern="^(en|fr|ar)$", description="column docs language"
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_VIEW)),
    service: ProductTransferService = Depends(_get_service),
) -> Response:
    """Header-only file (never an example row that could be imported)."""
    data, media_type, filename = service.template(fmt=format, locale=locale)  # type: ignore[arg-type]
    return Response(
        content=data,
        media_type=media_type,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.post(
    "/export",
    summary="Export products as CSV or XLSX",
    tags=["products"],
    response_class=Response,
)
def export_products(
    body: ProductExportRequest,
    user: User = Depends(require_permission(PermissionScope.EXPORT_DATA)),
    service: ProductTransferService = Depends(_get_service),
) -> Response:
    """Download the requested scope; the scope is echoed in a header."""
    data, media_type, filename, rows = service.export(body, user_id=user.id)
    return Response(
        content=data,
        media_type=media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "X-Export-Scope": body.scope,
            "X-Export-Rows": str(rows),
        },
    )


@router.post(
    "/import",
    summary="Import products from a CSV/XLSX file (dry run by default)",
    tags=["products"],
    response_model=ImportReport,
)
def import_products(
    file: UploadFile = File(...),
    dry_run: bool = Form(default=True),
    on_conflict: OnConflict = Form(default="skip"),
    mapping: str | None = Form(
        default=None,
        description=(
            "Optional JSON object mapping file field names to 0-based "
            "column indexes; when omitted the headers are auto-matched."
        ),
    ),
    user: User = Depends(require_permission(PermissionScope.PRODUCT_CREATE)),
    service: ProductTransferService = Depends(_get_service),
) -> ImportReport:
    """Preview (``dry_run=true``, the default) or apply an import file.

    Updating existing products additionally requires ``product_update``;
    archiving rows additionally requires ``product_archive`` (checked
    inside the service and reported per row).
    """
    if on_conflict == "update" and not user.has_permission(
        PermissionScope.PRODUCT_UPDATE
    ):
        raise ForbiddenError(
            "Importing with on_conflict=update requires the product_update "
            "permission.",
            details={"required_permission": PermissionScope.PRODUCT_UPDATE.value},
        )

    parsed_mapping: dict[str, object] | None = None
    if mapping and mapping.strip():
        try:
            parsed = json.loads(mapping)
        except json.JSONDecodeError as exc:
            raise ValidationError(
                f"mapping is not valid JSON: {exc}",
                code="IMPORT_MAPPING_INVALID",
            ) from exc
        if not isinstance(parsed, dict):
            raise ValidationError(
                "mapping must be a JSON object",
                code="IMPORT_MAPPING_INVALID",
            )
        parsed_mapping = parsed

    content = file.file.read(MAX_IMPORT_BYTES + 1)
    if len(content) > MAX_IMPORT_BYTES:
        # Service raises the documented 413; reading one extra byte here
        # only avoids buffering an unbounded upload in memory first.
        raise AppError(
            "The import file exceeds the 20 MB limit.",
            details={"bytes": len(content), "limit": MAX_IMPORT_BYTES},
            code="IMPORT_FILE_TOO_LARGE",
            status_code=413,
            message_key="import_file_too_large",
        )

    return service.run_import(
        filename=file.filename or "upload.csv",
        content=content,
        dry_run=dry_run,
        on_conflict=on_conflict,
        mapping=parsed_mapping,
        user_id=user.id,
        archive_allowed=user.has_permission(PermissionScope.PRODUCT_ARCHIVE),
    )
