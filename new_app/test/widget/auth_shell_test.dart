import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/dashboard/dashboard_screen.dart';
import 'package:supermarket_pos/features/products/products_screen.dart';
import 'package:supermarket_pos/features/users/users_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
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
const _logoutPath = '/api/v1/auth/logout';
const _usersPath = '/api/v1/users';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(Options());
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
        'the header wordmark is the generic product name in ar / fr / en, '
        'with the direction each locale needs', (tester) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      stubBootRequests(dio);
      stubLogin(dio, adminLoginResponse);

      final container = await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');

      // Default locale is Arabic: the generic wordmark, laid out RTL.
      final ar = find.text('نظام تسيير المحلات');
      expect(ar, findsOneWidget);
      expect(Directionality.of(tester.element(ar)), TextDirection.rtl);

      // French keeps the same alignment and typography, LTR.
      container.read(localeProvider.notifier).setLocale(AppLocale.fr);
      await tester.pumpAndSettle();
      final fr = find.text('Système de gestion des commerces');
      expect(fr, findsOneWidget);
      expect(Directionality.of(tester.element(fr)), TextDirection.ltr);

      // English mirrors French: one wordmark Text, LTR.
      container.read(localeProvider.notifier).setLocale(AppLocale.en);
      await tester.pumpAndSettle();
      final en = find.text('Store Management System');
      expect(en, findsOneWidget);
      expect(Directionality.of(tester.element(en)), TextDirection.ltr);

      // The old supermarket wording is gone from the header entirely.
      for (final stale in ['نقطة بيع السوبرماركت', 'Supermarché POS']) {
        expect(find.text(stale), findsNothing);
      }
    });

    testWidgets(
        'renders app title, current user name and roles, logout, and dashboard screen',
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
      expect(find.byType(AppNavRail), findsOneWidget);
      expect(find.byType(DashboardScreen), findsOneWidget);
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

      // Logout authenticates with the bearer header: the JWT must never
      // travel in a body/query any more.
      final options = verify(
        () => dio.post(
          _logoutPath,
          data: any(named: 'data'),
          options: captureAny(named: 'options'),
        ),
      ).captured.single as Options;
      expect(options.headers?['Authorization'], startsWith('Bearer '));
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
      expect(find.byType(DashboardScreen), findsNothing);
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
      expect(find.byType(DashboardScreen), findsOneWidget);

      // …but Users navigation is hidden.
      expect(find.text(AppStrings.t('user_list', 'ar')), findsNothing);
      expect(find.byType(UsersScreen), findsNothing);
      verifyNever(() => dio.get(_usersPath));
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 17 §18 — the global keyboard map
  // ---------------------------------------------------------------------------
  group('Phase 17 §18 — global keyboard shortcuts', () {
    /// Admin carrying every scope the map needs (`pos_sale`, `product_view`,
    /// `product_create`) — F3 is permission-gated, so without
    /// `product_create` the shortcut must stay a no-op.
    Response<dynamic> fullAdminLoginResponse() => Response<dynamic>(
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
              'permissions': [
                'user_manage',
                'pos_sale',
                'product_view',
                'product_create',
              ],
            },
          },
          statusCode: 200,
        );

    Response<dynamic> emptyList(String path) => Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          data: {'items': <dynamic>[], 'total': 0},
          statusCode: 200,
        );

    /// Every route the map can jump to loads lists on mount. Stub them all
    /// so these tests measure navigation, not error handling; [getLog] records
    /// each path so F5 can be shown to actually re-issue a request.
    void stubListEndpoints(MockDio dio, {List<String>? getLog}) {
      String record(Invocation invocation) {
        final path = invocation.positionalArguments.first as String;
        getLog?.add(path);
        return path;
      }

      when(() => dio.get(any())).thenAnswer(
        (invocation) async => emptyList(record(invocation)),
      );
      when(
        () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
      ).thenAnswer((invocation) async => emptyList(record(invocation)));
    }

    /// Put the keyboard focus INSIDE the shell. Right after login the primary
    /// focus is the Navigator's scope, which sits *above* the shell's
    /// shortcut layer — without this a raw key press would never reach it.
    Future<void> focusShell(WidgetTester tester) async {
      final node = Focus.maybeOf(
        tester.element(find.byKey(const Key('shortcuts-help-button'))),
        createDependency: false,
      );
      expect(node, isNotNull, reason: 'shell must own a focus node');
      node!.requestFocus();
      await tester.pump();
    }

    Future<bool> press(WidgetTester tester, LogicalKeyboardKey key) async {
      final handled = await tester.sendKeyEvent(key);
      await tester.pump();
      return handled;
    }

    Future<bool> pressCtrl(
      WidgetTester tester,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final handled = await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      return handled;
    }

    Future<ProviderContainer> boot(WidgetTester tester) async {
      final dio = MockDio();
      stubListEndpoints(dio);
      stubBootRequests(dio);
      stubLogin(dio, fullAdminLoginResponse);
      final container = await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');
      expect(find.byType(DashboardScreen), findsOneWidget);
      await focusShell(tester);
      return container;
    }

    testWidgets('F1 opens the POS screen', (tester) async {
      useDesktopViewport(tester);
      final container = await boot(tester);

      expect(await press(tester, LogicalKeyboardKey.f1), isTrue);
      await tester.pumpAndSettle();

      expect(container.read(routerProvider).state.uri.path, '/pos');
      expect(find.byKey(const Key('pos-screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F2 opens the Products screen', (tester) async {
      useDesktopViewport(tester);
      final container = await boot(tester);

      expect(await press(tester, LogicalKeyboardKey.f2), isTrue);
      await tester.pumpAndSettle();

      expect(container.read(routerProvider).state.uri.path, '/products');
      expect(find.byType(ProductsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F3 opens the add-product form', (tester) async {
      useDesktopViewport(tester);
      await boot(tester);

      expect(await press(tester, LogicalKeyboardKey.f3), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ctrl+N opens the add-product form', (tester) async {
      useDesktopViewport(tester);
      await boot(tester);

      expect(await pressCtrl(tester, LogicalKeyboardKey.keyN), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F4 / Ctrl+F focus the current page search field', (
      tester,
    ) async {
      useDesktopViewport(tester);
      final container = await boot(tester);
      expect(await press(tester, LogicalKeyboardKey.f2), isTrue);
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).state.uri.path, '/products');

      await focusShell(tester);
      expect(await press(tester, LogicalKeyboardKey.f4), isTrue);
      expect(
        _focusedFieldKey(tester),
        'products-search-field',
        reason: 'F4 must reach the page, not just the shell',
      );

      await focusShell(tester);
      expect(await pressCtrl(tester, LogicalKeyboardKey.keyF), isTrue);
      expect(_focusedFieldKey(tester), 'products-search-field');
      expect(tester.takeException(), isNull);
    });

    testWidgets('F5 refreshes the current page and never clears state', (
      tester,
    ) async {
      useDesktopViewport(tester);
      final dio = MockDio();
      final productGets = <String>[];
      stubListEndpoints(dio, getLog: productGets);
      stubBootRequests(dio);
      stubLogin(dio, fullAdminLoginResponse);
      await pumpFullApp(tester, dio);
      await loginAs(tester, 'Admin');
      expect(await press(tester, LogicalKeyboardKey.f2), isTrue);
      await tester.pumpAndSettle();

      await focusShell(tester);
      final before = productGets
          .where((p) => p == '/api/v1/products')
          .length;
      expect(await press(tester, LogicalKeyboardKey.f5), isTrue);
      await tester.pumpAndSettle();

      expect(
        productGets.where((p) => p == '/api/v1/products').length,
        greaterThan(before),
        reason: 'F5 must re-issue the page load',
      );
      expect(find.byType(ProductsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the AppBar shortcuts button opens the localized map', (
      tester,
    ) async {
      useDesktopViewport(tester);
      await boot(tester);

      await tester.tap(find.byKey(const Key('shortcuts-help-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('shortcuts_title', 'ar')),
        findsOneWidget,
      );
      // Both scopes and every row of the map are rendered. Scoped to the
      // dialog: the POS screen underneath carries its own Space key chip
      // on the PAY button, so a bare find.text would count both.
      final map = find.byKey(const Key('shortcuts-dialog'));
      expect(
        find.descendant(of: map, matching: find.text('Space / F8')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: map, matching: find.text('F12')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('shortcuts_scope_pos', 'ar')),
        findsWidgets,
      );

      await tester.tap(find.byKey(const Key('shortcuts-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcuts-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Value key of the focused text field, if the focus is on one.
String? _focusedFieldKey(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final field = context.widget is TextField
      ? context.widget as TextField
      : context.findAncestorWidgetOfExactType<TextField>();
  final key = field?.key;
  return key is ValueKey<String> ? key.value : null;
}
