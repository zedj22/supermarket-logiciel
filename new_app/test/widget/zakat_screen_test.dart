// Zakat screen (widget): RBAC gate, calculator sections, the
// server-authoritative calculate flow (result + warnings), and the
// saved-history tab.
//
// Harness: same full-app login flow as reports_screen_test (mocktail
// Dio + FakeCredentialStorage). Default locale in tests is Arabic.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

/// In-memory credential storage (same harness as reports_screen_test).
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
const _zakatPath = '/api/v1/zakat';
const _contextPath = '/api/v1/zakat/context';
const _calculatePath = '/api/v1/zakat/calculate';

const _viewerScopes = ['report_financial'];

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

Map<String, dynamic> _contextJson() => <String, dynamic>{
      'store_name': 'Klick Market',
      'store_phone': '',
      'store_address': '',
      'today': '2026-10-16',
      'official_nisab_reference': {
        'hijri_year': 1447,
        'amount': '2295000.000',
        'gold_price_per_gram': '27000.000',
        'purity': '18k',
        'source': 'AGENOR',
        'note': 'official',
      },
      'defaults': {
        'zakat_rate': '0.025',
        'hawl_days': 354,
        'nisab_gold_grams': '85',
        'inventory_basis': 'market',
        'debt_treatment': 'deduct_all',
      },
      'inventory': {
        'product_count': 3,
        'total_market_value': '900.000',
        'total_cost_value': '600.000',
        'truncated': false,
        'lines': <dynamic>[],
      },
      'receivables_reference': {
        'ledger_total': '1500.000',
        'debtor_count': 2,
        'debtors': <dynamic>[],
      },
      'liabilities_reference': {
        'supplier_balance_total': '800.000',
        'supplier_count': 1,
        'suppliers': <dynamic>[],
      },
    };

Map<String, dynamic> _calculateJson() => <String, dynamic>{
      'store_name': 'Klick Market',
      'generated_at': '2026-10-16T10:00:00Z',
      'result': <String, dynamic>{
        'zakat_date': '2026-10-16',
        'status': 'final',
        'missing_fields': <dynamic>[],
        'warnings': <dynamic>[
          {
            'code': 'BELOW_NISAB',
            'detail': {'net': '1000.000', 'nisab': '2295000.000'},
          },
        ],
        'hawl_start_date': '2025-10-01',
        'hawl_days_elapsed': 380,
        'hawl_completed': true,
        'gold_price_per_gram': '27000.000',
        'nisab_amount': '2295000.000',
        'nisab_source': 'gold_price',
        'inventory_basis': 'market',
        'inventory_value': '900.000',
        'inventory_source': 'imported',
        'inventory_imported_value': '900.000',
        'inventory_excluded_value': '0.000',
        'inventory_product_count': 3,
        'inventory_included_count': 3,
        'cash_provided': false,
        'cash_total': null,
        'cash_item_count': 0,
        'collectible_receivables': '100.000',
        'doubtful_receivables': null,
        'other_receivables_total': '0.000',
        'receivables_included_total': '100.000',
        'receivable_item_count': 0,
        'debt_treatment': 'deduct_all',
        'liabilities_total_entered': '0.000',
        'deductions_applied': '0.000',
        'liabilities_skipped_amount': '0.000',
        'liabilities_skipped_count': 0,
        'liability_item_count': 0,
        'net_zakatable': '1000.000',
        'zakat_rate': '0.025',
        'zakat_due': '25.000',
        'provisional_zakat_due': null,
        'reaches_nisab': false,
        'eligibility_reasons': ['BELOW_NISAB'],
      },
    };

const _historyJson = <String, dynamic>{
  'items': [
    {
      'id': 'z1',
      'zakat_date': '2026-10-01',
      'status': 'final',
      'net_zakatable': '5100.000',
      'zakat_due': '127.500',
      'provisional_zakat_due': null,
      'nisab_amount': '2295000.000',
      'reaches_nisab': false,
      'hawl_completed': true,
      'payments_total': '100.000',
      'notes': null,
      'created_by': 'u1',
      'created_at': '2026-10-01T10:00:00Z',
    },
  ],
  'total': 1,
  'page': 1,
  'page_size': 40,
  'pages': 1,
};

const _dashboardJson = <String, dynamic>{
  'date_from': '2026-10-16',
  'date_to': '2026-10-16',
  'today_sales': '0.000',
  'today_invoices': 0,
  'today_net_profit': '0.000',
  'today_expenses': '0.000',
  'total_products': 0,
  'total_customers': 0,
  'stock_value': '0.000',
  'low_stock_count': 0,
  'customers_with_debt': 0,
  'total_debt': '0.000',
  'recent_sales': <dynamic>[],
  'top_products': <dynamic>[],
};

const _emptyPage = <String, dynamic>{
  'items': <dynamic>[],
  'total': 0,
  'page': 1,
  'page_size': 100,
  'pages': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  final calculateBodies = <Map<String, dynamic>>[];

  void stubRequests(
    MockDio dio, {
    List<String> scopes = _viewerScopes,
    String roleName = 'admin',
    Map<String, dynamic> Function()? calculateJson,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    calculateBodies.clear();

    when(() => dio.post(any(), data: any(named: 'data')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _loginPath) {
        return okResponse(_loginPath, _loginBody(scopes, roleName));
      }
      if (path == _calculatePath) {
        final data = invocation.namedArguments[#data];
        if (data is Map) {
          calculateBodies.add(Map<String, dynamic>.from(data));
        }
        return okResponse(
          _calculatePath,
          (calculateJson ?? _calculateJson)(),
        );
      }
      if (path == _zakatPath) {
        return okResponse(_zakatPath, <String, dynamic>{}, );
      }
      return okResponse(path, <String, dynamic>{'message': 'ok'});
    });

    when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _zakatPath) return okResponse(path, _historyJson);
      if (path == '/api/v1/dashboard') return okResponse(path, _dashboardJson);
      return okResponse(path, _emptyPage);
    });

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _contextPath) return okResponse(path, _contextJson());
      if (path == _zakatPath) return okResponse(path, _historyJson);
      if (path == '/api/v1/dashboard') {
        return okResponse(path, _dashboardJson);
      }
      return okResponse(path, _emptyPage);
    });

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

  void containerGoZakat(ProviderContainer container) {
    container.read(routerProvider).go('/zakat');
  }

  group('Zakat screen — RBAC', () {
    testWidgets('viewer: rail entry opens the calculator with sections',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpLogin(tester, dio);

      final zakatRail = railLabel(AppStrings.t('zakat', 'ar'));
      expect(zakatRail, findsOneWidget);

      await tester.tap(zakatRail);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('zakat-screen')), findsOneWidget);
      expect(find.byKey(const Key('zakat-title')), findsOneWidget);
      expect(find.byKey(const Key('zakat-tab-calculator')), findsOneWidget);
      expect(find.byKey(const Key('zakat-tab-history')), findsOneWidget);

      // Context seeded: official reference banner + dates card.
      expect(
        find.byKey(const Key('zakat-official-reference')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('zakat-official-nisab-line')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('zakat-section-dates')), findsOneWidget);
      expect(find.byKey(const Key('zakat-section-nisab')), findsOneWidget);
      expect(
        find.byKey(const Key('zakat-section-inventory')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('zakat-section-cash')), findsOneWidget);
      expect(
        find.byKey(const Key('zakat-section-receivables')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('zakat-section-liabilities')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('zakat-calculate')), findsOneWidget);
      expect(find.byKey(const Key('zakat-save')), findsOneWidget);
      expect(find.byKey(const Key('zakat-pdf')), findsOneWidget);

      // Calculation date seeded from the server's `today`.
      final dateField = tester.widget<TextFormField>(
        find.byKey(const Key('zakat-field-date')),
      );
      expect(dateField.controller?.text, '2026-10-16');
    });

    testWidgets('no report scope: no rail entry, deep link shows denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: ['expense_view'], roleName: 'cashier');
      final container = await pumpLogin(tester, dio);

      expect(railLabel(AppStrings.t('zakat', 'ar')), findsNothing);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('zakat-denied')), findsOneWidget);
      expect(find.byKey(const Key('zakat-screen')), findsNothing);
    });
  });

  group('Zakat screen — calculate flow', () {
    testWidgets('entering receivables + calculate shows the server result',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('zakat-field-collectible')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('zakat-field-collectible')),
        '100',
      );
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();

      // Result card from the SERVER's numbers — no client math.
      expect(find.byKey(const Key('zakat-result')), findsOneWidget);
      expect(
        find.byKey(const Key('zakat-result-status')),
        findsOneWidget,
      );
      final net = tester.widget<Text>(
        find.byKey(const Key('zakat-result-net')),
      );
      expect(net.data, contains('1 000'));
      final due = tester.widget<Text>(
        find.byKey(const Key('zakat-result-due')),
      );
      expect(due.data, contains('25'));

      // Warning localized through `zakat_warn_below_nisab` (the tile
      // appends server detail values after the localized text).
      expect(
        find.byKey(const Key('zakat-warn-below_nisab')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          AppStrings.t('zakat_warn_below_nisab', 'ar'),
        ),
        findsOneWidget,
      );

      // Disclaimer always visible on the result.
      expect(find.byKey(const Key('zakat-disclaimer')), findsOneWidget);

      // Payload carried the normalized money string.
      expect(calculateBodies.single['collectible_receivables'], '100.000');
      expect(calculateBodies.single['zakat_date'], '2026-10-16');
    });

    testWidgets('empty required fields block the request', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      // Receivables are required and left empty → validation fails and
      // no calculate request is ever sent.
      await tester.ensureVisible(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();

      expect(calculateBodies, isEmpty);
      expect(find.byKey(const Key('zakat-result')), findsNothing);
    });

    testWidgets(
        'result card values render LTR (bidi: grouped digits + DA stay '
        'in logical order)', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('zakat-field-collectible')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('zakat-field-collectible')),
        '100',
      );
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();

      // The Arabic locale lays every paragraph out RTL by default; the
      // grouped money values (and the trailing `DA`) must opt into an
      // LTR paragraph so the number groups never reorder visually
      // (`DA 577.85 915 895 217` — the reported bug).
      final net = tester.widget<Text>(
        find.byKey(const Key('zakat-result-net')),
      );
      expect(net.textDirection, TextDirection.ltr);
      expect(net.data, contains('1 000'));

      final due = tester.widget<Text>(
        find.byKey(const Key('zakat-result-due')),
      );
      expect(due.textDirection, TextDirection.ltr);

      final nisab = tester.widget<Text>(
        find.byKey(const Key('zakat-result-nisab')),
      );
      expect(nisab.textDirection, TextDirection.ltr);
    });

    testWidgets(
        'cash line with amount but no label blocks the request '
        '(field report: 4,000,000 silently vanished)', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      // Enable cash, add one line, type the amount — but leave the label
      // blank, exactly as in the field report.
      await tester.ensureVisible(
        find.byKey(const Key('zakat-field-cash-provided')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-field-cash-provided')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('zakat-cash-lines-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('zakat-cash-lines-amount-0')),
        '4000000',
      );
      await tester.enterText(
        find.byKey(const Key('zakat-field-collectible')),
        '200000',
      );
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();

      // The blank label must block submission — the amount may never be
      // silently dropped from the payload.
      expect(calculateBodies, isEmpty);
      expect(find.byKey(const Key('zakat-result')), findsNothing);
      expect(
        find.text(AppStrings.t('field_required', 'ar')),
        findsWidgets,
      );
    });
  });

  // Stock-only breakdown + wholesale valuation basis. The server values
  // CURRENT remaining stock at the chosen basis and returns the qty /
  // cost / market reference figures plus the 2.5 % estimate on the
  // merchandise value alone — clearly labelled on screen as NOT the
  // complete business zakat (cash / receivables / liabilities / nisab
  // stay in the net formula).
  group('Zakat screen — stock-only breakdown & wholesale basis', () {
    Map<String, dynamic> calculateWithBreakdown() {
      final json = _calculateJson();
      final result =
          Map<String, dynamic>.from(json['result'] as Map<String, dynamic>);
      result
        ..['inventory_quantity'] = '40.000'
        ..['inventory_cost_value'] = '2800.000'
        ..['inventory_market_value'] = '4000.000'
        ..['inventory_stock_only_zakat'] = '100.000';
      return Map<String, dynamic>.from(json)..['result'] = result;
    }

    Future<void> runCalculate(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('zakat-field-collectible')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('zakat-field-collectible')),
        '100',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-calculate')));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'result card shows remaining qty, cost vs market value and the '
        'stock-only 2.5% estimate with its not-the-full-zakat note',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, calculateJson: calculateWithBreakdown);
      final container = await pumpLogin(tester, dio);
      containerGoZakat(container);
      await tester.pumpAndSettle();
      await runCalculate(tester);

      expect(find.byKey(const Key('zakat-result')), findsOneWidget);
      final qty = tester.widget<Text>(
        find.byKey(const Key('zakat-result-stock-qty')),
      );
      expect(qty.data, contains('40'));
      final cost = tester.widget<Text>(
        find.byKey(const Key('zakat-result-stock-cost')),
      );
      expect(cost.data, contains('2 800'),
          reason: 'cost value shown for reference, at 3-decimal precision');
      final market = tester.widget<Text>(
        find.byKey(const Key('zakat-result-stock-market')),
      );
      expect(market.data, contains('4 000'),
          reason: 'market selling value differs from cost');
      final only = tester.widget<Text>(
        find.byKey(const Key('zakat-result-stock-only-zakat')),
      );
      expect(only.data, contains('100'));
      expect(only.data, contains(AppStrings.t('currency', 'ar')));
      expect(only.style!.fontWeight, FontWeight.w700);
      expect(find.byKey(const Key('zakat-stock-only-note')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('zakat_stock_only_note', 'ar')),
        findsOneWidget,
        reason: 'the note states this is NOT the complete business zakat',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('old snapshots without a breakdown render no stock-only rows',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);
      containerGoZakat(container);
      await tester.pumpAndSettle();
      await runCalculate(tester);

      expect(find.byKey(const Key('zakat-result')), findsOneWidget);
      for (final key in [
        'zakat-result-stock-qty',
        'zakat-result-stock-cost',
        'zakat-result-stock-market',
        'zakat-result-stock-only-zakat',
        'zakat-stock-only-note',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: 'absent: $key');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the basis dropdown offers wholesale and the payload carries the '
        'chosen basis (market default untouched)', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);
      containerGoZakat(container);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('zakat-field-basis')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('zakat-field-basis')));
      await tester.pumpAndSettle();
      for (final basis in ['market', 'cost', 'wholesale', 'override']) {
        // The selected value renders both on the closed button and in
        // the open menu — every basis label must resolve at least once.
        expect(
          find.text(AppStrings.t('zakat_basis_$basis', 'ar')),
          findsWidgets,
          reason: 'basis option missing: $basis',
        );
      }

      await tester.tap(
        find.text(AppStrings.t('zakat_basis_wholesale', 'ar')).last,
      );
      await tester.pumpAndSettle();
      await runCalculate(tester);

      expect(calculateBodies.single['inventory_basis'], 'wholesale');
      expect(tester.takeException(), isNull);
    });
  });

  group('Zakat screen — history tab', () {
    testWidgets('history tab lists saved calculations', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final container = await pumpLogin(tester, dio);

      containerGoZakat(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('zakat-tab-history')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('zakat-history')), findsOneWidget);
      expect(find.byKey(const Key('zakat-history-header')), findsOneWidget);
      expect(find.byKey(const Key('zakat-history-row-0')), findsOneWidget);
      expect(
        find.byKey(const Key('zakat-history-row-0-open')),
        findsOneWidget,
      );
      // One row, no "load more".
      expect(find.byKey(const Key('zakat-history-more')), findsNothing);
    });
  });
}
