// Global barcode capture in the Add Product form.
//
// While the dialog is open, a keyboard-wedge scan must land in the
// Barcode field no matter which form field holds focus — the gateway's
// `allowWhileEditing` handler claims the run as a PASS-THROUGH: every
// digit reaches the focused field as ordinary typing (numeric entry is
// never consumed), and Enter rolls the field back to its pre-run text
// before the burst lands in the Barcode field. The form is never
// submitted by a scan, and every other field keeps its value. Closing
// the dialog unregisters the handler and restores the ordinary screen
// target.
//
// The final group is the typing side of that contract: digit-by-digit
// assertions through the `handleKeyForTest` seam (the exact regression —
// before pass-through runs, every digit while the form was focused came
// back `true` = consumed, so typed numbers vanished), plus the Enter
// terminator's rollback / divergence / stale-gap decisions.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/keyboard.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
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

const _breadId = '00000000-0000-0000-0000-0000000000p2';
const _breadBarcode = '444555666';

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
                'product_create',
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
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _createdProductBody() => _productJson(
      id: '00000000-0000-0000-0000-0000000000p9',
      name: 'Test Item',
      barcode: '12345',
    );

Map<String, dynamic> _inventoryItem({
  required String id,
  required String name,
  String barcode = '111',
  String quantity = '12',
  String categoryName = 'Drinks',
}) =>
    {
      'product_id': id,
      'name': name,
      'barcode': barcode,
      'unit': 'piece',
      'quantity': quantity,
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'cost': '75.0',
      'avg_cost': '80.5',
      'stock_value': '966.0',
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
          id: _breadId,
          name: 'Bread',
          barcode: _breadBarcode,
          quantity: '3',
          categoryName: 'Bakery',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 100,
      'pages': 1,
      'total_stock_value': '1056.0',
    };

Map<String, dynamic> _breadDetailBody() => {
      'product_id': _breadId,
      'name': 'Bread',
      'barcode': _breadBarcode,
      'unit': 'piece',
      'quantity': '3',
      'cost': '30.0',
      'avg_cost': '30.0',
      'stock_value': '90.0',
      'price': '50.0',
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'is_archived': false,
      'packaging': {'full_packages': 0, 'loose_quantity': 3},
      'variants': [],
      'purchase_units': [],
      'recent_movements': [],
    };

Map<String, dynamic> _movementJson() => {
      'id': 'm1',
      'product_id': '00000000-0000-0000-0000-0000000000p1',
      'product_name': 'Apple Juice',
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
      'items': [_movementJson()],
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

Map<String, dynamic> _productsListBody() => {
      'items': [
        _productJson(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Apple Juice',
          barcode: '111222333',
          categoryId: '00000000-0000-0000-0000-0000000000c1',
          categoryName: 'Drinks',
        ),
        _productJson(
          id: _breadId,
          name: 'Bread',
          barcode: _breadBarcode,
          price: '50.0',
          cost: '30.0',
          quantity: '20.0',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 100,
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
    List<Map<String, dynamic>>? productQueryLog,
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
      return okResponse(_productsPath, _productsListBody());
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
    ).thenAnswer(
      (_) async => okResponse(_inventoryPath, _inventoryListBody()),
    );
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
        '/api/v1/inventory/$_breadId',
      ),
    ).thenAnswer(
      (_) async => okResponse('/api/v1/inventory/$_breadId', _breadDetailBody()),
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
    when(() => dio.post(_productsPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_productsPath, _createdProductBody()),
    );
  }

  Map<String, Map<String, dynamic>> breadLookup() => {
        _breadBarcode: {
          'found': true,
          'kind': 'product',
          'product_id': _breadId,
          'product_name': 'Bread',
          'product_price': '50.0',
          'product_quantity': '20.0',
          'product_unit': 'piece',
          'is_archived': false,
        },
      };

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

  Future<void> navTo(WidgetTester tester, String path) async {
    await tester.tap(
      find.byKey(Key('nav-item-$path')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// Logs in, lands on Products and opens the Add Product form.
  Future<void> openAddProductForm(WidgetTester tester, MockDio dio) async {
    await pumpApp(tester, dio);
    await navTo(tester, '/products');
    await tester.tap(find.byKey(const Key('products-add-button')));
    await tester.pumpAndSettle();
    expect(find.byType(ProductFormDialog), findsOneWidget);
  }

  String fieldText(WidgetTester tester, Key key) {
    final field = tester.widget<TextField>(find.byKey(key));
    return field.controller?.text ?? '';
  }

  String? focusedFieldKey(WidgetTester tester) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    final field = context.widget is TextField
        ? context.widget as TextField
        : context.findAncestorWidgetOfExactType<TextField>();
    final key = field?.key;
    return key is ValueKey<String> ? key.value : null;
  }

  const barcodeKey = Key('product-barcode-field');
  const nameKey = Key('product-name-field');
  const priceKey = Key('product-price-field');
  const quantityKey = Key('product-quantity-field');
  const wholesalePriceKey = Key('product-wholesale-price-field');
  const wholesaleMinQtyKey = Key('product-wholesale-min-qty-field');

  /// A digit key-down at a custom timestamp — the staleness input
  /// ([wedgeKeyDown] always carries `Duration.zero`).
  KeyEvent digitAt(String character, Duration timeStamp) {
    final base = wedgeKeyDown(character) as KeyDownEvent;
    return KeyDownEvent(
      physicalKey: base.physicalKey,
      logicalKey: base.logicalKey,
      timeStamp: timeStamp,
      character: character,
    );
  }

  /// Non-digit key-downs: every one of them must pass through the
  /// gateway and abandon any run in progress.
  const periodDown = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.period,
    logicalKey: LogicalKeyboardKey.period,
    timeStamp: Duration.zero,
    character: '.',
  );
  const backspaceDown = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.backspace,
    logicalKey: LogicalKeyboardKey.backspace,
    timeStamp: Duration.zero,
  );
  const arrowRightDown = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.arrowRight,
    logicalKey: LogicalKeyboardKey.arrowRight,
    timeStamp: Duration.zero,
  );

  group('Add Product form global barcode capture', () {
    testWidgets('a scan while the Name field is focused lands only in the '
        'barcode field', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);

      // The dialog autofocuses Name; type a name, then scan.
      await tester.enterText(find.byKey(nameKey), 'Organic Olive Oil');
      expect(focusedFieldKey(tester), 'product-name-field');

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(fieldText(tester, nameKey), 'Organic Olive Oil');
      expect(fieldText(tester, priceKey), isEmpty);
      expect(
        focusedFieldKey(tester),
        'product-name-field',
        reason: 'the scan never steals focus from the field being typed in',
      );
      expect(find.byType(ProductFormDialog), findsOneWidget);
      verifyNever(
        () => dio.post(_productsPath, data: any(named: 'data')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scan while the Price field is focused lands only in the '
        'barcode field', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);

      await tester.enterText(find.byKey(priceKey), '12.5');
      expect(focusedFieldKey(tester), 'product-price-field');

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(fieldText(tester, priceKey), '12.5');
      expect(fieldText(tester, nameKey), isEmpty);
      expect(focusedFieldKey(tester), 'product-price-field');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scan replaces the barcode and never touches the other '
        'filled fields', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);

      await tester.enterText(find.byKey(nameKey), 'Hummus 400g');
      await tester.enterText(find.byKey(priceKey), '25');
      await tester.enterText(find.byKey(quantityKey), '8');
      await tester.enterText(find.byKey(barcodeKey), '111');

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(fieldText(tester, nameKey), 'Hummus 400g');
      expect(fieldText(tester, priceKey), '25');
      expect(fieldText(tester, quantityKey), '8');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      verifyNever(
        () => dio.post(_productsPath, data: any(named: 'data')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a partial digit run never reaches the barcode field',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);

      await tester.enterText(find.byKey(nameKey), 'Tea');
      // Three digits, no Enter: the gateway buffers them but never
      // dispatches — the barcode field must stay untouched.
      for (final d in ['1', '2', '3']) {
        await tester.sendKeyEvent(digitKey(d));
      }
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), isEmpty);
      expect(fieldText(tester, nameKey), 'Tea');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing the form unregisters the handler and Products '
        'scanning resumes', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        productQueryLog: queryLog,
        barcodeLookups: breadLookup(),
      );
      await openAddProductForm(tester, dio);

      // Screen handler + form handler.
      expect(BarcodeScannerGateway.instance.handlerCount, 2);

      await tester.tap(find.byKey(const Key('product-form-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsNothing);
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      // The Products handler is live again: a raw wedge burst filters
      // the catalog and highlights the hit.
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      expect(queryLog.last['search'], _breadBarcode);
      expect(
        find.byKey(ValueKey(
          'product-row-highlight-$_breadId',
        )),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('scanning works on Stock after the form closed', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      await tester.tap(find.byKey(const Key('product-form-cancel')));
      await tester.pumpAndSettle();

      await navTo(tester, '/stock');
      expect(find.byType(StockScreen), findsOneWidget);
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stock-detail-panel')),
        findsOneWidget,
        reason: 'the Stock handler resolved the scan to the Bread detail',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual barcode typing and form validation still work',
        (tester) async {
      final dio = MockDio();
      final createPayloads = <Map<String, dynamic>>[];
      stubRequests(dio);
      // Re-install the POST stub AFTER stubRequests so the payload is
      // recorded (stubRequests installs its own plain POST answer).
      when(() => dio.post(_productsPath, data: any(named: 'data')))
          .thenAnswer((invocation) async {
        final data = invocation.namedArguments[#data];
        if (data is Map<String, dynamic>) {
          createPayloads.add(Map<String, dynamic>.from(data));
        }
        return okResponse(_productsPath, _createdProductBody());
      });
      await openAddProductForm(tester, dio);

      // Manual entry: a short code types into the barcode field normally.
      await tester.enterText(find.byKey(barcodeKey), '12345');
      await tester.enterText(find.byKey(priceKey), '10');

      // Empty name still fails validation and blocks the POST.
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-form-error')), findsOneWidget);
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(createPayloads, isEmpty);

      // Completing the form submits with the manually typed barcode.
      await tester.enterText(find.byKey(nameKey), 'Test Item');
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsNothing);
      expect(createPayloads, hasLength(1));
      expect(createPayloads.single['barcode'], '12345');
      expect(createPayloads.single['name'], 'Test Item');
      expect(tester.takeException(), isNull);
    });
  });

  group('numeric typing keeps working while the form captures scans', () {
    testWidgets('digits typed into the Price field are never consumed '
        '(the regression)', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      await tester.tap(find.byKey(priceKey));
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'product-price-field');

      // The regression: with every digit consumed by the gateway while
      // the form was focused, typed numbers never reached the field.
      // Each digit must now come back `false` = pass-through.
      for (final d in ['1', '2']) {
        expect(
          gateway.handleKeyForTest(wedgeKeyDown(d)),
          isFalse,
          reason: 'digit "$d" must reach the focused Price field',
        );
      }
      expect(gateway.handleKeyForTest(periodDown), isFalse);
      expect(gateway.handleKeyForTest(wedgeKeyDown('5')), isFalse);
      // A short human run keeps its Enter (never dispatches).
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(focusedFieldKey(tester), 'product-price-field');
      expect(fieldText(tester, barcodeKey), isEmpty);
      expect(fieldText(tester, priceKey), isEmpty);

      // The same digits through the REAL event pipeline: they leave the
      // gateway, cross the focus tree and change nothing else.
      await tester.sendKeyEvent(digitKey('7'));
      await tester.pump();
      expect(focusedFieldKey(tester), 'product-price-field');
      expect(fieldText(tester, priceKey), isEmpty);
      expect(fieldText(tester, barcodeKey), isEmpty);
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('digits typed into Quantity and Wholesale fields pass '
        'through the gateway', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      for (final key in [quantityKey, wholesalePriceKey, wholesaleMinQtyKey]) {
        await tester.ensureVisible(find.byKey(key));
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();
        expect(
          focusedFieldKey(tester),
          (key as ValueKey<String>).value,
        );
        expect(
          gateway.handleKeyForTest(wedgeKeyDown('7')),
          isFalse,
          reason: 'digit typing works while ${key.value} is focused',
        );
        // Abandon that single-digit run before moving to the next field.
        expect(gateway.handleKeyForTest(periodDown), isFalse);
      }
      expect(fieldText(tester, barcodeKey), isEmpty);
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('decimal, backspace and arrow keys pass through and '
        'abandon the run', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      await tester.tap(find.byKey(priceKey));
      await tester.pumpAndSettle();

      expect(gateway.handleKeyForTest(wedgeKeyDown('1')), isFalse);
      // The decimal point is human typing: it passes AND junks the run.
      expect(gateway.handleKeyForTest(periodDown), isFalse);
      // Five digits after it form a fresh, non-barcode-shaped run.
      for (final d in ['2', '3', '4', '5', '6']) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isFalse);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      expect(fieldText(tester, barcodeKey), isEmpty,
          reason: 'five digits + Enter is never a scan');
      // Editing keys are never claimed either.
      expect(gateway.handleKeyForTest(backspaceDown), isFalse);
      expect(gateway.handleKeyForTest(arrowRightDown), isFalse);
      expect(focusedFieldKey(tester), 'product-price-field');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scan typed into the focused field is rolled back at '
        'Enter and lands in the barcode field', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      await tester.enterText(find.byKey(priceKey), '12.5');
      expect(focusedFieldKey(tester), 'product-price-field');

      // The burst arrives as pass-through digits…
      for (final d in _breadBarcode.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isFalse);
      }
      // …and the engine delivers them into the focused field (the seam
      // key events themselves never insert text in widget tests).
      final landed = '12.5$_breadBarcode';
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: landed,
        selection: TextSelection.collapsed(offset: landed.length),
      ));
      await tester.pump();

      // Enter is the confident terminator: consumed, field rolled back,
      // the code dispatched to the barcode field.
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      await tester.pumpAndSettle();

      expect(fieldText(tester, priceKey), '12.5',
          reason: 'the burst is stripped from the field it transited');
      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(focusedFieldKey(tester), 'product-price-field');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      verifyNever(
        () => dio.post(_productsPath, data: any(named: 'data')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a field diverged from the run at Enter is human typing: '
        'never dispatched, never restored', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      await tester.enterText(find.byKey(priceKey), '12.5');
      for (final d in _breadBarcode.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isFalse);
      }
      // The field no longer matches snapshot nor snapshot+beyond-run
      // digits — a human edit won the race against the terminator.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '12.5999',
        selection: TextSelection.collapsed(offset: 7),
      ));
      await tester.pump();

      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse,
          reason: 'diverged field = typing, never a scan');
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), isEmpty,
          reason: 'no dispatch from a diverged run');
      expect(fieldText(tester, priceKey), '12.5999',
          reason: 'the edit stands exactly as the user left it');
      expect(find.byType(ProductFormDialog), findsOneWidget);
      verifyNever(
        () => dio.post(_productsPath, data: any(named: 'data')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pause beyond the stale gap restarts the run so slow '
        'typing never accumulates into a scan', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      await tester.tap(find.byKey(priceKey));
      await tester.pumpAndSettle();

      expect(gateway.handleKeyForTest(digitAt('1', Duration.zero)), isFalse);
      // 500ms later — past kBarcodeRunStaleGap (400ms): the buffered '1'
      // is typing residue and is dropped before this digit starts fresh.
      const afterGap = Duration(milliseconds: 500);
      expect(gateway.handleKeyForTest(digitAt('2', afterGap)), isFalse);
      for (final d in ['3', '4', '5', '6']) {
        expect(gateway.handleKeyForTest(digitAt(d, afterGap)), isFalse);
      }
      // Buffer is '23456' (5 digits) — without the stale reset it would
      // be '123456' and this Enter would have dispatched a scan.
      expect(gateway.handleKeyForTest(wedgeEnter()), isFalse);
      await tester.pumpAndSettle();
      expect(fieldText(tester, barcodeKey), isEmpty);
      expect(find.byType(ProductFormDialog), findsOneWidget);

      // Recovery: a real fast burst right afterwards still dispatches.
      for (final d in _breadBarcode.split('')) {
        expect(gateway.handleKeyForTest(wedgeKeyDown(d)), isFalse);
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      await tester.pumpAndSettle();
      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with no field focused the form handler still consumes '
        'the whole run (nothing leaks)', (tester) async {
      final dio = MockDio();
      stubRequests(dio, barcodeLookups: breadLookup());
      await openAddProductForm(tester, dio);
      final gateway = BarcodeScannerGateway.instance;

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(editableTextHasFocus(), isFalse);

      // No EditableText to pass through to: the default consume path —
      // no digit may leak into a shortcut or focus move.
      for (final d in _breadBarcode.split('')) {
        expect(
          gateway.handleKeyForTest(wedgeKeyDown(d)),
          isTrue,
          reason: 'an idle form still captures the burst outright',
        );
      }
      expect(gateway.handleKeyForTest(wedgeEnter()), isTrue);
      await tester.pumpAndSettle();

      expect(fieldText(tester, barcodeKey), _breadBarcode);
      expect(fieldText(tester, nameKey), isEmpty);
      expect(find.byType(ProductFormDialog), findsOneWidget);
      verifyNever(
        () => dio.post(_productsPath, data: any(named: 'data')),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
