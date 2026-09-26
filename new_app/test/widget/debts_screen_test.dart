// Phase 9 — Debts screen (AR summary + debtors list) widget tests.
//
// Same harness/stub-order rules as clients_screen_test.dart: specific
// auth GET stubs registered LAST, catch-alls before them, one universal
// POST stub dispatched on path.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/clients/clients_providers.dart';
import 'package:supermarket_pos/features/debts/debts_screen.dart';
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
const _customersPath = '/api/v1/customers';
const _summaryPath = '/api/v1/debts/summary';

const _adminScopes = ['customer_view', 'customer_manage'];

Map<String, dynamic> _loginBody({List<String> scopes = _adminScopes}) => {
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
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _customerJson({
  required String id,
  required String name,
  String? phone,
  String balance = '0.000',
  String ceiling = '0.000',
}) =>
    {
      'id': id,
      'name': name,
      'phone': phone,
      'address': null,
      'balance': balance,
      'debt_ceiling': ceiling,
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _debtorsBody() => {
      'items': [
        _customerJson(
          id: 'c1',
          name: 'Alice Market',
          phone: '0555000001',
          balance: '1500.000',
          ceiling: '5000.000',
        ),
        _customerJson(
          id: 'c4',
          name: 'Charlie Store',
          phone: '0555000004',
          balance: '400.000',
          ceiling: '400.000',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _summaryBody() => {
      'total_debt': '4500.000',
      'customers_with_debt': 3,
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
    List<String> scopes = _adminScopes,
    DioException? payError,
    List<Map<String, dynamic>>? listQueryLog,
    List<Object?>? payPayloads,
    List<int>? summaryCounter,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    // ONE post stub (login / pay) dispatched on path.
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        final data = invocation.namedArguments[#data] as Map<String, dynamic>;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody(scopes: scopes));
        }
        if (path.endsWith('/pay')) {
          if (payPayloads != null) payPayloads.add(data);
          if (payError != null) throw payError;
          return okResponse(path, {
            'id': 'p1',
            'customer_id': 'c1',
            'entry_type': 'payment',
            'amount': data['amount'],
            'balance': '1000.000',
            'note': null,
            'client_request_id': data['client_request_id'],
            'entry_date': '2026-02-03T10:00:00Z',
            'idempotent_replay': false,
          });
        }
        return okResponse(path, {'message': 'ok'});
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
      if (path == _customersPath) {
        listQueryLog?.add(params);
        return okResponse(path, _debtorsBody());
      }
      return okResponse(path, _debtorsBody());
    });
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _summaryPath) {
        summaryCounter?.add(1);
        return okResponse(path, _summaryBody());
      }
      return okResponse(path, _summaryBody());
    });

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
              {'name': 'admin'},
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

  group('Debts screen (admin with customer scopes)', () {
    testWidgets('shows AR summary and debtors list (has_debt=true)',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('debts', 'ar'),
      );

      expect(find.byType(DebtsScreen), findsOneWidget);
      expect(find.byKey(const Key('debts-title')), findsOneWidget);
      expect(find.byKey(const Key('debts-summary')), findsOneWidget);
      expect(find.byKey(const Key('debts-total')), findsOneWidget);
      // formatMoney('4500.000') → '4500'
      expect(find.text('4500'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      expect(find.byKey(const Key('debtor-tile-0')), findsOneWidget);
      expect(find.text('Alice Market'), findsOneWidget);
      expect(find.text('Charlie Store'), findsOneWidget);
      expect(find.byKey(const Key('debtor-balance-0')), findsOneWidget);
      // Over-limit hint on Charlie (balance == ceiling == 400 → not over),
      // Alice is under ceiling — no over-limit badges.
      expect(find.byKey(const Key('debtor-over-limit-0')), findsNothing);

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['has_debt'], true);
      expect(queryLog.first['page'], 1);
      expect(container.read(debtorsProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'record payment from debtor tile posts command and refreshes summary',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      final payloads = <Object?>[];
      final summaryCounter = <int>[];
      stubRequests(
        dio,
        listQueryLog: queryLog,
        payPayloads: payloads,
        summaryCounter: summaryCounter,
      );

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('debts', 'ar'),
      );
      final summaryLoadsBefore = summaryCounter.length;
      final listLoadsBefore = queryLog.length;

      await tester.tap(find.byKey(const Key('debtor-pay-button-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debt-payment-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '100',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('debt-pay-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('debt-payment-dialog')), findsNothing);
      expect(
        find.byKey(const Key('debts-payment-success-toast')),
        findsOneWidget,
      );
      expect(payloads, hasLength(1));
      final payload = payloads.single as Map<String, dynamic>;
      expect(payload['amount'], '100');
      expect(payload['client_request_id'], isA<String>());

      // Summary + debtors list were refreshed after the payment.
      expect(summaryCounter.length, greaterThan(summaryLoadsBefore));
      expect(queryLog.length, greaterThan(listLoadsBefore));
    });

    testWidgets(
        'user without customer_view: no rail entry and permission denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: const ['pos_sale']);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
      );

      expect(find.text(AppStrings.t('debts', 'ar')), findsNothing);

      container.read(routerProvider).go('/debts');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('debts-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('debts-title')), findsNothing);
    });

    testWidgets('view-only user sees debtors but no payment action',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: const ['customer_view']);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('debts', 'ar'),
      );

      expect(find.byKey(const Key('debtor-tile-0')), findsOneWidget);
      expect(find.byKey(const Key('debtor-pay-button-0')), findsNothing);
      expect(find.byKey(const Key('debts-summary')), findsOneWidget);
    });
  });
}
