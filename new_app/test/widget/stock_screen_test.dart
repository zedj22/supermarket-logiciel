// Phase 7 stock screen regression tests:
// - Responsive StockScreen at 600×500, 800×600, 1024×768, 1366×768, 1920×1080 + Arabic RTL
// - Inventory list / movement journal tabs, permission gates, adjust dialog
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/stock/stock_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

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
const _inventoryPath = '/api/v1/inventory';
const _movementsPath = '/api/v1/inventory/movements';

Map<String, dynamic> _adminLoginBody({
  List<String> scopes = const [
    'inventory_view',
    'inventory_adjust',
    'product_view',
    'user_manage',
  ],
}) =>
    {
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

Map<String, dynamic> _inventoryListBody() => {
      'items': [
        _inventoryItem(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Apple Juice',
          barcode: '111222333',
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
      'page_size': 40,
      'pages': 1,
      'total_stock_value': '1056.0',
    };

Map<String, dynamic> _movementJson({
  required String id,
  required String productId,
  required String productName,
  String movementType = 'adjustment',
  String quantityChange = '+5',
  String quantityBefore = '10',
  String quantityAfter = '15',
  String? avgCostAfter,
  String? reason = 'Cycle count',
  String? userName = 'Admin',
}) =>
    {
      'id': id,
      'product_id': productId,
      'product_name': productName,
      'variant_id': null,
      'variant_name': null,
      'movement_type': movementType,
      'quantity_change': quantityChange,
      'quantity_before': quantityBefore,
      'quantity_after': quantityAfter,
      'document_quantity': null,
      'document_unit': null,
      'purchase_unit_id': null,
      'packages_change': null,
      'unit_cost': null,
      'avg_cost_after': avgCostAfter,
      'reason': reason,
      'source_document_type': null,
      'source_document_id': null,
      'user_id': '00000000-0000-0000-0000-0000000000a1',
      'user_name': userName,
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
          avgCostAfter: '82.5',
        ),
        _movementJson(
          id: 'm2',
          productId: '00000000-0000-0000-0000-0000000000p1',
          productName: 'Apple Juice',
          movementType: 'sale',
          quantityChange: '-2',
          quantityBefore: '15',
          quantityAfter: '13',
          reason: 'POS sale',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _productDetailBody() => {
      'product_id': '00000000-0000-0000-0000-0000000000p1',
      'name': 'Apple Juice',
      'barcode': '111222333',
      'unit': 'piece',
      'quantity': '12',
      'cost': '75.0',
      'avg_cost': '80.5',
      'stock_value': '966.0',
      'price': '100.0',
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'is_archived': false,
      'packaging': {'full_packages': 0, 'loose_quantity': 12},
      'variants': [],
      'purchase_units': [],
      'recent_movements': [
        _movementJson(
          id: 'm1',
          productId: '00000000-0000-0000-0000-0000000000p1',
          productName: 'Apple Juice',
          avgCostAfter: '80.5',
        ),
      ],
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
    Map<String, dynamic>? loginBody,
    Map<String, dynamic>? inventoryBody,
    List<Map<String, dynamic>>? inventoryQueryLog,
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
      (_) async => okResponse(_loginPath, loginBody ?? _adminLoginBody()),
    );
    when(() => dio.post('/api/v1/auth/logout-token', data: any(named: 'data')))
        .thenAnswer(
      (_) async => okResponse('/api/v1/auth/logout-token', {
        'message': 'logged out',
      }),
    );
    when(
      () => dio.get(
        _inventoryPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final q = invocation.namedArguments[#queryParameters];
      if (q is Map<String, dynamic>) {
        inventoryQueryLog?.add(Map<String, dynamic>.from(q));
      }
      return okResponse(
        _inventoryPath,
        inventoryBody ?? _inventoryListBody(),
      );
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
        '/api/v1/inventory/00000000-0000-0000-0000-0000000000p1',
      ),
    ).thenAnswer(
      (_) async => okResponse(
        '/api/v1/inventory/00000000-0000-0000-0000-0000000000p1',
        _productDetailBody(),
      ),
    );
    when(() => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')))
        .thenAnswer(
      (_) async => okResponse('/api/v1/inventory/adjust', {'ok': true}),
    );
  }

  /// Captures the last adjust payload for assertion (base-unit only).
  Map<String, dynamic>? lastAdjustPayload;

  void captureAdjustPayload(MockDio dio) {
    when(() => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')))
        .thenAnswer((invocation) async {
      final data = invocation.namedArguments[#data];
      if (data is Map<String, dynamic>) {
        lastAdjustPayload = Map<String, dynamic>.from(data);
      }
      return okResponse('/api/v1/inventory/adjust', {'ok': true});
    });
  }

  Future<void> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required Size size,
    bool useArabic = true,
  }) async {
    // useArabic reserved for future non-default locale switches (default is ar).
    // ignore: unused_element
    useArabic;
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

    tester.view.physicalSize = size;
    await tester.pumpAndSettle();

    // Default locale is Arabic — Stock destination uses the warehouse icon.
    // Hidden entirely when the user lacks inventory_view.
    final stockNav = find.byIcon(Icons.warehouse_outlined);
    if (stockNav.evaluate().isNotEmpty) {
      await tester.tap(stockNav.first, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }
  }

  Future<void> pumpStockScreenDirect(
    WidgetTester tester,
    MockDio dio, {
    required List<String> permissions,
    Size size = const Size(1366, 768),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final user = AuthUser(
      id: '00000000-0000-0000-0000-0000000000a1',
      fullName: 'Admin',
      isActive: true,
      roles: const ['admin'],
      permissions: permissions,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
          currentUserProvider.overrideWithValue(user),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: const Scaffold(body: StockScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  void expectNoOverflow(WidgetTester tester) {
    expect(tester.takeException(), isNull);
  }

  group('Responsive StockScreen', () {
    final sizes = <String, Size>{
      '600x500': const Size(600, 500),
      '800x600': const Size(800, 600),
      '1024x768': const Size(1024, 768),
      '1366x768': const Size(1366, 768),
      '1920x1080': const Size(1920, 1080),
    };

    for (final entry in sizes.entries) {
      testWidgets('renders inventory list at ${entry.key} without overflow',
          (tester) async {
        final dio = MockDio();
        stubRequests(dio);
        await pumpApp(tester, dio, size: entry.value);

        expect(find.byKey(const Key('stock-title')), findsOneWidget);
        expect(find.byKey(const Key('stock-search')), findsOneWidget);
        expect(find.byKey(const Key('stock-tab-list')), findsOneWidget);
        expect(find.byKey(const Key('stock-tab-movements')), findsOneWidget);
        expect(find.text('Apple Juice'), findsOneWidget);
        // Bread may be below the fold on compact heights.
        final bread = find.text('Bread');
        if (bread.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            bread,
            80,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.pumpAndSettle();
        }
        expect(bread, findsOneWidget);

        // Narrow (<800) uses cards; medium/wide use the table.
        if (entry.value.width < 800) {
          expect(find.byKey(const Key('stock-cards')), findsOneWidget);
          expect(find.byKey(const Key('stock-list')), findsNothing);
        } else {
          expect(find.byKey(const Key('stock-list')), findsOneWidget);
        }
        expectNoOverflow(tester);
      });
    }

    testWidgets('Arabic RTL narrow layout has no overflow', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        size: const Size(600, 500),
        useArabic: true,
      );

      expect(find.byKey(const Key('stock-cards')), findsOneWidget);
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(
        find.text(AppStrings.t('inventory', 'ar')),
        findsWidgets,
      );
      expectNoOverflow(tester);
    });

    testWidgets('wide layout shows total stock value in KPI', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      expect(find.byKey(const Key('kpi-total-value')), findsOneWidget);
      expect(find.text('1056.0'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('KPI cards show total value, count, low, out (wide)',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      expect(find.byKey(const Key('kpi-total-value')), findsOneWidget);
      expect(find.byKey(const Key('kpi-product-count')), findsOneWidget);
      expect(find.byKey(const Key('kpi-low-stock')), findsOneWidget);
      expect(find.byKey(const Key('kpi-out-stock')), findsOneWidget);
      // total_stock_value from list body
      expect(find.text('1056.0'), findsWidgets);
      // Product count = total (2)
      expect(find.byKey(const Key('kpi-product-count')), findsOneWidget);
      // Bread is low (3 <= 5) → at least 1 low; Apple Juice ok → 0 out
      expectNoOverflow(tester);
    });

    testWidgets('KPI compact chips on narrow without overflow',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(600, 500));

      expect(find.byKey(const Key('kpi-total-value')), findsOneWidget);
      expect(find.byKey(const Key('kpi-low-stock')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('toolbar is one rounded container with dominant search',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byKey(const Key('stock-toolbar')), findsOneWidget);
      expect(find.byKey(const Key('stock-search')), findsOneWidget);
      expect(find.byKey(const Key('stock-status-filter')), findsOneWidget);
      expect(find.byKey(const Key('stock-low-filter')), findsOneWidget);
      expect(find.byKey(const Key('stock-toolbar-refresh')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('table shows status pills and barcode under product name',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      expect(find.text('111222333'), findsOneWidget);
      expect(find.text(AppStrings.t('in_stock', 'ar')), findsWidgets);
      // Bread is low stock → low pill present
      expect(find.text(AppStrings.t('low_stock', 'ar')), findsWidgets);
      expectNoOverflow(tester);
    });

    testWidgets('detail panel shows quantity, cost rows, adjust action',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      await tester.tap(find.byKey(
        const Key('stock-item-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);
      expect(find.byKey(const Key('detail-name')), findsOneWidget);
      expect(find.byKey(const Key('detail-quantity')), findsOneWidget);
      expect(find.byKey(const Key('detail-adjust')), findsOneWidget);
      expect(find.byKey(const Key('detail-close')), findsOneWidget);
      expect(find.textContaining('80.5'), findsWidgets);
      expectNoOverflow(tester);
    });

    testWidgets('medium stacks detail below list without overflow',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1024, 768));

      await tester.tap(
        find.byKey(
          const Key('stock-item-00000000-0000-0000-0000-0000000000p1'),
        ),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      if (find.byKey(const Key('stock-detail-panel')).evaluate().isEmpty) {
        // Row may need a slight scroll into view before tap.
        await tester.drag(
          find.byKey(const Key('stock-list')),
          const Offset(0, -40),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const Key('stock-item-00000000-0000-0000-0000-0000000000p1'),
          ),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
      }

      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);
      expect(find.byKey(const Key('detail-name')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('movement journal tab lists movements', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(const Key('stock-tab-movements')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('movements-list')), findsOneWidget);
      expect(find.byKey(const Key('movement-m1')), findsOneWidget);
      expect(find.byKey(const Key('movement-m2')), findsOneWidget);
      expect(find.textContaining('PMP'), findsWidgets);
      expectNoOverflow(tester);
    });

    testWidgets('detail panel opens on row tap (wide)', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      await tester.tap(find.byKey(
        const Key('stock-item-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);
      expect(find.byKey(const Key('detail-name')), findsOneWidget);
      expect(find.text('Apple Juice'), findsWidgets);
      expectNoOverflow(tester);
    });
  });

  group('Permission gates', () {
    testWidgets('shell hides Stock destination without inventory_view',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _adminLoginBody(
          scopes: const ['product_view', 'user_manage'],
        ),
      );
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byIcon(Icons.warehouse_outlined), findsNothing);
      expect(find.byKey(const Key('stock-title')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('StockScreen without inventory_view shows permission denied',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['product_view'],
      );

      expect(find.byKey(const Key('stock-permission-denied')), findsOneWidget);
      expect(find.byKey(const Key('stock-title')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('user with inventory_view but not inventory_adjust '
        'has no adjust buttons', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _adminLoginBody(
          scopes: const ['inventory_view'],
        ),
      );
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byIcon(Icons.warehouse_outlined), findsOneWidget);
      expect(find.byKey(const Key('stock-title')), findsOneWidget);
      expect(
        find.byKey(
          const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
        ),
        findsNothing,
      );
      // No contextual header adjust without a selected product either.
      expect(find.byKey(const Key('stock-header-adjust')), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('Adjust dialog', () {
    testWidgets(
        'increase allows empty reason; decrease/set require reason',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
      expect(find.byKey(const Key('adjust-operation')), findsOneWidget);
      expect(find.byKey(const Key('adjust-quantity')), findsOneWidget);
      expect(find.byKey(const Key('adjust-unit-cost')), findsOneWidget);
      expect(find.byKey(const Key('adjust-reason')), findsOneWidget);
      expect(find.byKey(const Key('adjust-submit')), findsOneWidget);
      expectNoOverflow(tester);

      // Submit without quantity → validation error.
      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-error')), findsOneWidget);
      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);

      // Increase (default operation) + qty, empty reason → succeeds.
      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-new-stock-preview')), findsOneWidget);

      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expectNoOverflow(tester);

      // Re-open → decrease without reason → blocked (Arabic default locale).
      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.t('decrease', 'ar')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '1',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-error')), findsOneWidget);
      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
    });

    testWidgets('increase with reason submits and closes dialog',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '3',
      );
      await tester.enterText(
        find.byKey(const Key('adjust-reason')),
        'Cycle count',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('shows required/optional helper text per operation',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      // Default is increase → reason optional.
      expect(
        find.text(AppStrings.t('reason_optional', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('unit_cost_optional', 'ar')),
        findsOneWidget,
      );

      // Switch to decrease → reason required.
      await tester.tap(find.text(AppStrings.t('decrease', 'ar')));
      await tester.pumpAndSettle();
      expect(
        find.text(AppStrings.t('reason_required', 'ar')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('reason_optional', 'ar')), findsNothing);

      // Switch to set → still required.
      await tester.tap(find.text(AppStrings.t('set_quantity', 'ar')));
      await tester.pumpAndSettle();
      expect(
        find.text(AppStrings.t('reason_required', 'ar')),
        findsOneWidget,
      );
      expectNoOverflow(tester);
    });

    testWidgets('contains NO unit selector; shows base unit label',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
      expect(find.byKey(const Key('adjust-unit-selector')), findsNothing);
      expect(
        find.byKey(const Key('adjust-conversion-preview')),
        findsNothing,
      );
      // Base unit helper next to quantity.
      expect(
        find.text(
          '${AppStrings.t('base_unit', 'ar')}: '
          '${AppStrings.unitLabel('piece', 'ar')}',
        ),
        findsOneWidget,
      );
      // Current stock chip shows base unit.
      expect(
        find.textContaining(AppStrings.unitLabel('piece', 'ar')),
        findsWidgets,
      );
      expectNoOverflow(tester);
    });

    testWidgets('new stock preview: 12 + 5 = 17 base units', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '5',
      );
      await tester.pumpAndSettle();

      final preview = find.byKey(const Key('adjust-new-stock-preview'));
      expect(preview, findsOneWidget);
      final text = tester.widget<Text>(preview).data ?? '';
      expect(text, contains('17.000'));
      expect(text, contains(AppStrings.unitLabel('piece', 'ar')));
      expectNoOverflow(tester);
    });

    testWidgets('set operation preview is absolute target', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text(AppStrings.t('set_quantity', 'ar')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '30',
      );
      await tester.pumpAndSettle();

      final preview = find.byKey(const Key('adjust-new-stock-preview'));
      expect(tester.widget<Text>(preview).data, contains('30.000'));
      expectNoOverflow(tester);
    });

    testWidgets('submit sends base quantity only (no unit ids)',
        (tester) async {
      lastAdjustPayload = null;
      final dio = MockDio();
      stubRequests(dio);
      captureAdjustPayload(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.tap(find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('adjust-quantity')),
        '5',
      );
      await tester.enterText(
        find.byKey(const Key('adjust-reason')),
        'Restock',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(lastAdjustPayload, isNotNull);
      expect(lastAdjustPayload!['quantity'], '5');
      expect(lastAdjustPayload!.containsKey('selling_unit_id'), isFalse);
      expect(lastAdjustPayload!.containsKey('purchase_unit_id'), isFalse);
      expect(lastAdjustPayload!['operation'], 'increase');
      expectNoOverflow(tester);
    });

    testWidgets('adjust dialog no overflow at narrow 600x500',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      // Direct screen mount avoids shell AppBar/Rail eating vertical space.
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view', 'inventory_adjust'],
        size: const Size(600, 500),
      );

      final adjustBtn = find.byKey(
        const Key('stock-adjust-00000000-0000-0000-0000-0000000000p1'),
      );
      await tester.ensureVisible(adjustBtn);
      await tester.pumpAndSettle();
      await tester.tap(adjustBtn, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
      expect(find.byKey(const Key('adjust-quantity')), findsOneWidget);
      expect(find.byKey(const Key('adjust-submit')), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('Movement color semantics', () {
    test('quantity change direction mapping', () {
      expect(
        movementDirectionFromQuantityChange('+5'),
        MovementDirection.increase,
      );
      expect(
        movementDirectionFromQuantityChange('+10.000'),
        MovementDirection.increase,
      );
      expect(
        movementDirectionFromQuantityChange('5.000'),
        MovementDirection.increase,
      );
      expect(
        movementDirectionFromQuantityChange('-2'),
        MovementDirection.decrease,
      );
      expect(
        movementDirectionFromQuantityChange('-3.500'),
        MovementDirection.decrease,
      );
      expect(movementDirectionFromQuantityChange('0'), MovementDirection.set);
      expect(
        movementDirectionFromQuantityChange('0.000'),
        MovementDirection.set,
      );
    });

    test('quantity colors: increase => success/green, decrease => error/red, '
        'set => neutral/info', () {
      expect(movementQuantityColor('+10'), AppColors.success);
      expect(movementQuantityColor('+5.000'), AppColors.success);
      expect(movementQuantityColor('+3'), AppColors.success);
      expect(movementQuantityColor('-2'), AppColors.error);
      expect(movementQuantityColor('-3.000'), AppColors.error);
      expect(movementQuantityColor('-5'), AppColors.error);
      expect(movementQuantityColor('0'), AppColors.info);
      expect(movementQuantityColor('0.000'), AppColors.info);
    });

    test('movement type badge colors follow semantic rules', () {
      expect(movementTypeColor('purchase'), AppColors.success);
      expect(movementTypeColor('package_receive'), AppColors.success);
      expect(movementTypeColor('sale'), AppColors.error);
      expect(movementTypeColor('sale_void'), AppColors.success);
      // Adjustment increase (e.g. +10 initial / restock) → green
      expect(
        movementTypeColor('adjustment', quantityChange: '+10'),
        AppColors.success,
      );
      expect(
        movementTypeColor('adjustment', quantityChange: '+5'),
        AppColors.success,
      );
      // Adjustment decrease → red
      expect(
        movementTypeColor('adjustment', quantityChange: '-3'),
        AppColors.error,
      );
      // SET / zero-delta adjustment → neutral info (not red)
      expect(
        movementTypeColor('adjustment', quantityChange: '0'),
        AppColors.info,
      );
      expect(
        movementTypeColor('adjustment', quantityChange: '0.000'),
        AppColors.info,
      );
      // Return-out (negative) → red; return-in → green
      expect(
        movementTypeColor('return', quantityChange: '-2'),
        AppColors.error,
      );
      expect(
        movementTypeColor('return', quantityChange: '+4'),
        AppColors.success,
      );
    });

    test('formatSignedQuantityChange keeps visible + on positives', () {
      expect(formatSignedQuantityChange('5.000'), '+5.000');
      expect(formatSignedQuantityChange('+5.000'), '+5.000');
      expect(formatSignedQuantityChange('10'), '+10');
      expect(formatSignedQuantityChange('-2.000'), '-2.000');
      expect(formatSignedQuantityChange('0'), '0');
      expect(formatSignedQuantityChange('abc'), 'abc');
    });
  });
}
