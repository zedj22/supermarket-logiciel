// Phase 12 fix round 1 — Return Products dialog (INDEPENDENT, multi-product).
//
// Covers: search + barcode scan add, merge on repeated add (one line per
// product/variant, never duplicates), quantity editing with the never<=0
// rule, optional reason (blank omitted from the payload — no fake default),
// one POST = ONE return document with N lines, and ar/fr/en localization
// incl. Arabic RTL.
//
// Harness rules shared with returns_screen_test.dart: ONE catch-all GET
// stub dispatched on path (search filtered by the `search` term like the
// server), ONE universal POST stub that captures the payload.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/returns/return_products_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

const _productsPath = '/api/v1/products';
const _barcodePath = '/api/v1/products/barcode-lookup';

class _HttpLog {
  final gets = <Map<String, dynamic>>[];
  final posts = <Map<String, dynamic>>[];
}

Map<String, dynamic> _productJson({
  required String id,
  required String name,
  String price = '120.000',
  String unit = 'piece',
  String barcode = '',
  String quantity = '25',
}) =>
    {
      'id': id,
      'name': name,
      'price': price,
      'unit': unit,
      'quantity': quantity,
      'barcode': barcode,
      'is_active': true,
    };

Map<String, dynamic> _createResponseBody() => {
      'return': {
        'id': 'r1',
        'return_number': 'RET-0001',
        'sale_id': null,
        'invoice_number': null,
        'customer_id': null,
        'reason': null,
        'subtotal': '240.000',
        'discount': '0.000',
        'total': '240.000',
        'note': null,
        'return_date': '2026-09-28T10:00:00Z',
        'lines': <dynamic>[],
      },
      'idempotent_replay': false,
      'refund_total': '240.000',
      'credit_reversed': '0.000',
      'cash_pending': '240.000',
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
    List<Map<String, dynamic>> searchItems = const [],
    Map<String, dynamic>? barcode,
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
      if (path == _barcodePath) {
        return okResponse(path, barcode ?? {'found': false, 'kind': ''});
      }
      if (path == _productsPath) {
        final term = '${params['search'] ?? ''}'.toLowerCase();
        final items = searchItems
            .where((p) => '${p['name']}'.toLowerCase().contains(term))
            .toList();
        return okResponse(path, {
          'items': items,
          'total': items.length,
          'page': 1,
          'page_size': 20,
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
    AppLocale locale = AppLocale.en,
  }) async {
    tester.view.physicalSize = const Size(2400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
                      onPressed: () =>
                          showReturnProductsDialog(buttonContext),
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

  /// Type into the search field and wait out the 300 ms debounce.
  Future<void> search(WidgetTester tester, String term) async {
    await tester.enterText(
      find.byKey(const Key('return-product-search')),
      term,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  Future<void> addResult(WidgetTester tester, int index) async {
    final add = find.byKey(Key('return-product-add-$index'));
    await tester.ensureVisible(add);
    await tester.tap(add);
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

  group('Return Products dialog (independent multi-product)', () {
    testWidgets('opens empty: search, optional reason, no lines yet',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);

      expect(find.byKey(const Key('return-products-dialog')), findsOneWidget);
      expect(find.byKey(const Key('return-product-search')), findsOneWidget);
      expect(find.byKey(const Key('return-reason-select')), findsOneWidget);
      expect(find.byKey(const Key('return-reason-none')), findsOneWidget);
      expect(find.byKey(const Key('return-selected-empty')), findsOneWidget);

      // Submit with nothing selected → localized error, NO request.
      await submit(tester);
      expect(find.byKey(const Key('return-create-error')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-create-error')))
            .data,
        AppStrings.t('return_no_products', 'en'),
      );
      expect(log.posts, isEmpty);
      expect(find.byKey(const Key('return-products-dialog')), findsOneWidget);
    });

    testWidgets('search results add a product with quantity 1',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');

      expect(find.byKey(const Key('return-product-0')), findsOneWidget);
      expect(find.text('Coffee 250g'), findsOneWidget);
      expect(
        log.gets.any(
          (g) => g['path'] == _productsPath && g['search'] == 'Coffee',
        ),
        isTrue,
      );

      await addResult(tester, 0);
      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(qtyText(tester, 0), '1');
      expect(find.byKey(const Key('return-merge-info')), findsNothing);
    });

    testWidgets('repeated add of the same product MERGES into one line',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');
      await addResult(tester, 0);
      await addResult(tester, 0);

      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(find.byKey(const Key('return-line-1')), findsNothing);
      expect(qtyText(tester, 0), '2');
      expect(find.byKey(const Key('return-merge-info')), findsOneWidget);
    });

    testWidgets('two different products become two lines; remove drops one',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
          _productJson(id: 'prod-milk', name: 'Milk 1L', price: '45.000'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');
      await addResult(tester, 0);
      await search(tester, 'Milk');
      await addResult(tester, 0);

      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(find.byKey(const Key('return-line-1')), findsOneWidget);
      expect(find.text('Milk 1L (${AppStrings.unitLabel('piece', 'en')})'),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('return-line-remove-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(find.byKey(const Key('return-line-1')), findsNothing);
      expect(find.text('Coffee 250g (${AppStrings.unitLabel('piece', 'en')})'),
          findsOneWidget);
    });

    testWidgets('quantity steppers: +1/-1, never below 1, typed 0 rejected',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');
      await addResult(tester, 0);

      await tester.tap(find.byKey(const Key('return-line-inc-0')));
      await tester.pump();
      expect(qtyText(tester, 0), '2');

      await tester.tap(find.byKey(const Key('return-line-dec-0')));
      await tester.pump();
      expect(qtyText(tester, 0), '1');

      // At 1 the decrement is disabled — quantity can never reach 0.
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('return-line-dec-0')))
            .onPressed,
        isNull,
      );
      expect(qtyText(tester, 0), '1');

      // Typing 0 is rejected by local validation before any POST.
      await tester.enterText(find.byKey(const Key('return-line-qty-0')), '0');
      await tester.pump();
      await submit(tester);
      expect(find.byKey(const Key('return-create-error')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-create-error')))
            .data,
        AppStrings.t('invalid_qty', 'en'),
      );
      expect(log.posts, isEmpty);
    });

    testWidgets('submit without reason: ONE doc with N lines, no reason key',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
          _productJson(id: 'prod-milk', name: 'Milk 1L', price: '45.000'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');
      await addResult(tester, 0);
      await search(tester, 'Milk');
      await addResult(tester, 0);
      await tester.enterText(find.byKey(const Key('return-line-qty-0')), '3');
      await tester.pump();

      await submit(tester);

      expect(log.posts, hasLength(1));
      final payload = log.posts.single;
      expect(payload.containsKey('reason'), isFalse);
      expect(payload.containsKey('sale_id'), isFalse);
      expect('${payload['client_request_id']}', isNotEmpty);
      final lines = payload['lines'] as List<dynamic>;
      expect(lines, hasLength(2));
      expect(lines[0]['product_id'], 'prod-coffee');
      expect(lines[0]['quantity'], '3');
      expect(lines[0].containsKey('variant_id'), isFalse);
      expect(lines[1]['product_id'], 'prod-milk');
      expect(lines[1]['quantity'], '1');

      expect(find.byKey(const Key('return-products-dialog')), findsNothing);
    });

    testWidgets('reason selected → carried in the payload', (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        searchItems: [
          _productJson(id: 'prod-coffee', name: 'Coffee 250g'),
        ],
      );

      await pumpDialog(tester, dio);
      await search(tester, 'Coffee');
      await addResult(tester, 0);

      await tester.tap(find.byKey(const Key('return-reason-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('return-reason-defective')));
      await tester.pumpAndSettle();

      await submit(tester);

      expect(log.posts, hasLength(1));
      expect(log.posts.single['reason'], 'defective');
      final lines = log.posts.single['lines'] as List<dynamic>;
      expect(lines, hasLength(1));
    });

    testWidgets('variant barcode scan keeps the variant id in the payload',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(
        dio,
        log: log,
        barcode: {
          'found': true,
          'kind': 'variant',
          'product_id': 'p9',
          'product_name': 'Coffee',
          'variant_id': 'v1',
          'variant_name': '500g',
          'product_unit': 'piece',
          'is_archived': false,
        },
      );

      await pumpDialog(tester, dio);
      await tester.enterText(
        find.byKey(const Key('return-product-search')),
        'VAR-1',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('return-line-0')), findsOneWidget);
      expect(find.text('Coffee (500g) (${AppStrings.unitLabel('piece', 'en')})'),
          findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('return-product-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        log.gets.any((g) => g['path'] == _barcodePath),
        isTrue,
      );

      await submit(tester);

      expect(log.posts, hasLength(1));
      final lines = log.posts.single['lines'] as List<dynamic>;
      expect(lines, hasLength(1));
      expect(lines[0]['product_id'], 'p9');
      expect(lines[0]['variant_id'], 'v1');
      expect(lines[0]['quantity'], '1');
    });

    testWidgets('unknown barcode shows localized not-found (never silent)',
        (tester) async {
      final dio = MockDio();
      final log = _HttpLog();
      stubRequests(dio, log: log);

      await pumpDialog(tester, dio);
      await tester.enterText(
        find.byKey(const Key('return-product-search')),
        'NOPE-1',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('return-create-error')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('return-create-error')))
            .data,
        AppStrings.t('return_product_not_found', 'en'),
      );
      expect(find.byKey(const Key('return-line-0')), findsNothing);
      expect(log.posts, isEmpty);
    });
  });

  group('Return Products dialog localization', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      testWidgets('title + reason label + direction for ${locale.name}',
          (tester) async {
        final dio = MockDio();
        final log = _HttpLog();
        stubRequests(dio, log: log);

        await pumpDialog(tester, dio, locale: locale);
        final loc = locale.name;

        expect(
          find.text(AppStrings.t('return_products', loc)),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('return_reason_none', loc)),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('return_no_products', loc)),
          findsOneWidget,
        );

        final direction = Directionality.of(
          tester.element(find.byKey(const Key('return-products-dialog'))),
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
