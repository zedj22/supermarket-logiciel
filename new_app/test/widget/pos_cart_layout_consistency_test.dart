// POS cart layout consistency — the cart ALWAYS renders the compact table.
//
// Contract under test (regression for the renderer flipping between a
// card list and the table when the catalog/layout switch changed):
//  * catalog hidden (`show_pos_product_list` OFF, the default) → table;
//  * catalog visible (OFF → ON) → the SAME table, beside the catalog;
//  * toggling the catalog setting on a live screen never changes the
//    renderer;
//  * the POS layout switch (standard | reversed) never changes the
//    renderer either — it only moves the panels;
//  * product and pack rows keep every control (qty stepper, line
//    discount, line total, remove, pack components);
//  * a narrow window and Arabic RTL keep working without overflow.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
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
const _scopes = <String>['pos_sale', 'product_view', 'pos_discount'];

Map<String, dynamic> _product({
  required String id,
  required String name,
  String price = '10.0',
  String quantity = '20',
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'barcode': null,
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

final List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[
  _product(id: 'p-bread', name: 'Bread'),
  _product(id: 'p-milk', name: 'Milk', price: '15.0'),
];

final Map<String, dynamic> _familyPack = <String, dynamic>{
  'id': 'pack-1',
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

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void _stubBackend(MockDio dio) {
  Object? bodyFor(String path) {
    if (path == _catalogPath) {
      return <String, Object>{'items': _catalog, 'total': _catalog.length};
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
    return <String, Object>{'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.get(any())).thenAnswer(
    (invocation) async => _ok(
      invocation.positionalArguments.first as String? ?? '',
      bodyFor(invocation.positionalArguments.first as String? ?? ''),
    ),
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

const _bread = CartLine(
  productId: 'p1',
  name: 'Bread',
  quantity: '2',
  unitPrice: '10',
  availableStock: '20',
);

const _pack = CartLine(
  packId: 'pack-1',
  name: 'Family Pack',
  quantity: '1',
  unitPrice: '250',
  componentsSummary: '2 × Bread',
);

/// The compact table's own cells — one horizontal row per line, with the
/// shared column headers above them. The card renderer's `summary` cell
/// must never come back.
void _expectTableCart(String key) {
  expect(find.byKey(const Key('pos-cart-lines')), findsOneWidget);
  expect(find.byKey(const Key('pos-dense-header')), findsOneWidget);
  expect(find.byKey(Key('cart-line-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-name-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-price-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-total-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-qty-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-qty-dec-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-qty-inc-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-discount-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-remove-$key')), findsOneWidget);
  expect(find.byKey(Key('cart-line-summary-$key')), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('cart renderer is independent of the product catalog', () {
    testWidgets('catalog hidden → compact table', (tester) async {
      final container = await _pumpPos(tester, showProductList: false);
      expect(find.byKey(const Key('pos-product-catalog')), findsNothing);
      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      _expectTableCart(_bread.key);
      expect(tester.takeException(), isNull);
    });

    testWidgets('catalog visible → the SAME compact table', (tester) async {
      final container = await _pumpPos(tester, showProductList: true);
      expect(find.byKey(const Key('pos-product-catalog')), findsOneWidget);
      expect(find.byKey(const Key('pos-layout-switch')), findsOneWidget);

      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      _expectTableCart(_bread.key);
      // The cart keeps its own column beside the catalog (not the whole
      // window), and the catalog is still on screen.
      expect(
        tester.getSize(find.byKey(const Key('pos-cart-panel'))).width,
        lessThan(tester.view.physicalSize.width),
      );
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the catalog ON/OFF never changes the renderer',
        (tester) async {
      final container = await _pumpPos(tester, showProductList: false);
      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      // OFF → ON
      container.read(posSettingsProvider.notifier).setShowPosProductList(true);
      await tester.pumpAndSettle();
      _expectTableCart(_bread.key);
      expect(find.byKey(const Key('pos-product-catalog')), findsOneWidget);
      expect(container.read(posCartProvider).lines.single.key, _bread.key);

      // ON → OFF
      container.read(posSettingsProvider.notifier).setShowPosProductList(false);
      await tester.pumpAndSettle();
      _expectTableCart(_bread.key);
      expect(find.byKey(const Key('pos-product-catalog')), findsNothing);
      expect(container.read(posCartProvider).lines.single.key, _bread.key);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the POS layout configuration never changes the renderer',
        (tester) async {
      final container = await _pumpPos(tester, showProductList: true);
      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      _expectTableCart(_bread.key);

      // Standard → reversed: the panels swap SIDES only.
      await container
          .read(posLayoutSwitchProvider.notifier)
          .setLayout(PosScreenLayout.reversed);
      await tester.pumpAndSettle();
      _expectTableCart(_bread.key);

      await container
          .read(posLayoutSwitchProvider.notifier)
          .setLayout(PosScreenLayout.standard);
      await tester.pumpAndSettle();
      _expectTableCart(_bread.key);
      expect(tester.takeException(), isNull);
    });
  });

  group('table rows keep every control', () {
    testWidgets('product row: qty stepper, qty field, discount, total, remove',
        (tester) async {
      final container = await _pumpPos(tester, showProductList: false);
      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      // + increments the line, the qty field shows the committed value.
      await tester.tap(find.byKey(Key('cart-line-qty-inc-${_bread.key}')));
      await tester.pump();
      expect(container.read(posCartProvider).lines.single.quantity, '3');
      expect(
        tester
            .widget<TextField>(find.byKey(Key('cart-line-qty-${_bread.key}')))
            .controller!
            .text,
        '3',
      );

      // − decrements it back.
      await tester.tap(find.byKey(Key('cart-line-qty-dec-${_bread.key}')));
      await tester.pump();
      expect(container.read(posCartProvider).lines.single.quantity, '2');

      // The line discount field is the canonical mutation path.
      await tester.enterText(
        find.byKey(Key('cart-line-discount-${_bread.key}')),
        '2',
      );
      await tester.pump();
      expect(container.read(posCartProvider).lines.single.lineDiscount, '2');

      // The line total and the remove button are both on the row.
      expect(find.byKey(Key('cart-line-total-tap-${_bread.key}')),
          findsOneWidget);
      await tester.tap(find.byKey(Key('cart-line-remove-${_bread.key}')));
      await tester.pump();
      expect(container.read(posCartProvider).isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pack row keeps its badge, components and controls',
        (tester) async {
      final container = await _pumpPos(tester, showProductList: true);
      container.read(posCartProvider.notifier).addLine(_pack);
      await tester.pump();

      _expectTableCart(_pack.key);
      expect(
        find.byKey(Key('cart-line-pack-badge-${_pack.key}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('cart-line-pack-components-${_pack.key}')),
        findsOneWidget,
      );
      expect(find.byKey(Key('cart-line-qty-${_pack.key}')), findsOneWidget);
      expect(container.read(posCartProvider).lines.single.packId, 'pack-1');
      expect(tester.takeException(), isNull);
    });
  });

  group('responsive and RTL', () {
    testWidgets('narrow window (600x800) keeps the compact table', (tester) async {
      final container = await _pumpPos(
        tester,
        showProductList: false,
        size: const Size(600, 800),
      );
      container.read(posCartProvider.notifier).addLine(_bread);
      // Let the chrome-compaction probe converge at this short viewport.
      await tester.pumpAndSettle();

      _expectTableCart(_bread.key);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('very short window (600x500) scrolls instead of overflowing',
        (tester) async {
      final container = await _pumpPos(
        tester,
        showProductList: false,
        size: const Size(600, 500),
      );
      container.read(posCartProvider.notifier).addLine(_bread);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byKey(Key('cart-line-${_bread.key}')), findsOneWidget);
      expect(find.byKey(const Key('pos-dense-header')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Arabic RTL with the catalog on keeps the compact table',
        (tester) async {
      final container = await _pumpPos(
        tester,
        showProductList: true,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      container.read(posCartProvider.notifier).addLine(_bread);
      await tester.pump();

      _expectTableCart(_bread.key);
      expect(find.byKey(const Key('pos-product-catalog')), findsOneWidget);
      expect(
        Directionality.of(
          tester.element(find.byKey(Key('cart-line-${_bread.key}'))),
        ),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
