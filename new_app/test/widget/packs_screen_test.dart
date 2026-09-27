// Phase 10 — Packs screen widget tests (list, permissions, archive).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/packs/packs_screen.dart';
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
const _packsPath = '/api/v1/packs';

Map<String, dynamic> _loginBody({List<String> scopes = const [
  'product_view',
  'product_create',
  'product_update',
  'product_archive',
]}) =>
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

Map<String, dynamic> _packJson({
  String id = '00000000-0000-0000-0000-0000000000k1',
  String name = 'Family Pack',
  String barcode = '777888999',
  String price = '250.0',
  int componentsCount = 3,
  String sumOfParts = '300.0',
  bool archived = false,
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'price': price,
      'is_active': !archived,
      'is_archived': archived,
      'archived_at': archived ? '2026-01-02T00:00:00Z' : null,
      'image_path': null,
      'components_count': componentsCount,
      'sum_of_parts': sumOfParts,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _packDetailJson() => {
      ..._packJson(),
      'sum_of_parts': '240',
      'estimated_cost': '240',
      'estimated_profit': '80',
      'estimated_margin_percent': '25',
      'components': [
        {
          'product_id': '00000000-0000-0000-0000-0000000000p1',
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
    };

Map<String, dynamic> _sellingUnitsBody() => {
      'items': [
        {
          'id': 'su-base',
          'product_id': '00000000-0000-0000-0000-0000000000p1',
          'name': 'Piece',
          'unit_type': 'piece',
          'multiplier': '1',
          'barcode': null,
          'selling_price': null,
          'is_base_unit': true,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-09-23T00:00:00Z',
          'updated_at': '2026-09-23T00:00:00Z',
        },
        {
          'id': 'su-box',
          'product_id': '00000000-0000-0000-0000-0000000000p1',
          'name': 'Box',
          'unit_type': 'piece',
          'multiplier': '24',
          'barcode': null,
          'selling_price': null,
          'is_base_unit': false,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-09-23T00:00:00Z',
          'updated_at': '2026-09-23T00:00:00Z',
        },
      ],
      'total': 2,
    };

Map<String, dynamic> _packsListBody({List<Map<String, dynamic>>? items}) => {
      'items': items ?? [_packJson()],
      'total': items?.length ?? 1,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: status,
    );

void stubRequests(
  MockDio dio, {
  Map<String, dynamic>? loginBody,
  Map<String, dynamic>? packsBody,
  Map<String, dynamic>? packDetailBody,
  Map<String, dynamic>? sellingUnitsBody,
  List<Map<String, dynamic>>? packQueryLog,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
    (_) async => _ok('/api/v1/auth/setup/check', {'setup_needed': false}),
  );
  when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
    (_) async => _ok('/api/v1/auth/login-users', {
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
    (_) async => _ok(_loginPath, loginBody ?? _loginBody()),
  );
  when(() => dio.post('/api/v1/auth/logout-token', data: any(named: 'data')))
      .thenAnswer(
    (_) async => _ok('/api/v1/auth/logout-token', {'message': 'logged out'}),
  );

  // Mocktail dispatches on the call shape (queryParameters present or not),
  // so the pack list, the pack detail and the selling-units lookup can all
  // be served from one pair of generic GET stubs.
  Object? bodyFor(String path, {Map<String, dynamic>? qp}) {
    if (path == '/api/v1/auth/setup/check') return {'setup_needed': false};
    if (path == '/api/v1/auth/login-users') {
      return {
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
      };
    }
    if (path == _packsPath) {
      if (packQueryLog != null && qp != null) {
        packQueryLog.add(Map<String, dynamic>.from(qp));
      }
      return packsBody ?? _packsListBody();
    }
    if (path == '$_packsPath/00000000-0000-0000-0000-0000000000k1') {
      return packDetailBody ?? _packDetailJson();
    }
    if (path.endsWith('/selling-units')) {
      return sellingUnitsBody ?? {'items': <dynamic>[], 'total': 0};
    }
    return packsBody ?? _packsListBody();
  }

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final qp =
        invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
    return _ok(path, bodyFor(path, qp: qp));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });

  when(() => dio.post(_packsPath, data: any(named: 'data'))).thenAnswer(
    (_) async => _ok(_packsPath, _packJson(), status: 201),
  );
  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (_) async => _ok(_packsPath, _packJson()),
  );
  when(() => dio.delete(any())).thenAnswer(
    (_) async => _ok(_packsPath, _packJson(archived: true)),
  );
}

Future<void> pumpApp(
  WidgetTester tester,
  MockDio dio, {
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

  await tester.tap(find.text('Admin'));
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final packsLabel = AppStrings.t('packs', 'ar');

  group('Packs screen (product scopes)', () {
    testWidgets('loads via GET /api/v1/packs and lists the pack row',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, packQueryLog: queryLog);

      await pumpApp(tester, dio, navLabel: packsLabel);

      expect(find.byType(PacksScreen), findsOneWidget);
      expect(find.byKey(const Key('packs-header-title')), findsOneWidget);
      expect(find.byKey(const Key('packs-list')), findsOneWidget);
      expect(find.text('Family Pack'), findsOneWidget);
      expect(
        find.byKey(
          const Key('pack-row-sum-00000000-0000-0000-0000-0000000000k1'),
        ),
        findsOneWidget,
      );
      expect(find.text('${AppStrings.t('total', 'ar')}: 1'), findsOneWidget);

      expect(queryLog, isNotEmpty);
      expect(queryLog.last['page'], 1);
      expect(queryLog.last['status'], 'active');
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty list shows the localized empty state', (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        packsBody: {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      );

      await pumpApp(tester, dio, navLabel: packsLabel);

      expect(find.byKey(const Key('packs-empty')), findsOneWidget);
      expect(find.text(AppStrings.t('no_packs', 'ar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('archive pack asks for confirmation then DELETEs',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio, navLabel: packsLabel);

      final archiveKey = find.byKey(
        const Key('pack-archive-00000000-0000-0000-0000-0000000000k1'),
      );
      await tester.ensureVisible(archiveKey);
      await tester.pumpAndSettle();
      await tester.tap(archiveKey);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('pack-archive-confirm')),
        findsOneWidget,
      );
      expect(
        find.textContaining(AppStrings.t('archive_pack_confirm', 'ar')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('pack-archive-confirm-button')));
      await tester.pumpAndSettle();

      verify(
        () => dio.delete(
          '$_packsPath/00000000-0000-0000-0000-0000000000k1',
        ),
      ).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('add pack dialog validates the required name', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio, navLabel: packsLabel);
      await tester.tap(find.byKey(const Key('packs-add-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pack-form-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pack-form-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pack-form-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('field_required', 'ar')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'edit fetches GET /packs/{id} and hydrates every component row '
        'by name with its pinned unit', (tester) async {
      final dio = MockDio();
      stubRequests(dio, sellingUnitsBody: _sellingUnitsBody());

      await pumpApp(tester, dio, navLabel: packsLabel);

      final editKey = find.byKey(
        const Key('pack-edit-00000000-0000-0000-0000-0000000000k1'),
      );
      await tester.ensureVisible(editKey);
      await tester.pumpAndSettle();
      await tester.tap(editKey);
      await tester.pumpAndSettle();

      // The list row has no components — the DETAIL endpoint provides them.
      verify(
        () => dio.get('$_packsPath/00000000-0000-0000-0000-0000000000k1'),
      ).called(1);
      expect(find.byKey(const Key('pack-form-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('pack-form-title')),
        findsOneWidget,
      );
      // Component row hydrated by NAME (not silently dropped).
      expect(find.text('Sugar'), findsOneWidget);
      expect(find.byKey(const Key('pack-component-row-0')), findsOneWidget);
      // Pinned selling unit + unit quantity.
      expect(find.text('Box \u00d724'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pack-component-qty-0')))
            .controller!
            .text,
        '2',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Packs permissions', () {
    testWidgets('user without product_view has no Packs destination',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio, loginBody: _loginBody(scopes: ['pos_sale']));

      await pumpApp(tester, dio);

      expect(find.text(packsLabel), findsNothing);
      expect(find.byType(PacksScreen), findsNothing);
      verifyNever(
        () => dio.get(
          _packsPath,
          queryParameters: any(named: 'queryParameters'),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('product_view without product_create shows no Add pack',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        loginBody: _loginBody(scopes: ['product_view']),
      );

      await pumpApp(tester, dio, navLabel: packsLabel);

      expect(find.byType(PacksScreen), findsOneWidget);
      expect(find.text('Family Pack'), findsOneWidget);
      expect(find.byKey(const Key('packs-add-button')), findsNothing);
      expect(
        find.byKey(
          const Key(
            'pack-edit-00000000-0000-0000-0000-0000000000k1',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'pack-archive-00000000-0000-0000-0000-0000000000k1',
          ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
