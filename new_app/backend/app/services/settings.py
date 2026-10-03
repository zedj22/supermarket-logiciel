"""Settings service (Phase 17, §17.1).

Owns the store/application settings contract:

* **read** never writes — a fresh install (or an in-memory test database)
  returns the documented defaults without mutating anything;
* **write** is a partial update that persists exactly the fields supplied,
  creates the singleton row on first save, and appends one ``update`` audit
  row **in the same transaction**: a change that cannot be audited is not
  reported as saved;
* failures surface as :class:`app.core.exceptions.AppError` subclasses and
  are never swallowed.

``store_name`` defaults to ``settings.STORE_NAME`` (the ``.env`` value) so a
fresh install keeps behaving exactly as it does today — Phase 15 renders
that name on receipts until an owner saves a different one here.
"""

from __future__ import annotations

import json
import uuid

import structlog
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.models.settings import (
    DEFAULT_LOW_STOCK_THRESHOLD,
    DEFAULT_PAPER,
    DEFAULT_STORE_NAME,
    SINGLETON_ID,
    AppSetting,
)
from app.repositories.settings import SettingsRepository
from app.schemas.settings import SettingsUpdateRequest
from app.services.base import BaseService

logger = structlog.get_logger(__name__)


class SettingsService(BaseService):
    """Store/application settings use case."""

    def __init__(self, db: Session):
        super().__init__(db)
        self._repo = SettingsRepository(db)

    # -- read ---------------------------------------------------------------

    def get(self) -> AppSetting:
        """Current settings.  Never writes to the database."""
        row = self._repo.get_singleton()
        if row is not None:
            return row
        return AppSetting(id=SINGLETON_ID, **self._defaults())

    # -- write --------------------------------------------------------------

    def update(
        self,
        request: SettingsUpdateRequest,
        *,
        actor_id: uuid.UUID | None = None,
    ) -> AppSetting:
        """Apply a partial update, persist it and audit the change.

        Raises an :class:`AppError` when the row cannot be written, so a
        caller is never told "saved" unless the commit really happened.
        """
        changes = request.provided()
        before = self.get()
        before_snapshot = {key: getattr(before, key) for key in changes}
        after_snapshot = {**before_snapshot, **changes}

        with self.transaction():
            row = self._repo.get_singleton()
            if row is None:
                row = self._repo.create_singleton(**self._defaults())
            for key, value in changes.items():
                setattr(row, key, value)
            # Same transaction as the change: no audit row, no save.
            self.db.add(
                AuditLog(
                    user_id=actor_id,
                    action=AuditAction.UPDATE.value,
                    entity_type="settings",
                    details=json.dumps(sorted(changes)),
                    before_state=json.dumps(before_snapshot, default=str),
                    after_state=json.dumps(after_snapshot, default=str),
                )
            )
        logger.info(
            "settings_updated",
            fields=sorted(changes),
            user_id=str(actor_id) if actor_id else None,
        )
        return row

    # -- helpers ------------------------------------------------------------

    def _defaults(self) -> dict[str, object]:
        return {
            "store_name": settings.STORE_NAME or DEFAULT_STORE_NAME,
            "store_phone": "",
            "store_address": "",
            "invoice_footer": "",
            "default_paper": DEFAULT_PAPER,
            "ask_before_print": False,
            "auto_print_invoice": False,
            "allow_debt": True,
            "low_stock_threshold": DEFAULT_LOW_STOCK_THRESHOLD,
        }
