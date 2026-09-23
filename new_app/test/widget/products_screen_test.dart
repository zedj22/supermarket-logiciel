import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/categories_dialog.dart';
import 'package:supermarket_pos/features/products/products_providers.dart';
import 'package:supermarket_pos/features/products/products_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Stateful in-memory credential storage for the full-app login flow.
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
const _productsPath = '/api/v1/products';
const _categoriesPath = '/api/v1/categories';

/// Real LoginResponse shape: permissions nested under roles[].permissions[].
Map<String, dynamic> _adminLoginBody({
  List<String> scopes = const [
    'product_view',
    'product_create',
    'product_update',
    'product_archive',
    'category_view',
    'category_manage',
    'user_manage',
  ],
}) =>
    {
      'access_token': 'tok-admin',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'roles': [
          {
            'name': 'admin',
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _productJson({
  required String id,
  required String name,
  required String barcode,
  String price = '100.0',
  String cost = '80.0',
  String quantity = '10.0',
  String? categoryId,
  String? categoryName,
  bool archived = false,
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
      'cost': cost,
      'quantity': quantity,
      'low_stock_threshold': '5.0',
      'allow_negative_stock': false,
      'expiry_date': null,
      'image_path': null,
      'category_id': categoryId,
      'category_name': categoryName,
      'is_archived': archived,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _productsListBody() => {
      'items': [
        _productJson(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Apple Juice',
          barcode: '111222333',
          categoryId: '00000000-0000-0000-0000-0000000000c1',
          categoryName: 'Drinks',
        ),
        _productJson(
          id: '00000000-0000-0000-0000-0000000000p2',
          name: 'Bread',
          barcode: '444555666',
          price: '50.0',
          cost: '30.0',
          quantity: '20.0',
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _createdProductBody() => _productJson(
      id: '00000000-0000-0000-0000-0000000000p3',
      name: 'New Item',
      barcode: '999888777',
    );

Map<String, dynamic> _categoriesListBody() => {
      'items': [
        {
          'id': '00000000-0000-0000-0000-0000000000c1',
          'name': 'Drinks',
          'parent_id': null,
          'sort_order': 0,
          'product_count': 1,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
        {
          'id': '00000000-0000-0000-0000-0000000000c2',
          'name': 'Snacks',
          'parent_id': null,
          'sort_order': 1,
          'product_count': 0,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
      ],
      'total': 2,
      'page': 1,
      'page_size': 100,
      'pages': 1,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(<String, dynamic>{});
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  void stubRequests(
    MockDio dio, {
    Map<String, dynamic>? loginBody,
    Map<String, dynamic>? productsBody,
    Map<String, dynamic>? categoriesBody,
    List<Map<String, dynamic>>? productQueryLog,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/setup/check', {
        'setup_needed': false,
      }),
    );
    when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
      (_) async => okResponse('/api/v1/auth/login-users', {
        'items': [
          {
            'id': '00000000-0000-0000-0000-0000000000a1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
          },
          {
            'id': '00000000-0000-0000-0000-0000000000c1',
            'full_name': 'Cashier Ali',
            'is_active': true,
            'roles': [
              {'name': 'cashier'},
            ],
          },
        ],
        'total': 2,
      }),
    );
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(
        _loginPath,
        loginBody ?? _adminLoginBody(),
      ),
    );
    when(() => dio.post('/api/v1/auth/logout-token', data: any(named: 'data')))
        .thenAnswer(
      (_) async => okResponse('/api/v1/auth/logout-token', {
        'message': 'logged out',
      }),
    );
    when(
      () => dio.get(
        _productsPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final params = invocation.namedArguments[#queryParameters];
      if (productQueryLog != null && params is Map<String, dynamic>) {
        productQueryLog.add(Map<String, dynamic>.from(params));
      }
      return okResponse(_productsPath, productsBody ?? _productsListBody());
    });
    when(
      () => dio.get(
        _categoriesPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => okResponse(
        _categoriesPath,
        categoriesBody ?? _categoriesListBody(),
      ),
    );
    when(() => dio.post(_productsPath, data: any(named: 'data'))).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _productsPath),
        data: _createdProductBody(),
        statusCode: 201,
      ),
    );
    when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_productsPath, _createdProductBody()),
    );
    when(() => dio.delete(any())).thenAnswer(
      (_) async => okResponse(_productsPath, _createdProductBody()),
    );
    when(() => dio.post(_categoriesPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_categoriesPath, {
        'id': '00000000-0000-0000-0000-0000000000c3',
        'name': 'New Category',
        'parent_id': null,
        'sort_order': 0,
        'product_count': 0,
        'is_archived': false,
        'archived_at': null,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      }),
    );
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required String userName,
    required String pin,
    String navLabel = '',
  }) async {
    tester.view.physicalSize = const Size(2200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(userName));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    if (navLabel.isNotEmpty) {
      await tester.tap(find.text(navLabel));
      await tester.pumpAndSettle();
    }

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  group('Products screen (admin with product scopes)', () {
    testWidgets('loads via GET /api/v1/products and lists products',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);

      final container = await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      expect(find.byType(ProductsScreen), findsOneWidget);
      expect(find.byKey(const Key('products-table')), findsOneWidget);
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.text('Bread'), findsOneWidget);
      expect(find.text('Drinks'), findsWidgets);
      expect(find.text('111222333'), findsOneWidget);
      expect(find.byKey(const Key('products-total')), findsOneWidget);
      expect(find.text('${AppStrings.t('total', 'ar')}: 2'), findsOneWidget);

      expect(queryLog, isNotEmpty);
      expect(queryLog.last['page'], 1);
      expect(queryLog.last['status'], 'active');

      // Categories loaded for the filter dropdown.
      verify(
        () => dio.get(
          _categoriesPath,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(greaterThanOrEqualTo(1));

      expect(container.read(productsProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cost column is visible for product_update permission',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      expect(find.text(AppStrings.t('cost', 'ar')), findsOneWidget);
      expect(find.text('80.0'), findsOneWidget); // cost cell from stub
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add Product dialog validates and POSTs the new product',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      await tester.tap(find.byKey(const Key('products-add-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('product-name-field')), findsOneWidget);
      expect(find.byKey(const Key('product-price-field')), findsOneWidget);
      expect(find.byKey(const Key('product-category-field')), findsOneWidget);

      // Submit without required fields → inline validation, no POST.
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('product-form-error')), findsOneWidget);
      verifyNever(() => dio.post(_productsPath, data: any(named: 'data')));

      // Fill valid data → POST issued, dialog closes.
      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'New Item',
      );
      await tester.enterText(
        find.byKey(const Key('product-price-field')),
        '25.5',
      );
      await tester.enterText(
        find.byKey(const Key('product-barcode-field')),
        '999888777',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      final posted = verify(
        () => dio.post(_productsPath, data: captureAny(named: 'data')),
      ).captured;
      expect(posted, hasLength(1));
      final payload = posted.single as Map<String, dynamic>;
      expect(payload['name'], 'New Item');
      expect(payload['price'], '25.5');
      expect(payload['barcode'], '999888777');
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search input is debounced before hitting the API',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      // Initial load = 1 call.
      expect(queryLog, hasLength(1));

      await tester.enterText(
        find.byKey(const Key('products-search-field')),
        'apple',
      );
      // Before the debounce fires, no extra request.
      await tester.pump(const Duration(milliseconds: 100));
      expect(queryLog, hasLength(1));

      // After ~300ms debounce, exactly one search request.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(queryLog, hasLength(2));
      expect(queryLog.last['search'], 'apple');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('status filter switches to archived', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      await tester.tap(find.byKey(const Key('products-status-filter')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.text(AppStrings.t('archived', 'ar')).last);
      await tester.pumpAndSettle();

      expect(queryLog.last['status'], 'archived');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Manage Categories dialog opens and shows category list',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      await tester.tap(
        find.byKey(const Key('products-manage-categories-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('categories-dialog')), findsOneWidget);
      expect(find.byType(CategoriesDialog), findsOneWidget);
      // 'Drinks' also appears in the table's category column behind the dialog.
      expect(find.text('Drinks'), findsWidgets);
      expect(find.text('Snacks'), findsOneWidget);
      expect(find.byKey(const Key('create-category-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('create category from dialog issues POST /categories',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      await tester.tap(
        find.byKey(const Key('products-manage-categories-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-category-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('category-name-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('category-name-field')),
        'Dairy',
      );
      await tester.tap(find.byKey(const Key('category-form-submit')));
      await tester.pumpAndSettle();

      final posted = verify(
        () => dio.post(_categoriesPath, data: captureAny(named: 'data')),
      ).captured;
      expect(posted.single, {'name': 'Dairy'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('archive product asks for confirmation then DELETEs',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      final archiveKey = find.byKey(
        const Key('product-archive-00000000-0000-0000-0000-0000000000p1'),
      );
      await tester.ensureVisible(archiveKey);
      await tester.pumpAndSettle();
      await tester.tap(archiveKey);
      await tester.pumpAndSettle();

      expect(
        find.text(AppStrings.t('archive_product_confirm', 'ar')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('confirm-archive-product')));
      await tester.pumpAndSettle();

      verify(() => dio.delete(
            '$_productsPath/00000000-0000-0000-0000-0000000000p1',
          )).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('edit opens the form pre-filled with the product name',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      final editKey = find.byKey(
        const Key('product-edit-00000000-0000-0000-0000-0000000000p1'),
      );
      await tester.ensureVisible(editKey);
      await tester.pumpAndSettle();
      await tester.tap(editKey);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      final nameField = tester.widget<TextField>(
        find.byKey(const Key('product-name-field')),
      );
      expect(nameField.controller?.text, 'Apple Juice');
      expect(
        find.widgetWithText(
          ElevatedButton,
          AppStrings.t('save', 'ar'),
        ),
        findsOneWidget,
      );
    });
  });

  group('Products permissions', () {
    testWidgets(
        'user without product_view does not see Products nav or data',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _adminLoginBody(scopes: ['pos_sale']),
      );
      await pumpApp(tester, dio, userName: 'Admin', pin: '1234');

      expect(find.text(AppStrings.t('products', 'ar')), findsNothing);
      expect(find.byType(ProductsScreen), findsNothing);
      verifyNever(
        () => dio.get(
          _productsPath,
          queryParameters: any(named: 'queryParameters'),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'user with product_view but without product_create '
        'sees no Add button', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _adminLoginBody(
          scopes: ['product_view', 'category_view'],
        ),
      );
      await pumpApp(
        tester,
        dio,
        userName: 'Admin',
        pin: '1234',
        navLabel: AppStrings.t('products', 'ar'),
      );

      expect(find.byType(ProductsScreen), findsOneWidget);
      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.byKey(const Key('products-add-button')), findsNothing);
      expect(
        find.byKey(const Key('products-manage-categories-button')),
        findsNothing,
      );
      // No update/archive action columns without those scopes.
      expect(
        find.byKey(
          const Key('product-edit-00000000-0000-0000-0000-0000000000p1'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('product-archive-00000000-0000-0000-0000-0000000000p1'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
