// Phase 13 â€” Expenses screen widget tests (list + summary, filters,
// create, cancel, RBAC).
//
// Harness rules from returns_screen_test.dart: catch-all GET stubs first,
// specific auth GET stubs LAST, ONE universal POST stub dispatched on
// path. Money is asserted exactly as `formatMoney` renders the server's
// decimal strings â€” the client never recomputes a total.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/expenses/expenses_providers.dart';
import 'package:supermarket_pos/features/expenses/expenses_screen.dart';
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

const _loginPath = '/api/v1/auth/login';
const _expensesPath = '/api/v1/expenses';
const _summaryPath = '/api/v1/expenses/summary';
const _cancelPath = '/api/v1/expenses/exp-1/cancel';

const _expenseScopes = ['expense_view', 'expense_create', 'expense_cancel'];

Map<String, dynamic> _loginBody({
  List<String> scopes = _expenseScopes,
  String roleName = 'cashier',
}) =>
    {
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

Map<String, dynamic> _expenseJson({
  String id = 'exp-1',
  String title = 'Electricity',
  String category = 'utilities',
  String amount = '120.500',
  bool paidFromDrawer = true,
  String status = 'posted',
  bool idempotentReplay = false,
  String? cancelReason,
}) =>
    {
      'id': id,
      'title': title,
      'category': category,
      'amount': amount,
      'paid_from_drawer': paidFromDrawer,
      'note': null,
      'status': status,
      'user_id': '00000000-0000-0000-0000-0000000000a1',
      'device_id': null,
      'client_request_id': 'req-$id',
      'expense_date': '2026-09-29T10:00:00Z',
      'cancelled_at': status == 'cancelled' ? '2026-09-29T11:00:00Z' : null,
      'cancelled_by':
          status == 'cancelled' ? '00000000-0000-0000-0000-0000000000a1' : null,
      'cancel_reason': cancelReason,
      'created_at': '2026-09-29T10:00:00Z',
      'updated_at': '2026-09-29T10:00:00Z',
      'idempotent_replay': idempotentReplay,
    };

Map<String, dynamic> _listBody() => {
      'items': [
        _expenseJson(),
        _expenseJson(
          id: 'exp-2',
          title: 'Office chairs',
          category: 'supplies',
          amount: '50.000',
          paidFromDrawer: false,
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 25,
      'pages': 1,
    };

Map<String, dynamic> _summaryBody() => {
      'count': 2,
      'total_amount': '170.500',
      'drawer_amount': '120.500',
      'external_amount': '50.000',
    };

const _emptyBody = {
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
    List<String> scopes = _expenseScopes,
    String roleName = 'cashier',
    List<Map<String, dynamic>>? listQueryLog,
    Map<String, dynamic>? Function(String path)? postBody,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    // ONE post stub (login / create / cancel) dispatched on path.
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(
            _loginPath,
            _loginBody(scopes: scopes, roleName: roleName),
          );
        }
        final body = postBody?.call(path);
        return okResponse(path, body ?? _expenseJson());
      },
    );

    // Catch-all GET stubs (registered before the specific auth stubs).
    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      if (path == _expensesPath) {
        listQueryLog?.add(params);
        return okResponse(path, _listBody());
      }
      if (path == _summaryPath) {
        return okResponse(path, _summaryBody());
      }
      return okResponse(path, _emptyBody);
    });
    when(() => dio.get(any())).thenAnswer(
      (invocation) async =>
          okResponse(invocation.positionalArguments.first as String, _emptyBody),
    );

    // Specific-path GET stubs LAST (checked first).
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
              {'name': 'cashier'},
            ],
          },
        ],
        'total': 1,
      }),
    );
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required String userName,
    required String pin,
    String navLabel = '',
  }) async {
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

    await tester.tap(find.text(userName));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    if (navLabel.isNotEmpty) {
      await tester.tap(find.text(navLabel));
      await tester.pumpAndSettle();
    }

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<ProviderContainer> pumpExpenses(
    WidgetTester tester,
    MockDio dio, {
    List<String> scopes = _expenseScopes,
    String roleName = 'cashier',
    List<Map<String, dynamic>>? listQueryLog,
    Map<String, dynamic>? Function(String path)? postBody,
    bool navigate = true,
  }) async {
    stubRequests(
      dio,
      scopes: scopes,
      roleName: roleName,
      listQueryLog: listQueryLog,
      postBody: postBody,
    );
    return pumpApp(
      tester,
      dio,
      userName: 'Admin',
      pin: '1234',
      // Without `expense_view` the rail destination does not exist at all.
      navLabel: navigate && scopes.contains('expense_view')
          ? AppStrings.t('expenses', 'ar')
          : '',
    );
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data ?? '';

  group('Expenses screen (all three expense scopes)', () {
    testWidgets('lists the expenses and their summary as the server computed',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      final container =
          await pumpExpenses(tester, dio, listQueryLog: queryLog);

      expect(find.byType(ExpensesScreen), findsOneWidget);
      expect(find.byKey(const Key('expenses-title')), findsOneWidget);
      expect(find.byKey(const Key('expenses-list')), findsOneWidget);

      expect(textOf(tester, 'expense-title-0'), 'Electricity');
      expect(textOf(tester, 'expense-amount-0'), '120.5');
      expect(textOf(tester, 'expense-title-1'), 'Office chairs');
      expect(textOf(tester, 'expense-amount-1'), '50');
      expect(find.byKey(const Key('expenses-empty')), findsNothing);

      expect(textOf(tester, 'expenses-summary-count'), '2');
      expect(textOf(tester, 'expenses-summary-total'), '170.5');
      expect(textOf(tester, 'expenses-summary-drawer'), '120.5');
      expect(textOf(tester, 'expenses-summary-external'), '50');

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first['page_size'], 25);
      expect(queryLog.first['status'], 'posted');
      expect(container.read(expensesProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('category filter is sent with page reset', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('expenses-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('expenses-category-rent')));
      await tester.pumpAndSettle();

      expect(queryLog.length, greaterThan(before));
      expect(queryLog.last['category'], 'rent');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('status filter "all" reaches the API', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);

      await tester.tap(find.byKey(const Key('expenses-status-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('expenses-status-all')));
      await tester.pumpAndSettle();

      expect(queryLog.last['status'], 'all');
      expect(tester.takeException(), isNull);
    });

    testWidgets('payment filter reaches the API as a boolean', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);

      await tester.tap(find.byKey(const Key('expenses-payment-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('expenses-payment-drawer')));
      await tester.pumpAndSettle();

      expect(queryLog.last['paid_from_drawer'], isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search submits q and resets the page', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);

      await tester.enterText(
        find.byKey(const Key('expenses-search')),
        'elec',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(queryLog.last['q'], 'elec');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });
    testWidgets('the two date-range pickers open from the filter bar',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);

      expect(find.byKey(const Key('expenses-date-label')), findsOneWidget);
      expect(find.byKey(const Key('expenses-date-from')), findsOneWidget);
      expect(find.byKey(const Key('expenses-date-to')), findsOneWidget);

      await tester.tap(find.byKey(const Key('expenses-date-from')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);

      // Dismiss through the barrier: no date chosen, no crash (GATE 27).
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Expenses screen â€” create', () {
    testWidgets('"Add expense" opens the editor and cancel closes it',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('expenses-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expense-form-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('expense-form-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expense-form-dialog')), findsNothing);
      expect(queryLog.length, before, reason: 'no reload on a backed-out form');
      expect(tester.takeException(), isNull);
    });

    testWidgets('posts the payload, shows the success toast and reloads',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('expenses-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('expense-form-title-input')),
        'Water bill',
      );
      await tester.enterText(
        find.byKey(const Key('expense-form-amount')),
        '45.250',
      );
      await tester.tap(find.byKey(const Key('expense-form-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('expense-form-dialog')), findsNothing);
      expect(find.byKey(const Key('expenses-toast')), findsOneWidget);

      final body = verify(
        () => dio.post(_expensesPath, data: captureAny(named: 'data')),
      ).captured.single as Map<String, dynamic>;
      expect(body['title'], 'Water bill');
      expect(body['amount'], '45.250');
      expect(body['category'], 'rent');
      expect(body['paid_from_drawer'], isTrue);
      expect(body.containsKey('expense_date'), isFalse);
      expect(body.containsKey('status'), isFalse);
      expect('${body['client_request_id']}', isNotEmpty);

      expect(queryLog.length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  group('Expenses screen â€” cancel', () {
    testWidgets('the row action posts the reason and refreshes the list',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpExpenses(
        tester,
        dio,
        listQueryLog: queryLog,
        postBody: (path) => path == _cancelPath
            ? _expenseJson(
                status: 'cancelled',
                cancelReason: 'Duplicate entry',
              )
            : null,
      );
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('expense-cancel-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expense-cancel-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('expense_cancel_confirm', 'ar')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('expense-cancel-reason-input')),
        'Duplicate entry',
      );
      await tester.tap(find.byKey(const Key('expense-cancel-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('expense-cancel-dialog')), findsNothing);
      expect(find.byKey(const Key('expenses-cancel-toast')), findsOneWidget);

      final body = verify(
        () => dio.post(_cancelPath, data: captureAny(named: 'data')),
      ).captured.single as Map<String, dynamic>;
      expect(body.keys.toSet(), {'reason'});
      expect(body['reason'], 'Duplicate entry');

      expect(queryLog.length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  group('Expenses screen RBAC', () {
    testWidgets('user without expense_view: no rail entry, route denied',
        (tester) async {
      final dio = MockDio();
      await pumpExpenses(tester, dio, scopes: const ['pos_sale']);

      expect(find.text(AppStrings.t('expenses', 'ar')), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(routerProvider).go('/expenses');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('expenses-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('expenses-title')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expense_view without expense_create hides the add button',
        (tester) async {
      final dio = MockDio();
      await pumpExpenses(tester, dio, scopes: const ['expense_view']);

      expect(find.byKey(const Key('expenses-title')), findsOneWidget);
      expect(find.byKey(const Key('expenses-list')), findsOneWidget);
      expect(find.byKey(const Key('expenses-add')), findsNothing);
      expect(find.byKey(const Key('expense-cancel-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // Human QA regression (Phase 13): the Expenses destination must exist for
  // every seeded role that holds `expense_view` (admin / manager / cashier
  // all do â€” seed.py ROLE_PERMISSIONS) and must sit immediately after
  // Returns. A role without `expense_view` never sees it, per the project's
  // permission-gated navigation convention.
  const Map<String, List<String>> roleScopes = {
    'admin': [
      'pos_sale',
      'pos_return',
      'product_view',
      'inventory_view',
      'customer_view',
      'supplier_view',
      'purchase_view',
      'user_manage',
      'expense_view',
      'expense_create',
      'expense_cancel',
    ],
    'manager': [
      'pos_sale',
      'pos_return',
      'product_view',
      'inventory_view',
      'customer_view',
      'supplier_view',
      'purchase_view',
      'expense_view',
      'expense_create',
      'expense_cancel',
    ],
    'cashier': [
      'pos_sale',
      'pos_return',
      'expense_view',
      'expense_create',
      'expense_cancel',
    ],
  };

  List<String> railLabels(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.byType(Text),
        ),
      )
      .map((text) => text.data ?? '')
      .toList();

  group('Expenses rail entry (Human QA regression)', () {
    for (final role in roleScopes.keys) {
      testWidgets('$role sees the Expenses destination after Returns',
          (tester) async {
        final dio = MockDio();
        await pumpExpenses(
          tester,
          dio,
          scopes: roleScopes[role]!,
          roleName: role,
          navigate: false,
        );

        final labels = railLabels(tester);
        final expensesLabel = AppStrings.t('expenses', 'ar');
        final returnsLabel = AppStrings.t('returns_history', 'ar');

        expect(
          labels,
          contains(expensesLabel),
          reason: '$role must see the Expenses destination (ar label)',
        );
        expect(
          labels.indexOf(expensesLabel),
          labels.indexOf(returnsLabel) + 1,
          reason: 'Expenses must be the destination right after Returns',
        );

        await tester.tap(find.text(expensesLabel));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('expenses-title')), findsOneWidget);
        expect(find.byKey(const Key('expenses-list')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a role without expense_view has no Expenses destination',
        (tester) async {
      final dio = MockDio();
      await pumpExpenses(
        tester,
        dio,
        scopes: const ['pos_sale', 'pos_return'],
        roleName: 'viewer',
        navigate: false,
      );

      final labels = railLabels(tester);
      expect(
        labels,
        isNot(contains(AppStrings.t('expenses', 'ar'))),
        reason: 'no expense_view â†’ no Expenses destination',
      );
      expect(labels, contains(AppStrings.t('returns_history', 'ar')));
      expect(tester.takeException(), isNull);
    });
  });
}
