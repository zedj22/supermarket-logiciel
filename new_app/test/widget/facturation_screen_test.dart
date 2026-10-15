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
  String documentDate = '2026-03-15',
}) =>
    {
      'id': id,
      'doc_type': docType,
      'year': 2026,
      'number': number,
      'document_date': documentDate,
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
  List<Map<String, dynamic>>? postLog,
  List<Map<String, dynamic>>? putLog,
  List<Map<String, dynamic>>? listItems,
  List<Map<String, dynamic>>? productItems,
}) {
  final log = listQueryLog ?? <Map<String, dynamic>>[];
  final posts = postLog ?? <Map<String, dynamic>>[];
  final puts = putLog ?? <Map<String, dynamic>>[];
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async {
      final path = invocation.positionalArguments.first as String;
      final data = invocation.namedArguments[#data];
      posts.add({'path': path, 'data': data});
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
        data: _listBody(items: listItems),
      );
    }
    if (path == '/api/v1/invoice-clients') {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'items': [_clientRef()],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
      );
    }
    // Product picker search — only active when the test provides items,
    // so every existing test keeps the catch-all {} behavior.
    if (path == '/api/v1/products/search' && productItems != null) {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'items': productItems,
          'total': productItems.length,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
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
    (invocation) async {
      puts.add({
        'path': invocation.positionalArguments.first as String,
        'data': invocation.namedArguments[#data],
      });
      return Response(
        requestOptions: RequestOptions(
          path: invocation.positionalArguments.first as String,
        ),
        statusCode: 200,
        data: _docDetail(),
      );
    },
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
  AppLocale? locale,
}) async {
  tester.view.physicalSize = const Size(2200, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        if (locale != null)
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(locale),
          ),
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
      // Server totals — net à payer 24.800 → formatDisplayMoney → '24.8 DA'
      expect(find.byKey(const Key('invoice-detail-total-net_a_payer')), findsOneWidget);
      expect(find.text('24.8 DA'), findsOneWidget);
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

  group('Facturation presentation formatting (C-2/C-3)', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      final code = locale.name;

      testWidgets('list date renders DD/MM/YYYY ($code)', (tester) async {
        final dio = MockDio();
        stubRequests(dio);

        await pumpApp(
          tester,
          dio,
          navLabel: AppStrings.t('facturation', code),
          locale: locale,
        );

        // Mock document_date is '2026-03-15' → 15/03/2026 (both rows).
        expect(find.byKey(const Key('facturation-date-0')), findsOneWidget);
        expect(find.text('15/03/2026'), findsNWidgets(2));
        // ISO form must not leak into the rendered cells.
        expect(find.text('2026-03-15'), findsNothing);
        // Layout direction follows the locale: only Arabic is RTL.
        expect(
          Directionality.of(
            tester.element(find.byKey(const Key('facturation-date-0'))),
          ),
          locale == AppLocale.ar ? TextDirection.rtl : TextDirection.ltr,
        );
      });
    }

    testWidgets('list date zero-pads single-digit day and month',
        (tester) async {
      final dio = MockDio();
      stubRequests(
        dio,
        listItems: [
          _docSummary(
            id: 'd1',
            number: 'FAC-2026-0001',
            documentDate: '2026-01-05',
          ),
        ],
      );

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      // '2026-01-05' → '05/01/2026' (zero-padded).
      expect(find.byKey(const Key('facturation-date-0')), findsOneWidget);
      expect(find.text('05/01/2026'), findsOneWidget);
      expect(find.text('2026-01-05'), findsNothing);
    });

    testWidgets('detail date and money totals carry exactly one DA (ar)',
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

      // Document date is display-formatted, not ISO. The meta's first line
      // is the document_date row; created_at is a separate timestamp that
      // legitimately still prints ISO, so scope the ISO check to line one.
      final meta = tester.widget<Text>(
        find.byKey(const Key('invoice-detail-meta')),
      );
      final docDateLine = meta.data!.split('\n').first;
      expect(docDateLine, contains('15/03/2026'));
      expect(docDateLine, isNot(contains('2026-03-15')));

      // Monetary totals carry exactly one DA suffix. total_ht appears twice
      // (line-table cell + totals row), so assert via the keyed totals rows.
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-detail-total-total_ht')),
            )
            .data,
        '20 DA',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-detail-total-total_tva')),
            )
            .data,
        '3.8 DA',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-detail-total-total_ttc')),
            )
            .data,
        '23.8 DA',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-detail-total-timbre')))
            .data,
        '1 DA',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-detail-total-net_a_payer')),
            )
            .data,
        '24.8 DA',
      );
      // Line-table unit price also carries DA (10.000 → 10 DA, one cell).
      expect(find.text('10 DA'), findsOneWidget);

      // Quantities and percentages stay suffix-free.
      expect(find.text('19%'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('2 DA'), findsNothing); // quantity must not gain DA
    });

    testWidgets('detail money/quantity formatting holds in English',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'en'),
        locale: AppLocale.en,
      );

      await tester.tap(find.byKey(const Key('facturation-tile-0')));
      await tester.pumpAndSettle();

      final meta = tester.widget<Text>(
        find.byKey(const Key('invoice-detail-meta')),
      );
      expect(meta.data, contains('15/03/2026'));
      expect(find.text('24.8 DA'), findsOneWidget);
      expect(find.text('19%'), findsOneWidget);
      expect(find.text('2 DA'), findsNothing);
    });

    testWidgets('detail money/quantity formatting holds in French',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'fr'),
        locale: AppLocale.fr,
      );

      await tester.tap(find.byKey(const Key('facturation-tile-0')));
      await tester.pumpAndSettle();

      final meta = tester.widget<Text>(
        find.byKey(const Key('invoice-detail-meta')),
      );
      expect(meta.data, contains('15/03/2026'));
      expect(find.text('24.8 DA'), findsOneWidget);
      expect(find.text('19%'), findsOneWidget);
      expect(find.text('2 DA'), findsNothing);
    });

    testWidgets('form footer subtotals use trimmed DA formatting',
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

      final footer = tester.widget<Text>(
        find.byKey(const Key('invoice-form-display-totals')),
      );
      // milliToMoney(0) = '0.000' → formatDisplayMoney → '0 DA'.
      expect(footer.data, contains('0 DA'));
      // The old untrimmed '0.000' must not appear.
      expect(footer.data, isNot(contains('0.000')));
    });

    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      final code = locale.name;

      testWidgets(
          'form edit identity and date label show DD/MM/YYYY ($code)',
          (tester) async {
        final dio = MockDio();
        stubRequests(dio);

        await pumpApp(
          tester,
          dio,
          navLabel: AppStrings.t('facturation', code),
          locale: locale,
        );

        await tester.tap(find.byKey(const Key('facturation-tile-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('invoice-detail-edit')));
        await tester.pumpAndSettle();

        final identity = tester.widget<Text>(
          find.byKey(const Key('invoice-form-identity')),
        );
        expect(identity.data, contains('15/03/2026'));
        expect(identity.data, isNot(contains('2026-03-15')));

        // The form's date button label is display-formatted too.
        final dateLabel = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('invoice-form-date')),
            matching: find.byType(Text),
          ),
        );
        expect(dateLabel.data, '15/03/2026');
        expect(dateLabel.data, isNot(contains('2026-03-15')));
      });
    }

    testWidgets('create payload keeps ISO document_date (English end-to-end)',
        (tester) async {
      final dio = MockDio();
      final postLog = <Map<String, dynamic>>[];
      stubRequests(dio, postLog: postLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'en'),
        locale: AppLocale.en,
      );

      // Open the create form.
      await tester.tap(find.byKey(const Key('facturation-add-button')));
      await tester.pumpAndSettle();

      // Pick a date via the Material date picker.
      await tester.tap(find.byKey(const Key('invoice-form-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // The date BUTTON is display-formatted (its label is a Text inside
      // the OutlinedButton.icon). The list rows behind the dialog are
      // display-formatted too, so scope the label assertion to the button.
      final dateLabel = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('invoice-form-date')),
          matching: find.byType(Text),
        ),
      );
      expect(dateLabel.data, matches(RegExp(r'^\d{2}/\d{2}/\d{4}$')));
      // Round-trip the display label to the ISO the API must receive. The
      // picker opens on the current month, so derive instead of hardcoding.
      final picked = dateLabel.data!.split('/');
      final expectedIso = '${picked[2]}-${picked[1]}-${picked[0]}';
      // No ISO date anywhere in the rendered UI.
      expect(find.text(expectedIso), findsNothing);

      // Pick the invoice client.
      await tester.tap(find.byKey(const Key('invoice-form-pick-client')));
      await tester.pumpAndSettle();
      // Scope to the picker option: the list rows behind also show the
      // same client name.
      await tester.tap(find.byKey(const Key('invoice-client-option-ic1')));
      await tester.pumpAndSettle();

      // Add a free-text line.
      await tester.tap(find.byKey(const Key('invoice-form-add-line')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invoice-line-description')),
        'Service',
      );
      await tester.enterText(find.byKey(const Key('invoice-line-qty')), '1');
      await tester.enterText(
        find.byKey(const Key('invoice-line-price')),
        '100',
      );
      await tester.tap(find.byKey(const Key('invoice-line-tva')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('0%').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invoice-line-submit')));
      await tester.pumpAndSettle();

      // Form line preview: unit price is money (exactly one DA), quantity
      // stays suffix-free — a suffixed quantity would render '1 DA × ...'.
      final lineTile = find.byKey(const Key('invoice-form-line-0'));
      final lineTexts = tester.widgetList<Text>(
        find.descendant(of: lineTile, matching: find.byType(Text)),
      );
      final subtitle = lineTexts.last.data ?? '';
      expect(subtitle, contains('1 × 100 DA'));
      expect(
        subtitle,
        contains('${AppStrings.t('line_total', 'en')}: 100 DA'),
      );

      // Run the preview — this sends the create payload.
      await tester.tap(find.byKey(const Key('invoice-form-preview-button')));
      await tester.pumpAndSettle();

      // The POST /factures/preview body must carry an ISO document_date.
      final previewPost = postLog.lastWhere(
        (p) => p['path'] == '$_facturesPath/preview',
      );
      final body = previewPost['data'] as Map<String, dynamic>;
      expect(body['document_date'], expectedIso);
      expect(body['document_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));

      // Preview totals are money surfaces too — exactly one DA each.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-total-total_ht')))
            .data,
        '100 DA',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-form-total-net_a_payer')),
            )
            .data,
        '101 DA',
      );
    });

    testWidgets(
        'preview and create carry the chosen unit price + register_as_sale',
        (tester) async {
      final dio = MockDio();
      final postLog = <Map<String, dynamic>>[];
      stubRequests(
        dio,
        postLog: postLog,
        productItems: [
          {
            'id': 'prod-1',
            'name': 'Kawkaw',
            'barcode': null,
            'sku': null,
            'description': null,
            'unit': 'piece',
            'price': '500',
            'cost': 0,
            'avg_cost': 0,
            'quantity': 50,
            'low_stock_threshold': 5,
            'allow_negative_stock': false,
            'wholesale_price': '400',
            'wholesale_min_qty': '10',
            'vat_rate': 0,
            'promotion': null,
            'expiry_date': null,
            'image_path': null,
            'category_id': null,
            'category_name': null,
            'is_archived': false,
          },
        ],
      );

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'en'),
        locale: AppLocale.en,
      );

      // Open the create form.
      await tester.tap(find.byKey(const Key('facturation-add-button')));
      await tester.pumpAndSettle();

      // Pick a date (same flow as the ISO test).
      await tester.tap(find.byKey(const Key('invoice-form-date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Pick the invoice client.
      await tester.tap(find.byKey(const Key('invoice-form-pick-client')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invoice-client-option-ic1')));
      await tester.pumpAndSettle();

      // Product line at the WHOLESALE reference price (field drives all
      // totals — 3 × 400).
      await tester.tap(find.byKey(const Key('invoice-form-add-line')));
      await tester.pumpAndSettle();
      expect(find.text('Unit Price (DA)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('invoice-line-pick-product')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('facturation-product-option-prod-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invoice-line-ref-wholesale')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('invoice-line-qty')), '3');
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-line-submit')));
      await tester.pumpAndSettle();

      // The form's line tile shows the chosen price.
      final lineTexts = tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('invoice-form-line-0')),
          matching: find.byType(Text),
        ),
      );
      expect(lineTexts.last.data, contains('3 × 400 DA'));

      // Preview — the REQUEST carries the chosen price.
      await tester.tap(find.byKey(const Key('invoice-form-preview-button')));
      await tester.pumpAndSettle();

      final previewPost = postLog.lastWhere(
        (p) => p['path'] == '$_facturesPath/preview',
      );
      final previewBody = previewPost['data'] as Map<String, dynamic>;
      final previewLines = previewBody['lines'] as List<dynamic>;
      expect(previewLines, hasLength(1));
      expect(previewLines.first['product_id'], 'prod-1');
      expect(previewLines.first['unit_price_ht'], '400');
      expect(previewLines.first['quantity'], '3');

      // Register as a POS sale and submit — the create body must carry
      // the SAME price the preview showed (no silent repricing) and the
      // register_as_sale flag the dialog promises.
      await tester.tap(find.byKey(const Key('invoice-form-register-as-sale')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('invoice-form-submit')));
      await tester.pumpAndSettle();

      final createPost = postLog.lastWhere((p) => p['path'] == _facturesPath);
      final createBody = createPost['data'] as Map<String, dynamic>;
      expect(createBody['register_as_sale'], isTrue);
      final createLines = createBody['lines'] as List<dynamic>;
      expect(createLines, hasLength(1));
      expect(createLines.first['product_id'], 'prod-1');
      expect(createLines.first['unit_price_ht'], '400');
      expect(createLines.first['quantity'], '3');
      expect(tester.takeException(), isNull);
    });

    testWidgets('update payload never carries document_date (edit mode)',
        (tester) async {
      final dio = MockDio();
      final putLog = <Map<String, dynamic>>[];
      stubRequests(dio, putLog: putLog);

      await pumpApp(
        tester,
        dio,
        navLabel: AppStrings.t('facturation', 'ar'),
      );

      await tester.tap(find.byKey(const Key('facturation-tile-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invoice-detail-edit')));
      await tester.pumpAndSettle();

      // Display stays DD/MM/YYYY right up to submit.
      final identity = tester.widget<Text>(
        find.byKey(const Key('invoice-form-identity')),
      );
      expect(identity.data, contains('15/03/2026'));

      await tester.tap(find.byKey(const Key('invoice-form-submit')));
      await tester.pumpAndSettle();

      // PUT /factures/{id} — document_date is immutable identity and must
      // never be serialized, display-formatted or otherwise.
      expect(putLog, hasLength(1));
      expect(putLog.single['path'], '$_facturesPath/d1');
      final body = putLog.single['data'] as Map<String, dynamic>;
      expect(body.containsKey('document_date'), isFalse);
      expect(
        body.keys.where((k) => k.contains('date')), // no date field at all
        isEmpty,
      );
      expect(body['client_id'], 'ic1');
    });
  });
}
