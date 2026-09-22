import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/users/users_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

/// Stateful fake: login saves the token, logout reads then clears it.
class ShellCredentialStorage extends SecureCredentialStorage {
  String? _token;
  List<String> _roles = [];
  List<String> _permissions = [];

  @override
  Future<bool> hasToken() async => _token != null && _token!.isNotEmpty;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveToken(String token) async => _token = token;

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async => _roles = roles;

  @override
  Future<void> saveUserPermissions(List<String> permissions) async =>
      _permissions = permissions;

  @override
  Future<List<String>> readUserRoles() async => _roles;

  @override
  Future<List<String>> readUserPermissions() async => _permissions;

  @override
  Future<void> clearAll() async {
    _token = null;
    _roles = [];
    _permissions = [];
  }
}

const _loginPath = '/api/v1/auth/login';
const _logoutPath = '/api/v1/auth/logout-token';
const _usersPath = '/api/v1/users';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  void stubBootRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/setup/check'),
        data: {'setup_needed': false},
        statusCode: 200,
      ),
    );
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
        data: {
          'items': [
            {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
            },
            {
              'id': 'u2',
              'full_name': 'Cashier',
              'is_active': true,
              'roles': [
                {'name': 'cashier'},
              ],
            },
          ],
          'total': 2,
        },
        statusCode: 200,
      ),
    );
    when(() => dio.get(_usersPath)).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _usersPath),
        data: {
          'items': [
            {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
            },
          ],
          'total': 1,
        },
        statusCode: 200,
      ),
    );
  }

  Response<dynamic> adminLoginResponse() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-admin',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
            'permissions': ['user_manage'],
          },
        },
        statusCode: 200,
      );

  /// Real backend LoginResponse shape: UserResponse has NO top-level
  /// `permissions` — scopes nest under roles[].permissions[].scope.
  Response<dynamic> realisticAdminLoginResponse() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-admin',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': '00000000-0000-0000-0000-0000000000a1',
            'full_name': 'Admin',
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
          },
        },
        statusCode: 200,
      );

  Response<dynamic> cashierLoginResponse() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-cashier',
          'expires_in': 3600,
          'user': {
            'id': 'u2',
            'full_name': 'Cashier',
            'is_active': true,
            'roles': [
              {'name': 'cashier'},
            ],
            'permissions': ['pos_sale'],
          },
        },
        statusCode: 200,
      );

  /// Worst case: login user payload carries NO scopes at all
  /// (no top-level permissions, no nested role permissions).
  Response<dynamic> loginWithoutAnyScopes() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-admin',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
          },
        },
        statusCode: 200,
      );

  Response<dynamic> meResponseWithUserManage() => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/me'),
        data: {
          'id': 'u1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': [
            {'name': 'admin'},
          ],
          'permissions': ['user_manage', 'pos_sale'],
        },
        statusCode: 200,
      );

  void stubLogin(MockDio dio, Response<dynamic> Function() response) {
    when(() => dio.post(_loginPath, data: any(named: 'data')))
        .thenAnswer((_) async => response());
    when(() => dio.post(_logoutPath, data: any(named: 'data'))).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _logoutPath),
        statusCode: 200,
        data: {'message': 'logged out'},
      ),
    );
  }

  void useDesktopViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<ProviderContainer> pumpFullApp(
    WidgetTester tester,
    MockDio dio,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(ShellCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> loginAs(WidgetTester tester, String userName) async {
    await tester.tap(find.text(userName));
    await tester.pumpAndSettle();
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
  }

  group('Authenticated shell', () {
    testWidgets(
        'renders app title, current user name and roles, logout, and dashboard placeholder',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      final container = await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      expect(find.text(AppStrings.t('app_name', 'ar')), findsOneWidget);
      expect(find.byKey(const Key('shell-user-name')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('shell-user-name'))).data,
        'Admin',
      );
      expect(find.byKey(const Key('shell-user-roles')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('shell-user-roles'))).data,
        AppStrings.t('admin', 'ar'),
      );
      expect(find.byKey(const Key('logout-button')), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Dashboard - Phase 2'), findsOneWidget);
      expect(container.read(currentUserProvider)?.fullName, 'Admin');
      expect(tester.takeException(), isNull);
    });
  });

  group('Logout', () {
    testWidgets('logout button exists and calls the existing logout flow',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      expect(find.byKey(const Key('logout-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('logout-button')));
      await tester.pumpAndSettle();

      verify(() => dio.post(_logoutPath, data: any(named: 'data'))).called(1);
    });

    testWidgets('logout navigates back to the login screen', (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');
      expect(find.byType(LoginScreen), findsNothing);

      await tester.tap(find.byKey(const Key('logout-button')));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'ar')), findsOneWidget);
      expect(find.text('Dashboard - Phase 2'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('after logout, protected screens cannot be opened',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      final container = await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      await tester.tap(find.byKey(const Key('logout-button')));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      // Attempt to open a protected route directly after logout.
      container.read(routerProvider).go('/users');
      await tester.pumpAndSettle();

      expect(find.byType(UsersScreen), findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
      verifyNever(() => dio.get(_usersPath));
      expect(tester.takeException(), isNull);
    });
  });

  group('Users navigation', () {
    testWidgets(
        'Admin sees Users nav even when login response has permissions only '
        'nested under roles (real backend UserResponse shape)', (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, realisticAdminLoginResponse);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      // user_manage must be derived from roles[].permissions[].scope
      expect(find.text(AppStrings.t('user_list', 'ar')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('user_list', 'ar')));
      await tester.pumpAndSettle();

      verify(() => dio.get(_usersPath)).called(1);
      expect(find.byType(UsersScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Users nav appears from GET /api/v1/auth/me when login payload has no scopes',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      when(() => dio.get('/api/v1/auth/me')).thenAnswer(
        (_) async => meResponseWithUserManage(),
      );
      stubLogin(dio, loginWithoutAnyScopes);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      verify(() => dio.get('/api/v1/auth/me')).called(1);
      expect(find.text(AppStrings.t('user_list', 'ar')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('user_list', 'ar')));
      await tester.pumpAndSettle();

      expect(find.byType(UsersScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Admin sees the Users navigation item and it opens Users',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      expect(find.text(AppStrings.t('user_list', 'ar')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('user_list', 'ar')));
      await tester.pumpAndSettle();

      verify(() => dio.get(_usersPath)).called(1);
      expect(find.byType(UsersScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('user without user_manage permission does not see Users nav',
        (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, cashierLoginResponse);

      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Cashier');

      // Shell still renders with user + logout…
      expect(find.byKey(const Key('shell-user-name')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('shell-user-name'))).data,
        'Cashier',
      );
      expect(find.byKey(const Key('logout-button')), findsOneWidget);
      expect(find.text('Dashboard - Phase 2'), findsOneWidget);

      // …but Users navigation is hidden.
      expect(find.text(AppStrings.t('user_list', 'ar')), findsNothing);
      expect(find.byType(UsersScreen), findsNothing);
      verifyNever(() => dio.get(_usersPath));
      expect(tester.takeException(), isNull);
    });
  });
}
