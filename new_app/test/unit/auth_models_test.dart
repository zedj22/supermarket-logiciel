import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';

void main() {
  group('AuthUser', () {
    test('fromJson parses correctly', () {
      final json = {
        'id': 'uuid-123',
        'full_name': 'Admin User',
        'is_active': true,
        'roles': [
          {'name': 'admin'},
          {'name': 'manager'},
        ],
        'permissions': ['pos_sale', 'product_view', 'user_manage'],
      };
      final user = AuthUser.fromJson(json);
      expect(user.id, 'uuid-123');
      expect(user.fullName, 'Admin User');
      expect(user.isActive, true);
      expect(user.roles, ['admin', 'manager']);
      expect(user.permissions, ['pos_sale', 'product_view', 'user_manage']);
    });

    test('hasPermission returns true for matching scope', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        permissions: ['pos_sale', 'product_view'],
      );
      expect(user.hasPermission('pos_sale'), true);
      expect(user.hasPermission('user_manage'), false);
    });

    test('isAdmin returns true when roles contain admin', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        roles: ['admin'],
      );
      expect(user.isAdmin, true);
      expect(user.isManager, false);
      expect(user.isCashier, false);
    });

    test('isCashier returns true when roles contain cashier', () {
      final user = AuthUser(
        id: '1',
        fullName: 'Test',
        isActive: true,
        roles: ['cashier'],
      );
      expect(user.isCashier, true);
      expect(user.isAdmin, false);
    });

    test('fromJson handles missing fields gracefully', () {
      final json = <String, dynamic>{
        'id': 'uuid-123',
        'full_name': 'Test',
      };
      final user = AuthUser.fromJson(json);
      expect(user.isActive, true);
      expect(user.roles, isEmpty);
      expect(user.permissions, isEmpty);
    });

    test(
        'fromJson extracts permissions nested under roles (login UserResponse shape)',
        () {
      // POST /api/v1/auth/login returns UserResponse: no top-level
      // "permissions" — scopes live at roles[].permissions[].scope.
      final json = {
        'id': 'uuid-123',
        'full_name': 'Admin User',
        'is_active': true,
        'roles': [
          {
            'name': 'admin',
            'permissions': [
              {'id': 'p1', 'scope': 'user_manage', 'description': null},
              {'id': 'p2', 'scope': 'pos_sale', 'description': null},
            ],
          },
        ],
      };
      final user = AuthUser.fromJson(json);
      expect(user.roles, ['admin']);
      expect(user.permissions, containsAll(['user_manage', 'pos_sale']));
      expect(user.hasPermission('user_manage'), true);
    });

    test('fromJson merges top-level and nested permissions without duplicates',
        () {
      final json = {
        'id': 'uuid-1',
        'full_name': 'Admin',
        'roles': [
          {
            'name': 'admin',
            'permissions': ['user_manage', 'pos_sale'],
          },
        ],
        'permissions': ['user_manage', 'product_view'],
      };
      final user = AuthUser.fromJson(json);
      expect(
        user.permissions.toSet(),
        {'user_manage', 'pos_sale', 'product_view'},
      );
      expect(user.permissions.where((p) => p == 'user_manage').length, 1);
    });
  });

  group('LoginResult', () {
    test('fromJson parses correctly', () {
      final json = {
        'access_token': 'jwt-token-abc',
        'expires_in': 28800,
        'user': {
          'id': 'uuid-456',
          'full_name': 'Cashier One',
          'is_active': true,
          'roles': [
            {'name': 'cashier'},
          ],
          'permissions': ['pos_sale'],
        },
      };
      final result = LoginResult.fromJson(json);
      expect(result.accessToken, 'jwt-token-abc');
      expect(result.expiresIn, 28800);
      expect(result.user.id, 'uuid-456');
      expect(result.user.fullName, 'Cashier One');
    });
  });

  group('SetupResult', () {
    test('fromJson parses correctly', () {
      final json = {
        'user_id': 'uuid-789',
        'name': 'Admin',
        'message': 'Admin account created successfully',
      };
      final result = SetupResult.fromJson(json);
      expect(result.userId, 'uuid-789');
      expect(result.name, 'Admin');
    });
  });

  group('UserListItem', () {
    test('fromJson parses correctly', () {
      final json = {
        'id': 'uuid-001',
        'full_name': 'Cashier',
        'is_active': true,
        'roles': [
          {'name': 'cashier'},
        ],
      };
      final item = UserListItem.fromJson(json);
      expect(item.id, 'uuid-001');
      expect(item.fullName, 'Cashier');
      expect(item.isActive, true);
      expect(item.roleNames, ['cashier']);
    });

    test('fromJson handles missing roles', () {
      final json = {
        'id': 'uuid-002',
        'full_name': 'User',
        'is_active': false,
      };
      final item = UserListItem.fromJson(json);
      expect(item.roleNames, isEmpty);
      expect(item.isActive, false);
    });
  });
}
