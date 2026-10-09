"""Role and permission seed data.

Provides deterministic initial data for the RBAC system.
Run with: python -m app.core.seed

This creates:
- All permission scopes from PermissionScope enum
- Three roles: admin, manager, cashier
- Admin gets all permissions
- Manager gets operational permissions
- Cashier gets basic POS permissions
- Every role (admin/manager/cashier) gets expense_view, expense_create
  and expense_cancel — Phase 13 GATE 7/8/9 product-owner decision.
- Promotions (Phase 18) — promotion_view/create/update go to admin and
  manager only; the cashier POS reads promotion prices through
  product_view (they ride on the product response).
- Facturation (Phase 9) — facturation_view / facturation_manage go to
  admin and manager only; the cashier has no access to Facturation or
  Invoice Clients.

NOT executed at application startup: run ``python -m app.core.seed``
after deploying a revision that adds permission scopes (decision record
D15).
"""

from __future__ import annotations

import sys

import structlog
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.engine import _factory
from app.models.enums import PermissionScope
from app.models.user import Permission, Role, RolePermission

logger = structlog.get_logger(__name__)

# Role → permissions mapping
ROLE_PERMISSIONS: dict[str, list[PermissionScope]] = {
    "admin": list(PermissionScope),  # All permissions
    "manager": [
        # POS
        PermissionScope.POS_SALE,
        PermissionScope.POS_CREDIT_SALE,
        PermissionScope.POS_DISCOUNT,
        PermissionScope.POS_VOID,
        PermissionScope.POS_RETURN,
        # Products
        PermissionScope.PRODUCT_VIEW,
        PermissionScope.PRODUCT_CREATE,
        PermissionScope.PRODUCT_UPDATE,
        PermissionScope.PRODUCT_ARCHIVE,
        # Categories
        PermissionScope.CATEGORY_VIEW,
        PermissionScope.CATEGORY_MANAGE,
        # Inventory
        PermissionScope.INVENTORY_VIEW,
        PermissionScope.INVENTORY_ADJUST,
        # Customers / Suppliers
        PermissionScope.CUSTOMER_VIEW,
        PermissionScope.CUSTOMER_MANAGE,
        PermissionScope.SUPPLIER_VIEW,
        PermissionScope.SUPPLIER_MANAGE,
        # Purchases
        PermissionScope.PURCHASE_VIEW,
        PermissionScope.PURCHASE_CREATE,
        PermissionScope.PURCHASE_DELETE,
        # Expenses (Phase 13, GATE 8/9) — same three scopes for every role
        PermissionScope.EXPENSE_VIEW,
        PermissionScope.EXPENSE_CREATE,
        PermissionScope.EXPENSE_CANCEL,
        # Promotions (Phase 18) — pricing management is admin + manager;
        # a cashier never manages promotions (POS reads them through
        # product_view on the product response).
        PermissionScope.PROMOTION_VIEW,
        PermissionScope.PROMOTION_CREATE,
        PermissionScope.PROMOTION_UPDATE,
        # Facturation (Phase 9) — documents + invoice clients are
        # admin + manager only; the cashier never touches fiscal docs.
        PermissionScope.FACTURATION_VIEW,
        PermissionScope.FACTURATION_MANAGE,
        # Financial
        PermissionScope.REPORT_FINANCIAL,
        PermissionScope.EXPORT_DATA,
    ],
    "cashier": [
        # POS
        PermissionScope.POS_SALE,
        PermissionScope.POS_CREDIT_SALE,
        PermissionScope.POS_DISCOUNT,
        PermissionScope.POS_RETURN,
        # Products (view only)
        PermissionScope.PRODUCT_VIEW,
        # Categories (view only)
        PermissionScope.CATEGORY_VIEW,
        # Customers (view + limited manage for debt)
        PermissionScope.CUSTOMER_VIEW,
        PermissionScope.CUSTOMER_MANAGE,
        # Expenses (Phase 13, GATE 8) — identical for all three roles
        PermissionScope.EXPENSE_VIEW,
        PermissionScope.EXPENSE_CREATE,
        PermissionScope.EXPENSE_CANCEL,
    ],
}


def seed_roles_and_permissions(db: Session) -> dict:
    """Seed roles and permissions. Idempotent — safe to run multiple times.

    Returns a summary of what was created.
    """
    created = {"permissions": 0, "roles": 0, "role_permissions": 0}

    # 1. Create all permissions from enum
    for scope in PermissionScope:
        existing = db.execute(
            select(Permission).where(Permission.scope == scope.value)
        ).scalar_one_or_none()

        if existing is None:
            perm = Permission(
                scope=scope.value,
                description=scope.value.replace("_", " ").title(),
            )
            db.add(perm)
            created["permissions"] += 1

    db.flush()

    # 2. Create roles and assign permissions
    for role_name, scopes in ROLE_PERMISSIONS.items():
        role = db.execute(
            select(Role).where(Role.name == role_name)
        ).scalar_one_or_none()

        if role is None:
            role = Role(
                name=role_name,
                description=f"{role_name.title()} role",
            )
            db.add(role)
            db.flush()
            created["roles"] += 1

        # Get existing permission assignments
        existing_perms = {
            rp.permission.scope
            for rp in role.role_permissions
        }

        # Add missing permissions
        for scope in scopes:
            if scope.value not in existing_perms:
                perm = db.execute(
                    select(Permission).where(Permission.scope == scope.value)
                ).scalar_one_or_none()

                if perm is not None:
                    db.add(RolePermission(role_id=role.id, permission_id=perm.id))
                    created["role_permissions"] += 1

    db.commit()
    return created


def run_seed():
    """CLI entry point for seeding."""
    SessionLocal = _factory.session_factory
    db = SessionLocal()
    try:
        result = seed_roles_and_permissions(db)
        logger.info(
            "seed_complete",
            permissions=result["permissions"],
            roles=result["roles"],
            role_permissions=result["role_permissions"],
        )
        print(f"Seed complete: {result}")
    except Exception as exc:
        db.rollback()
        logger.error("seed_failed", error=str(exc))
        print(f"Seed failed: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        db.close()


if __name__ == "__main__":
    run_seed()
