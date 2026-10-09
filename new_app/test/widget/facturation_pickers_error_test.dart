// Phase 10 Stage B — facturation picker error localization.
//
// The invoice-client and product pickers used to render the raw backend
// `error.message` (English) as the primary error line. They now route
// through the established mappers (`invoiceClientsApiError` /
// `facturationApiError`): the primary line is ALWAYS localized; the raw
// backend text travels as the secondary `detail` line only — the same
// contract as invoice_form_dialog.dart.
//
// Both pickers are self-contained (dio owned locally), so these tests
// pump the dialog widgets directly — no login flow required.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/facturation/facturation_pickers.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

DioException _envelopeError({
  required String path,
  required int status,
  required String code,
  required String message,
}) {
  final requestOptions = RequestOptions(path: path);
  return DioException(
    requestOptions: requestOptions,
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: requestOptions,
      statusCode: status,
      data: {
        'error': {
          'code': code,
          'message_key': 'errors.${code.toLowerCase()}',
          'message': message,
          'details': <String, dynamic>{},
          'request_id': null,
        },
      },
    ),
  );
}

DioException _networkError(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionTimeout,
    );

void _stubFailingGet(MockDio dio, DioException error) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  // Async throw: real Dio failures complete the returned Future, they do
  // not throw synchronously — mirrors production and keeps the catch out
  // of initState.
  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((_) async => throw error);
}

void _stubSuccessfulGet(MockDio dio, Map<String, dynamic> body) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer(
    (_) async => Response(
      requestOptions: RequestOptions(path: '/any'),
      statusCode: 200,
      data: body,
    ),
  );
}

Future<void> _pumpPicker(
  WidgetTester tester,
  Widget child, {
  required String localeCode,
  required MockDio dio,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(dio: dio))],
      child: MaterialApp(
        locale: Locale(localeCode),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('InvoiceClientPicker error localization', () {
    testWidgets('403 FORBIDDEN shows localized Arabic primary, raw as detail',
        (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _envelopeError(
          path: '/api/v1/invoice-clients',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Permission denied: facturation_view',
        ),
      );

      await _pumpPicker(
        tester,
        const InvoiceClientPicker(),
        localeCode: 'ar',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('invoice-client-picker-error')),
      );
      expect(primary.data, AppStrings.t('permission_denied', 'ar'));
      expect(primary.data, isNot('Permission denied: facturation_view'));

      final detail = tester.widget<Text>(
        find.byKey(const Key('invoice-client-picker-error-detail')),
      );
      expect(detail.data, 'Permission denied: facturation_view');
      expect(tester.takeException(), isNull);
    });

    testWidgets('403 FORBIDDEN shows localized English primary', (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _envelopeError(
          path: '/api/v1/invoice-clients',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Permission denied: facturation_view',
        ),
      );

      await _pumpPicker(
        tester,
        const InvoiceClientPicker(),
        localeCode: 'en',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('invoice-client-picker-error')),
      );
      expect(primary.data, AppStrings.t('permission_denied', 'en'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('network failure keeps the localized network message',
        (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _networkError('/api/v1/invoice-clients'),
      );

      await _pumpPicker(
        tester,
        const InvoiceClientPicker(),
        localeCode: 'ar',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('invoice-client-picker-error')),
      );
      expect(primary.data, AppStrings.t('network_error_retry', 'ar'));
      expect(
        find.byKey(const Key('invoice-client-picker-error-detail')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('successful load still lists clients and selection pops the '
        'model (regression)', (tester) async {
      final dio = MockDio();
      _stubSuccessfulGet(dio, {
        'items': [
          {
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
          },
        ],
        'total': 1,
        'page': 1,
        'page_size': 40,
        'pages': 1,
      });

      await _pumpPicker(
        tester,
        const InvoiceClientPicker(),
        localeCode: 'ar',
        dio: dio,
      );

      expect(find.byKey(const Key('invoice-client-picker-list')), findsOneWidget);
      expect(find.text('SARL Example'), findsOneWidget);
      expect(
        find.byKey(const Key('invoice-client-picker-error')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('invoice-client-option-ic1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('FacturationProductPicker error localization', () {
    testWidgets('401 UNAUTHORIZED shows localized Arabic primary, raw as '
        'detail', (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _envelopeError(
          path: '/api/v1/products/search',
          status: 401,
          code: 'UNAUTHORIZED',
          message: 'Missing authentication token',
        ),
      );

      await _pumpPicker(
        tester,
        const FacturationProductPicker(),
        localeCode: 'ar',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('facturation-product-picker-error')),
      );
      expect(primary.data, AppStrings.t('session_expired_login', 'ar'));
      expect(primary.data, isNot('Missing authentication token'));

      final detail = tester.widget<Text>(
        find.byKey(const Key('facturation-product-picker-error-detail')),
      );
      expect(detail.data, 'Missing authentication token');
      expect(tester.takeException(), isNull);
    });

    testWidgets('401 UNAUTHORIZED shows localized English primary',
        (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _envelopeError(
          path: '/api/v1/products/search',
          status: 401,
          code: 'UNAUTHORIZED',
          message: 'Missing authentication token',
        ),
      );

      await _pumpPicker(
        tester,
        const FacturationProductPicker(),
        localeCode: 'en',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('facturation-product-picker-error')),
      );
      expect(primary.data, AppStrings.t('session_expired_login', 'en'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('403 FORBIDDEN maps to permission_denied in French (LTR)',
        (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _envelopeError(
          path: '/api/v1/products/search',
          status: 403,
          code: 'FORBIDDEN',
          message: 'Permission denied: product_view',
        ),
      );

      await _pumpPicker(
        tester,
        const FacturationProductPicker(),
        localeCode: 'fr',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('facturation-product-picker-error')),
      );
      expect(primary.data, AppStrings.t('permission_denied', 'fr'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('network failure keeps the localized network message',
        (tester) async {
      final dio = MockDio();
      _stubFailingGet(
        dio,
        _networkError('/api/v1/products/search'),
      );

      await _pumpPicker(
        tester,
        const FacturationProductPicker(),
        localeCode: 'ar',
        dio: dio,
      );

      final primary = tester.widget<Text>(
        find.byKey(const Key('facturation-product-picker-error')),
      );
      expect(primary.data, AppStrings.t('network_error_retry', 'ar'));
      expect(
        find.byKey(const Key('facturation-product-picker-error-detail')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
