// Purchase → POS stock propagation (Objective 3) regression suite.
//
// Root cause of the reported bug: a cart line snapshots
// `availableStock` when it is added, and receiving a purchase on the
// Purchases screen never re-read the quantity views. The POS therefore
// validated the cart against pre-purchase stock — a restock blocked
// additions that were now legal, and a sale made elsewhere let the
// cashier over-add.
//
// Fixes under test:
//  * `PurchasesNotifier.onStockMutation` fires on the stock-changing
//    mutations (create / receive / cancel) and `refreshStockViews`
//    re-reads only the quantity providers that are ALREADY alive
//    (posSearch / products / inventory), never waking closed screens.
//  * `PosCartNotifier.syncAvailableStock` re-seeds the cart's per-line
//    snapshots from the catalog, and the POS screen runs it after every
//    catalog load (activation and F5), warning the cashier with the
//    localized toast when a line's stock SHRANK.
//
// The server stays authoritative at checkout (`sale.py` rejects
// insufficient stock) — these tests never weaken that.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/features/purchases/purchases_providers.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
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

const _catalogPath = '/api/v1/products';
const _productId = '00000000-0000-0000-0000-0000000000p1';
const _toggleKey = Key('page-toggle');
const _stockToastKey = Key('pos-cart-stock-changed-toast');

Map<String, dynamic> _product(String quantity) => <String, dynamic>{
      'id': _productId,
      'name': 'Bread',
      'price': '10.0',
      'cost': '5.0',
      'quantity': quantity,
      'unit': 'piece',
      'vat_rate': 0,
    };

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: 200,
    );

/// Mock Dio whose catalog stock comes from [stock] (read per call, so a
/// test can move the quantity between requests) and counts catalog
/// fetches into [catalogHits].
void _mockDio(
  MockDio dio, {
  required String Function() stock,
  List<String>? catalogHits,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    if (path == _catalogPath) {
      catalogHits?.add(path);
      return _ok(path, {
        'items': [_product(stock())],
        'total': 1,
        'page': 1,
        'pages': 1,
      });
    }
    return _ok(path, {
      'items': <dynamic>[],
      'total': 0,
      'page': 1,
      'pages': 1,
    });
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    return _ok(path, {
      'items': <dynamic>[],
      'total': 0,
      'page': 1,
      'pages': 1,
    });
  });

  final purchaseBody = <String, dynamic>{
    'id': 'purchase-1',
    'status': 'received',
    'supplier_id': 'supplier-1',
  };
  when(() => dio.post(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String, purchaseBody),
  );
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String, purchaseBody),
  );
  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String, purchaseBody),
  );
  when(() => dio.delete(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String, purchaseBody),
  );
}

AuthUser _user() => const AuthUser(
      id: '00000000-0000-0000-0000-0000000000b1',
      fullName: 'Cashier',
      isActive: true,
      roles: ['cashier'],
      permissions: [
        'pos_sale',
        'pos_discount',
        'product_view',
        'customer_view',
        'purchase_view',
        'purchase_create',
      ],
    );

/// Swaps the body under the POS on demand: the toggle button disposes the
/// POS State (the providers survive — they are app-scoped) and, when
/// pressed again, recreates it, which re-runs `initState` → catalog load
/// → `_syncCartStocks` exactly like leaving and re-entering the page.
class _PageSwitcher extends StatefulWidget {
  const _PageSwitcher();

  @override
  State<_PageSwitcher> createState() => _PageSwitcherState();
}

class _PageSwitcherState extends State<_PageSwitcher> {
  bool _onPos = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: _onPos
                ? const PosScreen()
                : const Center(child: Text('other page')),
          ),
          TextButton(
            key: _toggleKey,
            onPressed: () => setState(() => _onPos = !_onPos),
            child: Text(_onPos ? 'leave' : 'return'),
          ),
        ],
      ),
    );
  }
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  Size size = const Size(1366, 768),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user()),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const _PageSwitcher(),
      ),
    ),
  );
  await _pumpFrames(tester);
  expect(find.byKey(const Key('pos-screen')), findsOneWidget);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

/// Lets mocked requests and the screen's post-frame work settle without
/// relying on `pumpAndSettle` (the POS hosts animations that never idle).
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('cart snapshot re-sync (PosCartNotifier.syncAvailableStock)', () {
    PosCartNotifier cart() =>
        PosCartNotifier(MockDio(), () => 'en', () async => 'device');

    test('raises the snapshot when the shelf grew', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p1',
          name: 'Bread',
          availableStock: '5',
        ));

      final decreased = notifier.syncAvailableStock(const {'p1': '9'});

      expect(decreased, isEmpty, reason: 'a restock is not a warning');
      expect(notifier.state.lines.single.availableStock, '9');
    });

    test('lowers the snapshot and reports the line when stock shrank', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p1',
          name: 'Bread',
          availableStock: '5',
        ));

      final decreased = notifier.syncAvailableStock(const {'p1': '2'});

      expect(decreased, [notifier.state.lines.single.key]);
      expect(notifier.state.lines.single.availableStock, '2');
    });

    test('leaves an unchanged quantity alone', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p1',
          name: 'Bread',
          availableStock: '5',
        ));

      expect(notifier.syncAvailableStock(const {'p1': '5'}), isEmpty);
      expect(notifier.state.lines.single.availableStock, '5');
    });

    test('pack lines never take a product-level quantity', () {
      final notifier = cart()
        ..addLine(const CartLine(
          packId: 'pk1',
          productId: 'p1',
          name: 'Family Pack',
          availableStock: '5',
        ));

      expect(notifier.syncAvailableStock(const {'p1': '1'}), isEmpty);
      expect(notifier.state.lines.single.availableStock, '5');
    });

    test('variant lines keep their variant-level snapshot', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p1',
          variantId: 'v1',
          name: 'Bread 1kg',
          availableStock: '4',
        ));

      expect(notifier.syncAvailableStock(const {'p1': '1'}), isEmpty);
      expect(notifier.state.lines.single.availableStock, '4');
    });

    test('products missing from the loaded catalog page are untouched', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p2',
          name: 'Not on page 1',
          availableStock: '7',
        ));

      expect(notifier.syncAvailableStock(const {'p1': '1'}), isEmpty);
      expect(notifier.state.lines.single.availableStock, '7');
    });

    test('an empty catalog map is a no-op', () {
      final notifier = cart()
        ..addLine(const CartLine(
          productId: 'p1',
          name: 'Bread',
          availableStock: '5',
        ));

      expect(notifier.syncAvailableStock(const {}), isEmpty);
      expect(notifier.state.lines.single.availableStock, '5');
    });
  });

  group('purchase mutations that move stock', () {
    test(
        'create / receive / cancel fire onStockMutation, '
        'draft-only edits do not', () async {
      var fired = 0;
      final dio = MockDio();
      _mockDio(dio, stock: () => '10');

      final notifier = PurchasesNotifier(
        dio,
        () => 'en',
        onStockMutation: () => fired++,
      );

      await notifier.receive('purchase-1');
      expect(fired, 1, reason: 'receive adds stock');

      await notifier.cancel('purchase-1');
      expect(fired, 2, reason: 'cancel reverses stock');

      await notifier.create({'supplier_id': 'supplier-1'});
      expect(fired, 3, reason: 'create may post atomically (receive: true)');

      await notifier.update('purchase-1', {'note': 'draft edit'});
      expect(fired, 3, reason: 'a draft edit changes no stock');

      await notifier.deleteDraft('purchase-1');
      expect(fired, 3, reason: 'deleting a draft changes no stock');
    });

    test('pos_cart_stock_changed is translated in every locale', () {
      for (final loc in ['ar', 'fr', 'en']) {
        expect(
          AppStrings.t('pos_cart_stock_changed', loc),
          isNotEmpty,
          reason: 'missing $loc translation',
        );
      }
    });
  });

  group('live propagation', () {
    testWidgets(
        'receiving a purchase re-reads an open POS catalog',
        (tester) async {
      var stock = '2';
      final catalogHits = <String>[];
      final dio = MockDio();
      _mockDio(dio, stock: () => stock, catalogHits: catalogHits);
      final container = await _pumpApp(tester, dio: dio);

      expect(
        container.read(posSearchProvider).items.single.quantity,
        '2',
        reason: 'precondition: the POS shows the pre-purchase stock',
      );
      final hitsBefore = catalogHits.length;

      stock = '22';
      await container
          .read(purchasesProvider.notifier)
          .receive('purchase-1');
      await _pumpFrames(tester);

      expect(
        catalogHits.length,
        greaterThan(hitsBefore),
        reason: 'the catalog was refetched instead of staying stale',
      );
      expect(
        container.read(posSearchProvider).items.single.quantity,
        '22',
        reason: 'the open catalog now serves the received quantity',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a purchase received while the POS is away re-seeds the cart '
        'and warns when a line now exceeds the shelf', (tester) async {
      var stock = '5';
      final dio = MockDio();
      _mockDio(dio, stock: () => stock);
      final container = await _pumpApp(tester, dio: dio);

      container.read(posCartProvider.notifier).addLine(const CartLine(
            productId: _productId,
            name: 'Bread',
            quantity: '4',
            availableStock: '5',
          ));
      expect(
        container.read(posCartProvider).lines.single.availableStock,
        '5',
      );

      // Cashier leaves the POS (State disposed, providers survive).
      await tester.tap(find.byKey(_toggleKey));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('pos-screen')), findsNothing);

      // Stock moves elsewhere (purchase received on the Purchases screen).
      stock = '3';
      await container
          .read(purchasesProvider.notifier)
          .receive('purchase-1');
      await _pumpFrames(tester);
      expect(
        container.read(posSearchProvider).items.single.quantity,
        '3',
        reason: 'the provider reloaded even with the screen disposed',
      );

      // Back to the POS: activation re-seeds the held cart's snapshots.
      await tester.tap(find.byKey(_toggleKey));
      await _pumpFrames(tester);

      expect(
        container.read(posCartProvider).lines.single.availableStock,
        '3',
        reason: 'the held line must validate against the current shelf',
      );
      expect(
        find.byKey(_stockToastKey),
        findsOneWidget,
        reason: 'a shrinking line has to warn the cashier',
      );
      expect(
        find.text(
          AppStrings.t(
            'pos_cart_stock_changed',
            container.read(localeProvider).flutterLocale.languageCode,
          ),
        ),
        findsOneWidget,
        reason: 'the warning is localized, not backend text',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a restock re-seeds the cart silently', (tester) async {
      var stock = '5';
      final dio = MockDio();
      _mockDio(dio, stock: () => stock);
      final container = await _pumpApp(tester, dio: dio);

      container.read(posCartProvider.notifier).addLine(const CartLine(
            productId: _productId,
            name: 'Bread',
            quantity: '1',
            availableStock: '5',
          ));

      await tester.tap(find.byKey(_toggleKey));
      await _pumpFrames(tester);
      stock = '9';
      await tester.tap(find.byKey(_toggleKey));
      await _pumpFrames(tester);

      expect(
        container.read(posCartProvider).lines.single.availableStock,
        '9',
        reason: 'the snapshot follows the shelf upward too',
      );
      expect(
        find.byKey(_stockToastKey),
        findsNothing,
        reason: 'a restock needs no warning',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
