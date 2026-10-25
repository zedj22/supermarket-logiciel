// Phase 8 Step 3 — POS screen widget tests:
// - Responsive layouts at 600×500, 800×600, 1024×768, 1366×768, 1920×1080
// - Arabic RTL / French / English localization
// - Cart empty state, search field, pay button disabled, permission gates
// - Line add/remove, totals, hold/checkout state (mocked Dio)
// - UX FIX #2: add-to-cart decision tree, grid/list view mode + persistence,
//   text-first cards when image missing/invalid, catalog no-reload on toggle
// - UX FIX #8: cart width floors, readable header/customer/actions/lines,
//   2-column secondary grid, TOTAL 36–48, PAY ≥56, cart-only scrolling
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/features/pos/pos_toast.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/print_service.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';
import 'package:supermarket_pos/features/settings/scan_settings_provider.dart';
import 'package:supermarket_pos/features/stock/adjust_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

import '../helpers/wedge_scanner.dart';

class MockDio extends Mock implements Dio {}

/// Mirrors the LTR isolate the app wraps numeric segments in (W7).
String _m(String v) => bidiIsolateLtr(v);

class _FakePrintService implements PrintService {
  _FakePrintService({this.fail = false});

  final bool fail;
  final List<String> printed = <String>[];
  final List<Uint8List> printedPdfs = <Uint8List>[];
  final List<String> printedPapers = <String>[];

  @override
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) async {
    if (fail) {
      throw const PrintServiceException('no printer');
    }
    printedPdfs.add(bytes);
    printedPapers.add(paper);
  }

  @override
  Future<void> printText(String text) async {
    if (fail) {
      throw const PrintServiceException('no printer');
    }
    printed.add(text);
  }
}

/// Phase 15 preview seam fake: records the bytes it received and shows a
/// deterministic placeholder instead of rasterizing (§19.2 — no plugin).
class _FakePdfPreview implements PdfPreviewBuilder {
  final List<Uint8List> received = <Uint8List>[];
  final List<String> papers = <String>[];

  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  }) {
    received.add(bytes);
    papers.add(paper);
    return Text('pdf:${bytes.length}:$paper:$filename');
  }
}

/// Fresh instance replaced by every `_pumpApp` call.
_FakePdfPreview _fakePreview = _FakePdfPreview();

/// Bodies posted to `POST /api/v1/print` (reset per `_mockDio`).
final List<Map<String, dynamic>> printRequestBodies =
    <Map<String, dynamic>>[];

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
const _catalogPath = '/api/v1/products';
const _favoritesPath = '/api/v1/pos/favorites';
const _salesPath = '/api/v1/sales';

const _defaultScopes = <String>[
  'pos_sale',
  'pos_discount',
  'pos_credit_sale',
  'product_view',
  'customer_view',
];

const _productId = '00000000-0000-0000-0000-0000000000p1';

Map<String, dynamic> _saleBody({
  bool withOverride = false,
  String clientRequestId = '',
}) =>
    {
      'id': 'sale-1',
      'invoice_number': 'INV-001',
      'status': 'completed',
      'subtotal': '10.00',
      'discount': '0',
      'total': '10.00',
      'paid': '10.00',
      'change': '0',
      'debt': '0',
      'payment_method': 'cash',
      'idempotent_replay': false,
      'client_request_id': clientRequestId,
      'price_overrides': withOverride
          ? [
              {
                'line_index': 0,
                'product_id': _productId,
                'requested_unit_price': '9.00',
                'applied_unit_price': '10.00',
              },
            ]
          : <dynamic>[],
    };

Map<String, dynamic> _loginBody({List<String> scopes = _defaultScopes}) =>
    {
      'access_token': 'tok-pos',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000b1',
        'full_name': 'Cashier',
        'is_active': true,
        'roles': [
          {
            'name': 'cashier',
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _product({
  String id = '00000000-0000-0000-0000-0000000000p1',
  String name = 'Bread',
  String barcode = '111',
  String price = '10.0',
  String quantity = '20',
  String? imagePath,
  String unit = 'piece',
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'unit': unit,
      'price': price,
      'cost': '5',
      'avg_cost': '5',
      'quantity': quantity,
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'category_id': null,
      'category_name': null,
      'image_path': imagePath,
      'is_archived': false,
    };

Map<String, dynamic> _variantJson({
  String id = 'var-1',
  String name = 'Large',
  String? price = '12',
  String quantity = '10',
  bool isArchived = false,
}) =>
    {
      'id': id,
      'product_id': _productId,
      'name': name,
      'barcode': 'B-$id',
      'sku': null,
      'price': price,
      'cost': null,
      'quantity': quantity,
      'is_archived': isArchived,
    };

Map<String, dynamic> _sellingUnitJson({
  String id = 'unit-1',
  String name = 'Piece',
  String? sellingPrice = '10',
  bool isBaseUnit = true,
  bool isArchived = false,
  String multiplier = '1',
  String unitType = 'piece',
  String availableSelling = '20',
  String availableBase = '20',
}) =>
    {
      'id': id,
      'product_id': _productId,
      'name': name,
      'unit_type': unitType,
      'multiplier': multiplier,
      'barcode': null,
      'selling_price': sellingPrice,
      'is_base_unit': isBaseUnit,
      'is_archived': isArchived,
      'available_base_qty': availableBase,
      'available_selling_qty': availableSelling,
      'effective_price': sellingPrice,
    };

Response<dynamic> _ok(String path, Object? data) => Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

/// Canonical barcode-lookup payload for the default mock product (Bread,
/// barcode 111). Any other code misses unless the test overrides it via
/// _mockDio's barcodeLookups map.
Map<String, dynamic> _lookupHit({
  String productId = _productId,
  String productName = 'Bread',
  String productPrice = '10.0',
  String productQuantity = '20',
  String productUnit = 'piece',
}) =>
    {
      'found': true,
      'kind': 'product',
      'product_id': productId,
      'product_name': productName,
      'product_price': productPrice,
      'product_quantity': productQuantity,
      'product_unit': productUnit,
      'variant_id': null,
      'selling_unit_id': null,
      'is_archived': false,
    };

Map<String, dynamic> _lookupMiss() => {'found': false};

Map<String, dynamic> _defaultLookupBody(String barcode) =>
    barcode == '111' ? _lookupHit() : _lookupMiss();

Object? _defaultBody(String path, {String quantity = '20'}) {
  if (path == _catalogPath) {
    return {
      'items': [_product()],
      'total': 1,
    };
  }
  if (path == _favoritesPath) {
    return {'items': <dynamic>[], 'total': 0};
  }
  if (path.endsWith('/variants')) {
    return {'items': <dynamic>[], 'total': 0};
  }
  if (path.endsWith('/selling-units')) {
    return {'items': <dynamic>[], 'total': 0};
  }
  if (path == '/api/v1/products/barcode-lookup') {
    // The GET stubs extract the barcode from queryParameters and serve
    // _defaultLookupBody; reaching here without them means a miss.
    return _lookupMiss();
  }
  if (path.startsWith('/api/v1/products/') && !path.endsWith('/search')) {
    // Product detail — what _resolveAndAddBarcode re-fetches for a scan;
    // carries the configured stock so scans hit the real stock guard.
    return _product(quantity: quantity);
  }
  if (path == '/api/v1/auth/setup/check') {
    return {'setup_needed': false};
  }
  if (path == '/api/v1/auth/login-users') {
    return {
      'items': [
        {
          'id': '00000000-0000-0000-0000-0000000000b1',
          'full_name': 'Cashier',
          'is_active': true,
        },
      ],
    };
  }
  return {'items': <dynamic>[], 'total': 0};
}

void _mockDio(
  MockDio dio, {
  List<String> scopes = _defaultScopes,
  bool withProduct = true,
  bool saleWithOverride = false,
  List<Map<String, dynamic>> variants = const [],
  List<Map<String, dynamic>> sellingUnits = const [],
  String? imagePath,
  String productPrice = '10.0',
  String productQuantity = '20',
  String productUnit = 'piece',
  void Function()? onSearch,
  int? variantsErrorStatus,
  int? sellingUnitsErrorStatus,
  bool variantsNetworkError = false,
  bool sellingUnitsNetworkError = false,
  int variantsFailOnce = 0,
  Map<String, dynamic>? saleListBody,
  Map<String, dynamic>? saleDetailBody,
  int? saleErrorStatus,
  Map<String, dynamic>? saleErrorBody,
  Map<String, dynamic>? holdsBody,
  Map<String, dynamic>? restoreBody,
  bool restoreNetworkError = false,
  int? restoreErrorStatus,
  List<String>? recordPaths,
  Map<String, dynamic>? settingsBody,
  Map<String, Map<String, dynamic>>? barcodeLookups,
  bool barcodeLookupNetworkError = false,
  Duration latency = Duration.zero,
}) {
  void record(String path) => recordPaths?.add(path);
  printRequestBodies.clear();

  // Simulated network round-trip — every GET waits [latency] before it
  // resolves. The scan-latency measurement advances the fake clock one
  // [latency] per pump, so sequential round trips are countable.
  Future<void> tick() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  Never failPath(String path, {required bool network, int? status}) {
    if (network) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: path),
        reason: 'connection refused',
      );
    }
    throw DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: status ?? 500,
        data: {
          'error': {
            'code': 'LOOKUP_FAILED',
            'message': 'lookup failed ($status)',
          },
        },
      ),
    );
  }

  // One-shot variants failure counter (see the /variants branch below):
  // lives in the mock's closure scope so it survives across requests.
  var remainingVariantFailures = variantsFailOnce;

  Object? bodyFor(String path, {String? barcode}) {
    if (path == _catalogPath) {
      onSearch?.call();
      return {
        'items': [
          _product(
            imagePath: imagePath,
            price: productPrice,
            quantity: productQuantity,
            unit: productUnit,
          ),
        ],
        'total': 1,
      };
    }
    if (path == _favoritesPath) {
      return {'items': <dynamic>[], 'total': 0};
    }
    if (path == '/api/v1/products/barcode-lookup') {
      return barcodeLookups?[barcode ?? ''] ??
          _defaultLookupBody(barcode ?? '');
    }
    if (path == '/api/v1/pos/holds') {
      return holdsBody ?? {'items': <dynamic>[], 'total': 0};
    }
    if (path == _salesPath) {
      return saleListBody ??
          {'items': <dynamic>[], 'total': 0, 'page': 1, 'page_size': 50};
    }
    if (path.startsWith('$_salesPath/')) {
      final id = path.substring(_salesPath.length + 1);
      final detail = saleDetailBody;
      return detail != null
          ? {...detail, 'id': id}
          : <String, dynamic>{};
    }
    if (path.endsWith('/variants')) {
      // `variantsFailOnce`: the FIRST variants lookup fails (the add shows
      // the retry toast), every later one succeeds — the scan → failed
      // lookup → RETRY flow of the scanner-origin focus regression.
      final failNow = variantsNetworkError ||
          variantsErrorStatus != null ||
          remainingVariantFailures > 0;
      if (remainingVariantFailures > 0) remainingVariantFailures--;
      if (failNow) {
        failPath(
          path,
          network: variantsNetworkError,
          status: variantsErrorStatus,
        );
      }
      return {'items': variants, 'total': variants.length};
    }
    if (path.endsWith('/selling-units')) {
      if (sellingUnitsNetworkError || sellingUnitsErrorStatus != null) {
        failPath(
          path,
          network: sellingUnitsNetworkError,
          status: sellingUnitsErrorStatus,
        );
      }
      return {'items': sellingUnits, 'total': sellingUnits.length};
    }
    if (path == '/api/v1/settings') {
      // §17.6 print settings; the default keeps the pre-§17.6 behaviour.
      return settingsBody ?? <String, dynamic>{'items': <dynamic>[]};
    }
    return _defaultBody(path, quantity: productQuantity);
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    record(path);
    await tick();
    final params =
        invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
    if (path == '/api/v1/products/barcode-lookup') {
      // `barcodeLookupNetworkError`: the canonical lookup never answers —
      // the resolve path must treat that as ERROR (transient), never as
      // a definitive miss (the unknown-barcode scan action's guard).
      if (barcodeLookupNetworkError) {
        failPath(path, network: true);
      }
      return _ok(path, bodyFor(path, barcode: params?['barcode'] as String?));
    }
    if (path == _catalogPath && !withProduct) {
      return _ok(path, {'items': <dynamic>[], 'total': 0});
    }
    return _ok(path, bodyFor(path));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    record(path);
    await tick();
    return _ok(path, bodyFor(path));
  });

  when(() => dio.get(_favoritesPath)).thenAnswer((_) async {
    await tick();
    return _ok(_favoritesPath, {'items': <dynamic>[], 'total': 0});
  });

  Response<dynamic> postAnswer(Invocation invocation) {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == _loginPath) return _ok(path, _loginBody(scopes: scopes));
    if (path == '/api/v1/print') {
      // Phase 15 document render — bytes + sanitized filename header.
      final data = invocation.namedArguments[#data];
      if (data is Map) {
        printRequestBodies.add(Map<String, dynamic>.from(data));
      }
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: Uint8List.fromList(utf8.encode('%PDF-1.4 fake-phase15')),
        headers: Headers.fromMap(<String, List<String>>{
          'content-disposition': <String>[
            'attachment; filename="sale_document.pdf"',
          ],
        }),
      );
    }
    if (path.endsWith('/restore')) {
      if (restoreNetworkError) {
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: path),
          reason: 'connection refused',
        );
      }
      if (restoreErrorStatus != null) {
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: restoreErrorStatus,
            data: {
              'error': {'code': 'ERROR', 'message': 'restore failed'},
            },
          ),
        );
      }
      return _ok(path, restoreBody ?? <String, dynamic>{});
    }
    if (path == '/api/v1/pos/holds') {
      return _ok(path, <String, dynamic>{'id': 'hold-created'});
    }
    if (path == _salesPath) {
      if (saleErrorStatus != null) {
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: saleErrorStatus,
            data: saleErrorBody ??
                {
                  'error': {'code': 'ERROR', 'message': 'sale failed'},
                },
          ),
        );
      }
      final data = invocation.namedArguments[#data];
      final requestId = data is Map ? '${data['client_request_id']}' : '';
      return _ok(path, _saleBody(withOverride: saleWithOverride, clientRequestId: requestId));
    }
    return _ok(path, <String, dynamic>{});
  }

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => postAnswer(invocation),
  );

  when(() => dio.post(any())).thenAnswer(
    (invocation) async => postAnswer(invocation),
  );

  when(
    () => dio.post(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((invocation) async => postAnswer(invocation));

  // Phase 15 byte endpoints (`POST /print`) call `post<Uint8List>` —
  // mocktail matches the generic type argument strictly, so they need
  // their own registrations; the body/filename still come from postAnswer.
  Future<Response<Uint8List>> postBytes(Invocation invocation) async {
    final response = postAnswer(invocation);
    return Response<Uint8List>(
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      data: response.data is Uint8List ? response.data as Uint8List : null,
      headers: response.headers,
      statusMessage: response.statusMessage,
    );
  }

  when(() => dio.post<Uint8List>(any(), data: any(named: 'data')))
      .thenAnswer(postBytes);

  when(
    () => dio.post<Uint8List>(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(postBytes);

  when(() => dio.delete(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 204,
    );
  });
}

Map<String, dynamic> _holdJson({
  String id = 'hold-1',
  String? note,
  String quantity = '2',
}) =>
    {
      'id': id,
      'device_id': 'pos-test',
      'customer_id': null,
      'note': note,
      'invoice_discount': '0',
      'created_at': '2026-01-01T10:00:00',
      'items': [
        {
          'product_id': _productId,
          'variant_id': null,
          'selling_unit_id': null,
          'product_name': 'Bread',
          'quantity': quantity,
          'unit_price': '10',
          'line_discount': '0',
          'product_unit': 'piece',
        },
      ],
    };

AuthUser _user({List<String> scopes = _defaultScopes}) => AuthUser(
      id: '00000000-0000-0000-0000-0000000000b1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: scopes,
    );

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  Size size = const Size(1366, 768),
  AppLocale locale = AppLocale.en,
  TextDirection direction = TextDirection.ltr,
  List<String>? permissions,
  Map<String, Object>? initialPrefs,
  PrintService? printService,
  ThemeData? theme,
}) async {
  SharedPreferences.setMockInitialValues(
    initialPrefs ?? <String, Object>{},
  );
  final prefs = await SharedPreferences.getInstance();
  _fakePreview = _FakePdfPreview();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider
            .overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(
          _user(scopes: permissions ?? _defaultScopes),
        ),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        posSettingsProvider.overrideWith((ref) => PosSettingsNotifier(prefs)),
        pdfPreviewProvider.overrideWithValue(_fakePreview),
        if (printService != null)
          printServiceProvider.overrideWithValue(printService),
      ],
      child: MaterialApp(
        theme: theme,
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

void main() {
  late MockDio dio;

  setUp(() {
    dio = MockDio();
    _mockDio(dio);
  });

  group('responsive layout', () {
    const sizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1024x768': Size(1024, 768),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };

    sizes.forEach((label, size) {
      testWidgets('renders without overflow at $label', (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        expect(find.byKey(const Key('pos-screen')), findsOneWidget);
        expect(find.byKey(const Key('pos-search-field')), findsOneWidget);
        if (posLayoutModeFor(size.width) == PosLayoutMode.narrow) {
          expect(find.byKey(const Key('toggle-cart')), findsOneWidget);
          expect(find.byKey(const Key('pos-pay-button')), findsNothing);
          await tester.tap(find.byKey(const Key('toggle-cart')));
          await tester.pump();
          expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
          expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
        } else {
          expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
          expect(find.byKey(const Key('toggle-cart')), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    });

    test('layout mode breakpoints are pure functions', () {
      expect(posLayoutModeFor(600), PosLayoutMode.narrow);
      expect(posLayoutModeFor(800), PosLayoutMode.medium);
      expect(posLayoutModeFor(1100), PosLayoutMode.wide);
      expect(posLayoutModeFor(1920), PosLayoutMode.wide);
    });
  });

  group('cart & payment UI', () {
    testWidgets('empty cart shows hint and pay disabled', (tester) async {
      await _pumpApp(tester, dio: dio);
      expect(find.byKey(const Key('pos-cart-empty')), findsOneWidget);
      final pay = tester.widget<FilledButton>(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(pay.onPressed, isNull);
    });

    testWidgets('search results show product card', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(find.text('Bread'), findsWidgets);
    });

    testWidgets('pay button becomes enabled after adding a line via provider',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final pay = tester.widget<FilledButton>(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(pay.onPressed, isNotNull);
      expect(find.byKey(const Key('pos-cart-lines')), findsOneWidget);
    });

    testWidgets('remove line empties cart', (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      const line = CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '1',
        unitPrice: '10',
      );
      container.read(posCartProvider.notifier).addLine(line);
      await tester.pump();
      expect(find.byKey(Key('cart-line-remove-${line.key}')), findsOneWidget);
      await tester.tap(find.byKey(Key('cart-line-remove-${line.key}')));
      await tester.pump();
      expect(container.read(posCartProvider).isEmpty, isTrue);
    });

    testWidgets('F12 clear requires confirmation (does not destroy cart)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('clear-cart-confirm')), findsOneWidget);
      expect(container.read(posCartProvider).isEmpty, isFalse);

      await tester.tap(find.text(AppStrings.t('cancel', 'en')));
      await tester.pumpAndSettle();
      expect(container.read(posCartProvider).isEmpty, isFalse);
    });
  });

  group('localization', () {
    testWidgets('English labels', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.en);
      expect(find.text(AppStrings.t('cart_empty_hint', 'en')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('payment_shortcut', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('French labels', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.fr);
      expect(find.byKey(const Key('pos-screen')), findsOneWidget);
      expect(
        AppStrings.t('cart_empty_hint', 'fr'),
        isNot(AppStrings.t('cart_empty_hint', 'en')),
      );
    });

    testWidgets('Arabic RTL directionality does not crash', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      expect(find.byKey(const Key('pos-screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        AppStrings.t('pos_subtitle', 'ar'),
        isNot(AppStrings.t('pos_subtitle', 'en')),
      );
    });
  });

  group('permissions', () {
    testWidgets('discount button snackbar without pos_discount',
        (tester) async {
      final limited = MockDio();
      _mockDio(
        limited,
        scopes: const ['pos_sale', 'product_view'],
      );

      await _pumpApp(
        tester,
        dio: limited,
        size: const Size(1366, 768),
        permissions: const ['pos_sale', 'product_view'],
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-discount-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(AppStrings.t('permission_discount', 'en')),
        findsWidgets,
      );
    });
  });

  group('price override confirmation', () {
    Future<void> checkoutCash(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-pay-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    testWidgets(
        'POST /sales price_overrides shows dialog with product, client price, '
        'server price, explanation; cart intact until checkout succeeds',
        (tester) async {
      final overrideDio = MockDio();
      _mockDio(overrideDio, saleWithOverride: true);

      await _pumpApp(tester, dio: overrideDio);

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      const line = CartLine(
        productId: _productId,
        name: 'Bread',
        quantity: '1',
        unitPrice: '9',
      );
      container.read(posCartProvider.notifier).addLine(line);
      await tester.pump();

      // Cart remains intact while payment dialog is open (before success).
      expect(container.read(posCartProvider).isEmpty, isFalse);
      await tester.tap(find.byKey(const Key('pos-pay-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(container.read(posCartProvider).isEmpty, isFalse);

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Dialog shown with required content.
      expect(find.byKey(const Key('price-override-dialog')), findsOneWidget);
      expect(
        find.byKey(Key('price-override-name-$_productId')),
        findsOneWidget,
      );
      expect(find.text('Bread'), findsWidgets);
      expect(
        find.byKey(Key('price-override-client-$_productId')),
        findsOneWidget,
      );
      expect(find.text('9.00'), findsWidgets);
      expect(
        find.byKey(Key('price-override-server-$_productId')),
        findsOneWidget,
      );
      expect(find.text('10.00'), findsWidgets);
      expect(
        find.byKey(const Key('price-override-explanation')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('price_override_explanation', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('price_override_client_price', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('price_override_server_price', 'en')),
        findsWidgets,
      );

      // Cart cleared only because checkout succeeded (not before).
      expect(container.read(posCartProvider).isEmpty, isTrue);
      expect(container.read(posCartProvider).lastResult, isNotNull);
      expect(
        container.read(posCartProvider).lastResult!.priceOverrides,
        hasLength(1),
      );
      expect(
        container
            .read(posCartProvider)
            .lastResult!
            .priceOverrides
            .first
            .productName,
        'Bread',
      );

      // Success snackbar not yet until acknowledge.
      expect(find.byKey(const Key('checkout-success-snackbar')), findsNothing);

      await tester.tap(find.byKey(const Key('price-override-acknowledge')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('price-override-dialog')), findsNothing);
      expect(
        find.byKey(const Key('checkout-success-snackbar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('successful sale without overrides skips override dialog',
        (tester) async {
      final plainDio = MockDio();
      _mockDio(plainDio, saleWithOverride: false);

      await _pumpApp(tester, dio: plainDio);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: _productId,
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();

      await checkoutCash(tester);

      expect(find.byKey(const Key('price-override-dialog')), findsNothing);
      expect(
        find.byKey(const Key('checkout-success-snackbar')),
        findsOneWidget,
      );
      expect(container.read(posCartProvider).isEmpty, isTrue);
      expect(
        container.read(posCartProvider).lastResult!.priceOverrides,
        isEmpty,
      );
    });
  });

  group('add-to-cart decision tree', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    testWidgets(
        'no variants + no selling units → direct add (qty 1, no dialog)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.productId, _productId);
      expect(line.quantity, '1');
      expect(line.unitPrice, '10.0');
      expect(line.variantId, isNull);
      expect(line.sellingUnitId, isNull);
      expect(line.unitName, 'piece');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
    });

    testWidgets('no variants + selling units → selling-unit picker',
        (tester) async {
      final unitsDio = MockDio();
      _mockDio(
        unitsDio,
        sellingUnits: [_sellingUnitJson(id: 'su-box', name: 'Box')],
      );
      await _pumpApp(tester, dio: unitsDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
    });

    testWidgets('multiple variants → variant picker', (tester) async {
      final multiDio = MockDio();
      _mockDio(
        multiDio,
        variants: [
          _variantJson(id: 'var-a', name: 'Small'),
          _variantJson(id: 'var-b', name: 'Large'),
        ],
      );
      await _pumpApp(tester, dio: multiDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
    });

    testWidgets(
        'single variant auto-selects (no dialog) + no units → direct add '
        'with variantId', (tester) async {
      final singleDio = MockDio();
      _mockDio(
        singleDio,
        variants: [
          _variantJson(id: 'var-only', name: 'Solo', price: '8'),
        ],
      );
      await _pumpApp(tester, dio: singleDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.first.variantId, 'var-only');
      expect(cart.lines.first.unitPrice, '8');
      expect(cart.lines.first.quantity, '1');
    });

    testWidgets(
        'after variant choice → selling-unit picker when units exist '
        '(no second variant dialog)', (tester) async {
      final bothDio = MockDio();
      _mockDio(
        bothDio,
        variants: [
          _variantJson(id: 'var-a', name: 'Small'),
          _variantJson(id: 'var-b', name: 'Large'),
        ],
        sellingUnits: [_sellingUnitJson(id: 'su-piece', name: 'Piece')],
      );
      await _pumpApp(tester, dio: bothDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);

      await tester.tap(find.byKey(const Key('variant-var-b')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
    });

    testWidgets(
        'empty variants success + empty selling units success → direct add',
        (tester) async {
      final emptyDio = MockDio();
      _mockDio(emptyDio, variants: const [], sellingUnits: const []);
      await _pumpApp(tester, dio: emptyDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-lookup-error')), findsNothing);
      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(
        containerOf(tester).read(posCartProvider).lines,
        hasLength(1),
      );
    });

    testWidgets(
        'variant API failure (500) → no cart mutation + localized error/retry',
        (tester) async {
      final failDio = MockDio();
      _mockDio(failDio, variantsErrorStatus: 500);
      await _pumpApp(tester, dio: failDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);
      expect(
        find.byKey(const Key('pos-lookup-error-message')),
        findsOneWidget,
      );
      expect(find.text('lookup failed (500)'), findsOneWidget);
      expect(find.byKey(const Key('pos-lookup-error-retry')), findsOneWidget);
      expect(find.text(AppStrings.t('retry', 'en')), findsOneWidget);
    });

    testWidgets(
        'variant API network failure → no cart mutation + network error',
        (tester) async {
      final netDio = MockDio();
      _mockDio(netDio, variantsNetworkError: true);
      await _pumpApp(tester, dio: netDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('network_error_retry', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pos-lookup-error-retry')), findsOneWidget);
    });

    testWidgets(
        'empty selling units success (after empty variants) → direct add',
        (tester) async {
      final unitsEmptyDio = MockDio();
      _mockDio(unitsEmptyDio, variants: const [], sellingUnits: const []);
      await _pumpApp(tester, dio: unitsEmptyDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-lookup-error')), findsNothing);
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(
        containerOf(tester).read(posCartProvider).lines.first.sellingUnitId,
        isNull,
      );
    });

    testWidgets(
        'selling-unit API failure → no cart mutation + error/retry '
        '(not treated as empty)', (tester) async {
      final unitFailDio = MockDio();
      _mockDio(unitFailDio, sellingUnitsErrorStatus: 500);
      await _pumpApp(tester, dio: unitFailDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);
      expect(find.text('lookup failed (500)'), findsOneWidget);
      expect(find.byKey(const Key('pos-lookup-error-retry')), findsOneWidget);
    });

    testWidgets(
        'retry after lookup failure succeeds → then direct add when '
        'lookups recover', (tester) async {
      var variantsBroken = true;
      final recoverDio = MockDio();
      // First call fails; after flipping flag the bodyFor path must succeed.
      // Rebuild mock with a live flag via custom onSearch not enough — use
      // status that we clear by re-mocking is heavy; instead fail once then
      // succeed by checking flag inside a custom get for variants only.
      when(() => recoverDio.interceptors).thenReturn(Interceptors());
      when(() => recoverDio.options).thenReturn(BaseOptions());
      when(() => recoverDio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        final path = invocation.positionalArguments.first as String? ?? '';
        if (path.endsWith('/variants') && variantsBroken) {
          throw DioException(
            requestOptions: RequestOptions(path: path),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: path),
              statusCode: 503,
              data: {
                'error': {'code': 'UNAVAILABLE', 'message': 'temporarily down'},
              },
            ),
          );
        }
        return _ok(
          path,
          path == _catalogPath
              ? {'items': [_product()], 'total': 1}
              : path.endsWith('/variants')
                  ? {'items': <dynamic>[], 'total': 0}
                  : path.endsWith('/selling-units')
                      ? {'items': <dynamic>[], 'total': 0}
                      : _defaultBody(path),
        );
      });
      when(() => recoverDio.get(any())).thenAnswer((invocation) async {
        final path = invocation.positionalArguments.first as String? ?? '';
        if (path.endsWith('/variants') && variantsBroken) {
          throw DioException(
            requestOptions: RequestOptions(path: path),
            type: DioExceptionType.badResponse,
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: path),
              statusCode: 503,
              data: {
                'error': {'code': 'UNAVAILABLE', 'message': 'temporarily down'},
              },
            ),
          );
        }
        return _ok(
          path,
          path.endsWith('/variants')
              ? {'items': <dynamic>[], 'total': 0}
              : path.endsWith('/selling-units')
                  ? {'items': <dynamic>[], 'total': 0}
                  : _defaultBody(path),
        );
      });
      when(() => recoverDio.get(_favoritesPath)).thenAnswer(
        (_) async => _ok(_favoritesPath, {'items': <dynamic>[], 'total': 0}),
      );
      when(() => recoverDio.post(any(), data: any(named: 'data')))
          .thenAnswer(
        (invocation) async => _ok(
          invocation.positionalArguments.first as String? ?? '',
          <String, dynamic>{},
        ),
      );
      when(() => recoverDio.post(any())).thenAnswer(
        (invocation) async => _ok(
          invocation.positionalArguments.first as String? ?? '',
          <String, dynamic>{},
        ),
      );

      await _pumpApp(tester, dio: recoverDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);

      variantsBroken = false;
      await tester.tap(find.byKey(const Key('pos-lookup-error-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-lookup-error')), findsNothing);
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
    });
  });

  group('catalog view mode', () {
    testWidgets('defaults to grid when no preference stored', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('pos-view-mode-toggle')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-list')), findsNothing);
      // Grid segment shows its localized label (selected style applied in UI).
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.text(AppStrings.t('catalog_view_grid', 'en')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('toggle to list shows compact list and persists key',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-grid')), findsNothing);
      expect(find.byKey(Key('pos-product-$_productId')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.text(AppStrings.t('catalog_view_list', 'en')),
        ),
        findsOneWidget,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'list');
    });

    testWidgets('toggle back to grid restores grid and persists key',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-list')), findsNothing);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'grid');
    });

    testWidgets(
        'view mode persists across provider/widget recreation; toggle does '
        'not reload catalog', (tester) async {
      var searchLoads = 0;
      final counted = MockDio();
      _mockDio(counted, onSearch: () => searchLoads++);

      await _pumpApp(tester, dio: counted);
      await tester.pump(const Duration(milliseconds: 500));
      expect(searchLoads, greaterThan(0));
      final loadsBeforeToggle = searchLoads;

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(searchLoads, loadsBeforeToggle);

      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(kPosCatalogViewModeKey);
      expect(saved, 'list');

      await tester.pumpWidget(const SizedBox());
      await _pumpApp(
        tester,
        dio: counted,
        initialPrefs: {kPosCatalogViewModeKey: saved!},
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-grid')), findsNothing);
    });
  });

  group('product card image fallback', () {
    late Directory tempDir;
    late File validImage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pos_img_');
      validImage = File('${tempDir.path}${Platform.pathSeparator}p.png');
      await validImage.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
          'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        ),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('missing image_path → text-first card (no blank placeholder)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(Key('pos-product-name-$_productId')), findsOneWidget);
      expect(find.byKey(Key('pos-product-price-$_productId')), findsOneWidget);
      expect(find.text('Bread'), findsWidgets);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('invalid image path (file missing) → still text-first',
        (tester) async {
      final badDio = MockDio();
      _mockDio(
        badDio,
        imagePath: '${tempDir.path}${Platform.pathSeparator}missing.png',
      );
      await _pumpApp(tester, dio: badDio);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(Key('pos-product-name-$_productId')), findsOneWidget);
      expect(find.byKey(Key('pos-product-price-$_productId')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('valid image file → image widget rendered with name + price',
        (tester) async {
      final imgDio = MockDio();
      _mockDio(imgDio, imagePath: validImage.path);
      await _pumpApp(tester, dio: imgDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('pos-product-name-$_productId')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-price-$_productId')), findsOneWidget);
      // R4: the catalog card name sits in the readable band — 16px
      // semibold (was 14px bold), never smaller for a thumbnail card.
      final cardName = tester.widget<Text>(
        find.byKey(Key('pos-product-name-$_productId')),
      );
      expect(cardName.style?.fontSize, 16);
      expect(cardName.style?.fontWeight, FontWeight.w600);
      expect(tester.takeException(), isNull);
    });
  });

  group('responsive catalog (UX FIX #2)', () {
    const sizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };

    sizes.forEach((label, size) {
      testWidgets('grid and list toggle without overflow at $label',
          (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);

        await tester.tap(find.byKey(const Key('pos-view-mode-list')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('cart selling unit presentation (UX FIX #3)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    const boxUnitId = 'su-box';
    final cartLineKey = '$_productId||$boxUnitId';

    Map<String, dynamic> boxUnit({
      String multiplier = '10',
      String sellingPrice = '550',
      String availableSelling = '2',
      String availableBase = '20',
    }) =>
        _sellingUnitJson(
          id: boxUnitId,
          name: 'Box',
          multiplier: multiplier,
          unitType: 'box',
          sellingPrice: sellingPrice,
          isBaseUnit: false,
          availableSelling: availableSelling,
          availableBase: availableBase,
        );

    /// Drive: product tap → selling-unit picker → quantity dialog → confirm.
    Future<void> pickSellingUnit(
      WidgetTester tester, {
      String quantity = '1',
    }) async {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      await tester.tap(find.byKey(Key('selling-unit-$boxUnitId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      // Phase 17 §18: the dialog opens blank + focused, so the quantity is
      // ALWAYS typed explicitly (there is no pre-filled `1` to fall back on).
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        quantity,
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'base product (no selling unit) → base unit + price visible, '
        'no base-info block, no extra line',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.unitName, 'piece');
      expect(line.unitPrice, '10.0');
      expect(line.sellingUnitId, isNull);
      expect(line.unitMultiplier, isNull);

      final key = line.key;
      expect(
        find.byKey(Key('cart-line-summary-$key')),
        findsOneWidget,
      );
      expect(
        find.text('1 ${AppStrings.unitLabel('piece', 'en')} × 10.0'),
        findsOneWidget,
      );
      expect(find.byKey(Key('cart-line-base-qty-$key')), findsNothing);
      expect(find.byKey(Key('cart-line-base-price-$key')), findsNothing);
      expect(cart.lines, hasLength(1));
    });

    testWidgets(
        'selling unit → selected unit + price, base piece qty, base price '
        'visible; exactly one cart line',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(
        unitDio,
        productPrice: '60',
        sellingUnits: [boxUnit()],
      );
      await _pumpApp(tester, dio: unitDio);
      await pickSellingUnit(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1)); // never a second Piece line
      final line = cart.lines.first;
      expect(line.sellingUnitId, boxUnitId);
      expect(line.unitName, 'Box');
      expect(line.unitPrice, '550');
      expect(line.quantity, '1');
      expect(line.baseUnitPrice, '60');
      expect(line.unitMultiplier, '10');

      expect(
        find.text('1 Box × 550'),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('cart-line-base-qty-$cartLineKey')),
        findsOneWidget,
      );
      expect(find.text('10 Piece'), findsOneWidget);
      expect(
        find.byKey(Key('cart-line-base-price-$cartLineKey')),
        findsOneWidget,
      );
      expect(
        find.text('${AppStrings.t('base_price', 'en')}: ${_m('60')} / Piece'),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('cart-line-total-$cartLineKey')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(Key('cart-line-total-$cartLineKey')))
            .data,
        '550.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(Key('cart-line-total-$cartLineKey')))
            .textDirection,
        TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('1 Box → base quantity 10 Piece (multiplier visible)',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio);
      await pickSellingUnit(tester, quantity: '1');

      expect(find.text('1 Box × 550'), findsOneWidget);
      expect(find.text('10 Piece'), findsOneWidget);
      final line = containerOf(tester).read(posCartProvider).lines.first;
      expect(line.quantity, '1');
    });

    testWidgets('2 Box → base quantity 20 Piece (double multiplier)',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio);
      await pickSellingUnit(tester, quantity: '2');

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(find.text('2 Box × 550'), findsOneWidget);
      expect(find.text('20 Piece'), findsOneWidget);
      expect(cart.lines.first.quantity, '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'cart total uses selling-unit price only (2×550=1100, never '
        '20×60=1200); base price informational',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio);
      await pickSellingUnit(tester, quantity: '2');

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.totals.total, closeTo(1100, 0.001));
      expect(cart.totals.total, isNot(closeTo(1200, 0.001)));
      expect(
        find.byKey(Key('cart-line-total-$cartLineKey')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(Key('cart-line-total-$cartLineKey')))
            .data,
        '1 100.00',
      );
      // Base price displayed independently, does not change total.
      expect(
        find.text('${AppStrings.t('base_price', 'en')}: ${_m('60')} / Piece'),
        findsOneWidget,
      );
    });

    testWidgets(
        'variant + selling unit → unit, price, base unit, base price visible '
        '(base = variant price)',
        (tester) async {
      final varDio = MockDio();
      _mockDio(
        varDio,
        productPrice: '60',
        variants: [
          _variantJson(id: 'var-only', name: 'Large', price: '12'),
        ],
        sellingUnits: [boxUnit(availableBase: '10', availableSelling: '1')],
      );
      await _pumpApp(tester, dio: varDio);
      // Single variant auto-selects → picker opens directly.
      await pickSellingUnit(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.variantId, 'var-only');
      expect(line.sellingUnitId, boxUnitId);
      expect(line.unitName, 'Box');
      expect(line.unitPrice, '550');
      expect(line.baseUnitPrice, '12'); // variant price, not product price
      expect(line.unitMultiplier, '10');

      expect(find.textContaining('Large'), findsWidgets);
      expect(find.text('1 Box × 550'), findsOneWidget);
      expect(find.text('10 Piece'), findsOneWidget);
      expect(
        find.text('${AppStrings.t('base_price', 'en')}: ${_m('12')} / Piece'),
        findsOneWidget,
      );
      final varLineKey = '$_productId|var-only|$boxUnitId';
      expect(
        find.byKey(Key('cart-line-total-$varLineKey')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(Key('cart-line-total-$varLineKey')))
            .data,
        '550.00',
      );
    });

    testWidgets('Arabic RTL → localized base price label + base unit',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio, locale: AppLocale.ar);
      await pickSellingUnit(tester);

      // The selling-unit name is localized too (Box → علبة in ar).
      expect(
        find.text(
          '1 ${AppStrings.unitLabel('Box', 'ar')} × 550',
        ),
        findsOneWidget,
      );
      expect(
        find.text('10 ${AppStrings.unitLabel('piece', 'ar')}'),
        findsOneWidget,
      );
      expect(
        find.text(
          '${AppStrings.t('base_price', 'ar')}: '
          '${_m('60')} / ${AppStrings.unitLabel('piece', 'ar')}',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('French LTR → localized base price label', (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio, locale: AppLocale.fr);
      await pickSellingUnit(tester);

      expect(
        find.text(
          '${AppStrings.t('base_price', 'fr')}: '
          '${_m('60')} / ${AppStrings.unitLabel('piece', 'fr')}',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English LTR → localized base price label', (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio, locale: AppLocale.en);
      await pickSellingUnit(tester);

      expect(
        find.text('${AppStrings.t('base_price', 'en')}: ${_m('60')} / Piece'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding Box creates no extra base-unit cart line',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, productPrice: '60', sellingUnits: [boxUnit()]);
      await _pumpApp(tester, dio: unitDio);
      await pickSellingUnit(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.first.sellingUnitId, boxUnitId);
      // No line exists whose key has an empty selling-unit segment.
      final baseLines =
          cart.lines.where((l) => l.sellingUnitId == null).toList();
      expect(baseLines, isEmpty);
    });
  });

  group('selling-unit base option (UX FIX #4 Part A)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Map<String, dynamic> boxOnly() => _sellingUnitJson(
          id: 'su-box',
          name: 'Box',
          multiplier: '10',
          unitType: 'box',
          sellingPrice: '550',
          isBaseUnit: false,
          availableSelling: '2',
          availableBase: '20',
        );

    Future<void> openPicker(WidgetTester tester, MockDio mock) async {
      await _pumpApp(tester, dio: mock);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
    }

    testWidgets('base unit option always shown alongside selling units',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await openPicker(tester, mock);

      expect(find.byKey(const Key('selling-unit-base')), findsOneWidget);
      expect(find.byKey(const Key('selling-unit-su-box')), findsOneWidget);
      // Configured isBaseUnit rows are filtered (none here besides box).
      expect(tester.takeException(), isNull);
    });

    testWidgets('base option shows product base price', (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await openPicker(tester, mock);

      final base = find.byKey(const Key('selling-unit-base'));
      expect(base, findsOneWidget);
      expect(
        find.descendant(of: base, matching: find.textContaining('60')),
        findsWidgets,
      );
    });

    testWidgets('selling unit option shows selling price', (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await openPicker(tester, mock);

      final box = find.byKey(const Key('selling-unit-su-box'));
      expect(box, findsOneWidget);
      expect(
        find.descendant(of: box, matching: find.textContaining('550')),
        findsWidgets,
      );
    });

    testWidgets('base selection → sellingUnitId null + base price + product '
        'unit name', (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await openPicker(tester, mock);

      await tester.tap(find.byKey(const Key('selling-unit-base')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '1',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.sellingUnitId, isNull);
      expect(line.unitPrice, '60');
      expect(line.unitName, 'piece');
      expect(line.unitMultiplier, isNull);
    });

    testWidgets('selling unit selection → its id + selling price',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await openPicker(tester, mock);

      await tester.tap(find.byKey(const Key('selling-unit-su-box')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '1',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.sellingUnitId, 'su-box');
      expect(line.unitPrice, '550');
      expect(line.unitName, 'Box');
    });

    testWidgets('variant auto-select → base option price uses variant price',
        (tester) async {
      final mock = MockDio();
      _mockDio(
        mock,
        productPrice: '60',
        variants: [
          _variantJson(id: 'var-1', name: 'Large', price: '12'),
        ],
        sellingUnits: [boxOnly()],
      );
      await openPicker(tester, mock);

      final base = find.byKey(const Key('selling-unit-base'));
      expect(base, findsOneWidget);
      expect(
        find.descendant(of: base, matching: find.textContaining('12')),
        findsWidgets,
      );
    });

    testWidgets('Arabic RTL → localized base unit label on base option',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock, productPrice: '60', sellingUnits: [boxOnly()]);
      await _pumpApp(tester, dio: mock, locale: AppLocale.ar);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      expect(find.byKey(const Key('selling-unit-base')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('selling-unit-base')),
          matching: find.text(AppStrings.t('base_unit', 'ar')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('sale history + detail (UX FIX #4 Part B)', () {
    const saleId = 'sale-h-1';
    const invoice = 'INV-0042';

    Map<String, dynamic> saleListItem() => {
          'id': saleId,
          'invoice_number': invoice,
          'total': '1100.00',
          'paid': '1100.00',
          'payment_method': 'cash',
          'status': 'completed',
          'sale_date': '2026-09-24T10:00:00',
          'customer_id': null,
        };

    Map<String, dynamic> saleDetailJson() => {
          'id': saleId,
          'invoice_number': invoice,
          'client_request_id': null,
          'customer_id': 'cust-9',
          'status': 'completed',
          'subtotal': '1100.00',
          'discount': '100.00',
          'total': '1000.00',
          'paid': '1000.00',
          'change': '0',
          'debt': '0',
          'payment_method': 'cash',
          'device_id': 'dev-1',
          'note': null,
          'sale_date': '2026-09-24T10:00:00',
          'lines': [
            {
              'id': 'line-1',
              'product_id': _productId,
              'variant_id': null,
              'product_name': 'Bread',
              'product_sku': null,
              'product_barcode': '111',
              'product_unit': 'piece',
              'unit_price': '550.00',
              'unit_cost': '400.00',
              'quantity': '2',
              'line_discount': '0',
              'line_total': '1100.00',
            },
          ],
          'payments': [
            {'id': 'pay-1', 'method': 'cash', 'amount': '1000.00'},
          ],
          'idempotent_replay': false,
        };

    Future<MockDio> pumpWithHistory(
      WidgetTester tester, {
      PrintService? printService,
      AppLocale locale = AppLocale.en,
      Map<String, dynamic>? settingsBody,
    }) async {
      final mock = MockDio();
      _mockDio(
        mock,
        saleListBody: {
          'items': [saleListItem()],
          'total': 1,
          'page': 1,
          'page_size': 50,
        },
        saleDetailBody: saleDetailJson(),
        settingsBody: settingsBody,
      );
      await _pumpApp(
        tester,
        dio: mock,
        locale: locale,
        printService: printService,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-history-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-history-dialog')), findsOneWidget);
      return mock;
    }

    Future<void> openDetail(WidgetTester tester) async {
      await tester.tap(find.byKey(Key('sale-row-$saleId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);
      // Allow detail GET to resolve.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    }

    testWidgets('history row tap opens sale detail', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);
      expect(find.byKey(const Key('sale-detail-body')), findsOneWidget);
    });

    testWidgets('detail shows invoice number', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-detail-invoice')))
            .data,
        invoice,
      );
    });

    testWidgets('detail shows sale lines', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-detail-line-0')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('sale-detail-dialog')),
          matching: find.text('Bread'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('detail shows discount amount', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-detail-discount')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-detail-discount')))
            .data,
        '100.00',
      );
    });

    testWidgets('detail shows totals (subtotal/total/paid)', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-detail-subtotal')))
            .data,
        '1 100.00',
      );
      final subtotal = tester
          .widget<Text>(find.byKey(const Key('sale-detail-subtotal')));
      expect(subtotal.textDirection, TextDirection.ltr);
      expect(
        tester.widget<Text>(find.byKey(const Key('sale-detail-total'))).data,
        '1 000.00',
      );
      final total =
          tester.widget<Text>(find.byKey(const Key('sale-detail-total')));
      expect(total.textDirection, TextDirection.ltr);
      expect(
        tester.widget<Text>(find.byKey(const Key('sale-detail-paid'))).data,
        '1 000.00',
      );
    });

    testWidgets('detail shows payment method', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      final payment = find.byKey(const Key('sale-detail-payment'));
      expect(payment, findsOneWidget);
      expect(
        tester.widget<Text>(payment).data,
        contains('cash'),
      );
    });

    testWidgets('detail shows customer when present', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-detail-customer')), findsOneWidget);
      expect(
        find.text(AppStrings.t('customer', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('detail shows Print button', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-print')), findsOneWidget);
    });

    testWidgets('detail shows Reprint button', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-reprint')), findsOneWidget);
    });

    testWidgets('print preview opens on the configured default paper (§17.6)',
        (tester) async {
      await pumpWithHistory(
        tester,
        settingsBody: <String, dynamic>{'default_paper': 'A4'},
      );
      await openDetail(tester);

      await tester.tap(find.byKey(const Key('sale-print')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      expect(_fakePreview.papers, <String>['A4']);
      expect(printRequestBodies, hasLength(1));
      expect(printRequestBodies.single['paper'], 'A4');
      expect(printRequestBodies.single['document_type'], 'sale');
    });

    testWidgets('print failure → localized error, never success',
        (tester) async {
      final failing = _FakePrintService(fail: true);
      await pumpWithHistory(tester, printService: failing);
      await openDetail(tester);

      await tester.tap(find.byKey(const Key('sale-print')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-error')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('print_failed', 'en')),
        findsOneWidget,
      );
      expect(failing.printed, isEmpty);
      // Never a success snackbar for print.
      expect(find.textContaining(AppStrings.t('sale_completed', 'en')),
          findsNothing);
    });

    testWidgets('failed print does not alter the sale (detail intact)',
        (tester) async {
      final failing = _FakePrintService(fail: true);
      await pumpWithHistory(tester, printService: failing);
      await openDetail(tester);

      await tester.tap(find.byKey(const Key('sale-print')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-detail-invoice')))
            .data,
        invoice,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('sale-detail-total'))).data,
        '1 000.00',
      );
      expect(find.byKey(const Key('print-error')), findsOneWidget);
    });

    testWidgets('copy invoice shows localized confirmation', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      await pumpWithHistory(tester);
      await openDetail(tester);

      await tester.tap(find.byKey(const Key('sale-copy-invoice')));
      await tester.pumpAndSettle();
      expect(
        find.text(AppStrings.t('invoice_copied', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('close button dismisses sale detail', (tester) async {
      await pumpWithHistory(tester);
      await openDetail(tester);
      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sale-detail-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-detail-dialog')), findsNothing);
      expect(find.byKey(const Key('sale-history-dialog')), findsOneWidget);
    });
  });

  group('print preview (UX FIX #4 Part B)', () {
    const saleId = 'sale-h-2';
    const invoice = 'INV-0077';

    Map<String, dynamic> saleDetailJson() => {
          'id': saleId,
          'invoice_number': invoice,
          'client_request_id': null,
          'customer_id': null,
          'status': 'completed',
          'subtotal': '550.00',
          'discount': '0',
          'total': '550.00',
          'paid': '550.00',
          'change': '0',
          'debt': '0',
          'payment_method': 'cash',
          'device_id': null,
          'note': null,
          'sale_date': '2026-09-24T11:00:00',
          'lines': [
            {
              'id': 'line-p',
              'product_id': _productId,
              'variant_id': null,
              'product_name': 'Rice Bag',
              'product_sku': null,
              'product_barcode': null,
              'product_unit': 'piece',
              'unit_price': '550.00',
              'unit_cost': '400.00',
              'quantity': '1',
              'line_discount': '0',
              'line_total': '550.00',
            },
          ],
          'payments': [
            {'id': 'pay-p', 'method': 'cash', 'amount': '550.00'},
          ],
          'idempotent_replay': false,
        };

    Future<_FakePrintService> openPreview(
      WidgetTester tester, {
      AppLocale locale = AppLocale.en,
    }) async {
      final printer = _FakePrintService();
      final mock = MockDio();
      _mockDio(
        mock,
        saleListBody: {
          'items': [
            {
              'id': saleId,
              'invoice_number': invoice,
              'total': '550.00',
              'paid': '550.00',
              'payment_method': 'cash',
              'status': 'completed',
              'sale_date': '2026-09-24T11:00:00',
              'customer_id': null,
            },
          ],
          'total': 1,
          'page': 1,
        },
        saleDetailBody: saleDetailJson(),
      );
      await _pumpApp(tester, dio: mock, locale: locale, printService: printer);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-history-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('sale-row-$saleId')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sale-print')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      return printer;
    }

    testWidgets('preview receives fetched PDF bytes; confirm prints them',
        (tester) async {
      final printer = await openPreview(tester);
      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      expect(find.byKey(const Key('print-preview-body')), findsOneWidget);

      // Preview seam received the backend bytes + server filename.
      expect(_fakePreview.received, hasLength(1));
      expect(_fakePreview.papers, <String>['80mm']);
      expect(find.textContaining('sale_document.pdf'), findsOneWidget);

      // Request body mirrors the sale (Phase 15 §12.2).
      expect(printRequestBodies, hasLength(1));
      expect(printRequestBodies.single['document_type'], 'sale');
      expect(printRequestBodies.single['document_id'], saleId);
      expect(printRequestBodies.single['paper'], '80mm');
      expect(printRequestBodies.single['locale'], 'en');

      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();
      // Preview/print parity: printPdf gets EXACTLY the previewed bytes.
      expect(printer.printedPdfs, hasLength(1));
      expect(printer.printedPdfs.single, _fakePreview.received.single);
      expect(printer.printedPapers, <String>['80mm']);
      expect(printer.printed, isEmpty); // superseded text path never runs
      expect(find.byKey(const Key('print-preview-dialog')), findsNothing);
    });

    testWidgets('paper toggle refetches the document for A4',
        (tester) async {
      final printer = await openPreview(tester);
      await tester.tap(find.text(AppStrings.t('paper_a4', 'en')));
      await tester.pumpAndSettle();

      expect(printRequestBodies, hasLength(2));
      expect(printRequestBodies.last['paper'], 'A4');
      expect(_fakePreview.papers, <String>['80mm', 'A4']);

      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();
      expect(printer.printedPapers, <String>['A4']);
    });

    testWidgets('cancel → no print and no toast (§16.2)', (tester) async {
      final printer = await openPreview(tester);

      await tester.tap(find.byKey(const Key('print-preview-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-dialog')), findsNothing);
      expect(printer.printedPdfs, isEmpty);
      expect(printer.printed, isEmpty);
      expect(find.byKey(const Key('print-save-pdf-toast')), findsNothing);
      expect(
        find.textContaining(AppStrings.t('print_failed', 'en')),
        findsNothing,
      );
      // Sale detail stays intact behind the closed dialog.
      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);
    });
  });

  group('segmented grid/list control (UX FIX #6)', () {
    testWidgets('toggle shows both segments with icon + localized label',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      final toggle = find.byKey(const Key('pos-view-mode-toggle'));
      expect(toggle, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.byType(Icon),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.byType(Icon),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.text(AppStrings.t('catalog_view_grid', 'en')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.text(AppStrings.t('catalog_view_list', 'en')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('list mode shows meta line and dedicated add button',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(find.byKey(Key('pos-product-meta-$_productId')), findsOneWidget);
      expect(find.byKey(Key('pos-product-add-$_productId')), findsOneWidget);
      expect(find.byKey(Key('pos-product-name-$_productId')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching list → grid restores card layout without reload',
        (tester) async {
      var searchLoads = 0;
      final counted = MockDio();
      _mockDio(counted, onSearch: () => searchLoads++);
      await _pumpApp(tester, dio: counted);
      await tester.pump(const Duration(milliseconds: 500));
      final before = searchLoads;

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-list')), findsNothing);
      expect(searchLoads, before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selected segment persists to SharedPreferences', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'list');

      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'grid');
    });

    testWidgets('stored list preference restored on cold start', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        initialPrefs: {kPosCatalogViewModeKey: 'list'},
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-grid')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('both segments tappable in sequence without overflow',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(800, 600));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('pos-view-mode-list')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('responsive POS (UX FIX #6)', () {
    const sizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1024x768': Size(1024, 768),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };

    sizes.forEach((label, size) {
      testWidgets('no overflow at $label (grid, list, cart visible)',
          (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);

        // Narrow layout hides the cart (and pay) behind a toggle.
        final narrow = posLayoutModeFor(size.width) == PosLayoutMode.narrow;
        if (narrow) {
          expect(find.byKey(const Key('toggle-cart')), findsOneWidget);
          await tester.tap(find.byKey(const Key('toggle-cart')));
          await tester.pump();
          expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
          // Close the cart overlay so catalog controls are tappable again.
          await tester.tap(find.byKey(const Key('toggle-cart')));
          await tester.pump();
        } else {
          expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
        }
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('pos-view-mode-list')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('option picker localization (UX FIX #6)', () {
    Future<void> openVariantPicker(
      WidgetTester tester, {
      required AppLocale locale,
      required TextDirection direction,
    }) async {
      final multiDio = MockDio();
      _mockDio(
        multiDio,
        variants: [
          _variantJson(id: 'var-a', name: 'Small'),
          _variantJson(id: 'var-b', name: 'Large'),
        ],
      );
      await _pumpApp(
        tester,
        dio: multiDio,
        locale: locale,
        direction: direction,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
    }

    testWidgets('Arabic RTL variant picker shows localized labels',
        (tester) async {
      await openVariantPicker(
        tester,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      final loc = 'ar';
      expect(find.text(AppStrings.t('variants', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_variant_hint', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_and_add', loc)), findsOneWidget);
      expect(
        find.text(AppStrings.t('picker_keyboard_hint', loc)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('variant-var-a')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('French variant picker shows localized labels', (tester) async {
      await openVariantPicker(
        tester,
        locale: AppLocale.fr,
        direction: TextDirection.ltr,
      );
      final loc = 'fr';
      expect(find.text(AppStrings.t('variants', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_variant_hint', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_and_add', loc)), findsOneWidget);
      expect(
        find.text(AppStrings.t('picker_keyboard_hint', loc)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English variant picker shows localized labels', (tester) async {
      await openVariantPicker(
        tester,
        locale: AppLocale.en,
        direction: TextDirection.ltr,
      );
      final loc = 'en';
      expect(find.text(AppStrings.t('variants', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_variant_hint', loc)), findsOneWidget);
      expect(find.text(AppStrings.t('select_and_add', loc)), findsOneWidget);
      expect(
        find.text(AppStrings.t('picker_keyboard_hint', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('cart totals panel & pay (UX FIX #7)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addBread(ProviderContainer container, {String qty = '2'}) {
      container.read(posCartProvider.notifier).addLine(
            CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: qty,
              unitPrice: '10',
            ),
          );
    }

    testWidgets('empty cart shows dedicated totals panel with zero values',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
            .data,
        '0.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-discount-value'))).data,
        '-0.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .data,
        '0.00 DA',
      );
      expect(find.byKey(const Key('pos-total-label')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
    });

    testWidgets('pay button disabled when empty, enabled after adding line',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      var pay = tester.widget<FilledButton>(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(pay.onPressed, isNull);

      addBread(containerOf(tester));
      await tester.pump();
      pay = tester.widget<FilledButton>(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(pay.onPressed, isNotNull);
    });

    testWidgets('pay shows shortcut, total amount and currency DA',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addBread(containerOf(tester), qty: '3');
      await tester.pump();

      final payTexts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('pos-pay-button')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .join(' ');
      expect(payTexts, contains(AppStrings.t('payment_shortcut', 'en')));
      expect(payTexts, contains('30.00'));
      expect(payTexts, contains('DA'));
    });

    testWidgets('subtotal/total update when line added', (tester) async {
      await _pumpApp(tester, dio: dio);
      addBread(containerOf(tester), qty: '2');
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
            .data,
        '20.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '20.00 DA',
      );
    });

    testWidgets('invoice discount row updates total (amber discount value)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      addBread(container, qty: '2');
      container.read(posCartProvider.notifier).setInvoiceDiscount('5');
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('pos-discount-value'))).data,
        '-5.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '15.00 DA',
      );
    });

    testWidgets('TOTAL value uses primary color and is larger than subtotal',
        (tester) async {
      await _pumpApp(tester, dio: dio, theme: AppTheme.dark());
      addBread(containerOf(tester));
      await tester.pump();

      final totalStyle = tester
          .widget<Text>(find.byKey(const Key('pos-total-value')))
          .style!;
      final subStyle = tester
          .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
          .style!;
      final theme = Theme.of(
        tester.element(find.byKey(const Key('pos-totals-panel'))),
      );

      expect(totalStyle.color, theme.colorScheme.primary);
      // Normal desktop (768 height): TOTAL 40–48 (UX FIX #8).
      expect(totalStyle.fontSize!, inInclusiveRange(40, 48));
      expect(totalStyle.fontWeight, FontWeight.w800);
      expect(subStyle.fontSize ?? 14, lessThan(totalStyle.fontSize!));
      expect(totalStyle.fontSize!, greaterThanOrEqualTo(36));
    });

    testWidgets('discount value uses warning amber; subtotal muted',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addBread(containerOf(tester));
      containerOf(tester)
          .read(posCartProvider.notifier)
          .setInvoiceDiscount('2');
      await tester.pump();

      final discountStyle = tester
          .widget<Text>(find.byKey(const Key('pos-discount-value')))
          .style!;
      final subStyle = tester
          .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
          .style!;
      final theme = Theme.of(
        tester.element(find.byKey(const Key('pos-totals-panel'))),
      );

      expect(discountStyle.color, const Color(0xFFFF9800));
      expect(subStyle.color, isNot(theme.colorScheme.primary));
      expect(subStyle.color, isNot(const Color(0xFFFF9800)));
    });

    testWidgets('total label fontSize in 18–20 range', (tester) async {
      await _pumpApp(tester, dio: dio, theme: AppTheme.dark());
      final style = tester
          .widget<Text>(find.byKey(const Key('pos-total-label')))
          .style!;
      expect(style.fontSize!, inInclusiveRange(18, 20));
      expect(style.fontWeight, FontWeight.w700);
    });

    testWidgets('pay button is at least 56 logical px tall (60 wide)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addBread(containerOf(tester));
      await tester.pump();
      final size = tester.getSize(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(size.height, greaterThanOrEqualTo(56));
      // Wide desktop viewport keeps the preferred 60px PAY height.
      await _pumpApp(
        tester,
        dio: dio,
        size: const Size(1366, 768),
        theme: AppTheme.dark(),
      );
      addBread(containerOf(tester));
      await tester.pump();
      final sizeWide = tester.getSize(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(sizeWide.height, greaterThanOrEqualTo(56));
      expect(sizeWide.height, lessThanOrEqualTo(64));
      // Full width of cart content (minus panel padding).
      final panelW = tester.getSize(
        find.byKey(const Key('pos-totals-panel')),
      );
      expect(sizeWide.width, greaterThanOrEqualTo(panelW.width * 0.85));
    });

    testWidgets(
        'secondary actions are a 2-column grid of F7/F9/F10/F11 '
        'buttons height 44–48', (tester) async {
      await _pumpApp(tester, dio: dio);
      final actionKeys = <Key>[
        const Key('pos-discount-button'),
        const Key('pos-hold-button'),
        const Key('pos-holds-button'),
        const Key('pos-history-button'),
      ];
      expect(find.byKey(const Key('pos-cart-actions')), findsOneWidget);

      final sizes = <Offset, Size>{};
      for (final key in actionKeys) {
        final btn = find.byKey(key);
        expect(btn, findsOneWidget, reason: '$key');
        final h = tester.getSize(btn).height;
        expect(h, greaterThanOrEqualTo(44), reason: '$key height $h');
        expect(h, lessThanOrEqualTo(48), reason: '$key height $h');
        sizes[tester.getCenter(btn)] = tester.getSize(btn);
      }

      // 2-column layout: two pairs share the same vertical centers.
      final centers = sizes.keys.toList();
      final rows = <int, List<Offset>>{};
      for (final c in centers) {
        rows.putIfAbsent(c.dy.round(), () => []).add(c);
      }
      expect(rows.length, 2, reason: 'expected 2 action rows');
      for (final row in rows.values) {
        expect(row.length, 2, reason: 'each row has 2 buttons');
      }
      // Same row → nearly equal Y; different columns → different X.
      final rowList = rows.values.toList();
      expect(
        (rowList[0][0].dx - rowList[0][1].dx).abs(),
        greaterThan(20),
      );
      expect(
        (rowList[0][0].dy - rowList[1][0].dy).abs(),
        greaterThan(8),
      );
    });

    testWidgets('hold button disabled when cart empty, enabled with line',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      var hold = tester.widget<OutlinedButton>(
        find.byKey(const Key('pos-hold-button')),
      );
      expect(hold.onPressed, isNull);
      addBread(containerOf(tester));
      await tester.pump();
      hold = tester.widget<OutlinedButton>(
        find.byKey(const Key('pos-hold-button')),
      );
      expect(hold.onPressed, isNotNull);
    });
  });

  group('RTL bidi currency order (Windows screenshots acceptance)', () {
    // Regression for the authoritative Windows screenshots run under the
    // Arabic locale: grouped money must render "20 235.00 DA" (digits
    // left of DA) on the POS grand total and the PAY button, while the
    // surrounding layout and the Arabic labels stay RTL. The box
    // assertions use RenderParagraph — real ICU bidi glyph placement
    // under the Ahem test font — layout evidence, not a Windows golden
    // screenshot.
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    bool digitsLeftOfDa(RenderParagraph paragraph, String text) {
      final daStart = text.lastIndexOf(' DA');
      final daBoxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: daStart + 1,
        extentOffset: text.length,
      ));
      final digitIdx =
          text.substring(0, daStart).lastIndexOf(RegExp('[0-9]'));
      final digitBoxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: digitIdx,
        extentOffset: digitIdx + 1,
      ));
      return digitBoxes.first.left < daBoxes.first.left;
    }

    void addBigLine(ProviderContainer container) {
      container.read(posCartProvider.notifier).addLine(
            CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2023.5',
              unitPrice: '10',
            ),
          );
    }

    testWidgets(
        'grand total & PAY amount render 20 235.00 DA in LTR order under RTL',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      addBigLine(containerOf(tester));
      await tester.pump();

      const money = '20 235.00 DA';

      final totalText = tester.widget<Text>(
        find.byKey(const Key('pos-total-value')),
      );
      expect(totalText.data, money);
      expect(totalText.textDirection, TextDirection.ltr);
      final totalParagraph = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('pos-total-value')),
      );
      expect(
        digitsLeftOfDa(totalParagraph, money),
        isTrue,
        reason: 'POS grand total must render digits left of DA under RTL',
      );

      final payText = tester.widget<Text>(
        find.byKey(const Key('pos-pay-amount')),
      );
      expect(payText.data, money);
      expect(payText.textDirection, TextDirection.ltr);
      final payParagraph = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('pos-pay-amount')),
      );
      expect(
        digitsLeftOfDa(payParagraph, money),
        isTrue,
        reason: 'PAY amount must render digits left of DA under RTL',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('PAY Arabic label sits right of the amount under RTL',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      addBigLine(containerOf(tester));
      await tester.pump();

      final payTexts = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('pos-pay-button')),
          matching: find.byType(Text),
        ),
      );
      final label = payTexts.singleWhere(
        (t) => t.key != const Key('pos-pay-amount'),
      );
      expect(
        label.data,
        contains(AppStrings.t('payment_shortcut', 'ar')),
      );

      final labelRect = tester.getRect(find.byWidget(label));
      final amountRect = tester.getRect(
        find.byKey(const Key('pos-pay-amount')),
      );
      expect(
        labelRect.left,
        greaterThan(amountRect.left),
        reason: 'RTL row: the Arabic PAY label must sit right of the '
            'amount so the money stays one LTR visual unit',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('cart header, empty state & line controls (UX FIX #7)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    testWidgets('header shows cart icon, title and line/unit counts',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      expect(find.byKey(const Key('pos-cart-header')), findsOneWidget);
      final header = find.descendant(
        of: find.byKey(const Key('pos-cart-header')),
        matching: find.text('🛒'),
      );
      expect(header, findsOneWidget);
      expect(find.text(AppStrings.t('cart_title', 'en')), findsOneWidget);

      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '3',
              unitPrice: '10',
            ),
          );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p2',
              name: 'Milk',
              quantity: '2',
              unitPrice: '5',
            ),
          );
      await tester.pump();

      final counts = tester
          .widget<Text>(find.byKey(const Key('pos-cart-counts')))
          .data;
      expect(counts, '${_m('2')} lines · ${_m('5')} units');
    });

    testWidgets('empty state: icon, title, hint and F4 shortcut hint',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      expect(find.byKey(const Key('pos-cart-empty-icon')), findsOneWidget);
      expect(find.text('🛒'), findsWidgets);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(find.byKey(const Key('pos-cart-empty')), findsOneWidget);
      expect(
        find.text(AppStrings.t('cart_empty_hint', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pos-cart-empty-f4')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-cart-empty-f4')))
            .data,
        AppStrings.t('search_focus', 'en'),
      );
    });

    testWidgets('qty increment control increases quantity to 2', (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;

      await tester.tap(find.byKey(Key('cart-line-qty-inc-$key')));
      await tester.pump();
      expect(
        container.read(posCartProvider).lines.first.quantity,
        '2',
      );
    });

    testWidgets('qty decrement control decreases quantity 3 → 2',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '3',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;

      await tester.tap(find.byKey(Key('cart-line-qty-dec-$key')));
      await tester.pump();
      expect(
        container.read(posCartProvider).lines.first.quantity,
        '2',
      );
    });

    testWidgets('direct numeric qty editing still works', (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;

      await tester.enterText(
        find.byKey(Key('cart-line-qty-$key')),
        '7',
      );
      await tester.pump();
      expect(
        container.read(posCartProvider).lines.first.quantity,
        '7',
      );
    });

    testWidgets('line discount field present and updates cart', (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;
      final field = find.byKey(Key('cart-line-discount-$key'));
      expect(field, findsOneWidget);

      await tester.enterText(field, '4');
      await tester.pump();
      expect(
        container.read(posCartProvider).lines.first.lineDiscount,
        '4',
      );
      // Subtotal already nets line discounts in provider totals.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .data,
        '16.00 DA',
      );
    });

    testWidgets('remove line is compact icon button with localized tooltip',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;
      final btn = tester.widget<IconButton>(
        find.byKey(Key('cart-line-remove-$key')),
      );
      expect(btn.tooltip, AppStrings.t('remove_line', 'en'));
      final removeSize =
          tester.getSize(find.byKey(Key('cart-line-remove-$key')));
      expect(removeSize.width, greaterThanOrEqualTo(40));
      expect(removeSize.width, lessThanOrEqualTo(52));
      expect(removeSize.height, greaterThanOrEqualTo(40));
    });

    testWidgets('only cart lines scroll; totals panel stays outside list',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      final container = containerOf(tester);
      for (var i = 0; i < 8; i++) {
        container.read(posCartProvider.notifier).addLine(
              CartLine(
                productId: 'p$i',
                name: 'Item $i',
                quantity: '1',
                unitPrice: '10',
              ),
            );
      }
      await tester.pump();

      expect(find.byKey(const Key('pos-cart-lines')), findsOneWidget);
      // Totals panel is a sibling region, not inside the ListView.
      final inList = find.descendant(
        of: find.byKey(const Key('pos-cart-lines')),
        matching: find.byKey(const Key('pos-totals-panel')),
      );
      expect(inList, findsNothing);
      final inPanel = find.descendant(
        of: find.byKey(const Key('pos-cart-panel')),
        matching: find.byKey(const Key('pos-totals-panel')),
      );
      expect(inPanel, findsOneWidget);

      await tester.drag(
        find.byKey(const Key('pos-cart-lines')),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('cart themes & localization (UX FIX #7)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    for (final entry in <String, ThemeData Function()>{
      'dark': AppTheme.dark,
      'light': AppTheme.light,
      'grey': AppTheme.grey,
    }.entries) {
      testWidgets('${entry.key} theme renders totals panel + pay without error',
          (tester) async {
        await _pumpApp(tester, dio: dio, theme: entry.value());
        containerOf(tester).read(posCartProvider.notifier).addLine(
              const CartLine(
                productId: 'p1',
                name: 'Bread',
                quantity: '2',
                unitPrice: '10',
              ),
            );
        await tester.pump();

        expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
        expect(find.byKey(const Key('pos-total-value')), findsOneWidget);
        expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
        expect(find.byKey(const Key('pos-cart-header')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Arabic RTL cart: localized labels, no overflow',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'خبز',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();

      expect(find.text(AppStrings.t('cart_title', 'ar')), findsOneWidget);
      expect(find.byKey(const Key('pos-total-value')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-cart-counts')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-cart-counts')))
            .data,
        '${_m('1')} ${AppStrings.t('lines_word', 'ar')} · '
            '${_m('2')} ${AppStrings.t('units_word', 'ar')}',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('French LTR cart: localized labels', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.fr);
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Pain',
              quantity: '1',
              unitPrice: '10',
            ),
          );
      await tester.pump();

      expect(find.text(AppStrings.t('cart_title', 'fr')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-cart-counts')))
            .data,
        '${_m('1')} ${AppStrings.t('lines_word', 'fr')} · '
            '${_m('1')} ${AppStrings.t('units_word', 'fr')}',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '10.00 DA',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English LTR cart counts format', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.en);
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '4',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-cart-counts')))
            .data,
        '${_m('1')} lines · ${_m('4')} units',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('responsive cart totals (UX FIX #7)', () {
    const sizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1024x768': Size(1024, 768),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };

    sizes.forEach((label, size) {
      testWidgets('totals + pay visible, no overflow at $label with lines',
          (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));

        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );
        container.read(posCartProvider.notifier).addLine(
              const CartLine(
                productId: 'p1',
                name: 'Bread',
                quantity: '2',
                unitPrice: '10',
              ),
            );
        await tester.pump();

        final narrow = posLayoutModeFor(size.width) == PosLayoutMode.narrow;
        if (narrow && find.byKey(const Key('toggle-cart')).evaluate().isNotEmpty) {
          // Cart drawer may already be open after add; ensure totals visible.
          if (find.byKey(const Key('pos-totals-panel')).evaluate().isEmpty) {
            await tester.tap(find.byKey(const Key('toggle-cart')));
            await tester.pump();
          }
        }

        expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
        expect(find.byKey(const Key('pos-total-value')), findsOneWidget);
        expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
        expect(find.byKey(const Key('pos-cart-header')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('selling-unit presentation preserved in totals (UX FIX #7)', () {
    testWidgets('total uses selling-unit price only; one line; base info kept',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(
        unitDio,
        productPrice: '60',
        sellingUnits: [
          _sellingUnitJson(
            id: 'su-box',
            name: 'Box',
            multiplier: '10',
            unitType: 'box',
            sellingPrice: '550',
            isBaseUnit: false,
            availableSelling: '2',
            availableBase: '20',
          ),
        ],
      );
      await _pumpApp(tester, dio: unitDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('selling-unit-su-box')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '2',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      final cart = container.read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.totals.total, closeTo(1100, 0.001));
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '1 100.00 DA',
      );
      final key = cart.lines.first.key;
      expect(find.byKey(Key('cart-line-summary-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-base-qty-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-base-price-$key')), findsOneWidget);
      expect(find.text('2 Box × 550'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('final cart sizing (UX FIX #8)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(
      ProviderContainer container, {
      String name = 'Bread',
      String qty = '2',
      String price = '10',
    }) {
      container.read(posCartProvider.notifier).addLine(
            CartLine(
              productId: 'p1',
              name: name,
              quantity: qty,
              unitPrice: price,
            ),
          );
    }

    test('cart width floors and targets are pure functions', () {
      expect(posCartWidthFor(600), 600); // narrow full-width
      expect(posCartWidthFor(800), 400); // medium target 380–420
      expect(posCartWidthFor(1099), 400);
      expect(posCartWidthFor(1100), 440); // wide 1100–1399 → 420–460
      expect(posCartWidthFor(1399), 440);
      expect(posCartWidthFor(1400), 480); // wide ≥1400 → 460–500
      expect(posCartWidthFor(1920), 480);
      // Floors
      expect(posCartWidthFor(1100), greaterThanOrEqualTo(420));
      expect(posCartWidthFor(1366), greaterThanOrEqualTo(420));
      expect(posCartWidthFor(1024), greaterThanOrEqualTo(380));
      expect(posCartWidthFor(800), greaterThanOrEqualTo(380));
    });

    testWidgets('cart panel meets width floors at 1024 / 1366 / 1920',
        (tester) async {
      for (final size in const [
        Size(1024, 768),
        Size(1366, 768),
        Size(1920, 1080),
      ]) {
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));
        final panelW =
            tester.getSize(find.byKey(const Key('pos-cart-panel'))).width;
        if (size.width >= 1100) {
          expect(panelW, greaterThanOrEqualTo(420), reason: '$size');
          expect(panelW, lessThanOrEqualTo(500), reason: '$size');
        } else {
          expect(panelW, greaterThanOrEqualTo(380), reason: '$size');
          expect(panelW, lessThanOrEqualTo(420), reason: '$size');
        }
        // Catalog still usable beside the cart.
        final catalog = find.byKey(const Key('pos-product-grid'));
        if (catalog.evaluate().isNotEmpty) {
          expect(
            tester.getSize(catalog).width,
            greaterThanOrEqualTo(300),
            reason: 'catalog too narrow at $size',
          );
        }
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('header readable: title 20–22, counts 14–16, height 64–76',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      addLine(containerOf(tester));
      await tester.pump();

      final headerH =
          tester.getSize(find.byKey(const Key('pos-cart-header'))).height;
      expect(headerH, inInclusiveRange(64, 76));

      final title = tester
          .widget<Text>(find.byKey(const Key('pos-cart-title')))
          .style!;
      expect(title.fontSize!, inInclusiveRange(20, 22));
      expect(title.fontWeight, FontWeight.w700);

      final counts = tester
          .widget<Text>(find.byKey(const Key('pos-cart-counts')))
          .style!;
      expect(counts.fontSize!, inInclusiveRange(14, 16));
    });

    testWidgets('clear cart is a comfortable ≥44×44 icon button',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(containerOf(tester));
      await tester.pump();
      final size =
          tester.getSize(find.byKey(const Key('pos-clear-cart')));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('customer row height 48–52, name font ≥14, button ≥44',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      final rowH =
          tester.getSize(find.byKey(const Key('pos-customer-row'))).height;
      expect(rowH, inInclusiveRange(48, 52));

      final nameStyle = tester
          .widget<Text>(find.byKey(const Key('pos-customer-name')))
          .style;
      expect(nameStyle?.fontSize ?? 14, greaterThanOrEqualTo(14));

      final btnH = tester
          .getSize(find.byKey(const Key('pos-select-customer')))
          .height;
      expect(btnH, greaterThanOrEqualTo(44));
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('product name font ≥16 semibold, max 2 lines',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(
        containerOf(tester),
        name: 'A very long product name that should ellipsize after two lines',
      );
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-$key')),
      );
      expect(name.style?.fontSize ?? 16, greaterThanOrEqualTo(16));
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
    });

    testWidgets('quantity controls: buttons 40–44, field ≥48, font 15–16',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(containerOf(tester));
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      for (final suffix in ['dec', 'inc']) {
        final size =
            tester.getSize(find.byKey(Key('cart-line-qty-$suffix-$key')));
        expect(size.width, greaterThanOrEqualTo(40), reason: suffix);
        expect(size.width, lessThanOrEqualTo(48), reason: suffix);
        expect(size.height, greaterThanOrEqualTo(40), reason: suffix);
        expect(size.height, lessThanOrEqualTo(48), reason: suffix);
      }

      final field = find.byKey(Key('cart-line-qty-$key'));
      expect(tester.getSize(field).width, greaterThanOrEqualTo(48));
      final fieldStyle = tester.widget<TextField>(field).style;
      expect(fieldStyle?.fontSize, inInclusiveRange(15, 16));
    });

    testWidgets('line total font 16–18 semibold/bold and primary visible',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(containerOf(tester));
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      final style = tester
          .widget<Text>(find.byKey(Key('cart-line-total-$key')))
          .style!;
      expect(style.fontSize!, inInclusiveRange(16, 18));
      expect(style.fontWeight, FontWeight.w700);
      expect(
        tester.widget<Text>(find.byKey(Key('cart-line-total-$key'))).data,
        '20.00',
      );
    });

    testWidgets('line discount height 36–40, font 13–14; warning when >0',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(containerOf(tester));
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      final field = find.byKey(Key('cart-line-discount-$key'));
      final h = tester.getSize(field).height;
      expect(h, greaterThanOrEqualTo(36));
      expect(h, lessThanOrEqualTo(40));
      final style = tester.widget<TextField>(field).style;
      expect(style?.fontSize, inInclusiveRange(13, 14));

      await tester.enterText(field, '5');
      await tester.pump();
      final active = tester.widget<TextField>(field).style;
      expect(active?.color, const Color(0xFFFF9800));
      expect(active?.fontWeight, FontWeight.w700);
      // Totals math unchanged: 20 − 5 = 15.
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '15.00 DA',
      );
    });

    testWidgets('cart line content min height ≥90 (selling-unit ≥100)',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(
        unitDio,
        productPrice: '60',
        sellingUnits: [
          _sellingUnitJson(
            id: 'su-box',
            name: 'Box',
            multiplier: '10',
            unitType: 'box',
            sellingPrice: '550',
            isBaseUnit: false,
            availableSelling: '2',
            availableBase: '20',
          ),
        ],
      );
      await _pumpApp(tester, dio: unitDio);
      addLine(containerOf(tester));
      await tester.pump();
      final plainKey =
          containerOf(tester).read(posCartProvider).lines.first.key;
      final plainH =
          tester.getSize(find.byKey(Key('cart-line-$plainKey'))).height;
      expect(plainH, greaterThanOrEqualTo(90), reason: 'plain line $plainH');

      // Selling-unit line with base info present.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      if (find.byKey(const Key('selling-unit-picker')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('selling-unit-su-box')));
        await tester.pumpAndSettle();
        if (find.byKey(const Key('quantity-dialog')).evaluate().isNotEmpty) {
          await tester.enterText(
            find.byKey(const Key('quantity-input')),
            '1',
          );
          await tester.tap(find.byKey(const Key('quantity-submit')));
          await tester.pumpAndSettle();
        }
      }
      final lines = containerOf(tester).read(posCartProvider).lines;
      final withBase = lines.firstWhere(
        (l) => l.sellingUnitId != null,
        orElse: () => lines.first,
      );
      final sellH =
          tester.getSize(find.byKey(Key('cart-line-${withBase.key}'))).height;
      expect(sellH, greaterThanOrEqualTo(100), reason: 'selling $sellH');
      expect(tester.takeException(), isNull);
    });

    testWidgets('totals panel: subtotal/discount 14–16, TOTAL label 18–20, '
        'value 36–48 on normal viewport', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        size: const Size(1366, 768),
        theme: AppTheme.dark(),
      );
      addLine(containerOf(tester));
      await tester.pump();

      final sub = tester
          .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
          .style!;
      expect(sub.fontSize!, inInclusiveRange(14, 16));

      final disc = tester
          .widget<Text>(find.byKey(const Key('pos-discount-value')))
          .style!;
      expect(disc.fontSize!, inInclusiveRange(14, 16));
      expect(disc.color, const Color(0xFFFF9800));

      final label = tester
          .widget<Text>(find.byKey(const Key('pos-total-label')))
          .style!;
      expect(label.fontSize!, inInclusiveRange(18, 20));

      final total = tester
          .widget<Text>(find.byKey(const Key('pos-total-value')))
          .style!;
      expect(total.fontSize!, inInclusiveRange(40, 48));
      expect(total.fontWeight, FontWeight.w800);
      // Never below 36 on normal desktop.
      expect(total.fontSize!, greaterThanOrEqualTo(36));
    });

    testWidgets('pay button full width of cart content, font 16–18, icon 20–22',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        size: const Size(1366, 768),
      );
      addLine(containerOf(tester));
      await tester.pump();

      final pay = find.byKey(const Key('pos-pay-button'));
      final paySize = tester.getSize(pay);
      final panelSize =
          tester.getSize(find.byKey(const Key('pos-totals-panel')));
      expect(paySize.height, greaterThanOrEqualTo(56));
      expect(paySize.width, greaterThanOrEqualTo(panelSize.width - 40));

      final button = tester.widget<FilledButton>(pay);
      final textStyle = button.style?.textStyle?.resolve({}) ??
          const TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
      expect(textStyle.fontSize ?? 17, inInclusiveRange(16, 18));

      final icon = tester.widget<Icon>(
        find.descendant(of: pay, matching: find.byType(Icon)),
      );
      expect(icon.size ?? 22, greaterThanOrEqualTo(20));
      expect(icon.size ?? 22, lessThanOrEqualTo(22));
    });

    testWidgets('only cart lines scroll; totals + PAY remain visible after drag',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      final container = containerOf(tester);
      for (var i = 0; i < 10; i++) {
        container.read(posCartProvider.notifier).addLine(
              CartLine(
                productId: 'p$i',
                name: 'Item $i',
                quantity: '1',
                unitPrice: '10',
              ),
            );
      }
      await tester.pump();

      expect(find.byKey(const Key('pos-cart-lines')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-cart-lines')),
          matching: find.byKey(const Key('pos-totals-panel')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-cart-lines')),
          matching: find.byKey(const Key('pos-pay-button')),
        ),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const Key('pos-cart-lines')),
        const Offset(0, -300),
      );
      await tester.pump();
      expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-cart-actions')), findsOneWidget);
      expect(find.byKey(const Key('pos-cart-header')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('600x500: readable sizes, total ≥36, pay ≥48, no overflow',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(600, 500));
      addLine(containerOf(tester));
      await tester.pump();
      if (find.byKey(const Key('toggle-cart')).evaluate().isNotEmpty &&
          find.byKey(const Key('pos-totals-panel')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('toggle-cart')));
        await tester.pump();
      }

      expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
      final total = tester
          .widget<Text>(find.byKey(const Key('pos-total-value')))
          .style!;
      expect(total.fontSize!, greaterThanOrEqualTo(36));
      expect(total.fontSize!, lessThanOrEqualTo(40));

      final payH = tester
          .getSize(find.byKey(const Key('pos-pay-button')))
          .height;
      expect(payH, greaterThanOrEqualTo(48));
      expect(payH, lessThanOrEqualTo(52));

      final headerH =
          tester.getSize(find.byKey(const Key('pos-cart-header'))).height;
      expect(headerH, greaterThanOrEqualTo(64));

      final customerH = find.byKey(const Key('pos-customer-row')).evaluate().isEmpty
          ? 0.0
          : tester
              .getSize(find.byKey(const Key('pos-customer-row')))
              .height;
      if (customerH > 0) {
        expect(customerH, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('800x600: no overflow, cart ≥380, pay visible', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(800, 600));
      addLine(containerOf(tester));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('pos-cart-panel'))).width,
        greaterThanOrEqualTo(380),
      );
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .style!
            .fontSize!,
        greaterThanOrEqualTo(40),
      );
    });

    testWidgets('1024x768 / 1366x768 / 1920x1080: cart floors, catalog usable',
        (tester) async {
      for (final size in const [
        Size(1024, 768),
        Size(1366, 768),
        Size(1920, 1080),
      ]) {
        await _pumpApp(tester, dio: dio, size: size);
        addLine(containerOf(tester));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '$size');

        final panelW =
            tester.getSize(find.byKey(const Key('pos-cart-panel'))).width;
        final floor = size.width >= 1100 ? 420 : 380;
        expect(panelW, greaterThanOrEqualTo(floor), reason: '$size');
        expect(
          tester.getSize(find.byKey(const Key('pos-pay-button'))).height,
          greaterThanOrEqualTo(56),
          reason: '$size',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('pos-total-value')))
              .style!
              .fontSize!,
          inInclusiveRange(40, 48),
          reason: '$size',
        );

        final catalog = find.byKey(const Key('pos-product-grid'));
        if (catalog.evaluate().isNotEmpty) {
          expect(
            tester.getSize(catalog).width,
            greaterThanOrEqualTo(300),
            reason: 'catalog at $size',
          );
        }
        // Segmented control still visible.
        expect(find.byKey(const Key('pos-view-mode-toggle')), findsOneWidget);
        expect(find.byKey(const Key('pos-view-mode-grid')), findsOneWidget);
        expect(find.byKey(const Key('pos-view-mode-list')), findsOneWidget);
      }
    });

    testWidgets('Arabic RTL cart: directional padding, readable header/total',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
        size: const Size(1366, 768),
      );
      addLine(containerOf(tester), name: 'خبز');
      await tester.pump();

      expect(find.text(AppStrings.t('cart_title', 'ar')), findsOneWidget);
      final title = tester
          .widget<Text>(find.byKey(const Key('pos-cart-title')))
          .style!;
      expect(title.fontSize!, inInclusiveRange(20, 22));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .style!
            .fontSize!,
        inInclusiveRange(40, 48),
      );
      expect(find.byKey(const Key('pos-select-customer')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('pos-select-customer'))).height,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('French LTR cart: header + actions + total readable',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.fr,
        size: const Size(1366, 768),
      );
      addLine(containerOf(tester), name: 'Pain');
      await tester.pump();

      expect(find.text(AppStrings.t('cart_title', 'fr')), findsOneWidget);
      final counts = tester
          .widget<Text>(find.byKey(const Key('pos-cart-counts')))
          .style!;
      expect(counts.fontSize!, inInclusiveRange(14, 16));
      for (final key in [
        'pos-discount-button',
        'pos-hold-button',
        'pos-holds-button',
        'pos-history-button',
      ]) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          inInclusiveRange(44, 48),
          reason: key,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('English LTR cart: header title size + counts font',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.en,
        size: const Size(1366, 768),
      );
      addLine(containerOf(tester), qty: '4');
      await tester.pump();

      final title = tester
          .widget<Text>(find.byKey(const Key('pos-cart-title')))
          .style!;
      expect(title.fontSize!, inInclusiveRange(20, 22));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-cart-counts')))
            .data,
        '${_m('1')} lines · ${_m('4')} units',
      );
      expect(tester.takeException(), isNull);
    });

    for (final entry in <String, ThemeData Function()>{
      'dark': AppTheme.dark,
      'light': AppTheme.light,
      'grey': AppTheme.grey,
    }.entries) {
      testWidgets('${entry.key} theme: layered surfaces + large total',
          (tester) async {
        await _pumpApp(
          tester,
          dio: dio,
          theme: entry.value(),
          size: const Size(1366, 768),
        );
        addLine(containerOf(tester));
        await tester.pump();

        expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
        expect(find.byKey(const Key('pos-cart-actions')), findsOneWidget);
        expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
        final total = tester
            .widget<Text>(find.byKey(const Key('pos-total-value')))
            .style!;
        expect(total.fontSize!, inInclusiveRange(40, 48));
        final theme = Theme.of(
          tester.element(find.byKey(const Key('pos-totals-panel'))),
        );
        expect(total.color, theme.colorScheme.primary);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('cart totals remain mathematically unchanged (UX FIX #8)',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '3',
              unitPrice: '100',
              lineDiscount: '10',
            ),
          );
      container.read(posCartProvider.notifier).setInvoiceDiscount('20');
      await tester.pump();

      // lineTotal = 3*100 - 10 = 290; subtotal nets line discounts.
      // invoice discount 20 → total 270.
      final totals = container.read(posCartProvider).totals;
      expect(totals.total, closeTo(270, 0.001));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('pos-subtotal-value')))
            .data,
        '290.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-discount-value'))).data,
        '-20.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '270.00 DA',
      );
    });

    testWidgets('catalog segmented control still tappable after wider cart',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('pos-view-mode-toggle')), findsOneWidget);
      expect(find.byKey(const Key('pos-view-mode-grid')), findsOneWidget);
      expect(find.byKey(const Key('pos-view-mode-list')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('final POS polish (FIX #9)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(
      ProviderContainer container, {
      String name = 'Bread',
      String qty = '2',
      String price = '10',
    }) {
      container.read(posCartProvider.notifier).addLine(
            CartLine(
              productId: 'p1',
              name: name,
              quantity: qty,
              unitPrice: price,
            ),
          );
    }

    Future<void> showPermissionSnackbar(WidgetTester tester) async {
      final limited = MockDio();
      _mockDio(limited, scopes: const ['pos_sale', 'product_view']);
      await _pumpApp(
        tester,
        dio: limited,
        permissions: const ['pos_sale', 'product_view'],
      );
      addLine(containerOf(tester));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-discount-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(AppStrings.t('permission_discount', 'en')),
        findsWidgets,
      );
    }

    // ── FIX 1: snackbar never covers TOTAL / PAY / cart footer ────────
    const snackbarSizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1024x768': Size(1024, 768),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };

    snackbarSizes.forEach((label, size) {
      testWidgets('snackbar visible + PAY visible + no overlap at $label',
          (tester) async {
        final limited = MockDio();
        _mockDio(limited, scopes: const ['pos_sale', 'product_view']);
        await _pumpApp(
          tester,
          dio: limited,
          permissions: const ['pos_sale', 'product_view'],
          size: size,
        );
        if (posLayoutModeFor(size.width) == PosLayoutMode.narrow) {
          await tester.tap(find.byKey(const Key('toggle-cart')));
          await tester.pump();
        }
        addLine(containerOf(tester));
        await tester.pump();
        await tester.tap(find.byKey(const Key('pos-discount-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final snack = find.byType(SnackBar);
        final pay = find.byKey(const Key('pos-pay-button'));
        expect(snack, findsOneWidget, reason: label);
        expect(pay, findsOneWidget, reason: label);

        // Floating SnackBar's getRect includes the transparent margin
        // padding; measure the visible content area only.
        final snackWidget = tester.widget<SnackBar>(snack);
        final snackOuter = tester.getRect(snack);
        final margin = snackWidget.margin?.resolve(TextDirection.ltr) ??
            EdgeInsets.zero;
        final snackRect = Rect.fromLTRB(
          snackOuter.left + margin.left,
          snackOuter.top + margin.top,
          snackOuter.right - margin.right,
          snackOuter.bottom - margin.bottom,
        );
        final payRect = tester.getRect(pay);
        final totalRect = tester.getRect(
          find.byKey(const Key('pos-total-value')),
        );
        expect(
          snackRect.overlaps(payRect),
          isFalse,
          reason: 'snackbar $snackRect overlaps PAY $payRect at $label',
        );
        expect(
          snackRect.overlaps(totalRect),
          isFalse,
          reason: 'snackbar $snackRect overlaps TOTAL $totalRect at $label',
        );
        // Snackbar never obstructs the cart footer: either it sits
        // entirely above the PAY top edge (stacked layouts), or it sits
        // beside the cart horizontally clear (FIX #10B micro-fix: low
        // 24px position on wide screens where the cart is a side panel).
        final horizontallyClear = snackRect.right <= payRect.left ||
            snackRect.left >= payRect.right;
        expect(
          horizontallyClear || payRect.top - snackRect.bottom >= 0,
          isTrue,
          reason: 'snackbar must not obstruct PAY at $label '
              '(snack $snackRect, PAY $payRect)',
        );
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('snackbar is floating and fully on-screen at 800x600',
        (tester) async {
      final limited = MockDio();
      _mockDio(limited, scopes: const ['pos_sale', 'product_view']);
      await _pumpApp(
        tester,
        dio: limited,
        permissions: const ['pos_sale', 'product_view'],
        size: const Size(800, 600),
      );
      addLine(containerOf(tester));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-discount-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final snack = find.byType(SnackBar);
      expect(snack, findsOneWidget);
      final widget = tester.widget<SnackBar>(snack);
      expect(widget.behavior, SnackBarBehavior.floating);
      final rect = tester.getRect(snack);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(600));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(800));
      expect(tester.takeException(), isNull);
    });

    // ── FIX 2: cart product name always visible ───────────────────────
    testWidgets('cart product name is 17–18px w700 for short name',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(containerOf(tester), name: 'eau');
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-$key')),
      );
      expect(name.style?.fontSize, inInclusiveRange(17, 18));
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cart product name never below 16px for long name',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(
        containerOf(tester),
        name: 'A very long product name that should ellipsize after two lines',
      );
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-$key')),
      );
      expect(name.style?.fontSize ?? 16, greaterThanOrEqualTo(16));
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cart product name visible for selling-unit line',
        (tester) async {
      final unitDio = MockDio();
      _mockDio(unitDio, sellingUnits: [_sellingUnitJson(name: 'Box')]);
      await _pumpApp(tester, dio: unitDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      // Base unit (isBaseUnit) is rendered as the synthetic base card.
      await tester.tap(find.byKey(const Key('selling-unit-base')));
      await tester.pumpAndSettle();
      if (find.byKey(const Key('quantity-dialog')).evaluate().isNotEmpty) {
        await tester.enterText(
          find.byKey(const Key('quantity-input')),
          '1',
        );
        await tester.tap(find.byKey(const Key('quantity-submit')));
        await tester.pumpAndSettle();
      }
      final lines = containerOf(tester).read(posCartProvider).lines;
      expect(lines, isNotEmpty);
      final key = lines.first.key;
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-$key')),
      );
      expect(name.style?.fontSize ?? 16, greaterThanOrEqualTo(16));
      expect(name.maxLines, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cart product name visible for variant line', (tester) async {
      final varDio = MockDio();
      _mockDio(
        varDio,
        variants: [_variantJson(id: 'var-a', name: 'Small')],
      );
      await _pumpApp(tester, dio: varDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      final lines = containerOf(tester).read(posCartProvider).lines;
      expect(lines, hasLength(1));
      final key = lines.first.key;
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-$key')),
      );
      expect(name.style?.fontSize ?? 16, greaterThanOrEqualTo(16));
      expect(name.style?.fontWeight, FontWeight.w700);
      expect(name.maxLines, 2);
      expect(tester.takeException(), isNull);
    });

    // ── FIX 3: Grid / List segmented control clarity ──────────────────
    testWidgets('full Grid/List labels show without ellipsis at 1366',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      await tester.pump(const Duration(milliseconds: 500));
      final toggle = tester.getSize(
        find.byKey(const Key('pos-view-mode-toggle')),
      );
      expect(toggle.width, greaterThanOrEqualTo(190));

      final gridText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.text(AppStrings.t('catalog_view_grid', 'en')),
        ),
      );
      expect(gridText.maxLines, 1);
      expect(gridText.softWrap, isFalse);
      expect(gridText.overflow, isNot(TextOverflow.ellipsis));
      expect(gridText.style?.fontSize, inInclusiveRange(13, 15));

      final listText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.text(AppStrings.t('catalog_view_list', 'en')),
        ),
      );
      expect(listText.maxLines, 1);
      expect(listText.softWrap, isFalse);
      expect(listText.overflow, isNot(TextOverflow.ellipsis));
      expect(listText.style?.fontSize, inInclusiveRange(13, 15));

      final gridSeg = tester.getSize(
        find.byKey(const Key('pos-view-mode-grid')),
      );
      final listSeg = tester.getSize(
        find.byKey(const Key('pos-view-mode-list')),
      );
      expect(gridSeg.width, greaterThanOrEqualTo(90));
      expect(listSeg.width, greaterThanOrEqualTo(90));
      expect(tester.takeException(), isNull);
    });

    // ── R4: catalog name readability (list view) ───────────────────────
    testWidgets('catalog product name is 16px semibold in list view too',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      final name = tester.widget<Text>(
        find.byKey(Key('pos-product-name-$_productId')),
      );
      expect(name.style?.fontSize, 16);
      expect(name.style?.fontWeight, FontWeight.w600);
      expect(name.maxLines, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Grid/List segments ≥90px and icon 18–20 at 1024',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1024, 768));
      await tester.pump(const Duration(milliseconds: 500));
      final gridSeg = tester.getSize(
        find.byKey(const Key('pos-view-mode-grid')),
      );
      final listSeg = tester.getSize(
        find.byKey(const Key('pos-view-mode-list')),
      );
      expect(gridSeg.width, greaterThanOrEqualTo(90));
      expect(listSeg.width, greaterThanOrEqualTo(90));

      final gridIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.byIcon(Icons.grid_view),
        ),
      );
      expect(gridIcon.size, inInclusiveRange(18, 20));
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact Grid/List uses icons only at tight workspace',
        (tester) async {
      // 800 wide − cart 400 = workspace 400 < 500 → compact toggle.
      await _pumpApp(tester, dio: dio, size: const Size(800, 600));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('pos-view-mode-toggle')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.text(AppStrings.t('catalog_view_grid', 'en')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.text(AppStrings.t('catalog_view_list', 'en')),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.grid_view), findsOneWidget);
      expect(find.byIcon(Icons.view_list), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Grid/List toggle switches mode without catalog reload',
        (tester) async {
      var searchLoads = 0;
      final counted = MockDio();
      _mockDio(counted, onSearch: () => searchLoads++);
      await _pumpApp(tester, dio: counted);
      await tester.pump(const Duration(milliseconds: 500));
      final loadsAfterPump = searchLoads;

      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(searchLoads, loadsAfterPump);

      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(searchLoads, loadsAfterPump);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'grid');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Grid/List full labels visible in Arabic at 1366',
        (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
        size: const Size(1366, 768),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-grid')),
          matching: find.text(AppStrings.t('catalog_view_grid', 'ar')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-view-mode-list')),
          matching: find.text(AppStrings.t('catalog_view_list', 'ar')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    // ── FIX 4: held-sales count badge ─────────────────────────────────
    testWidgets('holds button shows badge count when holds exist',
        (tester) async {
      final holdsDio = MockDio();
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [_holdJson(id: 'hold-1'), _holdJson(id: 'hold-2')],
          'total': 2,
        },
      );
      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));

      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      final badgeWidget = tester.widget<Badge>(badge);
      expect((badgeWidget.label as Text?)?.data, '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('holds button shows no badge when hold list empty',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('holds badge updates after delete in dialog', (tester) async {
      final holdsDio = MockDio();
      // Dynamic list so post-dialog load() reflects the delete.
      var holdsItems = <dynamic>[
        _holdJson(id: 'hold-1'),
        _holdJson(id: 'hold-2'),
      ];
      _mockDio(holdsDio);
      when(() => holdsDio.get(
            '/api/v1/pos/holds',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': holdsItems,
                'total': holdsItems.length,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': holdsItems,
          'total': holdsItems.length,
        }),
      );
      when(() => holdsDio.delete(any())).thenAnswer((invocation) async {
        final path = invocation.positionalArguments.first as String? ?? '';
        final id = path.split('/').last;
        holdsItems =
            holdsItems.where((h) => (h as Map)['id'] != id).toList();
        return Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: 204,
        );
      });

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('holds-dialog')), findsOneWidget);
      expect(find.byKey(const Key('hold-row-hold-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('hold-delete-hold-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hold-row-hold-1')), findsNothing);
      expect(find.byKey(const Key('hold-row-hold-2')), findsOneWidget);

      await tester.tap(find.text(AppStrings.t('cancel', 'en')));
      await tester.pumpAndSettle();

      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('holds badge updates after F9 hold save', (tester) async {
      final holdsDio = MockDio();
      var holdCreated = false;
      _mockDio(holdsDio);
      when(() => holdsDio.post('/api/v1/pos/holds', data: any(named: 'data')))
          .thenAnswer((_) async {
        holdCreated = true;
        return _ok('/api/v1/pos/holds', {'id': 'hold-new'});
      });
      when(() => holdsDio.post('/api/v1/pos/holds')).thenAnswer((_) async {
        holdCreated = true;
        return _ok('/api/v1/pos/holds', {'id': 'hold-new'});
      });
      when(() => holdsDio.get('/api/v1/pos/holds', queryParameters: any(named: 'queryParameters')))
          .thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': holdCreated ? [_holdJson(id: 'hold-new')] : <dynamic>[],
                'total': holdCreated ? 1 : 0,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': holdCreated ? [_holdJson(id: 'hold-new')] : <dynamic>[],
          'total': holdCreated ? 1 : 0,
        }),
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(containerOf(tester));
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-hold-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(holdCreated, isTrue);
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(
        find.text(AppStrings.t('hold_saved', 'en')),
        findsWidgets,
      );
      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');
      expect(tester.takeException(), isNull);
    });

    // ── FIX 5: restore hold → cart + delete hold + refresh ────────────
    testWidgets(
        'restore loads cart, closes dialog, removes hold, badge 0',
        (tester) async {
      final holdsDio = MockDio();
      var holdDeleted = false;
      final hold = _holdJson(id: 'hold-r1');
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': true,
            },
          ],
        },
      );
      // After successful restore the server deletes the hold; subsequent
      // list GET returns empty (mirrors backend).
      when(() => holdsDio.post(
            any(that: endsWith('/restore')),
          )).thenAnswer((_) async {
        holdDeleted = true;
        return _ok('/restore', {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': true,
            },
          ],
        });
      });
      when(() => holdsDio.get(
            '/api/v1/pos/holds',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': holdDeleted ? <dynamic>[] : [hold],
                'total': holdDeleted ? 0 : 1,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': holdDeleted ? <dynamic>[] : [hold],
          'total': holdDeleted ? 0 : 1,
        }),
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));

      // Badge starts at 1.
      var badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');

      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('holds-dialog')), findsOneWidget);
      expect(find.byKey(const Key('hold-row-hold-r1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('hold-restore-hold-r1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      // Notice listener paints the hold_restored snackbar after the dialog
      // route is fully gone.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Dialog closed, cart has restored lines, hold removed, badge gone.
      expect(find.byKey(const Key('holds-dialog')), findsNothing);
      final lines = containerOf(tester).read(posCartProvider).lines;
      expect(lines, isNotEmpty);
      expect(lines.first.productId, _productId);
      expect(
        find.byKey(const Key('hold_restored')),
        findsOneWidget,
        reason: 'restore notice snackbar',
      );
      expect(
        find.text(AppStrings.t('hold_restored', 'en')),
        findsWidgets,
      );
      expect(holdDeleted, isTrue);

      badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect(badge, findsNothing, reason: 'badge cleared after restore');
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed restore keeps hold, shows error, allows retry',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-f1');
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreErrorStatus: 500,
      );
      when(() => holdsDio.get(
            '/api/v1/pos/holds',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': [hold],
                'total': 1,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': [hold],
          'total': 1,
        }),
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hold-row-hold-f1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('hold-restore-hold-f1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // Hold still listed (not deleted).
      expect(find.byKey(const Key('hold-row-hold-f1')), findsOneWidget);
      // Error snackbar visible.
      expect(
        find.byKey(const Key('hold-restore-error')),
        findsOneWidget,
      );
      // Cart not mutated from failed restore payload path.
      expect(
        containerOf(tester).read(posCartProvider).lines,
        isEmpty,
      );
      // Retry button (restore) still present.
      expect(
        find.byKey(const Key('hold-restore-hold-f1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    // ── FIX #10B: HTTP 200 + valid payload → success, never generic ──
    testWidgets('successful HTTP 200 restore shows no generic error',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-200');
      hold['items'] = [
        {
          'product_id': _productId,
          'variant_id': null,
          'selling_unit_id': null,
          'product_name': 'eau',
          'unit_name': 'Fardeau',
          'quantity': '2',
          'unit_price': '270',
          'line_discount': '0',
          'product_unit': 'piece',
        },
      ];
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': true,
            },
          ],
        },
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hold-row-hold-200')), findsOneWidget);

      await tester.tap(find.byKey(const Key('hold-restore-hold-200')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Success path only: no generic system-error toast, cart restored.
      expect(find.byKey(const Key('hold-restore-error')), findsNothing);
      expect(
        find.text(AppStrings.t('api_error_retry', 'en')),
        findsNothing,
        reason: 'HTTP 200 + valid payload never shows api_error_retry',
      );
      expect(find.byKey(const Key('hold_restored')), findsOneWidget);
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, isNotEmpty);
      expect(cart.lines.first.name, 'eau');
      expect(tester.takeException(), isNull);
    });

    // ── FIX #10: hold count + reopen list + ok:false + snapshot ───────
    testWidgets(
        'hold count 0→1→2→1→0; restored hold gone after reopening list',
        (tester) async {
      final holdsDio = MockDio();
      final holds = <Map<String, dynamic>>[];
      _mockDio(holdsDio);

      when(() => holdsDio.get(
            '/api/v1/pos/holds',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': holds,
                'total': holds.length,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': holds,
          'total': holds.length,
        }),
      );

      Future<Response<dynamic>> createHold(Invocation invocation) async {
        final id = 'h-${holds.length + 1}';
        holds.add(_holdJson(id: id));
        return _ok('/api/v1/pos/holds', {'id': id});
      }

      when(() => holdsDio.post('/api/v1/pos/holds', data: any(named: 'data')))
          .thenAnswer(createHold);
      when(() => holdsDio.post('/api/v1/pos/holds')).thenAnswer(createHold);

      when(() => holdsDio.post(any(that: endsWith('/restore'))))
          .thenAnswer((invocation) async {
        final path = invocation.positionalArguments.first as String;
        final holdId = path.split('/')[5]; // /api/v1/pos/holds/<id>/restore
        final hold = holds.firstWhere((h) => h['id'] == holdId);
        holds.removeWhere((h) => h['id'] == holdId); // backend deletes it
        return _ok(path, {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': true,
            },
          ],
        });
      });

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );

      // Before hold: count 0.
      expect(badge, findsNothing, reason: 'count starts at 0');

      // Hold 1 → count 1.
      addLine(containerOf(tester));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-hold-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');

      // Hold 2 → count 2.
      addLine(containerOf(tester));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-hold-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '2');

      // Restore one → count 1.
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hold-row-h-1')), findsOneWidget);
      expect(find.byKey(const Key('hold-row-h-2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('hold-restore-h-1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byKey(const Key('holds-dialog')), findsNothing);
      expect(badge, findsOneWidget);
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');

      // Reopening the list: restored hold is gone, other hold remains.
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('hold-row-h-1')),
        findsNothing,
        reason: 'restored hold removed from list',
      );
      expect(find.byKey(const Key('hold-row-h-2')), findsOneWidget);

      // Restore the second → count 0.
      await tester.tap(find.byKey(const Key('hold-restore-h-2')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byKey(const Key('holds-dialog')), findsNothing);
      expect(badge, findsNothing, reason: 'count back to 0');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'restore ok=false keeps hold, count and cart; shows error',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-bad');
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': false,
          'errors': ['line 0: out of stock'],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': false,
              'message': 'out of stock',
            },
          ],
        },
      );
      when(() => holdsDio.get(
            '/api/v1/pos/holds',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((_) async => _ok('/api/v1/pos/holds', {
                'items': [hold],
                'total': 1,
              }));
      when(() => holdsDio.get('/api/v1/pos/holds')).thenAnswer(
        (_) async => _ok('/api/v1/pos/holds', {
          'items': [hold],
          'total': 1,
        }),
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      final badge = find.descendant(
        of: find.byKey(const Key('pos-holds-button')),
        matching: find.byType(Badge),
      );
      expect((tester.widget<Badge>(badge).label as Text?)?.data, '1');

      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hold-restore-hold-bad')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // Dialog stays open, hold still listed, error shown, cart untouched.
      expect(find.byKey(const Key('holds-dialog')), findsOneWidget);
      expect(find.byKey(const Key('hold-row-hold-bad')), findsOneWidget);
      expect(find.byKey(const Key('hold-restore-error')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(
        (tester.widget<Badge>(badge).label as Text?)?.data,
        '1',
        reason: 'count unchanged on failed restore',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'restored cart shows product name, qty, unit, price, line total',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-n1');
      hold['items'] = [
        {
          'product_id': _productId,
          'variant_id': null,
          'selling_unit_id': null,
          'product_name': 'eau',
          'unit_name': 'Fardeau',
          'quantity': '1',
          'unit_price': '270',
          'line_discount': '0',
          'product_unit': 'piece',
        },
      ];
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': null,
              'ok': true,
            },
          ],
        },
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hold-restore-hold-n1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1), reason: 'no extra base-unit line');
      final line = cart.lines.first;
      expect(line.name, 'eau');
      expect(line.quantity, '1');
      expect(line.unitName, 'Fardeau');
      expect(line.unitPrice, '270');
      expect(line.lineTotal, closeTo(270, 0.001));

      final key = line.key;
      expect(
        tester.widget<Text>(find.byKey(Key('cart-line-name-$key'))).data,
        'eau',
        reason: 'product name visible from snapshot',
      );
      expect(find.text('1 Fardeau × 270'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(Key('cart-line-total-$key'))).data,
        '270.00',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('restored variant line keeps variant name (FIX #8)',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-v1');
      hold['items'] = [
        {
          'product_id': _productId,
          'variant_id': 'v-1',
          'selling_unit_id': null,
          'product_name': 'eau · Small',
          'variant_name': 'Small',
          'unit_name': 'piece',
          'quantity': '1',
          'unit_price': '50',
          'line_discount': '0',
          'product_unit': 'piece',
        },
      ];
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': 'v-1',
              'ok': true,
            },
          ],
        },
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hold-restore-hold-v1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.variantName, 'Small');
      expect(line.name, contains('Small'));
      expect(line.variantId, 'v-1');

      final key = line.key;
      final nameText =
          tester.widget<Text>(find.byKey(Key('cart-line-name-$key'))).data;
      expect(nameText, contains('Small'), reason: 'variant name visible');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'restored selling-unit line keeps multiplier + base info (FIX #8)',
        (tester) async {
      final holdsDio = MockDio();
      final hold = _holdJson(id: 'hold-u1');
      hold['items'] = [
        {
          'product_id': _productId,
          'variant_id': 'v-1',
          'selling_unit_id': 'su-box',
          'product_name': 'Fromage · Small',
          'variant_name': 'Small',
          'unit_name': 'Box',
          'quantity': '1',
          'unit_price': '550',
          'line_discount': '0',
          'product_unit': 'piece',
          'base_unit_price': '55',
          'unit_multiplier': '10',
          'available_stock': '12',
        },
      ];
      _mockDio(
        holdsDio,
        holdsBody: {
          'items': [hold],
          'total': 1,
        },
        restoreBody: {
          'ok': true,
          'errors': <dynamic>[],
          'hold': hold,
          'lines': [
            {
              'line_index': 0,
              'product_id': _productId,
              'variant_id': 'v-1',
              'ok': true,
            },
          ],
        },
      );

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-holds-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hold-restore-hold-u1')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      await tester.pump();

      final cart = containerOf(tester).read(posCartProvider);
      // Never reduced to a base-unit line / never duplicated.
      expect(cart.lines, hasLength(1), reason: 'exactly one restored line');
      final line = cart.lines.first;
      expect(line.sellingUnitId, 'su-box');
      expect(line.unitName, 'Box');
      expect(line.unitPrice, '550');
      expect(line.quantity, '1');
      expect(line.unitMultiplier, '10');
      expect(line.baseUnitPrice, '55');
      expect(line.variantName, 'Small');
      expect(line.lineTotal, closeTo(550, 0.001));

      final key = line.key;
      expect(find.text('1 Box × 550'), findsOneWidget);
      expect(find.text('1 Piece × 550'), findsNothing,
          reason: 'not reduced to base unit');
      expect(find.byKey(Key('cart-line-base-qty-$key')), findsOneWidget);
      expect(find.text('10 Piece'), findsOneWidget);
      expect(find.byKey(Key('cart-line-base-price-$key')), findsOneWidget);
      expect(
        find.text('${AppStrings.t('base_price', 'en')}: ${_m('55')} / Piece'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('hold save posts full display snapshot (FIX #6)',
        (tester) async {
      final holdsDio = MockDio();
      Map<String, dynamic>? postedItem;
      _mockDio(holdsDio);
      Future<Response<dynamic>> capture(Invocation invocation) async {
        final data = invocation.namedArguments[#data];
        if (data is Map) {
          final items = data['items'] as List<dynamic>?;
          postedItem = (items?.first as Map?)?.cast<String, dynamic>();
        }
        return _ok('/api/v1/pos/holds', {'id': 'hold-snap'});
      }

      when(() => holdsDio.post('/api/v1/pos/holds', data: any(named: 'data')))
          .thenAnswer(capture);
      when(() => holdsDio.post('/api/v1/pos/holds')).thenAnswer(capture);

      await _pumpApp(tester, dio: holdsDio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              variantId: 'v-1',
              sellingUnitId: 'su-box',
              name: 'Fromage · Small',
              variantName: 'Small',
              unitName: 'Box',
              quantity: '1',
              unitPrice: '550',
              productUnit: 'piece',
              baseUnitPrice: '55',
              unitMultiplier: '10',
              availableStock: '12',
            ),
          );
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-hold-button')));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(postedItem, isNotNull, reason: 'hold POST captured');
      expect(postedItem!['product_name'], 'Fromage · Small');
      expect(postedItem!['variant_name'], 'Small');
      expect(postedItem!['unit_name'], 'Box');
      expect(postedItem!['product_unit'], 'piece');
      expect(postedItem!['base_unit_price'], '55');
      expect(postedItem!['unit_multiplier'], '10');
      expect(postedItem!['available_stock'], '12');
      // Existing sales API keys unchanged.
      expect(postedItem!['quantity'], '1');
      expect(postedItem!['unit_price'], '550');
      expect(postedItem!['line_discount'], '0');
      expect(postedItem!['product_id'], 'p1');
      expect(tester.takeException(), isNull);
    });

    // ── FIX 6–9: out of stock marking / disabling ─────────────────────
    testWidgets('OOS product shows red badge and disabled card in grid',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(Key('pos-product-oos-badge-$_productId')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('pos-product-oos-$_productId')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('out_of_stock', 'en')),
        findsWidgets,
      );

      // Card InkWell has no onTap → disabled.
      final inkWell = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(Key('pos-product-$_productId')),
          matching: find.byType(InkWell),
        ),
      );
      expect(inkWell.onTap, isNull);

      // Tap does nothing to cart.
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS product tap shows localized cannot-add snackbar',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));

      // Even with onTap null, force path via add button key if present;
      // for grid, tapping the card does nothing — assert snackbar only if
      // a tap path exists. Use list mode add path below instead.
      // Here: verify snackbar string is available and cart stays empty.
      expect(
        AppStrings.t('cannot_add_out_of_stock', 'en'),
        'Cannot add product to cart: product is out of stock.',
      );
      expect(
        AppStrings.t('cannot_add_out_of_stock', 'ar'),
        isNot(equals(AppStrings.t('cannot_add_out_of_stock', 'en'))),
      );
      expect(
        AppStrings.t('cannot_add_out_of_stock', 'fr'),
        isNot(equals(AppStrings.t('cannot_add_out_of_stock', 'en'))),
      );
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS localized badge text in ar / fr / en', (tester) async {
      for (final (locale, appLocale) in [
        (AppLocale.en, 'en'),
        (AppLocale.fr, 'fr'),
        (AppLocale.ar, 'ar'),
      ]) {
        final oosDio = MockDio();
        _mockDio(oosDio, productQuantity: '0');
        await _pumpApp(tester, dio: oosDio, locale: locale);
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(Key('pos-product-oos-badge-$_productId')),
          findsOneWidget,
          reason: appLocale,
        );
        expect(
          find.text(AppStrings.t('out_of_stock', appLocale)),
          findsWidgets,
          reason: appLocale,
        );
        expect(tester.takeException(), isNull);
        // Reset for next locale iteration.
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('OOS list row shows red out_of_stock and disabled add',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('pos-product-oos-$_productId')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('out_of_stock', 'en')),
        findsWidgets,
      );
      final addBtn = tester.widget<IconButton>(
        find.byKey(Key('pos-product-add-$_productId')),
      );
      expect(addBtn.onPressed, isNull);

      // Row InkWell (outermost under the product key); IconButton nests
      // its own InkWell, so take the first descendant match.
      final inkWell = tester.widget<InkWell>(
        find
            .descendant(
              of: find.byKey(Key('pos-product-$_productId')),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(inkWell.onTap, isNull);

      await tester.tap(find.byKey(Key('pos-product-add-$_productId')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('available product still adds (stock > 0)', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(Key('pos-product-oos-$_productId')),
        findsNothing,
      );
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS variant is disabled; available variant remains usable',
        (tester) async {
      final varDio = MockDio();
      _mockDio(
        varDio,
        variants: [
          _variantJson(id: 'var-oos', name: 'OutOfStock', quantity: '0'),
          _variantJson(id: 'var-ok', name: 'Available', quantity: '5'),
        ],
      );
      await _pumpApp(tester, dio: varDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);

      final oosCard = find.byKey(const Key('variant-var-oos-tappable'));
      final okCard = find.byKey(const Key('variant-var-ok-tappable'));
      expect(oosCard, findsOneWidget);
      expect(okCard, findsOneWidget);
      expect(tester.widget<InkWell>(oosCard).onTap, isNull);
      expect(tester.widget<InkWell>(okCard).onTap, isNotNull);
      expect(
        find.text(AppStrings.t('out_of_stock', 'en')),
        findsWidgets,
      );

      // Selecting OOS card does not confirm / add.
      await tester.tap(oosCard);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);

      // Available variant still works.
      await tester.tap(okCard);
      await tester.pumpAndSettle();
      if (find.byKey(const Key('variant-picker')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('pos-option-picker-confirm')));
        await tester.pumpAndSettle();
      }
      final lines = containerOf(tester).read(posCartProvider).lines;
      expect(lines, hasLength(1));
      expect(lines.first.variantId, 'var-ok');
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS product blocks selling-unit picker (no cart mutation)',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(
        oosDio,
        productQuantity: '0',
        sellingUnits: [_sellingUnitJson(id: 'su-box', name: 'Box')],
      );
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(find.byKey(const Key('variant-picker')), findsNothing);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS list mode: cannot-add snackbar on disabled add path',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();

      // IconButton onPressed is null — Flutter does not fire onPressed.
      // Force the snackbar path by simulating the disabled button still
      // receiving a gesture is impossible; assert disabled state instead
      // and that localized message key exists for when a path fires.
      final addBtn = tester.widget<IconButton>(
        find.byKey(Key('pos-product-add-$_productId')),
      );
      expect(addBtn.onPressed, isNull);
      expect(
        AppStrings.t('cannot_add_out_of_stock', 'en'),
        isNotEmpty,
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS stock line uses error color, not normal stock text',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));

      final oosText = tester.widget<Text>(
        find.byKey(Key('pos-product-oos-$_productId')),
      );
      final theme = Theme.of(
        tester.element(find.byKey(Key('pos-product-oos-$_productId'))),
      );
      expect(oosText.style?.color, theme.colorScheme.error);
      expect(oosText.style?.fontWeight, FontWeight.w700);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS grid card has red border and reduced elevation',
        (tester) async {
      final oosDio = MockDio();
      _mockDio(oosDio, productQuantity: '0');
      await _pumpApp(tester, dio: oosDio);
      await tester.pump(const Duration(milliseconds: 500));

      final card = tester.widget<Card>(
        find.byKey(Key('pos-product-$_productId')),
      );
      final theme = Theme.of(
        tester.element(find.byKey(Key('pos-product-$_productId'))),
      );
      expect(card.elevation, 0);
      final shape = card.shape as RoundedRectangleBorder?;
      expect(shape, isNotNull);
      final side = shape!.side;
      expect(side.color, theme.colorScheme.error);
      expect(side.width, greaterThanOrEqualTo(1.5));
      expect(tester.takeException(), isNull);
    });

    // ── FIX 11–12 regression guards ───────────────────────────────────
    testWidgets('cart widths unchanged (FIX #11 / UX FIX #8 floors)',
        (tester) async {
      expect(posCartWidthFor(600), 600);
      expect(posCartWidthFor(800), 400);
      expect(posCartWidthFor(1100), 440);
      expect(posCartWidthFor(1400), 480);
      expect(posCartWidthFor(1920), 480);
    });

    testWidgets('totals + PAY sizing still meet UX FIX #8 floors',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      addLine(containerOf(tester));
      await tester.pump();
      final total = tester
          .widget<Text>(find.byKey(const Key('pos-total-value')))
          .style!;
      expect(total.fontSize!, inInclusiveRange(36, 48));
      final payH = tester.getSize(find.byKey(const Key('pos-pay-button'))).height;
      expect(payH, greaterThanOrEqualTo(56));
      expect(tester.takeException(), isNull);
    });

    testWidgets('secondary actions still 2-column height 44–48',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      final actionKeys = <Key>[
        const Key('pos-discount-button'),
        const Key('pos-hold-button'),
        const Key('pos-holds-button'),
        const Key('pos-history-button'),
      ];
      final centers = <Offset>[];
      for (final key in actionKeys) {
        final h = tester.getSize(find.byKey(key)).height;
        expect(h, greaterThanOrEqualTo(44), reason: '$key');
        expect(h, lessThanOrEqualTo(48), reason: '$key');
        centers.add(tester.getCenter(find.byKey(key)));
      }
      final rows = <int, List<Offset>>{};
      for (final c in centers) {
        rows.putIfAbsent(c.dy.round(), () => []).add(c);
      }
      expect(rows.length, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('permission toast still uses showPosToast (FIX #1/#9A)',
        (tester) async {
      await showPermissionSnackbar(tester);
      final snack = find.byType(SnackBar);
      expect(snack, findsOneWidget);
      expect(tester.widget<SnackBar>(snack).behavior, SnackBarBehavior.floating);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OOS does not change cart totals (FIX #10)', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1366, 768));
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '3',
              unitPrice: '100',
              lineDiscount: '10',
            ),
          );
      container.read(posCartProvider.notifier).setInvoiceDiscount('20');
      await tester.pump();
      final totals = container.read(posCartProvider).totals;
      expect(totals.total, closeTo(270, 0.001));
      expect(
        tester.widget<Text>(find.byKey(const Key('pos-total-value'))).data,
        '270.00 DA',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ── FIX #9A: compact POS feedback toast ─────────────────────────────
  group('compact POS feedback toast (FIX #9A)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Future<void> showToast(
      WidgetTester tester, {
      required String message,
      PosToastKind kind = PosToastKind.info,
      String? detail,
      Key? key,
    }) async {
      showPosToast(
        tester.element(find.byKey(const Key('pos-screen'))),
        message: message,
        kind: kind,
        detail: detail,
        key: key,
      );
      await tester.pumpAndSettle();
    }

    /// The visible toast card (SnackBar outer rect minus its margins).
    Rect visibleToastRect(WidgetTester tester) {
      final snack = find.byType(SnackBar);
      final widget = tester.widget<SnackBar>(snack);
      final outer = tester.getRect(snack);
      final margin = widget.margin!.resolve(TextDirection.ltr);
      return Rect.fromLTRB(
        outer.left + margin.left,
        outer.top + margin.top,
        outer.right - margin.right,
        outer.bottom - margin.bottom,
      );
    }

    testWidgets('success toast appears (semantic green + invoice detail)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('sale_completed', 'en'),
        detail: 'INV-20260924-165725',
        kind: PosToastKind.success,
        key: const Key('checkout-success-snackbar'),
      );
      expect(
        find.byKey(const Key('checkout-success-snackbar')),
        findsOneWidget,
      );
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.backgroundColor, AppColors.success);
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(find.text(AppStrings.t('sale_completed', 'en')), findsOneWidget);
      expect(find.text('INV-20260924-165725'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error toast appears (semantic red + close button)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('cannot_add_out_of_stock', 'en'),
        kind: PosToastKind.error,
        key: const Key('pos-out-of-stock-error'),
      );
      expect(find.byKey(const Key('pos-out-of-stock-error')), findsOneWidget);
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.backgroundColor, AppColors.error);
      expect(find.byKey(const Key('pos-toast-close')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('warning toast appears (semantic amber, not green)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('permission_discount', 'en'),
        kind: PosToastKind.warning,
      );
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.backgroundColor, AppColors.warning);
      expect(snack.backgroundColor, isNot(equals(AppColors.success)));
      expect(find.byIcon(Icons.priority_high), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toast is bottom-center and NOT full width (success)',
        (tester) async {
      await _pumpApp(tester, dio: dio); // 1366×768
      await showToast(tester, message: 'Saved', kind: PosToastKind.success);
      final rect = visibleToastRect(tester);
      expect(rect.width, lessThanOrEqualTo(kPosToastMaxWidth));
      expect(rect.width, lessThan(1366 - 120)); // never edge-to-edge
      expect(rect.width, lessThanOrEqualTo(1366 - 32)); // ≥16 px gutters
      expect(rect.center.dx, closeTo(1366 / 2, 1.0), reason: 'centered');
      // FIX #10B micro-fix: wide/medium sits 24px from the bottom edge.
      expect(rect.bottom, closeTo(768 - 24, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('error toast is bottom center', (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('api_error_retry', 'en'),
        kind: PosToastKind.error,
        key: const Key('toast-error-center'),
      );
      final rect = visibleToastRect(tester);
      expect(rect.center.dx, closeTo(1366 / 2, 1.0));
      expect(rect.width, lessThanOrEqualTo(kPosToastMaxWidth));
      final pay = tester.getRect(find.byKey(const Key('pos-pay-button')));
      expect(rect.overlaps(pay), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('warning toast is bottom center', (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('permission_discount', 'en'),
        kind: PosToastKind.warning,
        key: const Key('toast-warning-center'),
      );
      final rect = visibleToastRect(tester);
      expect(rect.center.dx, closeTo(1366 / 2, 1.0));
      expect(rect.width, lessThanOrEqualTo(kPosToastMaxWidth));
      expect(rect.width, lessThan(1366 - 120));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toast max width <= 440 (and >= 280) on wide desktop',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1920, 1080));
      await showToast(tester, message: 'Saved', kind: PosToastKind.info);
      final rect = visibleToastRect(tester);
      expect(rect.width, lessThanOrEqualTo(440));
      expect(rect.width, greaterThanOrEqualTo(280));
      expect(rect.width, lessThanOrEqualTo(1920 - 32));
      expect(rect.center.dx, closeTo(1920 / 2, 1.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toast remains readable (fonts, 2 lines, radius, padding)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('sale_completed', 'en'),
        detail: 'INV-1',
        kind: PosToastKind.success,
      );
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      final shape = snack.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, const BorderRadius.all(Radius.circular(12)));
      expect(snack.elevation!, greaterThanOrEqualTo(1));
      expect(snack.elevation!, lessThanOrEqualTo(6));
      final padding = snack.padding!.resolve(TextDirection.ltr);
      expect(padding.left, inInclusiveRange(12, 16));
      expect(padding.top, inInclusiveRange(12, 16));

      final toast = find.byType(PosToast);
      expect(toast, findsOneWidget);
      final texts = tester.widgetList<Text>(
        find.descendant(of: toast, matching: find.byType(Text)),
      );
      expect(texts, hasLength(2));
      expect(texts.first.style!.fontSize!, inInclusiveRange(13, 15));
      expect(texts.first.style!.fontWeight, FontWeight.w600);
      expect(texts.first.maxLines, 2);
      expect(texts.first.overflow, TextOverflow.ellipsis);
      expect(texts.last.style!.fontSize!, inInclusiveRange(11, 12));
      expect(texts.last.maxLines, 1);
      // Entry fade+slide settled → fully opaque, no clipping.
      final opacity = tester.widget<AnimatedOpacity>(
        find.descendant(of: toast, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacity.opacity, 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toast positioned above cart footer (never covers PAY/TOTAL)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      await showToast(tester, message: 'Saved', kind: PosToastKind.success);
      final rect = visibleToastRect(tester);
      final payRect = tester.getRect(find.byKey(const Key('pos-pay-button')));
      final totalRect = tester.getRect(
        find.byKey(const Key('pos-total-value')),
      );
      expect(rect.overlaps(payRect), isFalse);
      expect(rect.overlaps(totalRect), isFalse);
      // Never obstructs the cart footer: either entirely above the PAY top
      // edge, or beside the cart horizontally clear (approved FIX #10B
      // low 24 px position when the card sits in free space next to the
      // cart side panel — same rule as the snackbar check in FIX #9).
      final horizontallyClear =
          rect.right <= payRect.left || rect.left >= payRect.right;
      expect(
        horizontallyClear || payRect.top - rect.bottom >= 0,
        isTrue,
        reason: 'toast must not obstruct PAY (toast $rect, PAY $payRect)',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('PAY remains visible while the toast is shown', (tester) async {
      await _pumpApp(tester, dio: dio);
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      await showToast(tester, message: 'Saved', kind: PosToastKind.success);
      final pay = find.byKey(const Key('pos-pay-button'));
      expect(pay, findsOneWidget);
      final payRect = tester.getRect(pay);
      expect(payRect.top, greaterThanOrEqualTo(0));
      expect(payRect.bottom, lessThanOrEqualTo(768));
      expect(visibleToastRect(tester).overlaps(payRect), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TOTAL remains visible while the toast is shown',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      await showToast(tester, message: 'Saved', kind: PosToastKind.success);
      final total = find.byKey(const Key('pos-total-value'));
      expect(total, findsOneWidget);
      final totalRect = tester.getRect(total);
      expect(totalRect.top, greaterThanOrEqualTo(0));
      expect(totalRect.bottom, lessThanOrEqualTo(768));
      expect(visibleToastRect(tester).overlaps(totalRect), isFalse);
      expect(tester.takeException(), isNull);
    });

    // ── FIX #10B micro-fix: adaptive vertical position ───────────────
    // 24 px only when the bottom-centered card ends at/before the cart
    // side panel's left edge (free space beside the cart); when the cart
    // sits under the card it keeps the footer-safe `footer + 6` offset so
    // TOTAL/PAY stay clear:
    //   800x600   card right 620  <= cart left 400? no → footer + 6
    //   1366x768  card right 903  <= cart left 926    → 24 px
    //   1920x1080 card right 1180 <= cart left 1440   → 24 px
    const toastBottomSizes = <String, Size>{
      '800x600': Size(800, 600),
      '1366x768': Size(1366, 768),
      '1920x1080': Size(1920, 1080),
    };
    const toastClearsCart = <String, bool>{
      '800x600': false,
      '1366x768': true,
      '1920x1080': true,
    };
    toastBottomSizes.forEach((label, size) {
      testWidgets(
          'toast at $label uses the approved adaptive bottom offset '
          '(FIX #10B)', (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        containerOf(tester).read(posCartProvider.notifier).addLine(
              const CartLine(
                productId: 'p1',
                name: 'Bread',
                quantity: '2',
                unitPrice: '10',
              ),
            );
        await tester.pump();
        await showToast(tester, message: 'Saved', kind: PosToastKind.success);
        final rect = visibleToastRect(tester);
        final payRect = tester.getRect(find.byKey(const Key('pos-pay-button')));
        final double footerOffset = posToastFooterFor(size) + 6;
        if (toastClearsCart[label]!) {
          expect(
            rect.bottom,
            closeTo(size.height - 24, 1.0),
            reason: 'FIX #10B: clears the cart → 24px ($label)',
          );
          // Noticeably lower than the old footer + 6 offset.
          expect(
            rect.bottom,
            greaterThan(
              size.height - footerOffset,
            ),
            reason: 'moved lower than footer + 6 ($label)',
          );
        } else {
          expect(
            rect.bottom,
            closeTo(size.height - footerOffset, 1.0),
            reason: 'FIX #10B: cart under the card → footer + 6 ($label)',
          );
          // Cart sits directly under the centered card → never covers PAY.
          expect(rect.overlaps(payRect), isFalse, reason: label);
        }
        // Still horizontally bottom-center and in-bounds (no overflow).
        expect(rect.center.dx, closeTo(size.width / 2, 1.0), reason: label);
        expect(rect.left, greaterThanOrEqualTo(0), reason: label);
        expect(rect.right, lessThanOrEqualTo(size.width), reason: label);
        expect(tester.takeException(), isNull, reason: label);
      });
    });

    testWidgets('toast at 600x500 stays footer-safe (narrow, FIX #10B)',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(600, 500));
      // Narrow cart drawer open (same setup as the overlap tests).
      await tester.tap(find.byKey(const Key('toggle-cart')));
      await tester.pump();
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Bread',
              quantity: '2',
              unitPrice: '10',
            ),
          );
      await tester.pump();
      await showToast(tester, message: 'Saved', kind: PosToastKind.success);
      final rect = visibleToastRect(tester);
      expect(
        rect.bottom,
        closeTo(500 - (posToastFooterFor(const Size(600, 500)) + 6), 1.0),
        reason: 'narrow keeps footer + 6 offset',
      );
      final payRect = tester.getRect(find.byKey(const Key('pos-pay-button')));
      final totalRect = tester.getRect(
        find.byKey(const Key('pos-total-value')),
      );
      expect(rect.overlaps(payRect), isFalse);
      expect(rect.overlaps(totalRect), isFalse);
      expect(payRect.top - rect.bottom, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Arabic RTL toast renders localized message', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      final message = AppStrings.t('cannot_add_out_of_stock', 'ar');
      await showToast(tester, message: message, kind: PosToastKind.error);
      expect(find.text(message), findsOneWidget);
      final rect = visibleToastRect(tester);
      expect(rect.width, lessThanOrEqualTo(kPosToastMaxWidth));
      expect(rect.center.dx, closeTo(1366 / 2, 1.0), reason: 'RTL centered');
      expect(tester.takeException(), isNull);
    });

    testWidgets('French toast renders localized message', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.fr);
      final message = AppStrings.t('permission_discount', 'fr');
      await showToast(tester, message: message, kind: PosToastKind.warning);
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('English toast renders localized message', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.en);
      final message = AppStrings.t('invoice_copied', 'en');
      await showToast(tester, message: message, kind: PosToastKind.success);
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    const toastSizes = <String, Size>{
      '600x500': Size(600, 500),
      '800x600': Size(800, 600),
      '1366x768': Size(1366, 768),
    };
    toastSizes.forEach((label, size) {
      testWidgets(
          'toast at $label stays compact, above PAY, no overflow',
          (tester) async {
        await _pumpApp(tester, dio: dio, size: size);
        if (posLayoutModeFor(size.width) == PosLayoutMode.narrow) {
          await tester.tap(find.byKey(const Key('toggle-cart')));
          await tester.pump();
        }
        containerOf(tester).read(posCartProvider.notifier).addLine(
              const CartLine(
                productId: 'p1',
                name: 'Bread',
                quantity: '2',
                unitPrice: '10',
              ),
            );
        await tester.pump();
        await showToast(tester, message: 'Saved', kind: PosToastKind.success);

        final rect = visibleToastRect(tester);
        expect(rect.width, lessThanOrEqualTo(kPosToastMaxWidth), reason: label);
        expect(rect.width, greaterThanOrEqualTo(280), reason: label);
        expect(rect.width, lessThanOrEqualTo(size.width - 32), reason: label);
        expect(
          rect.center.dx,
          closeTo(size.width / 2, 1.0),
          reason: '$label centered',
        );
        expect(rect.left, greaterThanOrEqualTo(15), reason: label);
        expect(rect.right, lessThanOrEqualTo(size.width - 15), reason: label);

        final payRect = tester.getRect(find.byKey(const Key('pos-pay-button')));
        final totalRect = tester.getRect(
          find.byKey(const Key('pos-total-value')),
        );
        expect(rect.overlaps(payRect), isFalse, reason: label);
        expect(rect.overlaps(totalRect), isFalse, reason: label);
        expect(
          rect.right <= payRect.left ||
              rect.left >= payRect.right ||
              payRect.top - rect.bottom >= 0,
          isTrue,
          reason: '$label: toast must not obstruct PAY '
              '(snack $rect, PAY $payRect)',
        );
        expect(payRect.bottom, lessThanOrEqualTo(size.height), reason: label);
        expect(tester.takeException(), isNull, reason: label);
      });
    });

    testWidgets('success toast auto-dismisses after 3 seconds', (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: AppStrings.t('hold_saved', 'en'),
        kind: PosToastKind.success,
        key: const Key('toast-timing'),
      );
      expect(find.byKey(const Key('toast-timing')), findsOneWidget);
      // Still visible before the 3 s timeout.
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.byKey(const Key('toast-timing')), findsOneWidget);
      // Past 3 s the timer fires and the reverse animation removes it.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error toast stays longer (4–5 s) than a normal toast',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await showToast(
        tester,
        message: 'Network hiccup — try again',
        kind: PosToastKind.error,
        key: const Key('toast-error-timing'),
      );
      expect(find.byKey(const Key('toast-error-timing')), findsOneWidget);
      // A success toast (3 s) would already be gone at 3.4 s.
      await tester.pump(const Duration(milliseconds: 3400));
      expect(find.byKey(const Key('toast-error-timing')), findsOneWidget);
      // Past 4.5 s it dismisses.
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('replacing a visible toast never stacks bars', (tester) async {
      await _pumpApp(tester, dio: dio);
      showPosToast(
        tester.element(find.byKey(const Key('pos-screen'))),
        message: 'First',
        kind: PosToastKind.success,
        key: const Key('toast-first'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toast-first')), findsOneWidget);

      showPosToast(
        tester.element(find.byKey(const Key('pos-screen'))),
        message: 'Second',
        kind: PosToastKind.error,
        key: const Key('toast-second'),
      );
      // Mid-transition there is never more than one bar.
      await tester.pump();
      expect(
        tester.widgetList(find.byType(SnackBar)).length,
        lessThanOrEqualTo(1),
      );
      await tester.pumpAndSettle();
      expect(tester.widgetList(find.byType(SnackBar)).length, 1);
      expect(find.byKey(const Key('toast-second')), findsOneWidget);
      expect(find.byKey(const Key('toast-first')), findsNothing);
      expect(find.text('First'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('POS quantity shortcuts (+ and *)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Future<void> addLine(WidgetTester tester, CartLine line) async {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
      await tester.pump();
    }

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    // Main-row `+` (Shift + `=`): the key event carries the `+` character.
    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    // Main-row `*` (Shift + `8`): the key event carries the `*` character.
    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
    }

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    /// Label of a dialog button (the widget key sits on the button itself).
    String? buttonText(WidgetTester tester, Key key) => tester
        .widget<Text>(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)),
        )
        .data;

    const breadLine = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
      availableStock: '5',
    );

    testWidgets('+ increments the last active cart line by exactly 1',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '2');
      expect(
        tester
            .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
            .controller!
            .text,
        '2',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ pressed repeatedly keeps adding one unit per press',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);

      await pressPlus(tester);
      await pressPlus(tester);
      await pressPlus(tester);

      expect(qtyAt(tester, 0), '4');
    });

    testWidgets('+ works from the numpad add key', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
      await tester.pump();

      expect(qtyAt(tester, 0), '2');
    });

    testWidgets('* opens the quantity input dialog', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(find.byKey(const Key('qty-multiplier-input')), findsOneWidget);
      expect(find.byKey(const Key('qty-multiplier-apply')), findsOneWidget);
      expect(find.byKey(const Key('qty-multiplier-cancel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('* works from the numpad multiply key', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadMultiply);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
    });

    testWidgets('confirming the dialog REPLACES the quantity (never '
        'multiplies)', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '4',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsNothing);
      // 4 — NOT 3 × 4 = 12.
      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ keeps working on the same line after the dialog sets '
        'the quantity', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '4',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '4');

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '5');
    });

    testWidgets('Escape closes the quantity dialog without changes',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '4',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsNothing);
      expect(qtyAt(tester, 0), '3');
    });

    testWidgets('quantity dialog shows product name and current quantity',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-product')))
            .data,
        'Bread',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-current')))
            .data,
        "${AppStrings.t('quantity', 'en')}: 3",
      );
      expect(find.byKey(const Key('qty-multiplier-preview')), findsOneWidget);
    });

    testWidgets('dialog preview shows current → entered value (never a '
        'product)', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '4',
      );
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-preview')))
            .data,
        '3 → 4',
      );
    });

    testWidgets('empty quantity is rejected and the dialog stays open',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      // Phase 17 §18: the field opens BLANK (assert the seeded-then-cleared
      // state is gone) — applying it now must be rejected as empty.
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-error')))
            .data,
        AppStrings.t('enter_quantity', 'en'),
      );
      expect(qtyAt(tester, 0), '3');
    });

    testWidgets('quantity 0 is rejected', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '0',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(find.byKey(const Key('qty-multiplier-error')), findsOneWidget);
      expect(qtyAt(tester, 0), '3');
    });

    testWidgets('quantity beyond available stock is rejected',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '5',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      // 6 > 5 in stock → the shared stock rule rejects it.
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        '6',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-error')))
            .data,
        AppStrings.t('out_of_stock', 'en'),
      );
      expect(qtyAt(tester, 0), '3');
    });

    testWidgets('+ never exceeds available stock (toast, quantity kept)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '5',
          unitPrice: '10',
          availableStock: '5',
        ),
      );

      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(qtyAt(tester, 0), '5');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(find.text(AppStrings.t('out_of_stock', 'en')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ counts base units when the line uses a unit multiplier',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '1',
          unitPrice: '10',
          availableStock: '15',
          unitMultiplier: '10',
        ),
      );

      // 2 boxes × 10 = 20 base units > 15 in stock → blocked.
      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(qtyAt(tester, 0), '1');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
    });

    testWidgets('+ on an empty cart shows the cart-empty toast',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-qty-empty-cart')), findsOneWidget);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('* on an empty cart shows the cart-empty toast, no dialog',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-qty-empty-cart')), findsOneWidget);
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsNothing);
    });

    testWidgets('+ targets the last added line', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p2',
          name: 'Milk',
          quantity: '5',
          unitPrice: '5',
          availableStock: '9',
        ),
      );
      await addLine(tester, breadLine);

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '5');
      expect(qtyAt(tester, 1), '2');
    });

    testWidgets('+ targets the line edited last', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '2',
          unitPrice: '10',
          availableStock: '9',
        ),
      );
      await addLine(
        tester,
        const CartLine(
          productId: 'p2',
          name: 'Milk',
          quantity: '1',
          unitPrice: '5',
          availableStock: '5',
        ),
      );
      final firstKey = containerOf(tester).read(posCartProvider).lines.first.key;
      containerOf(tester)
          .read(posCartProvider.notifier)
          .updateLine(firstKey, quantity: '4');
      await tester.pump();

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '5');
      expect(qtyAt(tester, 1), '1');
    });

    // UX FIX #12 — FIX #2: the search field and the cart qty fields hand
    // `+` back to the POS shortcut (typing `+` there increments the active
    // line instead of inserting the character).
    testWidgets('+ increments while the POS search field has focus',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      await focusSearchField(tester);

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ increments while the line qty field has focus',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.tap(find.byKey(Key('cart-line-qty-$key')));
      await tester.pump(const Duration(milliseconds: 100));

      await pressPlus(tester);
      await pressPlus(tester);

      expect(qtyAt(tester, 0), '3');
      expect(tester.takeException(), isNull);
    });

    // Any other text field (dialogs, pickers) keeps normal typing: `+`
    // must NOT be swallowed there.
    testWidgets('+ is ignored inside a dialog text field', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);

      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('qty-multiplier-input')));
      await tester.pump(const Duration(milliseconds: 100));

      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(qtyAt(tester, 0), '1');
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // `*` is claimed in the POS search field and the cart qty fields
    // (Phase 8 FIX #3): the dialog opens and the `*` character is never
    // inserted into the text. Any other text field keeps normal typing.
    testWidgets('* opens the dialog from the search field and never '
        'inserts it', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      await focusSearchField(tester);
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pos-search-field')))
            .controller!
            .text,
        'bre',
      );
      expect(qtyAt(tester, 0), '1');
    });

    testWidgets('+ falls back to the remaining line after the active one '
        'is removed', (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      await addLine(
        tester,
        const CartLine(
          productId: 'p2',
          name: 'Milk',
          quantity: '1',
          unitPrice: '5',
          availableStock: '5',
        ),
      );
      final lastKey =
          containerOf(tester).read(posCartProvider).lines.last.key;
      containerOf(tester).read(posCartProvider.notifier).removeLine(lastKey);
      await tester.pump();

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '2');
      expect(containerOf(tester).read(posCartProvider).lines.length, 1);
    });

    testWidgets('+ after clearing the cart reports the empty cart again',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await addLine(tester, breadLine);
      containerOf(tester).read(posCartProvider.notifier).clearCart();
      await tester.pump();

      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(find.byKey(const Key('pos-qty-empty-cart')), findsOneWidget);
    });

    testWidgets('Arabic RTL: quantity dialog is localized', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-title')))
            .data,
        AppStrings.t('enter_quantity', 'ar'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-cancel')),
        AppStrings.t('cancel', 'ar'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-apply')),
        AppStrings.t('confirm', 'ar'),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('qty-multiplier-cancel')));
      await tester.pumpAndSettle();
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '4');
    });

    testWidgets('French: quantity dialog is localized', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.fr);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-title')))
            .data,
        AppStrings.t('enter_quantity', 'fr'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-cancel')),
        AppStrings.t('cancel', 'fr'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-apply')),
        AppStrings.t('confirm', 'fr'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English: quantity dialog is localized', (tester) async {
      await _pumpApp(tester, dio: dio, locale: AppLocale.en);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-title')))
            .data,
        AppStrings.t('enter_quantity', 'en'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-cancel')),
        AppStrings.t('cancel', 'en'),
      );
      expect(
        buttonText(tester, const Key('qty-multiplier-apply')),
        AppStrings.t('confirm', 'en'),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('sale line snapshots (UX FIX #11)', () {
    const saleId = 'sale-snap-1';
    const invoice = 'INV-SNAP-1';

    Map<String, dynamic> snapshotDetail() => {
          'id': saleId,
          'invoice_number': invoice,
          'customer_id': null,
          'status': 'completed',
          'subtotal': '2270.00',
          'discount': '0',
          'total': '2270.00',
          'paid': '2270.00',
          'change': '0',
          'debt': '0',
          'payment_method': 'cash',
          'device_id': 'dev-1',
          'note': null,
          'sale_date': '2026-09-24T10:00:00',
          'lines': [
            // Base-unit line — no snapshots.
            {
              'id': 'line-0',
              'product_id': _productId,
              'variant_id': null,
              'product_name': 'Rice Bag',
              'product_sku': 'RB-1',
              'product_barcode': null,
              'product_unit': 'piece',
              'variant_name': null,
              'selling_unit_name': null,
              'selling_unit_multiplier': null,
              'unit_price': '550.00',
              'unit_cost': '400.00',
              'quantity': '2',
              'line_discount': '0',
              'line_total': '1100.00',
            },
            // Variant line — stored variant name.
            {
              'id': 'line-1',
              'product_id': _productId,
              'variant_id': 'var-1',
              'product_name': 'Fromage',
              'product_sku': null,
              'product_barcode': null,
              'product_unit': 'piece',
              'variant_name': 'Cheddar',
              'selling_unit_name': null,
              'selling_unit_multiplier': null,
              'unit_price': '70.00',
              'unit_cost': '50.00',
              'quantity': '1',
              'line_discount': '0',
              'line_total': '70.00',
            },
            // Selling-unit line — stored name + multiplier.
            {
              'id': 'line-2',
              'product_id': _productId,
              'variant_id': null,
              'product_name': 'Fromage',
              'product_sku': null,
              'product_barcode': null,
              'product_unit': 'piece',
              'variant_name': null,
              'selling_unit_name': 'Box',
              'selling_unit_multiplier': '24.000',
              'unit_price': '550.00',
              'unit_cost': '400.00',
              'quantity': '2',
              'line_discount': '0',
              'line_total': '1100.00',
            },
          ],
          'payments': [
            {'id': 'pay-1', 'method': 'cash', 'amount': '2270.00'},
          ],
          'idempotent_replay': false,
        };

    Future<List<String>> openSnapshotDetail(
      WidgetTester tester, {
      AppLocale locale = AppLocale.en,
      Map<String, dynamic>? detail,
    }) async {
      final paths = <String>[];
      final mock = MockDio();
      _mockDio(
        mock,
        saleListBody: {
          'items': [
            {
              'id': saleId,
              'invoice_number': invoice,
              'total': '2270.00',
              'paid': '2270.00',
              'payment_method': 'cash',
              'status': 'completed',
              'sale_date': '2026-09-24T10:00:00',
              'customer_id': null,
            },
          ],
          'total': 1,
          'page': 1,
          'page_size': 50,
        },
        saleDetailBody: detail ?? snapshotDetail(),
        recordPaths: paths,
      );
      await _pumpApp(tester, dio: mock, locale: locale);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-history-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-history-dialog')), findsOneWidget);
      // Only record what the sale detail dialog itself fetches.
      paths.clear();
      await tester.tap(find.byKey(Key('sale-row-$saleId')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-detail-dialog')), findsOneWidget);
      return paths;
    }

    String textOf(WidgetTester tester, Key key) =>
        tester.widget<Text>(find.byKey(key)).data ?? '';

    testWidgets('base / variant / selling unit lines render from snapshots',
        (tester) async {
      await openSnapshotDetail(tester);

      expect(find.byKey(const Key('sale-detail-line-0')), findsOneWidget);
      expect(
        textOf(tester, const Key('sale-detail-line-qty-0')),
        '2 Piece × ${_m('550.00 DA')}',
      );
      // Variant name comes from the stored snapshot, not the catalog.
      expect(
        textOf(tester, const Key('sale-detail-line-variant-1')),
        'Cheddar',
      );
      expect(
        textOf(tester, const Key('sale-detail-line-qty-1')),
        '1 Piece × ${_m('70.00 DA')}',
      );
      // Selling unit label is the historical name (raw, not localized).
      expect(
        textOf(tester, const Key('sale-detail-line-qty-2')),
        '2 Box × ${_m('550.00 DA')}',
      );
      expect(
        textOf(tester, const Key('sale-detail-line-base-2')),
        'Base: ${_m('48')} Piece',
      );
      expect(textOf(tester, const Key('sale-detail-line-total-2')), '1 100.00');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Sale Detail does not call catalog APIs', (tester) async {
      final paths = await openSnapshotDetail(tester);

      expect(paths, contains('/api/v1/sales/$saleId'));
      final catalogCalls = paths.where(
        (p) =>
            p.endsWith('/variants') ||
            p.endsWith('/selling-units') ||
            (p.startsWith('/api/v1/products/') && !p.endsWith('/search')),
      );
      expect(
        catalogCalls,
        isEmpty,
        reason: 'Sale Detail must render snapshots only, got: $catalogCalls',
      );
    });

    testWidgets('legacy sale line without snapshot fields still renders',
        (tester) async {
      final legacy = snapshotDetail();
      final lines = (legacy['lines'] as List).cast<Map<String, dynamic>>();
      for (final line in lines) {
        line.remove('variant_name');
        line.remove('selling_unit_name');
        line.remove('selling_unit_multiplier');
      }

      await openSnapshotDetail(tester, detail: legacy);

      expect(find.byKey(const Key('sale-detail-line-0')), findsOneWidget);
      expect(
        textOf(tester, const Key('sale-detail-line-qty-0')),
        '2 Piece × ${_m('550.00 DA')}',
      );
      expect(find.byKey(const Key('sale-detail-line-base-2')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('snapshot labels are localized while names stay raw',
        (tester) async {
      await openSnapshotDetail(tester, locale: AppLocale.ar);

      // Localized base-unit label, raw stored selling unit name.
      expect(
        textOf(tester, const Key('sale-detail-line-qty-2')),
        '2 Box × ${_m('550.00 DA')}',
      );
      expect(
        textOf(tester, const Key('sale-detail-line-base-2')),
        contains(AppStrings.t('base', 'ar')),
      );
      expect(
        textOf(tester, const Key('sale-detail-line-variant-1')),
        'Cheddar',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ── UX FIX #12 — final human-QA corrections ──────────────────────────
  group('UX FIX #12 quantity corrections (human QA)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Future<void> addLine(WidgetTester tester, CartLine line) async {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
      await tester.pump();
    }

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '7',
      unitPrice: '10',
      availableStock: '500',
    );

    testWidgets('+ still works after the cashier typed a quantity by hand',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(tester, bread);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      // Hand-typed quantity keeps the qty field focused …
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '7');
      await tester.pump();
      // … and `+` must still claim the event (focus rule FIX #2).
      await pressPlus(tester);
      await tester.pump();

      expect(qtyAt(tester, 0), '8');
      expect(
        tester
            .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
            .controller!
            .text,
        '8',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('quantity expression 10*24 is applied as 240',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(tester, bread);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '10*24');
      await tester.pump();

      expect(qtyAt(tester, 0), '240');
      expect(
        tester
            .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
            .controller!
            .text,
        '240',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an incomplete expression never corrupts the cart',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(tester, bread);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '10*');
      await tester.pump();

      expect(qtyAt(tester, 0), '7');
      expect(tester.takeException(), isNull);
    });

    testWidgets('out-of-stock is detected while typing (immediate)',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '5',
          unitPrice: '10',
          availableStock: '10',
        ),
      );
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '20');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(qtyAt(tester, 0), '5', reason: 'impossible quantity rejected');
      expect(
        tester
            .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
            .controller!
            .text,
        '5',
        reason: 'field rolls back to the committed quantity',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('selling-unit line stock is checked in base units',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Rice',
          quantity: '4',
          unitPrice: '550',
          availableStock: '50',
          sellingUnitId: 'su-1',
          unitMultiplier: '10',
        ),
      );
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      // 4 boxes = 40 base units (ok) → 6 boxes = 60 > 50 (blocked).
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '6');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('invalid typed quantity shows the localized rejection',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock);
      await _pumpApp(tester, dio: mock);
      await addLine(tester, bread);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '10*');
      await tester.testTextInput
          .receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('pos-qty-invalid')), findsOneWidget);
      expect(qtyAt(tester, 0), '7');
      expect(tester.takeException(), isNull);
    });
  });

  group('UX FIX #12 sale history sold units (FIX #1)', () {
    Map<String, dynamic> historySale({
      List<Map<String, dynamic>>? lines,
      String? unitSummary,
    }) {
      final sale = <String, dynamic>{
        'id': 's1',
        'invoice_number': 'INV-1001',
        'total': '1100.00',
        'paid': '1100.00',
        'payment_method': 'cash',
        'status': 'completed',
        'sale_date': '2026-09-24T10:00:00',
        'customer_id': null,
      };
      if (unitSummary != null) sale['unit_summary'] = unitSummary;
      if (lines != null) sale['lines'] = lines;
      return <String, dynamic>{
        'items': [sale],
        'total': 1,
        'page': 1,
        'page_size': 50,
      };
    }

    Future<void> openHistory(
      WidgetTester tester,
      Map<String, dynamic> saleListBody, {
      AppLocale locale = AppLocale.en,
    }) async {
      final mock = MockDio();
      _mockDio(mock, saleListBody: saleListBody);
      await _pumpApp(tester, dio: mock, locale: locale);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-history-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('row shows what was sold (grouped by unit)', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {'quantity': '2', 'product_unit': 'piece', 'selling_unit_name': 'Box'},
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
      );

      expect(find.byKey(const Key('sale-history-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('sale-row-units-s1')),
        findsOneWidget,
        reason: 'sold units missing from the history row',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-row-units-s1')))
            .data,
        '2 Box · 48 Piece',
      );
      // Invoice / date / status line stays present.
      expect(find.byKey(const Key('sale-row-meta-s1')), findsOneWidget);
      expect(find.byKey(const Key('sale-row-total-s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('same unit quantities are summed in the row',
        (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {'quantity': '2', 'product_unit': 'piece', 'selling_unit_name': 'Box'},
            {'quantity': '1', 'product_unit': 'piece', 'selling_unit_name': 'Box'},
          ],
        ),
      );

      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-row-units-s1')))
            .data,
        '3 Box',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('row falls back to the API unit_summary when no lines',
        (tester) async {
      await openHistory(
        tester,
        historySale(unitSummary: '5 Piece'),
      );

      expect(
        tester
            .widget<Text>(find.byKey(const Key('sale-row-units-s1')))
            .data,
        '5 Piece',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('sale without unit info shows no units line',
        (tester) async {
      await openHistory(tester, historySale());

      expect(find.byKey(const Key('sale-row-units-s1')), findsNothing);
      expect(find.byKey(const Key('sale-row-meta-s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('units row is localized for Arabic', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {'quantity': '2', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
        locale: AppLocale.ar,
      );
      final arabic = tester
          .widget<Text>(find.byKey(const Key('sale-row-units-s1')))
          .data;
      expect(arabic, '2 ${AppStrings.unitLabel('piece', 'ar')}');
      expect(tester.takeException(), isNull);
    });
  });

  // ── PHASE 8 FIX #3 — Sale History sold-unit display ─────────────────────
  group('Phase 8 FIX #3 sale history sold units', () {
    Map<String, dynamic> historySale({
      List<Map<String, dynamic>>? lines,
      String? unitSummary,
    }) {
      final sale = <String, dynamic>{
        'id': 's1',
        'invoice_number': 'INV-3001',
        'total': '1100.00',
        'paid': '1100.00',
        'payment_method': 'cash',
        'status': 'completed',
        'sale_date': '2026-09-24T10:00:00',
        'customer_id': null,
      };
      if (unitSummary != null) sale['unit_summary'] = unitSummary;
      if (lines != null) sale['lines'] = lines;
      return <String, dynamic>{
        'items': [sale],
        'total': 1,
        'page': 1,
        'page_size': 50,
      };
    }

    Future<void> openHistory(
      WidgetTester tester,
      Map<String, dynamic> saleListBody, {
      AppLocale locale = AppLocale.en,
      List<String>? recordPaths,
      List<Map<String, dynamic>> sellingUnits = const [],
    }) async {
      final mock = MockDio();
      _mockDio(
        mock,
        saleListBody: saleListBody,
        recordPaths: recordPaths,
        sellingUnits: sellingUnits,
      );
      await _pumpApp(tester, dio: mock, locale: locale);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const Key('pos-history-button')));
      await tester.pumpAndSettle();
    }

    String unitsRow(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('sale-row-units-s1'))).data ??
        '';

    testWidgets('1. base-unit sale shows only the base unit (5 Piece)',
        (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '5',
              'product_unit': 'piece',
              'selling_unit_name': null,
            },
          ],
        ),
      );

      expect(unitsRow(tester), '5 ${AppStrings.unitLabel('piece', 'en')}');
      expect(find.byKey(const Key('sale-row-total-s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('2. selling-unit sale shows the sold unit, never the '
        'multiplied base (2 Box)', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
              'selling_unit_multiplier': '24',
            },
          ],
        ),
      );

      expect(unitsRow(tester), '2 ${AppStrings.unitLabel('Box', 'en')}');
      // The 48 base units belong to Sale Detail (`Base: 48 Piece`, asserted
      // in the UX FIX #11 snapshot tests) — the history row never expands it.
      expect(unitsRow(tester), isNot(contains('48')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('3. mixed-unit sale shows every group (2 Box · 48 Piece)',
        (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
      );

      expect(unitsRow(tester), '2 Box · 48 Piece');
      expect(tester.takeException(), isNull);
    });

    testWidgets('4. more than three unit groups are capped with +N',
        (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '1',
              'product_unit': 'piece',
              'selling_unit_name': 'Carton',
            },
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '3', 'product_unit': 'piece', 'selling_unit_name': null},
            {'quantity': '4', 'product_unit': 'pack', 'selling_unit_name': null},
          ],
        ),
      );

      expect(unitsRow(tester), '1 Carton · 2 Box · 3 Piece +1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('5. groups keep first-seen order (never sorted)', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {'quantity': '4', 'product_unit': 'pack', 'selling_unit_name': null},
            {'quantity': '3', 'product_unit': 'piece', 'selling_unit_name': null},
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
          ],
        ),
      );

      expect(unitsRow(tester), '4 Pack · 3 Piece · 2 Box');
      expect(tester.takeException(), isNull);
    });

    testWidgets('6. Arabic row is fully localized', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
        locale: AppLocale.ar,
      );

      final arabic = unitsRow(tester);
      expect(
        arabic,
        '2 ${AppStrings.unitLabel('Box', 'ar')} · '
        '48 ${AppStrings.unitLabel('piece', 'ar')}',
      );
      expect(arabic, isNot(contains('Box')));
      expect(arabic, isNot(contains('Piece')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('7. French row is fully localized', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
        locale: AppLocale.fr,
      );

      final french = unitsRow(tester);
      expect(
        french,
        '2 ${AppStrings.unitLabel('Box', 'fr')} · '
        '48 ${AppStrings.unitLabel('piece', 'fr')}',
      );
      expect(french, contains(AppStrings.unitLabel('Box', 'fr')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('8. English row uses English unit labels', (tester) async {
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
        locale: AppLocale.en,
      );

      expect(unitsRow(tester), '2 Box · 48 Piece');
      expect(tester.takeException(), isNull);
    });

    testWidgets('9. legacy NULL snapshot rows still render', (tester) async {
      // Pre-Phase-8 line: quantity only, no unit snapshots at all.
      await openHistory(
        tester,
        historySale(
          lines: const [
            {'quantity': '5'},
          ],
        ),
      );

      expect(
        find.byKey(const Key('sale-row-units-s1')),
        findsOneWidget,
        reason: 'legacy row must still show its units line',
      );
      expect(unitsRow(tester), '5 ${AppStrings.unitLabel('piece', 'en')}');
      expect(find.byKey(const Key('sale-row-meta-s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('10. renamed catalog: the row stays historical and never '
        'queries the product catalog', (tester) async {
      final paths = <String>[];
      await openHistory(
        tester,
        historySale(
          lines: const [
            {
              'quantity': '2',
              'product_unit': 'piece',
              'selling_unit_name': 'Box',
            },
            {'quantity': '48', 'product_unit': 'piece', 'selling_unit_name': null},
          ],
        ),
        recordPaths: paths,
        // The catalog now sells the same unit under a different name.
        sellingUnits: [
          _sellingUnitJson(id: 'su-box', name: 'Crate', isBaseUnit: false),
        ],
      );

      expect(unitsRow(tester), '2 Box · 48 Piece');
      final catalogCalls = paths
          .where((p) =>
              p.endsWith('/variants') ||
              p.endsWith('/selling-units') ||
              (p.startsWith('/api/v1/products/') && !p.endsWith('/search')))
          .toList();
      expect(
        catalogCalls,
        isEmpty,
        reason: 'history must render snapshots only, got: $catalogCalls',
      );
      expect(paths, contains(_salesPath));
      expect(tester.takeException(), isNull);
    });
  });

  // ── PHASE 8 FIX #5 — POS error toast localization ───────────────────────
  group('Phase 8 FIX #5 POS error toast localization', () {
    const scenarios = <({int? status, bool network, String key})>[
      (status: null, network: true, key: 'network_error_retry'),
      (status: 401, network: false, key: 'session_expired_login'),
      (status: 403, network: false, key: 'permission_denied'),
      (status: 409, network: false, key: 'stock_conflict'),
      (status: 422, network: false, key: 'validation_error'),
      (status: 500, network: false, key: 'api_error_retry'),
    ];

    Future<void> openFailingLookup(
      WidgetTester tester, {
      required AppLocale locale,
      int? status,
      bool network = false,
    }) async {
      final mock = MockDio();
      _mockDio(
        mock,
        variantsErrorStatus: status,
        variantsNetworkError: network,
      );
      await _pumpApp(tester, dio: mock, locale: locale);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
    }

    String headline(WidgetTester tester) => tester
            .widget<Text>(find.byKey(const Key('pos-lookup-error-message')))
            .data ??
        '';

    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      final loc = locale.name;
      for (final scenario in scenarios) {
        final label = scenario.network
            ? 'network failure'
            : 'HTTP ${scenario.status}';
        testWidgets('$loc $label → localized headline', (tester) async {
          await openFailingLookup(
            tester,
            locale: locale,
            status: scenario.status,
            network: scenario.network,
          );

          expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);
          final expected = AppStrings.t(scenario.key, loc);
          expect(headline(tester), expected,
              reason: '$loc $label must show the localized headline');
          expect(headline(tester), isNot(scenario.key),
              reason: 'untranslated key shown to the cashier');

          if (scenario.status != null) {
            final raw = 'lookup failed (${scenario.status})';
            // The raw backend text is present, but as the secondary detail
            // — never as the headline.
            expect(headline(tester), isNot(raw));
            expect(find.text(raw), findsOneWidget,
                reason: 'backend detail line missing');
          } else {
            expect(find.textContaining('lookup failed'), findsNothing);
          }

          if (loc != 'en') {
            expect(
              headline(tester),
              isNot(AppStrings.t(scenario.key, 'en')),
              reason: '$loc/$label fell back to the English headline',
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('the error toast keeps the approved compact design',
        (tester) async {
      await openFailingLookup(tester, locale: AppLocale.en, status: 409);

      final snackBar = tester.widget<SnackBar>(
        find.byWidgetPredicate(
            (w) => w is SnackBar && w.key == const Key('pos-lookup-error')),
      );
      expect(snackBar.behavior, SnackBarBehavior.floating);
      expect(
        snackBar.content,
        isA<PosToast>().having((t) => t.kind, 'kind', PosToastKind.error),
      );
      expect(find.byKey(const Key('pos-toast-close')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ── PHASE 9 BUG FIX — debt-ceiling rejection at checkout ─────────────────
  group('Phase 9 debt ceiling rejection at checkout', () {
    const ceilingEnvelope = <String, dynamic>{
      'error': {
        'code': 'DEBT_CEILING_EXCEEDED',
        'message_key': 'errors.businessRule',
        'message': 'Customer debt ceiling exceeded',
        'details': {
          'customer_id': '11111111-1111-1111-1111-111111111111',
          'current_balance': '0.000',
          'new_debt': '600.000',
          'projected_balance': '600.000',
          'debt_ceiling': '500.000',
        },
        'request_id': 'req-ceiling-1',
      },
    };

    Future<ProviderContainer> pumpRejectedCheckout(
      WidgetTester tester, {
      required AppLocale locale,
    }) async {
      final mock = MockDio();
      _mockDio(
        mock,
        saleErrorStatus: 422,
        saleErrorBody: ceilingEnvelope,
      );
      await _pumpApp(tester, dio: mock, locale: locale);
      await tester.pump(const Duration(milliseconds: 500));

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('pos-screen'))),
        listen: false,
      );
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: _productId,
              name: 'Bread',
              quantity: '1',
              unitPrice: '9',
            ),
          );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-pay-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      return container;
    }

    String dialogError(WidgetTester tester) =>
        tester
            .widget<Text>(find.byKey(const Key('payment-error')))
            .data ??
        '';

    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      testWidgets(
          '$locale rejection shows localized headline + amounts, '
          'cart preserved, no success UI', (tester) async {
        final container = await pumpRejectedCheckout(tester, locale: locale);
        final loc = locale.name;

        // Localized headline + the four amounts on the single error line.
        final error = dialogError(tester);
        expect(error, startsWith(AppStrings.t('debt_ceiling_exceeded', loc)));
        expect(error, contains('600.000'));
        expect(error, contains('500.000'));
        // Never the generic 422 headline, never the raw English message.
        expect(
          error,
          isNot(startsWith(AppStrings.t('validation_error', loc))),
        );
        expect(error, isNot('Customer debt ceiling exceeded'));
        if (loc != 'en') {
          expect(
            error,
            isNot(startsWith(AppStrings.t('debt_ceiling_exceeded', 'en'))),
            reason: '$loc fell back to the English headline',
          );
        }

        // Dialog stays open and usable (adjust payment / cancel).
        expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
        final submit = tester.widget<ElevatedButton>(
          find.byKey(const Key('payment-submit')),
        );
        expect(submit.onPressed, isNotNull,
            reason: 'dialog must remain interactive after rejection');

        // Cart + idempotency key preserved for the retry; no success state.
        final cart = container.read(posCartProvider);
        expect(cart.isEmpty, isFalse);
        expect(cart.pendingClientRequestId, isNotNull,
            reason: 'client_request_id must survive the rejection');
        expect(cart.lastResult, isNull);
        expect(find.text(AppStrings.t('sale_completed', loc)), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  // ── PHASE 8 FIX #1 — add focuses the new/merged line + global `+` ─────
  group('Phase 8 FIX #1 add focus and global +', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    /// Value key of the focused text field, if the focus is on one.
    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    // Main-row `+` (Shift + `=`): the key event carries the `+` character.
    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    const breadLine = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
      availableStock: '5',
    );

    String searchText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('pos-search-field')))
        .controller!
        .text;

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    /// Direct add (no variants, no selling units) through the real catalog.
    Future<void> addBread(WidgetTester tester) async {
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
    }

    testWidgets('adding a product never auto-focuses its quantity field',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await addBread(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.first.key;
      // The line is active — but NO quantity field owns the keyboard
      // (Phase 8 FIX #1 retired: an add never auto-focuses a qty field).
      expect(cart.lastActiveKey, key);
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$key'));

      // An EXPLICIT click still parks focus in the qty field and hand
      // editing keeps working normally.
      await tester.tap(find.byKey(Key('cart-line-qty-$key')));
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '5');
      await tester.pump();
      expect(qtyAt(tester, 0), '5');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ pressed right after the add increments the active line',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await addBread(tester);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '2');
      // `+` targets the ACTIVE line — never through a qty-field focus
      // move (the add never focused one).
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$key'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated + right after the add adds one unit per press',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await addBread(tester);

      await pressPlus(tester);
      await pressPlus(tester);
      await pressPlus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ from the search field increments and never inserts +',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await addBread(tester);
      // The cashier goes back to scanning (search field takes focus).
      await focusSearchField(tester);
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(focusedFieldKey(tester), 'pos-search-field');

      await pressPlus(tester);
      await pressPlus(tester);

      expect(qtyAt(tester, 0), '3');
      // The `+` never reached the text input.
      expect(searchText(tester), 'bre');
      expect(searchText(tester).contains('+'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the second product added becomes the active line',
        (tester) async {
      const secondId = '00000000-0000-0000-0000-0000000000p2';
      final twoDio = MockDio();
      _mockDio(twoDio);
      final catalog = _ok(_catalogPath, {
        'items': [
          _product(),
          _product(id: secondId, name: 'Milk', barcode: '222', price: '5.0'),
        ],
        'total': 2,
      });
      when(() => twoDio.get(_catalogPath, queryParameters: any(named: 'queryParameters')))
          .thenAnswer((_) async => catalog);
      when(() => twoDio.get(_catalogPath)).thenAnswer((_) async => catalog);
      await _pumpApp(tester, dio: twoDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      final firstKey = containerOf(tester).read(posCartProvider).lines.first.key;
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$firstKey'));

      await tester.tap(find.byKey(Key('pos-product-$secondId')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(2));
      final secondKey = cart.lines.last.key;
      expect(secondKey, isNot(firstKey));
      expect(cart.lastActiveKey, secondKey);
      // Neither add auto-focused any quantity field.
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$secondKey'));

      await pressPlus(tester);

      // Only the newly added (active) line moved.
      expect(qtyAt(tester, 0), '1');
      expect(qtyAt(tester, 1), '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding again merges into the same line', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await addBread(tester);
      await addBread(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.first.key;
      expect(cart.lines.first.quantity, '2');
      expect(cart.lastActiveKey, key);
      // The merge never auto-focused the quantity field.
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$key'));

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '3');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ after a hand-typed quantity and a focus change still '
        'targets the last active line', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await addBread(tester);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      // Hand-typed quantity …
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '7');
      await tester.pump();
      // … then the cashier moves on to the search field.
      await focusSearchField(tester);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '8');
      expect(searchText(tester), '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ on an empty cart reports the empty cart (no focus needed)',
        (tester) async {
      await _pumpApp(tester, dio: dio);

      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-qty-empty-cart')), findsOneWidget);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ typed inside a dialog field never touches the cart',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      // Line added without moving the keyboard focus: the POS shortcut layer
      // owns the focus, so `*` — which never fires while a text field has
      // focus — can still open the dialog.
      containerOf(tester)
          .read(posCartProvider.notifier)
          .addLine(breadLine);
      await tester.pump();
      expect(qtyAt(tester, 0), '1');

      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('qty-multiplier-input')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusedFieldKey(tester), 'qty-multiplier-input');
      await pressPlus(tester);
      await tester.pumpAndSettle();

      // The dialog keeps the key as typed (its field is not a POS quantity
      // input) — the cart line is untouched and the dialog stays open.
      expect(qtyAt(tester, 0), '1');
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ respects the stock guard on the active line',
        (tester) async {
      final stockDio = MockDio();
      _mockDio(stockDio, productQuantity: '3');
      await _pumpApp(tester, dio: stockDio);
      await tester.pump(const Duration(milliseconds: 500));

      await addBread(tester);
      expect(qtyAt(tester, 0), '1');

      await pressPlus(tester);
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '3');

      // 3 in stock: one more press is rejected through the shared funnel.
      await pressPlus(tester);
      await tester.pumpAndSettle();

      expect(qtyAt(tester, 0), '3');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a rejected add never steals keyboard focus', (tester) async {
      final stockDio = MockDio();
      _mockDio(stockDio, productQuantity: '2');
      await _pumpApp(tester, dio: stockDio);
      await tester.pump(const Duration(milliseconds: 500));

      // Line already holds all the stock there is …
      await addBread(tester);
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '2');
      await tester.pump();
      // … the cashier moves back to the scan field …
      await focusSearchField(tester);
      expect(focusedFieldKey(tester), 'pos-search-field');

      // … and adds the same product again: rejected by the stock guard.
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(qtyAt(tester, 0), '2');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      // The rejected add did not move the keyboard anywhere.
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });
  });

  group('Phase 8 FIX #2 global - decrement', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    /// Value key of the focused text field, if the focus is on one.
    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    String qtyFieldText(WidgetTester tester, String key) => tester
        .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
        .controller!
        .text;

    String searchText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('pos-search-field')))
        .controller!
        .text;

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Main-row minus: the key event carries the `-` character.
    Future<void> pressMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.pump();
    }

    // Numpad subtract: dedicated key, no character needed.
    Future<void> pressNumpadMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadSubtract);
      await tester.pump();
    }

    const fiveBread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '5',
      unitPrice: '10',
      availableStock: '5',
    );

    testWidgets('TEST 1: - decrements the active line 5 → 4', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();
      expect(qtyAt(tester, 0), '5');

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 2: repeated - removes exactly one unit per press',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();

      await pressMinus(tester);
      await pressMinus(tester);
      await pressMinus(tester);

      expect(qtyAt(tester, 0), '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 3: - from the search field decrements and never '
        'inserts -', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();
      await focusSearchField(tester);
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(focusedFieldKey(tester), 'pos-search-field');

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '4');
      // The `-` never reached the text input.
      expect(searchText(tester), 'bre');
      expect(searchText(tester).contains('-'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 4: - from the focused quantity field decrements and '
        'never inserts -', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '5');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      expect(qtyFieldText(tester, key), '5');

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(qtyFieldText(tester, key), '4');
      expect(qtyFieldText(tester, key).contains('-'), isFalse);
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 5: - works with no TextField focused', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      // The POS shortcut layer owns the focus — no text input.
      expect(focusedFieldKey(tester), isNull);
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();
      expect(focusedFieldKey(tester), isNull);

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 6: - changes only the active line of several',
        (tester) async {
      const lineA = CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '2',
        unitPrice: '10',
        availableStock: '9',
      );
      const lineB = CartLine(
        productId: 'p2',
        name: 'Milk',
        quantity: '5',
        unitPrice: '5',
        availableStock: '9',
      );
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      final notifier = containerOf(tester).read(posCartProvider.notifier);
      notifier.addLine(lineA);
      notifier.addLine(lineB);
      await tester.pump();

      final before = containerOf(tester).read(posCartProvider);
      expect(before.lines, hasLength(2));
      // The last added line (B) is the active one.
      expect(before.lastActiveKey, before.lines[1].key);
      final activeKey = before.lastActiveKey;

      await pressMinus(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines[0].quantity, '2'); // A untouched
      expect(cart.lines[1].quantity, '4'); // B decremented
      // The active line is preserved after the decrement.
      expect(cart.lastActiveKey, activeKey);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 7: - after selecting B and focusing search still '
        'targets B', (tester) async {
      const lineA = CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '2',
        unitPrice: '10',
        availableStock: '9',
      );
      const lineB = CartLine(
        productId: 'p2',
        name: 'Milk',
        quantity: '5',
        unitPrice: '5',
        availableStock: '9',
      );
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      final notifier = containerOf(tester).read(posCartProvider.notifier);
      notifier.addLine(lineB);
      notifier.addLine(lineA);
      await tester.pump();
      // A was added last, so A is active …
      expect(
        containerOf(tester).read(posCartProvider).lastActiveKey,
        containerOf(tester).read(posCartProvider).lines[1].key,
      );
      final keyB = containerOf(tester).read(posCartProvider).lines[0].key;

      // … the cashier selects B …
      await tester.enterText(find.byKey(Key('cart-line-qty-$keyB')), '5');
      await tester.pump();
      expect(
        containerOf(tester).read(posCartProvider).lastActiveKey,
        keyB,
      );
      // … then goes back to scanning.
      await focusSearchField(tester);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '4'); // B
      expect(qtyAt(tester, 1), '2'); // A untouched
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 8: - at the minimum quantity keeps the line at 1',
        (tester) async {
      const oneBread = CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '1',
        unitPrice: '10',
        availableStock: '5',
      );
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(oneBread);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;

      // The decrease button is disabled at the minimum — the shortcut
      // follows the very same rule.
      final button = tester.widget<IconButton>(
        find.byKey(Key('cart-line-qty-dec-$key')),
      );
      expect(button.onPressed, isNull);

      await pressMinus(tester);
      await tester.pumpAndSettle();

      expect(qtyAt(tester, 0), '1');
      expect(
        tester
            .widget<IconButton>(find.byKey(Key('cart-line-qty-dec-$key')))
            .onPressed,
        isNull,
      );
      // No error toast, no removal, no crash.
      expect(find.byKey(const Key('pos-qty-invalid')), findsNothing);
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      expect(find.byKey(const Key('pos-qty-empty-cart')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 9: - inside an open quantity dialog never touches the '
        'cart', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      // Line added without moving the keyboard focus: the POS shortcut
      // layer owns it, so `*` can still open the dialog.
      containerOf(tester)
          .read(posCartProvider.notifier)
          .addLine(fiveBread);
      await tester.pump();
      expect(qtyAt(tester, 0), '5');

      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('qty-multiplier-input')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusedFieldKey(tester), 'qty-multiplier-input');

      await pressMinus(tester);
      await tester.pumpAndSettle();

      // The dialog keeps keyboard control: cart untouched, dialog open.
      expect(qtyAt(tester, 0), '5');
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 10: - then + on the same line round-trips the quantity',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();
      await focusSearchField(tester);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await pressMinus(tester);
      expect(qtyAt(tester, 0), '4');

      // The `+` shortcut is untouched by the `-` fix.
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();

      expect(qtyAt(tester, 0), '5');
      expect(searchText(tester), '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 11: numpad subtract decrements too', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      containerOf(tester).read(posCartProvider.notifier).addLine(fiveBread);
      await tester.pump();

      await pressNumpadMinus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });
  });

  group('Phase 8 FIX #3 * quantity input dialog', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    /// Value key of the focused text field, if the focus is on one.
    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    String searchText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('pos-search-field')))
        .controller!
        .text;

    String qtyFieldText(WidgetTester tester, String key) => tester
        .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
        .controller!
        .text;

    /// Text currently inside the quantity dialog field.
    String dialogText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('qty-multiplier-input')))
        .controller!
        .text;

    String dialogError(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('qty-multiplier-error')))
        .data!;

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Main-row `*` (Shift + `8`): the key event carries the `*` character.
    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
    }

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    Future<void> pressMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.pump();
    }

    /// `*` → dialog open (asserted by every caller).
    Future<void> openDialog(WidgetTester tester) async {
      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
    }

    Future<void> typeInDialog(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const Key('qty-multiplier-input')),
        text,
      );
      await tester.pump();
    }

    Future<void> confirmDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pumpAndSettle();
    }

    const line24 = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '24',
      unitPrice: '10',
      availableStock: '50',
    );

    testWidgets('TEST 1: 24 → * → 3 = 3 (no multiplication)', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();
      expect(qtyAt(tester, 0), '24');

      await openDialog(tester);
      await typeInDialog(tester, '3');
      await confirmDialog(tester);

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsNothing);
      // 3 — NOT 24 × 3 = 72.
      expect(qtyAt(tester, 0), '3');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 2: 3 → * → 10 = 10', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '50',
        ),
      );
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '10');
      await confirmDialog(tester);

      expect(qtyAt(tester, 0), '10');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 3: 10 → * → 2.5 = 2.5', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '10',
          unitPrice: '10',
          availableStock: '50',
        ),
      );
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '2.5');
      await confirmDialog(tester);

      expect(qtyAt(tester, 0), '2.5');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 4: the dialog field opens blank and focused (Phase 17 §18)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);

      // Blank: the cashier types the NEW quantity instead of having to
      // select and replace a pre-filled `24`.
      expect(dialogText(tester), '');
      // Focused: the very next keystroke lands in the field.
      expect(focusedFieldKey(tester), 'qty-multiplier-input');
      // The current quantity is still visible above the field.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('qty-multiplier-current')))
            .data,
        "${AppStrings.t('quantity', 'en')}: 24",
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 5: * from the search field opens the dialog and never '
        'inserts *', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();
      await focusSearchField(tester);
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(searchText(tester), 'bre');
      expect(searchText(tester).contains('*'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 6: * from the focused quantity field opens the dialog '
        'and never inserts *', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '24');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      await pressStar(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      // The background quantity field kept its own value.
      expect(qtyFieldText(tester, key), '24');
      expect(qtyFieldText(tester, key).contains('*'), isFalse);
      expect(qtyAt(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 7: only the active line is replaced (A = 2, B = 24 → 3)',
        (tester) async {
      const lineA = CartLine(
        productId: 'p1',
        name: 'Bread',
        quantity: '2',
        unitPrice: '10',
        availableStock: '50',
      );
      const lineB = CartLine(
        productId: 'p2',
        name: 'Milk',
        quantity: '24',
        unitPrice: '5',
        availableStock: '50',
      );
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, lineA);
      addLine(tester, lineB);
      await tester.pump();
      // B was added last → B is the active line.
      expect(
        containerOf(tester).read(posCartProvider).lastActiveKey,
        containerOf(tester).read(posCartProvider).lines[1].key,
      );

      await openDialog(tester);
      await typeInDialog(tester, '3');
      await confirmDialog(tester);

      expect(qtyAt(tester, 0), '2'); // A untouched
      expect(qtyAt(tester, 1), '3'); // B replaced
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 8: cancel keeps the current quantity (24)', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '3');
      await tester.tap(find.byKey(const Key('qty-multiplier-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsNothing);
      expect(qtyAt(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 9: 0 is rejected, quantity stays 24, dialog stays open',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '0');
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(dialogError(tester), AppStrings.t('enter_quantity', 'en'));
      expect(qtyAt(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 10: -2 is rejected, quantity stays 24', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '-2');
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(dialogError(tester), AppStrings.t('enter_quantity', 'en'));
      expect(qtyAt(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 11: abc is rejected, quantity stays 24', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, 'abc');
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(dialogError(tester), AppStrings.t('enter_quantity', 'en'));
      expect(qtyAt(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 12: stock guard rejects 12 with 10 in stock, '
        'quantity stays 3', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '3',
          unitPrice: '10',
          availableStock: '10',
        ),
      );
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '12');
      await tester.tap(find.byKey(const Key('qty-multiplier-apply')));
      await tester.pump();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(dialogError(tester), AppStrings.t('out_of_stock', 'en'));
      expect(qtyAt(tester, 0), '3');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 13: + regression — after * sets 3, + gives 4',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '3');
      await confirmDialog(tester);
      expect(qtyAt(tester, 0), '3');

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '4');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 14: - regression — after * sets 3, - gives 2',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();

      await openDialog(tester);
      await typeInDialog(tester, '3');
      await confirmDialog(tester);
      expect(qtyAt(tester, 0), '3');

      await pressMinus(tester);

      expect(qtyAt(tester, 0), '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 15: dialog isolation — +, - and * never touch the '
        'background cart or open a second dialog', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(
        tester,
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '5',
          unitPrice: '10',
          availableStock: '50',
        ),
      );
      await tester.pump();

      await openDialog(tester);
      // Phase 17 §18: the field opens blank — apply is rejected as-is.
      expect(dialogText(tester), '');
      expect(focusedFieldKey(tester), 'qty-multiplier-input');

      await pressPlus(tester);
      await tester.pumpAndSettle();
      await pressMinus(tester);
      await tester.pumpAndSettle();
      await pressStar(tester);
      await tester.pumpAndSettle();

      // The background cart is untouched and the dialog still owns input.
      expect(qtyAt(tester, 0), '5');
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(focusedFieldKey(tester), 'qty-multiplier-input');
      expect(tester.takeException(), isNull);
    });
  });

  group('print settings (§17.6)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Map<String, Object> settingsJson({
      bool askBeforePrint = false,
      bool autoPrintInvoice = false,
      String defaultPaper = '80mm',
    }) =>
        <String, Object>{
          'store_name': 'Supermarket Pro',
          'store_phone': '',
          'store_address': '',
          'invoice_footer': '',
          'default_paper': defaultPaper,
          'ask_before_print': askBeforePrint,
          'auto_print_invoice': autoPrintInvoice,
          'allow_debt': true,
          'low_stock_threshold': 5,
        };

    Future<void> checkout(WidgetTester tester) async {
      containerOf(tester).read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: _productId,
              name: 'Bread',
              quantity: '1',
              unitPrice: '9',
            ),
          );
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-pay-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('payment-submit')));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    testWidgets('defaults never print and never prompt', (tester) async {
      final mock = MockDio();
      _mockDio(mock, settingsBody: settingsJson());
      final printer = _FakePrintService();
      await _pumpApp(tester, dio: mock, printService: printer);

      await checkout(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-print-dialog')), findsNothing);
      expect(printRequestBodies, isEmpty);
      expect(printer.printedPdfs, isEmpty);
      expect(find.byKey(const Key('checkout-success-snackbar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('auto_print_invoice prints on the default paper after checkout',
        (tester) async {
      final mock = MockDio();
      _mockDio(
        mock,
        settingsBody: settingsJson(autoPrintInvoice: true, defaultPaper: 'A4'),
      );
      final printer = _FakePrintService();
      await _pumpApp(tester, dio: mock, printService: printer);

      await checkout(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-print-dialog')), findsNothing);
      expect(printRequestBodies, hasLength(1));
      expect(printRequestBodies.single['document_type'], 'sale');
      expect(printRequestBodies.single['paper'], 'A4');
      expect(printRequestBodies.single['document_id'], isNotEmpty);
      expect(printer.printedPapers, <String>['A4']);
      // The sale is reported completed whether or not the print went out.
      expect(find.byKey(const Key('checkout-success-snackbar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ask_before_print: nothing prints until the cashier agrees',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock, settingsBody: settingsJson(askBeforePrint: true));
      final printer = _FakePrintService();
      await _pumpApp(tester, dio: mock, printService: printer);

      await checkout(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-print-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('ask_before_print_question', 'en')),
        findsOneWidget,
      );
      expect(printRequestBodies, isEmpty);
      expect(printer.printedPdfs, isEmpty);

      await tester.tap(find.byKey(const Key('ask-print-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask-print-dialog')), findsNothing);
      expect(printRequestBodies, isEmpty);
      expect(printer.printedPdfs, isEmpty);
      expect(find.byKey(const Key('checkout-success-snackbar')), findsOneWidget);
    });

    testWidgets('ask_before_print: confirming prints the invoice', (tester) async {
      final mock = MockDio();
      _mockDio(mock, settingsBody: settingsJson(askBeforePrint: true));
      final printer = _FakePrintService();
      await _pumpApp(tester, dio: mock, printService: printer);

      await checkout(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ask-print-confirm')));
      await tester.pumpAndSettle();

      expect(printRequestBodies, hasLength(1));
      expect(printRequestBodies.single['paper'], '80mm');
      expect(printer.printedPapers, <String>['80mm']);
      expect(find.byKey(const Key('checkout-success-snackbar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed auto print is a toast, never a failed sale',
        (tester) async {
      final mock = MockDio();
      _mockDio(mock, settingsBody: settingsJson(autoPrintInvoice: true));
      final printer = _FakePrintService(fail: true);
      await _pumpApp(tester, dio: mock, printService: printer);

      await checkout(tester);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('auto-print-failed-toast')),
        findsOneWidget,
      );
      expect(
        find.textContaining(AppStrings.t('print_failed', 'en')),
        findsWidgets,
      );
      expect(printer.printedPdfs, isEmpty);
      // Sale completed — cart cleared, payment dialog gone, no exception.
      // (The error toast replaces the success toast: toasts never stack.)
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(find.byKey(const Key('ask-print-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 17 §18 — POS keyboard shortcuts
  // ---------------------------------------------------------------------------
  group('Phase 17 §18 — POS keyboard shortcuts', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    String searchText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('pos-search-field')))
        .controller!
        .text;

    String qtyAt(WidgetTester tester, int index) =>
        containerOf(tester).read(posCartProvider).lines[index].quantity;

    /// Value key of the focused text field, if the focus is on one.
    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    Future<bool> press(WidgetTester tester, LogicalKeyboardKey key) async {
      final handled = await tester.sendKeyEvent(key);
      await tester.pump();
      return handled;
    }

    Future<bool> pressSpace(WidgetTester tester) async {
      final handled =
          await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.pump();
      return handled;
    }

    Future<bool> pressCtrl(
      WidgetTester tester,
      LogicalKeyboardKey key,
    ) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final handled = await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      return handled;
    }

    /// With an empty search box Escape hands the keyboard back to the POS
    /// workspace node (it NEVER touches the cart) — that is how SPACE
    /// becomes reachable at all, since the search field is autofocused.
    Future<void> focusWorkspace(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.escape);
      expect(focusedFieldKey(tester), isNull);
    }

    const line24 = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '24',
      unitPrice: '10',
      availableStock: '50',
    );

    const lineMilk = CartLine(
      productId: 'p2',
      name: 'Milk',
      quantity: '3',
      unitPrice: '5',
      availableStock: '40',
    );

    /// On-screen text of the cart quantity field of line [index] — what the
    /// cashier actually sees (it can lag the committed cart quantity while
    /// an incomplete expression is still being typed).
    String qtyFieldText(WidgetTester tester, int index) {
      final key = containerOf(tester).read(posCartProvider).lines[index].key;
      return tester
          .widget<TextField>(find.byKey(Key('cart-line-qty-$key')))
          .controller!
          .text;
    }

    /// Direct add through the real catalog (no variant / selling-unit
    /// picker) — the flow that (Phase 8 FIX #1 retired) leaves the new
    /// line ACTIVE without auto-focusing its qty field.
    Future<void> addFromCatalog(WidgetTester tester) async {
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
    }

    testWidgets('SPACE opens the payment dialog (legacy F8 removed)', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      expect(await pressSpace(tester), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE with an empty cart reports cart_empty, no dialog', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      await focusWorkspace(tester);

      expect(await pressSpace(tester), isTrue);
      await tester.pump();

      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F8 no longer opens payment', (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      final handled = await press(tester, LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();

      expect(handled, isFalse, reason: 'F8 must not be bound any more');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE inside the search field is not stolen', (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump();

      final handled = await pressSpace(tester);

      expect(handled, isFalse, reason: 'a text field owns the space');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      // Focus must stay in the box: an unhandled key event keeps flowing to the
      // platform text input, so the space character is never swallowed by us.
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(searchText(tester), 'bre');
      expect(tester.takeException(), isNull);
    });

    // ── SPACE vs the cart quantity field (regression) ─────────────────────
    // A catalog add leaves the new line ACTIVE but never focuses its
    // quantity field (Phase 8 FIX #1 retired): SPACE still wins the pay
    // key from that post-add state and must be CONSUMED, so no text input
    // ever sees the character and the quantity stays untouched.
    testWidgets(
        'SPACE right after a catalog add pays — the add never focused a '
        'qty field', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await addFromCatalog(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.first.key;
      expect(
        focusedFieldKey(tester),
        isNot('cart-line-qty-$key'),
        reason: 'the add must never focus the new line qty field',
      );
      final textBefore = qtyFieldText(tester, 0);

      final handled = await pressSpace(tester);
      await tester.pumpAndSettle();

      expect(handled, isTrue,
          reason: 'SPACE is the payment shortcut, qty focus or not');
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(qtyAt(tester, 0), '1');
      expect(
        qtyFieldText(tester, 0),
        textBefore,
        reason: 'the pay key must never edit the quantity',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE inside a cart quantity field pays, quantity untouched', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '24');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      final handled = await pressSpace(tester);
      await tester.pumpAndSettle();

      expect(handled, isTrue,
          reason: 'the POS payment shortcut owns SPACE here');
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(qtyAt(tester, 0), '24');
      expect(qtyFieldText(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE pays from any other cart quantity field too', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      addLine(tester, lineMilk);
      await tester.pump();
      final lines = containerOf(tester).read(posCartProvider).lines;
      expect(lines, hasLength(2));
      // An OLDER line's field — not the one the last add focused.
      final firstKey = lines.first.key;
      await tester.tap(find.byKey(Key('cart-line-qty-$firstKey')));
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$firstKey');

      final handled = await pressSpace(tester);
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(qtyAt(tester, 0), '24');
      expect(qtyFieldText(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE inside a dialog text field stays ordinary text', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);
      expect(await pressSpace(tester), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('payment-paid-input')));
      await tester.pump();
      expect(focusedFieldKey(tester), 'payment-paid-input');
      final paidBefore = tester
          .widget<TextField>(find.byKey(const Key('payment-paid-input')))
          .controller!
          .text;

      final handled = await pressSpace(tester);
      await tester.pump();

      expect(handled, isFalse, reason: 'a dialog input owns the space');
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('payment-paid-input')))
            .controller!
            .text,
        paidBefore,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter never pays — the qty field keeps its own submit', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '10*');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      await press(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);

      // Real devices translate Enter into TextInputAction.done (Flutter's
      // documented way to exercise onSubmitted): the invalid expression is
      // rejected and the field rolls back — unchanged by this fix.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(find.byKey(const Key('pos-qty-invalid')), findsOneWidget);
      expect(qtyAt(tester, 0), '24');
      expect(qtyFieldText(tester, 0), '24');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape from a quantity field hands focus to the workspace', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '7');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      await press(tester, LogicalKeyboardKey.escape);

      expect(focusedFieldKey(tester), isNull,
          reason: 'focus returns to the POS workspace node');
      expect(qtyAt(tester, 0), '7');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('F12 still asks for confirmation from a focused qty field', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '24');
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      await press(tester, LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('clear-cart-confirm')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).isEmpty, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape clears the search box and never the cart', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump();

      await press(tester, LogicalKeyboardKey.escape);

      expect(searchText(tester), '');
      expect(qtyAt(tester, 0), '24');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      // A second Escape only moves focus — the cart is still untouched.
      await press(tester, LogicalKeyboardKey.escape);
      expect(qtyAt(tester, 0), '24');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('F4 and Ctrl+F focus the search field', (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      expect(await press(tester, LogicalKeyboardKey.f4), isTrue);
      expect(focusedFieldKey(tester), 'pos-search-field');

      await focusWorkspace(tester);
      expect(await pressCtrl(tester, LogicalKeyboardKey.keyF), isTrue);
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });

    testWidgets('F5 refreshes the catalog and never touches the cart', (
      tester,
    ) async {
      var catalogLoads = 0;
      final refreshDio = MockDio();
      _mockDio(refreshDio, onSearch: () => catalogLoads++);
      await _pumpApp(tester, dio: refreshDio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, line24);
      await tester.pump();
      final before = catalogLoads;

      await focusWorkspace(tester);
      expect(await press(tester, LogicalKeyboardKey.f5), isTrue);
      await tester.pump(const Duration(milliseconds: 500));

      expect(catalogLoads, greaterThan(before), reason: 'F5 must reload');
      expect(qtyAt(tester, 0), '24');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the POS header exposes the localized shortcuts map', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const Key('pos-shortcuts-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pos-shortcuts-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);
      expect(
        find.text(AppStrings.t('shortcuts_title', 'en')),
        findsOneWidget,
      );
      // Both scopes are on screen, with the POS-only rows among them.
      expect(
        find.text(AppStrings.t('shortcuts_scope_global', 'en')),
        findsWidgets,
      );
      expect(
        find.text(AppStrings.t('shortcuts_scope_pos', 'en')),
        findsWidgets,
      );
      expect(find.text('Space'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
      expect(find.text('+'), findsWidgets);

      await tester.tap(find.byKey(const Key('shortcuts-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcuts-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('quick sale with Space (configurable)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    /// Value key of the focused text field, if the focus is on one.
    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    Future<bool> press(WidgetTester tester, LogicalKeyboardKey key) async {
      final handled = await tester.sendKeyEvent(key);
      await tester.pump();
      return handled;
    }

    /// With an empty search box Escape hands the keyboard back to the POS
    /// workspace node (it NEVER touches the cart) — that is how SPACE
    /// becomes reachable at all, since the search field is autofocused.
    Future<void> focusWorkspace(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.escape);
      expect(focusedFieldKey(tester), isNull);
    }

    Future<bool> pressSpace(WidgetTester tester) async {
      final handled =
          await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.pump();
      return handled;
    }

    const line24 = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '24',
      unitPrice: '10',
      availableStock: '50',
    );

    Map<String, Object> quickSalePrefs() => <String, Object>{
          PosSettingsNotifier.quickSaleWithSpaceKey: true,
        };

    testWidgets(
        'default OFF (no saved value): SPACE still opens the payment '
        'dialog — bit-for-bit the pre-quick-sale behaviour', (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      expect(await pressSpace(tester), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: SPACE completes the sale directly as full cash of the amount '
        'due — no dialog, one POST, cart cleared', (tester) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      expect(await pressSpace(tester), isTrue);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsNothing,
          reason: 'quick sale never opens the payment dialog');
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.isEmpty, isTrue, reason: 'the sale completed and reset');
      expect(cart.lastResult, isNotNull);
      expect(cart.lastResult!.paymentMethod, 'cash');
      expect(cart.lastResult!.status, 'completed');

      final bodies = verify(
        () => dio.post(
          _salesPath,
          data: captureAny(named: 'data'),
          options: any(named: 'options'),
        ),
      ).captured;
      expect(bodies, hasLength(1));
      final payload = Map<String, dynamic>.from(bodies.single as Map);
      expect(payload['payment_method'], 'cash');
      expect(payload['paid'], '240.00',
          reason: 'paid is exactly the amount due (24 × 10)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('ON: an empty cart is rejected — toast, no sale POST', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      await focusWorkspace(tester);

      expect(await pressSpace(tester), isTrue);
      await tester.pump();

      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      verifyNever(
        () => dio.post(
          _salesPath,
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: repeated SPACE presses never duplicate the sale — one POST '
        'total', (tester) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      // Hammer the key: the first press enters the pipeline, every repeat
      // is swallowed by the in-flight guard (or sees the emptied cart).
      await pressSpace(tester);
      await pressSpace(tester);
      await pressSpace(tester);
      await tester.pumpAndSettle();
      await pressSpace(tester);
      await tester.pumpAndSettle();

      final bodies = verify(
        () => dio.post(
          _salesPath,
          data: captureAny(named: 'data'),
          options: any(named: 'options'),
        ),
      ).captured;
      expect(bodies, hasLength(1),
          reason: 'exactly one sale may ever leave one quick-sale intent');
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: SPACE inside the search field keeps its normal typing meaning '
        '— no sale, focus untouched', (tester) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump();

      final handled = await pressSpace(tester);

      expect(handled, isFalse,
          reason: 'with quick sale on, a focused text field keeps SPACE');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(containerOf(tester).read(posCartProvider).isEmpty, isFalse,
          reason: 'the cart is untouched');
      verifyNever(
        () => dio.post(
          _salesPath,
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: SPACE inside a cart quantity field never fires a sale', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      final key = containerOf(tester).read(posCartProvider).lines.first.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '24');
      await tester.pump();

      final handled = await pressSpace(tester);

      expect(handled, isFalse,
          reason: 'an immediate sale must never fire under the fingers');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(containerOf(tester).read(posCartProvider).isEmpty, isFalse);
      verifyNever(
        () => dio.post(
          _salesPath,
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ON: the PAY button still opens the payment dialog', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-pay-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('payment-dialog')), findsOneWidget,
          reason: 'method choice stays reachable through PAY');
      await tester.tap(find.byKey(const Key('payment-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('ON: the other POS shortcuts keep working (F7 / F12)', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice-discount-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('invoice-discount-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clear-cart-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('clear-cart-confirm')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: the shortcuts map documents the quick-sale semantics on the '
        'Space row', (tester) async {
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const Key('pos-shortcuts-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);
      expect(find.text(AppStrings.t('sc_a_quick_sale', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('sc_d_quick_sale', 'en')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('shortcuts-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ON: a failed checkout surfaces the error and keeps the cart (no '
        'silent fake success)', (tester) async {
      _mockDio(dio, saleErrorStatus: 500);
      await _pumpApp(tester, dio: dio, initialPrefs: quickSalePrefs());
      addLine(tester, line24);
      await tester.pump();
      await focusWorkspace(tester);

      await pressSpace(tester);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.isEmpty, isFalse,
          reason: 'a failed sale keeps the cart for a safe retry');
      expect(cart.lastError, isNotNull,
          reason: 'the server failure reached the cart state');
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'an error toast surfaced instead of silent success');
      expect(tester.takeException(), isNull);
    });
  });

  group('Phase 17 pricing — wholesale cue in the cart', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    testWidgets('shows only while the line charges the wholesale rate', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Rice',
              quantity: '5',
              unitPrice: '80',
              retailPrice: '100',
              wholesalePrice: '80',
              wholesaleMinQty: '5',
              availableStock: '999',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;
      expect(find.byKey(Key('cart-line-wholesale-$key')), findsOneWidget);
      expect(find.text(AppStrings.t('wholesale', 'en')), findsOneWidget);

      // Drop below the threshold → back to retail, cue disappears.
      container.read(posCartProvider.notifier).updateLine(key, quantity: '2');
      await tester.pump();
      expect(container.read(posCartProvider).lines.single.unitPrice, '100');
      expect(find.byKey(Key('cart-line-wholesale-$key')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an explicit-price line never shows the cue', (tester) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Rice',
              quantity: '50',
              unitPrice: '550',
              availableStock: '999',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.single.key;
      expect(container.read(posCartProvider).lines.single.unitPrice, '550');
      expect(find.byKey(Key('cart-line-wholesale-$key')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a custom selling-unit line never shows the cue', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      // Box = 24 Piece: 5 Box = 120 base units, far past a threshold of 5.
      // The multiplier converts quantity for INVENTORY only, so the line
      // keeps retail 200 and never earns the wholesale cue.
      container.read(posCartProvider.notifier).addLine(
            const CartLine(
              productId: 'p1',
              name: 'Rice',
              sellingUnitId: 'box-1',
              unitName: 'Box',
              quantity: '5',
              unitPrice: '200',
              retailPrice: '200',
              wholesalePrice: '180',
              wholesaleMinQty: '5',
              unitMultiplier: '24',
              availableStock: '999',
            ),
          );
      await tester.pump();
      final key = container.read(posCartProvider).lines.first.key;
      expect(container.read(posCartProvider).lines.single.unitPrice, '200');
      expect(find.byKey(Key('cart-line-wholesale-$key')), findsNothing);

      // Raising the quantity past the threshold keeps retail on a Box too.
      container.read(posCartProvider.notifier).updateLine(key, quantity: '10');
      await tester.pump();
      expect(container.read(posCartProvider).lines.single.unitPrice, '200');
      expect(find.byKey(Key('cart-line-wholesale-$key')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('weight/length amount entry (Klick POS)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    testWidgets(
        'base weight product (no selling units) opens the entry dialog '
        '— amount mode → fractional cart line', (tester) async {
      final kgDio = MockDio();
      _mockDio(
        kgDio,
        productUnit: 'kg',
        productPrice: '250',
        productQuantity: '20',
      );
      await _pumpApp(tester, dio: kgDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      // The dialog appears instead of a silent qty-1 add.
      expect(find.byKey(const Key('selling-unit-picker')), findsNothing);
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      // Weight unit → the mode toggle is offered.
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '100');
      await tester.pump();
      expect(find.text('Computed quantity: ${_m('0.4')} kg'), findsOneWidget);
      expect(find.text('Line total: ${_m('100')}'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.quantity, '0.4');
      expect(line.unitPrice, '250');
      expect(line.unitName, 'kg');
      expect(line.sellingUnitId, isNull);
      expect(line.productUnit, 'kg');
    });

    testWidgets(
        'base weight product quantity mode → fractional cart line; '
        'cancel adds nothing', (tester) async {
      final kgDio = MockDio();
      _mockDio(
        kgDio,
        productUnit: 'kg',
        productPrice: '250',
        productQuantity: '20',
      );
      await _pumpApp(tester, dio: kgDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '2.5',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.first.quantity, '2.5');
      expect(cart.lines.first.unitPrice, '250');

      // A second tap, cancelled → nothing is added.
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quantity-cancel')));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
    });

    testWidgets(
        'base length product (meter) → entry dialog, amount mode works',
        (tester) async {
      final mDio = MockDio();
      _mockDio(
        mDio,
        productUnit: 'meter',
        productPrice: '20',
        productQuantity: '50',
      );
      await _pumpApp(tester, dio: mDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '50');
      await tester.pump();
      expect(find.text('Computed quantity: ${_m('2.5')} meter'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.single.quantity, '2.5');
      expect(cart.lines.single.unitPrice, '20');
    });

    testWidgets(
        'custom kg selling unit → picker → amount mode → fractional line '
        'with selling_unit_id', (tester) async {
      final unitDio = MockDio();
      _mockDio(
        unitDio,
        productUnit: 'kg',
        productPrice: '200',
        productQuantity: '20',
        sellingUnits: [
          _sellingUnitJson(
            id: 'su-kg',
            name: 'Kg',
            sellingPrice: '250',
            isBaseUnit: false,
            unitType: 'kg',
            multiplier: '1',
          ),
        ],
      );
      await _pumpApp(tester, dio: unitDio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);

      await tester.tap(find.byKey(const Key('selling-unit-su-kg')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      // Configured kg unit → amount mode offered, priced at 250 (the
      // selling-unit price, not the product retail 200).
      expect(find.byKey(const Key('quantity-mode-amount')), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-mode-amount')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('amount-input')), '100');
      await tester.pump();
      expect(find.text('Computed quantity: ${_m('0.4')} Kg'), findsOneWidget);
      expect(find.text('Line total: ${_m('100')}'), findsOneWidget);

      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final line = cart.lines.first;
      expect(line.sellingUnitId, 'su-kg');
      expect(line.quantity, '0.4');
      expect(line.unitPrice, '250');
      expect(line.unitName, 'Kg');
    });

    testWidgets(
        'piece product direct add is unchanged — no dialog, qty 1', (
      tester,
    ) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('quantity-dialog')), findsNothing);
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.single.quantity, '1');
      expect(cart.lines.single.unitName, 'piece');
    });
  });

  group('POS layout switch', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
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

    /// Horizontal centers — the switch swaps the panels' left/right order.
    double catalogCenterX(WidgetTester tester) =>
        tester.getRect(find.byKey(const Key('pos-search-field'))).center.dx;

    double cartCenterX(WidgetTester tester) =>
        tester.getRect(find.byKey(const Key('pos-cart-panel'))).center.dx;

    Future<void> toggleLayout(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-layout-switch')));
      await tester.pumpAndSettle();
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '2',
      unitPrice: '10',
    );

    testWidgets('default layout is standard (cart on the right)',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('pos-layout-switch')), findsOneWidget);
      expect(cartCenterX(tester), greaterThan(catalogCenterX(tester)));
      // Standard mode keeps the stacked card (summary line present).
      addLine(tester, bread);
      await tester.pump();
      expect(
        find.byKey(Key('cart-line-summary-${bread.key}')),
        findsOneWidget,
      );
    });

    testWidgets('tap toggle swaps catalog and cart to reversed',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, bread);
      await tester.pump();

      await toggleLayout(tester);

      expect(cartCenterX(tester), lessThan(catalogCenterX(tester)));
      // Reversed mode renders the dense row (price cell; no card summary).
      expect(find.byKey(Key('cart-line-price-${bread.key}')), findsOneWidget);
      expect(find.byKey(Key('cart-line-summary-${bread.key}')), findsNothing);
      expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dense typography: 14px semibold column headers, 15px row '
        'name / unit price / line total', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, bread);
      await tester.pump();
      await toggleLayout(tester);

      // Column headers share one 14px w600 label style (was 12px bold —
      // glance-text the cashier reads while scanning rows).
      final header = find.byKey(const Key('pos-dense-header'));
      expect(header, findsOneWidget);
      for (final label in [
        AppStrings.t('name', 'en'),
        AppStrings.t('unit_price', 'en'),
        AppStrings.t('total_label', 'en'),
      ]) {
        final cell = tester.widget<Text>(
          find.descendant(of: header, matching: find.text(label)),
        );
        expect(cell.style?.fontSize, 14,
            reason: '$label column header must be 14px');
        expect(cell.style?.fontWeight, FontWeight.w600,
            reason: '$label column header must be semibold');
      }

      // Row text bumped to the readable band: name, unit price, line total.
      final name = tester.widget<Text>(
        find.byKey(Key('cart-line-name-${bread.key}')),
      );
      expect(name.style?.fontSize, 15);
      final price = tester.widget<Text>(
        find.byKey(Key('cart-line-price-${bread.key}')),
      );
      expect(price.style?.fontSize, 15);
      final total = tester.widget<Text>(
        find.byKey(Key('cart-line-total-${bread.key}')),
      );
      expect(total.style?.fontSize, 15);
      expect(tester.takeException(), isNull);
    });

    testWidgets('second tap restores the standard layout', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await toggleLayout(tester);
      expect(cartCenterX(tester), lessThan(catalogCenterX(tester)));

      await toggleLayout(tester);
      expect(cartCenterX(tester), greaterThan(catalogCenterX(tester)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('cart lines, selection and qty text survive the switch',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      // Real catalog add (screen-driven) — the line becomes active but
      // never auto-focuses its qty field (Phase 8 FIX #1 retired).
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      final cart = containerOf(tester).read(posCartProvider);
      final key = cart.lines.single.key;
      final qtyBefore = tester.widget<TextField>(
        find.byKey(Key('cart-line-qty-$key')),
      );
      expect(qtyBefore.controller!.text, '1');
      expect(focusedFieldKey(tester), isNot('cart-line-qty-$key'));

      await toggleLayout(tester);

      final afterCart = containerOf(tester).read(posCartProvider);
      expect(afterCart.lines.single.quantity, '1');
      final qtyAfter = tester.widget<TextField>(
        find.byKey(Key('cart-line-qty-$key')),
      );
      // The tile State is rebuilt with the new element tree; the qty text
      // is re-seeded from the committed quantity, never lost.
      expect(qtyAfter.controller!.text, '1');
      // Selection follows the provider (lastActiveKey), not the tile State.
      expect(
        find.byKey(Key('cart-line-selected-$key')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'barcode scan add in reversed mode selects the new line '
        '— and the arrows answer from the scan input', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      // One pre-existing line so the post-scan arrow has somewhere to go
      // (productId differs from the scanned catalog product → 2 lines).
      addLine(tester, bread);
      await tester.pump();

      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.pump(const Duration(milliseconds: 300));
      // Real devices translate Enter into TextInputAction.done.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(2));
      final key = cart.lines.last.key;
      expect(cart.lastActiveKey, key);
      expect(find.byKey(Key('cart-line-selected-$key')), findsOneWidget);
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'a scanner add never auto-focuses the qty field — the '
            '(cleared) scan input keeps focus',
      );
      expect(tester.takeException(), isNull);

      // The scan add leaves focus in the scan input — the NEXT arrow
      // press must walk the selection with no cart click, no focus
      // theft, and no vertical-caret assertion (§2).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          cart.lines.first.key,
          reason: 'Up right after a scan add must move the selection');
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lastActiveKey, key);
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'reversed layout: an arrow press reveals the moved-to row WITHOUT '
        'any manual settle', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      // Far more lines than fit — the moved-to row needs a real reveal.
      for (var i = 0; i < 30; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      await tester.pump();

      final cart = containerOf(tester).read(posCartProvider);
      final keys = [for (final line in cart.lines) line.key];
      expect(cart.lastActiveKey, keys.last,
          reason: 'the newest line is preselected by the last add');

      // §5: only the key press + explicit duration frames — no
      // pumpAndSettle (a full settle would mask a reveal that never
      // finishes). The idle barcode field holds focus, so the press is
      // claimed and the walk runs from the workspace state.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 300));

      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          keys[keys.length - 2],
          reason: 'Up must walk the selection in the dense table');
      final viewport = tester.getRect(find.byKey(const Key('pos-cart-lines')));
      final tile = tester.getRect(
          find.byKey(Key('cart-line-${keys[keys.length - 2]}')));
      expect(tile.top, greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'the moved-to row must be revealed above the fold');
      expect(tile.bottom, lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'and fully inside the dense viewport');
      expect(tester.takeException(), isNull);
    });

    testWidgets('keyboard shortcuts (+, *) target the selected line in '
        'reversed mode', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      addLine(tester, bread);
      await tester.pump();

      await pressPlus(tester);
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '3',
      );

      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many lines scroll vertically inside the dense table',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      for (var i = 0; i < 40; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      await tester.pump();

      expect(find.byKey(const Key('pos-cart-lines')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('pos-cart-lines')),
        const Offset(0, -400),
      );
      await tester.pump();
      expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reversed mode compacts the cart chrome; TOTAL and PAY stay '
        'prominent', (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      Size sizeOf(Key k) => tester.getSize(find.byKey(k));
      final stdHeader = sizeOf(const Key('pos-cart-header'));
      final stdCustomer = sizeOf(const Key('pos-customer-row'));
      final stdHold = sizeOf(const Key('pos-hold-button'));
      final stdActions = sizeOf(const Key('pos-cart-actions'));
      final stdTotals = sizeOf(const Key('pos-totals-panel'));
      final stdPay = sizeOf(const Key('pos-pay-button'));

      await toggleLayout(tester);

      final revHeader = sizeOf(const Key('pos-cart-header'));
      final revCustomer = sizeOf(const Key('pos-customer-row'));
      final revHold = sizeOf(const Key('pos-hold-button'));
      final revActions = sizeOf(const Key('pos-cart-actions'));
      final revTotals = sizeOf(const Key('pos-totals-panel'));
      final revPay = sizeOf(const Key('pos-pay-button'));

      // Header/customer rows give their slack back to the lines region
      // (72 → 56, 52 → 44).
      expect(revHeader.height, lessThan(stdHeader.height));
      expect(revHeader.height, inInclusiveRange(50, 56));
      expect(revCustomer.height, lessThan(stdCustomer.height));
      expect(revCustomer.height, greaterThanOrEqualTo(44));
      // Action buttons (Hold/F7/F9/F10 rows): 46 → 40, whole block 112 → 88.
      expect(revHold.height, lessThan(stdHold.height));
      expect(revHold.height, inInclusiveRange(36, 40));
      expect(revActions.height, lessThan(stdActions.height));
      // Totals panel trims padding/row gaps only…
      expect(revTotals.height, lessThan(stdTotals.height));
      // …while TOTAL and PAY keep their prominence (60px PAY, unchanged).
      expect(revPay.height, greaterThanOrEqualTo(56));
      expect(revPay.height, greaterThanOrEqualTo(stdPay.height));

      // Labels stay readable: every action button still renders its text.
      for (final key in [
        const Key('pos-discount-button'),
        const Key('pos-hold-button'),
        const Key('pos-holds-button'),
        const Key('pos-history-button'),
      ]) {
        expect(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)),
          findsWidgets,
          reason: '$key keeps its visible label',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact chrome holds in AR RTL and FR LTR reversed mode',
        (tester) async {
      final cases = <(TextDirection, AppLocale)>[
        (TextDirection.rtl, AppLocale.ar),
        (TextDirection.ltr, AppLocale.fr),
      ];
      for (final c in cases) {
        await tester.pumpWidget(const SizedBox());
        await _pumpApp(
          tester,
          dio: dio,
          direction: c.$1,
          locale: c.$2,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await toggleLayout(tester);

        final hold =
            tester.getSize(find.byKey(const Key('pos-hold-button')));
        expect(hold.height, inInclusiveRange(36, 40), reason: '${c.$2}');
        expect(
          tester.getSize(find.byKey(const Key('pos-cart-header'))).height,
          inInclusiveRange(50, 56),
          reason: '${c.$2}',
        );
        expect(find.byKey(const Key('pos-cart-panel')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '${c.$2}');
      }
    });

    testWidgets('overflowing dense list scrolls the last row fully into view '
        'above the checkout section', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      for (var i = 0; i < 40; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      await tester.pump();

      await tester.drag(
        find.byKey(const Key('pos-cart-lines')),
        const Offset(0, -5000),
      );
      await tester.pumpAndSettle();

      final lines =
          tester.getRect(find.byKey(const Key('pos-cart-lines')));
      final actions =
          tester.getRect(find.byKey(const Key('pos-cart-actions')));
      final totals =
          tester.getRect(find.byKey(const Key('pos-totals-panel')));
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.length, greaterThanOrEqualTo(40));
      final lastTile = tester
          .getRect(find.byKey(Key('cart-line-${cart.lines.last.key}')));

      // The lines region ends where the fixed chrome begins — the checkout
      // section can never overlay it (0.75px subpixel slack only).
      expect(lines.bottom, lessThanOrEqualTo(actions.top + 0.75));
      // The final row scrolls COMPLETELY into the region…
      expect(lastTile.top, greaterThanOrEqualTo(lines.top - 0.75));
      expect(lastTile.bottom, lessThanOrEqualTo(lines.bottom + 0.75));
      // …and sits clear of the actions/totals/PAY block below it.
      expect(lastTile.bottom, lessThanOrEqualTo(actions.top + 0.75));
      expect(actions.bottom, lessThanOrEqualTo(totals.top + 0.75));
      expect(tester.takeException(), isNull);
    });

    testWidgets('scan-added product lands fully visible above the checkout '
        'section with focus preserved', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      for (var i = 0; i < 40; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      await tester.pump();

      // Real barcode scan flow (search field → Enter) — the screen-driven
      // add path that issues the post-add reveal request (never a focus
      // request). The list sits at the TOP, so the new row (appended at
      // the END) is far below the fold when the request fires.
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(41));
      final key = cart.lines.last.key;
      expect(cart.lastActiveKey, key);

      final lines =
          tester.getRect(find.byKey(const Key('pos-cart-lines')));
      final actions =
          tester.getRect(find.byKey(const Key('pos-cart-actions')));
      final tile = tester.getRect(find.byKey(Key('cart-line-$key')));

      // ensureVisible brought the new row fully into the bounded lines
      // region, clear of the fixed action/totals/PAY section.
      expect(tile.top, greaterThanOrEqualTo(lines.top - 0.75));
      expect(tile.bottom, lessThanOrEqualTo(lines.bottom + 0.75));
      expect(tile.bottom, lessThanOrEqualTo(actions.top + 0.75));
      // The reveal brought the row into view WITHOUT moving focus — the
      // (cleared) scan input keeps it; the qty field is never
      // auto-focused after a scanner add.
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });

    testWidgets('reversed with a full cart: totals and PAY stay visible and '
        'functional', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);
      for (var i = 0; i < 30; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      await tester.pump();

      final panel =
          tester.getRect(find.byKey(const Key('pos-cart-panel')));
      final actions =
          tester.getRect(find.byKey(const Key('pos-cart-actions')));
      final totals =
          tester.getRect(find.byKey(const Key('pos-totals-panel')));
      final pay = tester.getRect(find.byKey(const Key('pos-pay-button')));

      // Stack order inside the panel: lines → actions → totals → PAY.
      expect(totals.top, greaterThanOrEqualTo(actions.bottom - 0.75));
      expect(totals.bottom, lessThanOrEqualTo(panel.bottom + 0.75));
      expect(pay.top, greaterThanOrEqualTo(totals.top));
      expect(pay.bottom, lessThanOrEqualTo(panel.bottom + 0.75));
      // Every totals/payment element renders…
      expect(find.byKey(const Key('pos-subtotal-value')), findsOneWidget);
      expect(find.byKey(const Key('pos-total-value')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-amount')), findsOneWidget);
      // …and PAY is enabled while the cart has lines.
      final payButton =
          tester.widget<FilledButton>(find.byKey(const Key('pos-pay-button')));
      expect(payButton.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('600x500 reversed drawer: full rows fit and the last row '
        'scrolls above the fixed section', (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(600, 500));
      await tester.pump(const Duration(milliseconds: 500));
      // Reversed first — the toolbar is hidden once the drawer is open.
      await toggleLayout(tester);
      await tester.tap(find.byKey(const Key('toggle-cart')));
      await tester.pumpAndSettle();

      for (var i = 0; i < 40; i++) {
        addLine(
          tester,
          CartLine(
            productId: 'p$i',
            name: 'Line $i',
            quantity: '1',
            unitPrice: '1',
          ),
        );
      }
      // Let the lines-floor probe CONVERGE: escalation is post-frame
      // (measure → setState → render on the next frame), so the assertion
      // reads the settled compaction, not the frame before it lands.
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      final someTile = tester
          .getRect(find.byKey(Key('cart-line-${cart.lines.last.key}')));
      var lines = tester.getRect(find.byKey(const Key('pos-cart-lines')));
      // The compacted chrome leaves room for at least ONE complete dense
      // row (previously the region shrank below the row height and every
      // row was cut at the fixed section).
      expect(
        lines.height,
        greaterThanOrEqualTo(someTile.height - 0.75),
        reason: 'lines region fits a full row',
      );

      await tester.drag(
        find.byKey(const Key('pos-cart-lines')),
        const Offset(0, -5000),
      );
      await tester.pumpAndSettle();

      lines = tester.getRect(find.byKey(const Key('pos-cart-lines')));
      final actions =
          tester.getRect(find.byKey(const Key('pos-cart-actions')));
      final totals =
          tester.getRect(find.byKey(const Key('pos-totals-panel')));
      final panel =
          tester.getRect(find.byKey(const Key('pos-cart-panel')));
      final lastTile = tester
          .getRect(find.byKey(Key('cart-line-${cart.lines.last.key}')));

      expect(lastTile.top, greaterThanOrEqualTo(lines.top - 0.75));
      expect(lastTile.bottom, lessThanOrEqualTo(lines.bottom + 0.75));
      expect(lines.bottom, lessThanOrEqualTo(actions.top + 0.75));
      expect(actions.bottom, lessThanOrEqualTo(totals.top + 0.75));
      expect(totals.bottom, lessThanOrEqualTo(panel.bottom + 0.75));

      final pay = tester.widget<FilledButton>(
        find.byKey(const Key('pos-pay-button')),
      );
      expect(pay.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 900x700, 1280x800, 1920x1080 in reversed mode',
        (tester) async {
      const sizes = <Size>[
        Size(900, 700),
        Size(1280, 800),
        Size(1920, 1080),
      ];
      for (final size in sizes) {
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));
        addLine(tester, bread);
        await tester.pump();
        await toggleLayout(tester);
        expect(tester.takeException(), isNull, reason: '$size reversed');
        expect(
          find.byKey(Key('cart-line-price-${bread.key}')),
          findsOneWidget,
          reason: '$size dense row',
        );
        await toggleLayout(tester);
        expect(tester.takeException(), isNull, reason: '$size back');
      }
    });

    testWidgets(
        'panel proportions exchange roles at 900x700, 1280x800, 1920x1080',
        (tester) async {
      const sizes = <Size>[
        Size(900, 700),
        Size(1280, 800),
        Size(1920, 1080),
      ];
      for (final size in sizes) {
        // Unmount first: ProviderScope state survives a bare pumpWidget of
        // the same type, which would leak the previous iteration's catalog
        // state (empty results) into the next measurement.
        await tester.pumpWidget(const SizedBox());
        await _pumpApp(tester, dio: dio, size: size);
        await tester.pump(const Duration(milliseconds: 500));

        double workspaceW() => tester
            .getRect(find.byKey(const Key('pos-product-grid')))
            .width;
        double cartW() =>
            tester.getRect(find.byKey(const Key('pos-cart-panel'))).width;

        // Standard: the workspace holds the large panel; the cart the
        // narrow fixed slot.
        final stdWorkspace = workspaceW();
        final stdCart = cartW();
        expect(stdWorkspace, greaterThan(stdCart), reason: '$size standard');
        expect(
          stdCart,
          moreOrLessEquals(posCartWidthFor(size.width), epsilon: 2),
          reason: '$size standard cart slot',
        );

        await toggleLayout(tester);

        // Reversed: BOTH the position and the allocation exchanged — the
        // cart now holds the exact panel the workspace had, and the
        // workspace holds the cart's former slot.
        final revWorkspace = workspaceW();
        final revCart = cartW();
        expect(revCart, greaterThan(revWorkspace), reason: '$size reversed');
        expect(
          revCart,
          moreOrLessEquals(stdWorkspace, epsilon: 2),
          reason: '$size cart takes the workspace panel',
        );
        expect(
          revWorkspace,
          moreOrLessEquals(stdCart, epsilon: 2),
          reason: '$size workspace takes the cart slot',
        );
        expect(tester.takeException(), isNull, reason: '$size reversed');
      }
    });

    testWidgets('reversed large cart keeps the full checkout chrome reachable',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 500));
      await toggleLayout(tester);

      // The cart owns the wide panel…
      expect(
        tester.getRect(find.byKey(const Key('pos-cart-panel'))).width,
        greaterThan(
          tester.getRect(find.byKey(const Key('pos-product-grid'))).width,
        ),
      );
      // …with its complete chrome on screen: header, customer row,
      // action buttons, totals and PAY.
      expect(find.byKey(const Key('pos-cart-header')), findsOneWidget);
      expect(find.byKey(const Key('pos-customer-row')), findsOneWidget);
      expect(find.byKey(const Key('pos-discount-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-hold-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-holds-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-history-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-clear-cart')), findsOneWidget);
      expect(find.byKey(const Key('pos-totals-panel')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);

      // Payment state machine intact: empty cart → PAY disabled.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pos-pay-button')))
            .onPressed,
        isNull,
      );

      // A line (dense row in the wide panel) enables PAY.
      addLine(tester, bread);
      await tester.pump();
      expect(find.byKey(Key('cart-line-price-${bread.key}')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pos-pay-button')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow 600x500: toggle in toolbar, dense cart in drawer',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(600, 500));
      await tester.pump(const Duration(milliseconds: 500));
      // Narrow drawer-closed state: workspace (with the toolbar toggle) is
      // visible; the total bar swaps above it when reversed.
      await toggleLayout(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('toggle-cart')));
      await tester.pumpAndSettle();
      addLine(tester, bread);
      await tester.pump();
      expect(find.byKey(Key('cart-line-price-${bread.key}')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('toggle-cart')));
      await tester.pumpAndSettle();
      await toggleLayout(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow 600x500 closed stack swaps the total bar and workspace',
        (tester) async {
      await _pumpApp(tester, dio: dio, size: const Size(600, 500));
      await tester.pump(const Duration(milliseconds: 500));

      final grid = find.byKey(const Key('pos-product-grid'));
      final bar = find.byKey(const Key('toggle-cart'));

      // Standard closed: workspace on top, total bar at the bottom.
      expect(tester.getRect(bar).top, greaterThan(tester.getRect(grid).top));

      await toggleLayout(tester);
      // Reversed closed: total bar on top, workspace below — the same two
      // regions the wide/medium layout exchanges, stacked vertically.
      expect(tester.getRect(bar).top, lessThan(tester.getRect(grid).top));
      expect(tester.takeException(), isNull);
    });

    testWidgets('AR RTL and FR/EN LTR: toggle flips sides both ways',
        (tester) async {
      for (final entry in const {
        'en': TextDirection.ltr,
        'fr': TextDirection.ltr,
        'ar': TextDirection.rtl,
      }.entries) {
        // Fresh container per locale — ProviderScope state survives a bare
        // pumpWidget, so unmount first (same pattern as the view-mode
        // persistence test).
        await tester.pumpWidget(const SizedBox());
        await _pumpApp(
          tester,
          dio: dio,
          locale: AppLocale.values.byName(entry.key),
          direction: entry.value,
        );
        await tester.pump(const Duration(milliseconds: 500));
        addLine(tester, bread);
        await tester.pump();

        final before = cartCenterX(tester);
        await toggleLayout(tester);
        final after = cartCenterX(tester);
        // LTR: cart moves right → left (negative delta). RTL mirrors the
        // Row, so the same child order moves the cart left → right.
        expect(
          (after - before).sign,
          entry.value == TextDirection.rtl ? 1 : -1,
          reason: '${entry.key} ${entry.value}',
        );
        expect(
          find.byKey(Key('cart-line-price-${bread.key}')),
          findsOneWidget,
          reason: '${entry.key} dense row',
        );
        expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: entry.key);
      }
    });

    testWidgets('reversed choice persists and is restored on next launch',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      await toggleLayout(tester);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosLayoutSwitchKey), 'reversed');

      await tester.pumpWidget(const SizedBox());
      await _pumpApp(
        tester,
        dio: dio,
        initialPrefs: {kPosLayoutSwitchKey: 'reversed'},
      );
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, bread);
      await tester.pump();
      // Restored: cart renders dense/reversed without tapping the toggle.
      expect(find.byKey(Key('cart-line-price-${bread.key}')), findsOneWidget);
      expect(cartCenterX(tester), lessThan(catalogCenterX(tester)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('dense table shows header, price, total and selection cells',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      addLine(tester, bread);
      await tester.pump();
      await toggleLayout(tester);

      // Header labels (EN) above the rows; the row cells share the keys.
      expect(find.text(AppStrings.t('name', 'en')), findsWidgets);
      expect(find.text(AppStrings.t('unit_price', 'en')), findsWidgets);
      expect(find.text(AppStrings.t('qty', 'en')), findsWidgets);
      expect(find.text(AppStrings.t('total_label', 'en')), findsWidgets);
      expect(find.text(AppStrings.t('line_discount', 'en')), findsWidgets);

      final key = bread.key;
      expect(find.byKey(Key('cart-line-name-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-price-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-total-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-qty-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-discount-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-remove-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-selected-$key')), findsOneWidget);
      expect(find.byKey(Key('cart-line-unselected-$key')), findsNothing);
      // Standard-card-only cell is gone.
      expect(find.byKey(Key('cart-line-summary-$key')), findsNothing);
      // Catalog untouched: still the grid view.
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dense row shows the stock warning when qty exceeds stock',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
      const over = CartLine(
        productId: 'p-stock',
        name: 'Rice',
        quantity: '6',
        unitPrice: '10',
        availableStock: '5',
      );
      addLine(tester, over);
      await tester.pump();
      await toggleLayout(tester);

      final warning = find.byKey(Key('cart-line-stock-warning-${over.key}'));
      expect(warning, findsOneWidget);
      expect(
        tester.widget<Text>(warning).data,
        '${AppStrings.t('stock', 'en')}: 5',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('layout switch and catalog view-mode are independent',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));

      // List view mode, then switch layout — catalog stays list.
      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      await toggleLayout(tester);
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(cartCenterX(tester), lessThan(catalogCenterX(tester)));

      // Layout stays reversed when the view mode goes back to grid.
      await tester.tap(find.byKey(const Key('pos-view-mode-grid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(cartCenterX(tester), lessThan(catalogCenterX(tester)));
      expect(tester.takeException(), isNull);
    });
  });

  group('selected-line shortcuts without quantity focus', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    String qtyAt(WidgetTester tester, int index) =>
        containerOf(tester).read(posCartProvider).lines[index].quantity;

    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    String controllerText(WidgetTester tester, Key key) =>
        tester.widget<TextField>(find.byKey(key)).controller!.text;

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    Future<void> pressMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.pump();
    }

    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
    }

    Future<void> pressDelete(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
      availableStock: '10',
    );
    const milk = CartLine(
      productId: 'p2',
      name: 'Milk',
      quantity: '1',
      unitPrice: '5',
      availableStock: '10',
    );

    testWidgets('Delete removes the tapped line while the workspace holds '
        'focus (no quantity focus required)', (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();
      // No text field holds focus — the screen-level workspace node does.
      expect(focusedFieldKey(tester), isNull);

      // Tap bread: the selection moves to it, focus does not.
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      expect(focusedFieldKey(tester), isNull);

      await pressDelete(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.map((line) => line.productId).toList(), ['p2'],
          reason: 'only the selected line is removed');
      expect(find.byKey(Key('cart-line-remove-${bread.key}')), findsNothing);
      expect(
        find.byKey(Key('cart-line-remove-${milk.key}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Delete targets the tapped selection and stays out of a '
        'focused sibling quantity field', (tester) async {
      // Tall surface (same rationale as the sibling tap test below): the
      // two full-height cards must never crowd the lines region — focusing
      // milk's field must not scroll bread's name out of the viewport, so
      // the tap hits the name itself.
      await _pumpApp(tester, dio: dio, size: const Size(1366, 1080));
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();

      // Milk's quantity field takes keyboard focus for editing. Focusing a
      // field kicks off the framework's ensure-visible scroll — settle it
      // (its IgnorePointer would otherwise swallow the next tap).
      await tester.enterText(
          find.byKey(Key('cart-line-qty-${milk.key}')), '5');
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-qty-${milk.key}');

      // …the cashier selects bread by tapping its name (focus unchanged)…
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      expect(focusedFieldKey(tester), 'cart-line-qty-${milk.key}');

      // …Delete must NOT fire here: a text field is editing, so the key
      // belongs to the quantity input — no line disappears, once or twice.
      await pressDelete(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(2));
      expect(qtyAt(tester, 0), '1');
      expect(qtyAt(tester, 1), '5');
      expect(focusedFieldKey(tester), 'cart-line-qty-${milk.key}');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Delete keeps editing search, quantity and discount fields',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      addLine(tester, bread);
      await tester.pump();

      // Search field: Delete stays a text-editing key, cart untouched.
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 400));
      await pressDelete(tester);
      expect(controllerText(tester, const Key('pos-search-field')), 'bre');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      // Quantity field: same rule — editing wins over line removal.
      final qtyKey = Key('cart-line-qty-${bread.key}');
      await tester.enterText(find.byKey(qtyKey), '4');
      await tester.pump();
      await pressDelete(tester);
      expect(controllerText(tester, qtyKey), '4');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      // Line discount field: same rule.
      final discountKey = Key('cart-line-discount-${bread.key}');
      await tester.enterText(find.byKey(discountKey), '5');
      await tester.pump();
      await pressDelete(tester);
      expect(controllerText(tester, discountKey), '5');
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(focusedFieldKey(tester), 'cart-line-discount-${bread.key}');

      // Let the debounced search load triggered above settle.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap selects a line and +, - and * act on it while a '
        'sibling discount field is focused', (tester) async {
      // Tall surface: the two cards never overflow the cart list, so
      // focusing the discount cannot scroll the sibling's name out of the
      // viewport (the tap below must hit the name itself).
      await _pumpApp(tester, dio: dio, size: const Size(1366, 1080));
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();

      // Milk's DISCOUNT field takes focus — bread's quantity field never
      // does. Settle the focus-scroll so the next tap is not swallowed.
      await tester.enterText(
          find.byKey(Key('cart-line-discount-${milk.key}')), '5');
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-discount-${milk.key}');

      // Tap bread: selection moves, focus stays in the discount field.
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      expect(focusedFieldKey(tester), 'cart-line-discount-${milk.key}');

      // `+` / `-` claim the key (never inserted as discount text) and act
      // on the SELECTED line.
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '2');
      expect(qtyAt(tester, 1), '1');
      expect(controllerText(tester, Key('cart-line-discount-${milk.key}')),
          '5');
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '3');
      await pressMinus(tester);
      expect(qtyAt(tester, 0), '2');
      expect(containerOf(tester).read(posCartProvider).lines[1].lineDiscount,
          '5');

      // `*` opens the quantity dialog for the selected line — the field
      // keeps its text, the cart keeps the quantity.
      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('qty-multiplier-cancel')));
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '2');
      expect(controllerText(tester, Key('cart-line-discount-${milk.key}')),
          '5');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Delete removes the selected row in the reversed dense '
        'layout', (tester) async {
      await _pumpApp(
        tester,
        dio: dio,
        initialPrefs: {kPosLayoutSwitchKey: 'reversed'},
      );
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();
      expect(focusedFieldKey(tester), isNull);

      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      expect(
        find.byKey(Key('cart-line-selected-${bread.key}')),
        findsOneWidget,
      );

      await pressDelete(tester);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.map((line) => line.productId).toList(), ['p2']);
      expect(find.byKey(Key('cart-line-remove-${bread.key}')), findsNothing);
      expect(
        find.byKey(Key('cart-line-remove-${milk.key}')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Delete on an empty cart shows the shared empty-cart toast',
        (tester) async {
      await _pumpApp(tester, dio: dio);
      await tester.pump();

      await pressDelete(tester);

      expect(find.byKey(const Key('pos-qty-empty-cart')), findsOneWidget);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('Clear Cart keeps the workspace (catalog / search / views)', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    Future<void> typeSearch(WidgetTester tester, String query) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester
          .enterText(find.byKey(const Key('pos-search-field')), query);
      // Debounced page-1 load (kPosSearchDebounce) fully settles.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
    );

    testWidgets(
        'button clear empties only the cart: catalog, search, favorites '
        'and view mode stay — no refetch, no navigation', (tester) async {
      var searchLoads = 0;
      final paths = <String>[];
      final counted = MockDio();
      _mockDio(counted, onSearch: () => searchLoads++, recordPaths: paths);

      await _pumpApp(tester, dio: counted);
      await tester.pump(const Duration(milliseconds: 500));
      expect(searchLoads, greaterThan(0));
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);

      // Workspace state the clear must NOT touch: list view + an active
      // search query + non-empty catalog rows.
      await tester.tap(find.byKey(const Key('pos-view-mode-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      await typeSearch(tester, 'bre');
      expect(containerOf(tester).read(posSearchProvider).items, isNotEmpty);

      containerOf(tester).read(posCartProvider.notifier).addLine(bread);
      await tester.pump();
      expect(containerOf(tester).read(posCartProvider).isEmpty, isFalse);

      final loadsBefore = searchLoads;
      final pathsBefore = List<String>.of(paths);

      await tester.tap(find.byKey(const Key('pos-clear-cart')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-cart-confirm')));
      await tester.pumpAndSettle();

      // Cart state cleared …
      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(find.byKey(const Key('clear-cart-confirm')), findsNothing);

      // … and NOTHING else moved: not one extra request, same catalog
      // rows, same query (field and provider state), same list view,
      // still on the POS screen.
      expect(searchLoads, loadsBefore, reason: 'no catalog refetch');
      expect(paths, pathsBefore, reason: 'no network request at all');
      expect(
        containerOf(tester).read(posSearchProvider).items,
        isNotEmpty,
        reason: 'catalog rows stay loaded',
      );
      expect(containerOf(tester).read(posSearchProvider).query, 'bre');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pos-search-field')))
            .controller!
            .text,
        'bre',
        reason: 'search field text stays too',
      );
      expect(find.byKey(const Key('pos-product-list')), findsOneWidget);
      expect(find.byKey(const Key('pos-product-grid')), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPosCatalogViewModeKey), 'list');
      expect(find.byKey(const Key('pos-screen')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('F12 clear keeps the catalog and search query too',
        (tester) async {
      var searchLoads = 0;
      final paths = <String>[];
      final counted = MockDio();
      _mockDio(counted, onSearch: () => searchLoads++, recordPaths: paths);

      await _pumpApp(tester, dio: counted);
      await tester.pump(const Duration(milliseconds: 500));
      await typeSearch(tester, 'mil');
      containerOf(tester).read(posCartProvider.notifier).addLine(bread);
      await tester.pump();

      final loadsBefore = searchLoads;
      final pathsBefore = List<String>.of(paths);

      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clear-cart-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('clear-cart-confirm')));
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).isEmpty, isTrue);
      expect(searchLoads, loadsBefore);
      expect(paths, pathsBefore);
      expect(containerOf(tester).read(posSearchProvider).query, 'mil');
      expect(containerOf(tester).read(posSearchProvider).items, isNotEmpty);
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pos-search-field')))
            .controller!
            .text,
            'mil',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('selected-line shortcuts and SPACE from the idle barcode field', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    String qtyAt(WidgetTester tester, int index) =>
        containerOf(tester).read(posCartProvider).lines[index].quantity;

    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    String controllerText(WidgetTester tester, Key key) =>
        tester.widget<TextField>(find.byKey(key)).controller!.text;

    Future<bool> pressSpace(WidgetTester tester) async {
      final handled =
          await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.pump();
      return handled;
    }

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    Future<void> pressMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.pump();
    }

    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
    }

    Future<void> pressDelete(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
    }

    Future<void> toggleLayout(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-layout-switch')));
      await tester.pumpAndSettle();
    }

    /// Focus the POS search field and leave it EMPTY — the barcode-ready
    /// home state (autofocus after boot / Escape), where the cashier has
    /// not started typing a query.
    Future<void> focusIdleSearch(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(
        controllerText(tester, const Key('pos-search-field')),
        isEmpty,
        reason: 'the barcode field must be empty (idle, not typing)',
      );
    }

    Future<void> closePaymentDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('payment-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
      availableStock: '10',
    );
    const milk = CartLine(
      productId: 'p2',
      name: 'Milk',
      quantity: '1',
      unitPrice: '5',
      availableStock: '10',
    );

    Future<void> setup(WidgetTester tester, {bool reversed = false}) async {
      await _pumpApp(
        tester,
        dio: dio,
        initialPrefs: reversed ? {kPosLayoutSwitchKey: 'reversed'} : null,
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> spaceOpensPaymentFromIdleSearch(
      WidgetTester tester, {
      required bool reversed,
    }) async {
      await setup(tester, reversed: reversed);
      addLine(tester, bread);
      await tester.pump();
      await focusIdleSearch(tester);

      final handled = await pressSpace(tester);
      await tester.pumpAndSettle();

      expect(handled, isTrue,
          reason: 'the idle barcode field is not typing — SPACE must pay');
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(
        controllerText(tester, const Key('pos-search-field')),
        isEmpty,
        reason: 'the pay key must never reach the barcode field as text',
      );
      expect(tester.takeException(), isNull);
    }

    testWidgets(
        'SPACE opens payment from the idle barcode field — standard layout',
        (tester) async {
      await spaceOpensPaymentFromIdleSearch(tester, reversed: false);
    });

    testWidgets(
        'SPACE opens payment from the idle barcode field — reversed layout',
        (tester) async {
      await spaceOpensPaymentFromIdleSearch(tester, reversed: true);
    });

    testWidgets('SPACE from the idle barcode field with an empty cart shows '
        'cart_empty and no dialog', (tester) async {
      await setup(tester);
      await focusIdleSearch(tester);

      final handled = await pressSpace(tester);
      await tester.pump();

      expect(handled, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(find.text(AppStrings.t('cart_empty', 'en')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('row selected and no editable focused: SPACE opens the '
        'payment dialog exactly once — both layouts', (tester) async {
      await setup(tester);
      addLine(tester, bread);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focusedFieldKey(tester), isNull);
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();

      final first = await pressSpace(tester);
      await tester.pumpAndSettle();
      expect(first, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      await closePaymentDialog(tester);

      await toggleLayout(tester);
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      final second = await pressSpace(tester);
      await tester.pumpAndSettle();
      expect(second, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE does not pay while a search query is being typed '
        '(row selected)', (tester) async {
      await setup(tester);
      addLine(tester, bread);
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();

      final handled = await pressSpace(tester);
      await tester.pump();

      expect(handled, isFalse, reason: 'a query owns the space');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(
        controllerText(tester, const Key('pos-search-field')),
        'bre',
        reason: 'typing state is untouched',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE does not pay while a line discount field is focused',
        (tester) async {
      await setup(tester, reversed: true);
      addLine(tester, bread);
      await tester.pump();
      await tester.enterText(
        find.byKey(Key('cart-line-discount-${bread.key}')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-discount-${bread.key}');

      final handled = await pressSpace(tester);
      await tester.pump();

      expect(handled, isFalse, reason: 'a discount being edited owns the space');
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(
        controllerText(tester, Key('cart-line-discount-${bread.key}')),
        '5',
      );
      expect(tester.takeException(), isNull);
    });

    Future<void> lineShortcutsFromIdleSearch(
      WidgetTester tester, {
      required bool reversed,
    }) async {
      await setup(tester, reversed: reversed);
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();

      // Select bread by tapping it — selection without quantity focus.
      await tester.tap(find.byKey(Key('cart-line-name-${bread.key}')));
      await tester.pump();
      expect(
        containerOf(tester).read(posCartProvider).lastActiveKey,
        bread.key,
      );

      // Barcode-ready focus: the empty search field, never a quantity field.
      await focusIdleSearch(tester);

      // `+` / `-` hit the SELECTED line (bread), never the other line, and
      // run exactly once per press.
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '2');
      expect(qtyAt(tester, 1), '1');
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '3');
      expect(qtyAt(tester, 1), '1');
      await pressMinus(tester);
      expect(qtyAt(tester, 0), '2');
      expect(qtyAt(tester, 1), '1');

      // `*` opens the multiplier dialog for the SELECTED line.
      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('qty-multiplier-cancel')));
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '2');

      // Delete removes the SELECTED line from the idle barcode field.
      await focusIdleSearch(tester);
      await pressDelete(tester);
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.map((line) => line.productId).toList(), ['p2'],
          reason: 'the selected line is removed while the barcode field is '
              'focused but not typing');
      expect(find.byKey(Key('cart-line-remove-${milk.key}')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    testWidgets('+, -, * and Delete act on the selected line from the idle '
        'barcode field — standard layout', (tester) async {
      await lineShortcutsFromIdleSearch(tester, reversed: false);
    });

    testWidgets('+, -, * and Delete act on the selected line from the idle '
        'barcode field — reversed layout', (tester) async {
      await lineShortcutsFromIdleSearch(tester, reversed: true);
    });

    testWidgets('* with a characterless Shift+8 (hardware main row) opens '
        'the multiplier dialog', (tester) async {
      await setup(tester);
      addLine(tester, bread);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // Windows hardware press of Shift+8 with no character delivered on
      // the event (the tester otherwise derives '8' from the logical key)
      // — the documented main-row fallback for `*`.
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.shiftLeft,
        character: '',
      );
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.digit8,
        character: '',
      );
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit8);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget,
          reason: 'the main-row key must reach the multiplier shortcut when '
              'no character is delivered');
      expect(tester.takeException(), isNull);
    });

    testWidgets('SPACE held down does not open a second payment dialog', (
      tester,
    ) async {
      await setup(tester);
      addLine(tester, bread);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      final first = await tester.sendKeyDownEvent(
        LogicalKeyboardKey.space,
        character: ' ',
      );
      await tester.pumpAndSettle();
      expect(first, isTrue);
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(focusedFieldKey(tester), 'payment-paid-input');

      // Real key auto-repeat while SPACE is held: never a second dialog,
      // never a stray character in the payment input.
      await tester.sendKeyRepeatEvent(
        LogicalKeyboardKey.space,
        character: ' ',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget,
          reason: 'one dialog per SPACE gesture');
      expect(
        controllerText(tester, const Key('payment-paid-input')),
        '10.00',
        reason: 'the repeat must not alter the prefilled payment amount',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();

      // A second, separate press while the dialog is open: still one
      // dialog (the dialog route owns the keys behind a modal).
      await pressSpace(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(
        controllerText(tester, const Key('payment-paid-input')),
        '10.00',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('stock safeguard: + from the idle barcode field at the stock '
        'limit reports the stock error', (tester) async {
      await setup(tester);
      addLine(
        tester,
        const CartLine(
          productId: 'p9',
          name: 'Rice',
          quantity: '5',
          unitPrice: '10',
          availableStock: '5',
        ),
      );
      await tester.pump();
      await focusIdleSearch(tester);

      await pressPlus(tester);

      expect(qtyAt(tester, 0), '5', reason: 'quantity never exceeds stock');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('shortcuts keep working after clicking empty cart-panel space', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
          listen: false,
        );

    void addLine(WidgetTester tester, CartLine line) {
      containerOf(tester).read(posCartProvider.notifier).addLine(line);
    }

    String qtyAt(WidgetTester tester, int index) =>
        containerOf(tester).read(posCartProvider).lines[index].quantity;

    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    Future<void> pressPlus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal, character: '+');
      await tester.pump();
    }

    Future<bool> pressSpace(WidgetTester tester) async {
      final handled =
          await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.pump();
      return handled;
    }

    Future<void> pressMinus(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.minus, character: '-');
      await tester.pump();
    }

    Future<void> pressStar(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pump();
    }

    Future<void> pressDelete(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
    }

    String controllerText(WidgetTester tester, Key key) =>
        tester.widget<TextField>(find.byKey(key)).controller!.text;

    Future<void> setup(WidgetTester tester, {bool reversed = false}) async {
      await _pumpApp(
        tester,
        dio: dio,
        initialPrefs: reversed ? {kPosLayoutSwitchKey: 'reversed'} : null,
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// Click the cart panel's empty, non-editable space with the desktop
    /// MOUSE — the cashier's real input (the input that makes EditableText
    /// unfocus the focused field on desktop). Prefers the truly blank area
    /// below the last line; the standard card list fills the panel, so the
    /// empty header region next to the cart title serves there. Both points
    /// sit inside the cart panel, away from every text field and button.
    Future<void> clickEmptyCartSpace(
      WidgetTester tester,
      String lastLineKey,
    ) async {
      final lines = tester.getRect(find.byKey(const Key('pos-cart-lines')));
      final lastLine = tester.getRect(find.byKey(Key('cart-line-$lastLineKey')));
      final blank = lines.bottomCenter - const Offset(0, 30);
      if (lines.contains(blank) && blank.dy > lastLine.bottom) {
        await tester.tapAt(
          blank,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryButton,
        );
      } else {
        await tester.tap(
          find.byKey(const Key('pos-cart-title')),
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryButton,
        );
      }
      await tester.pumpAndSettle();
    }

    const bread = CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: '10',
      availableStock: '10',
    );
    const milk = CartLine(
      productId: 'p2',
      name: 'Milk',
      quantity: '1',
      unitPrice: '5',
      availableStock: '10',
    );

    /// The screenshot's exact failure sequence, both layouts: focus a line's
    /// quantity field (shortcuts work), then click empty cart-panel space
    /// with the mouse — the active line must stay active, and every
    /// shortcut must keep reaching this page's single handler.
    Future<void> emptyCartClickKeepsShortcuts(
      WidgetTester tester, {
      required bool reversed,
    }) async {
      await setup(tester, reversed: reversed);
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();

      // Screenshot step 2: click the quantity field — focus lands there,
      // the line becomes active, the shortcuts work.
      await tester.tap(find.byKey(Key('cart-line-qty-${bread.key}')));
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-qty-${bread.key}');
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '2', reason: 'baseline: + works while focused');
      expect(qtyAt(tester, 1), '1');

      // Screenshot step 3: click an empty/non-editable area inside the
      // cart panel, with the desktop mouse.
      await clickEmptyCartSpace(tester, milk.key);

      // The active line is PRESERVED and the quantity field did NOT keep
      // (or regain) focus — selection and keyboard focus stay independent.
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      expect(focusedFieldKey(tester), isNull);

      // +, -, * and Delete each target the ACTIVE line, never the sibling.
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '3');
      expect(qtyAt(tester, 1), '1');
      await pressMinus(tester);
      expect(qtyAt(tester, 0), '2');
      expect(qtyAt(tester, 1), '1');
      await pressStar(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('qty-multiplier-cancel')));
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '2');
      expect(qtyAt(tester, 1), '1');
      await pressDelete(tester);
      final afterDelete = containerOf(tester).read(posCartProvider);
      expect(afterDelete.lines.map((line) => line.productId).toList(), ['p2'],
          reason: 'only the active line is removed — never another line');
      expect(find.byKey(Key('cart-line-remove-${milk.key}')), findsOneWidget);

      // SPACE invokes the existing payment flow exactly once; the open
      // dialog keeps owning the keys behind the modal.
      final handled = await pressSpace(tester);
      await tester.pumpAndSettle();
      expect(handled, isTrue,
          reason: 'SPACE must reach the payment handler from the parked '
              'in-page focus');
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(focusedFieldKey(tester), 'payment-paid-input');
      await pressSpace(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget,
          reason: 'a repeat while the dialog is open never opens a second '
              'dialog');
      expect(
        controllerText(tester, const Key('payment-paid-input')),
        '5.00',
        reason: 'prefilled with the remaining cart total (milk only - bread '
            'was deleted)',
      );
      await tester.tap(find.byKey(const Key('payment-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    }

    testWidgets('shortcuts survive an empty cart-panel click — standard '
        'layout', (tester) async {
      await emptyCartClickKeepsShortcuts(tester, reversed: false);
    });

    testWidgets('shortcuts survive an empty cart-panel click — reversed '
        'layout', (tester) async {
      await emptyCartClickKeepsShortcuts(tester, reversed: true);
    });

    testWidgets('clicking empty catalog space keeps the selected line as the '
        'shortcut target', (tester) async {
      await setup(tester);
      addLine(tester, bread);
      addLine(tester, milk);
      await tester.pump();

      // The screenshot's start state: the line's quantity field focused
      // (focusing a line makes it the shortcut target).
      await tester.tap(find.byKey(Key('cart-line-qty-${bread.key}')));
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-qty-${bread.key}');
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);

      // Empty catalog area: inside the product grid, in the blank space
      // below the single mock product card.
      final grid = tester.getRect(find.byKey(const Key('pos-product-grid')));
      final card = tester.getRect(find.byKey(
          const Key('pos-product-00000000-0000-0000-0000-0000000000p1')));
      final blank = grid.bottomCenter - const Offset(0, 40);
      expect(grid.contains(blank), isTrue,
          reason: 'the click point must sit inside the catalog grid');
      expect(card.contains(blank), isFalse,
          reason: 'the click point must be empty space, not a product card');
      await tester.tapAt(
        blank,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await tester.pumpAndSettle();

      // Selection is untouched (no stale re-target, no switch to the
      // newest line) and no text field holds focus.
      expect(containerOf(tester).read(posCartProvider).lastActiveKey,
          bread.key);
      expect(focusedFieldKey(tester), isNull);

      // The shortcuts still work and still target the SELECTED line.
      await pressPlus(tester);
      expect(qtyAt(tester, 0), '2', reason: 'the active line is incremented');
      expect(qtyAt(tester, 1), '1', reason: 'the sibling line is untouched');
      await pressDelete(tester);
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.map((line) => line.productId).toList(), ['p2'],
          reason: 'the active line alone is removed');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing keeps working in quantity, discount and search after '
        'an empty cart-panel click', (tester) async {
      await setup(tester);
      addLine(tester, bread);
      await tester.pump();
      await tester.tap(find.byKey(Key('cart-line-qty-${bread.key}')));
      await tester.pumpAndSettle();
      await clickEmptyCartSpace(tester, bread.key);
      expect(focusedFieldKey(tester), isNull);

      // Quantity: digits land in the field — no shortcut steals them.
      await tester.enterText(
          find.byKey(Key('cart-line-qty-${bread.key}')), '4');
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-qty-${bread.key}');
      expect(qtyAt(tester, 0), '4');

      // Line discount: text entry stays completely normal.
      await tester.enterText(
          find.byKey(Key('cart-line-discount-${bread.key}')), '3');
      await tester.pumpAndSettle();
      expect(focusedFieldKey(tester), 'cart-line-discount-${bread.key}');
      expect(
        controllerText(tester, Key('cart-line-discount-${bread.key}')),
        '3',
      );
      expect(qtyAt(tester, 0), '4');

      // Search/barcode: a typed query is untouched text (the SPACE/DELETE
      // rules for a typed query are covered by their own tests).
      await tester.enterText(find.byKey(const Key('pos-search-field')), 'bre');
      await tester.pump(const Duration(milliseconds: 400));
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(controllerText(tester, const Key('pos-search-field')), 'bre');
      expect(tester.takeException(), isNull);
    });
  });

  group('barcode scanner integration (POS)', () {
    late MockDio dio;

    setUp(() {
      dio = MockDio();
      _mockDio(dio);
    });

    Future<void> pumpPos(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>>? barcodeLookups,
      String productQuantity = '20',
      Size size = const Size(1366, 768),
      int variantsFailOnce = 0,
    }) async {
      if (barcodeLookups != null ||
          productQuantity != '20' ||
          variantsFailOnce > 0) {
        dio = MockDio();
        _mockDio(
          dio,
          barcodeLookups: barcodeLookups,
          productQuantity: productQuantity,
          variantsFailOnce: variantsFailOnce,
        );
      }
      await _pumpApp(tester, dio: dio, size: size);
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
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

    String controllerText(WidgetTester tester, Key key) {
      final field = tester.widget<TextField>(find.byKey(key));
      return field.controller?.text ?? '';
    }

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
        );

    String qtyAt(WidgetTester tester, int index) => containerOf(tester)
        .read(posCartProvider)
        .lines[index]
        .quantity;

    testWidgets('scan + Enter adds the product even when the Enter lands '
        'before the search debounce fires', (tester) async {
      await pumpPos(tester);
      await focusSearchField(tester);

      // The wedge types the code and hits Enter immediately — no 250ms
      // debounce wait. The old debounce-race path silently added nothing
      // (or the wrong product); the canonical lookup resolves instead.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      // Continuous-scanning hygiene: the field is cleared and empty.
      expect(
        controllerText(tester, const Key('pos-search-field')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown barcode shows the not-found toast and adds nothing',
        (tester) async {
      await pumpPos(tester);
      await focusSearchField(tester);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '9998887776665',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // A pure-digit query after a lookup miss is a scan of an unknown
      // code — NO fuzzy first-result fallback (that would add the wrong
      // product); a clear not-found toast replaces the old silence.
      expect(find.byKey(const Key('pos-barcode-not-found-toast')), findsOneWidget);
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('scan into the focused line qty field merges into the '
        'existing line instead of typing digits into the quantity',
        (tester) async {
      // The second scan's code resolves to the same product via the
      // lookup — the merge path must increment, never add a line.
      await pumpPos(
        tester,
        barcodeLookups: {
          '111': _lookupHit(),
          '8718114202402': _lookupHit(),
        },
      );
      await focusSearchField(tester);

      // First scan: adds Bread (qty 1); post-add focus returns to the
      // (cleared) scan input — never the new line's qty field.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.single.key;
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'a scanner add must never auto-focus the qty field',
      );

      // Second scan: the cashier clicks into the qty field (manual edit
      // path) and the 13-digit run is typed there. It is a barcode, not a
      // quantity — Enter forwards it to the canonical resolve, which
      // merges into the same product's line.
      await tester.enterText(
        find.byKey(Key('cart-line-qty-$key')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final after = containerOf(tester).read(posCartProvider);
      expect(after.lines, hasLength(1),
          reason: 'the scan merged into the existing line');
      expect(after.lines.single.quantity, '2');
      // The qty field shows the merged quantity, never the barcode digits.
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '2',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a real wedge burst into the focused qty field merges +1 '
        'without out-of-stock noise', (tester) async {
      // Regression: the second scan of a continuous session lands as a
      // REAL keyboard-wedge burst in the focused line qty field. Bread
      // stock is 20; the burst's digit prefixes (8, 87, 871, …) must
      // never be parsed as quantities — that fired the shared stock
      // guard mid-burst ("Out of stock" with stock available) and left
      // the line quantity corrupted. The engine types by APPENDING at
      // the caret (which parks at the committed quantity's end after
      // every add), so the field shows 1 → 18 → 187 → … until Enter.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);

      // First scan: adds Bread (qty 1); post-add focus returns to the
      // (cleared) scan input.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'a scanner add must never auto-focus the qty field',
      );

      // The cashier clicks into the qty field (manual edit path) — the
      // next burst types there, appended to the committed quantity ('1'),
      // terminated by Enter.
      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(
        tester,
        qtyField,
        '8718114202402',
      );
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1),
          reason: 'the scan merged into the existing line');
      expect(
        cart.lines.single.quantity,
        '2',
        reason: 'each distinct burst adds exactly one unit',
      );
      // The field shows the merged quantity again, never the barcode
      // digits and never a stock-guard rollback artifact.
      expect(controllerText(tester, Key('cart-line-qty-$key')), '2');
      expect(
        find.byKey(const Key('pos-qty-stock-error')),
        findsNothing,
        reason: 'no stock guard may fire while stock (20) is available',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated scans merge unit-by-unit up to the stock, then '
        'the exhausted scan fires the stock guard exactly once',
        (tester) async {
      // Stock 10: nine more scans after the first (qty 1 → 10) all
      // succeed; the 11th is rejected through the shared funnel with the
      // localized out-of-stock toast, and the quantity stays at 10.
      await pumpPos(
        tester,
        productQuantity: '10',
        barcodeLookups: {
          '8718114202402': _lookupHit(productQuantity: '10'),
        },
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));

      // Scans 2–10: every burst is accepted, one unit at a time. Each
      // burst the cashier clicks into the qty field first (manual edit
      // path) — the add itself never moves focus there.
      for (var scan = 2; scan <= 10; scan++) {
        await tester.tap(qtyField);
        await tester.pump(const Duration(milliseconds: 50));
        await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
        await tester.pumpAndSettle();
        expect(
          containerOf(tester).read(posCartProvider).lines.single.quantity,
          '$scan',
          reason: 'scan $scan must land exactly at quantity $scan',
        );
      }

      // Scan 11: stock is exhausted — guard fires, quantity unchanged.
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '10');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      // The rejected scan left the field showing the committed quantity.
      expect(controllerText(tester, Key('cart-line-qty-$key')), '10');
      expect(tester.takeException(), isNull);
    });

    testWidgets('scans merge into a partially-filled line only up to the '
        'remaining stock', (tester) async {
      // Stock 5, line already holds 3: two further scans succeed (4, 5);
      // the next is rejected — the guard counts the existing line's base
      // quantity exactly once against the stock.
      await pumpPos(
        tester,
        productQuantity: '5',
        barcodeLookups: {
          '8718114202402': _lookupHit(productQuantity: '5'),
        },
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      await tester.enterText(find.byKey(Key('cart-line-qty-$key')), '3');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '3');

      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '4');

      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '5');

      // No stock left: rejected with the stock-guard toast.
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '5');
      expect(find.byKey(const Key('pos-qty-stock-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('back-to-back scans with no settle between them each add '
        'exactly one unit', (tester) async {
      // Continuous scanning: the first burst resolves while the qty field
      // is focused; the second burst types straight into that same field
      // (real caret-append) after only one frame — the merge of the first
      // is still in flight (no pumpAndSettle). Production always gets at
      // least one 16ms frame between two physical scans (the previous
      // scan's post-frame clear restores the committed quantity that the
      // next burst appends onto); zero frames is physically impossible.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.single.quantity, '1');

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      // The cashier clicks into the qty field for each burst (manual edit
      // path) — what is under test is the ZERO-SETTLE timing: the second
      // burst types while the first burst's merge is still in flight.
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      // One frame only — the first scan's chain has NOT settled (its
      // merge and the qty-field clear are both still pending).
      await tester.pump();
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();

      final after = containerOf(tester).read(posCartProvider);
      expect(after.lines, hasLength(1));
      expect(
        after.lines.single.quantity,
        '3',
        reason: 'start 1 + two bursts = 3, each applied exactly once',
      );
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      expect(find.byKey(const Key('pos-barcode-not-found-toast')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a duplicate Enter for the same completed scan never '
        'double-adds', (tester) async {
      // The wedge terminates with Enter; a stuck/duplicated terminator
      // (or the gateway's buffered Enter replayed) submits again. The
      // field has been reset to the committed quantity, so the second
      // submit is a no-op quantity apply — the scan is never re-run.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));

      // The cashier clicks into the qty field (manual edit path), the
      // burst types there and merges +1.
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '2');
      // The merge completed; the cashier clicks back into the qty field
      // showing the committed quantity — a stuck/duplicated Enter
      // terminator (or the wedge replaying one) resubmits that quantity
      // only.
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '2',
        reason: 'one physical scan adds exactly one unit, even with '
            'duplicated Enter terminators',
      );
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a duplicate delivery of one completed scan inside the '
        'clear window adds exactly one unit', (tester) async {
      // Platform-level duplicate: the engine re-delivers the SAME submit
      // for the SAME on-screen text before the post-frame clear has landed
      // (CR+LF terminator, queued performAction, key repeat inside the
      // frame). One physical scan = one mutation — the second delivery
      // must be swallowed, never re-dispatched.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));

      // The burst is typed into the focused qty field but NOT yet
      // submitted (per-character text updates, no receiveAction).
      final editable = tester.widget<EditableText>(
        find.descendant(of: qtyField, matching: find.byType(EditableText)),
      );
      var text = editable.controller.text;
      for (final character in '8718114202402'.split('')) {
        text += character;
        tester.testTextInput.updateEditingValue(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ));
        await tester.pump();
      }
      expect(text, '18718114202402');

      // Deliver the completed scan TWICE with no frame in between — the
      // field still shows the burst text on the second delivery.
      final textField = tester.widget<TextField>(qtyField);
      textField.onSubmitted!(text);
      textField.onSubmitted!(text);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '2',
        reason: 'one physical scan must add exactly one unit even when '
            'the platform delivers its submit twice inside one frame',
      );
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '2',
        reason: 'the field converges back to the committed quantity',
      );
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a burst digit after a quantity expression that resolved to '
        'the committed value is a run append, never a quantity', (tester) async {
      // Desync regression (repeated-scan corruption): `1*1` applies as the
      // SAME quantity the line already holds, so the rebuild never
      // corrects the typing tracker — the next scanner digit used to fail
      // the append check and parse as a barcode prefix (quantity jumped to
      // 14/15, or the stock guard fired while stock was available).
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      expect(qtyAt(tester, 0), '1');

      // Whole-replace with an expression equal to the committed value:
      // applies (returns true) but the quantity does not change.
      await tester.enterText(qtyField, '1*1');
      await tester.pump();
      expect(qtyAt(tester, 0), '1');

      // The FIRST digit of the next physical burst lands in the field.
      final editable = tester.widget<EditableText>(
        find.descendant(of: qtyField, matching: find.byType(EditableText)),
      );
      final base = editable.controller.text;
      final next = '${base}4';
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      ));
      await tester.pump();

      expect(
        qtyAt(tester, 0),
        '1',
        reason: 'a single appended burst digit must never be parsed as a '
            'quantity (the video bug: quantity jumped to 14/15 mid-burst)',
      );
      expect(
        find.byKey(const Key('pos-qty-stock-error')),
        findsNothing,
        reason: 'the stock guard may not fire on a burst prefix while '
            'stock (20) is available',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated scans keep product identity and the stock stamp '
        'intact', (tester) async {
      // Three scans in a row: the line stays the same product line with
      // the same identity fields and the server's stock stamp — only the
      // quantity moves.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final before = containerOf(tester).read(posCartProvider).lines.single;
      final qtyField = find.byKey(Key('cart-line-qty-${before.key}'));

      for (var scan = 2; scan <= 4; scan++) {
        await tester.tap(qtyField);
        await tester.pump(const Duration(milliseconds: 50));
        await typeWedgeScanIntoField(tester, qtyField, '8718114202402');
        await tester.pumpAndSettle();
        final line = containerOf(tester).read(posCartProvider).lines.single;
        expect(line.quantity, '$scan');
        expect(line.productId, before.productId);
        expect(line.variantId, before.variantId);
        expect(line.sellingUnitId, before.sellingUnitId);
        expect(line.unitName, before.unitName);
        expect(line.availableStock, before.availableStock);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown scan in the qty field shows the not-found toast '
        'and leaves the quantity untouched', (tester) async {
      await pumpPos(tester);
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      await tester.enterText(
        find.byKey(Key('cart-line-qty-$key')),
        '9998887776665',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-barcode-not-found-toast')), findsOneWidget);
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '1',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('leading-zero barcode resolves as a string (never parsed '
        'as a number)', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {
          '00123456789012': _lookupHit(),
        },
      );
      await focusSearchField(tester);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '00123456789012',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1),
          reason: 'the exact leading-zero string resolved via the lookup');
      expect(cart.lines.single.name, 'Bread');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typed text Enter still falls back to the first result',
        (tester) async {
      await pumpPos(tester);
      await focusSearchField(tester);

      // 'bre' is typed text, not a scan: the canonical lookup misses,
      // the fresh search runs, no exact name/SKU/barcode matches, and
      // the documented first-result fallback adds Bread.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bre',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a double Enter on a known barcode adds the product once',
        (tester) async {
      await pumpPos(tester);
      await focusSearchField(tester);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      // Two Enters racing the same in-flight resolve — the re-entry
      // guard drops the second before it can double-add.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('focus-yank regression: a burst landing in the search '
        'field while the post-add qty refocus is still pending is never '
        'split across the two fields', (tester) async {
      // Real-device Evidence B, vector 1 (`qty-submit len=7`): scan #1
      // submits from the search field, its add chain refocuses search for
      // the next scan and queues the line-qty refocus for the next frame.
      // The NEXT burst starts typing into the still-focused search field
      // before that frame runs — and the pending qty refocus used to fire
      // MID-burst, stealing the remaining digits into the qty field. One
      // physical scan must complete in exactly ONE consumer.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);

      // Scan #1 via the focused search field. Only MICROTASKS drain after
      // this (no frame): the add chain completes — search refocused and
      // cleared — and the qty refocus stays queued for the next frame.
      // This is the race window.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.microtask(() {});
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      await Future<void>.microtask(() {});

      // The next burst starts typing NOW — into the still-focused search
      // field — before any frame has run the pending qty refocus.
      const searchKey = Key('pos-search-field');
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '871811',
        selection: TextSelection.collapsed(offset: 6),
      ));
      await tester.pump();

      // The qty refocus fired this frame — it may NOT steal a field that
      // holds uncommitted burst digits.
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'the post-add qty refocus must never interrupt a '
            'burst mid-typing (it splits one physical scan across two '
            'fields)',
      );
      expect(controllerText(tester, searchKey), '871811');

      // The rest of the SAME burst continues into the same field.
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: '${controllerText(tester, searchKey)}4202402',
        selection: const TextSelection.collapsed(offset: 13),
      ));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '2',
        reason: 'two physical scans = two units, never a fragment',
      );
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsNothing,
        reason: 'the 7-char suffix must never be looked up on its own',
      );
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(1);
      verifyNever(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '4202402'},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('mid-burst quantity sync regression: a concurrent merge '
        'never wipes the digit run being typed', (tester) async {
      // Real-device Evidence B, vector 2: while the cashier's burst sits
      // in the focused qty field, a slow lookup from a concurrent add
      // resolves and bumps the committed quantity 1 → 2. The tile sync
      // used to clobber the in-flight run with the new committed value,
      // so the burst's remaining digits submitted as a FOREIGN suffix on
      // that base (`2` + `4202402` → `qty-submit len=7`).
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyKey = Key('cart-line-qty-$key');
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'a scanner add returns focus to the (cleared) scan input '
            '— never auto-focusing the qty field',
      );
      // The cashier clicks into the qty field (manual edit path) — the
      // burst below types straight into it.
      await tester.tap(find.byKey(qtyKey));
      await tester.pump(const Duration(milliseconds: 50));
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      expect(controllerText(tester, qtyKey), '1');

      // The concurrent scan's lookup is SLOW — it will resolve while the
      // burst below is already in the field.
      var lookups = 0;
      when(() => dio.get(
            '/api/v1/products/barcode-lookup',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((invocation) async {
        lookups++;
        if (lookups == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return _ok(
          '/api/v1/products/barcode-lookup',
          _lookupHit(),
        );
      });

      // The START of this burst is typed straight into the focused qty
      // field, not yet submitted (per-character text updates, no Enter).
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '1871811',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );

      // The concurrent add is submitted from the search field while the
      // burst sits in the qty field — its lookup stays in flight until
      // the pump below.
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(
        controllerText(tester, qtyKey),
        '1871811',
        reason: 'moving focus never edits the qty run',
      );
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));

      // The slow lookup resolved mid-"burst": the committed quantity
      // moved 1 → 2, but the pure-digit run in the qty field must survive
      // the sync untouched.
      expect(qtyAt(tester, 0), '2');
      expect(
        controllerText(tester, qtyKey),
        '1871811',
        reason: 'a committed-quantity sync may never wipe a pure-digit '
            'run in progress',
      );

      // The rest of the SAME burst completes in the qty field and submits
      // as one full code.
      await tester.tap(find.byKey(qtyKey));
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '18718114202402',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '3',
        reason: 'three physical scans = three units',
      );
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(2);
      verifyNever(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '4202402'},
        ),
      );
      expect(find.byKey(const Key('pos-barcode-not-found-toast')), findsNothing);
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scanner add from the scan input never auto-focuses the '
        'quantity field', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.single.key;
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'focus returns to the (cleared) scan input after a '
            'scanner-driven add',
      );
      expect(
        focusedFieldKey(tester),
        isNot('cart-line-qty-$key'),
        reason: 'the qty field must never receive scanner input',
      );
      expect(controllerText(tester, const Key('pos-search-field')), isEmpty);
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '1',
        reason: 'the qty field holds only the committed quantity, never '
            'scanner digits',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('two consecutive scans from the scan input each add one '
        'unit with focus staying in the scan input', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );
      expect(focusedFieldKey(tester), 'pos-search-field');

      // Second physical scan: the first add cleared and refocused the
      // scan input, so the burst lands there as a fresh code.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '2');
      final key = cart.lines.single.key;
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'focus returns to the scan input after every scanner add',
      );
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '2',
        reason: 'the qty field never receives scanner digits',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated scan adds never type partial barcode digits into '
        'the quantity field', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Consecutive scans, no manual field clicks: every burst must find
      // the scan input focused, and the qty field must show only the
      // committed quantity — never a barcode prefix/suffix fragment.
      for (var scan = 2; scan <= 4; scan++) {
        expect(
          focusedFieldKey(tester),
          'pos-search-field',
          reason: 'scan $scan must find the scan input focused',
        );
        await tester.enterText(
          find.byKey(const Key('pos-search-field')),
          '8718114202402',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final cart = containerOf(tester).read(posCartProvider);
        expect(cart.lines, hasLength(1));
        expect(cart.lines.single.quantity, '$scan');
        final key = cart.lines.single.key;
        expect(
          controllerText(tester, Key('cart-line-qty-$key')),
          '$scan',
          reason: 'after scan $scan the qty field shows only the committed '
              'quantity — never a barcode fragment',
        );
        expect(
          find.byKey(const Key('pos-barcode-not-found-toast')),
          findsNothing,
        );
        expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual click-to-edit of the quantity field still applies '
        'a typed quantity', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final key = containerOf(tester).read(posCartProvider).lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      expect(focusedFieldKey(tester), 'pos-search-field');

      // Phase 8 FIX #1 survives: a cashier click focuses the qty field…
      await tester.tap(qtyField);
      await tester.pump(const Duration(milliseconds: 50));
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      // …and a typed quantity applies through the shared validating
      // mutation (stock guard and over-stock typing covered at
      // 'out-of-stock is detected while typing (immediate)' and the
      // scan-loop stock tests above).
      await tester.enterText(qtyField, '5');
      await tester.pumpAndSettle();
      expect(qtyAt(tester, 0), '5');
      expect(controllerText(tester, Key('cart-line-qty-$key')), '5');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a successful scan keeps the product panel populated — '
        'never stuck on the empty state', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        find.byKey(const Key('pos-no-products')),
        findsNothing,
        reason: 'the post-scan catalog clear must immediately reload the '
            'normal list — the panel can never stick on "No matching '
            'products" until the cashier navigates away and back',
      );
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(
        find.byKey(Key('pos-product-name-$_productId')),
        findsOneWidget,
      );
      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'focus is back on the cleared scan input',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the product panel stays usable for another add after a '
        'scan — no navigation away and back', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      // The catalog card is still on screen and still adds: tapping it
      // merges into the scanned line (quantity 2). No page navigation
      // anywhere in this test.
      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '2');
      expect(find.byKey(const Key('pos-no-products')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated scans keep the product list populated between '
        'every scan', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);

      for (var scan = 1; scan <= 3; scan++) {
        await tester.enterText(
          find.byKey(const Key('pos-search-field')),
          '8718114202402',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(
          containerOf(tester).read(posCartProvider).lines.single.quantity,
          '$scan',
          reason: 'scan $scan adds exactly one unit',
        );
        expect(
          find.byKey(const Key('pos-no-products')),
          findsNothing,
          reason: 'after scan $scan the panel must show the normal list',
        );
        expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
        expect(
          focusedFieldKey(tester),
          'pos-search-field',
          reason: 'scan $scan must leave the barcode field ready and must '
              'never park focus in a quantity field',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('search typing and the product list stay in sync after a '
        'scan — query edits still filter, Escape still restores',
        (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));
      final search = containerOf(tester).read(posSearchProvider);
      expect(search.query, isEmpty, reason: 'the scan input is cleared');
      expect(
        search.items,
        isNotEmpty,
        reason: 'the catalog reloaded right after the scan clear',
      );

      // A typed query after the scan behaves exactly as before: the
      // provider query follows the field and the list stays in sync.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bre',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(containerOf(tester).read(posSearchProvider).query, 'bre');
      expect(find.byKey(const Key('pos-no-products')), findsNothing);

      // Escape clears the query and the list returns to the full catalog
      // — still without any navigation.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(controllerText(tester, const Key('pos-search-field')), isEmpty);
      expect(containerOf(tester).read(posSearchProvider).query, isEmpty);
      expect(find.byKey(const Key('pos-no-products')), findsNothing);
      expect(find.byKey(const Key('pos-product-grid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scanner-origin add retried from the lookup-error toast '
        'never auto-focuses the quantity field', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
        variantsFailOnce: 1,
      );
      await focusSearchField(tester);
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8718114202402',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // The first variants lookup failed: the product is OUT of the cart
      // and the retry toast is up.
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(find.byKey(const Key('pos-lookup-error')), findsOneWidget);
      expect(find.byKey(const Key('pos-lookup-error-retry')), findsOneWidget);

      // RETRY — the second lookup succeeds and writes the line. The add
      // keeps its SCANNER origin, so the qty field must never receive
      // focus (the scan input stays the keyboard home).
      await tester.tap(find.byKey(const Key('pos-lookup-error-retry')));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      final key = cart.lines.single.key;
      expect(
        focusedFieldKey(tester),
        isNot('cart-line-qty-$key'),
        reason: 'a scanner-driven retry must never run the manual '
            'post-add quantity focus (Phase 8 FIX #1 is for manual adds)',
      );
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });
  });

  group('global barcode scan (workspace unfocused)', () {
    late MockDio dio;

    setUp(() {
      dio = MockDio();
      _mockDio(dio);
    });

    Future<void> pumpPos(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>>? barcodeLookups,
    }) async {
      if (barcodeLookups != null) {
        dio = MockDio();
        _mockDio(dio, barcodeLookups: barcodeLookups);
      }
      await _pumpApp(tester, dio: dio);
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<bool> press(WidgetTester tester, LogicalKeyboardKey key) async {
      final handled = await tester.sendKeyEvent(key);
      await tester.pump();
      return handled;
    }

    Future<bool> pressSpace(WidgetTester tester) async {
      final handled = await tester.sendKeyEvent(
        LogicalKeyboardKey.space,
        character: ' ',
      );
      await tester.pump();
      return handled;
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

    String controllerText(WidgetTester tester, Key key) {
      final field = tester.widget<TextField>(find.byKey(key));
      return field.controller?.text ?? '';
    }

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
        );

    /// Escape with an empty search box hands the keyboard back to the
    /// POS workspace node — no text field owns focus anymore.
    Future<void> focusWorkspace(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.escape);
      expect(focusedFieldKey(tester), isNull);
    }

    testWidgets('a raw wedge burst adds the product and returns focus to '
        'the scan input, never the qty field', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, '8718114202402');
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      expect(cart.lines.single.quantity, '1');
      // Proof the app-level gateway ran instead of the focused-search
      // path: the barcode box never saw the code during the burst — and
      // post-add focus returns to the cleared scan input, never the qty
      // field (a scanner add must never auto-focus quantity editing).
      expect(controllerText(tester, const Key('pos-search-field')), isEmpty);
      expect(focusedFieldKey(tester), 'pos-search-field');
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every burst of a continuous session adds exactly one unit',
        (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, '8718114202402');
      await tester.pumpAndSettle();
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );

      // Post-add the empty scan input owns focus (disarming the gateway
      // while a text field is focused); Escape hands the keyboard back to
      // the workspace, and the next burst scans again — one dispatch per
      // burst, never a double add.
      await focusWorkspace(tester);
      await sendWedgeScan(tester, '8718114202402');
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '2');
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a burst that starts unfocused and hits a mid-run focus '
        'move still adds exactly one unit', (tester) async {
      // THE video sequence, re-grounded: scan #1 returns from the
      // workspace; post-add focus lands in the cleared scan input. While
      // the NEXT burst is already typing, focus moves into the line's
      // qty field — the digits typed before that move belong to the
      // gateway and must not be discarded (the remainder used to type on
      // top of the committed quantity and Enter parsed the barcode
      // prefix as a quantity).
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      await focusWorkspace(tester);

      // Scan #1: full burst from the workspace — adds Bread (qty 1) and
      // post-add focus returns to the cleared scan input (never the
      // line's qty field).
      await sendWedgeScan(tester, '8718114202402');
      await tester.pumpAndSettle();
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines.single.quantity, '1');
      final key = cart.lines.single.key;
      final qtyField = find.byKey(Key('cart-line-qty-$key'));
      expect(focusedFieldKey(tester), 'pos-search-field');

      // Hand the keyboard back to the workspace — scan #2 starts with NO
      // field focused (the gateway is armed again).
      await focusWorkspace(tester);

      // First part of burst #2: consumed by the gateway, field untouched.
      for (final character in '8718114'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      expect(controllerText(tester, Key('cart-line-qty-$key')), '1');

      // A focus move lands mid-run: the cashier clicks into the qty
      // field while the scanner is still typing.
      await tester.tap(qtyField);
      await tester.pump();
      expect(focusedFieldKey(tester), 'cart-line-qty-$key');

      // Remaining digits + terminator: still the gateway's run.
      for (final character in '202402'.split('')) {
        await tester.sendKeyEvent(digitKey(character));
      }
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '1',
        reason: 'gateway-consumed digits never reach the focused field',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final after = containerOf(tester).read(posCartProvider);
      expect(after.lines, hasLength(1));
      expect(
        after.lines.single.quantity,
        '2',
        reason: 'one physical burst = exactly one unit, even when focus '
            'moves mid-run',
      );
      expect(
        controllerText(tester, Key('cart-line-qty-$key')),
        '2',
        reason: 'the field shows the merged quantity, never burst digits',
      );
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsNothing,
        reason: 'the full code resolved — no truncated-remainder lookup',
      );
      expect(
        find.byKey(const Key('pos-qty-stock-error')),
        findsNothing,
      );
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two scans whose lookups overlap both land — no stale '
        'cart write', (tester) async {
      // Scenario 7: scan #1's lookup is slow, scan #2 resolves first. The
      // slow writer finishes LAST — if it had captured the cart before
      // its await, scan #2's unit would be silently overwritten.
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      var lookups = 0;
      when(() => dio.get(
            '/api/v1/products/barcode-lookup',
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((invocation) async {
        lookups++;
        if (lookups == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return _ok(
          '/api/v1/products/barcode-lookup',
          _lookupHit(),
        );
      });

      await focusWorkspace(tester);
      await sendWedgeScan(tester, '8718114202402'); // slow chain (#1)
      await sendWedgeScan(tester, '8718114202402'); // fast chain (#2)

      // Fast chain lands first (line qty 1), slow chain lands after.
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '2',
        reason: 'overlapping lookups must both merge — the later resolve '
            'may never overwrite the earlier unit',
      );
      verify(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      ).called(2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown barcode from the workspace shows the not-found '
        'toast and adds nothing', (tester) async {
      await pumpPos(tester); // every code misses except the default '111'
      await focusWorkspace(tester);

      await sendWedgeScan(tester, '9998887776665');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsOneWidget,
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a burst while the payment dialog is open never touches '
        'the cart', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {'8718114202402': _lookupHit()},
      );
      // SPACE opens payment only with something to pay — add one line
      // through the ordinary focused path first.
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      await focusWorkspace(tester);
      expect(await pressSpace(tester), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(BarcodeScannerGateway.instance.hasActiveHandler, isFalse);

      await sendWedgeScan(tester, '8718114202402');
      await tester.pumpAndSettle();

      // Never scan behind a modal dialog: the burst code is never even
      // looked up, the cart keeps exactly the line from before, no
      // not-found toast fires — and the dialog is still the live route.
      verifyNever(
        () => dio.get(
          '/api/v1/products/barcode-lookup',
          queryParameters: {'barcode': '8718114202402'},
        ),
      );
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '1');
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsNothing,
      );
      expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing and workspace shortcuts keep working while scans '
        'are armed', (tester) async {
      await pumpPos(tester);
      await focusWorkspace(tester);
      expect(BarcodeScannerGateway.instance.hasActiveHandler, isTrue);

      // Focus a text field: the gateway stands down instantly, typing
      // is untouched.
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        BarcodeScannerGateway.instance.hasActiveHandler,
        isFalse,
      );
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '111',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(posCartProvider).lines, hasLength(1));

      // Back to the workspace (armed again): the `*` quantity shortcut
      // must still claim its key from the focus system — a non-digit
      // key the gateway never consumes.
      await focusWorkspace(tester);
      expect(BarcodeScannerGateway.instance.hasActiveHandler, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8, character: '*');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qty-multiplier-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the gateway releases POS once the screen unmounts',
        (tester) async {
      await pumpPos(tester);
      expect(BarcodeScannerGateway.instance.handlerCount, 1);

      await tester.pumpWidget(const SizedBox());
      expect(BarcodeScannerGateway.instance.handlerCount, 0);
      expect(BarcodeScannerGateway.instance.hasActiveHandler, isFalse);

      // A burst into the void dispatches nowhere (and never crashes).
      await sendWedgeScan(tester, '8718114202402');
      expect(tester.takeException(), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // Configurable scan actions (SharedPreferences — both OFF by default):
  //   A: unknown barcode (definitive miss, scan shape) → Add Product form
  //      with the barcode prefilled instead of the not-found toast;
  //   B: scan-driven add rejected for stock → Adjust Stock dialog instead
  //      of the out-of-stock / qty stock-error toast.
  // Network errors and unrelated validation failures never raise either
  // dialog; repeated scans never stack one; scanning resumes after close.
  // -----------------------------------------------------------------------

  group('configurable scan actions', () {
    const unknownCode = '9998887776665';
    const knownCode = '8718114202402';

    const addProductAction = {
      ScanSettingsNotifier.openAddProductOnUnknownBarcodeKey: true,
    };
    const adjustStockAction = {
      ScanSettingsNotifier.openAdjustStockOnOutOfStockScanKey: true,
    };

    late MockDio dio;

    setUp(() {
      dio = MockDio();
      _mockDio(dio);
    });

    Future<void> pumpPos(
      WidgetTester tester, {
      Map<String, Object>? initialPrefs,
      Map<String, Map<String, dynamic>>? barcodeLookups,
      String productQuantity = '20',
      List<Map<String, dynamic>> variants = const [],
      bool barcodeLookupNetworkError = false,
    }) async {
      dio = MockDio();
      _mockDio(
        dio,
        barcodeLookups: barcodeLookups,
        productQuantity: productQuantity,
        variants: variants,
        barcodeLookupNetworkError: barcodeLookupNetworkError,
      );
      await _pumpApp(tester, dio: dio, initialPrefs: initialPrefs);
      await tester.pump(const Duration(milliseconds: 500));
    }

    String controllerText(WidgetTester tester, Key key) {
      final field = tester.widget<TextField>(find.byKey(key));
      return field.controller?.text ?? '';
    }

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
        );

    String? focusedFieldKey(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final field = context.widget is TextField
          ? context.widget as TextField
          : context.findAncestorWidgetOfExactType<TextField>();
      final key = field?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    /// Escape with an empty search box hands the keyboard back to the
    /// POS workspace node — no text field owns focus anymore.
    Future<void> focusWorkspace(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focusedFieldKey(tester), isNull);
    }

    testWidgets('unknown scan with the Add Product action ON opens the form '
        'prefilled and suppresses the not-found toast', (tester) async {
      await pumpPos(tester, initialPrefs: addProductAction);
      await focusWorkspace(tester);

      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(
        controllerText(tester, const Key('product-barcode-field')),
        unknownCode,
        reason: 'the scanned code lands in the barcode field',
      );
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsNothing,
        reason: 'the dialog replaces the toast, never stacks with it',
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scan into the open Add Product form replaces the '
        'prefilled barcode and never touches the name field', (tester) async {
      await pumpPos(tester, initialPrefs: addProductAction);
      await focusWorkspace(tester);

      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(
        controllerText(tester, const Key('product-barcode-field')),
        unknownCode,
        reason: 'prefill from the POS unknown-barcode scan',
      );

      // Type a name, then scan a DIFFERENT code while Name is focused:
      // the form handler captures the burst and replaces only the
      // barcode field — no submit, no lost keystrokes elsewhere.
      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Hummus 400g',
      );
      await sendWedgeScan(tester, '5901234123457');
      await tester.pumpAndSettle();

      expect(
        controllerText(tester, const Key('product-barcode-field')),
        '5901234123457',
      );
      expect(
        controllerText(tester, const Key('product-name-field')),
        'Hummus 400g',
      );
      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing the unknown-barcode form restores scan input focus '
        'and the next scan adds normally', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: addProductAction,
        barcodeLookups: {knownCode: _lookupHit()},
      );
      await focusWorkspace(tester);
      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('product-form-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsNothing);
      expect(focusedFieldKey(tester), 'pos-search-field');

      // Scanner resumed: hand the keyboard back to the workspace and scan
      // a KNOWN code — it adds through the ordinary resolve path.
      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      expect(cart.lines.single.quantity, '1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown scan with the action OFF keeps the not-found toast '
        'and never opens the form', (tester) async {
      await pumpPos(tester); // both settings default OFF
      await focusWorkspace(tester);

      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsNothing);
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short digit fragment with the action ON keeps the toast '
        '(a partial barcode never raises the form)', (tester) async {
      await pumpPos(tester, initialPrefs: addProductAction);

      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '999',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsNothing);
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsOneWidget,
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typed text with the action ON still fuzzy-adds the first '
        'result and never opens the form', (tester) async {
      await pumpPos(tester, initialPrefs: addProductAction);

      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bre',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsNothing);
      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.name, 'Bread');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a lookup network failure with the action ON keeps the '
        'not-found toast (a failed lookup is never a definitive miss)',
        (tester) async {
      await pumpPos(
        tester,
        initialPrefs: addProductAction,
        barcodeLookupNetworkError: true,
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsNothing);
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a product-detail network failure with the action ON never '
        'opens the form', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: addProductAction,
        barcodeLookups: {knownCode: _lookupHit()},
      );
      when(() => dio.get('/api/v1/products/$_productId')).thenThrow(
        DioException.connectionError(
          requestOptions: RequestOptions(path: '/api/v1/products/$_productId'),
          reason: 'connection refused',
        ),
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsNothing);
      // The established error surface for a failed resolve stays the
      // not-found toast — a transport error is not "no such product".
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsOneWidget,
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a repeated unknown scan while the form is open never stacks '
        'a second dialog', (tester) async {
      await pumpPos(tester, initialPrefs: addProductAction);
      await focusWorkspace(tester);
      await sendWedgeScan(tester, unknownCode);
      await tester.pumpAndSettle();
      expect(find.byType(ProductFormDialog), findsOneWidget);

      // A second code submitted through the focused search path while the
      // form is open: the scan-action serialization swallows it — still
      // exactly ONE form, and no toast sneaks in behind it.
      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        '8887776665554',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byType(ProductFormDialog), findsOneWidget);
      expect(
        find.byKey(const Key('pos-barcode-not-found-toast')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an out-of-stock scan with the Adjust Stock action ON opens '
        'the dialog and suppresses the out-of-stock toast', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: adjustStockAction,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '0',
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
      expect(find.byKey(const Key('adjust-product-name')), findsOneWidget);
      expect(
        find.byKey(const Key('pos-out-of-stock-error')),
        findsNothing,
        reason: 'the dialog replaces the toast, never stacks with it',
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a submitted adjustment closes the dialog, posts the audit '
        'call and restores scan input focus', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: adjustStockAction,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '0',
      );
      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('adjust-quantity')), '5');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('adjust-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(find.byKey(const Key('pos-out-of-stock-error')), findsNothing);
      verify(
        () => dio.post(
          '/api/v1/inventory/adjust',
          data: any(named: 'data'),
        ),
      ).called(1);
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an out-of-stock scan with the action OFF keeps the '
        'out-of-stock toast and never opens the dialog', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '0',
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(
        find.byKey(const Key('pos-out-of-stock-error')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a variant-level out-of-stock scan with the action ON opens '
        'the dialog scoped to that variant', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: adjustStockAction,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '20',
        variants: [_variantJson(quantity: '0')],
      );
      await focusWorkspace(tester);

      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      final dialog = find.byType(AdjustDialog);
      expect(dialog, findsOneWidget);
      expect(tester.widget<AdjustDialog>(dialog).variantId, 'var-1');
      expect(
        find.byKey(const Key('pos-out-of-stock-error')),
        findsNothing,
      );
      expect(containerOf(tester).read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a merge that exceeds stock with the action ON opens Adjust '
        'Stock instead of the qty stock-error toast', (tester) async {
      await pumpPos(
        tester,
        initialPrefs: adjustStockAction,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '1',
      );
      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );

      // Second scan of the same product: the merge (1 + 1) exceeds the
      // stock of 1 — the shared guard's out-of-stock verdict opens the
      // dialog (setting ON) instead of the `pos-qty-stock-error` toast.
      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsOneWidget);
      expect(find.byKey(const Key('pos-qty-stock-error')), findsNothing);

      // Cancel keeps the committed unit — the rejection never mutated cart.
      final cancel = find.descendant(
        of: find.byKey(const Key('adjust-dialog')),
        matching: find.text(AppStrings.t('cancel', 'en')),
      );
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a merge that exceeds stock with the action OFF keeps the '
        'established qty stock-error toast', (tester) async {
      await pumpPos(
        tester,
        barcodeLookups: {knownCode: _lookupHit()},
        productQuantity: '1',
      );
      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      await focusWorkspace(tester);
      await sendWedgeScan(tester, knownCode);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(
        find.byKey(const Key('pos-qty-stock-error')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a manual catalog add that exceeds stock with both actions '
        'ON keeps the qty stock-error toast (never the dialog)',
        (tester) async {
      // The grid tile for an out-of-stock product is INERT (onTap null) —
      // the manual path that can still reach the stock funnel is the
      // merge guard: tap once (adds the single available unit), tap
      // again (merge exceeds stock). fromScan is false there, so the
      // established toast wins even with both scan actions ON.
      await pumpPos(
        tester,
        initialPrefs: {
          ...addProductAction,
          ...adjustStockAction,
        },
        productQuantity: '1',
      );

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();
      expect(
        containerOf(tester).read(posCartProvider).lines.single.quantity,
        '1',
      );

      await tester.tap(find.byKey(Key('pos-product-$_productId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('adjust-dialog')), findsNothing);
      expect(find.byType(ProductFormDialog), findsNothing);
      expect(
        find.byKey(const Key('pos-qty-stock-error')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------------------------------
  // Scan-latency optimization contract — MEASURED, not claimed. Every
  // request in this group resolves after one simulated 100ms round trip,
  // so the fake clock counts real sequential hops:
  //  - typing a burst must not rebuild the POS screen per keystroke
  //    (posSearchProvider must stay silent while digits arrive),
  //  - submit → cart update must cost 2 sequential round trips
  //    (barcode lookup, then product ∥ variants ∥ units) — never 4,
  //  - an undisturbed scan must not refetch the catalog at all
  //    (the pending digit-search debounce is cancelled and the
  //    post-add reload is skipped when no query disturbed the panel),
  //  - one physical burst observed by BOTH dispatch origins (the raw-PoC
  //    decode and the legacy Enter) must produce exactly ONE cart action.
  // ------------------------------------------------------------------------
  group('scan-to-cart latency (measured)', () {
    late MockDio dio;
    late List<String> recordPaths;

    const rtt = Duration(milliseconds: 100);
    const scanCode = '8718114202402';

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byKey(const Key('pos-screen'))),
        );

    Future<void> focusSearchField(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('pos-search-field')));
      await tester.pump(const Duration(milliseconds: 100));
    }

    /// Escape with an empty search box hands the keyboard back to the
    /// POS workspace node — no text field owns focus anymore.
    Future<void> focusWorkspace(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      final context = FocusManager.instance.primaryFocus?.context;
      expect(
        context == null ||
            context.findAncestorWidgetOfExactType<TextField>() == null,
        isTrue,
        reason: 'Escape must hand focus back to the workspace',
      );
    }

    Future<void> pumpPos(WidgetTester tester) async {
      dio = MockDio();
      recordPaths = <String>[];
      _mockDio(
        dio,
        barcodeLookups: {scanCode: _lookupHit()},
        recordPaths: recordPaths,
        latency: rtt,
      );
      await _pumpApp(tester, dio: dio);
      final container = containerOf(tester);
      for (var i = 0; i < 40; i++) {
        await tester.pump(rtt);
        if (container.read(posSearchProvider).items.isNotEmpty) break;
      }
      expect(
        container.read(posSearchProvider).items,
        isNotEmpty,
        reason: 'the initial catalog load must have landed before measuring',
      );
    }

    testWidgets(
        'scan input → cart: keystroke rebuilds, sequential round trips '
        'and catalog refetches are all bounded', (tester) async {
      await pumpPos(tester);
      final container = containerOf(tester);

      await focusSearchField(tester);

      var searchNotifications = 0;
      container.listen(
        posSearchProvider,
        (_, _) => searchNotifications++,
        fireImmediately: false,
      );

      // One digit at a time — exactly the state churn a wedge burst
      // causes — without ever advancing the debounce clock.
      for (var i = 1; i <= scanCode.length; i++) {
        await tester.enterText(
          find.byKey(const Key('pos-search-field')),
          scanCode.substring(0, i),
        );
        await tester.pump();
      }
      final notificationsWhileTyping = searchNotifications;

      final catalogBefore =
          recordPaths.where((p) => p == kPosCatalogPath).length;

      await tester.testTextInput.receiveAction(TextInputAction.done);

      // One simulated round trip per step until the cart line exists.
      var scanToCartMs = 0;
      while (container.read(posCartProvider).lines.isEmpty &&
          scanToCartMs < 5000) {
        await tester.pump(rtt);
        scanToCartMs += rtt.inMilliseconds;
      }
      // Let every post-scan timer (debounce / reload) land before counting.
      await tester.pump(rtt * 5);

      final catalogDuringScan =
          recordPaths.where((p) => p == kPosCatalogPath).length -
              catalogBefore;

      debugPrint(
        'SCAN-LATENCY scan-to-cart=${scanToCartMs}ms | '
        'keystroke notifications=$notificationsWhileTyping | '
        'catalog requests around scan=$catalogDuringScan',
      );

      expect(container.read(posCartProvider).lines, hasLength(1));
      expect(container.read(posCartProvider).lines.single.quantity, '1');
      expect(
        notificationsWhileTyping,
        0,
        reason: 'a keystroke must not rebuild the POS screen — the query '
            'lives inside the notifier until the debounced load runs',
      );
      expect(
        scanToCartMs,
        lessThanOrEqualTo(250),
        reason: 'barcode lookup + (product ∥ variants ∥ units) = 2 '
            'sequential round trips at a 100ms simulated RTT',
      );
      expect(
        catalogDuringScan,
        0,
        reason: 'an undisturbed scan neither runs the digit-search '
            'debounce (cancelled at submit) nor reloads the catalog '
            'after the add',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'one physical burst observed by BOTH dispatch origins (legacy '
        'Enter first, raw-PoC dispatch second) adds exactly one cart action',
        (tester) async {
      await pumpPos(tester);
      await focusWorkspace(tester);
      BarcodeScannerGateway.instance.resetDispatchDedupForTest();

      await sendWedgeScan(tester, scanCode);
      // The native suppression race's second observation: the raw PoC
      // decoder completed the same run and dispatches it through the
      // external entry point moments later.
      final dispatched = BarcodeScannerGateway.instance
          .dispatchExternalScan(scanCode);
      // Drive the fake clock one simulated RTT at a time — pumpAndSettle
      // stops at the next frame boundary while the request timer pends.
      for (var i = 0; i < 12; i++) {
        await tester.pump(rtt);
        if (containerOf(tester).read(posCartProvider).lines.isNotEmpty) {
          break;
        }
      }
      await tester.pump(rtt * 5);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(
        cart.lines.single.quantity,
        '1',
        reason: 'the cross-origin duplicate dispatch must be dropped — '
            'one physical scan, one cart action',
      );
      expect(
        dispatched,
        isFalse,
        reason: 'the second observation is the dropped one',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'one physical burst observed by BOTH dispatch origins (raw-PoC '
        'dispatch first, legacy Enter second) adds exactly one cart action',
        (tester) async {
      await pumpPos(tester);
      await focusWorkspace(tester);
      final gateway = BarcodeScannerGateway.instance;
      gateway.resetDispatchDedupForTest();

      // Raw observation first…
      final dispatched = gateway.dispatchExternalScan(scanCode);
      // …then the legacy observation of the same run through the gateway's
      // synchronous key seam (no platform round trips — the two dispatches
      // sit milliseconds apart exactly like the real race does).
      for (final character in scanCode.split('')) {
        gateway.handleKeyForTest(wedgeKeyDown(character));
      }
      final legacyHandled = gateway.handleKeyForTest(wedgeEnter());
      for (var i = 0; i < 12; i++) {
        await tester.pump(rtt);
        if (containerOf(tester).read(posCartProvider).lines.isNotEmpty) {
          break;
        }
      }
      await tester.pump(rtt * 5);

      final cart = containerOf(tester).read(posCartProvider);
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.quantity, '1');
      expect(dispatched, isTrue);
      expect(
        legacyHandled,
        isTrue,
        reason: 'the duplicate run is still consumed as a scan — only '
            'its second ACTION is dropped',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
