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
* **Facturation shares this row** (Phase 6): the company/fiscal identity a
  future invoice header renders (wilaya / email / NIF / NIS / RC / AI /
  RIB) is added HERE instead of in a second ``CompanySettings`` /
  ``FiscalSettings`` table.  ``store_name`` / ``store_address`` /
  ``store_phone`` above ARE the legacy ``Company`` name/address/phone —
  Facturation reads the same columns rather than duplicating them
  (``app.services.facturation.get_facturation_company_settings`` is the
  read abstraction; no other persistence exists).
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

from decimal import Decimal

from sqlalchemy import Boolean, CheckConstraint, Integer, Numeric, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin

#: Primary key of the one and only row.
SINGLETON_ID = 1

#: Defaults mirrored by :mod:`app.services.settings` for a fresh install.
DEFAULT_STORE_NAME = "Supermarket Pro"
DEFAULT_PAPER = "80mm"
PAPERS = ("80mm", "A4")
DEFAULT_LOW_STOCK_THRESHOLD = 5

#: Post-checkout receipt printing modes (``ck_app_settings_receipt_print_mode``).
#: One control, four behaviours: no printing, ask-then-print, print
#: automatically, or open the native print dialog above an amount.  The two
#: legacy booleans (``ask_before_print`` / ``auto_print_invoice``) are kept
#: for wire compatibility only — they are migrated into this column once
#: (0039) and never consulted again.
RECEIPT_PRINT_MODES = ("disabled", "ask", "auto_print", "ask_above_threshold")
DEFAULT_RECEIPT_PRINT_MODE = "disabled"
DEFAULT_RECEIPT_MIN_AMOUNT = Decimal("0")


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
            "receipt_print_mode IN ('disabled', 'ask', 'auto_print', "
            "'ask_above_threshold')",
            name="ck_app_settings_receipt_print_mode",
        ),
        CheckConstraint(
            "receipt_min_amount >= 0",
            name="ck_app_settings_receipt_min_amount",
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

    # -- company / fiscal identity (Phase 6 facturation) ------------------
    # factura_simple ``Company`` (singleton) fields the document header
    # renders (docx_export.build_docx / pdf_invoice.dart): wilaya, e-mail
    # and the fiscal/legal identifiers.  Name / address / phone are the
    # store_* columns above — never repeated here.  All optional in the
    # source (``str = ""``), so every default is '' and every value is
    # free text: no Algerian NIF/RC regex is invented (the legacy project
    # defines none, and ``invoice_clients`` stores its identifiers the
    # same plain way).  Lengths mirror the closest existing columns
    # (wilaya 100 / email 100 like suppliers.email / identifiers 30 like
    # invoice_clients.nif).
    store_wilaya: Mapped[str] = mapped_column(
        String(100), nullable=False, default=""
    )
    store_email: Mapped[str] = mapped_column(String(100), nullable=False, default="")
    store_nif: Mapped[str] = mapped_column(String(30), nullable=False, default="")
    store_nis: Mapped[str] = mapped_column(String(30), nullable=False, default="")
    store_rc: Mapped[str] = mapped_column(String(30), nullable=False, default="")
    store_ai: Mapped[str] = mapped_column(String(30), nullable=False, default="")
    store_rib: Mapped[str] = mapped_column(String(30), nullable=False, default="")

    # -- printing (Phase 15 deferral, §17.6) -------------------------------
    default_paper: Mapped[str] = mapped_column(
        String(10), nullable=False, default=DEFAULT_PAPER
    )
    ask_before_print: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    auto_print_invoice: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False
    )
    # The ONE post-checkout receipt printing control (see RECEIPT_PRINT_MODES).
    # The legacy booleans above are no longer read by any behaviour; 0039
    # folded their values into this column and zeroed them.
    receipt_print_mode: Mapped[str] = mapped_column(
        String(30), nullable=False, default=DEFAULT_RECEIPT_PRINT_MODE
    )
    # Only meaningful in ``ask_above_threshold`` mode; the amount is a
    # currency figure, so it uses the project's NUMERIC(18, 3) convention.
    receipt_min_amount: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=DEFAULT_RECEIPT_MIN_AMOUNT
    )

    # -- POS rules the backend enforces ------------------------------------
    allow_debt: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    low_stock_threshold: Mapped[int] = mapped_column(
        Integer, nullable=False, default=DEFAULT_LOW_STOCK_THRESHOLD
    )
