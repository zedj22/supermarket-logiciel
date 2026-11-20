// Safe permanent deletion — variants, selling units, purchase units.
//
// Covers (TASK safe permanent deletion):
// - Delete action visibility (with / without product_archive permission)
// - Confirmation dialog: title, message, cancel + confirm buttons
// - Cancel fires NO delete request (no accidental deletion)
// - Confirm sends DELETE with permanent=true, list refreshes, success snack
// - Blocked deletion (409) shows the localized in-use message, row remains
// - ar/fr/en key presence for every new permanent-deletion string
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

const _allScopes = [
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
  'category_view',
  'category_manage',
];

const _loginPath = '/api/v1/auth/login';
const _setupCheckPath = '/api/v1/auth/setup/check';
const _mePath = '/api/v1/auth/me';

Map<String, dynamic> _authUserJson(List<String> scopes) => {
      'id': '00000000-0000-0000-0000-0000000000a1',
      'full_name': 'Admin',
      'is_active': true,
      'permissions': scopes,
      'roles': ['admin'],
    };

Map<String, dynamic> _loginBody(List<String> scopes) => {
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

Map<String, dynamic> _productJson() => {
      'id': 'prod-1',
      'name': 'Fromage Test',
      'barcode': '900000',
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': '10',
      'cost': '6',
      'quantity': '240',
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

Map<String, dynamic> _variantJson({String id = 'var-1', String name = 'Large'}) =>
    {
      'id': id,
      'product_id': 'prod-1',
      'name': name,
      'barcode': 'VAR$id',
      'sku': null,
      'price': '12',
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
}) =>
    {
      'id': id,
      'product_id': 'prod-1',
      'name': name,
      'unit_type': 'piece',
      'multiplier': '24',
      'barcode': 'BOX$id',
      'selling_price': '220',
      'is_base_unit': false,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-09-23T00:00:00Z',
      'updated_at': '2026-09-23T00:00:00Z',
      'available_base_qty': '240',
      'available_selling_qty': '10',
      'effective_price': '220',
    };

Map<String, dynamic> _purchaseUnitJson({
  String id = 'pu-1',
  String name = 'Carton',
}) =>
    {
      'id': id,
      'product_id': 'prod-1',
      'name': name,
      'unit_type': 'piece',
      'multiplier': '48',
      'barcode': 'PU$id',
      'is_default': true,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-09-23T00:00:00Z',
      'updated_at': '2026-09-23T00:00:00Z',
      'full_packages': '0',
      'base_equivalent_available': '0',
    };

/// Mutable in-memory backend double: GET lists reflect deletions, DELETE
/// invocations are recorded (with their `permanent` flag) and can be made
/// to fail with the backend's 409 blocked-deletion envelope.
class FakeBackend {
  FakeBackend(this.dio, {this.scopes = _allScopes});

  final MockDio dio;
  final List<String> scopes;
  final List<Map<String, String>> deleteCalls = [];
  List<Map<String, dynamic>> variants = [_variantJson()];
  List<Map<String, dynamic>> sellingUnits = [_sellingUnitJson()];
  List<Map<String, dynamic>> purchaseUnits = [_purchaseUnitJson()];
  bool failVariantDelete = false;
  bool failSellingUnitDelete = false;
  bool failPurchaseUnitDelete = false;

  Response<dynamic> _ok(String path, Object? data) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  Object? _get(String path) {
    if (path == _setupCheckPath) return {'setup_needed': false};
    if (path == _mePath) return _authUserJson(scopes);
    if (path.endsWith('/variants')) {
      return {'items': variants, 'total': variants.length};
    }
    if (path.endsWith('/selling-units')) {
      return {'items': sellingUnits, 'total': sellingUnits.length};
    }
    if (path.endsWith('/purchase-units')) {
      return {'items': purchaseUnits, 'total': purchaseUnits.length};
    }
    if (path == '/api/v1/categories') {
      return {
        'items': <dynamic>[],
        'total': 0,
        'page': 1,
        'page_size': 100,
        'pages': 1,
      };
    }
    return {'items': <dynamic>[], 'total': 0};
  }

  DioException _blocked(String path) => DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 409,
          data: {
            'error': {
              'code': 'CONFLICT',
              'message_key': 'errors.conflict',
              'message': 'Cannot permanently delete',
              'details': {'archive_recommended': true},
            },
          },
        ),
      );

  void stub() {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      return _ok(path, _get(path));
    });
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      return _ok(path, _get(path));
    });

    when(() => dio.delete(any(), queryParameters: any(named: 'queryParameters')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      final qp = invocation.namedArguments[#queryParameters]
          as Map<String, dynamic>?;
      deleteCalls.add({'path': path, 'permanent': '${qp?['permanent']}'});
      if (path.contains('/variants/')) {
        if (failVariantDelete) throw _blocked(path);
        variants = [];
      }
      if (path.contains('/selling-units/')) {
        if (failSellingUnitDelete) throw _blocked(path);
        sellingUnits = [];
      }
      if (path.contains('/purchase-units/')) {
        if (failPurchaseUnitDelete) throw _blocked(path);
        purchaseUnits = [];
      }
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 204,
        data: null,
      );
    });
    when(() => dio.delete(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      deleteCalls.add({'path': path, 'permanent': 'false'});
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: null,
      );
    });

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String? ?? '';
        if (path == _loginPath) return _ok(path, _loginBody(scopes));
        return _ok(path, {'valid': true, 'user': _authUserJson(scopes)});
      },
    );
    when(() => dio.post(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String? ?? '';
      return _ok(path, {'valid': true, 'user': _authUserJson(scopes)});
    });
  }
}

Future<void> pumpProductForm(
  WidgetTester tester,
  FakeBackend backend, {
  List<String> scopes = _allScopes,
}) async {
  final storage = FakeCredentialStorage();
  // Cold start never adopts a persisted session: state the signed-in user
  // (with the scopes under test) explicitly.
  final user = AuthUser(
    id: 'u-admin',
    fullName: 'Admin',
    isActive: true,
    roles: const ['admin'],
    permissions: scopes,
  );

  tester.view.physicalSize = const Size(1280, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: backend.dio)),
        credentialStorageProvider.overrideWithValue(storage),
        currentUserProvider.overrideWithValue(user),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ProductFormDialog(product: ProductModel.fromJson(_productJson())),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder, warnIfMissed: true);
  await tester.pumpAndSettle();
}

void main() {
  group('Delete action visibility', () {
    testWidgets('delete buttons visible for all three entity types',
        (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      expect(find.byKey(const Key('delete-variant-var-1')), findsOneWidget);
      expect(find.byKey(const Key('delete-selling-unit-su-1')), findsOneWidget);
      expect(find.byKey(const Key('delete-purchase-unit-pu-1')), findsOneWidget);
    });

    testWidgets('delete buttons hidden without product_archive permission',
        (tester) async {
      const limitedScopes = ['product_view', 'product_update'];
      final backend = FakeBackend(MockDio(), scopes: limitedScopes)..stub();
      await pumpProductForm(tester, backend, scopes: limitedScopes);

      expect(find.byKey(const Key('delete-variant-var-1')), findsNothing);
      expect(find.byKey(const Key('delete-selling-unit-su-1')), findsNothing);
      expect(find.byKey(const Key('delete-purchase-unit-pu-1')), findsNothing);
    });
  });

  group('Variant permanent delete', () {
    testWidgets('confirmation dialog shows title, message and both actions',
        (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-variant-var-1'));

      expect(
        find.text(AppStrings.t('delete_permanently_confirm_title', 'en')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('permanent-delete-confirm-message')),
        findsOneWidget,
      );
      expect(
        find.text(
          AppStrings.t('delete_permanently_confirm_message', 'en'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('permanent-delete-cancel')), findsOneWidget);
      expect(find.byKey(const Key('confirm-delete-variant')), findsOneWidget);
    });

    testWidgets('cancel fires no delete request and keeps the row',
        (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-variant-var-1'));
      await _tapKey(tester, const Key('permanent-delete-cancel'));

      expect(backend.deleteCalls, isEmpty);
      expect(find.byKey(const Key('variant-row-var-1')), findsOneWidget);
      expect(find.byKey(const Key('permanent-delete-confirm-message')),
          findsNothing);
    });

    testWidgets(
        'confirm sends DELETE with permanent=true, refreshes the list '
        'and shows the success snack', (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-variant-var-1'));
      await _tapKey(tester, const Key('confirm-delete-variant'));

      expect(backend.deleteCalls, hasLength(1));
      expect(backend.deleteCalls.single['path'],
          '/api/v1/products/prod-1/variants/var-1');
      expect(backend.deleteCalls.single['permanent'], 'true');
      // List refreshed without the deleted record.
      expect(find.byKey(const Key('variant-row-var-1')), findsNothing);
      // Success notification via the existing snackbar pattern.
      expect(
        find.text(AppStrings.t('variant_deleted', 'en')),
        findsOneWidget,
      );
    });

    testWidgets(
        'blocked deletion (409) shows the localized in-use message '
        'and keeps the record visible', (tester) async {
      final backend = FakeBackend(MockDio())
        ..failVariantDelete = true
        ..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-variant-var-1'));
      await _tapKey(tester, const Key('confirm-delete-variant'));

      expect(backend.deleteCalls, hasLength(1));
      expect(
        find.byKey(const Key('product-form-error')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('delete_blocked_in_use', 'en')),
        findsOneWidget,
      );
      // Surrounding screen intact — record still listed.
      expect(find.byKey(const Key('variant-row-var-1')), findsOneWidget);
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
    });
  });

  group('Selling unit permanent delete', () {
    testWidgets('confirm deletes, refreshes and shows success snack',
        (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-selling-unit-su-1'));
      await _tapKey(tester, const Key('confirm-delete-selling-unit'));

      expect(backend.deleteCalls, hasLength(1));
      expect(backend.deleteCalls.single['path'],
          '/api/v1/products/prod-1/selling-units/su-1');
      expect(backend.deleteCalls.single['permanent'], 'true');
      expect(find.byKey(const Key('selling-unit-row-su-1')), findsNothing);
      expect(
        find.text(AppStrings.t('selling_unit_deleted', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('cancel fires no delete request', (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-selling-unit-su-1'));
      await _tapKey(tester, const Key('permanent-delete-cancel'));

      expect(backend.deleteCalls, isEmpty);
      expect(find.byKey(const Key('selling-unit-row-su-1')), findsOneWidget);
    });

    testWidgets('blocked deletion shows the localized in-use message',
        (tester) async {
      final backend = FakeBackend(MockDio())
        ..failSellingUnitDelete = true
        ..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-selling-unit-su-1'));
      await _tapKey(tester, const Key('confirm-delete-selling-unit'));

      expect(
        find.text(AppStrings.t('delete_blocked_in_use', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('selling-unit-row-su-1')), findsOneWidget);
    });
  });

  group('Purchase unit permanent delete', () {
    testWidgets('confirm deletes, refreshes and shows success snack',
        (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-purchase-unit-pu-1'));
      await _tapKey(tester, const Key('confirm-delete-purchase-unit'));

      expect(backend.deleteCalls, hasLength(1));
      expect(backend.deleteCalls.single['path'],
          '/api/v1/products/prod-1/purchase-units/pu-1');
      expect(backend.deleteCalls.single['permanent'], 'true');
      expect(find.byKey(const Key('purchase-unit-row-pu-1')), findsNothing);
      expect(
        find.text(AppStrings.t('purchase_unit_deleted', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('cancel fires no delete request', (tester) async {
      final backend = FakeBackend(MockDio())..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-purchase-unit-pu-1'));
      await _tapKey(tester, const Key('permanent-delete-cancel'));

      expect(backend.deleteCalls, isEmpty);
      expect(find.byKey(const Key('purchase-unit-row-pu-1')), findsOneWidget);
    });

    testWidgets('blocked deletion shows the localized in-use message',
        (tester) async {
      final backend = FakeBackend(MockDio())
        ..failPurchaseUnitDelete = true
        ..stub();
      await pumpProductForm(tester, backend);

      await _tapKey(tester, const Key('delete-purchase-unit-pu-1'));
      await _tapKey(tester, const Key('confirm-delete-purchase-unit'));

      expect(
        find.text(AppStrings.t('delete_blocked_in_use', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('purchase-unit-row-pu-1')), findsOneWidget);
    });
  });

  group('Permanent deletion i18n keys (ar/fr/en)', () {
    const keys = [
      'delete_variant',
      'delete_selling_unit',
      'delete_purchase_unit',
      'delete_permanently',
      'delete_permanently_confirm_title',
      'delete_permanently_confirm_message',
      'variant_deleted',
      'selling_unit_deleted',
      'purchase_unit_deleted',
      'delete_blocked_in_use',
    ];

    for (final loc in ['ar', 'fr', 'en']) {
      test('all keys present, non-empty and translated in $loc', () {
        for (final k in keys) {
          final value = AppStrings.t(k, loc);
          expect(value, isNotEmpty, reason: 'missing key $k in $loc');
          expect(value, isNot(k), reason: 'key $k not translated in $loc');
        }
      });
    }

    test('Arabic values are genuine RTL translations', () {
      expect(
        AppStrings.t('delete_permanently', 'ar'),
        isNot(AppStrings.t('delete_permanently', 'en')),
      );
      expect(
        AppStrings.t('delete_blocked_in_use', 'ar'),
        isNot(AppStrings.t('delete_blocked_in_use', 'en')),
      );
      expect(
        AppStrings.t('delete_permanently_confirm_title', 'ar'),
        contains('؟'),
      );
    });
  });
}
