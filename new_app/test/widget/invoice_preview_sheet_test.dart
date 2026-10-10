// Stage 2 — full invoice preview sheet widget tests.
//
// Harness copied from facturation_screen_test.dart (full-app login flow,
// MockDio). Covers the A4 preview sheet inside the invoice form dialog:
// company/client identity, line items + totals, amount in words, show_*
// column/row visibility, ar/fr/en localization, loading / validation /
// failure states, debounced auto-refresh, and save compatibility.
//
// Every monetary value asserted here originates from the mocked
// POST /factures/preview response — the sheet performs no arithmetic.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
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
const _settingsPath = '/api/v1/settings';

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
      'address': '5 Rue Didouche Mourad',
      'wilaya': 'Alger',
      'phone': '021 23 45 67',
      'nif': '000916000111111',
      'rc': '16/00-1234567 B 21',
      'ai': '000916000333333',
      'nis': '000916000222222',
      'is_archived': false,
      'created_at': null,
      'updated_at': null,
    };

/// Full Stage 1 settings snapshot (company identity for the sheet).
Map<String, dynamic> _settingsBody() => {
      'store_name': 'Supermarket Pro',
      'store_phone': '023 45 67 89',
      'store_address': '12 Rue de la Liberté',
      'invoice_footer': '',
      'store_wilaya': 'Alger',
      'store_email': 'contact@supermarket.dz',
      'store_nif': '1600011111111111',
      'store_nis': '1600022222222222',
      'store_rc': '16/00-9999999 B 99',
      'store_ai': '1600033333333333',
      'store_rib': '0079 1111 2222 3333 44',
      'default_paper': '80mm',
      'ask_before_print': false,
      'auto_print_invoice': false,
      'allow_debt': true,
      'low_stock_threshold': 5,
    };

/// POST /factures/preview response — server-authoritative values.
Map<String, dynamic> _previewBody({
  String number = 'FAC-2026-0042',
  String netAPayer = '120.000',
  String amountInWords = "cent vingt dinars algériens",
  String timbre = '1.000',
}) =>
    {
      'document_date': '2026-03-15',
      'year': 2026,
      'number': number,
      'client_id': 'ic1',
      'client': _clientRef(),
      'lines': [
        {
          'product_id': null,
          'description': 'Service',
          'quantity': '2',
          'unit_price_ht': '50.000',
          'tva_rate': '19.000',
          'discount_pct': '5.000',
          'position': 0,
          'total_ht': '95.000',
          'total_tva': '18.050',
        },
      ],
      'totals': {
        'total_ht': '95.000',
        'total_tva': '18.050',
        'total_ttc': '113.050',
        'timbre': timbre,
        'net_a_payer': netAPayer,
      },
      'amount_in_words': amountInWords,
    };

void stubRequests(
  MockDio dio, {
  List<Map<String, dynamic>>? postLog,
  Map<String, dynamic> Function()? previewBody,
  int failFirstPreviewAfter = 0,
  Future<Response<dynamic>> Function(RequestOptions options)? previewHandler,
  bool settingsLoaded = true,
}) {
  final posts = postLog ?? <Map<String, dynamic>>[];
  var previewAttempts = 0;
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
        previewAttempts++;
        if (previewHandler != null) {
          return previewHandler(
            RequestOptions(path: path, data: data),
          );
        }
        if (previewAttempts <= failFirstPreviewAfter) {
          // Mocktail bypasses Dio's validateStatus — a bad-status
          // Response would be treated as success. Throw like real Dio.
          throw DioException(
            requestOptions: RequestOptions(path: path),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(path: path),
              statusCode: 500,
              data: {'detail': 'preview exploded'},
            ),
          );
        }
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: previewBody?.call() ?? _previewBody(),
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
    if (path == _facturesPath) {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'items': [
            {
              'id': 'd1',
              'doc_type': 'FAC',
              'year': 2026,
              'number': 'FAC-2026-0001',
              'document_date': '2026-03-15',
              'client_id': 'ic1',
              'client': _clientRef(),
              'payment_method': 'cash',
              'notes': null,
              'created_at': '2026-03-15T10:00:00Z',
              'updated_at': null,
            },
          ],
          'total': 1,
          'page': 1,
          'page_size': 40,
          'pages': 1,
        },
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
    return Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: <String, dynamic>{},
    );
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    if (path == _facturesPath) {
      return Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'items': <Map<String, dynamic>>[],
          'total': 0,
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
  when(() => dio.get(_settingsPath)).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: _settingsPath),
      statusCode: 200,
      data: settingsLoaded ? _settingsBody() : <String, dynamic>{},
    ),
  );

  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => Response(
      requestOptions: RequestOptions(
        path: invocation.positionalArguments.first as String,
      ),
      statusCode: 200,
      data: <String, dynamic>{},
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
  AppLocale? locale,
}) async {
  tester.view.physicalSize = const Size(2200, 1400);
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

  await tester.tap(find.text(AppStrings.t('facturation', locale?.name ?? 'ar')));
  await tester.pumpAndSettle();
}

Future<void> _openCreateForm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('facturation-add-button')));
  await tester.pumpAndSettle();
}

Future<void> _pickClient(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('invoice-form-pick-client')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('invoice-client-option-ic1')));
  await tester.pumpAndSettle();
}

Future<void> _addLine(
  WidgetTester tester, {
  String description = 'Service',
  String qty = '2',
  String price = '50',
  String tvaLabel = '19%',
  bool flushPreview = true,
}) async {
  await tester.tap(find.byKey(const Key('invoice-form-add-line')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('invoice-line-description')),
    description,
  );
  await tester.enterText(find.byKey(const Key('invoice-line-qty')), qty);
  await tester.enterText(find.byKey(const Key('invoice-line-price')), price);
  await tester.tap(find.byKey(const Key('invoice-line-tva')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(tvaLabel).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('invoice-line-submit')));
  await tester.pump();
  await tester.pumpAndSettle();
  if (!flushPreview) return;
  // The 350 ms auto-preview debounce needs fake-clock time; a pending
  // Timer schedules no frames, so pumpAndSettle alone can settle before
  // it fires. Flush it explicitly, then let the request land.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Sheet-internal finder: background tiles and form controls repeat the
/// same strings (selected client, doc-type label …), so every sheet text
/// assertion must be scoped to the preview widget.
Finder _inSheet(Finder matching) => find.descendant(
      of: find.byKey(const Key('invoice-form-preview')),
      matching: matching,
    );

int _previewPostCount(List<Map<String, dynamic>> postLog) =>
    postLog.where((p) => p['path'] == '$_facturesPath/preview').length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Invoice preview sheet (Stage 2)', () {
    testWidgets(
        'renders company identity, client, line items, totals, words, '
        'payment and notes from the server preview', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await tester.enterText(
        find.byKey(const Key('invoice-form-notes')),
        'Merci de votre visite',
      );
      await _addLine(tester);
      // The debounced auto-preview lands during pumpAndSettle above.

      final sheet = find.byKey(const Key('invoice-preview-sheet'));
      expect(sheet, findsOneWidget);

      // Company identity (Stage 1 settings snapshot).
      expect(
        _inSheet(find.byKey(const Key('invoice-preview-company-name'))),
        findsOneWidget,
      );
      expect(_inSheet(find.text('Supermarket Pro')), findsOneWidget);
      expect(_inSheet(find.text('12 Rue de la Liberté')), findsOneWidget);
      expect(_inSheet(find.text('Alger')), findsWidgets); // company + client
      expect(_inSheet(find.text('Phone : 023 45 67 89')), findsOneWidget);
      expect(
        _inSheet(find.text('Email : contact@supermarket.dz')),
        findsOneWidget,
      );
      expect(_inSheet(find.text('RC : 16/00-9999999 B 99')), findsOneWidget);
      expect(_inSheet(find.text('NIF : 1600011111111111')), findsOneWidget);
      expect(_inSheet(find.text('AI : 1600033333333333')), findsOneWidget);
      expect(_inSheet(find.text('NIS : 1600022222222222')), findsOneWidget);
      expect(
        _inSheet(find.text('RIB/CCP : 0079 1111 2222 3333 44')),
        findsOneWidget,
      );

      // Title box: localized doc title, proposed number, display date.
      expect(_inSheet(find.text('INVOICE')), findsOneWidget);
      expect(_inSheet(find.text('N° : FAC-2026-0042')), findsOneWidget);
      expect(_inSheet(find.text('Date : 15/03/2026')), findsOneWidget);

      // Client block (live ref from the preview response).
      expect(_inSheet(find.text('SARL Example')), findsOneWidget);
      expect(_inSheet(find.text('5 Rue Didouche Mourad')), findsOneWidget);
      expect(_inSheet(find.text('NIF : 000916000111111')), findsOneWidget);

      // Items table — server-formatted values, DA money, trimmed rates.
      expect(_inSheet(find.text('Description')), findsOneWidget);
      expect(_inSheet(find.text('Unit price excl. tax')), findsOneWidget);
      expect(_inSheet(find.text('Discount %')), findsOneWidget);
      expect(_inSheet(find.text('VAT %')), findsOneWidget);
      expect(_inSheet(find.text('Service')), findsOneWidget);
      expect(_inSheet(find.text('50 DA')), findsOneWidget);
      expect(_inSheet(find.text('5')), findsOneWidget); // trimmed discount
      expect(_inSheet(find.text('19')), findsOneWidget); // trimmed TVA

      // Totals — server values with the Phase 8 widget keys.
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-total-total_ht')))
            .data,
        '95 DA',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-total-total_tva')))
            .data,
        '18.05 DA',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-total-total_ttc')))
            .data,
        '113.05 DA',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-total-timbre')))
            .data,
        '1 DA',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('invoice-form-total-net_a_payer')),
            )
            .data,
        '120 DA',
      );

      // French amount in words, verbatim from the server.
      expect(
        _inSheet(find.text("cent vingt dinars algériens")),
        findsOneWidget,
      );

      // Payment method + notes + signature.
      expect(_inSheet(find.text('Payment Method : Cash')), findsOneWidget);
      expect(
        _inSheet(find.text('Note : Merci de votre visite')),
        findsOneWidget,
      );
      expect(_inSheet(find.text('Signature')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'Remise / TVA columns and TVA / timbre total rows follow the same '
        'show_* rules as the server PDF', (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await _addLine(tester);

      // All flags on: both gated columns and both gated rows present.
      expect(_inSheet(find.text('Discount %')), findsOneWidget);
      expect(_inSheet(find.text('VAT %')), findsOneWidget);
      expect(
        find.byKey(const Key('invoice-form-total-total_tva')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('invoice-form-total-timbre')), findsOneWidget);

      // Hide the discount column → auto-refresh drops it, TVA stays.
      await tester.tap(find.byKey(const Key('invoice-form-show-discount')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('Discount %')), findsNothing);
      expect(_inSheet(find.text('VAT %')), findsOneWidget);

      // Hide TVA → column AND Total VAT row disappear (facture_a4 rule).
      await tester.tap(find.byKey(const Key('invoice-form-show-tva')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('VAT %')), findsNothing);
      expect(
        find.byKey(const Key('invoice-form-total-total_tva')),
        findsNothing,
      );

      // Hide timbre → row disappears (server also zeroes it, but the
      // sheet must not render the row regardless).
      await tester.tap(find.byKey(const Key('invoice-form-show-timbre')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice-form-total-timbre')), findsNothing);

      // Re-enable TVA → column and row return after the refresh.
      await tester.tap(find.byKey(const Key('invoice-form-show-tva')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('VAT %')), findsOneWidget);
      expect(
        find.byKey(const Key('invoice-form-total-total_tva')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('amount in words renders only when the flag is on',
        (tester) async {
      final dio = MockDio();
      stubRequests(dio);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await _addLine(tester);

      expect(_inSheet(find.text("cent vingt dinars algériens")), findsOneWidget);

      await tester.tap(find.byKey(const Key('invoice-form-show-words')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text("cent vingt dinars algériens")), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final locale in [AppLocale.ar, AppLocale.fr]) {
      testWidgets('sheet labels follow the active locale (${locale.name})',
          (tester) async {
        final dio = MockDio();
        stubRequests(dio);

        await pumpApp(tester, dio, locale: locale);
        await _openCreateForm(tester);
        await _pickClient(tester);
        await _addLine(tester);

        final loc = locale.name;
        // Localized document title (backend DOC_TITLE_KEYS parity) —
        // scoped: the doc-type dropdown shows the same string.
        expect(
          _inSheet(find.text(AppStrings.t('doc_facture', loc))),
          findsOneWidget,
        );
        // Localized totals label + net value.
        expect(
          find.byKey(const Key('invoice-form-total-net_a_payer')),
          findsOneWidget,
        );
        expect(
          _inSheet(find.text(AppStrings.t('col_net_a_payer', loc))),
          findsOneWidget,
        );
        expect(
          _inSheet(find.text('120 DA')),
          findsOneWidget,
        );
        // Signature label.
        expect(
          _inSheet(find.text(AppStrings.t('signature', loc))),
          findsOneWidget,
        );
        // Latin-digit date + money regardless of locale.
        expect(
          _inSheet(
            find.text('${AppStrings.t('date', loc)} : 15/03/2026'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('shows a loading state while the preview is in flight, '
        'then the sheet — never a stale one', (tester) async {
      final dio = MockDio();
      final gate = Completer<Response<dynamic>>();
      stubRequests(
        dio,
        previewHandler: (options) => gate.future,
      );

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);

      // Add the line without flushing: pumpAndSettle would hang on the
      // indeterminate progress animation once the gated request starts.
      await _addLine(tester, flushPreview: false);
      // Fire the 350 ms debounce while the gate holds the request open.
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const Key('invoice-form-preview-loading')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('invoice-preview-sheet')), findsNothing);

      gate.complete(
        Response(
          requestOptions: RequestOptions(path: '$_facturesPath/preview'),
          statusCode: 200,
          data: _previewBody(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invoice-form-preview-loading')), findsNothing);
      expect(find.byKey(const Key('invoice-preview-sheet')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an invalid form previews silently: the button reports the '
        'validation error and no request is sent', (tester) async {
      final dio = MockDio();
      final postLog = <Map<String, dynamic>>[];
      stubRequests(dio, postLog: postLog);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);

      // No client yet — auto-preview must stay quiet.
      await tester.pumpAndSettle();
      expect(_previewPostCount(postLog), 0);
      expect(find.byKey(const Key('invoice-form-error')), findsNothing);

      // The explicit button surfaces the reason.
      await tester.tap(find.byKey(const Key('invoice-form-preview-button')));
      await tester.pumpAndSettle();
      expect(_previewPostCount(postLog), 0);
      expect(
        find.byKey(const Key('invoice-form-error')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invoice-form-error')))
            .data,
        AppStrings.t('select_invoice_client', 'en'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed preview shows a recoverable error, never stale '
        'values, and the next run recovers', (tester) async {
      final dio = MockDio();
      stubRequests(dio, failFirstPreviewAfter: 1);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      // Auto-preview (attempt 1) fails inside pumpAndSettle.
      await _addLine(tester);

      expect(find.byKey(const Key('invoice-form-error')), findsOneWidget);
      // No stale sheet, no stale totals keys.
      expect(find.byKey(const Key('invoice-preview-sheet')), findsNothing);
      expect(find.byKey(const Key('invoice-form-total-net_a_payer')), findsNothing);
      // Fallback display-only line is honest about having no preview.
      expect(find.byKey(const Key('invoice-form-display-totals')), findsOneWidget);

      // Manual retry (attempt 2) succeeds → sheet, error cleared.
      await tester.tap(find.byKey(const Key('invoice-form-preview-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invoice-form-error')), findsNothing);
      expect(find.byKey(const Key('invoice-preview-sheet')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('form changes debounce-refresh the preview automatically',
        (tester) async {
      final dio = MockDio();
      final postLog = <Map<String, dynamic>>[];
      stubRequests(dio, postLog: postLog);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await _addLine(tester);

      final afterSetup = _previewPostCount(postLog);
      expect(afterSetup, greaterThanOrEqualTo(1));
      expect(find.byKey(const Key('invoice-preview-sheet')), findsOneWidget);

      // A flag change schedules exactly one more debounced preview.
      await tester.tap(find.byKey(const Key('invoice-form-show-tva')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_previewPostCount(postLog), afterSetup + 1);

      // Notes typing debounces into a single refresh too.
      await tester.enterText(
        find.byKey(const Key('invoice-form-notes')),
        'a',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(_previewPostCount(postLog), afterSetup + 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the save workflow is preserved after a preview (create '
        'POST + success toast)', (tester) async {
      final dio = MockDio();
      final postLog = <Map<String, dynamic>>[];
      stubRequests(dio, postLog: postLog);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await _addLine(tester);
      expect(find.byKey(const Key('invoice-preview-sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('invoice-form-submit')));
      await tester.pumpAndSettle();

      // The create POST fired and the dialog closed with the toast.
      expect(
        postLog.where((p) => p['path'] == _facturesPath),
        hasLength(1),
      );
      expect(find.byKey(const Key('invoice-form-dialog')), findsNothing);
      expect(
        find.byKey(const Key('invoice-form-success-toast')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('without a settings snapshot the company block degrades to '
        'the company_missing hint (never crashes)', (tester) async {
      final dio = MockDio();
      stubRequests(dio, settingsLoaded: false);

      await pumpApp(tester, dio, locale: AppLocale.en);
      await _openCreateForm(tester);
      await _pickClient(tester);
      await _addLine(tester);

      expect(
        _inSheet(find.byKey(const Key('invoice-preview-company-missing'))),
        findsOneWidget,
      );
      expect(
        _inSheet(find.text(AppStrings.t('company_missing', 'en'))),
        findsOneWidget,
      );
      // Fiscal values still render — they come from the preview response.
      expect(_inSheet(find.text('N° : FAC-2026-0042')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
