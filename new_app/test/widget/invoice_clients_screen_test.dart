// Phase 8 — Invoice Clients screen (CRUD) widget tests.
//
// Harness copied from clients_screen_test.dart (full-app login flow,
// MockDio). Invoice-clients rail entries are gated on facturation_view
// (Phase 9 Stage C) — the mock admin login grants that scope.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/invoice_clients/invoice_clients_screen.dart';
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

const _loginPath = '/api/v1/auth/login';
const _clientsPath = '/api/v1/invoice-clients';

Map<String, dynamic> _loginBody() => {
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
              {'id': 'p-view', 'scope': 'customer_view', 'description': null},
              {
                'id': 'p-fact',
                'scope': 'facturation_view',
                'description': null,
              },
            ],
          },
        ],
      },
    };

Map<String, dynamic> _clientJson({
  required String id,
  required String name,
  String? phone,
  String? wilaya,
  String? nif,
  bool archived = false,
}) =>
    {
      'id': id,
      'name': name,
      'address': null,
      'wilaya': wilaya,
      'phone': phone,
      'nif': nif,
      'rc': null,
      'ai': null,
      'nis': null,
      'is_archived': archived,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _listBody({
  List<Map<String, dynamic>>? items,
  int total = 2,
}) =>
    {
      'items': items ??
          [
            _clientJson(
              id: 'ic1',
              name: 'SARL Example',
              phone: '0555112233',
              wilaya: 'Alger',
              nif: 'NIF-001',
            ),
            _clientJson(id: 'ic2', name: 'EURL Demo', wilaya: 'Oran'),
          ],
      'total': total,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

void stubRequests(
  MockDio dio, {
  List<Map<String, dynamic>>? listQueryLog,
}) {
  final log = listQueryLog ?? <Map<String, dynamic>>[];
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _loginPath) {
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: _loginBody(),
        );
      }
      if (path == _clientsPath) {
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 201,
          data: _clientJson(id: 'ic-new', name: 'New Client'),
        );
      }
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: <String, dynamic>{},
      );
    },
  );

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    final params =
        invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
    if (path == _clientsPath) {
      log.add({...?params});
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: _listBody(),
      );
    }
    return Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: <String, dynamic>{},
    );
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    if (path == _clientsPath) {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: _listBody(),
      );
    }
    return Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: <String, dynamic>{},
    );
  });

  // Specific-path GET stubs LAST (checked first) — must beat the
  // any() catch-alls above.
  when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/api/v1/auth/setup/check'),
      statusCode: 200,
      data: {'setup_needed': false},
    ),
  );
  when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
      statusCode: 200,
      data: {
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
      },
    ),
  );

  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => Response(
      requestOptions: RequestOptions(
        path: invocation.positionalArguments.first as String,
      ),
      statusCode: 200,
      data: _clientJson(id: 'ic1', name: 'SARL Example Updated'),
    ),
  );

  when(() => dio.delete(any())).thenAnswer(
    (invocation) async => Response(
      requestOptions: RequestOptions(
        path: invocation.positionalArguments.first as String,
      ),
      statusCode: 200,
      data: _clientJson(id: 'ic1', name: 'SARL Example', archived: true),
    ),
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

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Invoice clients screen', () {
    testWidgets('loads via GET /api/v1/invoice-clients and lists clients',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      expect(find.byType(InvoiceClientsScreen), findsOneWidget);
      expect(find.byKey(const Key('invoice-clients-title')), findsOneWidget);
      expect(find.text('SARL Example'), findsOneWidget);
      expect(find.text('EURL Demo'), findsOneWidget);
      expect(find.byKey(const Key('invoice-client-name-0')), findsOneWidget);
      expect(find.byKey(const Key('invoice-clients-total')), findsOneWidget);
      expect(
        find.text('${AppStrings.t('total', 'ar')}: 2'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('rail entries visible when facturation_view is granted',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio);

      expect(find.text(AppStrings.t('facturation', 'ar')), findsOneWidget);
      expect(
        find.text(AppStrings.t('invoice_clients', 'ar')),
        findsOneWidget,
      );
    });

    testWidgets('search debounce sends q parameter', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      await tester.enterText(
        find.byKey(const Key('invoice-clients-search')),
        'SARL',
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(queryLog, isNotEmpty);
      expect(queryLog.last['q'], 'SARL');
      expect(queryLog.last['page'], 1);
    });

    testWidgets('show-archived toggle sends include_archived', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      await tester.tap(
        find.byKey(const Key('invoice-clients-archived-toggle')),
      );
      await tester.pumpAndSettle();

      expect(queryLog.last['include_archived'], isTrue);
    });

    testWidgets('add button opens form dialog and submits POST', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      await tester.tap(find.byKey(const Key('invoice-clients-add-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-client-form-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('invoice-client-name-field')),
        'New Client',
      );
      await tester.tap(find.byKey(const Key('invoice-client-form-submit')));
      await tester.pumpAndSettle();

      verify(() => dio.post(
            _clientsPath,
            data: any(named: 'data'),
          )).called(1);
    });

    testWidgets('archive flow: confirm dialog → DELETE', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      await tester.tap(find.byKey(const Key('invoice-client-archive-0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('invoice-client-archive-confirm')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('invoice-client-archive-confirm-button')),
      );
      await tester.pumpAndSettle();

      verify(() => dio.delete('$_clientsPath/ic1')).called(1);
    });

    testWidgets('edit opens form pre-filled with client name', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('invoice_clients', 'ar'),
      );

      await tester.tap(find.byKey(const Key('invoice-client-edit-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-client-form-dialog')), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'SARL Example'),
        findsOneWidget,
      );
    });
  });
}
