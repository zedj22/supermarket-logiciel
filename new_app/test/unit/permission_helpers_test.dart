import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/permission_helpers.dart';

void main() {
  group('AuthUserExtension', () {
    test('hasAnyPermission returns true when user has any of the scopes', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        permissions: ['pos_sale', 'product_view'],
      );
      expect(user.hasAnyPermission(['pos_sale', 'user_manage']), true);
    });

    test('hasAnyPermission returns false when user has none of the scopes', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        permissions: ['pos_sale'],
      );
      expect(user.hasAnyPermission(['user_manage', 'report_financial']), false);
    });

    test('hasAnyPermission with empty list returns false', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        permissions: ['pos_sale'],
      );
      expect(user.hasAnyPermission([]), false);
    });
  });

  group('AuthUser permission checks', () {
    test('admin has all expected roles', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Admin',
        isActive: true,
        roles: ['admin'],
      );
      expect(user.isAdmin, true);
      expect(user.isManager, false);
      expect(user.isCashier, false);
    });

    test('cashier role detection', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Cashier',
        isActive: true,
        roles: ['cashier'],
      );
      expect(user.isCashier, true);
      expect(user.isAdmin, false);
    });

    test('inactive user', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Disabled',
        isActive: false,
        roles: ['admin'],
      );
      expect(user.isActive, false);
    });
  });
}
