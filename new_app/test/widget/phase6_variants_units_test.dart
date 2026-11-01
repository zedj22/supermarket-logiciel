// Phase 6 tests — variants, selling units, quantity dialog, pickers,
// product form management sections, barcode lookup model, i18n keys.
//
// Covers (spec §32):
// - VariantModel / SellingUnitModel / BarcodeLookupModel parsing
// - Quantity dialog: conversion preview, validation, confirm/cancel
// - Selling unit picker: list, empty, error, select → quantity
// - Variant picker: list, empty, inherit price display
// - Product form: manage variants / selling units sections (edit mode)
// - Selling unit form: base multiplier=1, price independent
// - ar/fr/en keys for all Phase 6 strings
// - No hardcoded visible strings (keys exist in all locales)
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
import 'package:supermarket_pos/features/products/quantity_dialog.dart';
import 'package:supermarket_pos/features/products/selling_unit_form_dialog.dart';
import 'package:supermarket_pos/features/products/selling_unit_picker.dart';
import 'package:supermarket_pos/features/products/variant_form_dialog.dart';
import 'package:supermarket_pos/features/products/variant_picker.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
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

const _loginPath = '/api/v1/auth/login';
const _productsPath = '/api/v1/products';
const _setupCheckPath = '/api/v1/auth/setup/check';
const _verifyTokenPath = '/api/v1/auth/verify-token';
const _mePath = '/api/v1/auth/me';

Map<String, dynamic> _loginBody({List<String> scopes = const [
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_view',
  'category_manage',
]}) =>
    {
      'access_token': 'tok',
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

Map<String, dynamic> _verifyTokenBody({List<String> scopes = const [
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_view',
  'category_manage',
]}) =>
    {
      'valid': true,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'permissions': scopes,
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

Map<String, dynamic> _meBody({List<String> scopes = const [
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_view',
  'category_manage',
]}) =>
    {
      'id': '00000000-0000-0000-0000-0000000000a1',
      'full_name': 'Admin',
      'is_active': true,
      'permissions': scopes,
      'roles': ['admin'],
    };

Map<String, dynamic> _productJson({
  String id = 'prod-1',
  String name = 'Fromage Test',
  String barcode = '900000',
  String price = '10',
  String quantity = '240',
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
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
      'created_at': '2026-09-23T00:00:00Z',
      'updated_at': '2026-09-23T00:00:00Z',
    };

Map<String, dynamic> _variantJson({
  String id = 'var-1',
  String name = 'Large',
  String? barcode = 'VAR1',
  String? price = '12',
}) =>
    {
      'id': id,
      'product_id': 'prod-1',
      'name': name,
      'barcode': barcode,
      'sku': null,
      'price': price,
      'cost': null,
      'quantity': '10',
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-09-23T00:00:00Z',
      'updated_at': '2026-09-23T00:00:00Z',
    };

Map<String, dynamic> _sellingUnitJson({
  String id = 'su-1',
  String name = 'Box',
  String multiplier = '24',
  String? sellingPrice = '220',
  bool isBaseUnit = false,
  String availableSelling = '10',
}) =>
    {
      'id': id,
      'product_id': 'prod-1',
      'name': name,
      'unit_type': 'piece',
      'multiplier': multiplier,
      'barcode': 'BOX$id',
      'selling_price': sellingPrice,
      'is_base_unit': isBaseUnit,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-09-23T00:00:00Z',
      'updated_at': '2026-09-23T00:00:00Z',
      'available_base_qty': '240',
      'available_selling_qty': availableSelling,
      'effective_price': sellingPrice ?? '10',
    };

/// Stubs login + product GET (+ optional nested endpoints).
///
/// Mocktail last-match-wins for a given method signature, so all GETs are
/// registered as a single generic stub that dispatches on path.
void stubRequests(
  MockDio dio, {
  Map<String, dynamic>? productsBody,
  Map<String, dynamic>? loginBody,
  List<String>? productQueryLog,
  Map<String, Map<String, dynamic>>? getBodies,
}) {
  Response<dynamic> ok(String path, Object? data) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  final productsDefault = productsBody ??
      {
        'items': [_productJson()],
        'total': 1,
        'page': 1,
        'page_size': 40,
        'pages': 1,
      };

  Object? bodyFor(String path, {Map<String, dynamic>? qp}) {
    if (path == _loginPath) return loginBody ?? _loginBody();
    if (path == _productsPath) {
      productQueryLog?.add('${qp?['page'] ?? 1}|${qp?['page_size'] ?? 40}');
      return productsDefault;
    }
    if (path == _setupCheckPath) return {'setup_needed': false};
    if (path == _mePath) return _meBody();
    return getBodies?[path] ?? {'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final qp =
        invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
    return ok(path, bodyFor(path, qp: qp));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return ok(path, bodyFor(path));
  });

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      if (path == _verifyTokenPath) return ok(path, _verifyTokenBody());
      if (path == _loginPath) return ok(path, loginBody ?? _loginBody());
      return ok(path, loginBody ?? _loginBody());
    },
  );
  when(() => dio.post(any())).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      if (path == _verifyTokenPath) return ok(path, _verifyTokenBody());
      return ok(path, loginBody ?? _loginBody());
    },
  );
}

Future<void> pumpApp(
  WidgetTester tester,
  Widget app, {
  MockDio? dio,
  Size size = const Size(1280, 900),
  bool stubDio = true,
}) async {
  final mockDio = dio ?? MockDio();
  final storage = FakeCredentialStorage();
  await storage.saveToken('tok');
  await storage.saveUserPermissions([
    'product_view',
    'product_create',
    'product_update',
    'product_archive',
    'category_view',
    'category_manage',
  ]);
  await storage.saveUserRoles(['admin']);

  if (stubDio) {
    // Caller already stubbed with getBodies → only ensure interceptors/options
    // when they passed a pre-stubbed dio. Otherwise fully stub a fresh dio.
    if (dio == null) {
      stubRequests(mockDio);
    } else {
      when(() => mockDio.interceptors).thenReturn(Interceptors());
      when(() => mockDio.options).thenReturn(BaseOptions());
    }
  }

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: mockDio)),
        credentialStorageProvider.overrideWithValue(storage),
        // English locale so AppStrings.t(..., 'en') matches on-screen text.
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: app,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

// ---------------------------------------------------------------------------
// Model parsing
// ---------------------------------------------------------------------------

void main() {
  group('Phase 6 model parsing', () {
    test('VariantModel.fromJson with price override', () {
      final v = VariantModel.fromJson(_variantJson());
      expect(v.id, 'var-1');
      expect(v.name, 'Large');
      expect(v.price, '12');
      expect(v.barcode, 'VAR1');
      expect(v.isArchived, false);
    });

    test('VariantModel.fromJson null price inherits', () {
      final v = VariantModel.fromJson(_variantJson(price: null));
      expect(v.price, isNull);
    });

    test('SellingUnitModel.fromJson with availability', () {
      final u = SellingUnitModel.fromJson(_sellingUnitJson());
      expect(u.multiplier, '24');
      expect(u.sellingPrice, '220');
      expect(u.availableSellingQty, '10');
      expect(u.effectivePrice, '220');
      expect(u.isBaseUnit, false);
    });

    test('BarcodeLookupModel.fromJson found selling unit', () {
      final m = BarcodeLookupModel.fromJson({
        'found': true,
        'kind': 'selling_unit',
        'product_id': 'prod-1',
        'product_name': 'Fromage',
        'product_price': '10',
        'product_quantity': '240',
        'product_unit': 'piece',
        'selling_unit_id': 'su-1',
        'selling_unit_name': 'Box',
        'selling_unit_multiplier': '24',
        'selling_unit_price': '220',
        'is_archived': false,
      });
      expect(m.found, true);
      expect(m.kind, 'selling_unit');
      expect(m.sellingUnitMultiplier, '24');
      expect(m.sellingUnitPrice, '220');
    });

    test('BarcodeLookupModel.fromJson not found', () {
      final m = BarcodeLookupModel.fromJson({'found': false});
      expect(m.found, false);
      expect(m.kind, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // i18n keys — all Phase 6 keys exist in ar/fr/en
  // ---------------------------------------------------------------------------

  group('Phase 6 i18n keys', () {
    const keys = [
      'variants',
      'add_variant',
      'edit_variant',
      'archive_variant',
      'selling_units',
      'add_selling_unit',
      'edit_selling_unit',
      'archive_selling_unit',
      'base_unit',
      'selling_unit',
      'multiplier',
      'pieces_per_box',
      'quantity_per_unit',
      'price_per_unit',
      'price_override',
      'inherit_price',
      'available_quantity',
      'available_boxes',
      'enter_quantity',
      'weight',
      'piece',
      'box',
      'boite',
      'carton',
      'unit_price',
      'conversion',
      'one_unit_equals',
      'no_variants',
      'no_selling_units',
      'variant_name',
      'selling_unit_name',
      'is_base_unit',
      'manage_variants',
      'manage_selling_units',
      'select_variant',
      'select_selling_unit',
      'archived_unit',
      'archived_variant',
      'multiplier_hint',
      'selling_units_hint',
      'variants_hint',
    ];

    for (final loc in ['ar', 'fr', 'en']) {
      test('all keys present and non-empty in $loc', () {
        for (final k in keys) {
          final value = AppStrings.t(k, loc);
          expect(value, isNotEmpty, reason: 'missing key $k in $loc');
          expect(value, isNot(k), reason: 'key $k not translated in $loc');
        }
      });
    }

    test('Arabic strings are RTL script (not identical to English)', () {
      // Spot-check a few — must differ from English fallback
      expect(AppStrings.t('selling_units', 'ar'), isNot('Selling Units'));
      expect(AppStrings.t('base_unit', 'ar'), isNot('Base Unit'));
      expect(AppStrings.t('variants', 'ar'), isNot('Variants'));
    });
  });

  // ---------------------------------------------------------------------------
  // Quantity dialog
  // ---------------------------------------------------------------------------

  group('Quantity dialog', () {
    const boxUnit = SellingUnitModel(
      id: 'su-box',
      productId: 'prod-1',
      name: 'Box',
      multiplier: '24',
      sellingPrice: '220',
      availableSellingQty: '10',
    );

    testWidgets('shows conversion preview with explicit multiplier',
        (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: QuantityDialog(
              unit: boxUnit,
              productQuantity: '240',
              productUnit: 'piece',
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('quantity-dialog')), findsOneWidget);
      expect(find.byKey(const Key('quantity-conversion')), findsOneWidget);
      expect(
        find.textContaining('24'),
        findsWidgets,
        reason: 'conversion must show multiplier 24',
      );
      expect(find.byKey(const Key('quantity-input')), findsOneWidget);
    });

    testWidgets('rejects quantity exceeding base stock', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: QuantityDialog(
              unit: boxUnit,
              productQuantity: '240',
              productUnit: 'piece',
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '11',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pump();
      expect(find.byKey(const Key('quantity-error')), findsOneWidget);
    });

    testWidgets('accepts valid quantity and returns it', (tester) async {
      String? result;
      await pumpApp(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open-btn'),
                  onPressed: () async {
                    result = await showQuantityDialog(
                      context,
                      unit: boxUnit,
                      productQuantity: '240',
                      productUnit: 'piece',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('quantity-input')),
        '5',
      );
      await tester.tap(find.byKey(const Key('quantity-submit')));
      await tester.pumpAndSettle();
      expect(result, '5');
    });

    testWidgets('cancel returns null', (tester) async {
      String? result = 'unset';
      await pumpApp(
        tester,
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('open-btn'),
                  onPressed: () async {
                    result = await showQuantityDialog(
                      context,
                      unit: boxUnit,
                      productQuantity: '240',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.t('cancel', 'en')));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Selling unit picker
  // ---------------------------------------------------------------------------

  group('Selling unit picker', () {
    testWidgets('lists units with multiplier and price', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/selling-units': {
            'items': [
              _sellingUnitJson(
                id: 'su-base',
                name: 'Piece',
                multiplier: '1',
                sellingPrice: '10',
                isBaseUnit: true,
                availableSelling: '240',
              ),
              _sellingUnitJson(),
            ],
            'total': 2,
          },
        },
      );

      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SellingUnitPicker(productId: 'prod-1', productQuantity: '240'),
          ),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('selling-unit-picker')), findsOneWidget);
      expect(find.text('Piece'), findsOneWidget);
      expect(find.text('Box'), findsOneWidget);
      expect(find.textContaining('24'), findsWidgets);
    });

    testWidgets('shows empty state when no units', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/selling-units': {
            'items': <dynamic>[],
            'total': 0,
          },
        },
      );
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SellingUnitPicker(productId: 'prod-1'),
          ),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('selling-unit-picker-empty')), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Variant picker
  // ---------------------------------------------------------------------------

  group('Variant picker', () {
    testWidgets('lists variants with inherit-price fallback', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/variants': {
            'items': [
              _variantJson(price: null),
              _variantJson(id: 'var-2', name: 'Small', price: '8'),
            ],
            'total': 2,
          },
        },
      );
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: VariantPicker(productId: 'prod-1', productPrice: '10'),
          ),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('variant-picker')), findsOneWidget);
      expect(find.text('Large'), findsOneWidget);
      expect(find.text('Small'), findsOneWidget);
      // null price falls back to product price 10
      expect(find.textContaining('10'), findsWidgets);
    });

    testWidgets('empty state', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/variants': {
            'items': <dynamic>[],
            'total': 0,
          },
        },
      );
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(body: VariantPicker(productId: 'prod-1')),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('variant-picker-empty')), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Selling unit form
  // ---------------------------------------------------------------------------

  group('Selling unit form', () {
    testWidgets('base checkbox forces multiplier 1', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SellingUnitFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      expect(
        find.byKey(const Key('selling-unit-form-dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('selling-unit-multiplier-field')),
        '24',
      );
      await tester.tap(find.byKey(const Key('selling-unit-base-checkbox')));
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('selling-unit-multiplier-field')),
      );
      expect(field.controller?.text, '1');
    });

    testWidgets('rejects multiplier <= 0', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SellingUnitFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('selling-unit-name-field')),
        'Bad',
      );
      await tester.enterText(
        find.byKey(const Key('selling-unit-multiplier-field')),
        '0',
      );
      await tester.tap(find.byKey(const Key('selling-unit-form-submit')));
      await tester.pump();
      expect(
        find.byKey(const Key('selling-unit-form-error')),
        findsOneWidget,
      );
    });

    testWidgets('price field is independent (not auto-computed)',
        (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SellingUnitFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('selling-unit-multiplier-field')),
        '24',
      );
      await tester.pump();
      final priceField = tester.widget<TextField>(
        find.byKey(const Key('selling-unit-price-field')),
      );
      // Price stays empty — never filled from multiplier × base
      expect(priceField.controller?.text, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Variant form
  // ---------------------------------------------------------------------------

  group('Variant form', () {
    testWidgets('shows price override with inherit hint', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: VariantFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      expect(find.byKey(const Key('variant-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('variant-price-field')), findsOneWidget);
      expect(
        find.text(AppStrings.t('inherit_price', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('rejects empty name', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: VariantFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('variant-form-submit')));
      await tester.pump();
      expect(find.byKey(const Key('variant-form-error')), findsOneWidget);
    });

    testWidgets('rejects negative price', (tester) async {
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: VariantFormDialog(productId: 'prod-1'),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('variant-name-field')),
        'X',
      );
      await tester.enterText(
        find.byKey(const Key('variant-price-field')),
        '-1',
      );
      await tester.tap(find.byKey(const Key('variant-form-submit')));
      await tester.pump();
      expect(find.byKey(const Key('variant-form-error')), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Product form — Phase 6 management sections (edit mode)
  // ---------------------------------------------------------------------------

  group('Product form Phase 6 sections', () {
    Future<void> openEditDialog(WidgetTester tester, MockDio dio) async {
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/variants': {
            'items': [_variantJson()],
            'total': 1,
          },
          '/api/v1/products/prod-1/selling-units': {
            'items': [
              _sellingUnitJson(
                id: 'su-base',
                name: 'Piece',
                multiplier: '1',
                isBaseUnit: true,
                sellingPrice: '10',
              ),
              _sellingUnitJson(),
            ],
            'total': 2,
          },
          '/api/v1/categories': {
            'items': <dynamic>[],
            'total': 0,
            'page': 1,
            'page_size': 100,
            'pages': 1,
          },
        },
      );
      await pumpApp(
        tester,
        MaterialApp(
          home: Scaffold(
            body: ProductFormDialog(product: ProductModel.fromJson(_productJson())),
          ),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows manage variants and selling units in edit mode',
        (tester) async {
      final dio = MockDio();
      await openEditDialog(tester, dio);

      expect(
        find.text(AppStrings.t('manage_variants', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('manage_selling_units', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('add-variant-button')), findsOneWidget);
      expect(
        find.byKey(const Key('add-selling-unit-button')),
        findsOneWidget,
      );
      // Loaded rows
      expect(find.byKey(const Key('variant-row-var-1')), findsOneWidget);
      expect(
        find.byKey(const Key('selling-unit-row-su-base')),
        findsOneWidget,
      );
      expect(find.textContaining('×24'), findsWidgets);
      expect(
        find.textContaining(AppStrings.t('base_unit', 'en')),
        findsWidgets,
      );
    });

    testWidgets('image picker still present (Phase 5 regression)',
        (tester) async {
      final dio = MockDio();
      await openEditDialog(tester, dio);
      expect(find.byKey(const Key('product-image-choose')), findsOneWidget);
      // No raw image_path text field
      expect(find.byType(TextField), findsWidgets);
      final labels = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((t) => t.decoration?.labelText)
          .whereType<String>()
          .toList();
      expect(labels, isNot(contains('image_path')));
    });
  });

  // ---------------------------------------------------------------------------
  // Product form — CREATE mode: child sections visible + staged rows
  // ---------------------------------------------------------------------------

  group('Product form CREATE mode children', () {
    Future<void> openCreateDialog(WidgetTester tester, MockDio dio) async {
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/categories': {
            'items': <dynamic>[],
            'total': 0,
            'page': 1,
            'page_size': 100,
            'pages': 1,
          },
        },
      );
      await pumpApp(
        tester,
        const MaterialApp(
          home: Scaffold(body: ProductFormDialog()),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
        'variant/selling/purchase sections visible in create mode '
        '(no productId)', (tester) async {
      final dio = MockDio();
      await openCreateDialog(tester, dio);

      expect(
        find.byKey(const Key('product-form-dialog')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('manage_variants', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('manage_selling_units', 'en')),
        findsOneWidget,
      );
      // Staged add buttons present but no edit-mode load/rows.
      expect(
        find.byKey(const Key('add-variant-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('add-selling-unit-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('add-purchase-unit-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('variant-row-var-1')), findsNothing);
    });

    testWidgets(
        'opening add-variant in create mode opens staged dialog '
        '(no productId required)', (tester) async {
      final dio = MockDio();
      await openCreateDialog(tester, dio);

      final addButton = find.byKey(const Key('add-variant-button'));
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton, warnIfMissed: true);
      await tester.pumpAndSettle();

      // Staged dialog must open (assert(staged || productId != null) holds).
      expect(
        find.byKey(const Key('variant-form-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);

      // Fill and submit staged variant → Map pops back, row appears.
      await tester.enterText(
        find.byKey(const Key('variant-name-field')),
        'Staged L',
      );
      await tester.tap(find.byKey(const Key('variant-form-submit')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('variant-form-dialog')),
        findsNothing,
      );
      expect(find.textContaining('Staged L'), findsOneWidget);
    });

    testWidgets(
        'selling unit model with null sellingPrice keeps null '
        '(does not become 0.000)', (tester) async {
      final u = SellingUnitModel.fromJson(
        _sellingUnitJson(sellingPrice: null),
      );
      expect(u.sellingPrice, isNull);
      // effectivePrice still comes from backend (product price inherit).
      expect(u.effectivePrice, '10');
    });
  });

  // ---------------------------------------------------------------------------
  // TASK 5 XOR — a product may have variants OR selling units, never both.
  // The add button of the other kind is disabled while the first kind has
  // any ACTIVE row (archived rows are history and never block).
  // ---------------------------------------------------------------------------

  group('TASK 5 XOR: add buttons disabled across kinds', () {
    Map<String, dynamic> archivedVariantJson() => {
          ..._variantJson(id: 'var-arch'),
          'is_archived': true,
          'archived_at': '2026-09-20T00:00:00Z',
        };

    Map<String, dynamic> archivedUnitJson() => {
          ..._sellingUnitJson(id: 'su-arch'),
          'is_archived': true,
          'archived_at': '2026-09-20T00:00:00Z',
        };

    Future<void> openEdit(
      WidgetTester tester,
      MockDio dio, {
      required List<Map<String, dynamic>> variants,
      required List<Map<String, dynamic>> units,
    }) async {
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/products/prod-1/variants': {
            'items': variants,
            'total': variants.length,
          },
          '/api/v1/products/prod-1/selling-units': {
            'items': units,
            'total': units.length,
          },
          '/api/v1/categories': {
            'items': <dynamic>[],
            'total': 0,
            'page': 1,
            'page_size': 100,
            'pages': 1,
          },
        },
      );
      await pumpApp(
        tester,
        MaterialApp(
          home: Scaffold(
            body:
                ProductFormDialog(product: ProductModel.fromJson(_productJson())),
          ),
        ),
        dio: dio,
      );
      await tester.pumpAndSettle();
    }

    Future<void> openCreate(WidgetTester tester, MockDio dio) async {
      stubRequests(
        dio,
        getBodies: {
          '/api/v1/categories': {
            'items': <dynamic>[],
            'total': 0,
            'page': 1,
            'page_size': 100,
            'pages': 1,
          },
        },
      );
      await pumpApp(
        tester,
        const MaterialApp(home: Scaffold(body: ProductFormDialog())),
        dio: dio,
      );
      await tester.pumpAndSettle();
    }

    bool buttonEnabled(WidgetTester tester, Key key) {
      final button = tester.widget<TextButton>(find.byKey(key));
      return button.onPressed != null;
    }

    testWidgets(
        'active units disable add-variant with localized hint (edit mode)',
        (tester) async {
      final dio = MockDio();
      await openEdit(
        tester,
        dio,
        variants: [],
        units: [
          _sellingUnitJson(
            id: 'su-base',
            name: 'Piece',
            multiplier: '1',
            isBaseUnit: true,
            sellingPrice: '10',
          ),
        ],
      );

      expect(buttonEnabled(tester, const Key('add-variant-button')), isFalse);
      expect(
        find.byKey(const Key('variants-locked-hint')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('variants_locked_by_units', 'en')),
        findsOneWidget,
      );
      // The units side is unaffected.
      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isTrue,
      );
      expect(find.byKey(const Key('selling-units-locked-hint')), findsNothing);
    });

    testWidgets(
        'active variants disable add-selling-unit with localized hint '
        '(edit mode)', (tester) async {
      final dio = MockDio();
      await openEdit(
        tester,
        dio,
        variants: [_variantJson()],
        units: [],
      );

      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isFalse,
      );
      expect(
        find.byKey(const Key('selling-units-locked-hint')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('units_locked_by_variants', 'en')),
        findsOneWidget,
      );
      expect(buttonEnabled(tester, const Key('add-variant-button')), isTrue);
      expect(find.byKey(const Key('variants-locked-hint')), findsNothing);
    });

    testWidgets(
        'archived-only rows never block the other kind (edit mode)',
        (tester) async {
      final dio = MockDio();
      await openEdit(
        tester,
        dio,
        variants: [archivedVariantJson()],
        units: [archivedUnitJson()],
      );

      // Archived units → variants add enabled.
      expect(buttonEnabled(tester, const Key('add-variant-button')), isTrue);
      // Archived variants → units add enabled.
      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isTrue,
      );
      expect(find.byKey(const Key('variants-locked-hint')), findsNothing);
      expect(find.byKey(const Key('selling-units-locked-hint')), findsNothing);
    });

    testWidgets('plain product keeps both add buttons enabled (edit mode)',
        (tester) async {
      final dio = MockDio();
      await openEdit(tester, dio, variants: [], units: []);

      expect(buttonEnabled(tester, const Key('add-variant-button')), isTrue);
      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isTrue,
      );
    });

    testWidgets(
        'CREATE mode: staged variant disables add-selling-unit, '
        'remove re-enables', (tester) async {
      final dio = MockDio();
      await openCreate(tester, dio);

      // Stage one variant.
      final addVariant = find.byKey(const Key('add-variant-button'));
      await tester.ensureVisible(addVariant);
      await tester.pumpAndSettle();
      await tester.tap(addVariant);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('variant-name-field')),
        'Staged L',
      );
      await tester.tap(find.byKey(const Key('variant-form-submit')));
      await tester.pumpAndSettle();

      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isFalse,
      );
      expect(
        find.byKey(const Key('selling-units-locked-hint')),
        findsOneWidget,
      );
      expect(buttonEnabled(tester, const Key('add-variant-button')), isTrue);

      // Remove the staged variant → both enabled again.
      final removeVariant = find.byKey(
        const Key('remove-staged-variant-staged-var-1'),
      );
      await tester.ensureVisible(removeVariant);
      await tester.pumpAndSettle();
      await tester.tap(removeVariant);
      await tester.pumpAndSettle();
      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isTrue,
      );
      expect(find.byKey(const Key('selling-units-locked-hint')), findsNothing);
    });

    testWidgets(
        'CREATE mode: staged selling unit disables add-variant, '
        'remove re-enables', (tester) async {
      final dio = MockDio();
      await openCreate(tester, dio);

      // Stage one selling unit.
      final addUnit = find.byKey(const Key('add-selling-unit-button'));
      await tester.ensureVisible(addUnit);
      await tester.pumpAndSettle();
      await tester.tap(addUnit);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('selling-unit-name-field')),
        'Staged Box',
      );
      await tester.enterText(
        find.byKey(const Key('selling-unit-multiplier-field')),
        '24',
      );
      await tester.tap(find.byKey(const Key('selling-unit-form-submit')));
      await tester.pumpAndSettle();

      expect(buttonEnabled(tester, const Key('add-variant-button')), isFalse);
      expect(find.byKey(const Key('variants-locked-hint')), findsOneWidget);
      expect(
        buttonEnabled(tester, const Key('add-selling-unit-button')),
        isTrue,
      );

      // Remove the staged unit → both enabled again.
      final removeUnit = find.byKey(
        const Key('remove-staged-selling-unit-staged-su-1'),
      );
      await tester.ensureVisible(removeUnit);
      await tester.pumpAndSettle();
      await tester.tap(removeUnit);
      await tester.pumpAndSettle();
      expect(buttonEnabled(tester, const Key('add-variant-button')), isTrue);
      expect(find.byKey(const Key('variants-locked-hint')), findsNothing);
    });

    test('XOR lock strings exist in ar/fr/en', () {
      for (final loc in ['ar', 'fr', 'en']) {
        for (final k in ['variants_locked_by_units', 'units_locked_by_variants']) {
          final value = AppStrings.t(k, loc);
          expect(value, isNotEmpty, reason: 'missing key $k in $loc');
          expect(value, isNot(k), reason: 'key $k not translated in $loc');
        }
      }
      // Arabic must differ from English (RTL translation present).
      expect(
        AppStrings.t('variants_locked_by_units', 'ar'),
        isNot(AppStrings.t('variants_locked_by_units', 'en')),
      );
      expect(
        AppStrings.t('units_locked_by_variants', 'ar'),
        isNot(AppStrings.t('units_locked_by_variants', 'en')),
      );
    });
  });
}
