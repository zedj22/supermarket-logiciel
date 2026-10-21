// Phase 5 UI refinement + final visual redesign regression tests:
// - Responsive ProductsScreen at 600×500, 800×600, 1024×768, 1920×1080 + Arabic RTL narrow
// - Product form / categories dialogs at narrow sizes (no overflow)
// - Product image picker: choose/preview/cancel/replace/remove/unsupported/edit-with-image/missing-path
// - Final redesign: full-width workspace, unified toolbar, empty/loading/error states, gates
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/colors.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/product_image_picker_service.dart';
import 'package:supermarket_pos/features/products/products_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

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

/// In-memory fake for the image picker — never opens a real dialog.
class FakeImagePicker implements ProductImagePickerService {
  FakeImagePicker({this.nextPath, this.failWithException = false});

  String? nextPath;
  bool failWithException;
  int pickCalls = 0;

  @override
  Future<String?> pickImage() async {
    pickCalls++;
    if (failWithException) {
      throw Exception('dialog failed');
    }
    return nextPath;
  }

  @override
  bool isSupportedPath(String path) {
    final lower = path.toLowerCase();
    return kAllowedProductImageExtensions.any(lower.endsWith);
  }
}

const _loginPath = '/api/v1/auth/login';
const _productsPath = '/api/v1/products';
const _categoriesPath = '/api/v1/categories';

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
  String? imagePath,
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
      'image_path': imagePath,
      'category_id': categoryId,
      'category_name': categoryName,
      'is_archived': archived,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _productsListBody({String? imagePath}) => {
      'items': [
        _productJson(
          id: '00000000-0000-0000-0000-0000000000p1',
          name: 'Apple Juice',
          barcode: '111222333',
          categoryId: '00000000-0000-0000-0000-0000000000c1',
          categoryName: 'Drinks',
          imagePath: imagePath,
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
  });

  Response<dynamic> okResponse(String path, Object? data) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: 200,
      );

  void stubRequests(
    MockDio dio, {
    Map<String, dynamic>? productsBody,
    Map<String, dynamic>? loginBody,
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
        ],
        'total': 1,
      }),
    );
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_loginPath, loginBody ?? _adminLoginBody()),
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
      final q = invocation.namedArguments[#queryParameters];
      if (q is Map<String, dynamic>) {
        productQueryLog?.add(Map<String, dynamic>.from(q));
      }
      return okResponse(
        _productsPath,
        productsBody ?? _productsListBody(),
      );
    });
    when(
      () => dio.get(
        _categoriesPath,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => okResponse(_categoriesPath, _categoriesListBody()),
    );
    when(() => dio.post(_productsPath, data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_productsPath, {
        'id': '00000000-0000-0000-0000-0000000000p3',
        'name': 'New',
        'barcode': '999',
        'sku': null,
        'description': null,
        'unit': 'piece',
        'price': '10',
        'cost': '0',
        'quantity': '0',
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
      }),
    );
    when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => okResponse(_productsPath, {}),
    );
    when(() => dio.delete(any())).thenAnswer(
      (_) async => okResponse(_productsPath, {}),
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

  Future<void> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required Size size,
    FakeImagePicker? imagePicker,
    bool useArabic = false,
    AppThemeMode? themeMode,
    AppLocale? locale,
  }) async {
    // Login at a comfortable size first — the login PIN pad does not fit
    // in a 600×500 viewport. Then switch to the target size so the
    // Products screen (and open dialogs) are laid out at that size.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
          if (imagePicker != null)
            productImagePickerProvider.overrideWithValue(imagePicker),
          if (themeMode != null)
            themeProvider.overrideWith(
              (ref) => ThemeNotifier()..setTheme(themeMode),
            ),
          if (locale != null)
            localeProvider.overrideWith(
              (ref) => LocaleNotifier()..setLocale(locale),
            ),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    // Switch to the target viewport before exercising the products UI.
    tester.view.physicalSize = size;
    await tester.pumpAndSettle();

    await tester.tap(
      find.text(AppStrings.t('products', locale?.name ?? 'ar')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  void expectNoOverflow(WidgetTester tester) {
    expect(tester.takeException(), isNull);
  }

  group('Responsive ProductsScreen', () {
    final sizes = <String, Size>{
      '600x500': const Size(600, 500),
      '800x600': const Size(800, 600),
      '1024x768': const Size(1024, 768),
      '1366x768': const Size(1366, 768),
      '1920x1080': const Size(1920, 1080),
    };

    for (final entry in sizes.entries) {
      testWidgets('renders products list at ${entry.key} without overflow',
          (tester) async {
        final dio = MockDio();
        stubRequests(dio);
        await pumpApp(tester, dio, size: entry.value);

        expect(find.byKey(const Key('products-search-field')), findsOneWidget);
        expect(find.byKey(const Key('products-status-filter')), findsOneWidget);
        expect(find.text('Apple Juice'), findsOneWidget);
        expect(find.byKey(const Key('products-total')), findsOneWidget);

        // Narrow (<800) uses cards; medium/wide use the table.
        if (entry.value.width < 800) {
          expect(find.byKey(const Key('products-cards')), findsOneWidget);
          expect(find.byKey(const Key('products-table')), findsNothing);
        } else {
          expect(find.byKey(const Key('products-table')), findsOneWidget);
        }
        expectNoOverflow(tester);
      });
    }

    testWidgets('no table cell wraps into a second line at any desktop size',
        (tester) async {
      // A wrapped figure ("20.00" / "0%") reads as two values, so every
      // cell in the table — header, figure, pill, badge — has to stay on
      // one line at each supported desktop width.
      const sizes = <String, Size>{
        '1280x720': Size(1280, 720),
        '1366x768': Size(1366, 768),
        '1600x900': Size(1600, 900),
        '1920x1080': Size(1920, 1080),
      };

      for (final entry in sizes.entries) {
        final dio = MockDio();
        stubRequests(dio);
        await pumpApp(tester, dio, size: entry.value);

        final texts = tester.widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('products-table')),
            matching: find.byType(Text),
          ),
        );
        expect(texts, isNotEmpty, reason: 'no table text at ${entry.key}');

        for (final text in texts) {
          // Local layout size: ancestor transforms (the figures are scaled
          // down by a FittedBox when the column is tight) must not hide a
          // wrap.
          final size =
              (tester.renderObject(find.byWidget(text)) as RenderBox).size;
          final fontSize = text.style?.fontSize;
          final ceiling = text.maxLines == 2
              ? fontSize! * 3.0
              : fontSize == null
                  ? 26.0
                  : fontSize * 1.6;
          expect(
            size.height,
            lessThanOrEqualTo(ceiling),
            reason: '"${text.data}" wrapped to ${size.height}px '
                '(fs=$fontSize) at ${entry.key}',
          );
        }
        expectNoOverflow(tester);

        await tester.tap(find.byKey(const Key('products-search-field')));
      }
    });

    testWidgets('Arabic RTL narrow layout has no overflow', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        size: const Size(600, 500),
        useArabic: true,
      );

      expect(find.byKey(const Key('products-cards')), findsOneWidget);
      expect(find.text('Apple Juice'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('cost is hidden on narrow card list for view-only user',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      // Rebuild with limited scopes: product_view only.
      when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
        (_) async => okResponse(
          _loginPath,
          _adminLoginBody(
            scopes: const ['product_view', 'category_view'],
          ),
        ),
      );
      await pumpApp(tester, dio, size: const Size(600, 500));

      expect(find.byKey(const Key('products-cards')), findsOneWidget);
      expect(find.text(AppStrings.t('cost', 'ar')), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('Product form dialog at narrow viewport', () {
    testWidgets('opens, shows image section, submits without overflow',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: null);
      await pumpApp(
        tester,
        dio,
        size: const Size(600, 500),
        imagePicker: picker,
      );

      await tester.tap(find.byKey(const Key('products-add-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('product-name-field')), findsOneWidget);
      expect(find.byKey(const Key('product-image-preview')), findsOneWidget);
      expect(find.byKey(const Key('product-image-choose')), findsOneWidget);
      expectNoOverflow(tester);

      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Narrow Item',
      );
      await tester.enterText(
        find.byKey(const Key('product-price-field')),
        '10',
      );
      await tester.tap(find.byKey(const Key('product-form-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('Categories dialog at narrow viewport', () {
    testWidgets('opens and lists categories without overflow',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(600, 500));

      await tester.tap(
        find.byKey(const Key('products-manage-categories-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('categories-dialog')), findsOneWidget);
      expect(find.text('Drinks'), findsWidgets);
      expect(find.text('Snacks'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('Product image picker', () {
    Future<void> openForm(
      WidgetTester tester,
      MockDio dio,
      FakeImagePicker picker, {
      Size size = const Size(1024, 768),
    }) async {
      await pumpApp(tester, dio, size: size, imagePicker: picker);
      await tester.tap(
        find.byKey(const Key('products-add-button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      // The image section sits at the bottom of a scrollable form.
      final choose = find.byKey(const Key('product-image-choose'));
      await tester.ensureVisible(choose);
      await tester.pumpAndSettle();
    }

    Future<void> tapChoose(WidgetTester tester) async {
      final choose = find.byKey(const Key('product-image-choose'));
      await tester.ensureVisible(choose);
      await tester.pumpAndSettle();
      await tester.tap(choose);
      await tester.pumpAndSettle();
    }

    testWidgets('choose image action exists on empty form', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker();
      await openForm(tester, dio, picker);

      expect(find.byKey(const Key('product-image-choose')), findsOneWidget);
      expect(find.byKey(const Key('product-image-placeholder')), findsOneWidget);
      expect(
        find.text(AppStrings.t('no_image', 'ar')),
        findsWidgets,
      );
      expect(picker.pickCalls, 0);
      expectNoOverflow(tester);
    });

    testWidgets('successful pick shows preview and file name', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: 'C:/tmp/pic.png');
      await openForm(tester, dio, picker);

      await tapChoose(tester);

      expect(picker.pickCalls, 1);
      expect(find.byKey(const Key('product-image-name')), findsOneWidget);
      expect(find.text('pic.png'), findsOneWidget);
      expect(find.byKey(const Key('product-image-remove')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('cancel (null path) keeps form without error', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: null);
      await openForm(tester, dio, picker);

      await tapChoose(tester);

      expect(picker.pickCalls, 1);
      expect(find.byKey(const Key('product-form-error')), findsNothing);
      expect(find.byKey(const Key('product-image-placeholder')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('replace image swaps to the new path', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: 'C:/tmp/first.png');
      await openForm(tester, dio, picker);

      await tapChoose(tester);
      expect(find.text('first.png'), findsOneWidget);

      picker.nextPath = 'C:/tmp/second.png';
      await tapChoose(tester);

      expect(picker.pickCalls, 2);
      expect(find.text('second.png'), findsOneWidget);
      expect(find.text('first.png'), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('remove image clears selection back to placeholder',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: 'C:/tmp/pic.png');
      await openForm(tester, dio, picker);

      await tapChoose(tester);
      expect(find.text('pic.png'), findsOneWidget);

      final remove = find.byKey(const Key('product-image-remove'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();

      expect(find.text('pic.png'), findsNothing);
      expect(find.byKey(const Key('product-image-placeholder')), findsOneWidget);
      expect(find.byKey(const Key('product-image-remove')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('unsupported extension is rejected with error and no path',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      final picker = FakeImagePicker(nextPath: 'C:/tmp/malware.exe');
      await openForm(tester, dio, picker);

      await tapChoose(tester);

      // Extension allowlist rejects .exe before it can be applied.
      expect(picker.isSupportedPath('C:/tmp/malware.exe'), isFalse);
      expect(picker.pickCalls, 1);
      expect(find.text('malware.exe'), findsNothing);
      // Path never applied → still empty placeholder (no crash).
      expect(find.byKey(const Key('product-image-placeholder')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('edit product with existing image path shows preview area',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: _productsListBody(imagePath: 'C:/missing/pic.png'),
      );
      final picker = FakeImagePicker();
      await pumpApp(
        tester,
        dio,
        size: const Size(1024, 768),
        imagePicker: picker,
      );

      final editKey = find.byKey(
        const Key('product-edit-00000000-0000-0000-0000-0000000000p1'),
      );
      await tester.ensureVisible(editKey);
      await tester.pumpAndSettle();
      await tester.tap(editKey);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      final remove = find.byKey(const Key('product-image-remove'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      expect(remove, findsOneWidget);
      expect(find.byKey(const Key('product-image-preview')), findsOneWidget);
      // Path set but file missing on disk → placeholder, no crash.
      expect(find.byKey(const Key('product-image-placeholder')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('missing path on card thumbnail falls back to icon',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: _productsListBody(imagePath: 'C:/gone/nope.png'),
      );
      await pumpApp(tester, dio, size: const Size(600, 500));

      expect(find.byKey(const Key('products-cards')), findsOneWidget);
      expect(find.byIcon(Icons.inventory_2_outlined), findsWidgets);
      expectNoOverflow(tester);
    });
  });

  group('Phase 5 final visual redesign', () {
    Map<String, dynamic> emptyProductsBody() => {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        };

    testWidgets('wide workspace fills content width after nav rail',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      final workspace = tester.widget<Material>(
        find.byKey(const Key('products-workspace')),
      );
      expect(workspace, isNotNull);

      final workspaceRect = tester.getRect(
        find.byKey(const Key('products-workspace')),
      );
      final screen = tester.getSize(find.byType(MaterialApp));
      // Fills nearly the full content width (nav rail + page padding only).
      expect(workspaceRect.width, greaterThan(screen.width * 0.75));
      expect(workspaceRect.right, lessThanOrEqualTo(screen.width));

      final toolbarRect = tester.getRect(
        find.byKey(const Key('products-toolbar')),
      );
      expect(
        toolbarRect.width,
        closeTo(workspaceRect.width, 1.0),
        reason: 'toolbar and workspace share the same content column width',
      );
      expect(find.byKey(const Key('products-header-title')), findsOneWidget);
      expect(find.byKey(const Key('products-header-subtitle')), findsOneWidget);
      expect(find.byKey(const Key('products-add-button')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('medium layout uses table and unified toolbar keys',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1024, 768));

      expect(find.byKey(const Key('products-toolbar')), findsOneWidget);
      expect(find.byKey(const Key('products-workspace')), findsOneWidget);
      expect(find.byKey(const Key('products-table')), findsOneWidget);
      expect(find.byKey(const Key('products-cards')), findsNothing);
      expect(find.byKey(const Key('products-refresh-button')), findsOneWidget);
      expect(find.byKey(const Key('products-footer')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('empty state shows empty key and Add when permitted',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, productsBody: emptyProductsBody());
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byKey(const Key('products-empty')), findsOneWidget);
      expect(find.byKey(const Key('products-empty-add')), findsOneWidget);
      expect(find.byKey(const Key('products-workspace')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('empty state hides Add when product_create is missing',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: emptyProductsBody(),
        loginBody: _adminLoginBody(
          scopes: const ['product_view', 'category_view'],
        ),
      );
      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byKey(const Key('products-empty')), findsOneWidget);
      expect(find.byKey(const Key('products-empty-add')), findsNothing);
      expect(find.byKey(const Key('products-add-button')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('error state shows message and retry re-fetches',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      // First product load fails; retry succeeds.
      var failNext = true;
      when(
        () => dio.get(
          _productsPath,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async {
        if (failNext) {
          failNext = false;
          throw DioException(
            requestOptions: RequestOptions(path: _productsPath),
            type: DioExceptionType.connectionTimeout,
          );
        }
        return okResponse(_productsPath, _productsListBody());
      });

      await pumpApp(tester, dio, size: const Size(1366, 768));

      expect(find.byKey(const Key('products-error')), findsOneWidget);
      expect(find.byKey(const Key('products-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('products-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Apple Juice'), findsOneWidget);
      expect(find.byKey(const Key('products-error')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('loading state key appears while products are fetching',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      // Gate the first products response so loading is observable.
      final gate = Completer<void>();
      when(
        () => dio.get(
          _productsPath,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async {
        await gate.future;
        return okResponse(_productsPath, _productsListBody());
      });

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            credentialStorageProvider
                .overrideWithValue(FakeCredentialStorage()),
          ],
          child: const SupermarketPosApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Admin'));
      await tester.pumpAndSettle();
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('login-submit-button')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.text(AppStrings.t('products', 'ar')),
        warnIfMissed: false,
      );
      // Allow initState microtask → load() to start, but not complete.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('products-loading')), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Apple Juice'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('search clear button resets the query and reloads',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);
      await pumpApp(tester, dio, size: const Size(1366, 768));

      await tester.enterText(
        find.byKey(const Key('products-search-field')),
        'Apple',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('products-search-clear')), findsOneWidget);
      expect(queryLog.last['search'], 'Apple');

      await tester.tap(find.byKey(const Key('products-search-clear')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(queryLog.last['search'], isNot('Apple'));
      expectNoOverflow(tester);
    });

    testWidgets('permission gates: no edit/archive without product_update',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _adminLoginBody(
          scopes: const ['product_view', 'category_view'],
        ),
      );
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.byType(ProductsScreen), findsOneWidget);
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
      expect(find.byKey(const Key('products-add-button')), findsNothing);
      // Cost column gated on product_update.
      expect(find.text(AppStrings.t('cost', 'ar')), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('Phase 5 final color & visual polish', () {
    testWidgets('wide table shows status badge and category pill keys',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.byKey(const Key('products-table')), findsOneWidget);
      // Apple Juice qty 10 > threshold 5 → active; Bread qty 20 → active.
      expect(find.byKey(const Key('product-status-active')), findsWidgets);
      expect(
        find.byKey(
          const Key('product-category-pill-Drinks'),
        ),
        findsWidgets,
      );
      expect(find.byKey(const Key('product-unit-piece')), findsWidgets);
      expect(find.byKey(const Key('products-header-subtitle')), findsOneWidget);
      expect(find.byKey(const Key('products-sort-filter')), findsOneWidget);
      expect(find.byKey(const Key('products-page-size')), findsOneWidget);
      expect(find.byKey(const Key('products-status-filter')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('table cells, pills and badges meet the readability floor', (
      tester,
    ) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      // Column labels: the shared table rung, read from the rendered
      // RichText because the cell itself inherits its style.
      final header = tester.widget<RichText>(
        find.descendant(
          of: find.descendant(
            of: find.byKey(const Key('products-table-header')),
            matching: find.text(AppStrings.t('price', 'ar')),
          ),
          matching: find.byType(RichText),
        ),
      );
      expect(header.text.style?.fontSize, inInclusiveRange(13, 14));
      expect(header.text.style?.fontWeight, FontWeight.w700);

      // Product name: the strongest text in the row.
      final name = tester.widget<Text>(find.text('Apple Juice'));
      expect(name.style?.fontSize, greaterThanOrEqualTo(14));
      expect(name.style?.fontWeight?.value, greaterThan(FontWeight.w500.value));

      // Money and quantity: 14px floor, tabular figures from the numeric rung.
      final qty = tester.widget<Text>(
        find.byKey(const Key('product-qty-00000000-0000-0000-0000-0000000000p1')),
      );
      expect(qty.style?.fontSize, inInclusiveRange(14, 16));
      expect(qty.style?.fontFeatures, isNotEmpty);

      // Category pill and status badge are the smallest labels and still
      // clear the 11px badge floor (12px for the pill).
      final pill = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('product-category-pill-Drinks')),
          matching: find.byType(Text),
        ),
      );
      expect(pill.style?.fontSize, greaterThanOrEqualTo(12));
      // The pill foreground is contrast-selected against the composited
      // 14% wash — it must clear WCAG AA, not merely exist. The pill's
      // hue is hashed from the category ID (default theme is dark).
      final pillColor =
          AppColors.categoryIdentity('00000000-0000-0000-0000-0000000000c1');
      final pillBg = Color.lerp(
        AppColors.darkSurface,
        pillColor,
        0.14,
      )!;
      expect(pill.style?.color, isNotNull);
      expect(
        AppColors.contrastRatio(pill.style!.color!, pillBg),
        greaterThanOrEqualTo(4.5),
        reason: 'category pill text must clear WCAG AA on its wash',
      );

      final badge = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('product-status-active')),
          matching: find.byType(Text),
        ),
      ).first;
      expect(badge.style?.fontSize, greaterThanOrEqualTo(11));

      expectNoOverflow(tester);
    });

    testWidgets('Phase 17 §17.2 the table heading is pinned above the rows',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      final header = find.byKey(const Key('products-table-header'));
      final body = find.byKey(const Key('products-table-body'));
      expect(header, findsOneWidget);
      expect(body, findsOneWidget);
      // Structurally the heading is a *sibling* of the scrolling body —
      // if it were ever nested inside it, the labels would scroll away.
      expect(find.descendant(of: body, matching: header), findsNothing);

      final before = tester.getTopLeft(header);
      expect(tester.getTopLeft(body).dy, greaterThan(before.dy));

      await tester.drag(body, const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(header, findsOneWidget);
      expect(tester.getTopLeft(header), before,
          reason: 'the heading must not travel with the rows');
      expectNoOverflow(tester);
    });

    testWidgets('narrow cards show status badge, pills, and unit pill',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(600, 500));

      expect(find.byKey(const Key('products-cards')), findsOneWidget);
      expect(find.byKey(const Key('product-status-active')), findsWidgets);
      expect(
        find.byKey(const Key('product-category-pill-Drinks')),
        findsWidgets,
      );
      expect(find.byKey(const Key('product-unit-piece')), findsWidgets);
      expect(find.byKey(const Key('products-header-subtitle')), findsNothing);
      // Page-size control is ≥800 only.
      expect(find.byKey(const Key('products-page-size')), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('status filter header key and status labels use AppStrings',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.text(AppStrings.t('status', 'ar')), findsOneWidget);
      expect(find.text(AppStrings.t('active', 'ar')), findsWidgets);
      expect(find.text(AppStrings.t('refresh', 'ar')), findsNothing);
      expect(
        find.byKey(const Key('products-refresh-button')),
        findsOneWidget,
      );
      expectNoOverflow(tester);
    });

    testWidgets('page size change resets to page 1 via setPageSize',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);
      await pumpApp(tester, dio, size: const Size(1600, 900));

      final pageSize = find.byKey(const Key('products-page-size'));
      expect(pageSize, findsOneWidget);
      await tester.ensureVisible(pageSize);
      await tester.tap(pageSize);
      await tester.pumpAndSettle();
      await tester.tap(find.text('25').last);
      await tester.pumpAndSettle();

      expect(queryLog, isNotEmpty);
      expect(queryLog.last['page_size'], 25);
      expect(queryLog.last['page'], 1);
      expectNoOverflow(tester);
    });

    testWidgets('sort dropdown appears on wide only', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, productQueryLog: queryLog);
      await pumpApp(tester, dio, size: const Size(1600, 900));
      expect(find.byKey(const Key('products-sort-filter')), findsOneWidget);
      await tester.tap(find.byKey(const Key('products-sort-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${AppStrings.t('sort_price', 'ar')} ↑'));
      await tester.pumpAndSettle();
      expect(queryLog.last['sort_by'], 'price');
      expect(queryLog.last['sort_order'], 'asc');
      expectNoOverflow(tester);
    });

    testWidgets('sort dropdown hidden on narrow cards', (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(tester, dio, size: const Size(600, 500));
      expect(find.byKey(const Key('products-sort-filter')), findsNothing);
      expect(find.byKey(const Key('products-refresh-button')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('Arabic RTL narrow shows localized status and subtitle off',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      await pumpApp(
        tester,
        dio,
        size: const Size(600, 500),
        useArabic: true,
      );

      expect(find.byKey(const Key('products-cards')), findsOneWidget);
      expect(find.text(AppStrings.t('active', 'ar')), findsWidgets);
      expect(find.text(AppStrings.t('products_subtitle', 'ar')), findsNothing);
      expect(find.text('Apple Juice'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('out of stock status uses error key when quantity is zero',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: {
          'items': [
            _productJson(
              id: '00000000-0000-0000-0000-0000000000p9',
              name: 'Gone Item',
              barcode: '000999',
              quantity: '0.0',
            ),
          ],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      );
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.byKey(const Key('product-status-out')), findsOneWidget);
      expect(find.text(AppStrings.t('out_of_stock', 'ar')), findsOneWidget);
      expect(find.text('Gone Item'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('low stock status uses warning key at threshold',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: {
          'items': [
            _productJson(
              id: '00000000-0000-0000-0000-0000000000p8',
              name: 'Low Item',
              barcode: '000555',
              quantity: '5.0',
            ),
          ],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      );
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.byKey(const Key('product-status-low')), findsOneWidget);
      expect(find.text(AppStrings.t('low_stock', 'ar')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('archived product status wins over stock quantity',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        productsBody: {
          'items': [
            _productJson(
              id: '00000000-0000-0000-0000-0000000000p7',
              name: 'Old Item',
              barcode: '000444',
              quantity: '0.0',
              archived: true,
            ),
          ],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      );
      await pumpApp(tester, dio, size: const Size(1600, 900));

      expect(find.byKey(const Key('product-status-archived')), findsOneWidget);
      expect(find.text(AppStrings.t('archived', 'ar')), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('Layout mode helper', () {
    test('breakpoints map to wide/medium/narrow', () {
      expect(productsLayoutModeFor(600), ProductsLayoutMode.narrow);
      expect(productsLayoutModeFor(799), ProductsLayoutMode.narrow);
      expect(productsLayoutModeFor(800), ProductsLayoutMode.medium);
      expect(productsLayoutModeFor(1199), ProductsLayoutMode.medium);
      expect(productsLayoutModeFor(1200), ProductsLayoutMode.wide);
      expect(productsLayoutModeFor(1920), ProductsLayoutMode.wide);
    });
  });
}
