// Phase 8 — Facturation screen (document list) widget tests.
//
// Harness copied from clients_screen_test.dart (full-app login flow,
// MockDio). Facturation rail entries are gated on facturation_view
// (Phase 9 Stage C) — the mock admin login grants that scope.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/facturation/facturation_screen.dart';
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
const _facturesPath = '/api/v1/factures';

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

Map<String, dynamic> _clientRef() => {
      'id': 'ic1',
      'name': 'SARL Example',
      'address': null,
      'wilaya': 'Alger',
      'phone': null,
      'nif': null,
      'rc': null,
      'ai': null,
      'nis': null,
      'is_archived': false,
      'created_at': null,
      'updated_at': null,
    };

Map<String, dynamic> _docSummary({
  required String id,
  required String number,
  String docType = 'FAC',
}) =>
    {
      'id': id,
      'doc_type': docType,
      'year': 2026,
      'number': number,
      'document_date': '2026-03-15',
      'client_id': 'ic1',
      'client': _clientRef(),
      'payment_method': 'cash',
      'notes': null,
      'created_at': '2026-03-15T10:00:00Z',
      'updated_at': null,
    };

Map<String, dynamic> _listBody({List<Map<String, dynamic>>? items}) => {
      'items': items ??
          [
            _docSummary(id: 'd1', number: 'FAC-2026-0001'),
            _docSummary(id: 'd2', number: 'BL-2026-0002', docType: 'BL'),
          ],
      'total': 2,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Map<String, dynamic> _docDetail() => {
      'id': 'd1',
      'doc_type': 'FAC',
      'year': 2026,
      'number': 'FAC-2026-0001',
      'document_date': '2026-03-15',
      'client_id': 'ic1',
      'client': _clientRef(),
      'payment_method': 'cash',
      'notes': 'note',
      'show_discount': true,
      'show_tva': true,
      'show_timbre': true,
      'show_payment_method': true,
      'show_amount_words': true,
      'lines': [
        {
          'id': 'l1',
          'product_id': 'p1',
          'description': 'Widget',
          'quantity': '2',
          'unit_price_ht': '10.000',
          'tva_rate': '19.000',
          'discount_pct': '0.000',
          'position': 0,
          'total_ht': '20.000',
          'total_tva': '3.800',
        },
      ],
      'totals': {
        'total_ht': '20.000',
        'total_tva': '3.800',
        'total_ttc': '23.800',
        'timbre': '1.000',
        'net_a_payer': '24.800',
      },
      'amount_in_words': 'vingt-quatre dinars…',
      'created_at': '2026-03-15T10:00:00Z',
      'updated_at': null,
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
      if (path == '$_facturesPath/preview') {
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: {
            'document_date': '2026-03-15',
            'year': 2026,
            'number': 'FAC-2026-0042',
            'client_id': 'ic1',
            'client': _clientRef(),
            'lines': [
              {
                'product_id': null,
                'description': 'Service',
                'quantity': '1',
                'unit_price_ht': '100.000',
                'tva_rate': '0.000',
                'discount_pct': '0.000',
                'position': 0,
                'total_ht': '100.000',
                'total_tva': '0.000',
              },
            ],
            'totals': {
              'total_ht': '100.000',
              'total_tva': '0.000',
              'total_ttc': '100.000',
              'timbre': '1.000',
              'net_a_payer': '101.000',
            },
            'amount_in_words': 'cent-un dinars…',
          },
        );
      }
      if (path == _facturesPath) {
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 201,
          data: {
            'id': 'd-new',
            'doc_type': 'FAC',
            'year': 2026,
            'number': 'FAC-2026-0043',
            'document_date': '2026-03-15',
            'client_id': 'ic1',
            'client': _clientRef(),
            'payment_method': 'cash',
            'notes': null,
            'show_discount': true,
            'show_tva': true,
            'show_timbre': true,
            'show_payment_method': true,
            'show_amount_words': true,
            'lines': [],
            'totals': {
              'total_ht': '0.000',
              'total_tva': '0.000',
              'total_ttc': '0.000',
              'timbre': '0.000',
              'net_a_payer': '0.000',
            },
            'amount_in_words': '',
            'created_at': null,
            'updated_at': null,
          },
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
    if (path == _facturesPath) {
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
    if (path == '$_facturesPath/d1') {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: _docDetail(),
      );
    }
    if (path == _facturesPath) {
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
      data: _docDetail(),
    ),
  );

  when(() => dio.delete(any())).thenAnswer(
    (invocation) async => Response(
      requestOptions: RequestOptions(
        path: invocation.positionalArguments.first as String,
      ),
      statusCode: 405,
      data: <String, dynamic>{},
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

  group('Facturation screen', () {
    testWidgets('loads via GET /api/v1/factures and lists documents',
        (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      expect(find.byType(FacturationScreen), findsOneWidget);
      expect(find.byKey(const Key('facturation-title')), findsOneWidget);
      expect(find.text('FAC-2026-0001'), findsOneWidget);
      expect(find.text('BL-2026-0002'), findsOneWidget);
      expect(find.byKey(const Key('facturation-total')), findsOneWidget);
      expect(
        find.text('${AppStrings.t('total', 'ar')}: 2'),
        findsOneWidget,
      );
      expect(queryLog, isNotEmpty);
      expect(queryLog.first['page'], 1);
      expect(queryLog.first.containsKey('q'), isFalse);
      expect(queryLog.first.containsKey('doc_type'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('doc-type filter sends doc_type parameter', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.tap(find.byKey(const Key('facturation-doctype-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.t('doc_type_bl', 'ar')).last);
      await tester.pumpAndSettle();

      expect(queryLog.last['doc_type'], 'BL');
    });

    testWidgets('search debounce sends q parameter', (tester) async {
      final dio = MockDio();
      final queryLog = <Map<String, dynamic>>[];
      stubRequests(dio, listQueryLog: queryLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.enterText(
        find.byKey(const Key('facturation-search')),
        'FAC-2026',
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(queryLog.last['q'], 'FAC-2026');
    });

    testWidgets('new document button opens the invoice form dialog',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.tap(find.byKey(const Key('facturation-add-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-form-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('invoice-form-lines-empty')),
        findsOneWidget,
      );
    });

    testWidgets('tapping a row opens the detail dialog with server totals',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.tap(find.byKey(const Key('facturation-tile-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-detail-dialog')), findsOneWidget);
      expect(find.byKey(const Key('invoice-detail-number')), findsOneWidget);
      // The tile behind the dialog still shows the same number.
      expect(find.text('FAC-2026-0001'), findsNWidgets(2));
      // Server totals — net à payer 24.800 → formatMoney → '24.8'
      expect(find.byKey(const Key('invoice-detail-total-net_a_payer')), findsOneWidget);
      expect(find.text('24.8'), findsOneWidget);
      // Lines from GET /factures/{id}
      expect(find.text('Widget'), findsOneWidget);
    });

    testWidgets('detail dialog exposes edit + PDF actions', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.tap(find.byKey(const Key('facturation-tile-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-detail-edit')), findsOneWidget);
      expect(find.byKey(const Key('invoice-detail-pdf')), findsOneWidget);
    });
  });
}
