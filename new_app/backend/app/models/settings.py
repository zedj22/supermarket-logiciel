"""Application settings model: app_settings (Phase 17, §17.1).

Single row (``id = 1``) holding the **store/application** settings that
belong to the *server*.

Ownership split (deliberate — one settings system, no duplication):

* **Server owns** everything the backend renders or enforces: store
  identity (name / phone / address), the receipt footer, print defaults
  and the POS rules the API itself applies (``allow_debt``,
  ``low_stock_threshold``).  These are exactly the fields Phase 15 deferred
  (``PHASE_15_PRINTING_EXPORTS_ANALYSIS.md`` Q3/Q6) and the Phase 0
  blueprint's ``GET/PUT /api/v1/settings`` payload.
* **The client owns** user/session preferences — language and theme —
  which stay in Flutter SharedPreferences exactly as they are today
  (``app_locale`` / ``app_theme_mode``).  Mirroring them here would create a
  second, conflicting settings system.

The row is created on demand by :class:`app.services.settings.SettingsService`,
so a brand-new database *and* an in-memory test database built with
``Base.metadata.create_all`` both work without a seeding migration.

All value columns are ``NOT NULL`` with Python-side defaults only: the DDL
is identical under Alembic and ``create_all`` and identical on PostgreSQL
and SQLite, so the migration and the unit-test schema can never drift.
"""

from sqlalchemy import Boolean, CheckConstraint, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin

#: Primary key of the one and only row.
SINGLETON_ID = 1

#: Defaults mirrored by :mod:`app.services.settings` for a fresh install.
DEFAULT_STORE_NAME = "Supermarket Pro"
DEFAULT_PAPER = "80mm"
PAPERS = ("80mm", "A4")
DEFAULT_LOW_STOCK_THRESHOLD = 5


class AppSetting(Base, TimestampMixin):
    """One row: the store's application settings."""

    __tablename__ = "app_settings"
    __table_args__ = (
        CheckConstraint(
            "default_paper IN ('80mm', 'A4')",
            name="ck_app_settings_default_paper",
        ),
        CheckConstraint(
            "low_stock_threshold >= 0",
            name="ck_app_settings_low_stock_threshold",
        ),
        CheckConstraint(
            "id = 1",
            name="ck_app_settings_singleton",
        ),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=SINGLETON_ID)

    # -- store identity (receipt / export header) --------------------------
    store_name: Mapped[str] = mapped_column(
        String(120), nullable=False, default=DEFAULT_STORE_NAME
    )
    store_phone: Mapped[str] = mapped_column(String(40), nullable=False, default="")
    store_address: Mapped[str] = mapped_column(
        String(255), nullable=False, default=""
    )
    invoice_footer: Mapped[str] = mapped_column(
        String(255), nullable=False, default=""
    )

    # -- printing (Phase 15 deferral, §17.6) -------------------------------
    default_paper: Mapped[str] = mapped_column(
        String(10), nullable=False, default=DEFAULT_PAPER
    )
    ask_before_print: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    auto_print_invoice: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )

    # -- POS rules the backend enforces ------------------------------------
    allow_debt: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    low_stock_threshold: Mapped[int] = mapped_column(
        Integer, nullable=False, default=DEFAULT_LOW_STOCK_THRESHOLD
    )
