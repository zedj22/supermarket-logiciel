// Phase 7 stock screen regression tests:
// - Responsive StockScreen at 600×500, 800×600, 1024×768, 1366×768, 1920×1080 + Arabic RTL
// - Inventory list / movement journal tabs, permission gates, adjust dialog
// - Quantity vs average-cost column separation (RTL + LTR), see the
//   'Inventory numeric column separation' group at the bottom.
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/core/widgets/status_chip.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/stock/stock_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

import '../helpers/wedge_scanner.dart';

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

/// Loads the bundled app font so layout tests measure production text
/// metrics (`flutter test` falls back to 1em-per-glyph test glyphs for
/// families it has not been given — which would wrap the average-cost
/// value in its cell and fake the very collision under test).
Future<void> _loadAppFonts() async {
  final loader = FontLoader('IBMPlexSansArabic')
    ..addFont(rootBundle.load('assets/fonts/IBMPlexSansArabic-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/IBMPlexSansArabic-Bold.ttf'));
  await loader.load();
}

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

/// Screenshot values for the quantity/average-cost separation tests:
/// quantity `35.000` and average cost `1 500.000` (as rendered by
/// [formatGrouped]) used to collide in the RTL table.
Map<String, dynamic> _separationListBody() => {
      'items': [
        _inventoryItem(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Huile de table',
          barcode: '111222333',
          quantity: '35.000',
          avgCost: '1500.000',
          stockValue: '52500.000',
          cost: '1400.000',
        ),
        _inventoryItem(
          id: '00000000-0000-0000-0000-0000000000p2',
          name: 'Bread',
          barcode: '444555666',
          quantity: '3',
          avgCost: '30',
          stockValue: '90',
          categoryName: 'Bakery',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 40,
      'pages': 1,
      // Deliberately NOT the sum of the cell values: the KPI total must
      // never duplicate a table cell string the tests look up by exact
      // text (find.text would then match twice).
      'total_stock_value': '57750.000',
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
    Locale locale = const Locale('ar'),
    ThemeData? theme,
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

    // The screen reads its strings from localeProvider (not from
    // MaterialApp), so both must follow the requested locale.
    final appLocale = switch (locale.languageCode) {
      'en' => AppLocale.en,
      'fr' => AppLocale.fr,
      _ => AppLocale.ar,
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
          currentUserProvider.overrideWithValue(user),
          localeProvider
              .overrideWith((_) => LocaleNotifier()..setLocale(appLocale)),
        ],
        child: MaterialApp(
          locale: locale,
          theme: theme,
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
      expect(find.text('1 056.0'), findsOneWidget);
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
      expect(find.text('1 056.0'), findsWidgets);
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

    testWidgets('Phase 17 §17.2 the stock heading is pinned above the list',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      final header = find.byKey(const Key('stock-table-header'));
      final list = find.byKey(const Key('stock-list'));
      expect(header, findsOneWidget);
      expect(list, findsOneWidget);
      // The heading sits *above* the scrolling list, never inside it.
      final scroller = find.descendant(of: list, matching: find.byType(ListView));
      expect(scroller, findsOneWidget);
      expect(find.descendant(of: scroller, matching: header), findsNothing);

      final before = tester.getTopLeft(header);
      expect(tester.getTopLeft(scroller).dy, greaterThan(before.dy));

      await tester.drag(scroller, const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header), before,
          reason: 'the heading must not travel with the rows');
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
      expect(formatSignedQuantityChange('+4'), '+4');
      expect(formatSignedQuantityChange('abc'), 'abc');
    });
  });

  group('Stock barcode scan (Enter in search)', () {
    testWidgets('known barcode locates the item and opens the detail panel '
        'without posting an adjustment', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        barcodeLookups: {
          '111222333': {
            'found': true,
            'kind': 'product',
            'product_id': '00000000-0000-0000-0000-0000000000p1',
            'product_name': 'Apple Juice',
            'product_price': '100.0',
            'product_quantity': '12',
            'product_unit': 'piece',
            'is_archived': false,
          },
        },
      );
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      // The wedge types the code and hits Enter immediately — the scan
      // resolves through the canonical lookup, selects the matching item
      // and opens the EXISTING detail panel. A scan never mutates stock.
      await tester.enterText(
        find.byKey(const Key('stock-search')),
        '111222333',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '111222333'},
        ),
      ).called(1);
      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);
      expect(find.byKey(const Key('detail-name')), findsOneWidget);
      // Selection only — the scan must NEVER post an adjustment.
      verifyNever(
        () => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')),
      );
      expectNoOverflow(tester);
    });

    testWidgets('unknown barcode leaves the list as-is and opens no detail',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      await tester.enterText(
        find.byKey(const Key('stock-search')),
        '9998887776665',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stock-detail-panel')), findsNothing);
      verifyNever(
        () => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')),
      );
      expectNoOverflow(tester);
    });
  });

  group('Stock global scan (no field focused)', () {
    bool searchFieldFocused(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      return field?.key == const Key('stock-search');
    }

    String searchControllerText(WidgetTester tester) {
      final field = tester.widget<TextField>(
        find.byKey(const Key('stock-search')),
      );
      return field.controller?.text ?? '';
    }

    testWidgets('a raw wedge burst opens the detail panel and never posts '
        'an adjustment', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        barcodeLookups: {
          '111222333': {
            'found': true,
            'kind': 'product',
            'product_id': '00000000-0000-0000-0000-0000000000p1',
            'product_name': 'Apple Juice',
            'product_price': '100.0',
            'product_quantity': '12',
            'product_unit': 'piece',
            'is_archived': false,
          },
        },
      );
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      // The last focus action was the nav tap (an ordinary control, not
      // a text field): the gateway is armed the moment the screen shows.
      expect(searchFieldFocused(tester), isFalse);
      expect(BarcodeScannerGateway.instance.hasActiveHandler, isTrue);

      await sendWedgeScan(tester, '111222333');
      await tester.pumpAndSettle();

      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '111222333'},
        ),
      ).called(1);
      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);
      expect(find.byKey(const Key('detail-name')), findsOneWidget);
      // Selection only — a scan NEVER posts an adjustment.
      verifyNever(
        () => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')),
      );
      // The box shows the code but the scan never focused it.
      expect(searchControllerText(tester), '111222333');
      expect(searchFieldFocused(tester), isFalse);
      expectNoOverflow(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown barcode from the workspace opens no detail',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1920, 1080));

      await sendWedgeScan(tester, '9998887776665');
      await tester.pumpAndSettle();

      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '9998887776665'},
        ),
      ).called(1);
      expect(find.byKey(const Key('stock-detail-panel')), findsNothing);
      verifyNever(
        () => dio.post('/api/v1/inventory/adjust', data: any(named: 'data')),
      );
      expectNoOverflow(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('navigating to Products unregisters stock: only the new '
        'screen answers the next burst', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        barcodeLookups: {
          '111222333': {
            'found': true,
            'kind': 'product',
            'product_id': '00000000-0000-0000-0000-0000000000p1',
            'product_name': 'Apple Juice',
            'product_price': '100.0',
            'product_quantity': '12',
            'product_unit': 'piece',
            'is_archived': false,
          },
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
      // The stock harness does not stub the catalog endpoints the
      // Products screen loads after the route swap.
      when(
        () => dio.get(
          '/api/v1/products',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => okResponse('/api/v1/products', {
          'items': [
            {
              'id': '00000000-0000-0000-0000-0000000000p1',
              'name': 'Apple Juice',
              'barcode': '111222333',
              'sku': null,
              'description': null,
              'unit': 'piece',
              'price': '100.0',
              'cost': '80.0',
              'quantity': '12.0',
              'low_stock_threshold': '5.0',
              'allow_negative_stock': false,
              'expiry_date': null,
              'image_path': null,
              'category_id': null,
              'category_name': null,
              'is_archived': false,
              'archived_at': null,
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
            },
            {
              'id': '00000000-0000-0000-0000-0000000000p2',
              'name': 'Bread',
              'barcode': '444555666',
              'sku': null,
              'description': null,
              'unit': 'piece',
              'price': '50.0',
              'cost': '30.0',
              'quantity': '20.0',
              'low_stock_threshold': '5.0',
              'allow_negative_stock': false,
              'expiry_date': null,
              'image_path': null,
              'category_id': null,
              'category_name': null,
              'is_archived': false,
              'archived_at': null,
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
            },
          ],
          'total': 2,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        }),
      );
      when(
        () => dio.get(
          '/api/v1/categories',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => okResponse('/api/v1/categories', {
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 100,
          'pages': 1,
        }),
      );

      await pumpApp(tester, dio, size: const Size(1920, 1080));
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      // On Stock the burst opens the detail panel through stock's own
      // registered handler.
      await sendWedgeScan(tester, '111222333');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-detail-panel')), findsOneWidget);

      // Navigate: Stock unmounts (and must unregister itself) while
      // Products mounts — never two live scan targets. The rail item
      // key is unique where the localized label is not.
      await tester.tap(find.byKey(const Key('nav-item-/products')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('products-table')), findsOneWidget);
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      // The next burst is answered by Products: highlight in the catalog,
      // no stock detail panel anywhere.
      await sendWedgeScan(tester, '444555666');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(
          'product-row-highlight-00000000-0000-0000-0000-0000000000p2',
        )),
        findsOneWidget,
      );
      expect(find.byKey(const Key('stock-detail-panel')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // ── Quantity vs average-cost separation ──────────────────────────
  //
  // Screenshot bug: in the RTL table the quantity value (Column cross
  // alignment, resolved by the ambient direction) and the average-cost
  // value (`TextAlign.end` inside numericText's LTR-forced paragraph)
  // hugged the SAME shared cell boundary — `35.000` and `1 500.000`
  // rendered collapsed together. These tests pin the separation in both
  // locales plus the purchases-style contract: digits keep the LTR
  // paragraph, the cell edge does the placing.

  /// The pinned header label for one column, scoped to the table header
  /// (the KPI row and detail panel reuse some of the same strings).
  Finder stockHeading(String labelKey, String lang) => find.descendant(
        of: find.byKey(const Key('stock-table-header')),
        matching: find.text(AppStrings.t(labelKey, lang)),
      );

  /// Positive = clear horizontal space between the two text boxes,
  /// negative = width of the overlap. Two values meeting exactly at the
  /// shared cell boundary report 0.
  double horizontalGap(Rect a, Rect b) =>
      math.max(b.left - a.right, a.left - b.right);

  /// A numeric value must sit at the same edge of its column as its
  /// heading — ambient directional end (left under RTL, right under LTR).
  void expectValueUnderHeading(
    WidgetTester tester, {
    required String labelKey,
    required Finder value,
    required String lang,
    required TextDirection direction,
  }) {
    final heading = tester.getRect(stockHeading(labelKey, lang));
    final rect = tester.getRect(value);
    if (direction == TextDirection.rtl) {
      expect(rect.left, closeTo(heading.left, 0.01),
          reason: '$labelKey: under RTL the value must hug the heading '
              'edge (ambient end = left), not the opposite cell edge');
    } else {
      expect(rect.right, closeTo(heading.right, 0.01),
          reason: '$labelKey: under LTR the value must hug the heading '
              'edge (ambient end = right)');
    }
  }

  /// The numeric-cell contract: digits keep an LTR paragraph (grouped
  /// numbers never mirror) while placement comes from the cell's
  /// directional edge — `textAlign.end` inside that LTR paragraph is the
  /// RTL bug: it hugs the opposite edge from the ambient-RTL heading.
  void expectNumericCellContract(WidgetTester tester) {
    for (final value in [
      find.text('35.000'),
      find.text('1 500.000'),
      find.text('52 500.000'),
    ]) {
      final text = tester.widget<Text>(value);
      expect(text.textDirection, TextDirection.ltr,
          reason: '$value keeps the numericText LTR paragraph');
      expect(
        text.textAlign,
        isNull,
        reason: '$value must be placed by the cell edge '
            '(AlignmentDirectional.centerEnd / Column cross alignment), '
            'never by textAlign.end inside the LTR paragraph',
      );
    }
  }

  group('Inventory numeric column separation', () {
    setUpAll(_loadAppFonts);

    testWidgets('RTL (ar): quantity and average cost are distinct, '
        'separated columns', (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1366, 768),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      final qty = find.text('35.000');
      final avg = find.text('1 500.000');
      final stock = find.text('52 500.000');
      expect(qty, findsOneWidget);
      expect(avg, findsOneWidget);
      expect(stock, findsOneWidget);

      // The screenshot bug: under RTL both values hugged the same
      // shared cell boundary → no visible space between them.
      expect(
        horizontalGap(tester.getRect(qty), tester.getRect(avg)),
        greaterThanOrEqualTo(16),
        reason: 'quantity 35.000 and average cost 1 500.000 must be '
            'visibly distinct columns under RTL',
      );
      expect(
        horizontalGap(tester.getRect(avg), tester.getRect(stock)),
        greaterThanOrEqualTo(16),
        reason: 'average cost must not collide with the stock value',
      );

      expectValueUnderHeading(
        tester,
        labelKey: 'quantity',
        value: qty,
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      expectValueUnderHeading(
        tester,
        labelKey: 'avg_cost',
        value: avg,
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      expectValueUnderHeading(
        tester,
        labelKey: 'stock_value',
        value: stock,
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      expectNoOverflow(tester);
    });

    testWidgets('LTR (en): quantity and average cost keep their separation',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1366, 768),
        locale: const Locale('en'),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      final qty = find.text('35.000');
      final avg = find.text('1 500.000');
      final stock = find.text('52 500.000');
      expect(qty, findsOneWidget);
      expect(avg, findsOneWidget);
      expect(stock, findsOneWidget);

      expect(
        horizontalGap(tester.getRect(qty), tester.getRect(avg)),
        greaterThanOrEqualTo(16),
        reason: 'quantity and average cost must stay distinct under LTR',
      );
      expect(
        horizontalGap(tester.getRect(avg), tester.getRect(stock)),
        greaterThanOrEqualTo(16),
        reason: 'average cost must not collide with the stock value',
      );

      expectValueUnderHeading(
        tester,
        labelKey: 'quantity',
        value: qty,
        lang: 'en',
        direction: TextDirection.ltr,
      );
      expectValueUnderHeading(
        tester,
        labelKey: 'avg_cost',
        value: avg,
        lang: 'en',
        direction: TextDirection.ltr,
      );
      expectValueUnderHeading(
        tester,
        labelKey: 'stock_value',
        value: stock,
        lang: 'en',
        direction: TextDirection.ltr,
      );
      expectNoOverflow(tester);
    });

    testWidgets('numeric cells keep an LTR paragraph for the digits and '
        'are placed by the cell edge, never textAlign.end', (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1366, 768),
        theme: AppTheme.light(),
      );

      expect(find.text('35.000'), findsOneWidget);
      expectNumericCellContract(tester);
      expectNoOverflow(tester);
    });

    testWidgets('RTL medium (1024) keeps the separation without the '
        'category column', (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1024, 768),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      // Medium drops the category column entirely (wide-only).
      expect(stockHeading('category', 'ar'), findsNothing);
      final qty = find.text('35.000');
      final avg = find.text('1 500.000');
      expect(qty, findsOneWidget);
      expect(avg, findsOneWidget);
      expect(
        horizontalGap(tester.getRect(qty), tester.getRect(avg)),
        greaterThanOrEqualTo(16),
        reason: 'medium table must keep quantity and average cost apart '
            'under RTL',
      );
      expectNoOverflow(tester);
    });

    testWidgets('RTL narrow cards keep quantity and average cost apart',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(600, 500),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-cards')), findsOneWidget);
      final card = find.byKey(
        const Key('stock-card-00000000-0000-0000-0000-0000000000p1'),
      );
      expect(card, findsOneWidget);
      // Card quantity renders value + unit in one line ('35.000 …').
      final qty = find.descendant(
        of: card,
        matching: find.textContaining('35.000'),
      );
      final avg = find.descendant(
        of: card,
        matching: find.text('1 500.000'),
      );
      expect(qty, findsOneWidget);
      expect(avg, findsOneWidget);
      expect(
        horizontalGap(tester.getRect(qty), tester.getRect(avg)),
        greaterThanOrEqualTo(16),
        reason: 'card stats must keep quantity and average cost apart',
      );
      expectNoOverflow(tester);
    });
  });

  // ── Wide category-column distribution ─────────────────────────────
  //
  // Screenshot bug: Category was `Expanded(flex: 2)`, so at wide
  // desktop every pixel the fixed numerics don't use was split 3:2
  // between the product name and Category. At 1920 the Category cell
  // measured ~576px; its start-aligned label hid against the name side
  // and the whole leftover showed as a blank wedge between Category
  // and Quantity. Category now shares the fixed-width cluster and the
  // name column absorbs the fluid width.

  /// The wide-distribution contract: the Category header and body cells
  /// are bounded (fixed 180 + padding), the label sits at the ambient
  /// end against the numeric cluster, every column shares one width
  /// definition between header and body, and the name column is the
  /// one that absorbs the fluid width.
  void expectCategoryGroupedWithNumerics(
    WidgetTester tester, {
    required String lang,
    required TextDirection direction,
  }) {
    final row = find.byKey(
      const Key('stock-item-00000000-0000-0000-0000-0000000000p1'),
    );

    // Header and body cells must share one width definition by
    // construction (same spec list drives both). The body keys repeat
    // per row, so they resolve against the p1 row only.
    for (var i = 0; i < 7; i++) {
      final header = tester.getRect(find.byKey(Key('stock-header-col-$i')));
      final body = tester.getRect(
        find.descendant(
          of: row,
          matching: find.byKey(Key('stock-body-col-$i')),
        ),
      );
      expect(body.width, closeTo(header.width, 0.01),
          reason: 'column $i: header and body cells must be identical '
              'boxes so headings sit exactly above their values');
    }

    final categoryHeader = tester.getRect(
      find.byKey(const Key('stock-header-col-1')),
    );
    expect(
      categoryHeader.width,
      lessThanOrEqualTo(220),
      reason: 'the category header must be a bounded fixed-width cell, '
          'not an Expanded soaking up the leftover table width',
    );

    final category = find.descendant(of: row, matching: find.text('Drinks'));
    expect(category, findsOneWidget);
    final categoryRect = tester.getRect(category);
    final categoryCell = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('stock-body-col-1')),
      ),
    );
    expect(
      categoryCell.width,
      lessThanOrEqualTo(220),
      reason: 'the body cell must hug its bounded fixed width instead of '
          'stretching across an oversized flex cell',
    );

    // The label sits against the cluster side (ambient end) in both
    // directions: its far edge meets the cell's end content edge, so
    // the only slack left between Category and Quantity is the
    // quantity cell's own padding + figure slack — never the old
    // start-against-the-name wedge of leftover cell width.
    final qtyCell = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('stock-body-col-2')),
      ),
    );
    expect(
      horizontalGap(categoryRect, tester.getRect(find.text('35.000'))),
      lessThanOrEqualTo(300),
      reason: 'category must sit against the numeric cluster — the gap '
          'is bounded by the quantity cell ($qtyCell), not by category '
          'cell remainder',
    );
    final end = direction == TextDirection.rtl
        ? categoryRect.left
        : categoryRect.right;
    final cellEnd = direction == TextDirection.rtl
        ? categoryCell.left + 10
        : categoryCell.right - 10;
    expect(end, closeTo(cellEnd, 0.01),
        reason: 'the category label must hug the ambient end of its '
            'cell (against the numeric cluster), not the name side');

    // Fluid column: the name absorbs the leftover width.
    final nameHeader = tester.getRect(
      find.byKey(const Key('stock-header-col-0')),
    );
    final nameBody = tester.getRect(
      find.descendant(
        of: row,
        matching: find.byKey(const Key('stock-body-col-0')),
      ),
    );
    expect(
      nameHeader.width,
      greaterThanOrEqualTo(400),
      reason: 'the name column is the fluid column and must absorb the '
          'remaining width at wide desktop',
    );
    expect(nameHeader.width, lessThanOrEqualTo(900),
        reason: 'the fluid share must stay a reasonable name column, '
            'not the whole table');

    // The figure cells keep a comfortable minimum so grouped values
    // never crowd against their neighbours.
    for (final i in [2, 3, 4]) {
      expect(
        tester
            .getRect(find.descendant(
              of: row,
              matching: find.byKey(Key('stock-body-col-$i')),
            ))
            .width,
        greaterThanOrEqualTo(150),
        reason: 'figure column $i must keep a comfortable width',
      );
    }

    // Header/value agreement for the clustered columns, and the name
    // value at its cell's start edge.
    expectValueUnderHeading(
      tester,
      labelKey: 'category',
      value: category,
      lang: lang,
      direction: direction,
    );
    expectValueUnderHeading(
      tester,
      labelKey: 'status',
      value: find.descendant(
        of: row,
        matching: find.byType(StatusChip),
      ),
      lang: lang,
      direction: direction,
    );
    final nameValue = find.descendant(of: row, matching: find.text('Huile de table'));
    expect(nameValue, findsOneWidget);
    final nameRect = tester.getRect(nameValue);
    final nameStart = direction == TextDirection.rtl
        ? nameRect.right
        : nameRect.left;
    final nameCellStart = direction == TextDirection.rtl
        ? nameBody.right - 10
        : nameBody.left + 10;
    expect(nameStart, closeTo(nameCellStart, 0.01),
        reason: 'the name value must hug the ambient start of the '
            'fluid cell');
  }

  group('Inventory category column distribution (wide)', () {
    setUpAll(_loadAppFonts);

    testWidgets('RTL wide (1920): category stays bounded and grouped '
        'with the numeric columns', (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1920, 1080),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      expectCategoryGroupedWithNumerics(
        tester,
        lang: 'ar',
        direction: TextDirection.rtl,
      );
      expectNoOverflow(tester);
    });

    testWidgets('LTR wide (1920): category keeps the same bounded '
        'distribution', (tester) async {
      final dio = MockDio();
      stubRequests(dio, inventoryBody: _separationListBody());
      await pumpStockScreenDirect(
        tester,
        dio,
        permissions: const ['inventory_view'],
        size: const Size(1920, 1080),
        locale: const Locale('en'),
        theme: AppTheme.light(),
      );

      expect(find.byKey(const Key('stock-list')), findsOneWidget);
      expectCategoryGroupedWithNumerics(
        tester,
        lang: 'en',
        direction: TextDirection.ltr,
      );
      expectNoOverflow(tester);
    });
  });
}
