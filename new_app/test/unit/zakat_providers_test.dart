// Zakat providers — request contract + localized error mapping.
//
// Gates covered: `GET /context` seeding, `POST /calculate` (stateless
// preview), idempotent `POST /zakat` save (client_request_id present),
// history paging append, snapshot detail load, payment POST, and the
// envelope-code → localized message mapping (IDEMPOTENCY_CONFLICT,
// ZAKAT_CALCULATION_NOT_FOUND, 403/422).
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/zakat/zakat_error.dart';
import 'package:supermarket_pos/features/zakat/zakat_models.dart';
import 'package:supermarket_pos/features/zakat/zakat_providers.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  Response<dynamic> okResponse(String path, Object? data, {int status = 200}) =>
      Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        data: data,
        statusCode: status,
      );

  DioException envelope(int status, String code, String path) => DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: status,
          data: <String, dynamic>{
            'error': <String, dynamic>{'code': code, 'message': 'raw'},
          },
        ),
      );

  Map<String, dynamic> contextJson() => <String, dynamic>{
        'store_name': 'Klick',
        'store_phone': '',
        'store_address': '',
        'today': '2026-10-16',
        'official_nisab_reference': {
          'hijri_year': 1447,
          'amount': '2295000.000',
          'gold_price_per_gram': '27000.000',
          'purity': '18k',
          'source': 'AGENOR',
          'note': '',
        },
        'defaults': {
          'zakat_rate': '0.025',
          'hawl_days': 354,
          'nisab_gold_grams': '85',
          'inventory_basis': 'market',
          'debt_treatment': 'deduct_all',
        },
        'inventory': {
          'product_count': 0,
          'total_market_value': '0.000',
          'total_cost_value': '0.000',
          'truncated': false,
          'lines': <dynamic>[],
        },
        'receivables_reference': {
          'ledger_total': '0.000',
          'debtor_count': 0,
          'debtors': <dynamic>[],
        },
        'liabilities_reference': {
          'supplier_balance_total': '0.000',
          'supplier_count': 0,
          'suppliers': <dynamic>[],
        },
      };

  Map<String, dynamic> calculateJson() => <String, dynamic>{
        'store_name': 'Klick',
        'generated_at': '2026-10-16T10:00:00Z',
        'result': <String, dynamic>{
          'zakat_date': '2026-10-16',
          'status': 'final',
          'missing_fields': <dynamic>[],
          'warnings': <dynamic>[
            {'code': 'BELOW_NISAB', 'detail': <String, dynamic>{}},
          ],
          'net_zakatable': '1000.000',
          'zakat_rate': '0.025',
          'zakat_due': '25.000',
          'inventory_basis': 'market',
          'inventory_source': 'imported',
          'debt_treatment': 'deduct_all',
          'nisab_amount': '2295000.000',
          'nisab_source': 'gold_price',
        },
      };

  Map<String, dynamic> detailJson() => <String, dynamic>{
        'id': 'z1',
        'zakat_date': '2026-10-16',
        'status': 'final',
        'net_zakatable': '1000.000',
        'zakat_due': '25.000',
        'payments_total': '0.000',
        'created_at': '2026-10-16T10:00:00Z',
        'result': calculateJson()['result'],
        'inputs': {'zakat_date': '2026-10-16'},
        'payments': <dynamic>[],
      };

  Map<String, dynamic> historyJson({int page = 1, int pages = 1}) =>
      <String, dynamic>{
        'items': [
          {
            'id': 'z$page',
            'zakat_date': '2026-10-1$page',
            'status': 'final',
            'net_zakatable': '1.000',
            'payments_total': '0.000',
            'created_at': '2026-10-16T10:00:00Z',
          },
        ],
        'total': 2,
        'page': page,
        'page_size': kZakatPageSize,
        'pages': pages,
      };

  ProviderContainer makeContainer(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    return ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
      ],
    );
  }

  group('zakatApiError', () {
    test('maps envelope codes to localized messages', () {
      expect(
        zakatApiMessage(
          envelope(409, 'IDEMPOTENCY_CONFLICT', kZakatPath),
          'en',
        ),
        AppStrings.t('zakat_idempotency_conflict', 'en'),
      );
      expect(
        zakatApiMessage(
          envelope(404, 'ZAKAT_CALCULATION_NOT_FOUND', kZakatPath),
          'en',
        ),
        AppStrings.t('zakat_calculation_not_found', 'en'),
      );
      expect(
        zakatApiMessage(envelope(403, 'FORBIDDEN', kZakatPath), 'en'),
        AppStrings.t('permission_denied', 'en'),
      );
      expect(
        zakatApiMessage(envelope(422, 'VALIDATION_ERROR', kZakatPath), 'en'),
        AppStrings.t('validation_error', 'en'),
      );
    });

    test('non-Dio failures fall back to the generic retry', () {
      expect(zakatApiMessage(StateError('boom'), 'ar'), AppStrings.t('api_error_retry', 'ar'));
    });
  });

  group('ZakatContextNotifier', () {
    test('load stores the parsed context', () async {
      final dio = MockDio();
      when(() => dio.get('$kZakatPath/context')).thenAnswer(
        (_) async => okResponse('$kZakatPath/context', contextJson()),
      );
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(zakatContextProvider.notifier).load();
      final state = container.read(zakatContextProvider);
      expect(state.data?.storeName, 'Klick');
      expect(state.data?.defaults.hawlDays, 354);
      expect(state.error, isNull);
    });

    test('failure surfaces a localized message', () async {
      final dio = MockDio();
      when(() => dio.get('$kZakatPath/context')).thenThrow(
        envelope(403, 'FORBIDDEN', '$kZakatPath/context'),
      );
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(zakatContextProvider.notifier).load();
      final state = container.read(zakatContextProvider);
      expect(state.data, isNull);
      expect(state.error, AppStrings.t('permission_denied', 'ar'));
    });
  });

  group('ZakatFormNotifier', () {
    const input = ZakatCalculationInput(
      zakatDate: '2026-10-16',
      goldPricePerGram: '27000',
      cashProvided: true,
      collectibleReceivables: '0',
    );

    test('calculate posts the payload and stores the result', () async {
      final dio = MockDio();
      final bodies = <Map<String, dynamic>>[];
      when(() => dio.post(
            '$kZakatPath/calculate',
            data: any(named: 'data'),
          )).thenAnswer((invocation) async {
        bodies.add(
          Map<String, dynamic>.from(
            invocation.namedArguments[#data]! as Map,
          ),
        );
        return okResponse('$kZakatPath/calculate', calculateJson());
      });
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(zakatFormProvider.notifier).calculate(input);
      final state = container.read(zakatFormProvider);
      expect(state.busy, isFalse);
      expect(state.result?.result.zakatDue, '25.000');
      expect(state.result?.result.warnings.single.labelKey,
          'zakat_warn_below_nisab');
      expect(bodies.single['zakat_date'], '2026-10-16');
      expect(bodies.single['gold_price_per_gram'], '27000');
      expect(state.lastInput?.zakatDate, '2026-10-16');
    });

    test('save sends a client_request_id + calculation and stores the detail',
        () async {
      final dio = MockDio();
      final bodies = <Map<String, dynamic>>[];
      when(() => dio.post(kZakatPath, data: any(named: 'data')))
          .thenAnswer((invocation) async {
        bodies.add(
          Map<String, dynamic>.from(
            invocation.namedArguments[#data]! as Map,
          ),
        );
        return okResponse(kZakatPath, detailJson(), status: 201);
      });
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      final detail =
          await container.read(zakatFormProvider.notifier).save(input);
      expect(detail?.id, 'z1');
      final body = bodies.single;
      final requestId = body['client_request_id'] as String;
      expect(requestId.length, greaterThanOrEqualTo(8));
      expect((body['calculation'] as Map)['zakat_date'], '2026-10-16');
      expect(container.read(zakatFormProvider).saved?.id, 'z1');
    });

    test('save 409 IDEMPOTENCY_CONFLICT maps to the localized conflict',
        () async {
      final dio = MockDio();
      when(() => dio.post(kZakatPath, data: any(named: 'data')))
          .thenThrow(envelope(409, 'IDEMPOTENCY_CONFLICT', kZakatPath));
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      final detail =
          await container.read(zakatFormProvider.notifier).save(input);
      expect(detail, isNull);
      expect(
        container.read(zakatFormProvider).error,
        AppStrings.t('zakat_idempotency_conflict', 'ar'),
      );
    });

    test('recordPayment posts amount/method and refreshes the detail',
        () async {
      final dio = MockDio();
      final bodies = <Map<String, dynamic>>[];
      final paidDetail = detailJson()
        ..['payments_total'] = '10.000'
        ..['payments'] = [
          {
            'id': 'p1',
            'calculation_id': 'z1',
            'amount': '10.000',
            'method': 'cash',
            'paid_at': '2026-10-16',
            'note': null,
            'created_by': 'u1',
            'created_at': '2026-10-16T12:00:00Z',
          },
        ];
      when(() => dio.post(
            '$kZakatPath/z1/payment',
            data: any(named: 'data'),
          )).thenAnswer((invocation) async {
        bodies.add(
          Map<String, dynamic>.from(
            invocation.namedArguments[#data]! as Map,
          ),
        );
        return okResponse('$kZakatPath/z1/payment', paidDetail, status: 201);
      });
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      final detail =
          await container.read(zakatFormProvider.notifier).recordPayment(
                calculationId: 'z1',
                amount: '10.000',
                method: 'cash',
                paidAt: '2026-10-16',
              );
      expect(detail?.paymentsTotal, '10.000');
      expect(detail?.payments.single.amount, '10.000');
      expect(bodies.single['amount'], '10.000');
      expect(bodies.single['method'], 'cash');
      expect(bodies.single['client_request_id'], isNotEmpty);
    });
  });

  group('ZakatHistoryNotifier', () {
    test('refresh loads page 1; loadMore appends the next page', () async {
      final dio = MockDio();
      final requestedPages = <int>[];
      when(() => dio.get(
            kZakatPath,
            queryParameters: any(named: 'queryParameters'),
          )).thenAnswer((invocation) async {
        final params = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>;
        final page = params['page'] as int;
        requestedPages.add(page);
        return okResponse(
          kZakatPath,
          historyJson(page: page, pages: 2),
        );
      });
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      final notifier = container.read(zakatHistoryProvider.notifier);
      await notifier.load(refresh: true);
      var state = container.read(zakatHistoryProvider);
      expect(state.items.single.id, 'z1');
      expect(state.hasMore, isTrue);

      await notifier.loadMore();
      state = container.read(zakatHistoryProvider);
      expect(requestedPages, [1, 2]);
      expect(state.items.map((i) => i.id), ['z1', 'z2']);
      expect(state.hasMore, isFalse);
    });

    test('failure surfaces a localized message', () async {
      final dio = MockDio();
      when(() => dio.get(
            kZakatPath,
            queryParameters: any(named: 'queryParameters'),
          )).thenThrow(envelope(403, 'FORBIDDEN', kZakatPath));
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(zakatHistoryProvider.notifier).load(refresh: true);
      expect(
        container.read(zakatHistoryProvider).error,
        AppStrings.t('permission_denied', 'ar'),
      );
    });
  });

  group('zakatDetailProvider (family)', () {
    test('loads one snapshot by id', () async {
      final dio = MockDio();
      when(() => dio.get('$kZakatPath/z1')).thenAnswer(
        (_) async => okResponse('$kZakatPath/z1', detailJson()),
      );
      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(zakatDetailProvider('z1').notifier).load('z1');
      final state = container.read(zakatDetailProvider('z1'));
      expect(state.data?.id, 'z1');
      expect(state.data?.result.netZakatable, '1000.000');
    });
  });
}
