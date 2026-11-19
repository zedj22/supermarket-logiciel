// Packs in the POS catalog list.
//
// The catalog lists eligible packs AFTER the products, under the SAME search
// term, with a localized "Pack" badge. Selecting one runs the existing
// pack flow: read-only availability pre-flight, then ONE charged pack line
// (`pack_id`, never a fake product).
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

const _packId = 'pack-1';
const _packsPath = '/api/v1/packs';
const _catalogPath = '/api/v1/products';

const _scopes = <String>['pos_sale', 'product_view'];

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

Map<String, dynamic> _productJson() => <String, dynamic>{
      'id': 'p-1',
      'name': 'Milk Product',
      'barcode': null,
      'sku': null,
      'unit': 'piece',
      'price': '100',
      'cost': '50',
      'quantity': '10',
      'low_stock_threshold': '2',
      'is_archived': false,
    };

Map<String, dynamic> _packJson() => <String, dynamic>{
      'id': _packId,
      'name': 'Family Pack',
      'barcode': '777888999',
      'price': '250.0',
      'is_active': true,
      'is_archived': false,
      'components_count': 2,
      'sum_of_parts': '300.0',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'components': [
        {
          'product_id': 'p-1',
          'product_name': 'Bread',
          'product_unit': 'piece',
          'product_price': '50',
          'quantity': '2',
        },
      ],
    };

Map<String, dynamic> _availabilityBody({
  bool saleable = true,
  String maxPacks = '3',
}) =>
    <String, dynamic>{
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
          'product_id': 'p-1',
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

class _Api {
  final List<Map<String, dynamic>> packQueries = <Map<String, dynamic>>[];
}

void _mockDio(
  MockDio dio,
  _Api api, {
  bool saleable = true,
  String maxPacks = '3',
}) {
  Object? bodyFor(String path, Map<String, dynamic> query) {
    if (path == _catalogPath) {
      return <String, Object>{
        'items': <dynamic>[_productJson()],
        'total': 1,
      };
    }
    if (path == _packsPath) {
      api.packQueries.add(query);
      final search = '${query['search'] ?? ''}';
      // Name/barcode search: only the exact term resolves the pack.
      final matches = search.isEmpty || search == 'fam';
      return <String, Object>{
        'items': matches ? <dynamic>[_packJson()] : <dynamic>[],
        'total': matches ? 1 : 0,
        'page': 1,
        'page_size': 50,
        'pages': 1,
      };
    }
    if (path.endsWith('/availability')) {
      return _availabilityBody(saleable: saleable, maxPacks: maxPacks);
    }
    if (path.endsWith('/variants') || path.endsWith('/selling-units')) {
      return <String, Object>{'items': <dynamic>[], 'total': 0};
    }
    return <String, Object>{'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final query = Map<String, dynamic>.from(
      (invocation.namedArguments[#queryParameters] as Map?) ?? const {},
    );
    return _ok(path, bodyFor(path, query));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path, const {}));
  });
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => _ok(
      invocation.positionalArguments.first as String? ?? '',
      <String, dynamic>{},
    ),
  );
  when(() => dio.post(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', {}),
  );
}

AuthUser _user() => AuthUser(
      id: 'u-1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<ProviderContainer> _pumpPos(WidgetTester tester, MockDio dio) async {
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
  return ProviderScope.containerOf(
    tester.element(find.byKey(const Key('pos-screen'))),
    listen: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets('an eligible pack is listed beside products with a badge',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    await _pumpPos(tester, dio);

    expect(find.byKey(const Key('pos-product-p-1')), findsOneWidget);
    expect(find.byKey(const Key('pos-pack-$_packId')), findsOneWidget);
    expect(find.byKey(const Key('pos-pack-badge-$_packId')), findsOneWidget);
    expect(find.text('Family Pack'), findsOneWidget);
    // Localized badge (en) — the same label in ar/fr comes from the table.
    expect(
      find.descendant(
        of: find.byKey(const Key('pos-pack-badge-$_packId')),
        matching: find.text(AppStrings.t('pack', 'en')),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting the pack runs the availability pre-flight and adds '
      'ONE pack line (pack_id, never a product)', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    final container = await _pumpPos(tester, dio);

    await tester.tap(find.byKey(const Key('pos-pack-$_packId')));
    await tester.pumpAndSettle();

    final lines = container.read(posCartProvider).lines;
    expect(lines, hasLength(1));
    final line = lines.single;
    expect(line.isPack, isTrue);
    expect(line.packId, _packId);
    expect(line.productId, isNull, reason: 'no fake product is invented');
    expect(line.quantity, '1');
    expect(line.unitPrice, '250.0');
    expect(line.availableStock, '3');
    expect(line.componentsSummary, contains('Bread'));

    final payload = line.toSaleJson();
    expect(payload['pack_id'], _packId);
    expect(payload.containsKey('product_id'), isFalse);
  });

  testWidgets('pack search rides the catalog search term', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    await _pumpPos(tester, dio);
    expect(api.packQueries, isNotEmpty);

    await tester.enterText(find.byKey(const Key('pos-search-field')), 'fam');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(api.packQueries.last['search'], 'fam');
    expect(find.byKey(const Key('pos-pack-$_packId')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pos-search-field')), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(api.packQueries.last['search'], 'zzz');
    expect(find.byKey(const Key('pos-pack-$_packId')), findsNothing);
  });

  testWidgets('mixed cart: product + pack + custom item stay separate lines',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    final container = await _pumpPos(tester, dio);

    await tester.tap(find.byKey(const Key('pos-product-p-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pos-pack-$_packId')));
    await tester.pumpAndSettle();
    container
        .read(posCartProvider.notifier)
        .addCustomLine(name: 'Carrier bag', total: '5');
    await tester.pumpAndSettle();

    final lines = container.read(posCartProvider).lines;
    expect(lines, hasLength(3));
    expect(lines.where((l) => l.isPack), hasLength(1));
    expect(lines.where((l) => l.customLine), hasLength(1));
    expect(lines.where((l) => !l.isPack && !l.customLine), hasLength(1));
    expect(lines.map((l) => l.key).toSet(), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsellable pack is refused with the localized reason',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api, saleable: false);
    final container = await _pumpPos(tester, dio);

    await tester.tap(find.byKey(const Key('pos-pack-$_packId')));
    await tester.pumpAndSettle();

    expect(container.read(posCartProvider).lines, isEmpty);
    expect(
      find.text(AppStrings.t('pack_not_saleable', 'en')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('a pack with no available stock is refused', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api, maxPacks: '0');
    final container = await _pumpPos(tester, dio);

    await tester.tap(find.byKey(const Key('pos-pack-$_packId')));
    await tester.pumpAndSettle();

    expect(container.read(posCartProvider).lines, isEmpty);
    expect(
      find.text(AppStrings.t('pack_stock_insufficient', 'en')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 600));
  });
}
