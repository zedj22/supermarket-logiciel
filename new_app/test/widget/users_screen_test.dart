import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/users/users_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Stateful in-memory credential storage for the full-app login flow.
class FakeCredentialStorage extends SecureCredentialStorage {
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
const _usersPath = '/api/v1/users';

/// Real LoginResponse: permissions nested under roles only.
Map<String, dynamic> _realisticAdminLoginBody() => {
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
            ],
          },
        ],
      },
    };

Map<String, dynamic> _usersListBody() => {
      'items': [
        {
          'id': '00000000-0000-0000-0000-0000000000a1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': [
            {'name': 'admin'},
          ],
        },
        {
          'id': '00000000-0000-0000-0000-0000000000c1',
          'full_name': 'Cashier Ali',
          'is_active': true,
          'roles': [
            {'name': 'cashier'},
          ],
        },
      ],
      'total': 2,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  void stubRequests(MockDio dio) {
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
              'id': '00000000-0000-0000-0000-0000000000a1',
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
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: _realisticAdminLoginBody(),
        statusCode: 200,
      ),
    );
    when(() => dio.post('/api/v1/auth/logout-token',
            data: any(named: 'data')))
        .thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/auth/logout-token'),
        statusCode: 200,
        data: {'message': 'logged out'},
      ),
    );
    when(() => dio.get(_usersPath)).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _usersPath),
        data: _usersListBody(),
        statusCode: 200,
      ),
    );
    when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/users/x'),
        statusCode: 200,
        data: {},
      ),
    );
    when(() => dio.delete(any())).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/users/x'),
        statusCode: 200,
        data: {},
      ),
    );
  }

  Future<ProviderContainer> pumpAppAsAdmin(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dio = MockDio();
    stubRequests(dio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Select Admin and log in (4-digit PIN).
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    // Navigate to Users via the shell rail.
    await tester.tap(find.text(AppStrings.t('user_list', 'ar')));
    await tester.pumpAndSettle();

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  group('Users screen (reachable from shell, admin session)', () {
    testWidgets('loads via authenticated GET /api/v1/users and lists users',
        (tester) async {
      final container = await pumpAppAsAdmin(tester);

      expect(find.byType(UsersScreen), findsOneWidget);
      expect(find.text('Admin'), findsWidgets);
      expect(find.text('Cashier Ali'), findsOneWidget);

      final dio = container.read(apiClientProvider).dio;
      verify(() => dio.get(_usersPath)).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Create User UI is reachable with working role selection',
        (tester) async {
      await pumpAppAsAdmin(tester);

      await tester.tap(
        find.widgetWithText(ElevatedButton, AppStrings.t('create_user', 'ar')),
      );
      await tester.pumpAndSettle();

      // Dialog open with name/PIN fields and role dropdown.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

      // Change role from default cashier → manager.
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.t('manager', 'ar')).last);
      await tester.pumpAndSettle();

      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.initialValue, 'manager');
      expect(tester.takeException(), isNull);
    });

    testWidgets('active/inactive control (Switch) is reachable per user',
        (tester) async {
      await pumpAppAsAdmin(tester);

      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(2)); // one per listed user
      final first = tester.widget<Switch>(switches.first);
      expect(first.value, isTrue); // active users from the stub
      expect(tester.takeException(), isNull);
    });

    testWidgets('delete confirmation dialog is reachable from row menu',
        (tester) async {
      final container = await pumpAppAsAdmin(tester);
      final dio = container.read(apiClientProvider).dio;

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.t('delete', 'ar')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(AppStrings.t('delete_user_confirm', 'ar')),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(
          TextButton,
          AppStrings.t('confirm', 'ar'),
        ),
        findsOneWidget,
      );

      // Confirm → DELETE issued, then list reloads.
      await tester.tap(find.widgetWithText(
        TextButton,
        AppStrings.t('confirm', 'ar'),
      ));
      await tester.pumpAndSettle();

      verify(() => dio.delete(any())).called(1);
      verify(() => dio.get(_usersPath)).called(greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });
  });
}
