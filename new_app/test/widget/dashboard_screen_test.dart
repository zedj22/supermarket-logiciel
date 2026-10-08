// Phase 14 Dashboard (§7 / §17.2): KPI cards straight from the server
// snapshot, recent sales + top products lists, the shared period
// selector, and content-level RBAC (a user without report_financial
// never triggers a dashboard request — §10).
//
// Harness: same full-app login flow as expenses_screen_test. Default
// locale in tests is Arabic (app default).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

/// In-memory credential storage (same harness as expenses_screen_test).
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
const _dashboardPath = '/api/v1/dashboard';

Map<String, dynamic> _loginBody(List<String> scopes, String roleName) => {
      'access_token': 'tok-$roleName',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'roles': [
          {
            'name': roleName,
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _dashboardJson({
  bool withRows = true,
}) =>
    <String, dynamic>{
      'date_from': '2026-09-30',
      'date_to': '2026-09-30',
      'today_sales': '250.500',
      'today_invoices': 3,
      'today_net_profit': '40.000',
      'today_expenses': '10.000',
      'total_products': 120,
      'total_customers': 15,
      'stock_value': '9000.000',
      'low_stock_count': 4,
      'customers_with_debt': 2,
      'total_debt': '150.000',
      'recent_sales': withRows
          ? <Map<String, dynamic>>[
              {
                'sale_id': 's1',
                'invoice_number': 'INV-7',
                'sale_date': '2026-09-30T10:00:00Z',
                'total': '250.500',
                'payment_method': 'cash',
                'customer_name': 'Ali',
              },
            ]
          : <Map<String, dynamic>>[],
      'top_products': withRows
          ? <Map<String, dynamic>>[
              {
                'item_id': 'p1',
                'kind': 'product',
                'name': 'Rice 5kg',
                'net_revenue': '80.000',
                'qty_sold': '4',
                'gross_profit': '20.000',
              },
            ]
          : <Map<String, dynamic>>[],
    };

const _emptyBody = <String, dynamic>{
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 25,
  'pages': 1,
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

  void stubRequests(
    MockDio dio, {
    List<String> scopes = const ['report_financial'],
    String roleName = 'admin',
    bool emptyLists = false,
    List<String>? dashboardPathLog,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody(scopes, roleName));
        }
        return okResponse(path, <String, dynamic>{'message': 'ok'});
      },
    );

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _dashboardPath) {
        dashboardPathLog?.add(path);
        return okResponse(path, _dashboardJson(withRows: !emptyLists));
      }
      if (path.startsWith('/api/v1/reports/')) {
        return okResponse(path, _emptyBody);
      }
      return okResponse(path, _emptyBody);
    });
    when(() => dio.get(any())).thenAnswer((invocation) async =>
        okResponse(invocation.positionalArguments.first as String,
            _emptyBody));

    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/setup/check', {
        'setup_needed': false,
      }),
    );
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/login-users', {
        'items': [
          {
            'id': '00000000-0000-0000-0000-0000000000a1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': roleName},
            ],
          },
        ],
        'total': 1,
      }),
    );
  }

  Future<ProviderContainer> pumpLogin(
    WidgetTester tester,
    MockDio dio,
  ) async {
    tester.view.physicalSize = const Size(2200, 1200);
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

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Finder railLabel(String label) => find.descendant(
        of: find.byType(AppNavRail),
        matching: find.text(label),
      );

  group('Dashboard (§7) — report viewer', () {
    testWidgets('renders server KPIs, recent sales and top products',
        (tester) async {
      final dio = MockDio();
      final log = <String>[];
      stubRequests(dio, dashboardPathLog: log);
      await pumpLogin(tester, dio);

      expect(find.byKey(const Key('dashboard-content')), findsOneWidget);
      expect(log, hasLength(1), reason: 'one snapshot per load');

      // §7 KPI cards — values are the server strings, formatted only.
      for (final label in [
        'kpi_today_sales',
        'kpi_invoices',
        'kpi_today_profit',
        'kpi_today_expenses',
        'kpi_total_products',
        'kpi_total_customers',
        'kpi_stock_value',
        'kpi_low_stock',
        'kpi_customers_with_debt',
        'kpi_total_debt',
      ]) {
        expect(find.byKey(Key('kpi-$label')), findsOneWidget,
            reason: 'missing KPI card: $label');
      }
      expect(
        tester
            .widget<Text>(find.byKey(const Key('kpi-kpi_today_sales-value')))
            .data,
        // formatMoney only trims trailing zeros (display rule) — the
        // server's decimal string is never recomputed.
        '250.5',
      );

      // Recent sales list (§7, capped at 5 server-side).
      expect(find.byKey(const Key('dashboard-recent')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-recent-0')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-recent-total-0')), findsOneWidget);
      expect(find.text('INV-7'), findsOneWidget);

      // Top products (§7, capped at 5 server-side).
      expect(find.byKey(const Key('dashboard-top')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-top-0')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-top-name-0')), findsOneWidget);
      // The name appears in the bar chart label AND the detail row.
      expect(find.byKey(const Key('top-bar-0-label')), findsOneWidget);
      expect(find.text('Rice 5kg'), findsNWidgets(2));

      // Period selector + secondary link to /reports (C7).
      expect(find.byKey(const Key('dashboard-preset-today')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-reports-link')), findsOneWidget);

      // The rail gained the gated Reports destination for this scope.
      expect(railLabel(AppStrings.t('reports', 'ar')), findsOneWidget);
    });

    testWidgets('period preset change reloads the snapshot',
        (tester) async {
      final dio = MockDio();
      final log = <String>[];
      stubRequests(dio, dashboardPathLog: log);
      await pumpLogin(tester, dio);
      expect(log, hasLength(1));

      await tester.tap(find.byKey(const Key('dashboard-preset-today')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('dashboard-preset-item-yesterday')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dashboard-preset-yesterday')),
          findsOneWidget);
      expect(log, hasLength(2), reason: 'filter change → new snapshot');
    });

    testWidgets('empty recent/top lists show the empty state',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, emptyLists: true);
      await pumpLogin(tester, dio);

      expect(find.byKey(const Key('dashboard-content')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-recent-empty')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-top-empty')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-recent')), findsNothing);
      expect(find.byKey(const Key('dashboard-top')), findsNothing);
    });

    testWidgets('secondary reports link navigates to /reports',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);

      await tester.tap(find.byKey(const Key('dashboard-reports-link')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reports-screen')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-content')), findsNothing);
    });
  });

  group('Dashboard (§7) — RBAC (§10)', () {
    testWidgets('no report scope: denied view, zero dashboard requests',
        (tester) async {
      final dio = MockDio();
      final log = <String>[];
      stubRequests(
        dio,
        scopes: ['expense_view'],
        roleName: 'cashier',
        dashboardPathLog: log,
      );
      await pumpLogin(tester, dio);

      // Content-level denial (no redirect guard exists for any route).
      expect(find.byKey(const Key('dashboard-denied')), findsOneWidget);
      expect(find.text(AppStrings.t('permission_denied', 'ar')), findsOneWidget);
      expect(find.byKey(const Key('dashboard-content')), findsNothing);

      // Never fetched KPIs it may not see.
      expect(log, isEmpty);

      // No rail entry either.
      expect(railLabel(AppStrings.t('reports', 'ar')), findsNothing);

      // Deep link shows the same denial, not the money screen.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(routerProvider).go('/reports');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reports-denied')), findsOneWidget);
      expect(log, isEmpty);
    });
  });
}
