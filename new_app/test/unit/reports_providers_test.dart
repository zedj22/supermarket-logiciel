// Phase 14 report providers (§8 common parameters, §11 query contract).
//
// Gates covered here: preset → range serialization (§6 inclusive local
// dates), device filter add/clear, per-tab query params (sort/page/
// status/payment/lookback/days), clamping of window parameters, the
// request-id staleness guard, shared-filter reloads only for initialized
// tabs, and localized error mapping (envelope codes §11).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/dashboard/dashboard_providers.dart';
import 'package:supermarket_pos/features/reports/reports_providers.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

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

  Map<String, dynamic> financialJson() => <String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'gross_sales': '100.000',
        'net_sales': '90.000',
        'device_breakdown': <dynamic>[],
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

  group('ReportFilter (§6 / §8 common parameters)', () {
    test('fromPreset resolves the four basic presets against the clock', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final t = ReportFilter.fromPreset('today');
      expect(t.dateFrom, today);
      expect(t.dateTo, today);

      final y = ReportFilter.fromPreset('yesterday');
      expect(y.dateFrom, today.subtract(const Duration(days: 1)));
      expect(y.dateTo, today.subtract(const Duration(days: 1)));

      final w = ReportFilter.fromPreset('last_7_days');
      expect(w.dateFrom, today.subtract(const Duration(days: 6)));
      expect(w.dateTo, today);
      expect(w.dateTo.difference(w.dateFrom).inDays, 6);

      final m = ReportFilter.fromPreset('this_month');
      expect(m.dateFrom, DateTime(now.year, now.month, 1));
      expect(m.dateTo, today);
    });

    test('fromPreset resolves every preset for reference date 2026-10-01',
        () {
      final ref = DateTime(2026, 10, 1);

      // Today = 10-01 → 10-01.
      final t = ReportFilter.fromPreset('today', now: ref);
      expect(t.dateFrom, DateTime(2026, 10, 1));
      expect(t.dateTo, DateTime(2026, 10, 1));

      // Yesterday = 09-30 → 09-30.
      final y = ReportFilter.fromPreset('yesterday', now: ref);
      expect(y.dateFrom, DateTime(2026, 9, 30));
      expect(y.dateTo, DateTime(2026, 9, 30));

      // Last 7 days = today − 6 → today (09-25 → 10-01, inclusive).
      final w = ReportFilter.fromPreset('last_7_days', now: ref);
      expect(w.dateFrom, DateTime(2026, 9, 25));
      expect(w.dateTo, DateTime(2026, 10, 1));

      // This month = 1st → today (10-01 → 10-01 while still partial).
      final tm = ReportFilter.fromPreset('this_month', now: ref);
      expect(tm.dateFrom, DateTime(2026, 10, 1));
      expect(tm.dateTo, DateTime(2026, 10, 1));

      // Last month = previous COMPLETE calendar month (09-01 → 09-30),
      // never a rolling 30-day window.
      final lm = ReportFilter.fromPreset('last_month', now: ref);
      expect(lm.dateFrom, DateTime(2026, 9, 1));
      expect(lm.dateTo, DateTime(2026, 9, 30));

      // Last 3 months = 3 complete months excluding the current one
      // (07-01 → 09-30).
      final l3 = ReportFilter.fromPreset('last_3_months', now: ref);
      expect(l3.dateFrom, DateTime(2026, 7, 1));
      expect(l3.dateTo, DateTime(2026, 9, 30));

      // Last 6 months = 6 complete months excluding the current one
      // (04-01 → 09-30).
      final l6 = ReportFilter.fromPreset('last_6_months', now: ref);
      expect(l6.dateFrom, DateTime(2026, 4, 1));
      expect(l6.dateTo, DateTime(2026, 9, 30));
    });

    test('month presets stay complete and ordered at year boundaries', () {
      // January: "last month" crosses into the previous year.
      final jan = DateTime(2026, 1, 15);
      final lm = ReportFilter.fromPreset('last_month', now: jan);
      expect(lm.dateFrom, DateTime(2025, 12, 1));
      expect(lm.dateTo, DateTime(2025, 12, 31));
      final l3 = ReportFilter.fromPreset('last_3_months', now: jan);
      expect(l3.dateFrom, DateTime(2025, 10, 1));
      expect(l3.dateTo, DateTime(2025, 12, 31));
      final l6 = ReportFilter.fromPreset('last_6_months', now: jan);
      expect(l6.dateFrom, DateTime(2025, 7, 1));
      expect(l6.dateTo, DateTime(2025, 12, 31));

      // First day of a month still resolves last_month to the month
      // before that one (not the current partial month).
      final feb = DateTime(2026, 2, 1);
      final lmFeb = ReportFilter.fromPreset('last_month', now: feb);
      expect(lmFeb.dateFrom, DateTime(2026, 1, 1));
      expect(lmFeb.dateTo, DateTime(2026, 1, 31));

      // from <= to for every preset across several references.
      for (final ref in <DateTime>[
        DateTime(2026, 10, 1),
        DateTime(2026, 1, 1),
        DateTime(2026, 1, 31),
        DateTime(2026, 12, 31),
        DateTime(2028, 3, 15), // leap year
      ]) {
        for (final preset in kReportPresets) {
          final f = ReportFilter.fromPreset(preset, now: ref);
          expect(
            f.dateFrom.isAfter(f.dateTo),
            isFalse,
            reason: 'reversed range for $preset @ $ref',
          );
        }
      }
    });

    test('rangeParams serializes yyyy-MM-dd and adds device only when set',
        () {
      final filter = ReportFilter(
        preset: 'custom',
        dateFrom: DateTime(2026, 9, 1),
        dateTo: DateTime(2026, 9, 30),
      );
      expect(filter.rangeParams(), <String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
      });

      final withDevice = ReportFilter(
        preset: 'custom',
        dateFrom: DateTime(2026, 9, 1),
        dateTo: DateTime(2026, 9, 30),
        deviceId: 'POS-1',
      );
      expect(withDevice.rangeParams()['device_id'], 'POS-1');
      expect(ReportFilter.initial().rangeParams()['date_from'],
          reportDateParam(DateTime.now()));
    });

    test('notifier: presets preserve device, custom range clamps bounds', () {
      final notifier = ReportFilterNotifier();
      notifier.setDevice(' POS-1 ');
      expect(notifier.state.deviceId, 'POS-1');

      notifier.setPreset('yesterday');
      expect(notifier.state.preset, 'yesterday');
      expect(notifier.state.deviceId, 'POS-1', reason: 'device survives preset');

      // Picking a start after the current end drags the end along.
      final far = notifier.state.dateTo.add(const Duration(days: 3));
      notifier.setDateFrom(far);
      expect(notifier.state.preset, 'custom');
      expect(notifier.state.dateTo, far);

      notifier.setDevice('');
      expect(notifier.state.deviceId, isNull);

      notifier.reset();
      expect(notifier.state.preset, 'today');
      expect(notifier.state.deviceId, isNull);
    });

    test('setPreset applies preset + both bounds atomically', () {
      final notifier = ReportFilterNotifier();
      notifier.setDevice('POS-1');

      // One state change carries the preset AND the full resolved range —
      // no intermediate state can hold a stale or reversed pair.
      notifier.setPreset('last_month');
      expect(
        notifier.state,
        ReportFilter.fromPreset('last_month', deviceId: 'POS-1'),
      );
      expect(notifier.state.preset, 'last_month');
      expect(
        notifier.state.dateFrom.isBefore(notifier.state.dateTo) ||
            notifier.state.dateFrom.isAtSameMomentAs(notifier.state.dateTo),
        isTrue,
        reason: 'from <= to after preset switch',
      );

      notifier.setPreset('last_6_months');
      expect(
        notifier.state,
        ReportFilter.fromPreset('last_6_months', deviceId: 'POS-1'),
      );
      expect(
        notifier.state.dateTo.isBefore(
          notifier.state.dateFrom.add(const Duration(days: 366)),
        ),
        isTrue,
      );
    });
  });

  group('sort labels (§8 R2)', () {
    test('every sort option maps to a real column key', () {
      expect(reportSortKey('net_revenue'), 'col_net_revenue');
      expect(reportSortKey('qty_sold'), 'col_qty');
      expect(reportSortKey('gross_profit'), 'col_gross_profit');
      expect(reportSortKey('return_qty'), 'col_returns_qty');
      expect(reportSortKey('margin_pct'), 'col_margin');
      expect(reportSortKey('bogus'), 'col_net_revenue');
    });
  });

  group('tab controllers (§11 query contract)', () {
    test('financial loads the endpoint with the shared range', () async {
      final dio = MockDio();
      Map<String, dynamic>? seenParams;
      String? seenPath;
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        seenPath = invocation.positionalArguments.first as String;
        seenParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>;
        return okResponse(seenPath!, financialJson());
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(financialProvider.notifier).load();
      final state = container.read(financialProvider);
      expect(seenPath, '/api/v1/reports/financial');
      expect(seenParams!['date_from'], reportDateParam(DateTime.now()));
      expect(seenParams!['date_to'], reportDateParam(DateTime.now()));
      expect(state.error, isNull);
      expect(state.data!.grossSales, '100.000');
      expect(state.loading, isFalse);
    });

    test('products params carry sort + pagination and setSort resets page',
        () async {
      final dio = MockDio();
      final pages = <Map<String, dynamic>>[];
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        pages.add(Map<String, dynamic>.from(
            invocation.namedArguments[#queryParameters] as Map));
        return okResponse('/api/v1/reports/products', <String, dynamic>{
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 100,
          'pages': 1,
          'totals': <String, dynamic>{},
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);
      final controller = container.read(productsProvider.notifier);

      await controller.load();
      expect(pages.last['sort'], 'net_revenue');
      expect(pages.last['page'], 1);
      expect(pages.last['page_size'], kReportPageSize);

      controller.setPage(3);
      await container.read(productsProvider.notifier).load();
      expect(pages.last['page'], 3);

      controller.setSort('margin_pct');
      await container.read(productsProvider.notifier).load();
      expect(pages.last['sort'], 'margin_pct');
      expect(pages.last['page'], 1, reason: 'sort change resets pagination');
    });

    test('peak-hours sends lookback only (clamped 1..90), no date range',
        () async {
      final dio = MockDio();
      Map<String, dynamic>? seenParams;
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        seenParams = Map<String, dynamic>.from(
            invocation.namedArguments[#queryParameters] as Map);
        return okResponse('/api/v1/reports/peak-hours', <String, dynamic>{
          'lookback_days': 30,
          'items': <dynamic>[],
          'totals': <String, dynamic>{},
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);
      final controller = container.read(peakProvider.notifier);

      controller.setLookback(0);
      await container.read(peakProvider.notifier).load();
      expect(seenParams!['lookback_days'], 1);

      controller.setLookback(400);
      await container.read(peakProvider.notifier).load();
      expect(seenParams!['lookback_days'], 90);
      expect(seenParams!.containsKey('date_from'), isFalse);
      expect(seenParams!.containsKey('date_to'), isFalse);
    });

    test('slow-moving clamps days/threshold and pages', () async {
      final dio = MockDio();
      Map<String, dynamic>? seenParams;
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        seenParams = Map<String, dynamic>.from(
            invocation.namedArguments[#queryParameters] as Map);
        return okResponse('/api/v1/reports/slow-moving', <String, dynamic>{
          'days': 30,
          'threshold': 0,
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 100,
          'pages': 1,
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);
      final controller = container.read(slowMovingProvider.notifier);

      controller.setDays(0);
      await container.read(slowMovingProvider.notifier).load();
      expect(seenParams!['days'], 1);

      controller.setDays(999);
      controller.setThreshold(-5);
      await container.read(slowMovingProvider.notifier).load();
      expect(seenParams!['days'], 365);
      expect(seenParams!['threshold'], 0);
      expect(seenParams!['page'], 1);
    });

    test('sales params: default status, optional payment, page reset', () async {
      final dio = MockDio();
      final pages = <Map<String, dynamic>>[];
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        pages.add(Map<String, dynamic>.from(
            invocation.namedArguments[#queryParameters] as Map));
        return okResponse('/api/v1/reports/sales', <String, dynamic>{
          'items': <dynamic>[],
          'total': 0,
          'page': 1,
          'page_size': 100,
          'pages': 1,
          'totals': <String, dynamic>{},
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);
      final controller = container.read(salesProvider.notifier);

      await controller.load();
      expect(pages.last['status'], 'completed');
      expect(pages.last.containsKey('payment_method'), isFalse);

      controller.setPaymentMethod('card');
      await container.read(salesProvider.notifier).load();
      expect(pages.last['payment_method'], 'card');
      expect(pages.last['page'], 1);

      controller.setPage(4);
      controller.setStatus('all');
      await container.read(salesProvider.notifier).load();
      expect(pages.last['status'], 'all');
      expect(pages.last['page'], 1, reason: 'status change resets page');
    });
  });

  group('error mapping (§11 codes)', () {
    DioException envelope(int status, String code) {
      const path = '/api/v1/reports/financial';
      return DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: status,
          data: <String, dynamic>{
            'error': <String, dynamic>{
              'code': code,
              'message': 'raw backend text',
            },
          },
        ),
      );
    }

    test('REPORT_* envelope codes map to their localized headline', () async {
      final dio = MockDio();
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenThrow(envelope(422, 'REPORT_RANGE_TOO_WIDE'));

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(financialProvider.notifier).load();
      final state = container.read(financialProvider);
      expect(state.data, isNull);
      expect(state.error, AppStrings.t('report_range_too_wide', 'ar'));
      expect(state.error, isNot('report_range_too_wide'));
    });

    test('FORBIDDEN maps to permission_denied (403 behavior, §10)', () async {
      final dio = MockDio();
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenThrow(envelope(403, 'FORBIDDEN'));

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(financialProvider.notifier).load();
      expect(container.read(financialProvider).error,
          AppStrings.t('permission_denied', 'ar'));
    });

    test('connection failure maps to the network message', () async {
      final dio = MockDio();
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenThrow(DioException.connectionError(
        requestOptions: RequestOptions(path: '/api/v1/reports/financial'),
        reason: 'refused',
      ));

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(financialProvider.notifier).load();
      expect(container.read(financialProvider).error,
          AppStrings.t('network_error_retry', 'ar'));
    });
  });

  group('staleness + shared filter', () {
    test('a late response from an older request is dropped', () async {
      final dio = MockDio();
      final completers = <Completer<Response<dynamic>>>[];
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) {
        final completer = Completer<Response<dynamic>>();
        completers.add(completer);
        return completer.future;
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);
      final controller = container.read(financialProvider.notifier);

      final first = controller.load();
      final second = controller.load();
      expect(completers, hasLength(2));

      // Newest request completes first…
      completers[1].complete(okResponse(
          '/api/v1/reports/financial', {'gross_sales': 'NEW'}));
      await second;
      expect(container.read(financialProvider).data!.grossSales, 'NEW');

      // …then the stale one arrives and must be ignored.
      completers[0].complete(okResponse(
          '/api/v1/reports/financial', {'gross_sales': 'STALE'}));
      await first;
      expect(container.read(financialProvider).data!.grossSales, 'NEW');
    });

    test('changing the shared filter reloads initialized tabs only', () async {
      final dio = MockDio();
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        final path = invocation.positionalArguments.first as String;
        if (path.endsWith('/financial')) {
          return okResponse(path, financialJson());
        }
        return okResponse(path, <String, dynamic>{
          'items': <dynamic>[],
          'totals': <String, dynamic>{},
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      // Open the financial tab…
      await container.read(financialProvider.notifier).load();
      verify(() => dio.get('/api/v1/reports/financial',
              queryParameters: any(named: 'queryParameters')))
          .called(1);

      // …then flip the preset: initialized tabs reload, unopened ones
      // (products) must not fire a request.
      container.read(reportFilterProvider.notifier).setPreset('yesterday');
      await Future<void>.delayed(Duration.zero);
      verify(() => dio.get('/api/v1/reports/financial',
              queryParameters: any(named: 'queryParameters')))
          .called(1);
      verifyNever(() => dio.get('/api/v1/reports/products',
          queryParameters: any(named: 'queryParameters')));
    });
  });

  group('dashboard provider (§7)', () {
    test('loads the snapshot with the shared range', () async {
      final dio = MockDio();
      Map<String, dynamic>? seenParams;
      String? seenPath;
      when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
          .thenAnswer((invocation) async {
        seenPath = invocation.positionalArguments.first as String;
        seenParams = Map<String, dynamic>.from(
            invocation.namedArguments[#queryParameters] as Map);
        return okResponse('/api/v1/dashboard', <String, dynamic>{
          'date_from': '2026-09-30',
          'date_to': '2026-09-30',
          'today_sales': '250.500',
          'today_invoices': 3,
          'today_net_profit': '40.000',
          'today_expenses': '10.000',
          'total_products': 120,
          'total_customers': 15,
          'stock_value': '9000.000',
          'low_stock_count': 4,
          'customers_with_debt': 2,
          'total_debt': '150.000',
          'recent_sales': <dynamic>[
            {
              'sale_id': 's1',
              'invoice_number': 'INV-7',
              'sale_date': '2026-09-30T10:00:00Z',
              'total': '250.500',
              'payment_method': 'cash',
              'customer_name': null,
            },
          ],
          'top_products': <dynamic>[
            {
              'item_id': 'p1',
              'kind': 'product',
              'name': 'Rice 5kg',
              'net_revenue': '80.000',
              'qty_sold': '4',
              'gross_profit': '20.000',
            },
          ],
        });
      });

      final container = makeContainer(dio);
      addTearDown(container.dispose);

      await container.read(dashboardProvider.notifier).load();
      final state = container.read(dashboardProvider);
      expect(seenPath, kDashboardPath);
      expect(seenParams!['date_from'], reportDateParam(DateTime.now()));
      expect(state.error, isNull);
      expect(state.data!.todaySales, '250.500');
      expect(state.data!.todayInvoices, 3);
      expect(state.data!.recentSales.single.invoiceNumber, 'INV-7');
      expect(state.data!.topProducts.single.netRevenue, '80.000');
      expect(state.loading, isFalse);
    });
  });
}
