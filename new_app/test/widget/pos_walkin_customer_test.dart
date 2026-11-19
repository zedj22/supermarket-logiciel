// Walk-in customer switching (F6 picker → "عميل عابر").
//
// The picker's walk-in action pops `null`; the POS must CLEAR the selected
// customer (never merely repaint the name), keep every cart line intact and
// drop `customer_id` from the next checkout payload. Selecting a registered
// customer again must keep working, repeatedly.
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
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
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

const _customersPath = '/api/v1/customers';
const _searchPath = '$_customersPath/search';

const _scopes = <String>[
  'pos_sale',
  'product_view',
  'customer_view',
  'customer_manage',
];

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

Map<String, dynamic> _customerJson(String id, String name) => <String, dynamic>{
      'id': id,
      'name': name,
      'phone': null,
      'address': null,
      'balance': '0.000',
      'debt_ceiling': '0.000',
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, Object> _listBody(List<Map<String, dynamic>> items) =>
    <String, Object>{
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _saleJson() => <String, dynamic>{
      'id': 'sale-1',
      'invoice_number': 'INV-1',
      'status': 'completed',
      'subtotal': '20.000',
      'discount': '3.000',
      'total': '17.000',
      'paid': '17.000',
      'change': '0.000',
      'debt': '0.000',
      'payment_method': 'cash',
    };

/// Captured request bodies (the checkout assertions read this).
class _Api {
  final List<Map<String, dynamic>> salePayloads = <Map<String, dynamic>>[];
}

void _mockDio(MockDio dio, _Api api) {
  Object? bodyFor(String path) {
    if (path == _searchPath) {
      return _listBody([
        _customerJson('c-1', 'Alice Market'),
        _customerJson('c-2', 'Bob Grocery'),
      ]);
    }
    if (path.startsWith('$_customersPath/') && path.endsWith('/loyalty')) {
      return <String, Object>{
        'customer_id': path.split('/')[4],
        'has_account': true,
        'points_balance': '0.000',
        'cashback_balance': '0.000',
        'available_rewards': 0,
        'remaining_points': '0.000',
        'min_reward_points': 100,
      };
    }
    return _listBody(const []);
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });

  Future<Response<dynamic>> postAnswer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final data = invocation.namedArguments[#data];
    if (path == '/api/v1/sales') {
      api.salePayloads.add(Map<String, dynamic>.from((data as Map?) ?? {}));
      return _ok(path, _saleJson());
    }
    return _ok(path, <String, dynamic>{});
  }

  // Checkout sends `data` AND `options` — stub the exact call shape.
  when(
    () => dio.post(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(postAnswer);
  when(() => dio.post(any(), data: any(named: 'data')))
      .thenAnswer(postAnswer);
  when(() => dio.post(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', {}),
  );
  when(() => dio.delete(any())).thenAnswer(
    (_) async => _ok('/deleted', <String, dynamic>{}, status: 204),
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
  required MockDio dio,
  required PosCartNotifier cart,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  tester.view.physicalSize = const Size(1366, 768);
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
        posCartProvider.overrideWith((ref) => cart),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: PosScreen()),
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

PosCartNotifier _cartWithOneLine(MockDio dio) {
  final cart = PosCartNotifier(dio, () => 'en', () async => 'pos-test');
  cart.addLine(const CartLine(
    productId: 'p-1',
    name: 'Bread',
    quantity: '2',
    unitPrice: '10',
    availableStock: '50',
  ));
  cart.setInvoiceDiscount('3');
  return cart;
}

String? _headerCustomerName(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('pos-customer-name'))).data;

Future<void> _openPicker(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f6);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets(
      'walk-in clears the selected customer, keeps the cart and drops '
      'customer_id from the checkout payload', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    final cart = _cartWithOneLine(dio);
    final container = await _pumpPos(tester, dio: dio, cart: cart);

    container.read(posCartProvider.notifier).setCustomer(
          const PosCustomer(id: 'c-1', name: 'Alice Market'),
        );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_headerCustomerName(tester), 'Alice Market');

    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-clear')));
    await tester.pumpAndSettle();

    // The picker closed and the cart really lost the customer id.
    expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
    expect(container.read(posCartProvider).customer, isNull);
    expect(_headerCustomerName(tester),
        AppStrings.t('walk_in_customer', 'en'));

    // Nothing else about the sale changed.
    final state = container.read(posCartProvider);
    expect(state.lines, hasLength(1));
    expect(state.lines.single.quantity, '2');
    expect(state.lines.single.unitPrice, '10');
    expect(state.invoiceDiscount, '3');
    expect(api.salePayloads, isEmpty);

    final future = container
        .read(posCartProvider.notifier)
        .checkout(method: PaymentMethod.cash, paid: 17);
    await tester.pump();
    await future;

    expect(api.salePayloads, hasLength(1));
    expect(api.salePayloads.single.containsKey('customer_id'), isFalse,
        reason: 'a walk-in sale must not carry the previously selected id');
    expect(api.salePayloads.single['items'], hasLength(1));
  });

  testWidgets('switching back and forth keeps working (no customer POST)',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    final cart = _cartWithOneLine(dio);
    final container = await _pumpPos(tester, dio: dio, cart: cart);

    // registered → walk-in
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-row-c-2')));
    await tester.pumpAndSettle();
    expect(container.read(posCartProvider).customer?.id, 'c-2');
    expect(_headerCustomerName(tester), 'Bob Grocery');

    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-clear')));
    await tester.pumpAndSettle();
    expect(container.read(posCartProvider).customer, isNull);

    // walk-in → ANOTHER registered customer: normal selection still works.
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-row-c-1')));
    await tester.pumpAndSettle();
    expect(container.read(posCartProvider).customer?.id, 'c-1');
    expect(_headerCustomerName(tester), 'Alice Market');

    // …and back to walk-in once more.
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-clear')));
    await tester.pumpAndSettle();
    expect(container.read(posCartProvider).customer, isNull);
    expect(_headerCustomerName(tester),
        AppStrings.t('walk_in_customer', 'en'));

    // A walk-in switch creates no customer record and touches no line.
    expect(api.salePayloads, isEmpty);
    expect(container.read(posCartProvider).lines, hasLength(1));
    expect(container.read(posCartProvider).invoiceDiscount, '3');
    expect(tester.takeException(), isNull);
  });
}
