// Every launch of the desktop app must ask who is using it and verify that
// user's PIN — a persisted session must never walk into the shell.
//
// Cold start therefore lands on the existing account-selection login screen
// on EVERY run (with or without a saved access/refresh token), an account
// tap opens the PIN pad, a wrong PIN is refused, the right PIN logs that
// account in with its own role/permissions, ordinary navigation afterwards
// never re-prompts, and logout returns to the login screen.
//
// The real `SecureCredentialStorage` is used here against
// `FlutterSecureStorage`'s in-memory test platform, so the seeded keys are
// the actual keystore key names the app reads and writes.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/dashboard/dashboard_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

const _setupPath = '/api/v1/auth/setup/check';
const _loginUsersPath = '/api/v1/auth/login-users';
const _loginPath = '/api/v1/auth/login';
const _logoutPath = '/api/v1/auth/logout';
const _verifyPath = '/api/v1/auth/verify-token';
const _mePath = '/api/v1/auth/me';
const _usersPath = '/api/v1/users';

/// Keystore keys written by `SecureCredentialStorage`.
const _tokenKey = 'auth_access_token';
const _refreshKey = 'auth_refresh_token';
const _userNameKey = 'auth_user_name';

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(Options());
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  MockDio buildDio() {
    final dio = MockDio();
    // Whoever logged in last — `/auth/me` must answer for that account so a
    // cashier cannot inherit the admin scopes stubbed for another test.
    var meId = 'u1';
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    // Generic list fallbacks, registered BEFORE the specific stubs below
    // (mocktail resolves with the most recently registered match).
    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer(
      (invocation) async => _ok(
        invocation.positionalArguments.first as String,
        {
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 100,
          'pages': 1,
        },
      ),
    );
    when(() => dio.get(any())).thenAnswer(
      (invocation) async => _ok(
        invocation.positionalArguments.first as String,
        {'items': <dynamic>[], 'total': 0},
      ),
    );
    when(() => dio.get(_setupPath))
        .thenAnswer((_) async => _ok(_setupPath, {'setup_needed': false}));
    when(() => dio.get(_loginUsersPath)).thenAnswer(
      (_) async => _ok(_loginUsersPath, {
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
      }),
    );
    when(() => dio.get(_usersPath)).thenAnswer(
      (_) async => _ok(_usersPath, {
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
      }),
    );
    when(() => dio.get(_mePath)).thenAnswer(
      (_) async => _ok(_mePath, {
        'id': meId,
        'full_name': meId == 'u2' ? 'Cashier' : 'Admin',
        'is_active': true,
        'roles': [
          {'name': meId == 'u2' ? 'cashier' : 'admin'},
        ],
        'permissions':
            meId == 'u2' ? ['pos_sale'] : ['user_manage', 'pos_sale'],
      }),
    );
    // The one accepted PIN is 1234; every other PIN is a 401 refusal.
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final body = invocation.namedArguments[#data] as Map;
        if (body['pin'] != '1234') {
          throw DioException(
            requestOptions: RequestOptions(path: _loginPath),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: _loginPath),
              statusCode: 401,
              data: {
                'error': {'code': 'INVALID_PIN', 'message': 'Invalid PIN'},
              },
            ),
          );
        }
        final cashier = body['user_id'] == 'u2';
        meId = cashier ? 'u2' : 'u1';
        return _ok(_loginPath, {
          'access_token': cashier ? 'tok-cashier' : 'tok-admin',
          'expires_in': 3600,
          'user': {
            'id': cashier ? 'u2' : 'u1',
            'full_name': cashier ? 'Cashier' : 'Admin',
            'is_active': true,
            'roles': [
              {'name': cashier ? 'cashier' : 'admin'},
            ],
            'permissions': cashier ? ['pos_sale'] : ['user_manage', 'pos_sale'],
          },
        });
      },
    );
    when(() => dio.post(_logoutPath, data: any(named: 'data')))
        .thenAnswer((_) async => _ok(_logoutPath, {'message': 'ok'}));
    return dio;
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester, MockDio dio) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(SecureCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> typePin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
  }

  Future<void> loginAs(WidgetTester tester, String name,
      {String pin = '1234'}) async {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    await typePin(tester, pin);
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
  }

  Future<String?> stored(String key) =>
      const FlutterSecureStorage().read(key: key);

  group('every launch starts at the login screen', () {
    testWidgets('a previously saved session does not enter the app',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        _tokenKey: 'tok-saved',
        _userNameKey: 'Admin',
      });
      final dio = buildDio();

      final container = await pumpApp(tester, dio);

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'ar')), findsOneWidget);
      expect(find.byType(ScaffoldWithNav), findsNothing);
      expect(find.byType(DashboardScreen), findsNothing);
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(container.read(currentUserProvider), isNull);
      // The stored credential is never proven against the backend…
      verifyNever(() => dio.post(_verifyPath, data: any(named: 'data')));
      verifyNever(() => dio.get(_mePath));
      verifyNever(() => dio.get(_usersPath));
      // …and it is dropped instead of lingering as a future bypass.
      expect(await stored(_tokenKey), isNull);
      expect(container.read(apiClientProvider).hasToken, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a valid access token alone is not a session', (tester) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        _tokenKey: 'tok-saved',
      });
      final dio = buildDio();

      final container = await pumpApp(tester, dio);

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ScaffoldWithNav), findsNothing);
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a valid refresh token alone is not a session', (tester) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        _refreshKey: 'refresh-saved',
      });
      final dio = buildDio();

      final container = await pumpApp(tester, dio);

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ScaffoldWithNav), findsNothing);
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(find.text('Admin'), findsOneWidget,
          reason: 'the accounts still come from the backend');
      expect(tester.takeException(), isNull);
    });
  });

  group('account selection and PIN', () {
    testWidgets('selecting an account asks for its PIN before any login call',
        (tester) async {
      final dio = buildDio();
      await pumpApp(tester, dio);

      await tester.tap(find.text('Cashier'));
      await tester.pumpAndSettle();

      expect(find.text('Cashier'), findsOneWidget);
      expect(find.byKey(const Key('login-submit-button')), findsOneWidget);
      final submit = tester.widget<ElevatedButton>(
        find.byKey(const Key('login-submit-button')),
      );
      expect(submit.onPressed, isNull,
          reason: 'no PIN typed yet — the button must stay disabled');
      verifyNever(() => dio.post(_loginPath, data: any(named: 'data')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the correct PIN logs the selected user in', (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      await loginAs(tester, 'Admin');

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(ScaffoldWithNav), findsOneWidget);
      expect(container.read(authProvider).status, AuthStatus.authenticated);
      expect(container.read(currentUserProvider)?.fullName, 'Admin');
      expect(await stored(_tokenKey), 'tok-admin',
          reason: 'a successful login persists the fresh session normally');
      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an incorrect PIN is refused and grants nothing',
        (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      // Distinct digits: a repeated digit is ambiguous to `find.text`
      // because the PIN field echoes the typed value too.
      await loginAs(tester, 'Admin', pin: '9876');

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(ScaffoldWithNav), findsNothing);
      expect(container.read(authProvider).status, isNot(AuthStatus.authenticated));
      expect(container.read(currentUserProvider), isNull);
      expect(await stored(_tokenKey), isNull);
      expect(container.read(apiClientProvider).hasToken, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('after a successful login', () {
    testWidgets('the selected user keeps their own permissions (cashier)',
        (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      await loginAs(tester, 'Cashier');

      expect(find.byType(ScaffoldWithNav), findsOneWidget);
      expect(container.read(currentUserProvider)?.roles, contains('cashier'));
      expect(
        container.read(currentUserProvider)?.hasPermission('user_manage'),
        isFalse,
      );
      expect(find.text(AppStrings.t('user_list', 'ar')), findsNothing);
      verifyNever(() => dio.get(_usersPath));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the admin keeps user_manage after logging in', (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      await loginAs(tester, 'Admin');

      expect(
        container.read(currentUserProvider)?.hasPermission('user_manage'),
        isTrue,
      );
      expect(find.text(AppStrings.t('user_list', 'ar')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('user_list', 'ar')));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('normal navigation never re-prompts for login',
        (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      await loginAs(tester, 'Admin');
      expect(container.read(authProvider).status, AuthStatus.authenticated);

      container.read(routerProvider).go('/products');
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(container.read(authProvider).status, AuthStatus.authenticated);
      expect(find.byType(ScaffoldWithNav), findsOneWidget);
      // The login screen was never re-mounted, so discovery/login ran once.
      verify(() => dio.get(_loginUsersPath)).called(1);
      verify(() => dio.post(_loginPath, data: any(named: 'data'))).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('logout returns to the login screen and clears the session',
        (tester) async {
      final dio = buildDio();
      final container = await pumpApp(tester, dio);

      await loginAs(tester, 'Admin');
      expect(await stored(_tokenKey), 'tok-admin');

      await tester.tap(find.byKey(const Key('logout-button')));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text(AppStrings.t('select_user', 'ar')), findsOneWidget);
      expect(find.byType(ScaffoldWithNav), findsNothing);
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(await stored(_tokenKey), isNull);
      expect(container.read(apiClientProvider).hasToken, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
