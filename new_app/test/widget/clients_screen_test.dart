// Phase 9 — Clients screen (master/detail) widget tests.
//
// Harness copied from products_screen_test.dart (full-app login flow,
// MockDio). Mocktail stub-order rule discovered for this suite: the
// parameterized GET stub must be registered BEFORE the bare GET stub —
// the LAST registered stub is checked first, and `any(named:
// 'queryParameters')` also matches calls where the argument is absent.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/clients/clients_providers.dart';
import 'package:supermarket_pos/features/clients/clients_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

/// Wraps a value in the same LTR isolate the app renders (W7: mixed
/// Arabic + number strings).
String _m(String v) => bidiIsolateLtr(v);

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
const _customersPath = '/api/v1/customers';
const _payPath = '$_customersPath/c1/pay';

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
  String? address,
  String balance = '0.000',
  String ceiling = '0.000',
  bool archived = false,
}) =>
    {
      'id': id,
      'name': name,
      'phone': phone,
      'address': address,
      'balance': balance,
      'debt_ceiling': ceiling,
      'is_archived': archived,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _alice() => _customerJson(
      id: 'c1',
      name: 'Alice Market',
      phone: '0555000001',
      address: 'Rue 1',
      balance: '1500.000',
      ceiling: '5000.000',
    );

Map<String, dynamic> _bob() => _customerJson(
      id: 'c2',
      name: 'Bob Wholesale',
      phone: '0555000002',
      balance: '0.000',
      ceiling: '0.000',
    );

Map<String, dynamic> _listBody({
  List<Map<String, dynamic>>? items,
  int total = 2,
  int pages = 1,
}) =>
    {
      'items': items ?? [_alice(), _bob()],
      'total': total,
      'page': 1,
      'page_size': 40,
      'pages': pages,
    };

Map<String, dynamic> _historyBody() => {
      'items': [
        {
          'id': 'e1',
          'customer_id': 'c1',
          'entry_type': 'sale',
          'amount': '1500.000',
          'note': null,
          'reference_sale_id': 's1',
          'invoice_number': 'INV-0001',
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-01T10:00:00Z',
        },
        {
          'id': 'e2',
          'customer_id': 'c1',
          'entry_type': 'payment',
          'amount': '500.000',
          'note': 'cash',
          'reference_sale_id': null,
          'invoice_number': null,
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-02T10:00:00Z',
        },
      ],
      'total': 2,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

/// Two credit sales for the same customer (newest first): 1500 + 500.
/// The card must show their SUM (2000), never one entry's amount.
Map<String, dynamic> _historyBodyForSales() => {
      'items': [
        {
          'id': 'e2',
          'customer_id': 'c1',
          'entry_type': 'sale',
          'amount': '500.000',
          'note': 'credit sale 2',
          'reference_sale_id': 's2',
          'invoice_number': 'INV-0002',
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-02T10:00:00Z',
          'balance_after': '2000.000',
        },
        {
          'id': 'e1',
          'customer_id': 'c1',
          'entry_type': 'sale',
          'amount': '1500.000',
          'note': 'credit sale',
          'reference_sale_id': 's1',
          'invoice_number': 'INV-0001',
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-01T10:00:00Z',
          'balance_after': '1500.000',
        },
      ],
      'total': 2,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

/// Full debt lifecycle (newest first): Pay All -> partial payment ->
/// credit sale, each with the computed running balance.
Map<String, dynamic> _lifecycleHistoryBody({int pages = 1}) => {
      'items': [
        {
          'id': 'e3',
          'customer_id': 'c1',
          'entry_type': 'payment',
          'amount': '1000.000',
          'note': 'Pay all',
          'reference_sale_id': null,
          'invoice_number': null,
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-03T10:00:00Z',
          'balance_after': '0.000',
        },
        {
          'id': 'e2',
          'customer_id': 'c1',
          'entry_type': 'payment',
          'amount': '500.000',
          'note': 'Cash 500',
          'reference_sale_id': null,
          'invoice_number': null,
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-02T10:00:00Z',
          'balance_after': '1000.000',
        },
        {
          'id': 'e1',
          'customer_id': 'c1',
          'entry_type': 'sale',
          'amount': '1500.000',
          'note': 'credit sale',
          'reference_sale_id': 's1',
          'invoice_number': 'INV-0001',
          'user_id': 'u1',
          'user_name': 'Admin',
          'entry_date': '2026-02-01T10:00:00Z',
          'balance_after': '1500.000',
        },
      ],
      'total': 3,
      'page': 1,
      'page_size': 20,
      'pages': pages,
    };

Map<String, dynamic> _payBody() => {
      'id': 'p1',
      'customer_id': 'c1',
      'entry_type': 'payment',
      'amount': '500.000',
      'balance': '1000.000',
      'note': null,
      'client_request_id': 'req-1',
      'entry_date': '2026-02-03T10:00:00Z',
      'idempotent_replay': false,
    };

DioException _envelopeError(int status, String code, {String? message}) {
  return DioException(
    requestOptions: RequestOptions(path: _customersPath),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: _customersPath),
      statusCode: status,
      data: {
        'error': {
          'code': code,
          'message': message ?? 'backend text for $code',
          'details': <String, dynamic>{},
        },
      },
    ),
  );
}

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
    Map<String, dynamic>? listBody,
    Map<String, dynamic>? historyBody,
    Map<String, dynamic>? detailBody,
    Object? payResult,
    DioException? payError,
    DioException? archiveError,
    List<Map<String, dynamic>>? listQueryLog,
    List<Object?>? payPayloads,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    // NOTE: auth GET stubs are registered AFTER the catch-all GET stubs
    // below — mocktail checks the LAST registered stub first, so specific
    // paths must always win over `any()` catch-alls.
    // ONE post stub for every POST (login / create / pay) — dispatched on
    // the path inside the answer (mocktail's `argThat` is not available,
    // and a later exact-path stub would otherwise shadow these).
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        final data = invocation.namedArguments[#data] as Map<String, dynamic>;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody(scopes: scopes));
        }
        if (path == '/api/v1/auth/logout-token') {
          return okResponse(path, {'message': 'logged out'});
        }
        if (path.endsWith('/pay')) {
          if (payPayloads != null) payPayloads.add(data);
          if (payError != null) throw payError;
          if (payResult != null) {
            return Response<dynamic>(
              requestOptions: RequestOptions(path: _payPath),
              data: payResult,
              statusCode: 200,
            );
          }
          return okResponse(_payPath, _payBody());
        }
        // POST /api/v1/customers (create)
        return Response<dynamic>(
          requestOptions: RequestOptions(path: _customersPath),
          data: _customerJson(id: 'c3', name: '${data['name']}'),
          statusCode: 201,
        );
      },
    );

    // Parameterized GET stub FIRST — the bare stub below is checked first
    // and must not swallow these calls (see file header).
    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      if (path == _customersPath) {
        listQueryLog?.add(params);
        return okResponse(path, listBody ?? _listBody());
      }
      if (path.endsWith('/debts')) {
        return okResponse(path, historyBody ?? _historyBody());
      }
      return okResponse(path, detailBody ?? _alice());
    });
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _customersPath) {
        listQueryLog?.add(const {});
        return okResponse(path, listBody ?? _listBody());
      }
      // GET /customers/{id} (detail) — everything else bare.
      return okResponse(path, detailBody ?? _alice());
    });

    // Specific-path GET stubs LAST (checked first) — must beat the
    // `any()` catch-alls above.
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
      }),
    );

    when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_customersPath, _alice()),
    );
    when(() => dio.delete(any())).thenAnswer((_) async {
      if (archiveError != null) throw archiveError;
      return okResponse(
        _customersPath,
        _customerJson(id: 'c1', name: 'Alice Market', archived: true),
      );
    });
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

  Future<void> openAlice(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('client-tile-0')));
    await tester.pumpAndSettle();
  }

  group('Clients screen (admin with customer scopes)', () {
    testWidgets('loads via GET /api/v1/customers and lists customers',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );

      expect(find.byType(ClientsScreen), findsOneWidget);
      expect(find.byKey(const Key('clients-title')), findsOneWidget);
      expect(find.text('Alice Market'), findsOneWidget);
      expect(find.text('Bob Wholesale'), findsOneWidget);
      expect(find.byKey(const Key('client-balance-0')), findsOneWidget);
      // formatMoney('1500.000') → '1500'
      expect(find.text('1 500'), findsOneWidget);
      expect(find.byKey(const Key('clients-total')), findsOneWidget);
      expect(
        find.text('${AppStrings.t('total', 'ar')}: 2'),
        findsOneWidget,
      );

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first.containsKey('q'), isFalse);
      expect(queryLog.first.containsKey('include_archived'), isFalse);
      expect(queryLog.first.containsKey('has_debt'), isFalse);

      expect(container.read(customersProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'user without customer_view: no rail entry and permission denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: ['pos_sale']);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
      );

      // Rail has no clients destination for this user.
      expect(find.text(AppStrings.t('clients', 'ar')), findsNothing);

      container.read(routerProvider).go('/clients');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('clients-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('clients-title')), findsNothing);
    });

    testWidgets('view-only user sees detail but no mutation actions',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: const ['customer_view']);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );

      expect(find.byKey(const Key('clients-add-button')), findsNothing);
      await openAlice(tester);

      expect(find.byKey(const Key('client-detail-name')), findsOneWidget);
      expect(find.text('Alice Market'), findsWidgets);
      expect(find.byKey(const Key('client-hist-amount-0')), findsOneWidget);
      expect(find.byKey(const Key('client-pay-button')), findsNothing);
      expect(find.byKey(const Key('client-edit-button')), findsNothing);
      expect(find.byKey(const Key('client-archive-button')), findsNothing);
    });

    testWidgets('selecting a customer loads detail and debt history',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );

      expect(find.byKey(const Key('clients-detail-empty')), findsOneWidget);

      await openAlice(tester);

      expect(find.byKey(const Key('client-detail')), findsOneWidget);
      expect(
        find.text('Alice Market'),
        findsWidgets,
      );
      // balance card: 'Balance: 1 500'
      expect(
        find.text(
          '${AppStrings.t('balance', 'ar')}: ${_m('1 500')}',
        ),
        findsOneWidget,
      );
      // Debt history rows (sale + payment).
      expect(find.byKey(const Key('client-hist-amount-0')), findsOneWidget);
      expect(find.byKey(const Key('client-hist-amount-1')), findsOneWidget);

      verify(
        () => dio.get(
          '$_customersPath/c1',
        ),
      ).called(1);
      verify(
        () => dio.get(
          '$_customersPath/c1/debts',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });

    testWidgets(
        'debt history shows lifecycle: signed amounts, localized types, '
        'Pay All labeled by zero balance', (tester) async {
      final dio = MockDio();
      stubRequests(dio, historyBody: _lifecycleHistoryBody());

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      // Newest first: Pay All payment -> full-payment label, '-1 000'.
      expect(
        find.text(
          '${AppStrings.t('entry_type_full_payment', 'ar')} · ${_m('-1 000')}',
        ),
        findsOneWidget,
      );
      // Normal partial payment keeps the payment label, '-500'.
      expect(
        find.text('${AppStrings.t('entry_type_payment', 'ar')} · ${_m('-500')}'),
        findsOneWidget,
      );
      // Credit sale: '+1 500' with the spec label.
      expect(
        find.text('${AppStrings.t('entry_type_sale', 'ar')} · ${_m('+1 500')}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'debt history meta shows date+time, running balance, invoice, '
        'user and note', (tester) async {
      final dio = MockDio();
      stubRequests(dio, historyBody: _lifecycleHistoryBody());

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      // Credit-sale row: timestamp, balance after, invoice, user, note.
      final saleMeta = tester
          .widget<Text>(find.byKey(const Key('client-hist-meta-2')))
          .data!;
      expect(saleMeta, contains(_m('2026-02-01 10:00:00')));
      expect(
        saleMeta,
        contains('${AppStrings.t('balance_after', 'ar')}: ${_m('1 500')}'),
      );
      expect(
        saleMeta,
        contains('${AppStrings.t('invoice_number', 'ar')}: ${_m('INV-0001')}'),
      );
      expect(saleMeta, contains('Admin'));
      expect(saleMeta, contains('credit sale'));

      // Pay All row: zero running balance after the entry.
      final payAllMeta = tester
          .widget<Text>(find.byKey(const Key('client-hist-meta-0')))
          .data!;
      expect(payAllMeta, contains(_m('2026-02-03 10:00:00')));
      expect(
        payAllMeta,
        contains('${AppStrings.t('balance_after', 'ar')}: ${_m('0')}'),
      );
      expect(payAllMeta, contains('Pay all'));
    });

    testWidgets('history rows remain visible after balance reaches zero',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        historyBody: _lifecycleHistoryBody(),
        detailBody: _customerJson(
          id: 'c1',
          name: 'Alice Market',
          balance: '0.000',
          ceiling: '0.000',
        ),
      );

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('0')}'),
        findsOneWidget,
      );
      // Full lifecycle (3 entries) still rendered with a zero balance.
      expect(find.byKey(const Key('client-hist-row-0')), findsOneWidget);
      expect(find.byKey(const Key('client-hist-row-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('debt history pagination shows page indicator and next '
        'loads page 2', (tester) async {
      final dio = MockDio();
      stubRequests(dio, historyBody: _lifecycleHistoryBody(pages: 2));

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('client-hist-next')));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      verify(
        () => dio.get(
          '$_customersPath/c1/debts',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(2);
    });

    testWidgets('create client posts payload and refreshes the list',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      final payloads = <Object?>[];
      stubRequests(dio, listQueryLog: queryLog, payPayloads: payloads);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      final initialLoads = queryLog.length;

      await tester.tap(find.byKey(const Key('clients-add-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'New Store',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(
        find.byKey(const Key('client-form-success-toast')),
        findsOneWidget,
      );

      final body = verify(
        () => dio.post(_customersPath, data: captureAny(named: 'data')),
      ).captured.single as Map<String, dynamic>;
      expect(body['name'], 'New Store');
      expect(body['debt_ceiling'], '0');
      expect(body['phone'], isNull);
      expect(body.containsKey('balance'), isFalse);

      // List was reloaded after the mutation.
      expect(queryLog.length, greaterThan(initialLoads));
    });

    testWidgets(
        'client-side mirror rejects payment above balance (no POST sent)',
        (tester) async {
      final dio = MockDio();
      final payloads = <Object?>[];
      stubRequests(dio, payPayloads: payloads);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      await tester.tap(find.byKey(const Key('client-pay-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('debt-payment-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '2000',
      );
      await tester.pump();
      expect(
        find.byKey(const Key('debt-amount-error')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('debt_payment_exceeds', 'ar')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('debt-pay-submit')))
            .onPressed,
        isNull,
      );

      // Correct amount → error clears, remaining preview exact decimal math.
      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '500',
      );
      await tester.pump();
      expect(find.byKey(const Key('debt-amount-error')), findsNothing);
      expect(
        find.text(
          '${AppStrings.t('remaining_after', 'ar')}: ${_m('1 000')}',
        ),
        findsOneWidget,
      );

      expect(payloads, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('record payment posts command with idempotency key',
        (tester) async {
      final dio = MockDio();
      final payloads = <Object?>[];
      stubRequests(dio, payPayloads: payloads);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      await tester.tap(find.byKey(const Key('client-pay-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '500',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('debt-pay-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('debt-payment-dialog')), findsNothing);
      expect(
        find.byKey(const Key('client-payment-success-toast')),
        findsOneWidget,
      );
      expect(payloads, hasLength(1));
      final payload = payloads.single as Map<String, dynamic>;
      expect(payload['amount'], '500');
      expect(payload['client_request_id'], isA<String>());
      expect(
        (payload['client_request_id'] as String).isEmpty,
        isFalse,
      );

      // Detail reloaded after payment (initial + refresh).
      verify(
        () => dio.get('$_customersPath/c1'),
      ).called(greaterThanOrEqualTo(2));
    });

    testWidgets('backend overpayment error shows localized dialog error',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        payError: _envelopeError(422, 'PAYMENT_EXCEEDS_BALANCE'),
      );

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      await tester.tap(find.byKey(const Key('client-pay-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '100',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('debt-pay-submit')));
      await tester.pumpAndSettle();

      // Dialog stays open with a localized headline + raw detail secondary.
      expect(find.byKey(const Key('debt-payment-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('debt-payment-error')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('debt_payment_exceeds', 'ar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('debt-payment-error-detail')),
        findsOneWidget,
      );
      expect(
        find.text('backend text for PAYMENT_EXCEEDS_BALANCE'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('debt-pay-submit')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
        'archive blocked by outstanding debt shows localized error toast',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        archiveError: _envelopeError(409, 'OUTSTANDING_DEBT'),
      );

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      await tester.tap(find.byKey(const Key('client-archive-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('client-archive-confirm')), findsOneWidget);

      await tester.tap(find.byKey(const Key('client-archive-confirm-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('client-archive-error-toast')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('customer_outstanding_debt', 'ar')),
        findsOneWidget,
      );
      // Selection is kept (archive failed).
      expect(find.byKey(const Key('client-detail')), findsOneWidget);
    });

    testWidgets('search is debounced and sends q with page reset',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      final initialLoads = queryLog.length;

      await tester.enterText(
        find.byKey(const Key('clients-search')),
        'ali',
      );
      // Debounce window (kCustomersSearchDebounce = 300ms).
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(queryLog.length, greaterThan(initialLoads));
      expect(queryLog.last['q'], 'ali');
      expect(queryLog.last['page'], 1);
    });

    testWidgets('show-archived toggle sends include_archived', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );

      await tester.tap(find.byKey(const Key('clients-archived-toggle')));
      await tester.pumpAndSettle();

      expect(queryLog.last['include_archived'], true);
    });
  });

  // Fix Round 2 — the reported bug: "the customer detail balance does not
  // go up when a new debt is added" / "a payment clears one debt and then
  // moves to the next one". Backend audit proved customers.balance ==
  // ledger sum; the stale value lived in these NON-autoDispose family
  // providers that only ever loaded once per customer id.
  group('Fix Round 2 — customer balance is the ledger aggregate', () {
    testWidgets('list row and detail card show the same aggregate balance',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      // ONE number for the whole customer (1500 in the list == 1500 on the
      // card), not a single debt entry and not the "next" debt.
      expect(
        find.byKey(const Key('client-balance-0')),
        findsOneWidget,
      );
      expect(find.text('1 500'), findsWidgets);
      expect(
        find.byKey(const Key('client-detail-balance')),
        findsOneWidget,
      );
      expect(
        find.text(
          '${AppStrings.t('balance', 'ar')}: ${_m('1 500')}',
        ),
        findsOneWidget,
      );
      expect(
        container.read(customerDetailProvider('c1')).value?.balance,
        '1500.000',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a silent reload after a new debt replaces the stale balance '
        'without a loading flash', (tester) async {
      final dio = MockDio();
      final detail = _alice();
      stubRequests(dio, detailBody: detail);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);
      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('1 500')}'),
        findsOneWidget,
      );

      // A credit sale of 534 was recorded since the first open — the pane
      // re-reads silently (the exact call the POS/debts refreshes make).
      detail['balance'] = '2034.000';
      container
          .read(customerDetailProvider('c1').notifier)
          .load(silent: true);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('client-detail-loading')),
        findsNothing,
        reason: 'silent refresh must not flash a spinner',
      );
      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('2 034')}'),
        findsOneWidget,
      );
      expect(
        container.read(customerDetailProvider('c1')).value?.balance,
        '2034.000',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a payment recorded on the Debts screen re-reads the open '
        'detail card', (tester) async {
      final dio = MockDio();
      final detail = _alice();
      stubRequests(dio, detailBody: detail);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);
      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('1 500')}'),
        findsOneWidget,
      );

      // Record a payment from the Debts screen while the detail provider
      // is still alive (the family never auto-disposes).
      container.read(routerProvider).go('/debts');
      await tester.pumpAndSettle();
      detail['balance'] = '1400.000';

      await tester.tap(find.byKey(const Key('debtor-pay-button-0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('debt-amount-field')),
        '100',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('debt-pay-submit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('debts-payment-success-toast')),
        findsOneWidget,
      );

      // The payment refresh must have re-READ the cached detail provider.
      expect(
        container.read(customerDetailProvider('c1')).value?.balance,
        '1400.000',
      );

      // Going back shows the fresh number, not the pre-payment snapshot.
      container.read(routerProvider).go('/clients');
      await tester.pumpAndSettle();
      if (find.byKey(const Key('clients-detail-empty')).evaluate().isNotEmpty) {
        await openAlice(tester);
      }
      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('1 400')}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'two debts are summed into one balance — paying never switches '
        'to the other debt or drops a history row', (tester) async {
      final dio = MockDio();
      final detail = _customerJson(
        id: 'c1',
        name: 'Alice Market',
        balance: '2000.000',
        ceiling: '5000.000',
      );
      final history = _historyBodyForSales();
      stubRequests(dio, detailBody: detail, historyBody: history);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('clients', 'ar'),
      );
      await openAlice(tester);

      // Aggregate = 1500 + 500 (two credit sales) = 2000.
      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('2 000')}'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('client-hist-amount-0')), findsOneWidget);
      expect(find.byKey(const Key('client-hist-amount-1')), findsOneWidget);

      // Payment of 500 -> the AGGREGATE drops; both debt rows stay.
      detail['balance'] = '1500.000';
      container
          .read(customerDetailProvider('c1').notifier)
          .load(silent: true);
      await tester.pumpAndSettle();

      expect(
        find.text('${AppStrings.t('balance', 'ar')}: ${_m('1 500')}'),
        findsOneWidget,
      );
      // No debt row disappeared and no row was re-labelled as "paid".
      expect(find.byKey(const Key('client-hist-amount-0')), findsOneWidget);
      expect(find.byKey(const Key('client-hist-amount-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
