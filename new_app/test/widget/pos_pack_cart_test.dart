// Phase 10 — POS pack picker → cart integration widget tests.
//
// Covers: picker listing/search, the read-only availability pre-flight,
// the pack cart line (badge, unit summary, component snapshot) and the
// checkout payload shape (pack_id, never product_id — GATE 6).
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
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  String? _token;

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
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => const [];

  @override
  Future<List<String>> readUserPermissions() async => const [];

  @override
  Future<void> clearAll() async => _token = null;
}

const _packId = '00000000-0000-0000-0000-0000000000k1';
const _packsPath = '/api/v1/packs';
const _searchPath = '/api/v1/products/search';

const _scopes = <String>['pos_sale', 'product_view'];

Map<String, dynamic> _packJson() => {
      'id': _packId,
      'name': 'Family Pack',
      'barcode': '777888999',
      'price': '250.0',
      'is_active': true,
      'is_archived': false,
      'archived_at': null,
      'image_path': null,
      'components_count': 2,
      'sum_of_parts': '300.0',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'components': [
        {
          'product_id': '00000000-0000-0000-0000-0000000000p1',
          'product_name': 'Bread',
          'product_unit': 'piece',
          'product_price': '50',
          'quantity': '2',
        },
        {
          'product_id': '00000000-0000-0000-0000-0000000000p2',
          'product_name': 'Milk',
          'product_unit': 'liter',
          'product_price': '25',
          'quantity': '1',
        },
      ],
    };

Map<String, dynamic> _packsListBody() => {
      'items': [_packJson()],
      'total': 1,
      'page': 1,
      'page_size': 50,
      'pages': 1,
    };

Map<String, dynamic> _availabilityBody({
  bool saleable = true,
  String maxPacks = '3',
}) =>
    {
      'pack_id': _packId,
      'pack_name': 'Family Pack',
      'price': '250.0',
      'is_active': true,
      'is_archived': false,
      'quantity': '1',
      'saleable': saleable,
      'max_pack_quantity': maxPacks,
      'sum_of_parts': '300.0',
      'components': [
        {
          'product_id': '00000000-0000-0000-0000-0000000000p1',
          'product_name': 'Bread',
          'product_unit': 'piece',
          'required_per_pack': '2',
          'required_quantity': '2',
          'available_quantity': '6',
          'ok': true,
        },
      ],
      'errors': <String>[],
    };

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

Map<String, dynamic> _loginBody() => {
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
              for (final s in _scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

void _mockDio(
  MockDio dio, {
  Map<String, dynamic>? availabilityBody,
  bool availabilityError = false,
}) {
  Object? bodyFor(String path, {bool hasQuery = false}) {
    if (path == _searchPath) {
      return {
        'items': <dynamic>[],
        'total': 0,
      };
    }
    if (path == _packsPath) return _packsListBody();
    if (path.endsWith('/availability')) {
      if (availabilityError) {
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.connectionError,
        );
      }
      return availabilityBody ?? _availabilityBody();
    }
    if (path.endsWith('/variants') || path.endsWith('/selling-units')) {
      return {'items': <dynamic>[], 'total': 0};
    }
    return {'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path, hasQuery: true));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == '/api/v1/auth/setup/check') {
      return _ok(path, {'setup_needed': false});
    }
    return _ok(path, bodyFor(path));
  });

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', _loginBody()),
  );
  when(() => dio.post(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', _loginBody()),
  );
}

AuthUser _user() => AuthUser(
      id: '00000000-0000-0000-0000-0000000000b1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<ProviderContainer> _pumpPos(
  WidgetTester tester,
  MockDio dio,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
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
  await tester.pump(const Duration(milliseconds: 200));
  return ProviderScope.containerOf(tester.element(find.byType(PosScreen)));
}

Future<void> _openPickerAndAdd(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pos-packs-button')));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('pack-option-$_packId')));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('pack-picker-add')));
  await tester.pumpAndSettle();
}

void main() {
  group('POS pack picker', () {
    testWidgets('Packs button opens the picker with the active packs',
        (tester) async {
      final dio = MockDio();
      _mockDio(dio);
      await _pumpPos(tester, dio);

      expect(find.byKey(const Key('pos-packs-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pos-packs-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pack-picker')), findsOneWidget);
      expect(find.byKey(const Key('pack-option-$_packId')), findsOneWidget);
      expect(find.text('Family Pack'), findsOneWidget);
      expect(find.text('250.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'adding a pack puts ONE pack line in the cart with badge, unit '
        'summary and component snapshot', (tester) async {
      final dio = MockDio();
      _mockDio(dio);
      final container = await _pumpPos(tester, dio);

      await _openPickerAndAdd(tester);

      // Dialog closed after the availability pre-flight passed.
      expect(find.byKey(const Key('pack-picker')), findsNothing);

      final lines = container.read(posCartProvider).lines;
      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line.isPack, isTrue);
      expect(line.packId, _packId);
      expect(line.productId, isNull);
      expect(line.quantity, '1');
      expect(line.unitPrice, '250.0');
      expect(line.componentsSummary, contains('Bread'));

      // Cart tile: pack badge + component snapshot line.
      expect(
        find.byKey(Key('cart-line-pack-badge-pack:$_packId')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('cart-line-pack-components-pack:$_packId')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(
          find.descendant(
            of: find.byKey(Key('cart-line-pack-badge-pack:$_packId')),
            matching: find.byType(Text),
          ),
        ).data,
        AppStrings.t('pack_badge', 'en'),
      );

      // Checkout contract (GATE 6): pack_id only, no product_id.
      final saleJson = line.toSaleJson();
      expect(saleJson['pack_id'], _packId);
      expect(saleJson.containsKey('product_id'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('availability with saleable=false keeps the pack out of '
        'the cart', (tester) async {
      final dio = MockDio();
      _mockDio(dio, availabilityBody: _availabilityBody(saleable: false));
      final container = await _pumpPos(tester, dio);

      await _openPickerAndAdd(tester);

      expect(find.byKey(const Key('pack-picker')), findsOneWidget);
      expect(find.byKey(const Key('pack-picker-error-line')), findsOneWidget);
      expect(
        find.text(AppStrings.t('pack_not_saleable', 'en')),
        findsOneWidget,
      );
      expect(container.read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'max pack quantity below the requested quantity is rejected',
        (tester) async {
      final dio = MockDio();
      _mockDio(dio, availabilityBody: _availabilityBody(maxPacks: '0'));
      final container = await _pumpPos(tester, dio);

      await _openPickerAndAdd(tester);

      expect(find.byKey(const Key('pack-picker')), findsOneWidget);
      expect(
        find.text(AppStrings.t('pack_stock_insufficient', 'en')),
        findsOneWidget,
      );
      expect(container.read(posCartProvider).lines, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
