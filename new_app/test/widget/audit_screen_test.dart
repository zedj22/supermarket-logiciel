// Audit Log screen widget tests (Slice B): server-side list + summary,
// server-side filters with page reset, pagination, the detail dialog
// (fetched by id, diff rendered), explicit empty / error / retry states,
// the honest legacy-unknown outcome, and the `audit_view` RBAC gate.
//
// Harness rules from expenses_screen_test.dart: catch-all GET stubs
// first, specific auth GET stubs LAST, ONE universal POST stub dispatched
// on path.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/audit/audit_providers.dart';
import 'package:supermarket_pos/features/audit/audit_screen.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/shell/app_nav_rail.dart';
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
const _auditPath = '/api/v1/audit';
const _summaryPath = '/api/v1/audit/summary';
const _detailPath = '/api/v1/audit/3d0f4a6e-1111-2222-3333-444455556666';

const _auditScopes = ['audit_view'];

Map<String, dynamic> _loginBody({List<String> scopes = _auditScopes}) => {
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

Map<String, dynamic> _eventJson({
  String id = '3d0f4a6e-1111-2222-3333-444455556666',
  String outcome = 'success',
  String action = 'void',
  String? module = 'sales',
  String? actorName = 'Amel B.',
  String? deviceName = 'Caisse 1',
  bool? deviceVerified = true,
}) =>
    {
      'id': id,
      'occurred_at': '2026-10-01T09:30:00Z',
      'recorded_at': '2026-10-01T09:30:02Z',
      'outcome': outcome,
      'module': module,
      'action': action,
      'actor_id': '00000000-0000-0000-0000-0000000000a1',
      'actor_name': actorName,
      'device_id': 'POS-1',
      'device_name': deviceName,
      'device_verified': deviceVerified,
      'session_id': 'sess-1',
      'request_id': 'req-1',
      'ip_address': '192.168.1.10',
      'entity_type': 'sale',
      'entity_id': '9b0c1d2e-5555-6666-7777-888899990000',
      'entity_ref': 'VTE-2026-0042',
      'reason': 'Wrong item',
      'details': null,
      'before': null,
      'after': null,
      'diff': null,
      'metadata': null,
    };

Map<String, dynamic> _detailJson() => {
      ..._eventJson(),
      'details': '{"cashier":"amel"}',
      'before': {'status': 'completed'},
      'after': {'status': 'void'},
      'diff': {
        'status': {'before': 'completed', 'after': 'void'},
      },
      'metadata': {'source': 'pos'},
    };

Map<String, dynamic> _listBody({int pages = 1, bool empty = false}) => {
      'items': empty
          ? <Map<String, dynamic>>[]
          : [
              _eventJson(),
              _eventJson(
                id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                outcome: 'unknown',
                action: 'create',
                module: null,
                actorName: null,
                deviceName: null,
                deviceVerified: null,
              ),
            ],
      'total': empty ? 0 : 42,
      'page': 1,
      'page_size': 25,
      'pages': pages,
    };

Map<String, dynamic> _summaryBody() => {
      'total': 42,
      'success': 30,
      'failure': 8,
      'denied': 3,
      'unknown': 1,
      'distinct_users': 4,
      'distinct_devices': 2,
      'by_action': <Map<String, dynamic>>[],
      'by_module': <Map<String, dynamic>>[],
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

  Response<dynamic> errorResponse(String path) => Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 500,
        data: {
          'error': {'code': 'INTERNAL_ERROR', 'message': 'boom'},
        },
      );

  DioException serverError(String path) => DioException(
        requestOptions: RequestOptions(path: path),
        response: errorResponse(path),
        type: DioExceptionType.badResponse,
      );

  void stubRequests(
    MockDio dio, {
    List<String> scopes = _auditScopes,
    List<Map<String, dynamic>>? listQueryLog,
    List<Map<String, dynamic>>? summaryQueryLog,
    bool Function()? failList,
    int pages = 1,
    bool empty = false,
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    // ONE post stub (login) dispatched on path.
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path == _loginPath) {
          return okResponse(path, _loginBody(scopes: scopes));
        }
        return okResponse(path, _eventJson());
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
      if (path == _auditPath) {
        listQueryLog?.add(params);
        // Real Dio throws on a non-2xx; the notifier only catches
        // DioException, so the failure must be a thrown exception.
        if (failList?.call() ?? false) throw serverError(path);
        return okResponse(path, _listBody(pages: pages, empty: empty));
      }
      if (path == _summaryPath) {
        summaryQueryLog?.add(params);
        return okResponse(path, _summaryBody());
      }
      if (path == _detailPath) {
        return okResponse(path, _detailJson());
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
              {'name': 'admin'},
            ],
          },
        ],
        'total': 1,
      }),
    );
    // The detail dialog fetches GET /audit/{id} with NO query parameters —
    // it must not fall through to the bare `get(any())` empty stub.
    when(() => dio.get(_detailPath)).thenAnswer(
      (_) async => okResponse(_detailPath, _detailJson()),
    );
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    MockDio dio, {
    required bool navigate,
    List<String> scopes = _auditScopes,
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

    if (navigate && scopes.contains('audit_view')) {
      await tester.tap(find.text(AppStrings.t('audit_log', 'ar')));
      await tester.pumpAndSettle();
    }

    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  Future<ProviderContainer> pumpAudit(
    WidgetTester tester,
    MockDio dio, {
    List<String> scopes = _auditScopes,
    List<Map<String, dynamic>>? listQueryLog,
    List<Map<String, dynamic>>? summaryQueryLog,
    bool Function()? failList,
    int pages = 1,
    bool empty = false,
    bool navigate = true,
  }) async {
    stubRequests(
      dio,
      scopes: scopes,
      listQueryLog: listQueryLog,
      summaryQueryLog: summaryQueryLog,
      failList: failList,
      pages: pages,
      empty: empty,
    );
    return pumpApp(tester, dio, navigate: navigate, scopes: scopes);
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data ?? '';

  group('Audit screen (list + server summary)', () {
    testWidgets(
        'lists events and shows the server aggregates — never page counts',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      final container = await pumpAudit(tester, dio, listQueryLog: queryLog);

      expect(find.byType(AuditScreen), findsOneWidget);
      expect(find.byKey(const Key('audit-title')), findsOneWidget);
      expect(find.byKey(const Key('audit-list')), findsOneWidget);

      expect(
        textOf(tester, 'audit-title-0'),
        '${AppStrings.t('audit_action_void', 'ar')} · '
        '${AppStrings.t('audit_module_sales', 'ar')}',
      );
      expect(find.byKey(const Key('audit-tile-1')), findsOneWidget);

      expect(textOf(tester, 'audit-summary-total'), '42');
      expect(textOf(tester, 'audit-summary-success'), '30');
      expect(textOf(tester, 'audit-summary-failure'), '8');
      expect(textOf(tester, 'audit-summary-denied'), '3');
      expect(textOf(tester, 'audit-summary-unknown'), '1');
      expect(textOf(tester, 'audit-summary-users'), '4');
      expect(textOf(tester, 'audit-summary-devices'), '2');

      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first['page_size'], 25);
      expect(container.read(auditProvider).total, 42);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a legacy NULL outcome row renders as explicit unknown',
        (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio);

      // The second event carries outcome "unknown" — help icon, not a
      // fabricated success checkmark.
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit screen — server-side filters', () {
    testWidgets('module filter is sent with page reset', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog);
      final before = queryLog.length;

      await tester.tap(find.byKey(const Key('audit-module-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audit-module-auth')));
      await tester.pumpAndSettle();

      expect(queryLog.length, greaterThan(before));
      expect(queryLog.last['module'], 'auth');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('outcome filter reaches the API', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog);

      await tester.tap(find.byKey(const Key('audit-outcome-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audit-outcome-denied')));
      await tester.pumpAndSettle();

      expect(queryLog.last['outcome'], 'denied');
      expect(tester.takeException(), isNull);
    });

    testWidgets('action filter reaches the API', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog);

      await tester.tap(find.byKey(const Key('audit-action-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audit-action-login')));
      await tester.pumpAndSettle();

      expect(queryLog.last['action'], 'login');
      expect(tester.takeException(), isNull);
    });

    testWidgets('search submits q and resets the page', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog);

      await tester.enterText(
        find.byKey(const Key('audit-search')),
        'VTE-2026',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(queryLog.last['q'], 'VTE-2026');
      expect(queryLog.last['page'], 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('entity-type filter submits entity_type', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog);

      await tester.enterText(
        find.byKey(const Key('audit-entity-type')),
        'sale',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(queryLog.last['entity_type'], 'sale');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the two date-range pickers open from the filter bar',
        (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio);

      expect(find.byKey(const Key('audit-date-label')), findsOneWidget);
      expect(find.byKey(const Key('audit-date-from')), findsOneWidget);
      expect(find.byKey(const Key('audit-date-to')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audit-date-from')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit screen — pagination', () {
    testWidgets('next page is requested from the server', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      await pumpAudit(tester, dio, listQueryLog: queryLog, pages: 2);

      expect(find.byKey(const Key('audit-next')), findsOneWidget);
      await tester.tap(find.byKey(const Key('audit-next')));
      await tester.pumpAndSettle();

      expect(queryLog.last['page'], 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit screen — empty / error / retry', () {
    testWidgets('an empty result is an explicit empty state', (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio, empty: true);

      expect(find.byKey(const Key('audit-empty')), findsOneWidget);
      expect(
        find.text(AppStrings.t('audit_empty', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load shows the error and retry recovers',
        (tester) async {
      final dio = MockDio();
      var failing = true;
      await pumpAudit(tester, dio, failList: () => failing);

      expect(find.byKey(const Key('audit-error')), findsOneWidget);
      expect(find.byKey(const Key('audit-retry')), findsOneWidget);

      failing = false;
      await tester.tap(find.byKey(const Key('audit-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audit-list')), findsOneWidget);
      expect(find.byKey(const Key('audit-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit screen — detail dialog', () {
    testWidgets('opens by id and renders the server-computed diff',
        (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio);

      await tester.tap(find.byKey(const Key('audit-tile-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audit-detail-dialog')), findsOneWidget);
      expect(find.byKey(const Key('audit-detail-id')), findsOneWidget);
      expect(textOf(tester, 'audit-detail-actor'), 'Amel B.');
      expect(find.byKey(const Key('audit-detail-diff')), findsOneWidget);
      expect(find.byKey(const Key('audit-diff-field-status')), findsOneWidget);
      expect(find.text('completed'), findsWidgets);
      expect(find.byKey(const Key('audit-detail-ip')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audit-detail-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audit-detail-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit screen RBAC', () {
    testWidgets('user without audit_view: no rail entry, route denied',
        (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio, scopes: const ['pos_sale']);

      expect(find.text(AppStrings.t('audit_log', 'ar')), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      container.read(routerProvider).go('/audit-log');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('audit-denied')), findsOneWidget);
      expect(
        find.text(AppStrings.t('permission_denied', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('audit-title')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('audit_view sees the destination under Administration',
        (tester) async {
      final dio = MockDio();
      await pumpAudit(tester, dio, navigate: false);

      final labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(AppNavRail),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data ?? '')
          .toList();
      expect(labels, contains(AppStrings.t('audit_log', 'ar')));

      await tester.tap(find.text(AppStrings.t('audit_log', 'ar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audit-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
