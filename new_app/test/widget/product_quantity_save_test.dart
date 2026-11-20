// Phase 17 Part B — the product quantity field actually saves.
//
// Root cause pinned here: `PUT /api/v1/products/{id}` has NO `quantity`
// field (Phase 7 moved stock into the inventory journal), so the dialog's
// old body was stripped by Pydantic, returned 200 and showed a success
// toast while the database never changed. Contracts under test:
//   * the edit PUT never carries `quantity`;
//   * edit + moved stock + `inventory_adjust` → audited
//     `POST /api/v1/inventory/adjust` with `operation: set` and a
//     localized reason, and the dialog only closes on success of BOTH;
//   * a rejected adjustment keeps the dialog open with a visible error
//     and no success toast;
//   * unchanged stock issues no journal entry;
//   * without `inventory_adjust` the field is read-only and routes to /stock;
//   * a backend decimal keeps its integer zeros (`240.000` → `240`), so a
//     no-op save can never turn into a real stock set.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
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

const _productsPath = '/api/v1/products';
const _adjustPath = '/api/v1/inventory/adjust';
const _categoriesPath = '/api/v1/categories';
const _setupPath = '/api/v1/auth/setup/check';
const _verifyPath = '/api/v1/auth/verify-token';
const _mePath = '/api/v1/auth/me';

const _productId = '00000000-0000-0000-0000-0000000000p1';

const _stockScopes = [
  'product_view',
  'product_update',
  'inventory_adjust',
];

/// Editor that can update products but holds no stock scope.
const _noStockScopes = ['product_view', 'product_update'];

Map<String, dynamic> _productJson({String quantity = '12.000'}) => {
      'id': _productId,
      'name': 'Fromage',
      'barcode': '900000',
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': '10',
      'cost': '6',
      'quantity': quantity,
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'expiry_date': null,
      'image_path': null,
      'category_id': null,
      'category_name': null,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _verifyBody(List<String> scopes) => {
      'valid': true,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'permissions': scopes,
        'roles': [
          {
            'name': 'admin',
            'permissions': [for (final s in scopes) {'scope': s}],
          },
        ],
      },
    };

Map<String, dynamic> _meBody(List<String> scopes) => {
      'id': '00000000-0000-0000-0000-0000000000a1',
      'full_name': 'Admin',
      'is_active': true,
      'permissions': scopes,
      'roles': ['admin'],
    };

/// Dispatches every call the dialog and its notifiers make.
///
/// [adjustStatus] 200 accepts the SET; anything else answers with a
/// standard error envelope so the localized message is predictable.
void _stub(
  MockDio dio, {
  required List<String> scopes,
  String quantity = '12.000',
  int adjustStatus = 200,
}) {
  Response<dynamic> ok(String path, Object? data) => Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == _productsPath) {
      return ok(path, {
        'items': [_productJson(quantity: quantity)],
        'total': 1,
        'page': 1,
        'page_size': 40,
        'pages': 1,
      });
    }
    if (path == _categoriesPath) {
      return ok(path, {
        'items': <dynamic>[],
        'total': 0,
        'page': 1,
        'page_size': 100,
        'pages': 1,
      });
    }
    return ok(path, {
      'items': <dynamic>[],
      'total': 0,
    });
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == _setupPath) return ok(path, {'setup_needed': false});
    if (path == _mePath) return ok(path, _meBody(scopes));
    return ok(path, {
      'items': <dynamic>[],
      'total': 0,
    });
  });

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      final data = invocation.namedArguments[#data];
      if (path == _verifyPath) return ok(path, _verifyBody(scopes));
      if (path == _adjustPath) {
        if (adjustStatus == 200) {
          return ok(path, {
            'product_id': _productId,
            'quantity': (data as Map)['quantity'],
            'avg_cost': '6.000',
          });
        }
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: adjustStatus,
            data: {
              'error': {'message': 'Stock adjustment refused'},
            },
          ),
        );
      }
      if (path == _productsPath) {
        // POST /products returns the created product body (the notifier
        // parses it so callers can select the fresh model immediately).
        return ok(path, _productJson());
      }
      return ok(path, _verifyBody(scopes));
    },
  );

  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => ok(
      invocation.positionalArguments.first as String? ?? _productsPath,
      _productJson(quantity: quantity),
    ),
  );
}

Future<void> _pumpHost(
  WidgetTester tester,
  MockDio dio, {
  required List<String> scopes,
  required ProductModel product,
}) async {
  final storage = FakeCredentialStorage();
  // Cold start never adopts a persisted session: the fixture supplies the
  // signed-in user explicitly, with the scopes under test.
  final user = AuthUser(
    id: '00000000-0000-0000-0000-0000000000a1',
    fullName: 'Admin',
    isActive: true,
    roles: const ['admin'],
    permissions: scopes,
  );

  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(storage),
        currentUserProvider.overrideWithValue(user),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-edit'),
                onPressed: () => showProductFormDialog(context, product: product),
                child: const Text('edit'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openEdit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-edit')));
  await tester.pumpAndSettle();
}

TextField _quantityField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('product-quantity-field')));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('product quantity save (edit + inventory_adjust)', () {
    testWidgets('PUT drops `quantity`; the audited SET carries it',
        (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _stockScopes);
      await _pumpHost(
        tester,
        dio,
        scopes: _stockScopes,
        product: ProductModel.fromJson(_productJson()),
      );
      await _openEdit(tester);

      // Backend decimal renders without eating integer zeros.
      expect(_quantityField(tester).controller!.text, '12');

      await tester.enterText(
        find.byKey(const Key('product-quantity-field')),
        '40',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      final puts =
          verify(() => dio.put(any(), data: captureAny(named: 'data')))
              .captured;
      expect(puts, hasLength(1));
      final putPayload = puts.single as Map<String, dynamic>;
      expect(putPayload.containsKey('quantity'), isFalse,
          reason: 'the update endpoint would silently drop it');
      expect(putPayload['name'], 'Fromage');

      final adjusts = verify(
        () => dio.post(_adjustPath, data: captureAny(named: 'data')),
      ).captured;
      expect(adjusts, hasLength(1));
      final adjustPayload = adjusts.single as Map<String, dynamic>;
      expect(adjustPayload['product_id'], _productId);
      expect(adjustPayload['operation'], 'set');
      expect(adjustPayload['quantity'], '40');
      expect(adjustPayload['reason'],
          AppStrings.t('product_stock_reason', 'en'));

      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(
        find.text(AppStrings.t('product_and_stock_updated', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('rejected adjustment keeps the dialog open, no toast',
        (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _stockScopes, adjustStatus: 403);
      await _pumpHost(
        tester,
        dio,
        scopes: _stockScopes,
        product: ProductModel.fromJson(_productJson()),
      );
      await _openEdit(tester);

      await tester.enterText(
        find.byKey(const Key('product-quantity-field')),
        '40',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      // The product update itself went through…
      verify(() => dio.put(any(), data: any(named: 'data'))).called(1);
      // …but the stock half failed and is reported instead of swallowed.
      verify(() => dio.post(_adjustPath, data: any(named: 'data'))).called(1);

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('product-form-error')), findsOneWidget);
      expect(find.text('Stock adjustment refused'), findsOneWidget);
      expect(
        find.text(AppStrings.t('product_updated', 'en')),
        findsNothing,
      );
      expect(
        find.text(AppStrings.t('product_and_stock_updated', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('unchanged stock writes no journal entry', (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _stockScopes, quantity: '240.000');
      await _pumpHost(
        tester,
        dio,
        scopes: _stockScopes,
        product: ProductModel.fromJson(_productJson(quantity: '240.000')),
      );
      await _openEdit(tester);

      // Integer zeros survive the display round-trip…
      expect(_quantityField(tester).controller!.text, '240');
      // …so `240.000` and the field's `240` compare equal.
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      verify(() => dio.put(any(), data: any(named: 'data'))).called(1);
      verifyNever(() => dio.post(_adjustPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(find.text(AppStrings.t('product_updated', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('product quantity without inventory_adjust', () {
    testWidgets('field is read-only, explains itself and routes to /stock',
        (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _noStockScopes);
      await _pumpHost(
        tester,
        dio,
        scopes: _noStockScopes,
        product: ProductModel.fromJson(_productJson()),
      );
      await _openEdit(tester);

      expect(_quantityField(tester).readOnly, isTrue);
      expect(
        find.text(AppStrings.t('quantity_readonly', 'en')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('product-quantity-open-stock')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('saving without the scope never calls the adjust endpoint',
        (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _noStockScopes);
      await _pumpHost(
        tester,
        dio,
        scopes: _noStockScopes,
        product: ProductModel.fromJson(_productJson()),
      );
      await _openEdit(tester);

      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Fromage renamed',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      verify(() => dio.put(any(), data: any(named: 'data'))).called(1);
      verifyNever(() => dio.post(_adjustPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(find.text(AppStrings.t('product_updated', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('create mode keeps seeding stock from the product body', () {
    testWidgets('POST still carries `quantity`', (tester) async {
      final dio = MockDio();
      _stub(dio, scopes: _stockScopes);

      final storage = FakeCredentialStorage();
      final user = AuthUser(
        id: '00000000-0000-0000-0000-0000000000a1',
        fullName: 'Admin',
        isActive: true,
        roles: const ['admin'],
        permissions: _stockScopes,
      );

      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            credentialStorageProvider.overrideWithValue(storage),
            currentUserProvider.overrideWithValue(user),
            localeProvider
                .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            home: const Scaffold(body: ProductFormDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'New Item',
      );
      await tester.enterText(
        find.byKey(const Key('product-price-field')),
        '25.5',
      );
      await tester.enterText(
        find.byKey(const Key('product-quantity-field')),
        '7',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      final posts = verify(
        () => dio.post(_productsPath, data: captureAny(named: 'data')),
      ).captured;
      expect(posts, hasLength(1));
      final payload = posts.single as Map<String, dynamic>;
      expect(payload['name'], 'New Item');
      expect(payload['quantity'], '7',
          reason: 'create seeds stock atomically — do not strip it');
      // Create never goes through /inventory/adjust.
      verifyNever(() => dio.post(_adjustPath, data: any(named: 'data')));
      expect(tester.takeException(), isNull);
    });
  });
}
