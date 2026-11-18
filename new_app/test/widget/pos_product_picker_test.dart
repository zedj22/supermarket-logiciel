// Quick product picker (Phase 17 §18) — widget tests.
//
// Covers the documented contract:
//   • open from the POS button and from its keyboard shortcut (Ctrl+N)
//   • the search field is focused on open, so typing works immediately
//   • search by name / barcode / SKU through the shared catalog provider
//   • Arrow Down / Arrow Up move the highlight, Enter adds, Escape cancels
//   • empty result sets never add anything
//   • the chosen product goes through the canonical add path, so a repeated
//     add merges into the existing cart line (quantity-increment rule)
//   • barcode scanning and the existing POS shortcuts keep working
//   • Arabic (RTL) and French layouts
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
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

const _catalogPath = '/api/v1/products';

const _defaultScopes = <String>[
  'pos_sale',
  'pos_discount',
  'pos_credit_sale',
  'product_view',
  'customer_view',
];

// ---------------------------------------------------------------------------
// Fixtures — a tiny three-product catalog. The picker must show name,
// barcode, SKU, selling price and stock for every one of them.
// ---------------------------------------------------------------------------

Map<String, dynamic> _product({
  required String id,
  required String name,
  String? barcode,
  String? sku,
  String price = '10.0',
  String quantity = '20',
  String unit = 'piece',
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': sku,
      'description': null,
      'unit': unit,
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

final _bread = _product(
  id: '00000000-0000-0000-0000-0000000000a1',
  name: 'Bread',
  barcode: '111',
  sku: 'BREAD-01',
  price: '10.0',
  quantity: '20',
);

final _milk = _product(
  id: '00000000-0000-0000-0000-0000000000a2',
  name: 'Milk',
  barcode: '222',
  sku: 'MILK-02',
  price: '15.0',
  quantity: '5',
);

final _sugar = _product(
  id: '00000000-0000-0000-0000-0000000000a3',
  name: 'Sugar',
  barcode: '333',
  sku: 'SUGAR-03',
  price: '20.0',
  quantity: '0',
);

final List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[
  _bread,
  _milk,
  _sugar,
];

/// Server-side search semantics the POS catalog endpoint implements:
/// name, barcode or reference, case-insensitive.
List<Map<String, dynamic>> _filterCatalog(String? term) {
  final q = (term ?? '').trim().toLowerCase();
  if (q.isEmpty) return _catalog;
  return _catalog.where((p) {
    final name = (p['name'] as String).toLowerCase();
    final barcode = (p['barcode'] as String? ?? '').toLowerCase();
    final sku = (p['sku'] as String? ?? '').toLowerCase();
    return name.contains(q) || barcode.contains(q) || sku.contains(q);
  }).toList();
}

AuthUser _user() => AuthUser(
      id: '00000000-0000-0000-0000-0000000000b1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _defaultScopes,
    );

void _mockDio(MockDio dio) {
  // ApiClient registers its auth/log interceptors on the injected Dio.
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  Future<Response<dynamic>> respond(
    String path,
    Map<String, dynamic>? queryParameters,
  ) async {
    if (path == _catalogPath) {
      final items = _filterCatalog(queryParameters?['search'] as String?);
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'items': items, 'total': items.length},
      );
    }
    if (path == '/api/v1/products/barcode-lookup') {
      final code = queryParameters?['barcode'] as String? ?? '';
      final hit = _catalog.where((p) => p['barcode'] == code).toList();
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: hit.isEmpty
            ? {'found': false}
            : {
                'found': true,
                'kind': 'product',
                'product_id': hit.first['id'],
                'product_name': hit.first['name'],
                'product_price': hit.first['price'],
                'product_quantity': hit.first['quantity'],
                'product_unit': hit.first['unit'],
                'variant_id': null,
                'selling_unit_id': null,
                'is_archived': false,
              },
      );
    }
    // Product detail (the scan path re-fetches the product by id).
    if (path.startsWith('/api/v1/products/') &&
        !path.endsWith('/variants') &&
        !path.endsWith('/selling-units')) {
      final id = path.substring('/api/v1/products/'.length);
      final hit = _catalog.where((p) => p['id'] == id).toList();
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: hit.isEmpty ? <String, dynamic>{} : hit.first,
      );
    }
    // No variants / no selling units → the add path goes straight to a
    // direct cart line (the simplest canonical add).
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: {'items': <dynamic>[], 'total': 0},
    );
  }

  when(() => dio.get(any())).thenAnswer(
    (inv) => respond(inv.positionalArguments.first as String, null),
  );
  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer(
    (inv) => respond(
      inv.positionalArguments.first as String,
      inv.namedArguments[#queryParameters] as Map<String, dynamic>?,
    ),
  );
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  Size size = const Size(1366, 800),
  AppLocale locale = AppLocale.en,
  TextDirection direction = TextDirection.ltr,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider
            .overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user()),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        posSettingsProvider.overrideWith((ref) => PosSettingsNotifier(prefs)),
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
}

PosCartState _cart(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byKey(const Key('pos-screen'))),
    ).read(posCartProvider);

Finder get _dialog => find.byKey(const Key('product-picker-dialog'));
Finder get _searchField => find.byKey(const Key('product-picker-search'));

/// Types [text] into the picker search box and lets the 250 ms debounce and
/// the (instant) mock response land.
Future<void> _typeSearch(WidgetTester tester, String text) async {
  await tester.enterText(_searchField, text);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 50));
}

/// The rows currently rendered by the picker.
List<String> _rowTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(
      find.descendant(of: _dialog, matching: find.byType(ListTile)),
    )
    .map((t) => (t.title as Text).data!)
    .toList();

/// Index of the highlighted row (-1 when nothing is selected).
int _selectedRow(WidgetTester tester) {
  final tiles = tester
      .widgetList<ListTile>(
        find.descendant(of: _dialog, matching: find.byType(ListTile)),
      )
      .toList();
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i].selected) return i;
  }
  return -1;
}

Future<void> _pressCtrlN(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  late MockDio dio;

  setUp(() {
    dio = MockDio();
    _mockDio(dio);
    BarcodeScannerGateway.instance.resetForTest();
  });

  group('opening the picker', () {
    testWidgets('the POS button opens the picker', (tester) async {
      await _pumpApp(tester, dio: dio);

      expect(_dialog, findsNothing);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
      // The complete catalog, not just the workspace page's rows.
      expect(_rowTitles(tester), <String>['Bread', 'Milk', 'Sugar']);
    });

    testWidgets('Ctrl+N opens the picker', (tester) async {
      await _pumpApp(tester, dio: dio);

      await _pressCtrlN(tester);
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
    });

    testWidgets('the button label shows its shortcut', (tester) async {
      await _pumpApp(tester, dio: dio);

      final button = find.byKey(const Key('pos-product-picker-button'));
      expect(find.descendant(of: button, matching: find.text('Ctrl+N')),
          findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('the search field is focused as soon as the picker opens',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      final editable = find.descendant(
        of: _searchField,
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
      expect(tester.widget<TextField>(_searchField).autofocus, isTrue);
    });

    testWidgets('search by product name', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'Mil');
      expect(_rowTitles(tester), <String>['Milk']);
    });

    testWidgets('search by barcode', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, '333');
      expect(_rowTitles(tester), <String>['Sugar']);
    });

    testWidgets('search by SKU / reference', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'MILK-02');
      expect(_rowTitles(tester), <String>['Milk']);
    });

    testWidgets('rows show barcode, SKU, price and stock', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'BREAD');

      expect(find.descendant(of: _dialog, matching: find.text('10')),
          findsOneWidget);
      expect(find.descendant(of: _dialog, matching: find.text('20 piece')),
          findsOneWidget);
      final subtitle = tester
          .widget<ListTile>(
            find.descendant(of: _dialog, matching: find.byType(ListTile)),
          )
          .subtitle as Text;
      expect(subtitle.data, contains('111'));
      expect(subtitle.data, contains('BREAD-01'));
    });

    testWidgets('an empty result set shows the empty state', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'nothing-matches-this');

      expect(_rowTitles(tester), isEmpty);
      expect(find.byKey(const Key('product-picker-empty')), findsOneWidget);
    });
  });

  group('keyboard navigation', () {
    testWidgets('the first match is highlighted automatically',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      expect(_selectedRow(tester), 0);
    });

    testWidgets('Arrow Down / Arrow Up move the highlight', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 2);

      // Wraps around to the first row.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 2);
    });

    testWidgets('filtering selects the first matching row', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 1);

      await _typeSearch(tester, 'Sugar');
      expect(_rowTitles(tester), <String>['Sugar']);
      expect(_selectedRow(tester), 0);
    });

    testWidgets('Enter adds the highlighted product and closes',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'Milk');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Milk');
      expect(cart.lines.single.quantity, '1');
    });

    testWidgets('Enter on an empty result set adds nothing', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'nothing-matches-this');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
      expect(_cart(tester).lines, isEmpty);
    });

    testWidgets('Escape closes without adding', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(_cart(tester).lines, isEmpty);
    });

    testWidgets('Escape cancels even with a highlighted row', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(_cart(tester).lines, isEmpty);
    });
  });

  group('cart integration', () {
    testWidgets('a repeated add merges into the existing cart line',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      Future<void> addBread() async {
        await tester.tap(find.byKey(const Key('pos-product-picker-button')));
        await tester.pumpAndSettle();
        await _typeSearch(tester, 'Bread');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }

      await addBread();
      expect(_cart(tester).lines, hasLength(1));
      expect(_cart(tester).lines.single.quantity, '1');

      await addBread();
      final cart = _cart(tester);
      // The existing quantity-increment rule: ONE line, quantity 2.
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      expect(cart.lines.single.quantity, '2');
    });

    testWidgets('an out-of-stock product never enters the cart',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await _typeSearch(tester, 'Sugar');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // Stock validation is NOT bypassed by the picker.
      expect(_cart(tester).lines, isEmpty);
    });
  });

  group('existing POS behaviour', () {
    testWidgets('barcode scanning still adds a product after using the picker',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      // Open and close the picker first: its route must not hijack scans.
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);

      // A scan arriving while the cashier is parked in the POS search field
      // (the field's own barcode path) still resolves and adds the product.
      final posSearchField = find.byKey(const Key('pos-search-field'));
      await tester.tap(posSearchField);
      await tester.pumpAndSettle();
      await typeWedgeScanIntoField(tester, posSearchField, '111');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      // The code was consumed as a scan, not left as a search phrase.
      expect(
        tester.widget<TextField>(posSearchField).controller?.text ?? '',
        isEmpty,
      );
    });

    testWidgets('POS shortcuts still respond while the picker is closed',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      // Put a line in the cart through the picker, then use a POS shortcut:
      // F12 = clear cart (its confirm dialog proves the page bindings are
      // alive next to the picker's Ctrl+N registration).
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();
      await _typeSearch(tester, 'Bread');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_cart(tester).lines, hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clear-cart-confirm')), findsOneWidget);
    });

    testWidgets('the picker owns Escape while open (POS never sees it)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Only the picker closed — the POS Escape handler did not run.
      expect(_dialog, findsNothing);
      expect(find.byKey(const Key('clear-cart-confirm')), findsNothing);
    });
  });

  group('localization', () {
    testWidgets('Arabic RTL renders the picker', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
      expect(
        find.descendant(of: _dialog, matching: find.text('اختر المنتج')),
        findsOneWidget,
      );
      expect(_rowTitles(tester), contains('Bread'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('French renders the picker', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.fr);
      await tester.tap(find.byKey(const Key('pos-product-picker-button')));
      await tester.pumpAndSettle();

      expect(_dialog, findsOneWidget);
      expect(
        find.descendant(
          of: _dialog,
          matching: find.text('Sélectionner un produit'),
        ),
        findsOneWidget,
      );
      expect(_rowTitles(tester), contains('Bread'));
      expect(tester.takeException(), isNull);
    });
  });
}
