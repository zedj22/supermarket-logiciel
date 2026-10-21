// Lifecycle & pagination regression tests for Products and Stock.
//
// Goals covered:
// - Route re-activation resets search/filters/page and reloads the list
//   (dialogs/detail panels never do — they never unmount the route).
// - A barcode highlight never survives a route change.
// - Refresh / navigation never duplicates scanner handlers.
// - Page sizes 25/50/100 (default 100), applied server-side, page resets
//   on size/search/sort changes, out-of-range pages clamped.
// - Stock changes made elsewhere are picked up on return to Stock.
// - The page-size preference persists through SharedPreferences.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/products_providers.dart';
import 'package:supermarket_pos/features/products/products_screen.dart';
import 'package:supermarket_pos/features/stock/inventory_providers.dart';
import 'package:supermarket_pos/features/stock/stock_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/wedge_scanner.dart';

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
const _productsPath = '/api/v1/products';
const _categoriesPath = '/api/v1/categories';
const _inventoryPath = '/api/v1/inventory';
const _movementsPath = '/api/v1/inventory/movements';

Map<String, dynamic> _adminLoginBody() => {
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
              for (final s in [
                'product_view',
                'category_view',
                'inventory_view',
                'inventory_adjust',
                'user_manage',
              ])
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _productJson({
  required String id,
  required String name,
  required String barcode,
  String price = '100.0',
  String cost = '80.0',
  String quantity = '10.0',
  String? categoryId,
  String? categoryName,
  bool archived = false,
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
      'cost': cost,
      'quantity': quantity,
      'low_stock_threshold': '5.0',
      'allow_negative_stock': false,
      'expiry_date': null,
      'image_path': null,
      'category_id': categoryId,
      'category_name': categoryName,
      'is_archived': archived,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _inventoryItem({
  required String id,
  required String name,
  String barcode = '111',
  String quantity = '12',
  String lowStockThreshold = '5',
  String avgCost = '80.5',
  String stockValue = '966.0',
  String cost = '75.0',
  String categoryName = 'Drinks',
}) =>
    {
      'product_id': id,
      'name': name,
      'barcode': barcode,
      'unit': 'piece',
      'quantity': quantity,
      'low_stock_threshold': lowStockThreshold,
      'allow_negative_stock': false,
      'cost': cost,
      'avg_cost': avgCost,
      'stock_value': stockValue,
      'price': '100.0',
      'is_archived': false,
      'category_id': '00000000-0000-0000-0000-0000000000c1',
      'category_name': categoryName,
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _movementJson({
  required String id,
  required String productId,
  required String productName,
}) =>
    {
      'id': id,
      'product_id': productId,
      'product_name': productName,
      'variant_id': null,
      'variant_name': null,
      'movement_type': 'adjustment',
      'quantity_change': '+5',
      'quantity_before': '10',
      'quantity_after': '15',
      'document_quantity': null,
      'document_unit': null,
      'purchase_unit_id': null,
      'packages_change': null,
      'unit_cost': null,
      'avg_cost_after': null,
      'reason': 'Cycle count',
      'source_document_type': null,
      'source_document_id': null,
      'user_id': '00000000-0000-0000-0000-0000000000a1',
      'user_name': 'Admin',
      'device_id': null,
      'movement_date': '2026-01-01T00:00:00Z',
      'created_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _movementsListBody() => {
      'items': [
        _movementJson(
          id: 'm1',
          productId: '00000000-0000-0000-0000-0000000000p1',
          productName: 'Apple Juice',
        ),
      ],
      'total': 1,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _categoriesListBody() => {
      'items': [
        {
          'id': '00000000-0000-0000-0000-0000000000c1',
          'name': 'Drinks',
          'parent_id': null,
          'sort_order': 0,
          'product_count': 1,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
    };

Map<String, dynamic> _inventoryListBody({
  String appleQuantity = '12',
}) =>
    {
      'items': [
        _inventoryItem(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Apple Juice',
          barcode: '111222333',
          quantity: appleQuantity,
        ),
        _inventoryItem(
          id: '00000000-0000-0000-0000-0000000000p2',
          name: 'Bread',
          barcode: '444555666',
          quantity: '3',
          lowStockThreshold: '5',
          avgCost: '30',
          stockValue: '90',
          categoryName: 'Bakery',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 100,
      'pages': 1,
      'total_stock_value': '1056.0',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  // A fresh (empty) prefs store per test: the page-size restore becomes a
  // no-op unless a test seeds one, and persists never leak across tests.
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  /// Full-app stub: auth + both list endpoints (with query logging and a
  /// per-test responder) + categories + movements + barcode lookup.
  void stubRequests(
    MockDio dio, {
    required Map<String, dynamic> Function(Map<String, dynamic> query)
        productsResponder,
    required Map<String, dynamic> Function(Map<String, dynamic> query)
        inventoryResponder,
    List<Map<String, dynamic>>? productQueryLog,
    List<Map<String, dynamic>>? inventoryQueryLog,
    Map<String, Map<String, dynamic>>? barcodeLookups,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
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
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_loginPath, _adminLoginBody()),
    );
    when(() => dio.post('/api/v1/auth/logout-token', data: any(named: 'data')))
        .thenAnswer(
      (_) async => okResponse('/api/v1/auth/logout-token', {
        'message': 'logged out',
      }),
    );
    when(
      () => dio.get(
        _productsPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final q = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      productQueryLog?.add(q);
      return okResponse(_productsPath, productsResponder(q));
    });
    when(
      () => dio.get(
        _categoriesPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => okResponse(_categoriesPath, _categoriesListBody()),
    );
    when(
      () => dio.get(
        _inventoryPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final q = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      inventoryQueryLog?.add(q);
      return okResponse(_inventoryPath, inventoryResponder(q));
    });
    when(
      () => dio.get(
        _movementsPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => okResponse(_movementsPath, _movementsListBody()),
    );
    when(
      () => dio.get(
        '/api/v1/products/barcode-lookup',
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final q = invocation.namedArguments[#queryParameters];
      final barcode = q is Map ? q['barcode']?.toString() ?? '' : '';
      return okResponse(
        '/api/v1/products/barcode-lookup',
        barcodeLookups?[barcode] ?? {'found': false},
      );
    });
  }

  /// Filters a stub item list the way the server would (name or barcode
  /// contains the search text).
  List<Map<String, dynamic>> filterItems(
    List<Map<String, dynamic>> items,
    Map<String, dynamic> q,
  ) {
    final search = q['search']?.toString().trim() ?? '';
    if (search.isEmpty) return items;
    return items
        .where((item) {
          final name = item['name'] as String? ?? '';
          final barcode = item['barcode'] as String? ?? '';
          return name.contains(search) || barcode.contains(search);
        })
        .toList();
  }

  /// Single-page default bodies (two products / two inventory items).
  Map<String, dynamic> defaultProducts(Map<String, dynamic> q) {
    final items = [
      _productJson(
        id: '00000000-0000-0000-0000-0000000000p1',
        name: 'Apple Juice',
        barcode: '111222333',
        categoryId: '00000000-0000-0000-0000-0000000000c1',
        categoryName: 'Drinks',
      ),
      _productJson(
        id: '00000000-0000-0000-0000-0000000000p2',
        name: 'Bread',
        barcode: '444555666',
        price: '50.0',
        cost: '30.0',
        quantity: '20.0',
      ),
    ];
    return {
      'items': filterItems(items, q),
      'total': 2,
      'page': 1,
      'page_size': q['page_size'],
      'pages': 1,
    };
  }

  /// Single-page default inventory body, name-filtered like the server.
  Map<String, dynamic> filteredInventory(Map<String, dynamic> q) {
    final body = _inventoryListBody();
    return {
      ...body,
      'items': filterItems(
        (body['items'] as List).cast<Map<String, dynamic>>(),
        q,
      ),
    };
  }

  Future<void> pumpApp(WidgetTester tester, MockDio dio) async {
    tester.view.physicalSize = const Size(1600, 900);
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
  }

  /// Rail navigation by the stable route key (the ShellRoute builder
  /// creates a fresh State per visit — the lifecycle hook under test).
  Future<void> navTo(WidgetTester tester, String path) async {
    await tester.tap(
      find.byKey(Key('nav-item-$path')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Future<void> searchFor(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const Key('products-search-field')),
      text,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// Opens a footer dropdown and picks an option. No ensureVisible: the
  /// stock footer lives inside the TabBarView's PageView, and scrolling
  /// to it would swipe the pager to the movements tab.
  Future<void> selectDropdownOption(
    WidgetTester tester,
    Key dropdownKey,
    String label,
  ) async {
    await tester.tap(find.byKey(dropdownKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  String productsSearchText(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.byKey(const Key('products-search-field')),
    );
    return field.controller?.text ?? '';
  }

  String stockSearchText(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.byKey(const Key('stock-search')),
    );
    return field.controller?.text ?? '';
  }

  group('Products route re-activation', () {
    testWidgets('search -> leave -> return shows the refreshed unfiltered '
        'list with an empty search box', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        productQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');

      await searchFor(tester, 'Apple');
      expect(queryLog.last['search'], 'Apple');
      expect(find.text('Bread'), findsNothing);

      await navTo(tester, '/');
      expect(find.byType(ProductsScreen), findsNothing);

      final requestsBefore = queryLog.length;
      await navTo(tester, '/products');

      expect(find.byType(ProductsScreen), findsOneWidget);
      expect(productsSearchText(tester), isEmpty);
      expect(queryLog.last.containsKey('search'), isFalse);
      expect(queryLog.last['page'], 1);
      expect(queryLog.last['status'], 'active');
      expect(queryLog.length, greaterThan(requestsBefore));
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('barcode scan -> leave -> return shows the refreshed list '
        'without the scan filter or highlight', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        productQueryLog: queryLog,
        barcodeLookups: {
          '444555666': {
            'found': true,
            'kind': 'product',
            'product_id': '00000000-0000-0000-0000-0000000000p2',
            'product_name': 'Bread',
            'product_price': '50.0',
            'product_quantity': '20.0',
            'product_unit': 'piece',
            'is_archived': false,
          },
        },
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');

      // A raw wedge burst: the scan filters the catalog to the hit and
      // highlights the matching row.
      await sendWedgeScan(tester, '444555666');
      await tester.pumpAndSettle();
      expect(queryLog.last['search'], '444555666');
      expect(
        find.byKey(const ValueKey(
          'product-row-highlight-00000000-0000-0000-0000-0000000000p2',
        )),
        findsOneWidget,
      );

      await navTo(tester, '/');
      await navTo(tester, '/products');

      // The highlight is State-local and dies with the old screen; the
      // catalog query is back to defaults and the list is refreshed.
      expect(
        find.byKey(const ValueKey(
          'product-row-highlight-00000000-0000-0000-0000-0000000000p2',
        )),
        findsNothing,
      );
      expect(productsSearchText(tester), isEmpty);
      expect(queryLog.last.containsKey('search'), isFalse);
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      // The fresh screen still answers scans (one handler, functional).
      expect(BarcodeScannerGateway.instance.handlerCount, 1);
      await sendWedgeScan(tester, '444555666');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(
          'product-row-highlight-00000000-0000-0000-0000-0000000000p2',
        )),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh and route changes never duplicate scanner handlers',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await tester.ensureVisible(
        find.byKey(const Key('products-refresh-button')),
      );
      await tester.tap(
        find.byKey(const Key('products-refresh-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await navTo(tester, '/');
      await navTo(tester, '/products');
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await navTo(tester, '/stock');
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await tester.ensureVisible(
        find.byKey(const Key('stock-toolbar-refresh')),
      );
      await tester.tap(
        find.byKey(const Key('stock-toolbar-refresh')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await navTo(tester, '/');
      await navTo(tester, '/stock');
      expect(BarcodeScannerGateway.instance.handlerCount, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('Stock route re-activation', () {
    testWidgets('search -> leave -> return shows the refreshed unfiltered '
        'list with an empty search box', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: filteredInventory,
        inventoryQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/stock');

      await tester.enterText(find.byKey(const Key('stock-search')), 'Apple');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(queryLog.last['search'], 'Apple');
      expect(find.text('Bread'), findsNothing);

      await navTo(tester, '/');
      expect(find.byType(StockScreen), findsNothing);

      final requestsBefore = queryLog.length;
      await navTo(tester, '/stock');

      expect(find.byType(StockScreen), findsOneWidget);
      expect(stockSearchText(tester), isEmpty);
      expect(queryLog.last.containsKey('search'), isFalse);
      expect(queryLog.last['page'], 1);
      expect(queryLog.length, greaterThan(requestsBefore));
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stock quantity changed elsewhere is reflected after '
        'returning to the screen', (tester) async {
      final dio = MockDio();
      var appleQuantity = '12';
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) =>
            _inventoryListBody(appleQuantity: appleQuantity),
        inventoryQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/stock');

      expect(find.text('12'), findsOneWidget);

      await navTo(tester, '/');
      // Adjusted in another screen / device while Stock was left.
      appleQuantity = '17';

      final requestsBefore = queryLog.length;
      await navTo(tester, '/stock');

      expect(queryLog.length, greaterThan(requestsBefore));
      expect(find.text('17'), findsOneWidget);
      expect(find.text('12'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Page size (25/50/100, default 100)', () {
    testWidgets('products: requests page_size=100 by default, the selector '
        'offers exactly 25/50/100 and every choice is sent server-side',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        productQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');

      expect(queryLog.first['page_size'], 100);
      expect(queryLog.first['page'], 1);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('products-page-size')),
      );
      expect(
        dropdown.items!.map((item) => item.value).toList(),
        [25, 50, 100],
      );
      expect(dropdown.value, 100);

      await selectDropdownOption(tester, const Key('products-page-size'), '25');
      expect(queryLog.last['page_size'], 25);
      expect(queryLog.last['page'], 1);

      await selectDropdownOption(tester, const Key('products-page-size'), '50');
      expect(queryLog.last['page_size'], 50);

      await selectDropdownOption(tester, const Key('products-page-size'), '100');
      expect(queryLog.last['page_size'], 100);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stock: requests page_size=100 by default, the selector '
        'offers exactly 25/50/100 and every choice is sent server-side',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        inventoryQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/stock');

      expect(queryLog.first['page_size'], 100);
      expect(queryLog.first['page'], 1);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('stock-page-size')),
      );
      expect(
        dropdown.items!.map((item) => item.value).toList(),
        [25, 50, 100],
      );
      expect(dropdown.value, 100);

      await selectDropdownOption(tester, const Key('stock-page-size'), '25');
      expect(queryLog.last['page_size'], 25);
      expect(queryLog.last['page'], 1);

      await selectDropdownOption(tester, const Key('stock-page-size'), '50');
      expect(queryLog.last['page_size'], 50);

      await selectDropdownOption(tester, const Key('stock-page-size'), '100');
      expect(queryLog.last['page_size'], 100);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the products page-size choice persists', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');

      await selectDropdownOption(tester, const Key('products-page-size'), '25');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(kProductsPageSizeKey), 25);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a saved stock page-size preference is applied to the first '
        'load and the selector', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kInventoryPageSizeKey: 50,
      });
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        inventoryQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/stock');

      expect(queryLog.last['page_size'], 50);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('stock-page-size')),
      );
      expect(dropdown.value, 50);
      expect(tester.takeException(), isNull);
    });
  });

  group('Products pagination', () {
    var pages = 2;

    // Two-page catalog: page 2 holds Bread only.
    Map<String, dynamic> twoPageProducts(Map<String, dynamic> q) {
      final page = (q['page'] as num?)?.toInt() ?? 1;
      return {
        'items': page == 2
            ? [
                _productJson(
                  id: '00000000-0000-0000-0000-0000000000p2',
                  name: 'Bread',
                  barcode: '444555666',
                  price: '50.0',
                  cost: '30.0',
                  quantity: '20.0',
                ),
              ]
            : [
                _productJson(
                  id: '00000000-0000-0000-0000-0000000000p1',
                  name: 'Apple Juice',
                  barcode: '111222333',
                  categoryId: '00000000-0000-0000-0000-0000000000c1',
                  categoryName: 'Drinks',
                ),
              ],
        'total': 3,
        'page': page,
        'page_size': q['page_size'],
        'pages': pages,
      };
    }

    testWidgets('boundary controls, search/sort page-reset, and clamping '
        'an out-of-range page back to the last page', (tester) async {
      pages = 2;
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: twoPageProducts,
        inventoryResponder: (_) => _inventoryListBody(),
        productQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/products');

      final prev = find.byKey(const Key('products-prev-page'));
      final next = find.byKey(const Key('products-next-page'));
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.widget<IconButton>(prev).onPressed, isNull);

      await tester.ensureVisible(next);
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Apple Juice'), findsNothing);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(tester.widget<IconButton>(next).onPressed, isNull);

      await tester.ensureVisible(prev);
      await tester.tap(prev, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 1);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('Apple Juice'), findsOneWidget);

      // A search change resets to page 1 (from page 2).
      await tester.ensureVisible(next);
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      await searchFor(tester, 'Apple');
      expect(queryLog.last['search'], 'Apple');
      expect(queryLog.last['page'], 1);

      // A sort change resets to page 1 (from page 2).
      await tester.ensureVisible(next);
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      await tester.ensureVisible(
        find.byKey(const Key('products-sort-filter')),
      );
      await tester.tap(
        find.byKey(const Key('products-sort-filter')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('${AppStrings.t('sort_price', 'ar')} ↑'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(queryLog.last['sort_by'], 'price');
      expect(queryLog.last['sort_order'], 'asc');
      expect(queryLog.last['page'], 1);

      // The result shrinks to one page while the user sits on page 2:
      // refresh requests page 2, gets pages=1 and clamps to page 1.
      await tester.ensureVisible(next);
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      pages = 1;
      await tester.ensureVisible(
        find.byKey(const Key('products-refresh-button')),
      );
      await tester.tap(
        find.byKey(const Key('products-refresh-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      final tail = queryLog.sublist(queryLog.length - 2);
      expect(tail[0]['page'], 2); // the refresh request
      expect(tail[1]['page'], 1); // the clamp retry
      expect(find.text('1 / 1'), findsOneWidget);
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('Stock pagination', () {
    testWidgets('boundary controls follow the server-reported page count '
        'and a search change resets to page 1', (tester) async {
      Map<String, dynamic> twoPageInventory(Map<String, dynamic> q) {
        final page = (q['page'] as num?)?.toInt() ?? 1;
        return {
          'items': page == 2
              ? [
                  _inventoryItem(
                    id: '00000000-0000-0000-0000-0000000000p2',
                    name: 'Bread',
                    barcode: '444555666',
                    quantity: '3',
                    lowStockThreshold: '5',
                    avgCost: '30',
                    stockValue: '90',
                    categoryName: 'Bakery',
                  ),
                ]
              : [
                  _inventoryItem(
                    id: '00000000-0000-0000-0000-0000000000p1',
                    name: 'Apple Juice',
                    barcode: '111222333',
                  ),
                ],
          'total': 3,
          'page': page,
          'page_size': q['page_size'],
          'pages': 2,
          'total_stock_value': '1056.0',
        };
      }

      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productsResponder: defaultProducts,
        inventoryResponder: twoPageInventory,
        inventoryQueryLog: queryLog,
      );
      await pumpApp(tester, dio);
      await navTo(tester, '/stock');

      final prev = find.byKey(const Key('stock-prev-page'));
      final next = find.byKey(const Key('stock-next-page'));
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.widget<IconButton>(prev).onPressed, isNull);

      // Never call ensureVisible here: the footer lives inside the
      // TabBarView's PageView, and ensureVisible would scroll that
      // horizontal pager to the movements tab instead of the footer.
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Apple Juice'), findsNothing);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(tester.widget<IconButton>(next).onPressed, isNull);

      await tester.tap(prev, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 1);
      expect(find.text('1 / 2'), findsOneWidget);

      // A search change resets to page 1 (from page 2).
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(queryLog.last['page'], 2);
      await tester.enterText(find.byKey(const Key('stock-search')), 'Apple');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(queryLog.last['search'], 'Apple');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });
  });
}
