// Search-state consistency (page-switch refresh) regression suite.
//
// Root cause of the reported bug: the search query lives in a Riverpod
// provider (kept alive across navigation) while the field's
// TextEditingController dies with the page's State. Re-entering a screen
// refetched with the OLD query but rendered an EMPTY box — a filter the
// user could neither see nor remove.
//
// Screens now re-seed their controller from the provider in initState
// (seedSearchField), and the two picker chips (facturation client,
// purchases supplier) keep their display label with the id in the query
// itself. These tests type a term, leave the page, come back, and assert
// the box shows what the provider is filtering by.
//
// Products (and Stock) went further on purpose: returning to the route
// RESETS search/filters/page and reloads the unfiltered list — the box
// is empty and the provider query is back to defaults. Their test
// asserts that reset contract; the screens below still keep the query.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pos_catalog_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/clients/clients_providers.dart';
import 'package:supermarket_pos/features/products/products_providers.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/suppliers/suppliers_providers.dart';
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

const _emptyBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 25,
  'pages': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  Response<dynamic> ok(String path, Object? data) => Response<dynamic>(
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
          return ok(path, {
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
          });
        }
        return ok(path, {'message': 'ok'});
      },
    );

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async =>
        ok(invocation.positionalArguments.first as String, _emptyBody));

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/auth/setup/check') {
        return ok(path, {'setup_needed': false});
      }
      if (path == '/api/v1/auth/login-users') {
        return ok(path, {
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
      return ok(path, _emptyBody);
    });
  }

  /// Logs in at a comfortable size, then resizes to the target.
  Future<ProviderContainer> pumpApp(WidgetTester tester, MockDio dio) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
          // This suite exercises the catalog search: opt into the legacy
          // product-list layout (`show_pos_product_list` is OFF by default).
          posCatalogMode(),
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

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpAndSettle();

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  /// Types [term], waits out the 300ms search debounce, leaves the page,
  /// comes back and asserts the field shows [term] again.
  Future<void> roundTrip(
    WidgetTester tester,
    ProviderContainer container, {
    required String route,
    required Key fieldKey,
    required String term,
    required String Function(ProviderContainer) currentQuery,
  }) async {
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(fieldKey), term);
    // setSearch is debounced (300ms) — let it fire and the reload settle.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(
      currentQuery(container),
      term,
      reason: 'precondition: the provider really is filtering on "$term"',
    );
    expect(
      tester.widget<TextField>(find.byKey(fieldKey)).controller?.text,
      term,
      reason: 'precondition: the field shows what was typed',
    );

    // Leave the page (State disposed) and come back.
    container.read(routerProvider).go('/about');
    await tester.pumpAndSettle();
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();

    expect(
      currentQuery(container),
      term,
      reason: 'the provider kept the query across navigation',
    );
    expect(
      tester.widget<TextField>(find.byKey(fieldKey)).controller?.text,
      term,
      reason:
          'the field must show the query the provider is filtering by '
          '(empty box + filtered list = unreachable filter)',
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets('products search resets on page switching (fresh list)',
      (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio);

    container.read(routerProvider).go('/products');
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('products-search-field')),
      'olive oil',
    );
    // setSearch is debounced (300ms) — let it fire and the reload settle.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      container.read(productsProvider).query.search,
      'olive oil',
      reason: 'precondition: the provider really is filtering on "olive oil"',
    );

    // Leave the page (State disposed) and come back.
    container.read(routerProvider).go('/about');
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/products');
    await tester.pumpAndSettle();

    expect(
      container.read(productsProvider).query.search,
      isEmpty,
      reason: 'returning to the route starts a fresh unfiltered catalog',
    );
    expect(
      tester.widget<TextField>(find.byKey(const Key('products-search-field')))
          .controller
          ?.text,
      isEmpty,
      reason: 'the box matches the reset query (no hidden filter)',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('suppliers search survives page switching', (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio);
    await roundTrip(
      tester,
      container,
      route: '/suppliers',
      fieldKey: const Key('suppliers-search'),
      term: 'Atlas',
      currentQuery: (c) => c.read(suppliersProvider).query.search,
    );
  });

  testWidgets('debts search survives page switching', (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio);
    await roundTrip(
      tester,
      container,
      route: '/debts',
      fieldKey: const Key('debts-search'),
      term: 'kacem',
      currentQuery: (c) => c.read(debtorsProvider).query.search,
    );
  });

  testWidgets('POS catalog search survives page switching', (tester) async {
    final dio = MockDio();
    stubRequests(dio);
    final container = await pumpApp(tester, dio);
    await roundTrip(
      tester,
      container,
      route: '/pos',
      fieldKey: const Key('pos-search-field'),
      term: 'sucre',
      currentQuery: (c) => c.read(posSearchProvider).query,
    );
  });
}
