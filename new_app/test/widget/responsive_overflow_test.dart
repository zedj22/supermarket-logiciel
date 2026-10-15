// Responsive overflow suite — Windows desktop layout regression tests.
//
// Human QA (flutter run -d windows) reported RenderFlex overflows on the
// real app at its default window size (~1127x720 logical, Arabic RTL):
// expenses filter row (365px), invoice-clients header, POS toolbar,
// promotions / suppliers / clients headers, reports metric cards and
// more. This suite pumps the FULL app (login → shell → every route) at
// the widths that reproduce those failures and asserts:
//  - no RenderFlex overflow exceptions at 1280 / 1127 / 1024 / 800;
//  - key controls stay visible and usable after the responsive layout
//    (Wrap / flexible halves) kicks in;
//  - the same holds in English (LTR) as in the default Arabic (RTL);
//  - 600x500 is clean on the screens that support that size (Products
//    and POS already did; the fixed list screens do now).
//
// Convention: products_responsive_test.dart (login at a comfortable size
// first, then resize; expectNoOverflow via takeException).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

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

/// Every scope that gates a shell destination — the worst case for every
/// header / filter bar (all buttons rendered).
const _allScopes = [
  'pos_sale',
  'pos_return',
  'pos_credit_sale',
  'pos_discount',
  'pos_void',
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_manage',
  'inventory_view',
  'inventory_adjust',
  'customer_view',
  'customer_manage',
  'supplier_view',
  'supplier_manage',
  'purchase_view',
  'purchase_create',
  'purchase_delete',
  'promotion_view',
  'promotion_create',
  'promotion_update',
  'user_manage',
  'report_financial',
  'export_data',
  'facturation_view',
  'expense_view',
  'expense_create',
  'expense_cancel',
  'audit_view',
];

const _routes = [
  '/',
  '/pos',
  '/returns',
  '/expenses',
  '/clients',
  '/products',
  '/packs',
  '/promotions',
  '/stock',
  '/sales',
  '/debts',
  '/suppliers',
  '/purchases',
  '/facturation',
  '/invoice-clients',
  '/reports',
  '/users',
  '/devices',
  '/audit-log',
  '/settings',
  '/about',
  '/documentation',
];

/// 600x500 is only expected on screens whose chrome fits a 500px-tall
/// window (Products and POS already supported it; the list screens do
/// now). Expenses / Stock / Audit keep a taller fixed chrome (summary +
/// filters above the list) and are documented as needing >= ~700px
/// height — out of this suite's scope.
const _routesAt600 = [
  '/pos',
  '/products',
  '/clients',
  '/suppliers',
  '/promotions',
  '/invoice-clients',
  '/returns',
  '/users',
  '/debts',
  '/about',
  '/reports',
  '/',
];

const _emptyBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 25,
  'pages': 1,
};

Map<String, dynamic> _loginBody() => {
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
              for (final s in _allScopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _summaryBody() => {
      'count': 0,
      'total_amount': '0',
      'drawer_amount': '0',
      'external_amount': '0',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  void stubRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == '/api/v1/auth/login') {
          return okResponse('/api/v1/auth/login', _loginBody());
        }
        return okResponse(path, {'message': 'ok'});
      },
    );

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/expenses/summary') {
        return okResponse(path, _summaryBody());
      }
      return okResponse(path, _emptyBody);
    });

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/auth/setup/check') {
        return okResponse(path, {'setup_needed': false});
      }
      if (path == '/api/v1/auth/login-users') {
        return okResponse(path, {
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
        });
      }
      return okResponse(path, _emptyBody);
    });
  }

  /// Logs in at a comfortable size (the PIN pad does not fit 600×500),
  /// then switches to the target size — same as products_responsive_test.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required Size size,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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

    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
    expect(find.byType(AppNavRail), findsOneWidget, reason: 'login worked');

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpAndSettle();

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<void> visit(
    WidgetTester tester,
    ProviderContainer container,
    String route,
  ) async {
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();
  }

  void expectNoOverflow(WidgetTester tester) {
    expect(
      tester.takeException(),
      isNull,
      reason: 'no RenderFlex overflow allowed (got the exception above)',
    );
  }

  for (final entry in const <String, Size>{
    '1280x800': Size(1280, 800),
    '1127x720': Size(1127, 720),
    '1024x720': Size(1024, 720),
    '800x700': Size(800, 700),
  }.entries) {
    testWidgets('every route lays out without overflow at ${entry.key}',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpApp(tester, dio, size: entry.value);

      for (final route in _routes) {
        await visit(tester, container, route);
        expectNoOverflow(tester);
      }
    });

    testWidgets('affected screens keep their key controls at ${entry.key}',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpApp(tester, dio, size: entry.value);

      await visit(tester, container, '/expenses');
      expect(find.byKey(const Key('expenses-search')), findsOneWidget);
      expect(find.byKey(const Key('expenses-add')), findsOneWidget);
      expect(find.byKey(const Key('expenses-refresh')), findsOneWidget);
      expect(
        find.byKey(const Key('expenses-status-filter')),
        findsOneWidget,
      );
      expectNoOverflow(tester);

      await visit(tester, container, '/invoice-clients');
      expect(
        find.byKey(const Key('invoice-clients-search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('invoice-clients-add-button')),
        findsOneWidget,
      );
      expectNoOverflow(tester);

      await visit(tester, container, '/clients');
      expect(find.byKey(const Key('clients-search')), findsOneWidget);
      expect(find.byKey(const Key('clients-add-button')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/suppliers');
      expect(find.byKey(const Key('suppliers-search')), findsOneWidget);
      expect(find.byKey(const Key('suppliers-add-button')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/promotions');
      expect(find.byKey(const Key('promotions-search')), findsOneWidget);
      expect(find.byKey(const Key('promotions-add')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/pos');
      expect(find.byKey(const Key('pos-packs-button')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/reports');
      expect(find.byKey(const Key('reports-filter-card')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/returns');
      expect(
        find.byKey(const Key('returns-filter-invoice')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('returns-return-products')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/debts');
      expect(find.byKey(const Key('debts-summary')), findsOneWidget);
      expectNoOverflow(tester);

      await visit(tester, container, '/');
      expect(find.byKey(const Key('dashboard-range')), findsOneWidget);
      expectNoOverflow(tester);
    });
  }

  testWidgets('English (LTR) matches Arabic (RTL): no overflow at 1127x720',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: const Size(1127, 720));

    // Default locale is Arabic — exercise the affected screens.
    for (final route in const ['/expenses', '/reports', '/invoice-clients']) {
      await visit(tester, container, route);
      expectNoOverflow(tester);
    }

    // Switch to English (LTR) and repeat.
    container.read(localeProvider.notifier).setLocale(AppLocale.en);
    await tester.pumpAndSettle();
    for (final route in const ['/expenses', '/reports', '/invoice-clients']) {
      await visit(tester, container, route);
      expectNoOverflow(tester);
    }
    await visit(tester, container, '/expenses');
    expect(find.byKey(const Key('expenses-search')), findsOneWidget);
  });

  testWidgets('600x500: supported screens lay out without overflow',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio, size: const Size(600, 500));

    for (final route in _routesAt600) {
      await visit(tester, container, route);
      expectNoOverflow(tester);
    }
  });
}
