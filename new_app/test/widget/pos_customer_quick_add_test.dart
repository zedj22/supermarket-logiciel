// POS customer picker — quick-add customer contract.
//
// - an "Add new customer" button sits under the picker's search field
//   (it is also the empty-results affordance), gated by customer_manage —
//   the same permission as the Clients page's add button;
// - the button opens the SHARED client form (client-form-dialog): one
//   customer-management implementation, one POST /api/v1/customers;
// - success closes the form, refreshes the picker's list (search +
//   customers GETs AFTER the POST) and selects the created customer for
//   the sale while the cart — lines, quantities, line + invoice
//   discounts — survives untouched;
// - a validation error or an API failure keeps the form open with the
//   localized message and selects NOTHING;
// - while saving the submit button is disabled: exactly one POST;
// - the pre-existing pick-existing-customer flow is unchanged.
// - every picker close (existing pick, quick-add success, walk-in/cancel,
//   loyalty multi-match) hands primary focus back to the POS search field,
//   so the next keyboard-wedge burst is armed and lands in the cart —
//   the regression cover for the lost post-picker focus.
import 'dart:async';
import 'dart:typed_data';

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
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
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
  Future<List<String>> readUserRoles() async => ['cashier'];

  @override
  Future<List<String>> readUserPermissions() async => const [
    'pos_sale',
    'customer_view',
  ];

  @override
  Future<void> clearAll() async {}
}

class _FakePdfPreview implements PdfPreviewBuilder {
  @override
  Widget build(Uint8List bytes, {required String paper, String? filename}) =>
      Text('pdf:${bytes.length}:$paper');
}

const _loginPath = '/api/v1/auth/login';
const _customersPath = '/api/v1/customers';
const _searchPath = '$_customersPath/search';
const _catalogPath = '/api/v1/products';
const _productId = '00000000-0000-0000-0000-0000000000p1';
const _productDetailPath = '$_catalogPath/$_productId';
const _barcodeLookupPath = '$_catalogPath/barcode-lookup';
const _loyaltyLookupPath = '/api/v1/loyalty/lookup';

/// A dispatchable wedge code: the gateway only dispatches a digit run of
/// barcode length (`^\d{6,}$`), so the product's own 3-digit barcode can
/// never drive [sendWedgeScan].
const _scanCode = '6134881000614';

const _scopes = <String>[
  'pos_sale',
  'pos_discount',
  'product_view',
  'customer_view',
  'customer_manage',
];

Map<String, dynamic> _customerJson({
  String id = 'c-new',
  String name = 'Fresh Customer',
  String? phone,
  String balance = '0.000',
  String ceiling = '0.000',
}) => {
  'id': id,
  'name': name,
  'phone': phone,
  'address': null,
  'balance': balance,
  'debt_ceiling': ceiling,
  'is_archived': false,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _product() => {
  'id': _productId,
  'name': 'Bread',
  'barcode': '111',
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

/// Canonical barcode-lookup hit resolving [_scanCode] to [_product()] —
/// the first hop of the wedge scan flow (`GET /barcode-lookup?barcode=`).
Map<String, dynamic> _lookupHit() => {
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

Map<String, dynamic> _listBody(List<Map<String, dynamic>> items) => {
  'items': items,
  'total': items.length,
  'page': 1,
  'page_size': 40,
  'pages': 1,
};

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

DioException _createFailed() => DioException(
  requestOptions: RequestOptions(path: _customersPath),
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: _customersPath),
    statusCode: 400,
    data: {
      'error': {
        'code': 'VALIDATION_ERROR',
        'message': 'A customer with this phone already exists',
        'details': <String, dynamic>{},
      },
    },
  ),
);

class _Api {
  final List<String> events = <String>[]; // 'GET /path' / 'POST /path'
  final List<Map<String, dynamic>> customerPosts = <Map<String, dynamic>>[];
}

/// One catch-all stub per verb; every call is appended to [api.events] in
/// invocation order so tests can assert refreshes happened AFTER the
/// create POST. [barcodeLookups] answers the wedge scan's canonical
/// resolve by scanned code; [loyaltyLookupItems] is the multi-match
/// payload for `KLICK:C:` submits.
void _stubApi(
  MockDio dio, {
  required _Api api,
  List<Map<String, dynamic>> searchItems = const [],
  DioException? customerCreateError,
  Completer<Response<dynamic>>? customerCreateGate,
  Map<String, Map<String, dynamic>> barcodeLookups = const {},
  List<Map<String, dynamic>> loyaltyLookupItems = const [],
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  String? barcodeOf(Invocation invocation) {
    final params = invocation.namedArguments[#queryParameters];
    return params is Map ? params['barcode'] as String? : null;
  }

  Object? bodyFor(String path, {String? barcode}) {
    if (path == _barcodeLookupPath) {
      return barcodeLookups[barcode] ??
          const <String, dynamic>{'found': false};
    }
    // Scan triage: empty choice lists → no picker → direct add.
    if (path.endsWith('/variants') || path.endsWith('/selling-units')) {
      return _listBody(const []);
    }
    // Product detail — what _resolveAndAddBarcode re-fetches for a hit.
    if (path == _productDetailPath) return _product();
    if (path == _catalogPath) {
      return {
        'items': [_product()],
        'total': 1,
      };
    }
    if (path == _searchPath) return _listBody(searchItems);
    if (path == _customersPath) return _listBody(searchItems);
    if (path == _loyaltyLookupPath) return {'items': loyaltyLookupItems};
    // Loyalty session follows the attached customer — tolerant models.
    if (path.endsWith('/loyalty')) return <String, dynamic>{};
    // favorites / holds / sales / settings …
    return _listBody(const []);
  }

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('GET $path');
    return _ok(path, bodyFor(path, barcode: barcodeOf(invocation)));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('GET $path');
    return _ok(path, bodyFor(path));
  });

  Future<Response<dynamic>> postAnswer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('POST $path');
    final data = invocation.namedArguments[#data];
    if (path == _customersPath) {
      final payload = Map<String, dynamic>.from(data as Map);
      api.customerPosts.add(payload);
      if (customerCreateGate != null) return customerCreateGate.future;
      if (customerCreateError != null) throw customerCreateError;
      return _ok(
        path,
        _customerJson(
          name: '${payload['name']}',
          phone: payload['phone'] as String?,
        ),
        status: 201,
      );
    }
    if (path == _loginPath) return _ok(path, <String, dynamic>{});
    return _ok(path, <String, dynamic>{});
  }

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(postAnswer);
  when(() => dio.post(any())).thenAnswer(postAnswer);
  when(
    () => dio.delete(any()),
  ).thenAnswer((_) async => _ok(_customersPath, <String, dynamic>{}));
}

AuthUser _user(List<String> scopes) => AuthUser(
  id: '00000000-0000-0000-0000-0000000000b1',
  fullName: 'Cashier',
  isActive: true,
  roles: const ['cashier'],
  permissions: scopes,
);

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  List<String> permissions = _scopes,
  AppLocale locale = AppLocale.en,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user(permissions)),
        localeProvider.overrideWith(
          (ref) => LocaleNotifier()..setLocale(locale),
        ),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        posSettingsProvider.overrideWith((ref) => PosSettingsNotifier(prefs)),
        pdfPreviewProvider.overrideWithValue(_FakePdfPreview()),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: PosScreen()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pos-select-customer')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
}

/// The key of the TextField (if any) currently owning primary focus — the
/// local helper pos_screen_test.dart keeps for its focus assertions.
String? focusedFieldKey(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final field = context.widget is TextField
      ? context.widget as TextField
      : context.findAncestorWidgetOfExactType<TextField>();
  final key = field?.key;
  return key is ValueKey<String> ? key.value : null;
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byKey(const Key('pos-screen'))),
      listen: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets('picker exposes "Add new customer" (permission-gated) and opens '
      'the shared client form', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _stubApi(dio, api: api);

    await _pumpApp(tester, dio: dio);
    await _openPicker(tester);

    // Empty results + the button together are the empty-state affordance.
    expect(find.byKey(const Key('customer-quick-add')), findsOneWidget);
    expect(find.text(AppStrings.t('quick_add_customer', 'en')), findsOneWidget);
    expect(find.text(AppStrings.t('no_customers_found', 'en')), findsOneWidget);

    await tester.tap(find.byKey(const Key('customer-quick-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);
    expect(find.byKey(const Key('client-name-field')), findsOneWidget);
    // Nothing was created by opening the form.
    expect(api.customerPosts, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
    'quick-add button is hidden without customer_manage (picker still '
    'searchable)',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(dio, api: api);

      await _pumpApp(
        tester,
        dio: dio,
        permissions: const ['pos_sale', 'product_view', 'customer_view'],
      );
      await _openPicker(tester);

      expect(find.byKey(const Key('customer-quick-add')), findsNothing);
      expect(find.byKey(const Key('customer-search-input')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets('validation: empty name / malformed ceiling block the create (no '
      'POST, both dialogs stay open)', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _stubApi(dio, api: api);

    await _pumpApp(tester, dio: dio);
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('customer-quick-add')));
    await tester.pumpAndSettle();

    // Empty name → field_required.
    await tester.tap(find.byKey(const Key('client-form-submit')));
    await tester.pump();
    expect(find.text(AppStrings.t('field_required', 'en')), findsOneWidget);
    expect(api.customerPosts, isEmpty);

    // Malformed credit ceiling → invalid_amount.
    await tester.ensureVisible(find.byKey(const Key('client-name-field')));
    await tester.enterText(find.byKey(const Key('client-name-field')), 'X');
    await tester.ensureVisible(find.byKey(const Key('client-ceiling-field')));
    await tester.enterText(
      find.byKey(const Key('client-ceiling-field')),
      '1.2.3',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('client-form-submit')));
    await tester.pump();
    expect(find.text(AppStrings.t('invalid_amount', 'en')), findsOneWidget);
    expect(api.customerPosts, isEmpty);

    // Neither dialog closed: nothing selected.
    expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);
    expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
    'success: creates the customer, refreshes the list, selects it for '
    'the sale and preserves the cart',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(dio, api: api);

      await _pumpApp(tester, dio: dio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier)
        ..addLine(
          const CartLine(
            productId: 'p1',
            name: 'Bread',
            quantity: '2',
            unitPrice: '10',
            lineDiscount: '5',
          ),
        )
        ..setInvoiceDiscount('3');
      await tester.pump();

      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-quick-add')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('client-name-field')));
      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'Fresh Customer',
      );
      await tester.ensureVisible(find.byKey(const Key('client-phone-field')));
      await tester.enterText(
        find.byKey(const Key('client-phone-field')),
        '0555123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pumpAndSettle();

      // Form + picker closed; the sale shows the new customer.
      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(find.byKey(const Key('pos-customer-name')), findsOneWidget);
      expect(find.text('Fresh Customer'), findsOneWidget);

      // The shared form's payload — no balance, ceiling default.
      expect(api.customerPosts, hasLength(1));
      expect(api.customerPosts.single['name'], 'Fresh Customer');
      expect(api.customerPosts.single['phone'], '0555123456');
      expect(api.customerPosts.single['debt_ceiling'], '0');
      expect(api.customerPosts.single.containsKey('balance'), isFalse);

      // The picker's list was refreshed AFTER the create.
      final postAt = api.events.indexOf('POST $_customersPath');
      expect(postAt, greaterThan(-1));
      final afterCreate = api.events.sublist(postAt + 1);
      expect(
        afterCreate.where(
          (e) => e == 'GET $_searchPath' || e == 'GET $_customersPath',
        ),
        isNotEmpty,
        reason: 'expected a search/customers refresh after the create POST',
      );

      // Cart, quantities, discounts and payment state untouched.
      final cart = container.read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '2');
      expect(cart.lines.single.lineDiscount, '5');
      expect(cart.invoiceDiscount, '3');
      expect(cart.checkoutPending, isFalse);
      expect(cart.customer?.id, 'c-new');
      expect(cart.customer?.name, 'Fresh Customer');

      expect(
        find.byKey(const Key('client-form-success-toast')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'API failure: localized error stays in the form, picker stays open, '
    'nothing is selected',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(dio, api: api, customerCreateError: _createFailed());

      await _pumpApp(tester, dio: dio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );

      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-quick-add')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('client-name-field')));
      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'Broken Customer',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pumpAndSettle();

      // The POST went out and failed; the form surfaces BOTH lines.
      expect(api.customerPosts, hasLength(1));
      expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('validation_error', 'en')), findsOneWidget);
      expect(
        find.text('A customer with this phone already exists'),
        findsOneWidget,
      );

      // The picker is still open and the sale selected NOTHING.
      expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
      expect(container.read(posCartProvider).customer, isNull);
      // The picker's own walk-in ACTION carries the same text — assert
      // the cart row specifically.
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-customer-name'))).data,
        AppStrings.t('walk_in_customer', 'en'),
      );

      // The submit button re-arms for a retry.
      final submit = tester.widget<ElevatedButton>(
        find.byKey(const Key('client-form-submit')),
      );
      expect(submit.onPressed, isNotNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'duplicate submissions are blocked while saving (exactly one POST)',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      final gate = Completer<Response<dynamic>>();
      _stubApi(dio, api: api, customerCreateGate: gate);

      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-quick-add')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('client-name-field')));
      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'Once Only',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pump();

      // Saving: the button is disabled and a second tap is a no-op.
      final saving = tester.widget<ElevatedButton>(
        find.byKey(const Key('client-form-submit')),
      );
      expect(saving.onPressed, isNull);
      expect(api.customerPosts, hasLength(1));
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pump();
      expect(api.customerPosts, hasLength(1));

      gate.complete(
        _ok(_customersPath, _customerJson(name: 'Once Only'), status: 201),
      );
      await tester.pumpAndSettle();

      expect(api.customerPosts, hasLength(1));
      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(find.text('Once Only'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'existing flow unchanged: picking a result selects it with no POST',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(
        dio,
        api: api,
        searchItems: [_customerJson(id: 'c1', name: 'Alice Market')],
      );

      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);

      await tester.tap(find.byKey(const Key('customer-row-c1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(find.text('Alice Market'), findsOneWidget);
      expect(api.customerPosts, isEmpty);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'focus: picking an existing customer hands focus back to the POS search '
    'field and the next wedge scan adds the product once',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(
        dio,
        api: api,
        searchItems: [_customerJson(id: 'c1', name: 'Alice Market')],
        barcodeLookups: {_scanCode: _lookupHit()},
      );

      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-row-c1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'the picker must hand primary focus back to the search field',
      );

      await sendWedgeScan(tester, _scanCode);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.productId, _productId);
      expect(cart.lines.single.quantity, '1');
      expect(cart.customer?.id, 'c1');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'focus: quick-add success restores search focus and the cart survives '
    'the next scan untouched',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(dio, api: api, barcodeLookups: {_scanCode: _lookupHit()});

      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier)
        ..addLine(
          const CartLine(
            productId: 'p1',
            name: 'Bread',
            quantity: '2',
            unitPrice: '10',
            lineDiscount: '5',
          ),
        )
        ..setInvoiceDiscount('3');
      await tester.pump();

      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-quick-add')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('client-name-field')));
      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'Fresh Customer',
      );
      await tester.ensureVisible(find.byKey(const Key('client-phone-field')));
      await tester.enterText(
        find.byKey(const Key('client-phone-field')),
        '0555123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pumpAndSettle();

      // Form + picker closed and focus back on the search field.
      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await sendWedgeScan(tester, _scanCode);
      await tester.pumpAndSettle();

      // The scan added ONE new line; the pre-existing line, its discount,
      // the invoice discount and the checkout state are untouched.
      final cart = container.read(posCartProvider);
      expect(cart.lines, hasLength(2));
      final original = cart.lines.firstWhere((l) => l.productId == 'p1');
      expect(original.quantity, '2');
      expect(original.lineDiscount, '5');
      final scanned = cart.lines.singleWhere((l) => l.productId == _productId);
      expect(scanned.quantity, '1');
      expect(cart.invoiceDiscount, '3');
      expect(cart.checkoutPending, isFalse);
      expect(cart.customer?.name, 'Fresh Customer');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'focus: cancelling the picker (walk-in) also restores search focus',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      _stubApi(dio, api: api, barcodeLookups: {_scanCode: _lookupHit()});

      await _pumpApp(tester, dio: dio);
      await _openPicker(tester);
      await tester.tap(find.byKey(const Key('customer-clear')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await sendWedgeScan(tester, _scanCode);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.customer, isNull);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  testWidgets(
    'focus: loyalty QR multi-match picks through the picker and restores '
    'search focus for the next scan',
    (tester) async {
      final dio = MockDio();
      final api = _Api();
      final loyal = [
        _customerJson(id: 'l1', name: 'Loyal One'),
        _customerJson(id: 'l2', name: 'Loyal Two'),
      ];
      _stubApi(
        dio,
        api: api,
        searchItems: loyal,
        loyaltyLookupItems: loyal,
        barcodeLookups: {_scanCode: _lookupHit()},
      );

      await _pumpApp(tester, dio: dio);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'KLICK:C:0001',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Two matches → the picker opens (rows from the picker's own list).
      expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('customer-row-l2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await sendWedgeScan(tester, _scanCode);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.customer?.id, 'l2');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    },
  );
}
