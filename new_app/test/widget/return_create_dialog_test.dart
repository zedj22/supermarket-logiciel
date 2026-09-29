// Phase 12 fix round 1 — LINKED return dialog (invoice returns).
//
// Covers: quantity inputs default to the REMAINING returnable quantity
// (sold − already returned from GET /api/v1/returns?sale_id=…), a fully
// returned line starts disabled at 0 with the "fully returned" label,
// an operator edit is what gets submitted, reason is optional (blank
// omitted), exceeding the remaining quantity is rejected before any POST,
// and ar/fr/en localization incl. Arabic RTL.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/returns/return_create_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

const _returnsPath = '/api/v1/returns';

class _HttpLog {
  final gets = <Map<String, dynamic>>[];
  final posts = <Map<String, dynamic>>[];
}

SaleDetailLine _line({
  required String id,
  String quantity = '5',
  String name = 'Coffee 250g',
}) =>
    SaleDetailLine(
      id: id,
      productId: 'p-$id',
      productName: name,
      productUnit: 'piece',
      unitPrice: '120.000',
      unitCost: '60.000',
      quantity: quantity,
      lineDiscount: '0.000',
      lineTotal: '600.000',
    );

SaleDetail _sale({List<SaleDetailLine>? lines}) => SaleDetail(
      id: 'sale-1',
      invoiceNumber: 'INV-20260928-0001',
      status: 'completed',
      subtotal: '600.000',
      discount: '0.000',
      total: '600.000',
      paid: '600.000',
      change: '0.000',
      debt: '0.000',
      paymentMethod: 'cash',
      saleDate: DateTime.parse('2026-09-28T10:00:00Z'),
      lines: lines ?? [_line(id: 'sl-1', quantity: '5')],
    );

Map<String, dynamic> _priorReturnJson({
  required String saleLineId,
  required String quantity,
}) =>
    {
      'id': 'r0',
      'return_number': 'RET-0000',
      'sale_id': 'sale-1',
      'invoice_number': 'INV-20260928-0001',
      'customer_id': null,
      'reason': null,
      'subtotal': '0.000',
      'discount': '0.000',
      'total': '0.000',
      'note': null,
      'return_date': '2026-09-28T09:00:00Z',
      'lines': [
        {
          'id': 'rl-0',
          'sale_line_id': saleLineId,
          'product_id': 'p-$saleLineId',
          'product_name': 'Coffee 250g',
          'product_unit': 'piece',
          'unit_price': '120.000',
          'unit_cost': '60.000',
          'quantity': quantity,
          'quantity_base': quantity,
          'line_discount': '0.000',
          'line_total': '0.000',
        },
      ],
    };

Map<String, dynamic> _createResponseBody() => {
      'return': {
        'id': 'r1',
        'return_number': 'RET-0001',
        'sale_id': 'sale-1',
        'invoice_number': 'INV-20260928-0001',
        'reason': null,
        'subtotal': '600.000',
        'discount': '0.000',
        'total': '600.000',
        'note': null,
        'return_date': '2026-09-28T10:00:00Z',
        'lines': <dynamic>[],
      },
      'idempotent_replay': false,
      'refund_total': '600.000',
      'credit_reversed': '0.000',
      'cash_pending': '600.000',
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
    required _HttpLog log,
    List<Map<String, dynamic>> priorReturns = const [],
  }) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    when(
      () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      log.gets.add({'path': path, ...params});
      if (path == _returnsPath) {
        return okResponse(path, {
          'items': priorReturns,
          'total': priorReturns.length,
          'page': 1,
          'page_size': 100,
          'pages': 1,
        });
      }
      return okResponse(path, {'items': <dynamic>[], 'total': 0});
    });

    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        log.posts.add(
          Map<String, dynamic>.from(
            invocation.namedArguments[#data] as Map,
          ),
        );
        return okResponse(path, _createResponseBody());
      },
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester,
    MockDio dio, {
    SaleDetail? sale,
    AppLocale locale = AppLocale.en,
  }) async {
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final target = sale ?? _sale();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          localeProvider.overrideWith(
            (ref) => LocaleNotifier()..setLocale(locale),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            final appLocale = ref.watch(localeProvider).flutterLocale;
            return MaterialApp(
              locale: appLocale,
              supportedLocales: appSupportedLocales,
              localizationsDelegates: appLocalizationsDelegates,
              home: Scaffold(
                body: Center(
                  child: Builder(
                    builder: (buttonContext) => ElevatedButton(
                      key: const Key('open-dialog'),
                      onPressed: () => showReturnCreateDialog(
                        buttonContext,
                        sale: target,
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.byKey(const Key('return-submit'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  String qtyText(WidgetTester tester, int index) => tester
      .widget<TextField>(find.byKey(Key('return-line-qty-$index')))
      .controller!
      .text;

  group('Linked return dialog (GATE 22 remaining quantity)', () {
    testWidgets('quantity defaults to the full remaining quantity',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);

      expect(find.byKey(const Key('return-create-dialog')), findsOneWidget);
      expect(find.byKey(const Key('return-create-invoice')), findsOneWidget);
      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(qtyText(tester, 0), '5');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-sold-0')))
            .data,
        contains('5'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-remaining-0')))
            .data,
        contains('5'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-returned-0')))
            .data,
        contains('0'),
      );
      expect(find.byKey(const Key('return-line-fully-0')), findsNothing);
      expect(
        log.gets.any(
          (g) =>
              g['path'] == _returnsPath &&
              g['sale_id'] == 'sale-1' &&
              g['page_size'] == 100,
        ),
        isTrue,
      );
    });

    testWidgets('partial prior return reduces the default to what is left',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        priorReturns: [
          _priorReturnJson(saleLineId: 'sl-1', quantity: '2'),
        ],
      );

      await pumpDialog(tester, dio);

      expect(qtyText(tester, 0), '3');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-returned-0')))
            .data,
        contains('2'),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-remaining-0')))
            .data,
        contains('3'),
      );
      expect(find.byKey(const Key('return-line-fully-0')), findsNothing);
    });

    testWidgets('fully returned line starts disabled at 0 with its label',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        priorReturns: [
          _priorReturnJson(saleLineId: 'sl-1', quantity: '5'),
        ],
      );

      await pumpDialog(
        tester,
        dio,
        sale: _sale(
          lines: [
            _line(id: 'sl-1', quantity: '5'),
            _line(id: 'sl-2', quantity: '2', name: 'Milk 1L'),
          ],
        ),
      );

      expect(qtyText(tester, 0), '0');
      expect(
        tester.widget<TextField>(find.byKey(const Key('return-line-qty-0'))).enabled,
        isFalse,
      );
      expect(find.byKey(const Key('return-line-fully-0')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-line-fully-0')))
            .data,
        AppStrings.t('return_fully_returned', 'en'),
      );

      // The untouched second line keeps its own remaining quantity.
      expect(qtyText(tester, 1), '2');
      expect(
        tester.widget<TextField>(find.byKey(const Key('return-line-qty-1'))).enabled,
        isTrue,
      );
    });

    testWidgets('submit without reason: payload omits reason, keeps edits',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);

      // Operator edits the defaulted quantity down to 1.
      await tester.enterText(find.byKey(const Key('return-line-qty-0')), '1');
      await tester.pump();
      await submit(tester);

      expect(log.posts, hasLength(1));
      final payload = log.posts.single;
      expect(payload['sale_id'], 'sale-1');
      expect(payload.containsKey('reason'), isFalse);
      expect('${payload['client_request_id']}', isNotEmpty);
      final lines = payload['lines'] as List<dynamic>;
      expect(lines, hasLength(1));
      expect(lines[0]['sale_line_id'], 'sl-1');
      expect(lines[0]['quantity'], '1');
      expect(find.byKey(const Key('return-create-dialog')), findsNothing);
    });

    testWidgets('reason selected → carried in the payload', (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);

      await tester.tap(find.byKey(const Key('return-reason-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('return-reason-other')));
      await tester.pumpAndSettle();

      await submit(tester);

      expect(log.posts, hasLength(1));
      expect(log.posts.single['reason'], 'other');
    });

    testWidgets('quantity above the remaining amount is rejected',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        priorReturns: [
          _priorReturnJson(saleLineId: 'sl-1', quantity: '2'),
        ],
      );

      await pumpDialog(tester, dio);
      expect(qtyText(tester, 0), '3');

      await tester.enterText(find.byKey(const Key('return-line-qty-0')), '4');
      await tester.pump();
      await submit(tester);

      expect(find.byKey(const Key('return-create-error')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-create-error')))
            .data,
        AppStrings.t('return_qty_exceeds_sold', 'en'),
      );
      expect(log.posts, isEmpty);
    });

    testWidgets('all quantities zero → nothing to return', (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);
      await tester.enterText(find.byKey(const Key('return-line-qty-0')), '0');
      await tester.pump();
      await submit(tester);

      expect(find.byKey(const Key('return-create-error')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-create-error')))
            .data,
        AppStrings.t('return_no_quantity', 'en'),
      );
      expect(log.posts, isEmpty);
    });
  });

  group('Linked return dialog localization', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      testWidgets('title + optional reason + direction for ${locale.name}',
          (tester) async {
        final dio = MockDio();
        final log = _HttpLog();
        stubRequests(dio, log: log);

        await pumpDialog(tester, dio, locale: locale);
        final loc = locale.name;

        expect(
          find.text(AppStrings.t('return_mode_linked', loc)),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('return_reason_none', loc)),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('return_reason_optional', loc)),
          findsOneWidget,
        );

        final direction = Directionality.of(
          tester.element(find.byKey(const Key('return-create-dialog'))),
        );
        expect(
          direction,
          locale == AppLocale.ar ? TextDirection.rtl : TextDirection.ltr,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
