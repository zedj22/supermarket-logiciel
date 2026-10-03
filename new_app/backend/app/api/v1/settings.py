"""Settings API endpoints (Phase 17, §17.1).

- ``GET  /api/v1/settings`` — read the store/application settings.
  Any **authenticated** user: the POS needs ``allow_debt``,
  ``low_stock_threshold`` and the print defaults on every role, so the read
  path must not be admin-only.  The device guard still applies in LAN mode.
- ``PUT  /api/v1/settings`` — partial update. **``settings_manage``** (admin
  only, ``PHASE_0_BUSINESS_RULES.md:41``).

Language and theme are intentionally absent: they are user/session
preferences owned by the Flutter client (``app_locale`` /
``app_theme_mode``), not the server.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.dependencies import get_current_user, require_permission
from app.db.session import get_db
from app.models.enums import PermissionScope
from app.models.settings import AppSetting
from app.models.user import User
from app.schemas.settings import SettingsResponse, SettingsUpdateRequest
from app.services.settings import SettingsService

router = APIRouter()


def _get_settings_service(db: Session = Depends(get_db)) -> SettingsService:
    return SettingsService(db)


def to_settings_response(row: AppSetting) -> SettingsResponse:
    """Map an ``AppSetting`` row to its API response."""
    return SettingsResponse(
        store_name=row.store_name,
        store_phone=row.store_phone,
        store_address=row.store_address,
        invoice_footer=row.invoice_footer,
        default_paper=row.default_paper,
        ask_before_print=row.ask_before_print,
        auto_print_invoice=row.auto_print_invoice,
        allow_debt=row.allow_debt,
        low_stock_threshold=row.low_stock_threshold,
    )


@router.get(
    "",
    response_model=SettingsResponse,
    summary="Get store settings",
    tags=["settings"],
)
def get_settings(
    user: User = Depends(get_current_user),
    service: SettingsService = Depends(_get_settings_service),
) -> SettingsResponse:
    """Read the current store/application settings."""
    return to_settings_response(service.get())


@router.put(
    "",
    response_model=SettingsResponse,
    summary="Update store settings",
    tags=["settings"],
)
def update_settings(
    request: SettingsUpdateRequest,
    user: User = Depends(
        require_permission(PermissionScope.SETTINGS_MANAGE)
    ),
    service: SettingsService = Depends(_get_settings_service),
) -> SettingsResponse:
    """Partial update — only the fields present in the body change."""
    row = service.update(request, actor_id=user.id)
    return to_settings_response(row)
