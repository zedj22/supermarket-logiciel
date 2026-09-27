// Phase 10 fix round — pack form unit selector, conversion preview,
// live profitability estimate, edit hydration and detail conversion.
//
// Covers (spec, PACK UX / DOMAIN FIX ROUND):
// - Issue 1: a component may pin one of the product's Phase 6 selling units
//   and the entered quantity is then expressed in that unit (2 Box = 48
//   base units), sent as `selling_unit_id` + quantity-in-unit.
// - Issue 2: informational cost / profit / margin preview from the live
//   `avg_cost` (PMP) — recomputes on price, quantity and unit changes and
//   never divides by a zero price.
// - Issue 3: the edit dialog hydrates components BY NAME with their pinned
//   unit and their unit quantity (no silent row loss).
// - The detail dialog spells out the stored conversion per component.
// - ar / fr / en labels + RTL rendering for the new preview.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/packs/pack_detail_dialog.dart';
import 'package:supermarket_pos/features/packs/pack_form_dialog.dart';
import 'package:supermarket_pos/features/packs/pack_models.dart';
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

const _packsPath = '/api/v1/packs';
const _searchPath = '/api/v1/products/search';
const _prod1 = 'prod-1';

Map<String, dynamic> _productJson({
  String id = _prod1,
  String name = 'Sugar',
  String unit = 'piece',
  String price = '10',
  String avgCost = '5',
}) => {
  'id': id,
  'name': name,
  'barcode': null,
  'sku': null,
  'description': null,
  'unit': unit,
  'price': price,
  'cost': '6',
  'avg_cost': avgCost,
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

Map<String, dynamic> _unitJson({
  String id = 'su-box',
  String name = 'Box',
  String multiplier = '24',
  bool isBaseUnit = false,
  bool isArchived = false,
  String productId = _prod1,
}) => {
  'id': id,
  'product_id': productId,
  'name': name,
  'unit_type': 'piece',
  'multiplier': multiplier,
  'barcode': null,
  'selling_price': null,
  'is_base_unit': isBaseUnit,
  'is_archived': isArchived,
  'archived_at': null,
  'created_at': '2026-09-23T00:00:00Z',
  'updated_at': '2026-09-23T00:00:00Z',
  'available_base_qty': '240',
  'available_selling_qty': null,
  'effective_price': null,
};

/// Piece ×1 (base) + Box ×24 — the Phase 6 catalog for `prod-1`.
List<dynamic> _unitsBody({bool withBox = true}) => [
  _unitJson(id: 'su-base', name: 'Piece', multiplier: '1', isBaseUnit: true),
  if (withBox) _unitJson(),
];

Map<String, dynamic> _packJson({
  List<Map<String, dynamic>>? components,
  String price = '320',
  String estimatedCost = '240',
  String estimatedProfit = '80',
  String estimatedMargin = '25',
}) => {
  'id': 'pack-1',
  'name': 'Family Pack',
  'barcode': '777888999',
  'price': price,
  'is_active': true,
  'is_archived': false,
  'archived_at': null,
  'image_path': null,
  'components_count': components?.length ?? 0,
  'sum_of_parts': '240',
  'estimated_cost': estimatedCost,
  'estimated_profit': estimatedProfit,
  'estimated_margin_percent': estimatedMargin,
  'components': components ?? const [],
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
};

Map<String, dynamic> _packsListBody() => {
  'items': [_packJson()],
  'total': 1,
  'page': 1,
  'page_size': 40,
  'pages': 1,
};

Map<String, dynamic> _availabilityJson() => {
  'pack_id': 'pack-1',
  'pack_name': 'Family Pack',
  'price': '320',
  'is_active': true,
  'is_archived': false,
  'quantity': '1',
  'saleable': true,
  'max_pack_quantity': '4',
  'sum_of_parts': '240',
  'components': [
    {
      'product_id': _prod1,
      'product_name': 'Sugar',
      'product_unit': 'piece',
      'required_per_pack': '48',
      'required_quantity': '48',
      'available_quantity': '240',
      'ok': true,
      'selling_unit_id': 'su-box',
      'selling_unit_name': 'Box',
      'selling_unit_multiplier': '24',
      'unit_quantity': '2',
      'required_unit_quantity': '2',
    },
  ],
  'errors': <dynamic>[],
};

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: status,
    );

/// Mocktail last-match-wins per call shape, so both GET forms are stubbed
/// and dispatched on the path (search / selling-units / detail / list).
void _mockDio(
  MockDio dio, {
  Map<String, Map<String, dynamic>>? getBodies,
  Map<String, dynamic>? packsList,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  Object? bodyFor(String path) {
    final override = getBodies?[path];
    if (override != null) return override;
    if (path == _packsPath) return packsList ?? _packsListBody();
    if (path == '/api/v1/auth/setup/check') return {'setup_needed': false};
    if (path == _searchPath) return {'items': <dynamic>[], 'total': 0};
    return {'items': <dynamic>[], 'total': 0};
  }

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => _ok(
      invocation.positionalArguments.first as String? ?? '',
      _packJson(),
      status: 201,
    ),
  );
  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', _packJson()),
  );
  when(() => dio.delete(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', _packJson()),
  );
}

/// Host with two launcher buttons: the create/edit form and the detail
/// dialog. English locale by default so on-screen text == AppStrings en.
///
/// The MaterialApp mirrors the real app (same delegates + supported
/// locales), so `AppLocale.ar` also drives the ROUTE-level directionality —
/// dialogs pushed by `showDialog` inherit it too.
Future<void> _pumpHost(
  WidgetTester tester,
  MockDio dio, {
  AppLocale locale = AppLocale.en,
  PackModel? editPack,
  Size size = const Size(1600, 1000),
}) async {
  final storage = FakeCredentialStorage();
  await storage.saveToken('tok');
  await storage.saveUserPermissions(const ['product_view', 'product_update']);
  await storage.saveUserRoles(const ['admin']);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(storage),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open-form'),
                    onPressed: () => showPackFormDialog(context),
                    child: const Text('form'),
                  ),
                ),
                Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open-form-edit'),
                    onPressed: () => showPackFormDialog(
                      context,
                      pack: editPack ?? _editPack(),
                    ),
                    child: const Text('edit'),
                  ),
                ),
                Builder(
                  builder: (context) => ElevatedButton(
                    key: const Key('open-detail'),
                    onPressed: () => showPackDetailDialog(
                      context,
                      pack: editPack ?? _editPack(),
                    ),
                    child: const Text('detail'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Detail payload used for hydration / detail tests: Sugar pinned to
/// Box ×24, entered quantity 2 (= 48 base units), live PMP 5.
PackModel _editPack() => PackModel.fromJson(
  _packJson(
    components: [
      {
        'product_id': _prod1,
        'product_name': 'Sugar',
        'product_unit': 'piece',
        'product_price': '10',
        'quantity': '48',
        'selling_unit_id': 'su-box',
        'selling_unit_name': 'Box',
        'selling_unit_multiplier': '24',
        'unit_quantity': '2',
        'base_quantity': '48',
        'avg_cost': '5',
      },
    ],
  ),
);

Future<void> _openCreateForm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-form')));
  await tester.pumpAndSettle();
}

/// Product picker -> pick Sugar -> component row (then units load).
Future<void> _addComponent(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pack-add-component')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('pack-product-option-$_prod1')));
  await tester.pumpAndSettle();
}

Future<void> _selectUnit(
  WidgetTester tester, {
  required int index,
  required String optionKey,
}) async {
  await tester.tap(find.byKey(Key('pack-component-unit-$index')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(optionKey)));
  await tester.pumpAndSettle();
}

String _qtyText(WidgetTester tester, int index) => tester
    .widget<TextField>(find.byKey(Key('pack-component-qty-$index')))
    .controller!
    .text;

String _estimate(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data ?? '';

void main() {
  group('Pack form — selling unit selector (Issue 1)', () {
    testWidgets('a component with selling units offers base + Box options', (
      tester,
    ) async {
      final dio = MockDio();
      _mockDio(
        dio,
        getBodies: {
          _searchPath: {
            'items': [_productJson()],
            'total': 1,
          },
          '/api/v1/products/$_prod1/selling-units': {
            'items': _unitsBody(),
            'total': 2,
          },
        },
      );
      await _pumpHost(tester, dio);
      await _openCreateForm(tester);
      await _addComponent(tester);

      expect(find.byKey(const Key('pack-component-unit-0')), findsOneWidget);
      // Options only exist while the menu is open.
      await tester.tap(find.byKey(const Key('pack-component-unit-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('pack-component-unit-option-su-base-0')),
        findsWidgets, // selected option: shown in the button AND the menu
      );
      expect(
        find.byKey(const Key('pack-component-unit-option-su-box-0')),
        findsOneWidget,
      );
      // Base unit is preselected (legacy-safe default) — dismiss the menu
      // by tapping its barrier instead of re-selecting an option (the
      // selected option is rendered twice: button + menu).
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Piece \u00d71'), findsOneWidget);
      // multiplier == 1 → no conversion line yet.
      expect(find.byKey(const Key('pack-component-preview-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'selecting Box previews the exact base conversion (2 Box = 48)',
      (tester) async {
        final dio = MockDio();
        _mockDio(
          dio,
          getBodies: {
            _searchPath: {
              'items': [_productJson()],
              'total': 1,
            },
            '/api/v1/products/$_prod1/selling-units': {
              'items': _unitsBody(),
              'total': 2,
            },
          },
        );
        await _pumpHost(tester, dio);
        await _openCreateForm(tester);
        await _addComponent(tester);

        await _selectUnit(
          tester,
          index: 0,
          optionKey: 'pack-component-unit-option-su-box-0',
        );
        await tester.enterText(
          find.byKey(const Key('pack-component-qty-0')),
          '2',
        );
        await tester.pump();

        expect(find.text('Box \u00d724'), findsOneWidget);
        expect(
          find.byKey(const Key('pack-component-preview-0')),
          findsOneWidget,
        );
        expect(find.text('2 Box = 48 piece'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'submit sends selling_unit_id with the quantity expressed in that '
      'unit (never the base conversion)',
      (tester) async {
        final dio = MockDio();
        _mockDio(
          dio,
          getBodies: {
            _searchPath: {
              'items': [_productJson()],
              'total': 1,
            },
            '/api/v1/products/$_prod1/selling-units': {
              'items': _unitsBody(),
              'total': 2,
            },
          },
        );
        await _pumpHost(tester, dio);
        await _openCreateForm(tester);
        await _addComponent(tester);
        await _selectUnit(
          tester,
          index: 0,
          optionKey: 'pack-component-unit-option-su-box-0',
        );
        await tester.enterText(
          find.byKey(const Key('pack-component-qty-0')),
          '2',
        );
        await tester.enterText(
          find.byKey(const Key('pack-name-field')),
          'Pack',
        );
        await tester.enterText(
          find.byKey(const Key('pack-price-field')),
          '320',
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('pack-form-submit')));
        await tester.pumpAndSettle();

        final captured = verify(
          () => dio.post(_packsPath, data: captureAny(named: 'data')),
        ).captured;
        final payload = Map<String, dynamic>.from(captured.single as Map);
        final component = Map<String, dynamic>.from(
          (payload['components'] as List).single as Map<String, dynamic>,
        );
        expect(payload['name'], 'Pack');
        expect(component['product_id'], _prod1);
        expect(component['selling_unit_id'], 'su-box');
        expect(component['quantity'], '2');
        expect(find.byKey(const Key('pack-form-dialog')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a product without selling units only shows its base unit', (
      tester,
    ) async {
      final dio = MockDio();
      _mockDio(
        dio,
        getBodies: {
          _searchPath: {
            'items': [_productJson()],
            'total': 1,
          },
          '/api/v1/products/$_prod1/selling-units': {
            'items': <dynamic>[],
            'total': 0,
          },
        },
      );
      await _pumpHost(tester, dio);
      await _openCreateForm(tester);
      await _addComponent(tester);

      // Static base-unit label, no dropdown, no conversion preview.
      expect(find.text('piece'), findsOneWidget);
      expect(tester.widgetList(find.byType(DropdownButton<String?>)), isEmpty);
      expect(find.byKey(const Key('pack-component-preview-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Pack form — live profitability preview (Issue 2)', () {
    Future<void> openWithBoxComponent(WidgetTester tester) async {
      final dio = MockDio();
      _mockDio(
        dio,
        getBodies: {
          _searchPath: {
            'items': [_productJson()],
            'total': 1,
          },
          '/api/v1/products/$_prod1/selling-units': {
            'items': _unitsBody(),
            'total': 2,
          },
        },
      );
      await _pumpHost(tester, dio);
      await _openCreateForm(tester);
      await _addComponent(tester);
      await _selectUnit(
        tester,
        index: 0,
        optionKey: 'pack-component-unit-option-su-box-0',
      );
      await tester.enterText(
        find.byKey(const Key('pack-component-qty-0')),
        '2',
      );
      await tester.pump();
    }

    testWidgets('estimate recomputes on price, quantity and unit changes '
        '(avg_cost PMP only)', (tester) async {
      await openWithBoxComponent(tester);

      // 2 Box ×24 = 48 base × avg_cost 5 → cost 240.
      expect(_estimate(tester, 'pack-estimated-cost'), '240');
      expect(find.byKey(const Key('pack-estimated-margin')), findsNothing);

      await tester.enterText(find.byKey(const Key('pack-price-field')), '320');
      await tester.pump();
      expect(_estimate(tester, 'pack-estimated-cost'), '240');
      expect(_estimate(tester, 'pack-estimated-profit'), '80');
      expect(_estimate(tester, 'pack-estimated-margin'), '25%');

      // Quantity is expressed in the SELECTED unit: 1 Box = 24 → cost 120.
      await tester.enterText(
        find.byKey(const Key('pack-component-qty-0')),
        '1',
      );
      await tester.pump();
      expect(_estimate(tester, 'pack-estimated-cost'), '120');
      expect(_estimate(tester, 'pack-estimated-profit'), '200');
      expect(_estimate(tester, 'pack-estimated-margin'), '62.5%');

      // Back to the base unit: 1 piece × avg_cost 5 → cost 5.
      await _selectUnit(
        tester,
        index: 0,
        optionKey: 'pack-component-unit-option-su-base-0',
      );
      expect(_estimate(tester, 'pack-estimated-cost'), '5');
      expect(find.byKey(const Key('pack-component-preview-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero price hides the margin row (never divide by zero)', (
      tester,
    ) async {
      await openWithBoxComponent(tester);
      await tester.enterText(find.byKey(const Key('pack-price-field')), '0');
      await tester.pump();

      expect(find.byKey(const Key('pack-estimated-margin')), findsNothing);
      expect(
        find.byKey(const Key('pack-estimated-margin-label')),
        findsNothing,
      );
      expect(_estimate(tester, 'pack-estimated-profit'), '-240');
      expect(find.byKey(const Key('pack-estimate-note')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'priced components report a real margin - never the buggy 100%',
      (tester) async {
        final dio = MockDio();
        _mockDio(
          dio,
          getBodies: {
            _searchPath: {
              'items': [
                _productJson(id: 'prod-1', name: 'A', avgCost: '240'),
                _productJson(id: 'prod-2', name: 'B', avgCost: '180'),
              ],
              'total': 2,
            },
          },
        );
        await _pumpHost(tester, dio);
        await _openCreateForm(tester);

        for (final productId in const ['prod-1', 'prod-2']) {
          await tester.tap(find.byKey(const Key('pack-add-component')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key('pack-product-option-$productId')));
          await tester.pumpAndSettle();
        }

        await tester.enterText(
          find.byKey(const Key('pack-price-field')),
          '500',
        );
        await tester.pump();

        // 240 x1 + 180 x1 = 420 of PMP cost -> profit 80 -> margin 16%.
        expect(_estimate(tester, 'pack-estimated-cost'), '420');
        expect(_estimate(tester, 'pack-estimated-profit'), '80');
        expect(_estimate(tester, 'pack-estimated-margin'), '16%');
        expect(_estimate(tester, 'pack-estimated-margin'), isNot('100%'));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Pack form — edit hydration (Issue 3)', () {
    Future<void> openEdit(WidgetTester tester) async {
      final dio = MockDio();
      _mockDio(
        dio,
        getBodies: {
          '/api/v1/products/$_prod1/selling-units': {
            'items': _unitsBody(),
            'total': 2,
          },
        },
      );
      await _pumpHost(tester, dio);
      await tester.tap(find.byKey(const Key('open-form-edit')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'components hydrate by name with their pinned unit and unit quantity',
      (tester) async {
        await openEdit(tester);

        // The component row exists and names the product.
        expect(find.byKey(const Key('pack-component-row-0')), findsOneWidget);
        expect(find.text('Sugar'), findsOneWidget);
        // The pinned unit is selected and the quantity is the UNIT quantity.
        expect(find.text('Box \u00d724'), findsOneWidget);
        expect(_qtyText(tester, 0), '2');
        expect(find.text('2 Box = 48 piece'), findsOneWidget);
        // Static estimate from the detail response.
        expect(_estimate(tester, 'pack-estimated-cost'), '240');
        expect(_estimate(tester, 'pack-estimated-profit'), '80');
        expect(_estimate(tester, 'pack-estimated-margin'), '25%');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'saving an untouched edit keeps the pinned unit and its unit quantity',
      (tester) async {
        final dio = MockDio();
        _mockDio(
          dio,
          getBodies: {
            '/api/v1/products/$_prod1/selling-units': {
              'items': _unitsBody(),
              'total': 2,
            },
          },
        );
        await _pumpHost(tester, dio);
        await tester.tap(find.byKey(const Key('open-form-edit')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('pack-form-submit')));
        await tester.pumpAndSettle();

        final captured = verify(
          () => dio.put('$_packsPath/pack-1', data: captureAny(named: 'data')),
        ).captured;
        final payload = Map<String, dynamic>.from(captured.single as Map);
        final component = Map<String, dynamic>.from(
          (payload['components'] as List).single as Map<String, dynamic>,
        );
        expect(payload['name'], 'Family Pack');
        expect(component['product_id'], _prod1);
        expect(component['selling_unit_id'], 'su-box');
        expect(component['quantity'], '2');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a legacy component (no unit identity) hydrates its BASE quantity '
      'and still sends a null selling_unit_id',
      (tester) async {
        final dio = MockDio();
        _mockDio(
          dio,
          getBodies: {
            '/api/v1/products/$_prod1/selling-units': {
              'items': _unitsBody(),
              'total': 2,
            },
          },
        );
        await _pumpHost(
          tester,
          dio,
          editPack: PackModel.fromJson(
            _packJson(
              components: [
                {
                  'product_id': _prod1,
                  'product_name': 'Sugar',
                  'product_unit': 'piece',
                  'product_price': '10',
                  'quantity': '48',
                  'avg_cost': '5',
                },
              ],
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open-form-edit')));
        await tester.pumpAndSettle();

        expect(find.text('Sugar'), findsOneWidget);
        // Base unit (multiplier 1) selected → quantity stays in base units.
        expect(find.text('Piece \u00d71'), findsOneWidget);
        expect(_qtyText(tester, 0), '48');
        expect(find.byKey(const Key('pack-component-preview-0')), findsNothing);

        await tester.tap(find.byKey(const Key('pack-form-submit')));
        await tester.pumpAndSettle();

        final captured = verify(
          () => dio.put('$_packsPath/pack-1', data: captureAny(named: 'data')),
        ).captured;
        final payload = Map<String, dynamic>.from(captured.single as Map);
        final component = Map<String, dynamic>.from(
          (payload['components'] as List).single as Map<String, dynamic>,
        );
        expect(component['selling_unit_id'], isNull);
        expect(component['quantity'], '48');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Pack detail dialog', () {
    testWidgets('shows the stored unit conversion per component', (
      tester,
    ) async {
      final dio = MockDio();
      _mockDio(
        dio,
        getBodies: {
          '$_packsPath/pack-1/availability': _availabilityJson(),
          '/api/v1/products/$_prod1/selling-units': {
            'items': _unitsBody(),
            'total': 2,
          },
        },
      );
      await _pumpHost(tester, dio);
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pack-detail-dialog')), findsOneWidget);
      // Static estimate from the detail payload.
      expect(find.byKey(const Key('pack-detail-estimate')), findsOneWidget);
      expect(
        find.byKey(const Key('pack-detail-estimate-note')),
        findsOneWidget,
      );
      // Component row: base columns + the pinned-unit conversion line.
      expect(find.text('Sugar'), findsOneWidget);
      expect(find.text('2 Box = 48 piece'), findsOneWidget);
      expect(
        find.byKey(const Key('pack-availability-component-unit-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Localization / RTL (fix round)', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      testWidgets('estimate labels resolve in $locale', (tester) async {
        final code = locale.name;
        final dio = MockDio();
        _mockDio(dio);
        await _pumpHost(tester, dio, locale: locale);
        await _openCreateForm(tester);

        expect(find.text(AppStrings.t('estimated_cost', code)), findsOneWidget);
        expect(
          find.text(AppStrings.t('estimated_profit', code)),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('estimate_pmp_note', code)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the form renders right-to-left in Arabic without exceptions', (
      tester,
    ) async {
      final dio = MockDio();
      _mockDio(dio);
      await _pumpHost(tester, dio, locale: AppLocale.ar);
      await _openCreateForm(tester);

      expect(find.byKey(const Key('pack-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('pack-estimate')), findsOneWidget);
      expect(find.text(AppStrings.t('estimated_cost', 'ar')), findsOneWidget);
      expect(
        tester
            .widget<Directionality>(
              find
                  .ancestor(
                    of: find.byKey(const Key('pack-form-dialog')),
                    matching: find.byType(Directionality),
                  )
                  .first,
            )
            .textDirection,
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
