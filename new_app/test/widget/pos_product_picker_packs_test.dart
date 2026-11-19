// Packs in the Ctrl+N quick product picker.
//
// The picker lists SALEABLE packs after the products, under the SAME search
// term and the SAME debounce (the pack list mirrors the settled catalog
// query). A pack is told apart by the localized badge and shows its selling
// price + component summary; selecting one runs the canonical pack flow
// (availability pre-flight, then ONE charged pack line with `pack_id`).
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

const _familyPackId = 'pack-1';
const _appleBoxId = 'pack-2';

const _scopes = <String>['pos_sale', 'product_view'];

// ---------------------------------------------------------------------------
// Fixtures — three products and three packs (one of them unsellable).
// ---------------------------------------------------------------------------

Map<String, dynamic> _product({
  required String id,
  required String name,
  String? barcode,
  String? sku,
  String price = '10.0',
  String quantity = '20',
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': sku,
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

final _bread = _product(
  id: '00000000-0000-0000-0000-0000000000a1',
  name: 'Bread',
  barcode: '111',
  sku: 'BREAD-01',
);
final _milk = _product(
  id: '00000000-0000-0000-0000-0000000000a2',
  name: 'Milk',
  barcode: '222',
  sku: 'MILK-02',
  price: '15.0',
  quantity: '5',
);
final _apple = _product(
  id: '00000000-0000-0000-0000-0000000000a3',
  name: 'Apple Juice',
  barcode: '444',
  sku: 'APPLE-03',
  price: '12.0',
  quantity: '7',
);

final List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[
  _bread,
  _milk,
  _apple,
];

Map<String, dynamic> _pack({
  required String id,
  required String name,
  String? barcode,
  String price = '250.0',
  bool active = true,
  int componentsCount = 1,
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'barcode': barcode,
      'price': price,
      'is_active': active,
      'is_archived': false,
      'components_count': componentsCount,
      'sum_of_parts': '300.0',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'components': [
        {
          'product_id': _bread['id'],
          'product_name': 'Bread',
          'product_unit': 'piece',
          'product_price': '10',
          'quantity': '2',
        },
      ],
    };

final List<Map<String, dynamic>> _packs = <Map<String, dynamic>>[
  _pack(id: _familyPackId, name: 'Family Pack', barcode: '777888999'),
  _pack(id: _appleBoxId, name: 'Apple Box', barcode: '555', price: '90.0'),
  _pack(id: 'pack-3', name: 'Retired Pack', barcode: '999000', active: false),
];

List<Map<String, dynamic>> _filterProducts(String? term) {
  final q = (term ?? '').trim().toLowerCase();
  if (q.isEmpty) return _catalog;
  return _catalog.where((p) {
    final name = '${p['name']}'.toLowerCase();
    final barcode = '${p['barcode'] ?? ''}'.toLowerCase();
    final sku = '${p['sku'] ?? ''}'.toLowerCase();
    return name.contains(q) || barcode.contains(q) || sku.contains(q);
  }).toList();
}

/// The packs endpoint matches pack name or barcode server-side.
List<Map<String, dynamic>> _filterPacks(String? term) {
  final q = (term ?? '').trim().toLowerCase();
  if (q.isEmpty) return _packs;
  return _packs.where((p) {
    final name = '${p['name']}'.toLowerCase();
    final barcode = '${p['barcode'] ?? ''}'.toLowerCase();
    return name.contains(q) || barcode.contains(q);
  }).toList();
}

Map<String, dynamic> _availabilityBody({String price = '250.0'}) =>
    <String, dynamic>{
      'pack_id': _familyPackId,
      'pack_name': 'Family Pack',
      'price': price,
      'is_active': true,
      'is_archived': false,
      'quantity': '1',
      'saleable': true,
      'max_pack_quantity': '3',
      'sum_of_parts': '300.0',
      'components': [
        {
          'product_id': _bread['id'],
          'product_name': 'Bread',
          'product_unit': 'piece',
          'required_per_pack': '2',
          'required_quantity': '2',
          'available_quantity': '6',
          'ok': true,
        },
      ],
      'errors': <String>[],
    };

class _Api {
  final List<Map<String, dynamic>> packQueries = <Map<String, dynamic>>[];
}

void _mockDio(MockDio dio, _Api api) {
  Object? bodyFor(String path, Map<String, dynamic> query) {
    if (path == _catalogPath) {
      final items = _filterProducts(query['search'] as String?);
      return <String, Object>{'items': items, 'total': items.length};
    }
    if (path == _packsPath) {
      api.packQueries.add(Map<String, dynamic>.from(query));
      final items = _filterPacks(query['search'] as String?);
      return <String, Object>{
        'items': items,
        'total': items.length,
        'page': 1,
        'page_size': 50,
        'pages': 1,
      };
    }
    if (path.endsWith('/availability')) {
      return _availabilityBody(
        price: path.contains(_appleBoxId) ? '90.0' : '250.0',
      );
    }
    // Product detail (the canonical add path re-fetches by id).
    if (path.startsWith('/api/v1/products/') &&
        !path.endsWith('/variants') &&
        !path.endsWith('/selling-units')) {
      final id = path.substring('/api/v1/products/'.length);
      for (final product in _catalog) {
        if (product['id'] == id) return product;
      }
      return <String, dynamic>{};
    }
    // No variants / no selling units → the add path builds a direct line.
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
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: bodyFor(path, query),
    );
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: bodyFor(path, const {}),
    );
  });
}

AuthUser _user() => AuthUser(
      id: '00000000-0000-0000-0000-0000000000b1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  AppLocale locale = AppLocale.en,
  TextDirection direction = TextDirection.ltr,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1366, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
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

Finder get _dialog => find.byKey(const Key('product-picker-dialog'));
Finder get _searchField => find.byKey(const Key('product-picker-search'));

PosCartState _cart(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byKey(const Key('pos-screen'))),
    ).read(posCartProvider);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pos-product-picker-button')));
  await tester.pumpAndSettle();
}

/// Types [text] into the picker search box and lets the 250 ms debounce and
/// the (instant) mock responses land — products and packs share it.
Future<void> _typeSearch(WidgetTester tester, String text) async {
  await tester.enterText(_searchField, text);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Row titles, handling both the plain product title and the pack row (a
/// Row holding the name plus the badge).
List<String> _rowTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(
      find.descendant(of: _dialog, matching: find.byType(ListTile)),
    )
    .map((tile) {
      final title = tile.title;
      if (title is Text) return title.data!;
      for (final child in (title as Row).children) {
        if (child is Text) return child.data!;
        if (child is Expanded && child.child is Text) {
          return (child.child as Text).data!;
        }
      }
      throw StateError('row title has no text');
    })
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

void main() {
  late MockDio dio;
  late _Api api;

  setUp(() {
    dio = MockDio();
    api = _Api();
    _mockDio(dio, api);
  });

  group('listing', () {
    testWidgets('saleable packs appear alongside products with the badge',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      expect(
        _rowTitles(tester),
        <String>[
          'Bread',
          'Milk',
          'Apple Juice',
          'Family Pack',
          'Apple Box',
        ],
      );
      expect(
        find.byKey(const Key('product-picker-pack-badge-$_familyPackId')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('product-picker-pack-badge-$_familyPackId')),
          matching: find.text(AppStrings.t('pack', 'en')),
        ),
        findsOneWidget,
      );
      // Selling price + component summary on the pack row.
      expect(
        find.descendant(of: _dialog, matching: find.text('250')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _dialog, matching: find.text('777888999  •  Bread')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-saleable packs never appear', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      expect(find.text('Retired Pack'), findsNothing);
      expect(find.byKey(const Key('product-picker-pack-badge-pack-3')),
          findsNothing);
      // The two saleable packs are still listed.
      expect(_rowTitles(tester).where((t) => t.endsWith('Pack')), hasLength(1));
      expect(_rowTitles(tester), contains('Apple Box'));
    });

    testWidgets('Arabic RTL shows the localized badge', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      await _openPicker(tester);

      expect(
        find.descendant(
          of: find.byKey(const Key('product-picker-pack-badge-$_familyPackId')),
          matching: find.text(AppStrings.t('pack', 'ar')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('search', () {
    testWidgets('searching by pack name resolves the pack', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, 'Family');

      expect(_rowTitles(tester), <String>['Family Pack']);
      // The pack list rides the SAME settled query (no second debounce).
      expect(api.packQueries.last['search'], 'Family');
    });

    testWidgets('searching by pack barcode resolves the pack', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, '777888999');
      expect(_rowTitles(tester), <String>['Family Pack']);

      await _typeSearch(tester, '555');
      expect(_rowTitles(tester), <String>['Apple Box']);
    });

    testWidgets('a mixed term lists the product and the pack', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, 'Apple');

      expect(_rowTitles(tester), <String>['Apple Juice', 'Apple Box']);
      expect(_selectedRow(tester), 0);
    });

    testWidgets('a term with no match shows the empty state', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, 'no-such-thing');

      expect(_rowTitles(tester), isEmpty);
      expect(find.byKey(const Key('product-picker-empty')), findsOneWidget);
    });
  });

  group('keyboard navigation', () {
    testWidgets('arrow keys move across products and packs', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      expect(_selectedRow(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 2);

      // Into the pack rows.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 3);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 4);

      // Wraps back to the first product.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 4);
    });

    testWidgets('the highlight stays valid when results change',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selectedRow(tester), 1);

      await _typeSearch(tester, 'Family');
      expect(_rowTitles(tester), <String>['Family Pack']);
      expect(_selectedRow(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(_cart(tester).lines.single.isPack, isTrue);
    });

    testWidgets('Escape closes the picker without adding', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      expect(_cart(tester).lines, isEmpty);
    });
  });

  group('selection', () {
    testWidgets('Enter on a product keeps the existing add path',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, 'Milk');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.single;
      expect(line.name, 'Milk');
      expect(line.packId, isNull);
      expect(line.productId, _milk['id']);
    });

    testWidgets('Enter on a pack adds ONE pack line with pack_id',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await _typeSearch(tester, 'Family');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(_dialog, findsNothing);
      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.single;
      expect(line.isPack, isTrue);
      expect(line.packId, _familyPackId);
      expect(line.productId, isNull, reason: 'no fake product is invented');
      expect(line.quantity, '1');
      expect(line.unitPrice, '250.0');
      expect(line.availableStock, '3');
      expect(line.componentsSummary, contains('Bread'));

      final payload = line.toSaleJson();
      expect(payload['pack_id'], _familyPackId);
      expect(payload.containsKey('product_id'), isFalse);
    });

    testWidgets('a click on a pack row adds the pack too', (tester) async {
      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await tester.tap(
        find.byKey(const Key('product-picker-pack-name-$_appleBoxId')),
      );
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.packId, _appleBoxId);
      expect(cart.lines.single.unitPrice, '90.0');
    });

    testWidgets('a mixed search can add both a product and a pack',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      await _openPicker(tester);
      await _typeSearch(tester, 'Apple');
      // First row = product.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      await _openPicker(tester);
      await _typeSearch(tester, 'Apple');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final cart = _cart(tester);
      expect(cart.lines, hasLength(2));
      expect(cart.lines.where((l) => l.isPack), hasLength(1));
      expect(cart.lines.where((l) => !l.isPack), hasLength(1));
      expect(cart.lines.map((l) => l.key).toSet(), hasLength(2));
    });
  });
}
