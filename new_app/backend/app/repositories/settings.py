"""Settings repository (Phase 17, §17.1).

Persistence only — no business rules, no HTTP.  The table holds a single
row (``id = 1``); see :mod:`app.models.settings`.
"""

from __future__ import annotations

from app.models.settings import SINGLETON_ID, AppSetting
from app.repositories.base import BaseRepository


class SettingsRepository(BaseRepository[AppSetting]):
    """CRUD for the singleton ``app_settings`` row."""

    model = AppSetting

    def get_singleton(self) -> AppSetting | None:
        """Return the settings row, or ``None`` when none has been written."""
        return self.db.get(AppSetting, SINGLETON_ID)

    def create_singleton(self, **values: object) -> AppSetting:
        """Insert the row.  Callers own the transaction."""
        row = AppSetting(id=SINGLETON_ID, **values)
        self.db.add(row)
        self.db.flush()
        return row
