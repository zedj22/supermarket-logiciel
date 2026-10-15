"""Loyalty repository (Phase A).

Persistence only — no business rules, no HTTP.  The settings table holds a
single row (``id = 1``); see :mod:`app.models.loyalty`.
"""

from __future__ import annotations

from app.models.loyalty import LOYALTY_SETTINGS_SINGLETON_ID, LoyaltySetting
from app.repositories.base import BaseRepository


class LoyaltySettingsRepository(BaseRepository[LoyaltySetting]):
    """CRUD for the singleton ``loyalty_settings`` row."""

    model = LoyaltySetting

    def get_singleton(self) -> LoyaltySetting | None:
        """Return the settings row, or ``None`` when none has been written."""
        return self.db.get(LoyaltySetting, LOYALTY_SETTINGS_SINGLETON_ID)

    def create_singleton(self, **values: object) -> LoyaltySetting:
        """Insert the row.  Callers own the transaction."""
        row = LoyaltySetting(id=LOYALTY_SETTINGS_SINGLETON_ID, **values)
        self.db.add(row)
        self.db.flush()
        return row
