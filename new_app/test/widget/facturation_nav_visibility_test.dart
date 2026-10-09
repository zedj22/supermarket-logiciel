// Phase 9 Stage C — Facturation + Invoice Clients nav visibility tests.
//
// Proves the rail entries are gated on facturation_view:
//   - Admin (seeded facturation_view) sees both destinations.
//   - Manager (seeded facturation_view) sees both destinations.
//   - Cashier (no facturation_view) sees neither.
//   - Authenticated user with no relevant scopes sees neither.
//   - Unrelated destinations (e.g. POS) stay visible for a cashier.
//
// Navigation visibility is UI-only; backend RBAC (Stage B) remains the
// security boundary. Direct route access without the scope is out of
// scope for this stage.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
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

const _emptyListBody = {
  'items': <Map<String, dynamic>>[],
  'total': 0,
  'page': 1,
  'page_size': 40,
  'pages': 1,
};

/// Build a login response body for a role with the given permission scopes.
Map<String, dynamic> _loginBody({
  required String roleName,
  required List<String> scopes,
  String fullName = 'Operator',
}) =>
    {
      'access_token': 'tok-$roleName',
      'token_type': 'bearer',
      'expires_in': 3600,
      'user': {
        'id': '00000000-0000-0000-0000-0000000000a1',
        'full_name': fullName,
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

void stubRequests(
  MockDio dio, {
  required String roleName,
  required List<String> scopes,
  String fullName = 'Operator',
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == _loginPath) {
        return Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          data: _loginBody(
            roleName: roleName,
            scopes: scopes,
            fullName: fullName,
          ),
          statusCode: 200,
        );
      }
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: {'message': 'ok'},
        statusCode: 200,
      );
    },
  );

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: _emptyListBody,
      statusCode: 200,
    );
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    return Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: _emptyListBody,
      statusCode: 200,
    );
  });

  when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
    (_) async => Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/auth/setup/check'),
      statusCode: 200,
      data: {'setup_needed': false},
    ),
  );
  when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
    (_) async => Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/auth/login-users'),
      statusCode: 200,
      data: {
        'items': [
          {
            'id': '00000000-0000-0000-0000-0000000000a1',
            'full_name': fullName,
            'is_active': true,
            'roles': [
              {'name': roleName},
            ],
          },
        ],
        'total': 1,
      },
    ),
  );
}

Future<void> pumpApp(
  WidgetTester tester,
  MockDio dio, {
  String tapUserName = 'Operator',
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

  await tester.tap(find.text(tapUserName));
  await tester.pumpAndSettle();
  for (final d in ['1', '2', '3', '4']) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('login-submit-button')));
  await tester.pumpAndSettle();
}

Finder facturationLabel() =>
    find.text(AppStrings.t('facturation', 'ar'));
Finder invoiceClientsLabel() =>
    find.text(AppStrings.t('invoice_clients', 'ar'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Facturation nav visibility (Phase 9 Stage C)', () {
    testWidgets('admin with facturation_view sees both entries',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        roleName: 'admin',
        scopes: ['facturation_view', 'customer_view'],
        fullName: 'Admin',
      );

      await pumpApp(tester, dio, tapUserName: 'Admin');

      expect(facturationLabel(), findsOneWidget);
      expect(invoiceClientsLabel(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('manager with facturation_view sees both entries',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        roleName: 'manager',
        scopes: ['facturation_view', 'pos_sale'],
        fullName: 'Manager Mo',
      );

      await pumpApp(tester, dio, tapUserName: 'Manager Mo');

      expect(facturationLabel(), findsOneWidget);
      expect(invoiceClientsLabel(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cashier without facturation_view sees neither entry',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        roleName: 'cashier',
        scopes: ['pos_sale', 'customer_view'],
        fullName: 'Cashier Ali',
      );

      await pumpApp(tester, dio, tapUserName: 'Cashier Ali');

      expect(facturationLabel(), findsNothing);
      expect(invoiceClientsLabel(), findsNothing);
      // Unrelated destinations remain visible for the cashier.
      expect(
        find.text(AppStrings.t('pos', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('clients', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'authenticated user without facturation_view sees neither entry',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        roleName: 'guest',
        scopes: [],
        fullName: 'Guest No Roles',
      );

      await pumpApp(tester, dio, tapUserName: 'Guest No Roles');

      expect(facturationLabel(), findsNothing);
      expect(invoiceClientsLabel(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
