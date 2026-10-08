// Phase 18 — Promotions screen widget tests (list, filters, create,
// toggle, RBAC).
//
// Harness rules from expenses_screen_test.dart: catch-all GET stubs first,
// specific auth GET stubs LAST, ONE universal POST stub dispatched on
// path. Money is asserted exactly as the server sent it — the client
// never rederives a promotional price.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/promotions/promotions_providers.dart';
import 'package:supermarket_pos/features/promotions/promotions_screen.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

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
const _promotionsPath = '/api/v1/promotions';
const _togglePath = '/api/v1/promotions/promo-1/toggle';

const _promotionScopes = [
  'promotion_view',
  'promotion_create',
  'promotion_update',
];

Map<String, dynamic> _loginBody({
  List<String> scopes = _promotionScopes,
  String roleName = 'manager',
}) =>
    {
      'access_token': 'tok-$roleName',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': 'Admin',
        'is_active': true,
        'roles': [
          {
            'name': roleName,
            'permissions': [
              for (final s in scopes)
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _promotionJson({
  String id = 'promo-1',
  String name = 'Ramadan sale',
  String type = 'percentage',
  String value = '20.000',
  bool isActive = true,
  int productCount = 2,
  bool idempotentReplay = false,
}) =>
    {
      'id': id,
      'name': name,
      'promotion_type': type,
      'value': value,
      'is_active': isActive,
      'products': [
        for (var i = 0; i < productCount; i++)
          {'id': 'p$i', 'name': 'Product $i'},
      ],
      'product_ids': [for (var i = 0; i < productCount; i++) 'p$i'],
      'product_count': productCount,
      'client_request_id': 'req-$id',
      'created_at': '2026-10-01T10:00:00Z',
      'updated_at': '2026-10-01T10:00:00Z',
      'idempotent_replay': idempotentReplay,
    };

Map<String, dynamic> _listBody() => {
      'items': [
        _promotionJson(),
        _promotionJson(
          id: 'promo-2',
          name: 'Clearance',
          type: 'fixed_price',
          value: '150.000',
          isActive: false,
          productCount: 1,
        ),
      ],
      'total': 2,
      'page': 1,
      'page_size': 25,
      'pages': 1,
    };

const _emptyBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 25,
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
    List<String> scopes = _promotionScopes,
    String roleName = 'manager',
    List<Map<String, dynamic>>? listQueryLog,
    Map<String, dynamic>? Function(String path)? postBody,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    // ONE post stub (login / create) dispatched on path.
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(
            _loginPath,
            _loginBody(scopes: scopes, roleName: roleName),
          );
        }
        final body = postBody?.call(path);
        return okResponse(path, body ?? _promotionJson());
      },
    );
    // Bodyless POST (toggle) — Dio omits the `data` argument entirely, so
    // it needs its own stub.
    when(() => dio.post(any())).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        final body = postBody?.call(path);
        return okResponse(path, body ?? _promotionJson());
      },
    );

    // Catch-all GET stubs (registered before the specific auth stubs).
    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      if (path == _promotionsPath) {
        listQueryLog?.add(params);
        return okResponse(path, _listBody());
      }
      if (path == '/api/v1/products/search') {
        return okResponse(path, {
          'items': [
            for (var i = 1; i <= 3; i++)
              {
                'id': 'p$i',
                'name': 'Product $i',
                'unit': 'piece',
                'price': '50.000',
                'cost': '40.000',
                'avg_cost': '40.000',
                'quantity': '10',
                'low_stock_threshold': '2',
                'allow_negative_stock': false,
                'is_active': true,
                'is_archived': false,
              },
          ],
          'total': 3,
        });
      }
      return okResponse(path, _emptyBody);
    });
    when(() => dio.get(any())).thenAnswer(
      (invocation) async =>
          okResponse(invocation.positionalArguments.first as String, _emptyBody),
    );

    // Specific-path GET stubs LAST (checked first).
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
              {'name': 'manager'},
            ],
          },
        ],
        'total': 1,
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

  Future<ProviderContainer> pumpPromotions(
    WidgetTester tester,
    MockDio dio, {
    List<String> scopes = _promotionScopes,
    String roleName = 'manager',
    List<Map<String, dynamic>>? listQueryLog,
    Map<String, dynamic>? Function(String path)? postBody,
    bool navigate = true,
  }) async {
    stubRequests(
      dio,
      scopes: scopes,
      roleName: roleName,
      listQueryLog: listQueryLog,
      postBody: postBody,
    );
    return pumpApp(
      tester,
      dio,
      userName: 'Admin',
      pin: '1234',
      // Without `promotion_view` the rail destination does not exist at all.
      navLabel: navigate && scopes.contains('promotion_view')
          ? AppStrings.t('promotions', 'ar')
          : '',
    );
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data ?? '';

  group('Promotions screen (all three promotion scopes)', () {
    testWidgets('lists the promotions exactly as the server sent them',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      final container =
          await pumpPromotions(tester, dio, listQueryLog: queryLog);

      expect(find.byType(PromotionsScreen), findsOneWidget);
      expect(find.byKey(const Key('promotions-title')), findsOneWidget);
      expect(find.byKey(const Key('promotions-list')), findsOneWidget);

      expect(textOf(tester, 'promotion-name-0'), 'Ramadan sale');
      expect(textOf(tester, 'promotion-meta-0'),
          contains(AppStrings.t('promotion_type_percentage', 'ar')));
      expect(textOf(tester, 'promotion-meta-0'), contains('20%'));
      expect(textOf(tester, 'promotion-name-1'), 'Clearance');
      expect(textOf(tester, 'promotion-meta-1'),
          contains(AppStrings.t('promotion_type_fixed_price', 'ar')));
      expect(textOf(tester, 'promotion-meta-1'), contains('150'));
      expect(find.byKey(const Key('promotions-empty')), findsNothing);

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first['page_size'], 25);
      expect(container.read(promotionsProvider).total, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('status filter is sent as a boolean with page reset',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('promotions-active-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('promotions-active-active')));
      await tester.pumpAndSettle();

      expect(queryLog.length, greaterThan(before));
      expect(queryLog.last['is_active'], isTrue);
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('status filter "all" omits the parameter', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(tester, dio, listQueryLog: queryLog);

      await tester.tap(find.byKey(const Key('promotions-active-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('promotions-active-inactive')));
      await tester.pumpAndSettle();
      expect(queryLog.last['is_active'], isFalse);

      await tester.tap(find.byKey(const Key('promotions-active-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('promotions-active-all')));
      await tester.pumpAndSettle();
      expect(queryLog.last.containsKey('is_active'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search submits q and resets the page', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(tester, dio, listQueryLog: queryLog);

      await tester.enterText(
        find.byKey(const Key('promotions-search')),
        'rama',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(queryLog.last['q'], 'rama');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('Promotions screen — create', () {
    testWidgets('"Add promotion" opens the editor and cancel closes it',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('promotions-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('promotion-form-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('promotion-form-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('promotion-form-dialog')), findsNothing);
      expect(queryLog.length, before, reason: 'no reload on a backed-out form');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the form blocks an empty value and an empty name',
        (tester) async {
      final dio = MockDio();
      await pumpPromotions(tester, dio);

      await tester.tap(find.byKey(const Key('promotions-add')));
      await tester.pumpAndSettle();

      // Blank everything → name first.
      await tester.tap(find.byKey(const Key('promotion-form-submit')));
      await tester.pump();
      expect(
        textOf(tester, 'promotion-form-error'),
        AppStrings.t('field_required', 'ar'),
      );

      // A name with a bad value → the value guard.
      await tester.enterText(
        find.byKey(const Key('promotion-form-name')),
        'Sale',
      );
      await tester.enterText(
        find.byKey(const Key('promotion-form-value')),
        '0',
      );
      await tester.tap(find.byKey(const Key('promotion-form-submit')));
      await tester.pump();
      expect(
        textOf(tester, 'promotion-form-error'),
        AppStrings.t('promotion_invalid_value', 'ar'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'multi-product × fixed price is refused client-side '
        '(MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED)', (tester) async {
      final dio = MockDio();
      await pumpPromotions(tester, dio);

      await tester.tap(find.byKey(const Key('promotions-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('promotion-form-name')),
        'Clearance',
      );
      await tester.tap(find.byKey(const Key('promotion-form-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('promotion-form-type-fixed_price')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('promotion-form-value')),
        '150',
      );

      // Two products from the picker.
      await tester.tap(find.byKey(const Key('promotion-form-add-products')));
      await tester.pumpAndSettle();
      final boxes = find.byType(CheckboxListTile);
      expect(boxes, findsWidgets);
      await tester.tap(boxes.at(0));
      await tester.pump();
      await tester.tap(boxes.at(1));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('promotion-product-picker-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('promotion-form-product-1')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('promotion-form-submit')));
      await tester.pump();
      expect(
        textOf(tester, 'promotion-form-error'),
        AppStrings.t('promotion_multi_fixed', 'ar'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('posts the bulk payload, toasts and reloads', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('promotions-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('promotion-form-name')),
        'Eid sale',
      );
      await tester.enterText(
        find.byKey(const Key('promotion-form-value')),
        '10',
      );
      await tester.tap(find.byKey(const Key('promotion-form-add-products')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('promotion-product-picker-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('promotion-form-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('promotion-form-dialog')), findsNothing);
      expect(find.byKey(const Key('promotions-toast')), findsOneWidget);

      final body = verify(
        () => dio.post(_promotionsPath, data: captureAny(named: 'data')),
      ).captured.single as Map<String, dynamic>;
      expect(body['name'], 'Eid sale');
      expect(body['promotion_type'], 'percentage');
      expect(body['value'], '10.000');
      expect(body['is_active'], isTrue);
      expect((body['product_ids'] as List).length, 1);
      expect('${body['client_request_id']}', isNotEmpty);

      expect(queryLog.length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  group('Promotions screen — toggle', () {
    testWidgets('the row switch posts the toggle and refreshes',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpPromotions(
        tester,
        dio,
        listQueryLog: queryLog,
        postBody: (path) =>
            path == _togglePath ? _promotionJson(isActive: false) : null,
      );
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('promotion-toggle-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('promotions-toggle-toast')), findsOneWidget);
      verify(() => dio.post(_togglePath)).called(1);
      expect(queryLog.length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 409 overlap surfaces the localized conflict message',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);
      // The toggle POST fails with the Phase 18 overlap code.
      when(() => dio.post(_togglePath)).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: _togglePath),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: _togglePath),
            statusCode: 409,
            data: {
              'error': {
                'code': 'PROMOTION_PRODUCT_CONFLICT',
                'message': 'overlap',
                'details': null,
              },
            },
          ),
        ),
      );

      await pumpApp(tester, dio, userName: 'Admin', pin: '1234');
      await tester.tap(find.text(AppStrings.t('promotions', 'ar')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('promotion-toggle-0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('promotions-toggle-error-toast')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('promotion_product_conflict', 'ar')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Promotions screen RBAC', () {
    testWidgets('user without promotion_view: no rail entry, route denied',
        (tester) async {
      final dio = MockDio();
      await pumpPromotions(tester, dio, scopes: const ['pos_sale']);

      expect(find.text(AppStrings.t('promotions', 'ar')), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(routerProvider).go('/promotions');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('promotions-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('promotions-title')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('promotion_view without create/update hides the actions',
        (tester) async {
      final dio = MockDio();
      await pumpPromotions(tester, dio, scopes: const ['promotion_view']);

      expect(find.byKey(const Key('promotions-title')), findsOneWidget);
      expect(find.byKey(const Key('promotions-list')), findsOneWidget);
      expect(find.byKey(const Key('promotions-add')), findsNothing);
      expect(find.byKey(const Key('promotion-toggle-0')), findsNothing);
      expect(find.byKey(const Key('promotion-edit-0')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // Rail entry: `promotion_view` holders (admin + manager per seed.py) see
  // the Promotions destination right after Packs; the cashier holds none of
  // the promotion scopes and never sees it.
  List<String> railLabels(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(AppNavRail),
          matching: find.byType(Text),
        ),
      )
      .map((text) => text.data ?? '')
      .toList();

  group('Promotions rail entry', () {
    testWidgets('manager sees Promotions right after Packs', (tester) async {
      final dio = MockDio();
      await pumpPromotions(
        tester,
        dio,
        // Packs lives behind `product_view` — the manager holds it.
        scopes: const ['product_view', 'promotion_view'],
        roleName: 'manager',
        navigate: false,
      );

      final labels = railLabels(tester);
      final promotionsLabel = AppStrings.t('promotions', 'ar');
      final packsLabel = AppStrings.t('packs', 'ar');

      expect(labels, contains(promotionsLabel));
      expect(
        labels.indexOf(promotionsLabel),
        labels.indexOf(packsLabel) + 1,
        reason: 'Promotions must be the destination right after Packs',
      );

      await tester.tap(find.text(promotionsLabel));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('promotions-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a role without promotion_view has no destination',
        (tester) async {
      final dio = MockDio();
      await pumpPromotions(
        tester,
        dio,
        scopes: const ['product_view', 'pos_sale'],
        roleName: 'cashier',
        navigate: false,
      );

      final labels = railLabels(tester);
      expect(
        labels,
        isNot(contains(AppStrings.t('promotions', 'ar'))),
        reason: 'no promotion_view → no Promotions destination',
      );
      expect(labels, contains(AppStrings.t('packs', 'ar')));
      expect(tester.takeException(), isNull);
    });
  });
}
