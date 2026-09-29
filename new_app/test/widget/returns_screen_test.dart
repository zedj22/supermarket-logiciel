// Phase 12 — Returns screen widget tests (list, detail, create entry,
// RBAC).
//
// Same harness/stub-order rules as debts_screen_test.dart: catch-all
// GET stubs first, specific auth GET stubs LAST, ONE universal POST stub
// dispatched on path.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/returns/return_providers.dart';
import 'package:supermarket_pos/features/returns/returns_screen.dart';
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
const _returnsPath = '/api/v1/returns';

const _adminScopes = ['pos_return'];

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
            'name': 'cashier',
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _returnJson({
  required String id,
  required String number,
  String invoice = 'INV-20260928-0001',
  String reason = 'defective',
  String total = '120.000',
}) =>
    {
      'id': id,
      'return_number': number,
      'sale_id': 'sale-1',
      'invoice_number': invoice,
      'customer_id': null,
      'user_id': '00000000-0000-0000-0000-0000000000a1',
      'reason': reason,
      'subtotal': total,
      'discount': '0.000',
      'total': total,
      'note': null,
      'device_id': null,
      'client_request_id': 'req-1',
      'return_date': '2026-09-28T10:00:00Z',
      'lines': [
        {
          'id': 'rl-1',
          'sale_line_id': 'sl-1',
          'product_id': 'prod-1',
          'pack_id': null,
          'variant_id': null,
          'product_name': 'Coffee 250g',
          'product_sku': null,
          'product_barcode': null,
          'product_unit': 'piece',
          'variant_name': null,
          'selling_unit_name': null,
          'selling_unit_multiplier': null,
          'unit_price': '120.000',
          'unit_cost': '60.000',
          'quantity': '1',
          'quantity_base': '1',
          'line_discount': '0.000',
          'line_total': total,
        },
      ],
    };

Map<String, dynamic> _listBody() => {
      'items': [
        _returnJson(id: 'r1', number: 'RET-0001'),
        _returnJson(
          id: 'r2',
          number: 'RET-0002',
          invoice: 'INV-20260928-0002',
          reason: 'wrong_item',
          total: '45.000',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

const String _productsPath = '/api/v1/products';

/// `GET /api/v1/products?search=…` body for the Return Products dialog.
Map<String, dynamic> _productsSearchBody() => {
      'items': [
        {
          'id': 'prod-1',
          'name': 'Coffee 250g',
          'unit': 'piece',
          'price': '120.000',
          'quantity': '10',
          'barcode': '6130000000017',
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 20,
      'pages': 1,
    };

/// `POST /api/v1/returns` 201 body (the success path behind the result
/// dialog).
Map<String, dynamic> _createReturnBody() => {
      'return': _returnJson(
        id: 'r9',
        number: 'RET-0003',
        invoice: 'INV-20260928-0003',
      ),
      'idempotent_replay': false,
      'refund_total': '120.000',
      'credit_reversed': '0.000',
      'cash_pending': '120.000',
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
    List<Map<String, dynamic>>? listQueryLog,
    Map<String, dynamic>? Function(String path)? postBody,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    // ONE post stub (login / return create / void) dispatched on path.
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(_loginPath, _loginBody(scopes: scopes));
        }
        final body = postBody?.call(path);
        return okResponse(path, body ?? {'message': 'ok'});
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
      if (path == _returnsPath) {
        listQueryLog?.add(params);
        return okResponse(path, _listBody());
      }
      if (path == _productsPath) {
        return okResponse(path, _productsSearchBody());
      }
      return okResponse(path, _listBody());
    });
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path.startsWith('$_returnsPath/')) {
        return okResponse(path, _returnJson(id: 'r1', number: 'RET-0001'));
      }
      return okResponse(path, _listBody());
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

  /// Drives the full Return Products flow up to the success result dialog:
  /// search → add line → submit → `POST /api/v1/returns` 201.
  Future<ProviderContainer> pumpToResultDialog(
    WidgetTester tester,
    MockDio dio,
  ) async {
    final container = await pumpApp(
      tester,
      dio,
      userName: 'Admin',
      pin: '1234',
      navLabel: AppStrings.t('returns_history', 'ar'),
    );

    await tester.tap(find.byKey(const Key('returns-return-products')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('return-product-search')),
      'Coffee',
    );
    await tester.pump(const Duration(milliseconds: 350)); // search debounce
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('return-product-add-0')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('return-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('return-result-dialog')), findsOneWidget);
    return container;
  }

  group('Returns screen (user with pos_return)', () {
    testWidgets('lists the returned documents with server money',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('returns_history', 'ar'),
      );

      expect(find.byType(ReturnsScreen), findsOneWidget);
      expect(find.byKey(const Key('returns-title')), findsOneWidget);
      expect(find.byKey(const Key('returns-list')), findsOneWidget);

      expect(find.byKey(const Key('return-tile-0')), findsOneWidget);
      expect(find.text('RET-0001'), findsOneWidget);
      expect(find.text('RET-0002'), findsOneWidget);
      expect(find.text('120.000'), findsOneWidget);
      expect(find.byKey(const Key('returns-empty')), findsNothing);

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first['page_size'], 20);
      expect(container.read(returnsProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opens the return detail from a row', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('returns_history', 'ar'),
      );

      await tester.tap(find.byKey(const Key('return-tile-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('return-detail-dialog')), findsOneWidget);
      expect(find.byKey(const Key('return-detail-title')), findsOneWidget);
      expect(find.byKey(const Key('return-detail-total')), findsOneWidget);
      expect(find.text('120.000'), findsWidgets);
      expect(find.byKey(const Key('return-detail-line-0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('return-detail-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('return-detail-dialog')), findsNothing);
    });

    testWidgets('"Return Products" opens the multi-product return dialog',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('returns_history', 'ar'),
      );

      await tester.tap(find.byKey(const Key('returns-return-products')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('return-products-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('return-products-title')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('return-product-search')), findsOneWidget);
      expect(find.byKey(const Key('return-reason-select')), findsOneWidget);
      expect(
        find.byKey(const Key('return-selected-empty')),
        findsOneWidget,
      );

      // Cancel closes without posting anything.
      await tester.tap(find.byKey(const Key('return-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('return-products-dialog')), findsNothing);
    });

    testWidgets('reason filter is sent to the API', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('returns_history', 'ar'),
      );
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('returns-filter-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('returns-reason-expired')));
      await tester.pumpAndSettle();

      expect(queryLog.length, greaterThan(before));
      expect(queryLog.last['reason'], 'expired');
      expect(queryLog.last['page'], 1);
    });
  });

  group('Return result dialog close (Phase 12 UI bug)', () {
    testWidgets('OK closes only the result dialog and keeps /returns',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        postBody: (path) => path == _returnsPath ? _createReturnBody() : null,
      );

      final container = await pumpToResultDialog(tester, dio);

      await tester.tap(find.byKey(const Key('return-result-close')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('return-result-dialog')), findsNothing);
      expect(find.byKey(const Key('returns-screen')), findsOneWidget);
      expect(find.byType(ReturnsScreen), findsOneWidget);
      // The Returns route is still the current route.
      expect(container.read(routerProvider).state.uri.path, '/returns');
      // ...and its page is still on GoRouter's stack (nothing was popped).
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .isNotEmpty,
        isTrue,
      );
      expect(find.byKey(const Key('returns-title')), findsOneWidget);
    });

    testWidgets(
        'a repeated tap on OK while the dialog closes never pops the '
        'Returns route', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        postBody: (path) => path == _returnsPath ? _createReturnBody() : null,
      );

      final container = await pumpToResultDialog(tester, dio);

      // A pointer cannot land on the button twice (the closing route stops
      // hit-testing), so capture the handler and fire it a second time —
      // exactly what a double-tap/re-entrant close does. Before the fix
      // the second pop targeted the /returns page ("You have popped the
      // last page off of the stack" + "!_debugLocked").
      final close = tester
          .widget<ElevatedButton>(find.byKey(const Key('return-result-close')))
          .onPressed!;

      await tester.tap(find.byKey(const Key('return-result-close')));
      await tester.pump(const Duration(milliseconds: 30)); // dialog closing
      expect(
        find.byKey(const Key('return-result-dialog')),
        findsOneWidget,
        reason: 'the dialog must still be mounted while it closes',
      );
      close(); // second invocation of the same callback
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('return-result-dialog')), findsNothing);
      expect(find.byKey(const Key('returns-screen')), findsOneWidget);
      expect(find.byType(ReturnsScreen), findsOneWidget);
      expect(container.read(routerProvider).state.uri.path, '/returns');
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .isNotEmpty,
        isTrue,
      );
      expect(find.byKey(const Key('returns-title')), findsOneWidget);
    });
  });

  group('Returns screen RBAC', () {
    testWidgets(
        'user without pos_return: no rail entry and permission denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, scopes: const ['pos_sale']);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
      );

      expect(find.text(AppStrings.t('returns_history', 'ar')), findsNothing);

      container.read(routerProvider).go('/returns');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('returns-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('returns-title')), findsNothing);
      expect(find.byKey(const Key('returns-return-products')), findsNothing);
    });
  });
}
