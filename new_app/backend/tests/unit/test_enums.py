"""Tests for Phase 2 domain enums."""

import json

import pytest

from app.models.enums import (
    AuditAction,
    DeviceStatus,
    ExpenseCategory,
    ExpenseStatus,
    PaymentMethod,
    PermissionScope,
    ProductUnit,
    ReturnReason,
    SaleStatus,
    StockMovementType,
    UserRoleEnum,
)


class TestUserRoleEnum:
    def test_values(self):
        assert UserRoleEnum.ADMIN.value == "admin"
        assert UserRoleEnum.MANAGER.value == "manager"
        assert UserRoleEnum.CASHIER.value == "cashier"

    def test_member_count(self):
        assert len(UserRoleEnum) == 3


class TestPermissionScope:
    def test_pos_scopes_exist(self):
        assert PermissionScope.POS_SALE.value == "pos_sale"
        assert PermissionScope.POS_CREDIT_SALE.value == "pos_credit_sale"
        assert PermissionScope.POS_DISCOUNT.value == "pos_discount"
        assert PermissionScope.POS_VOID.value == "pos_void"
        assert PermissionScope.POS_RETURN.value == "pos_return"

    def test_admin_scopes_exist(self):
        assert PermissionScope.USER_MANAGE.value == "user_manage"
        assert PermissionScope.SETTINGS_MANAGE.value == "settings_manage"
        assert PermissionScope.AUDIT_VIEW.value == "audit_view"

    def test_member_count(self):
        assert len(PermissionScope) == 33  # 30 + Phase 18 promotion scopes

    def test_expense_scopes_exist(self):
        assert PermissionScope.EXPENSE_VIEW.value == "expense_view"
        assert PermissionScope.EXPENSE_CREATE.value == "expense_create"
        assert PermissionScope.EXPENSE_CANCEL.value == "expense_cancel"

    def test_promotion_scopes_exist(self):
        assert PermissionScope.PROMOTION_VIEW.value == "promotion_view"
        assert PermissionScope.PROMOTION_CREATE.value == "promotion_create"
        assert PermissionScope.PROMOTION_UPDATE.value == "promotion_update"


class TestProductUnit:
    def test_values(self):
        assert ProductUnit.PIECE.value == "piece"
        assert ProductUnit.KG.value == "kg"
        assert ProductUnit.GRAM.value == "gram"
        assert ProductUnit.LITER.value == "liter"
        assert ProductUnit.MILLILITER.value == "milliliter"
        assert ProductUnit.METER.value == "meter"
        assert ProductUnit.PACK.value == "pack"


class TestSaleStatus:
    def test_values(self):
        assert SaleStatus.COMPLETED.value == "completed"
        assert SaleStatus.VOID.value == "void"


class TestPaymentMethod:
    def test_values(self):
        assert PaymentMethod.CASH.value == "cash"
        assert PaymentMethod.CARD.value == "card"
        assert PaymentMethod.CREDIT.value == "credit"
        assert PaymentMethod.PARTIAL.value == "partial"


class TestReturnReason:
    def test_values(self):
        assert ReturnReason.DEFECTIVE.value == "defective"
        assert ReturnReason.WRONG_ITEM.value == "wrong_item"
        assert ReturnReason.CUSTOMER_CHANGE.value == "customer_change"
        assert ReturnReason.EXPIRED.value == "expired"
        assert ReturnReason.OTHER.value == "other"


class TestStockMovementType:
    def test_values(self):
        assert StockMovementType.SALE.value == "sale"
        assert StockMovementType.SALE_VOID.value == "sale_void"
        assert StockMovementType.PURCHASE.value == "purchase"
        assert StockMovementType.PURCHASE_DELETE.value == "purchase_delete"
        assert StockMovementType.RETURN.value == "return"
        assert StockMovementType.ADJUSTMENT.value == "adjustment"
        assert StockMovementType.PACK_COMPONENT.value == "pack_component"


class TestExpenseCategory:
    def test_values(self):
        assert ExpenseCategory.RENT.value == "rent"
        assert ExpenseCategory.UTILITIES.value == "utilities"
        assert ExpenseCategory.SALARY.value == "salary"


class TestExpenseStatus:
    """Phase 13 GATE 1 — the only two expense states."""

    def test_values(self):
        assert ExpenseStatus.POSTED.value == "posted"
        assert ExpenseStatus.CANCELLED.value == "cancelled"

    def test_member_count(self):
        assert len(ExpenseStatus) == 2


class TestDeviceStatus:
    def test_values(self):
        assert DeviceStatus.PENDING.value == "pending"
        assert DeviceStatus.APPROVED.value == "approved"
        assert DeviceStatus.REJECTED.value == "rejected"


class TestAuditAction:
    def test_values(self):
        assert AuditAction.CREATE.value == "create"
        assert AuditAction.UPDATE.value == "update"
        assert AuditAction.DELETE.value == "delete"
        assert AuditAction.LOGIN.value == "login"
        assert AuditAction.LOGOUT.value == "logout"
        assert AuditAction.VOID.value == "void"
        assert AuditAction.RETURN.value == "return"
        assert AuditAction.PAYMENT.value == "payment"
        assert AuditAction.ADJUSTMENT.value == "adjustment"
        assert AuditAction.BACKUP.value == "backup"
        assert AuditAction.RESTORE.value == "restore"


class TestEnumSerialization:
    """All enums should serialize to their string value."""

    def test_str_enum_is_str(self):
        for e in UserRoleEnum:
            assert isinstance(e, str)
            assert e.value == e.name.lower()

    def test_json_serializable(self):
        data = {"role": UserRoleEnum.ADMIN, "status": SaleStatus.COMPLETED}
        serialized = json.dumps(data, default=str)
        assert "admin" in serialized
        assert "completed" in serialized
