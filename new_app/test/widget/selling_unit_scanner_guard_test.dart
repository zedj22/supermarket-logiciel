// Scanner-suspension regression suite (selling-unit dialog family).
//
// Reported bug: a keyboard-wedge burst arriving while the selling-unit
// picker (or the quantity dialog stacked on it) is open fell through the
// gateway's arming gates into the DIALOG's own focus tree: digit 1–9
// fired `PosOptionPickerDialog._onDigit` (silently confirming the default
// unit and opening the quantity dialog), the remaining digits typed into
// the quantity field, and the burst's Enter submitted the dialog — the
// burst changed the sale without any cashier action, and nothing of it
// was ever dispatched or queued.
//
// The fix scopes a suspension around both dialogs
// (`BarcodeScannerGateway.withScannerSuspended`): while it is held, no
// burst may dispatch (the raw path included) and every run is captured —
// consumed in front of the picker (no unit shortcut, no Enter
// confirmation) and passed through + rolled back in front of the
// quantity/amount field (manual typing and its Enter keep working, the
// terminator restores the field snapshot and swallows the scanner's
// Enter). These tests drive the REAL app (go_router shell) and the REAL
// gateway key pipeline, and assert:
//
//  * Test A — a burst in the picker changes nothing and is never
//    dispatched;
//  * Test B — scanner digits never reach the 1–9 shortcut, while arrows
//    and Enter still select a unit manually;
//  * Test C — a burst in the quantity field is restored and its Enter
//    never submits the dialog;
//  * Test D — manual quantity typing and Enter-submit still work;
//  * Test E — cancellation, never-queued, and clean suspension release
//    (the scanner works again the moment the last dialog is gone);
//  * gateway unit group — the suspension consumes main-row scanner
//    digits but exempts the two provably-manual shapes (numpad digit,
//    AZERTY Shift-digit) that a wedge scanner cannot emit;
//  * Test F — manual numpad number-key selection picks the unit and
//    completes the sale;
//  * Test G — a number key beyond the option list does nothing (as
//    before);
//  * Test H — number-key selection works for a different product with a
//    different unit configuration (first AND second option);
//  * Test I — an AZERTY FR-scanner burst (`-` at physical Digit 6) is
//    ignored completely, while the AZERTY human digit layer
//    (Shift + main-row digit) still selects;
//  * Test J — Escape cancels quantity → picker → closed, releasing the
//    suspension with no leak.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/scan_diagnostics.dart';
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

const String _p1Id = '00000000-0000-0000-0000-0000000000p1';
const String _p2Id = '00000000-0000-0000-0000-0000000000p2';
const String _p1Barcode = '111111';
const String _p2Barcode = '222222';
const String _boxUnitId = 'su-box';

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

Map<String, dynamic> _product({
  required String id,
  required String name,
  required String barcode,
  required String price,
  required String quantity,
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'barcode': barcode,
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

Map<String, dynamic> _unit({
  required String productId,
  required String id,
  required String name,
  required String multiplier,
  required String sellingPrice,
  required String availableSelling,
  required String availableBase,
  required bool isBaseUnit,
}) => <String, dynamic>{
  'id': id,
  'product_id': productId,
  'name': name,
  'unit_type': 'piece',
  'multiplier': multiplier,
  'barcode': null,
  'selling_price': sellingPrice,
  'is_base_unit': isBaseUnit,
  'is_archived': false,
  'available_base_qty': availableBase,
  'available_selling_qty': availableSelling,
  'effective_price': sellingPrice,
};

/// Base piece + ONE additional unit per product — every scanned product
/// opens the picker, and each picker's option 2 is its own extra unit.
final List<Map<String, dynamic>> _p1Units = <Map<String, dynamic>>[
  _unit(
    productId: _p1Id,
    id: 'su-base-1',
    name: 'Piece',
    multiplier: '1',
    sellingPrice: '10',
    availableSelling: '20',
    availableBase: '20',
    isBaseUnit: true,
  ),
  _unit(
    productId: _p1Id,
    id: _boxUnitId,
    name: 'Box',
    multiplier: '10',
    sellingPrice: '550',
    availableSelling: '2',
    availableBase: '200',
    isBaseUnit: false,
  ),
];

final List<Map<String, dynamic>> _p2Units = <Map<String, dynamic>>[
  _unit(
    productId: _p2Id,
    id: 'su-base-2',
    name: 'Bottle',
    multiplier: '1',
    sellingPrice: '20',
    availableSelling: '50',
    availableBase: '50',
    isBaseUnit: true,
  ),
  _unit(
    productId: _p2Id,
    id: 'su-crate',
    name: 'Crate',
    multiplier: '12',
    sellingPrice: '220',
    availableSelling: '4',
    availableBase: '600',
    isBaseUnit: false,
  ),
];

Map<String, dynamic> _productFor(String id) => id == _p1Id
    ? _product(
        id: _p1Id,
        name: 'Bread',
        barcode: _p1Barcode,
        price: '10.0',
        quantity: '20',
      )
    : _product(
        id: _p2Id,
        name: 'Milk',
        barcode: _p2Barcode,
        price: '20.0',
        quantity: '50',
      );

Map<String, dynamic> _lookupHitFor(String id) {
  final product = _productFor(id);
  return <String, dynamic>{
    'found': true,
    'kind': 'product',
    'product_id': id,
    'product_name': product['name'],
    'product_price': product['price'],
    'product_quantity': product['quantity'],
    'product_unit': 'piece',
    'variant_id': null,
    'selling_unit_id': null,
    'is_archived': false,
  };
}

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
  requestOptions: RequestOptions(path: path),
  statusCode: 200,
  data: data,
);

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
        'items': <dynamic>[
          _productFor(_p1Id),
          _productFor(_p2Id),
        ],
        'total': 2,
      };
    }
    if (path == _favoritesPath) {
      return <String, dynamic>{'items': <dynamic>[], 'total': 0};
    }
    if (path == '/api/v1/products/barcode-lookup') {
      return barcode == _p2Barcode
          ? _lookupHitFor(_p2Id)
          : _lookupHitFor(_p1Id);
    }
    if (path.endsWith('/variants')) {
      return <String, dynamic>{'items': <dynamic>[], 'total': 0};
    }
    if (path.endsWith('/selling-units')) {
      // /api/v1/products/{id}/selling-units
      final id = path.split('/')[4];
      final units = id == _p2Id ? _p2Units : _p1Units;
      return <String, dynamic>{
        'items': units,
        'total': units.length,
      };
    }
    if (path.startsWith('$_catalogPath/') && path != _catalogPath) {
      // /api/v1/products/{id} — segment 4 is the product id.
      return _productFor(path.split('/')[4]);
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

/// Scan [barcode] through the real gateway key pipeline so the product's
/// selling-unit picker opens.
Future<void> _wedgeScanToPicker(WidgetTester tester, String barcode) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.byKey(const Key('pos-search-field')));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 100));
  await sendWedgeScan(tester, barcode);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('selling-unit-picker')),
    findsOneWidget,
    reason: 'the product has an additional selling unit → picker opens',
  );
}

/// Choose option 2 (the extra unit) so the quantity dialog opens.
Future<void> _openQuantityOnBox(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('selling-unit-$_boxUnitId')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
}

/// Delivers one digit the way the real engine does when a wedge burst
/// arrives in a focused text field: the key event goes through the
/// framework first, and whatever the framework leaves unhandled lands in
/// the field through the text-input connection (one character per key).
/// Returns whether the framework consumed the key itself.
Future<bool> _deliverDigit(WidgetTester tester, String character) async {
  final editable = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(const Key('quantity-input')),
      matching: find.byType(EditableText),
    ),
  );
  final handled = await tester.sendKeyEvent(digitKey(character));
  if (!handled) {
    final text = editable.controller.text + character;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
  }
  return handled;
}

/// Delivers Enter the way the real engine does: the key event first, and
/// — when nothing in the framework consumed it — the field's submit
/// action. Returns whether the framework consumed the key itself.
Future<bool> _deliverEnter(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  if (!handled) {
    await tester.testTextInput.receiveAction(TextInputAction.done);
  }
  await tester.pumpAndSettle();
  return handled;
}

/// Subscribes a scan-diagnostics recorder and returns its event list.
List<Map<String, Object?>> _recordScanDiag() {
  final events = <Map<String, Object?>>[];
  void listener(String event, Map<String, Object?> fields) {
    events.add(<String, Object?>{'event': event, ...fields});
  }

  addScanDiagListener(listener);
  addTearDown(() => removeScanDiagListener(listener));
  return events;
}

bool _hasDispatch(List<Map<String, Object?>> events) =>
    events.any((event) => event['event'] == 'dispatch');

bool _hasSuspendedDrop(List<Map<String, Object?>> events) => events.any(
  (event) =>
      event['event'] == 'dispatch-drop' &&
      event['reason'] == 'scanner-suspended',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    BarcodeScannerGateway.instance.resetForTest();
  });

  testWidgets('A — a wedge burst in the selling-unit picker changes nothing '
      'and is never dispatched', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);

    final events = _recordScanDiag();
    await sendWedgeScan(tester, _p1Barcode);
    await tester.pumpAndSettle();

    // The burst's digit 1 used to fire the picker's 1–9 shortcut and
    // confirm the default unit; its Enter used to ride along. Nothing of
    // it may reach the dialog.
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(_hasDispatch(events), isFalse, reason: 'no dispatch, ever');
    expect(_hasSuspendedDrop(events), isTrue, reason: 'explicit drop');
    expect(tester.takeException(), isNull);
  });

  testWidgets('B — scanner digits never reach the picker 1–9 shortcut; '
      'arrows and Enter still select a unit manually', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);

    // Option 2's scanner key is CONSUMED at the gateway boundary — the
    // dialog's focus tree never sees it (pre-fix this opened the
    // quantity dialog on the default unit).
    final digitHandled = await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();
    expect(digitHandled, isTrue, reason: 'gateway consumed the scanner digit');
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);

    // Manual keyboard selection is untouched: arrows move, Enter
    // confirms option 2 (Box) on the 2-column layout.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quantity-unit-name'))).data,
      contains('Box'),
    );
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C — a wedge burst in the quantity field is restored and its '
      'Enter never submits the dialog', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);
    await _openQuantityOnBox(tester);

    // The human has typed quantity 2 — the field's state before the
    // burst arrives.
    await tester.enterText(find.byKey(const Key('quantity-input')), '2');
    await tester.pump();

    final events = _recordScanDiag();
    // The burst transits the focused field (a suspension pass-through
    // run): every digit the framework leaves unhandled is delivered as
    // text by the engine — exactly what a real device does.
    for (final digit in _p1Barcode.split('')) {
      await _deliverDigit(tester, digit);
    }
    final enterHandled = await _deliverEnter(tester);

    // The terminator recognized the run, restored the snapshot and
    // swallowed its own Enter — the dialog neither submitted nor
    // validated a scanner-shaped quantity.
    expect(enterHandled, isTrue, reason: 'gateway consumed the terminator');
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('quantity-input')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, '2', reason: 'field restored');
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(find.byKey(const Key('quantity-error')), findsNothing);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(_hasDispatch(events), isFalse);
    expect(_hasSuspendedDrop(events), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D — manual quantity typing and Enter submit still work while '
      'the scanner is suspended', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);
    await _openQuantityOnBox(tester);

    await tester.enterText(find.byKey(const Key('quantity-input')), '2');
    await tester.pump();
    // Enter with an EMPTY scan buffer is ordinary typing-submit: the
    // engine's done action reaches the dialog exactly as before.
    final submitted = await _deliverEnter(tester);

    expect(submitted, isFalse, reason: 'nothing consumed a human Enter');
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    final cart = container.read(posCartProvider);
    expect(cart.lines, hasLength(1));
    expect(cart.lines.last.quantity, '2');
    expect(cart.lines.last.sellingUnitId, _boxUnitId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('E — cancellation keeps the picker suspended; nothing is '
      'queued; the scanner works again once the last dialog is gone', (
    tester,
  ) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);
    await _openQuantityOnBox(tester);

    // Cancel back to the PICKER: the parent dialog is still open, so the
    // suspension — and the protection — must still be active.
    await tester.tap(find.byKey(const Key('quantity-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    await sendWedgeScan(tester, _p1Barcode);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);

    // The raw external entry point is gated too — a burst can never be
    // dispatched into the dialog, and nothing is buffered for later.
    final rawDropped = BarcodeScannerGateway.instance
        .dispatchExternalScan('999999');
    expect(rawDropped, isFalse);
    expect(BarcodeScannerGateway.instance.bufferedDigitCount, 0);

    // Close the picker: the LAST token releases the suspension.
    await tester.tap(find.byKey(const Key('pos-option-picker-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
    expect(BarcodeScannerGateway.instance.suspensionCount, 0);

    // The scanner is armed again — the next burst dispatches normally.
    await _wedgeScanToPicker(tester, _p2Barcode);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('gateway manual-digit exemption (suspension)', () {
    test('a main-row scanner digit is consumed; a numpad digit passes '
        'through with an untouched buffer', () {
      final gateway = BarcodeScannerGateway.instance;
      gateway.resetForTest();
      addTearDown(gateway.resetForTest);

      // Main-row digit (the scanner's own key shape): consumed at the
      // gateway — it can never reach a dialog shortcut.
      final scannerToken = Object();
      gateway.suspendScans(scannerToken);
      expect(gateway.handleKeyForTest(wedgeKeyDown('2')), isTrue);
      expect(gateway.bufferedDigitCount, 1, reason: 'a run started');
      gateway.resumeScans(scannerToken);

      // Numpad digit (the cashier's number key — scanners emit the main
      // row only): passes through, never starts a scanner run.
      final manualToken = Object();
      gateway.suspendScans(manualToken);
      expect(
        gateway.handleKeyForTest(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.numpad2,
            logicalKey: LogicalKeyboardKey.numpad2,
            timeStamp: Duration.zero,
            character: '2',
          ),
        ),
        isFalse,
        reason: 'the picker 1–9 shortcut receives it',
      );
      expect(gateway.bufferedDigitCount, 0, reason: 'no run, nothing to restore');
      gateway.resumeScans(manualToken);
      expect(gateway.suspensionCount, 0);
    });

    testWidgets('an AZERTY human digit (Shift held, ASCII digit character) '
        'passes through; the same key unshifted stays consumed', (
      tester,
    ) async {
      final gateway = BarcodeScannerGateway.instance;
      gateway.resetForTest();
      addTearDown(gateway.resetForTest);
      final token = Object();
      gateway.suspendScans(token);
      addTearDown(() => gateway.resumeScans(token));

      // AZERTY human layer: `Shift+2` delivers the character `2`. A
      // scanner never sends Shift → provably manual.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(
        gateway.handleKeyForTest(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.digit2,
            logicalKey: LogicalKeyboardKey.digit2,
            timeStamp: Duration.zero,
            character: '2',
          ),
        ),
        isFalse,
      );
      expect(gateway.bufferedDigitCount, 0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      // The SAME physical key unshifted is the scanner's shape —
      // consumed, exactly as before.
      gateway.resumeScans(token);
      gateway.suspendScans(token);
      expect(gateway.handleKeyForTest(wedgeKeyDown('2')), isTrue);
    });
  });

  testWidgets('F — manual number-key selection (numpad) picks the unit and '
      'completes the sale', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);

    // Option 2 by number key — the dialog's own shortcut receives it.
    // NumLock delivers the digit CHARACTER (`2`), the real-device shape.
    final handled = await tester.sendKeyEvent(
      LogicalKeyboardKey.numpad2,
      character: '2',
    );
    await tester.pumpAndSettle();
    expect(handled, isTrue, reason: 'the picker handled its number key');
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quantity-unit-name'))).data,
      contains('Box'),
    );

    await tester.enterText(find.byKey(const Key('quantity-input')), '2');
    await tester.pump();
    await _deliverEnter(tester);

    final cart = container.read(posCartProvider);
    expect(cart.lines, hasLength(1));
    expect(cart.lines.last.quantity, '2');
    expect(cart.lines.last.sellingUnitId, _boxUnitId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('G — a number key beyond the option list does nothing (as '
      'before)', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);

    // The picker shows 2 options (Piece, Box): digit 9 has no option —
    // `_onDigit` ignores it exactly as it always has. The digit
    // CHARACTER travels with the key (NumLock), the scanner-shaped
    // form.
    final handled = await tester.sendKeyEvent(
      LogicalKeyboardKey.numpad9,
      character: '9',
    );
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: 'the picker consumed its number key');
    expect(
      BarcodeScannerGateway.instance.bufferedDigitCount,
      0,
      reason: 'no scanner run started — the gateway never claimed it',
    );
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('H — number-key selection works for another product with a '
      'different unit configuration (option 2 and option 1)', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p2Barcode);

    // Second option (Crate) by number key (NumLock digit character).
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2, character: '2');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quantity-unit-name'))).data,
      contains('Crate'),
    );

    // Back to the picker — then the FIRST/default option by number key
    // (a manual press may select it; a scanner never may). Option 1 is
    // the synthetic BASE card, whose label the dialog seeds from the
    // product's unit (`piece`).
    await tester.tap(find.byKey(const Key('quantity-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad1, character: '1');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quantity-unit-name'))).data,
      contains('piece'),
    );

    await tester.tap(find.byKey(const Key('quantity-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pos-option-picker-cancel')));
    await tester.pumpAndSettle();
    expect(BarcodeScannerGateway.instance.suspensionCount, 0);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('I — an AZERTY FR-scanner burst (`-` at physical Digit 6) is '
      'ignored completely, while the AZERTY human Shift-digit still selects',
      (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);

    // Put a line on the cart first, so a decrement effect would be
    // observable if the burst leaked into the POS shortcuts.
    await _wedgeScanToPicker(tester, _p1Barcode);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2, character: '2');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('quantity-input')), '2');
    await _deliverEnter(tester);
    expect(container.read(posCartProvider).lines, hasLength(1));

    // Second round: picker open with the line already in the cart.
    await _wedgeScanToPicker(tester, _p1Barcode);
    final events = _recordScanDiag();
    await sendForeignWedgeScan(tester, '666666', characters: <String, String>{
      '6': '-',
    });
    await tester.pumpAndSettle();

    // The FR scanner's `-` digits were captured as scanner tokens and
    // dropped: no dialog action, no dispatch, no decrement of the
    // existing line (its quantity still reads 2, not 1).
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(_hasDispatch(events), isFalse);
    expect(_hasSuspendedDrop(events), isTrue);
    expect(container.read(posCartProvider).lines.last.quantity, '2');

    // The AZERTY HUMAN digit layer: Shift held + main-row Digit 2
    // (character `2`) — a scanner never sends Shift, so this passes
    // through to the picker's number shortcut.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '2');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quantity-unit-name'))).data,
      contains('Box'),
    );
    expect(container.read(posCartProvider).lines, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('J — Escape cancels quantity → picker → closed, releasing the '
      'suspension with no leak', (tester) async {
    final dio = MockDio();
    _stubDio(dio);
    final container = await _pumpApp(tester, dio);
    await _login(tester);
    await _openPos(tester, container);
    await _wedgeScanToPicker(tester, _p1Barcode);
    await _openQuantityOnBox(tester);
    expect(BarcodeScannerGateway.instance.suspensionCount, 2);

    // Escape closes the quantity dialog; the PICKER (and its
    // suspension) remains.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity-dialog')), findsNothing);
    expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    expect(BarcodeScannerGateway.instance.suspensionCount, 1);

    // Escape closes the picker: the last token releases the suspension.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
    expect(BarcodeScannerGateway.instance.suspensionCount, 0);
    expect(container.read(posCartProvider).lines, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
