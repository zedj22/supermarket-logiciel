"""Domain enums — shared across models, schemas, and API responses.

All values are lowercase strings to serialize cleanly to JSON/PostgreSQL.
"""

import enum

# ── Auth / RBAC ────────────────────────────────────────────────────────


class UserRoleEnum(str, enum.Enum):
    ADMIN = "admin"
    MANAGER = "manager"
    CASHIER = "cashier"


class PermissionScope(str, enum.Enum):
    """Granular permission scopes (not role labels)."""

    # POS
    POS_SALE = "pos_sale"
    POS_CREDIT_SALE = "pos_credit_sale"
    POS_DISCOUNT = "pos_discount"
    POS_VOID = "pos_void"
    POS_RETURN = "pos_return"

    # Products
    PRODUCT_VIEW = "product_view"
    PRODUCT_CREATE = "product_create"
    PRODUCT_UPDATE = "product_update"
    PRODUCT_ARCHIVE = "product_archive"

    # Categories
    CATEGORY_VIEW = "category_view"
    CATEGORY_MANAGE = "category_manage"

    # Inventory
    INVENTORY_VIEW = "inventory_view"
    INVENTORY_ADJUST = "inventory_adjust"

    # Customers / Suppliers
    CUSTOMER_VIEW = "customer_view"
    CUSTOMER_MANAGE = "customer_manage"
    SUPPLIER_VIEW = "supplier_view"
    SUPPLIER_MANAGE = "supplier_manage"

    # Purchases
    PURCHASE_VIEW = "purchase_view"
    PURCHASE_CREATE = "purchase_create"
    PURCHASE_DELETE = "purchase_delete"

    # Expenses (Phase 13) — GATE 7/8/9: admin, manager and cashier all
    # receive all three scopes (product-owner decision, §11 role matrix).
    EXPENSE_VIEW = "expense_view"
    EXPENSE_CREATE = "expense_create"
    EXPENSE_CANCEL = "expense_cancel"

    # Promotions (Phase 18) — pricing management, admin + manager only.
    # The POS reads promotion prices through PRODUCT_VIEW (they ride on the
    # product response), so a cashier never needs these scopes.
    PROMOTION_VIEW = "promotion_view"
    PROMOTION_CREATE = "promotion_create"
    PROMOTION_UPDATE = "promotion_update"

    # Financial
    REPORT_FINANCIAL = "report_financial"
    EXPORT_DATA = "export_data"
    BACKUP_RESTORE = "backup_restore"

    # Facturation (Phase 9) — documents + invoice clients; admin + manager only.
    FACTURATION_VIEW = "facturation_view"
    FACTURATION_MANAGE = "facturation_manage"

    # Admin
    USER_MANAGE = "user_manage"
    SETTINGS_MANAGE = "settings_manage"
    DEVICE_MANAGE = "device_manage"
    AUDIT_VIEW = "audit_view"


# ── Catalog ────────────────────────────────────────────────────────────


class ProductUnit(str, enum.Enum):
    PIECE = "piece"
    KG = "kg"
    GRAM = "gram"
    LITER = "liter"
    MILLILITER = "milliliter"
    METER = "meter"
    PACK = "pack"


# ── Sales ──────────────────────────────────────────────────────────────


class SaleStatus(str, enum.Enum):
    COMPLETED = "completed"
    VOID = "void"


class PaymentMethod(str, enum.Enum):
    CASH = "cash"
    CARD = "card"
    CREDIT = "credit"       # full debt
    PARTIAL = "partial"     # partial payment


# ── Returns ────────────────────────────────────────────────────────────


class ReturnReason(str, enum.Enum):
    DEFECTIVE = "defective"
    WRONG_ITEM = "wrong_item"
    CUSTOMER_CHANGE = "customer_change"
    EXPIRED = "expired"
    OTHER = "other"


# ── Purchases (Phase 11) ────────────────────────────────────────────────


class PurchaseStatus(str, enum.Enum):
    """Purchase document lifecycle (GATE 2 — minimal state machine).

    draft     — no stock / PMP / payable effects; editable and deletable.
    received  — posted atomically (stock + PMP + movements + payable).
    cancelled — terminal reversal of a received document (append-only).
    """

    DRAFT = "draft"
    RECEIVED = "received"
    CANCELLED = "cancelled"


# ── Inventory ──────────────────────────────────────────────────────────


class StockMovementType(str, enum.Enum):
    SALE = "sale"
    SALE_VOID = "sale_void"
    PURCHASE = "purchase"
    PURCHASE_DELETE = "purchase_delete"
    RETURN = "return"
    ADJUSTMENT = "adjustment"
    PACK_COMPONENT = "pack_component"
    # Phase 6 packaging / stock-breaking (audit of open/break events)
    PACKAGE_BREAK = "package_break"
    PACKAGE_RECEIVE = "package_receive"


# ── Expenses ───────────────────────────────────────────────────────────


class ExpenseCategory(str, enum.Enum):
    RENT = "rent"
    UTILITIES = "utilities"
    SALARY = "salary"
    MAINTENANCE = "maintenance"
    SUPPLIES = "supplies"
    TRANSPORT = "transport"
    OTHER = "other"


class ExpenseStatus(str, enum.Enum):
    """Expense lifecycle (GATE 1 — minimal state machine).

    posted     — recorded money-out; immutable, counted in summaries.
    cancelled  — terminal correction (row retained, audit carries the
                 reason; excluded from the default list/summary).
    """

    POSTED = "posted"
    CANCELLED = "cancelled"



# ── Promotions (Phase 18) ──────────────────────────────────────────────


class PromotionType(str, enum.Enum):
    """How a promotion rewrites the retail-branch price of its products.

    percentage  — value is the percent OFF (20 → pay 80% of retail)
    fixed_price — value replaces the retail unit price (single-product
                  promotions only; rejected for multi-product ones)
    """

    PERCENTAGE = "percentage"
    FIXED_PRICE = "fixed_price"


# ── Devices ────────────────────────────────────────────────────────────


class DeviceStatus(str, enum.Enum):
    """Server-side device registry lifecycle (Phase 16).

    pending  — a pairing request exists (pairing code was accepted) and is
               waiting for a human with ``device_manage`` to approve it.
    approved — a one-time device token was issued; the device may call the
               guarded API presenting X-Device-ID + X-Device-Token.
    rejected — the request was denied; the client must re-pair.
    revoked  — an approved device was withdrawn; the stored token hash is
               cleared and every further call fails with ``device_revoked``.
               (Code-only addition — the column stays VARCHAR, §10.1/D-04.)
    """

    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"
    REVOKED = "revoked"


# ── Audit ──────────────────────────────────────────────────────────────


class AuditAction(str, enum.Enum):
    CREATE = "create"
    UPDATE = "update"
    DELETE = "delete"
    LOGIN = "login"
    LOGOUT = "logout"
    VOID = "void"
    RETURN = "return"
    PAYMENT = "payment"
    ADJUSTMENT = "adjustment"
    BACKUP = "backup"
    RESTORE = "restore"
    # Objective 2: portable archive download / upload staging.  Additive
    # only — audit_logs.action is String(30).
    BACKUP_DOWNLOAD = "backup_download"
    BACKUP_UPLOAD = "backup_upload"
    # Phase 11: purchase receipt (draft -> received posting). Additive only.
    RECEIVE = "receive"
    # Phase 15: exports (/api/v1/exports) and print renders
    # (/api/v1/print). Additive only — every attempt (success or failure)
    # appends exactly one row.
    EXPORT = "export"
    PRINT = "print"
    # Phase 17: bulk product CSV/XLSX import (POST /api/v1/products/import).
    # Additive only — the audit_logs action column is String(30).
    IMPORT = "import"
    # Phase 16: device registry lifecycle.  Additive only — the audit_logs
    # action column is String(30).  NEVER carries the pairing code or the
    # device token (§18); no heartbeat/last_seen rows are ever written.
    DEVICE_PAIR = "device_pair"
    DEVICE_APPROVE = "device_approve"
    DEVICE_REJECT = "device_reject"
    DEVICE_REVOKE = "device_revoke"


class AuditOutcome(str, enum.Enum):
    """Outcome of one audited attempt (audit trail slice A).

    success — the operation completed (the state change committed).
    failure — the operation was attempted and rejected by business rules
              or credentials (wrong PIN, insufficient stock, ...).
    denied  — refused by policy before the operation ran (disabled
              account, missing permission scope, unknown device).

    Legacy rows written before this column existed carry NULL and are
    presented as "unknown" — never silently upgraded to "success".
    """

    SUCCESS = "success"
    FAILURE = "failure"
    DENIED = "denied"


class AuditModule(str, enum.Enum):
    """Functional module an audit event belongs to (audit trail slice A).

    Additive vocabulary for filtering the audit screen. Legacy rows may
    have module NULL ("unknown").
    """

    AUTH = "auth"
    USERS = "users"
    PRODUCTS = "products"
    CATEGORIES = "categories"
    INVENTORY = "inventory"
    SALES = "sales"
    RETURNS = "returns"
    PURCHASES = "purchases"
    CUSTOMERS = "customers"
    SUPPLIERS = "suppliers"
    DEBTS = "debts"
    EXPENSES = "expenses"
    PROMOTIONS = "promotions"
    PACKS = "packs"
    FACTURATION = "facturation"
    SETTINGS = "settings"
    DEVICES = "devices"
    BACKUPS = "backups"
    EXPORTS = "exports"
    PRINT = "print"
    REPORTS = "reports"
    SYSTEM = "system"


# ── Facturation (Phase 2 — invoices) ───────────────────────────────────


class InvoiceDocType(str, enum.Enum):
    """Facturation document types.

    Mirrors ``app.domain.facturation.DOC_TYPES`` (Phase 1 remains the
    validation authority).  Values are UPPERCASE on purpose — the
    factura_simple contract is ``FAC`` / ``DEV`` / ``PRO`` / ``BC`` / ``BL``
    and the document number embeds them (``FAC-2026-0001``), so the usual
    lowercase-enum convention does not apply here.
    """

    FAC = "FAC"
    DEV = "DEV"
    PRO = "PRO"
    BC = "BC"
    BL = "BL"


class InvoicePaymentMethod(str, enum.Enum):
    """Facturation payment methods.

    Mirrors ``app.domain.facturation.PAYMENT_METHODS`` (cash / transfer /
    cheque).  DISTINCT from the POS :class:`PaymentMethod` enum (cash /
    card / credit / partial) — the two vocabularies serve different
    document domains and must never be merged.
    """

    CASH = "cash"
    TRANSFER = "transfer"
    CHEQUE = "cheque"
