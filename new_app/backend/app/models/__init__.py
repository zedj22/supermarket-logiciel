"""Models package — SQLAlchemy ORM models.

Import all models here so they are registered with Base.metadata
and discoverable by Alembic autogenerate.

Usage:
    from app.models import User, Product, Sale  # noqa
    # or
    from app.models import *  # noqa: F401, F403
"""

# Enums (re-export for convenience)
from app.models.enums import (  # noqa: F401
    AuditAction,
    AuditModule,
    AuditOutcome,
    DeviceStatus,
    ExpenseCategory,
    InvoiceDocType,
    InvoicePaymentMethod,
    PaymentMethod,
    PermissionScope,
    PurchaseStatus,
    ReturnReason,
    SaleStatus,
    StockMovementType,
    UserRoleEnum,
    ProductUnit,
)

# User / RBAC
from app.models.user import (  # noqa: F401
    AuthSession,
    Permission,
    Role,
    RolePermission,
    User,
    UserRole,
)

# Catalog
from app.models.catalog import (  # noqa: F401
    Category,
    Pack,
    PackItem,
    Product,
    ProductPurchaseUnit,
    ProductSellingUnit,
    ProductStockPackage,
    ProductVariant,
)

# Customers / Suppliers
from app.models.party import Customer, Supplier  # noqa: F401

# Sales
from app.models.sale import Sale, SaleLine, SalePayment  # noqa: F401

# POS (Phase 8): holds + favorites
from app.models.pos import PosHold, ProductFavorite  # noqa: F401

# Purchases
from app.models.purchase import Purchase, PurchaseLine  # noqa: F401

# Returns
from app.models.return_doc import Return, ReturnLine  # noqa: F401

# Debt
from app.models.debt import DebtLedgerEntry  # noqa: F401

# Supplier ledger (Phase 11)
from app.models.supplier_ledger import SupplierLedgerEntry  # noqa: F401

# Expenses
from app.models.expense import Expense  # noqa: F401

# Promotions (Phase 18)
from app.models.promotion import Promotion, PromotionProduct  # noqa: F401

# Inventory
from app.models.inventory import InventoryMovement  # noqa: F401

# Audit
from app.models.audit import AuditLog  # noqa: F401

# Devices / pairing (Phase 16)
from app.models.device import Device  # noqa: F401

# Store/application settings (Phase 17)
from app.models.settings import AppSetting  # noqa: F401

# Facturation (Phase 2): invoice document domain — isolated from POS/Sales
from app.models.facturation import (  # noqa: F401
    InvoiceClient,
    InvoiceDocument,
    InvoiceDocumentCounter,
    InvoiceDocumentLine,
)

# Base (re-export for convenience)
from app.db.base import Base, BaseModel, DocumentModel, MasterModel  # noqa: F401

__all__ = [
    # Enums
    "AuditAction",
    "AuditModule",
    "AuditOutcome",
    "DeviceStatus",
    "ExpenseCategory",
    "InvoiceDocType",
    "InvoicePaymentMethod",
    "PaymentMethod",
    "PermissionScope",
    "ProductUnit",
    "PurchaseStatus",
    "ReturnReason",
    "SaleStatus",
    "StockMovementType",
    "UserRoleEnum",
    # User / RBAC
    "AuthSession",
    "User",
    "Role",
    "Permission",
    "UserRole",
    "RolePermission",
    # Catalog
    "Category",
    "Product",
    "ProductVariant",
    "ProductSellingUnit",
    "ProductPurchaseUnit",
    "ProductStockPackage",
    "Pack",
    "PackItem",
    # Customers / Suppliers
    "Customer",
    "Supplier",
    # Sales
    "Sale",
    "SaleLine",
    "SalePayment",
    "PosHold",
    "ProductFavorite",
    # Purchases
    "Purchase",
    "PurchaseLine",
    # Returns
    "Return",
    "ReturnLine",
    # Debt
    "DebtLedgerEntry",
    # Supplier ledger
    "SupplierLedgerEntry",
    # Expenses
    "Expense",
    # Promotions (Phase 18)
    "Promotion",
    "PromotionProduct",
    # Inventory
    "InventoryMovement",
    # Audit
    "AuditLog",
    # Store/application settings (Phase 17)
    "AppSetting",
    # Facturation (Phase 2)
    "InvoiceClient",
    "InvoiceDocument",
    "InvoiceDocumentLine",
    "InvoiceDocumentCounter",
    # Base
    "Base",
    "BaseModel",
    "DocumentModel",
    "MasterModel",
]
