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

    # Financial
    REPORT_FINANCIAL = "report_financial"
    EXPORT_DATA = "export_data"
    BACKUP_RESTORE = "backup_restore"

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



# ── Devices ────────────────────────────────────────────────────────────


class DeviceStatus(str, enum.Enum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"


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
    # Phase 11: purchase receipt (draft -> received posting). Additive only.
    RECEIVE = "receive"
    # Phase 15: exports (/api/v1/exports) and print renders
    # (/api/v1/print). Additive only — every attempt (success or failure)
    # appends exactly one row.
    EXPORT = "export"
    PRINT = "print"
