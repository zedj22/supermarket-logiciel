// Scanner-first POS (default layout) — the product catalog is hidden and
// the cashier works from the barcode input + the cart.
//
// Contract under test:
//  * `show_pos_product_list` defaults to false → no catalog, a full-width
//    cart, and the barcode field still on screen;
//  * the field never autofocuses and a wedge burst (digits + Enter) adds the
//    product with no click and no key press of its own — the app-level
//    gateway captures it while nothing is focused;
//  * the buffer is cleared after processing and repeated scans of the same
//    product keep adding to the same line;
//  * SPACE (and F8) always pay — the space character is never typed into the
//    barcode buffer;
//  * ordinary typing never adds a product: the field is a BARCODE input, not
//    a name/description search, and a short digit run is not a scan;
//  * Ctrl+N opens the existing product picker and product / pack selection
//    still run the canonical add paths;
//  * turning the setting ON restores the existing catalog layout;
//  * Arabic RTL renders the scanner-first layout without overflow.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';
import 'package:supermarket_pos/features/settings/scan_settings_provider.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/wedge_scanner.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => true;

  @override
  Future<String?> readToken() async => 'tok';

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => const ['cashier'];

  @override
  Future<List<String>> readUserPermissions() async => const [];

  @override
  Future<void> clearAll() async {}
}

const _catalogPath = '/api/v1/products';
const _packsPath = '/api/v1/packs';
const _lookupPath = '/api/v1/products/barcode-lookup';

/// Scan-shaped (13 digits, EAN-13) — the gateway only dispatches 6+ digits.
const _breadBarcode = '1111111111116';
const _packId = 'pack-1';
const _scopes = <String>['pos_sale', 'product_view', 'pos_discount'];

Map<String, dynamic> _product({
  required String id,
  required String name,
  String? barcode,
  String price = '10.0',
  String quantity = '20',
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
      'cost': '5',
      'avg_cost': '5',
      'quantity': quantity,
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'category_id': null,
      'category_name': null,
      'image_path': null,
      'is_archived': false,
    };

final Map<String, dynamic> _bread = _product(
  id: 'p-bread',
  name: 'Bread',
  barcode: _breadBarcode,
);
final Map<String, dynamic> _milk = _product(
  id: 'p-milk',
  name: 'Milk',
  barcode: '2223334445556',
  price: '15.0',
);

final List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[
  _bread,
  _milk,
];

final Map<String, dynamic> _familyPack = <String, dynamic>{
  'id': _packId,
  'name': 'Family Pack',
  'barcode': '777888999',
  'price': '250.0',
  'is_active': true,
  'is_archived': false,
  'components_count': 1,
  'sum_of_parts': '20.0',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'components': [
    {
      'product_id': 'p-bread',
      'product_name': 'Bread',
      'product_unit': 'piece',
      'product_price': '10',
      'quantity': '2',
    },
  ],
};

Map<String, dynamic> _lookupHit(Map<String, dynamic> product) =>
    <String, dynamic>{
      'found': true,
      'kind': 'product',
      'product_id': product['id'],
      'product_name': product['name'],
      'product_price': product['price'],
      'product_quantity': product['quantity'],
      'product_unit': 'piece',
      'variant_id': null,
      'selling_unit_id': null,
      'is_archived': false,
    };

Map<String, dynamic> _availabilityBody() => <String, dynamic>{
      'pack_id': _packId,
      'pack_name': 'Family Pack',
      'price': '250.0',
      'is_active': true,
      'is_archived': false,
      'quantity': '1',
      'saleable': true,
      'max_pack_quantity': '3',
      'sum_of_parts': '20.0',
      'components': [
        {
          'product_id': 'p-bread',
          'product_name': 'Bread',
          'product_unit': 'piece',
          'required_per_pack': '2',
          'required_quantity': '2',
          'available_quantity': '20',
          'ok': true,
        },
      ],
      'errors': <String>[],
    };

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void _stubBackend(MockDio dio) {
  Object? bodyFor(String path, Map<String, dynamic> query) {
    if (path == _catalogPath) {
      final term = (query['search'] as String?)?.trim().toLowerCase() ?? '';
      final items = term.isEmpty
          ? _catalog
          : _catalog
              .where((p) => '${p['name']}'.toLowerCase().contains(term))
              .toList();
      return <String, Object>{'items': items, 'total': items.length};
    }
    if (path == _packsPath) {
      return <String, Object>{
        'items': <Map<String, dynamic>>[_familyPack],
        'total': 1,
        'page': 1,
        'page_size': 50,
        'pages': 1,
      };
    }
    if (path == _lookupPath) {
      final code = query['barcode'];
      if (code == _breadBarcode) return _lookupHit(_bread);
      if (code == _milk['barcode']) return _lookupHit(_milk);
      // Definitive miss — no fuzzy text fallback may add anything.
      return <String, dynamic>{'found': false};
    }
    if (path.endsWith('/availability')) return _availabilityBody();
    if (path.startsWith('/api/v1/products/') &&
        !path.endsWith('/variants') &&
        !path.endsWith('/selling-units')) {
      final id = path.substring('/api/v1/products/'.length);
      for (final product in _catalog) {
        if (product['id'] == id) return product;
      }
      return <String, dynamic>{};
    }
    return <String, Object>{'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final query = Map<String, dynamic>.from(
      (invocation.namedArguments[#queryParameters] as Map?) ?? const {},
    );
    return _ok(path, bodyFor(path, query));
  });
  when(() => dio.get(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', bodyFor(
          invocation.positionalArguments.first as String? ?? '',
          const {},
        )),
  );
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', {}),
  );
}

AuthUser _user() => AuthUser(
      id: 'u-1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<ProviderContainer> _pumpPos(
  WidgetTester tester, {
  bool showProductList = false,
  AppLocale locale = AppLocale.en,
  TextDirection direction = TextDirection.ltr,
  Size size = const Size(1366, 800),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final dio = MockDio();
  _stubBackend(dio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user()),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        // Always explicit: the default (false) IS the scanner-first mode.
        posSettingsProvider.overrideWith(
          (ref) => PosSettingsNotifier()
            ..setShowPosProductList(showProductList),
        ),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Directionality(
          textDirection: direction,
          child: const Scaffold(body: PosScreen()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(
    tester.element(find.byKey(const Key('pos-screen'))),
    listen: false,
  );
}

PosCartState _cart(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byKey(const Key('pos-screen'))),
    ).read(posCartProvider);

TextField _barcodeField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('pos-search-field')));

String _barcodeText(WidgetTester tester) =>
    _barcodeField(tester).controller?.text ?? '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('hidden product catalog (default)', () {
    testWidgets('the catalog is hidden and the cart owns the workspace',
        (tester) async {
      await _pumpPos(tester);

      expect(find.byKey(const Key('pos-product-catalog')), findsNothing);
      expect(find.byKey(const Key('pos-product-p-bread')), findsNothing);
      expect(find.byKey(const Key('pos-pack-$_packId')), findsNothing);
      // The barcode input and the cart stay on screen.
      expect(find.byKey(const Key('pos-search-field')), findsOneWidget);
      expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
      // Manual selection stays reachable without the catalog.
      expect(find.byKey(const Key('pos-product-picker-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-packs-button')), findsOneWidget);
      // Catalog-only chrome disappears with the catalog.
      expect(find.byKey(const Key('pos-view-mode-toggle')), findsNothing);
      expect(find.byKey(const Key('pos-layout-switch')), findsNothing);
      // No dead panel: the cart spans the whole window.
      expect(
        tester.getSize(find.byKey(const Key('pos-cart-panel'))).width,
        greaterThan(1360),
        reason: 'the cart expands into the catalog\'s former space',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the barcode field never takes focus by itself', (tester) async {
      await _pumpPos(tester);

      expect(_barcodeField(tester).autofocus, isFalse);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        focus?.context?.widget is EditableText,
        isFalse,
        reason: 'an autofocused field is what used to eat the SPACE pay key',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the product list appears when the setting is enabled',
        (tester) async {
      await _pumpPos(tester, showProductList: true);

      expect(find.byKey(const Key('pos-product-catalog')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-p-bread')), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('barcode scanning without focus', () {
    testWidgets('a wedge burst adds the product with no click and no Enter key '
        'press of its own', (tester) async {
      await _pumpPos(tester);
      expect(_cart(tester).lines, isEmpty);

      // Exactly what a keyboard-wedge scanner sends: digits + Enter.
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.productId, 'p-bread');
      expect(cart.lines.single.name, 'Bread');
      expect(cart.lines.single.quantity, '1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the barcode buffer is cleared after processing',
        (tester) async {
      await _pumpPos(tester);

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      expect(_barcodeText(tester), isEmpty,
          reason: 'the next burst must never concatenate onto this code');
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated scans of the same product keep adding',
        (tester) async {
      await _pumpPos(tester);

      for (var i = 0; i < 3; i++) {
        await sendWedgeScan(tester, _breadBarcode);
        await tester.pumpAndSettle();
      }

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '3');
      expect(_barcodeText(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clicking elsewhere in the POS never breaks scanning',
        (tester) async {
      await _pumpPos(tester);

      // A click on the empty-cart area parks focus outside the barcode
      // field; the gateway must still capture the next burst.
      await tester.tap(find.byKey(const Key('pos-cart-panel')));
      await tester.pumpAndSettle();
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      expect(_cart(tester).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a second, different code adds its own line', (tester) async {
      await _pumpPos(tester);

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      await sendWedgeScan(tester, '2223334445556');
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(2));
      expect(
        cart.lines.map((line) => line.productId),
        containsAll(<String>['p-bread', 'p-milk']),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SPACE / F8 always pay', () {
    testWidgets('SPACE opens payment and never types a space into the barcode '
        'input', (tester) async {
      await _pumpPos(tester);
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      expect(_cart(tester).lines, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(_barcodeText(tester), isEmpty);
      expect(_barcodeText(tester).contains(' '), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F8 opens payment through the same action', (tester) async {
      await _pumpPos(tester);
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE still pays after the cashier clicked the barcode field',
        (tester) async {
      await _pumpPos(tester);
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();

      // A click parks focus in the scan field; barcodes contain no spaces, so
      // the key must stay the pay key there too.
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(_barcodeText(tester).contains(' '), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('ordinary typing is never a scan', () {
    testWidgets('a product NAME is not searchable here and adds nothing',
        (tester) async {
      await _pumpPos(tester);

      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'Milk');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(_cart(tester).lines, isEmpty,
          reason: 'the field is a barcode input, not a name search');
      expect(_barcodeText(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short digit run is not a scan', (tester) async {
      await _pumpPos(tester);

      await sendWedgeScan(tester, '123');
      await tester.pumpAndSettle();

      expect(_cart(tester).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing in a cart quantity field never adds a product',
        (tester) async {
      await _pumpPos(tester);
      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      final line = _cart(tester).lines.single;

      final qty = find.byKey(Key('cart-line-qty-${line.key}'));
      expect(qty, findsOneWidget);
      await tester.enterText(qty, '4');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1),
          reason: 'editing a quantity is not a scan and not a new line');
      expect(cart.lines.single.quantity, '4');
      expect(tester.takeException(), isNull);
    });
  });

  group('manual selection without the catalog', () {
    Future<void> openPicker(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-picker-dialog')), findsOneWidget);
    }

    testWidgets('Ctrl+N opens the existing picker with products and packs',
        (tester) async {
      await _pumpPos(tester);

      await openPicker(tester);

      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Family Pack'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the toolbar button opens the same picker', (tester) async {
      await _pumpPos(tester);

      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-picker-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selecting a product adds it to the cart', (tester) async {
      await _pumpPos(tester);
      await openPicker(tester);

      await tester.tap(find.text('Bread'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-picker-dialog')), findsNothing);
      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.productId, 'p-bread');
      expect(tester.takeException(), isNull);
    });

    testWidgets('selecting a pack adds ONE pack line with pack_id',
        (tester) async {
      await _pumpPos(tester);
      await openPicker(tester);

      await tester.tap(find.text('Family Pack'));
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.packId, _packId);
      expect(cart.lines.single.productId, isNull,
          reason: 'a pack is never a fake product line');
      expect(tester.takeException(), isNull);
    });
  });

  group('localization and layout', () {
    testWidgets('Arabic RTL: scan-first layout renders, scans and pays',
        (tester) async {
      await _pumpPos(
        tester,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );

      expect(find.byKey(const Key('pos-product-catalog')), findsNothing);
      expect(find.byKey(const Key('pos-search-field')), findsOneWidget);
      expect(
        find.text(AppStrings.t('pos_scan_field_hint', 'ar')),
        findsOneWidget,
      );

      await sendWedgeScan(tester, _breadBarcode);
      await tester.pumpAndSettle();
      expect(_cart(tester).lines, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow window: the cart still fills the space',
        (tester) async {
      await _pumpPos(tester, size: const Size(600, 600));

      expect(find.byKey(const Key('pos-product-catalog')), findsNothing);
      expect(find.byKey(const Key('pos-search-field')), findsOneWidget);
      expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
