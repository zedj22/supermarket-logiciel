// Reported Windows repro (go_router shell, DEBUG):
//   1. reach the POS screen,
//   2. scan a product that has an additional selling unit,
//   3. in the selling-unit dialog choose OPTION 2 (the first non-base unit),
//   4. type quantity 2,
//   5. press OK.
// The app then paints the red error screen: `InheritedElement.notifyClients`
// at framework.dart:6417 raised while an `UnmanagedRestorationScope` is
// being built inside the ROOT go_router Navigator, followed by
// `attached: is not true` render assertions.
//
// The existing POS suites pump `MaterialApp(home: PosScreen())`, which has
// no go_router Navigator / ShellRoute / HeroControllerScope around the
// dialog — so they never enter the failing path. This suite drives the SAME
// flow inside the real `SupermarketPosApp` (real GoRouter + ScaffoldWithNav)
// and asserts the first reported exception is null.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pos_catalog_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

import '../helpers/wedge_scanner.dart';

class MockDio extends Mock implements Dio {}

/// Stateful fake: login saves the token, logout reads then clears it.
class TestCredentialStorage extends SecureCredentialStorage {
  String? _token;
  List<String> _roles = <String>[];
  List<String> _permissions = <String>[];

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
    _roles = <String>[];
    _permissions = <String>[];
  }
}

const String _loginPath = '/api/v1/auth/login';
const String _catalogPath = '/api/v1/products';
const String _favoritesPath = '/api/v1/pos/favorites';
const String _productId = '00000000-0000-0000-0000-0000000000p1';
const String _boxUnitId = 'su-box';
const String _barcode = '111111';

const List<String> _scopes = <String>[
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

Map<String, dynamic> _product() => <String, dynamic>{
  'id': _productId,
  'name': 'Bread',
  'barcode': _barcode,
  'unit': 'piece',
  'price': '10.0',
  'cost': '5',
  'avg_cost': '5',
  'quantity': '20',
  'low_stock_threshold': '5',
  'allow_negative_stock': false,
  'category_id': null,
  'category_name': null,
  'image_path': null,
  'is_archived': false,
};

Map<String, dynamic> _unit({
  required String id,
  required String name,
  required String multiplier,
  required String unitType,
  required bool isBaseUnit,
  required String sellingPrice,
  required String availableSelling,
  required String availableBase,
}) => <String, dynamic>{
  'id': id,
  'product_id': _productId,
  'name': name,
  'unit_type': unitType,
  'multiplier': multiplier,
  'barcode': null,
  'selling_price': sellingPrice,
  'is_base_unit': isBaseUnit,
  'is_archived': false,
  'available_base_qty': availableBase,
  'available_selling_qty': availableSelling,
  'effective_price': sellingPrice,
};

/// Base piece + ONE additional unit (Box = 10 Piece) — the product shape the
/// repro needs: the picker then renders [base, Box], so "option 2" is Box.
final List<Map<String, dynamic>> _sellingUnits = <Map<String, dynamic>>[
  _unit(
    id: 'su-base',
    name: 'Piece',
    multiplier: '1',
    unitType: 'piece',
    isBaseUnit: true,
    sellingPrice: '10',
    availableSelling: '20',
    availableBase: '20',
  ),
  _unit(
    id: _boxUnitId,
    name: 'Box',
    multiplier: '10',
    unitType: 'box',
    isBaseUnit: false,
    sellingPrice: '550',
    availableSelling: '2',
    availableBase: '200',
  ),
];

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
  requestOptions: RequestOptions(path: path),
  statusCode: 200,
  data: data,
);

Map<String, dynamic> _lookupHit() => <String, dynamic>{
  'found': true,
  'kind': 'product',
  'product_id': _productId,
  'product_name': 'Bread',
  'product_price': '10.0',
  'product_quantity': '20',
  'product_unit': 'piece',
  'variant_id': null,
  'selling_unit_id': null,
  'is_archived': false,
};

void _stubDio(MockDio dio) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  Object? bodyFor(String path, {String? barcode}) {
    if (path == '/api/v1/auth/setup/check') {
      return <String, dynamic>{'setup_needed': false};
    }
    if (path == '/api/v1/auth/login-users') {
      return <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': <dynamic>[
              <String, dynamic>{'name': 'admin'},
            ],
          },
        ],
        'total': 1,
      };
    }
    if (path == _catalogPath) {
      return <String, dynamic>{
        'items': <dynamic>[_product()],
        'total': 1,
      };
    }
    if (path == _favoritesPath) {
      return <String, dynamic>{'items': <dynamic>[], 'total': 0};
    }
    if (path == '/api/v1/products/barcode-lookup') {
      return _lookupHit();
    }
    if (path.endsWith('/variants')) {
      return <String, dynamic>{'items': <dynamic>[], 'total': 0};
    }
    if (path.endsWith('/selling-units')) {
      return <String, dynamic>{
        'items': _sellingUnits,
        'total': _sellingUnits.length,
      };
    }
    if (path.startsWith('$_catalogPath/') && path != _catalogPath) {
      // Product detail — what the scan resolve re-fetches.
      return _product();
    }
    if (path == '/api/v1/settings') {
      return <String, dynamic>{'items': <dynamic>[]};
    }
    return <String, dynamic>{'items': <dynamic>[], 'total': 0};
  }

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final params =
        invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
    if (path == '/api/v1/products/barcode-lookup') {
      return _ok(path, bodyFor(path, barcode: params?['barcode'] as String?));
    }
    return _ok(path, bodyFor(path));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });

  Future<Response<dynamic>> postAnswer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == _loginPath) {
      return _ok(path, <String, dynamic>{
        'access_token': 'tok-admin',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': <String, dynamic>{
          'id': 'u1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': <dynamic>[
            <String, dynamic>{
              'name': 'admin',
              'permissions': <dynamic>[
                for (final s in _scopes)
                  <String, dynamic>{
                    'id': 'p-$s',
                    'scope': s,
                    'description': null,
                  },
              ],
            },
          ],
        },
      });
    }
    return _ok(path, <String, dynamic>{});
  }

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(postAnswer);
  when(() => dio.post(any())).thenAnswer(postAnswer);
  when(
    () => dio.post(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(postAnswer);

  when(() => dio.delete(any())).thenAnswer(
    (_) async => Response<dynamic>(
      requestOptions: RequestOptions(path: '/x'),
      statusCode: 204,
    ),
  );
}

Future<ProviderContainer> _pumpApp(WidgetTester tester, MockDio dio) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(TestCredentialStorage()),
        posCatalogMode(),
      ],
      child: const SupermarketPosApp(),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Future<void> _login(WidgetTester tester) async {
  await tester.tap(find.text('Admin'));
  await tester.pumpAndSettle();
  for (final digit in <String>['1', '2', '3', '4']) {
    await tester.tap(find.text(digit));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('login-submit-button')));
  await tester.pumpAndSettle();
  expect(find.byType(AppNavRail), findsOneWidget, reason: 'login worked');
}

Future<void> _openPos(WidgetTester tester, ProviderContainer container) async {
  container.read(routerProvider).go('/pos');
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('pos-screen')), findsOneWidget);
}

/// Scan the product so the selling-unit picker opens.
///
/// [wedge] false → the burst is typed into the focused search field and
/// terminated with the field's submit action (the path the older POS suites
/// use). [wedge] true → focus is handed back to the workspace first and the
/// burst travels through the real `BarcodeScannerGateway` key pipeline, which
/// is what a keyboard-wedge scanner does on the device.
Future<void> _scanToPicker(WidgetTester tester, {required bool wedge}) async {
  if (wedge) {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('pos-search-field')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    await sendWedgeScan(tester, _barcode);
    await tester.pumpAndSettle();
  } else {
    await tester.tap(find.byKey(const Key('pos-search-field')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('pos-search-field')), _barcode);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }
  expect(
    find.byKey(const Key('selling-unit-picker')),
    findsOneWidget,
    reason: 'the product has an additional selling unit → picker opens',
  );
}

/// OPTION 2 (first non-base card) → quantity 2 → OK.
///
/// [fast] skips the settle after the option tap, so the quantity dialog is
/// still animating in when OK pops it and both dialog routes close inside the
/// same frame — the cadence a quick cashier produces.
Future<void> _confirmBox(WidgetTester tester, {bool fast = false}) async {
  await tester.tap(find.byKey(const Key('selling-unit-$_boxUnitId')));
  await tester.pump(fast ? Duration.zero : const Duration(milliseconds: 400));
  expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);

  await tester.enterText(find.byKey(const Key('quantity-input')), '2');
  await tester.pump();
  await tester.tap(find.byKey(const Key('quantity-submit')));
  await tester.pumpAndSettle();
}

void _expectBoxLine(ProviderContainer container, {required int total}) {
  final cart = container.read(posCartProvider);
  expect(cart.lines, hasLength(total));
  expect(cart.lines.last.quantity, '2');
  expect(cart.lines.last.sellingUnitId, _boxUnitId);
  expect(cart.lines.last.unitMultiplier, '10');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('scan → selling-unit OPTION 2 → quantity 2 → OK adds the line '
      'without the framework assertion', (tester) async {
    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    await _scanToPicker(tester, wedge: false);
    await _confirmBox(tester);

    _expectBoxLine(container, total: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same flow driven by a real wedge burst (gateway path)', (
    tester,
  ) async {
    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    await _scanToPicker(tester, wedge: true);
    await _confirmBox(tester);

    _expectBoxLine(container, total: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker keyboard selection followed by quantity confirmation '
      'does not leave stale route dependencies', (tester) async {
    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    // Open the picker through the global wedge gateway, then use its
    // number-key selection while focus belongs to the DialogRoute. This
    // runs the scanner's outside-screen route/focus gate before the
    // quantity dialog is pushed and popped.
    //
    // (Numpad `2`, not top-row `2`: while the scanner suspension is
    // held, an unshifted main-row digit is event-identical to a
    // scanner's first key and stays consumed — the provably-manual numpad
    // digit (NumLock character travels with it) is the safe number-key
    // path the picker keeps. See selling_unit_scanner_guard_test.dart.)
    await _scanToPicker(tester, wedge: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2, character: '2');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('quantity-input')), '2');
    await tester.pump();
    await tester.tap(find.byKey(const Key('quantity-submit')));
    await tester.pumpAndSettle();

    _expectBoxLine(container, total: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same flow with the quantity dialog confirmed while it is '
      'still animating in (both dialog routes close in one frame)', (
    tester,
  ) async {
    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    await _scanToPicker(tester, wedge: false);
    await _confirmBox(tester, fast: true);

    _expectBoxLine(container, total: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same flow on a narrow viewport (single-column picker, cart '
      'drawer instead of the side panel)', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    await _scanToPicker(tester, wedge: false);
    await _confirmBox(tester);

    _expectBoxLine(container, total: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelling quantity returns to the picker without adding a line',
    (tester) async {
      final dio = MockDio();
      _stubDio(dio);

      final container = await _pumpApp(tester, dio);
      await _login(tester);
      await _openPos(tester, container);
      await _scanToPicker(tester, wedge: false);

      await tester.tap(find.byKey(const Key('selling-unit-$_boxUnitId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quantity-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quantity-dialog')), findsNothing);
      // Cancelling quantity returns to the unit picker so another unit can be
      // chosen; it must not add a cart line or dismiss the parent picker.
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      expect(container.read(posCartProvider).lines, isEmpty);
      await tester.tap(find.byKey(const Key('pos-option-picker-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a wedge scan while the selling-unit picker is open is blocked', (
    tester,
  ) async {
    final dio = MockDio();
    _stubDio(dio);

    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _scanToPicker(tester, wedge: false);

    await sendWedgeScan(tester, _barcode);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
