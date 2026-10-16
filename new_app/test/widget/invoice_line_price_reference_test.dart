// Invoice line dialog — unit price label + reference-price selection.
//
// Contract (facturation price selection):
// - the price field is labeled "Unit Price (DA)" (localized ar/fr/en);
// - a picked product shows its REFERENCE prices (regular, plus wholesale
//   when BOTH wholesale fields are configured with min qty > 0): chips
//   only populate the EDITABLE field — the field is what every line
//   total and document total is computed from;
// - a hand-typed price clears the chip selection (the field always shows
//   what the line will send — no silent repricing of what the user sees);
// - unconfigured wholesale stays visible but DISABLED with an
//   explanation, and wholesale is never offered under a variant option;
// - edit round-trips hydrate GET /products/{id} for the references; on
//   failure the section stays hidden and the line still saves.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/facturation/facturation_models.dart';
import 'package:supermarket_pos/features/facturation/invoice_line_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Mirrors the LTR isolate the app wraps money segments in (W7).
String _m(String v) => bidiIsolateLtr(v);

class FakeCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => true;

  @override
  Future<String?> readToken() async => 'tok';

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => ['admin'];

  @override
  Future<List<String>> readUserPermissions() async => [];

  @override
  Future<void> clearAll() async {}
}

Map<String, dynamic> _productJson({
  String price = '500',
  Object? wholesalePrice = 400,
  Object? wholesaleMinQty = 10,
}) =>
    {
      'id': 'prod-1',
      'name': 'Kawkaw',
      'barcode': null,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
      'cost': 0,
      'avg_cost': 0,
      'quantity': 50,
      'low_stock_threshold': 5,
      'allow_negative_stock': false,
      'wholesale_price': wholesalePrice,
      'wholesale_min_qty': wholesaleMinQty,
      'vat_rate': 0,
      'promotion': null,
      'expiry_date': null,
      'image_path': null,
      'category_id': null,
      'category_name': null,
      'is_archived': false,
    };

Map<String, dynamic> _variantJson() => {
      'id': 'var-1',
      'product_id': 'prod-1',
      'name': 'Big',
      'barcode': null,
      'sku': null,
      'price': '450',
      'cost': null,
      'quantity': 10,
      'is_archived': false,
    };

void _stub(
  MockDio dio, {
  Map<String, dynamic>? searchItem,
  Object? detail,
  bool detailFails = false,
}) {
  Response<dynamic> ok(String path, Object? data) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path.endsWith('/variants')) {
      return ok(path, {'items': [_variantJson()], 'total': 1});
    }
    if (path.endsWith('/products/search')) {
      return ok(path, {
        'items': searchItem == null ? <dynamic>[] : [searchItem],
        'total': searchItem == null ? 0 : 1,
      });
    }
    return ok(path, {'items': <dynamic>[], 'total': 0});
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return ok(path, <String, dynamic>{});
  });
  // Specific-path stub LAST (checked first).
  if (detailFails) {
    when(() => dio.get('/api/v1/products/prod-1')).thenAnswer(
      (_) async => throw DioException(
        requestOptions: RequestOptions(path: '/api/v1/products/prod-1'),
        type: DioExceptionType.connectionTimeout,
      ),
    );
  } else if (detail != null) {
    when(() => dio.get('/api/v1/products/prod-1'))
        .thenAnswer((_) async => ok('/api/v1/products/prod-1', detail));
  }
}

DraftInvoiceLine? _staged;

Future<void> _pumpLineDialog(
  WidgetTester tester, {
  required MockDio dio,
  DraftInvoiceLine? initial,
  AppLocale locale = AppLocale.en,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-dialog'),
              onPressed: () {
                showInvoiceLineDialog(context, initial: initial).then(
                  (value) => _staged = value,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  _staged = null;
  await tester.tap(find.byKey(const Key('open-dialog')));
  await tester.pumpAndSettle();
}

Future<void> _pickProduct(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('invoice-line-pick-product')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('facturation-product-option-prod-1')));
  await tester.pumpAndSettle();
}

Future<void> _pickVariant(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('invoice-line-pick-variant')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('facturation-variant-option-var-1')));
  await tester.pumpAndSettle();
}

String _priceFieldText(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const Key('invoice-line-price')))
        .controller!
        .text;

ChoiceChip _wholesaleChip(WidgetTester tester) => tester.widget<ChoiceChip>(
      find.byKey(const Key('invoice-line-ref-wholesale')),
    );

ChoiceChip _regularChip(WidgetTester tester) => tester.widget<ChoiceChip>(
      find.byKey(const Key('invoice-line-ref-regular')),
    );

Future<DraftInvoiceLine?> _submit(WidgetTester tester) async {
  _staged = null;
  await tester.tap(find.byKey(const Key('invoice-line-submit')));
  await tester.pumpAndSettle();
  return _staged;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets(
      'product line: Unit Price (DA) label, regular + wholesale references, '
      'prefill selects regular', (tester) async {
    final dio = MockDio();
    _stub(dio, searchItem: _productJson());
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);

    expect(find.text('Unit Price (DA)'), findsOneWidget);
    expect(find.byKey(const Key('invoice-line-reference-prices')), findsOneWidget);
    expect(find.text('Reference prices'), findsOneWidget);
    expect(find.text('Regular price: ${_m('500 DA')}'), findsOneWidget);
    expect(find.text('Wholesale price: ${_m('400 DA')}'), findsOneWidget);
    expect(
      find.byKey(const Key('invoice-line-wholesale-min-qty')),
      findsOneWidget,
    );

    // Prefill = the regular reference; the chip marks it.
    expect(_priceFieldText(tester), '500');
    expect(_regularChip(tester).selected, isTrue);
    expect(_wholesaleChip(tester).selected, isFalse);

    // Totals are computed from the FIELD.
    await tester.enterText(find.byKey(const Key('invoice-line-qty')), '3');
    await tester.pump();
    expect(find.text('Line total: ${_m('1 500 DA')}'), findsOneWidget);
  });

  testWidgets(
      'wholesale chip applies wholesale price to the field; line total and '
      'payload follow the field', (tester) async {
    final dio = MockDio();
    _stub(dio, searchItem: _productJson());
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);

    await tester.tap(find.byKey(const Key('invoice-line-ref-wholesale')));
    await tester.pump();

    expect(_priceFieldText(tester), '400');
    expect(_wholesaleChip(tester).selected, isTrue);
    expect(_regularChip(tester).selected, isFalse);

    await tester.enterText(find.byKey(const Key('invoice-line-qty')), '3');
    await tester.pump();
      expect(find.text('Line total: ${_m('1 200 DA')}'), findsOneWidget);

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.unitPriceHt, '400');
    expect(line.toPayload()['unit_price_ht'], '400');
    expect(line.toPayload()['product_id'], 'prod-1');
  });

  testWidgets(
      'hand-typed price keeps its value, drops chip selection, and is what '
      'the line sends', (tester) async {
    final dio = MockDio();
    _stub(dio, searchItem: _productJson());
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);
    expect(_regularChip(tester).selected, isTrue);

    await tester.enterText(
      find.byKey(const Key('invoice-line-price')),
      '450',
    );
    await tester.pump();

    expect(_priceFieldText(tester), '450');
    // The selection must never mask what the field holds.
    expect(_regularChip(tester).selected, isFalse);
    expect(_wholesaleChip(tester).selected, isFalse);

    await tester.enterText(find.byKey(const Key('invoice-line-qty')), '2');
    await tester.pump();
    expect(find.text('Line total: ${_m('900 DA')}'), findsOneWidget);

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.unitPriceHt, '450');
    expect(line.toPayload()['unit_price_ht'], '450');
  });

  testWidgets(
      'unconfigured wholesale: chip disabled with an explanation, regular '
      'still applies', (tester) async {
    final dio = MockDio();
    _stub(
      dio,
      searchItem: _productJson(wholesalePrice: null, wholesaleMinQty: null),
    );
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);

    expect(find.byKey(const Key('invoice-line-ref-wholesale')), findsOneWidget);
    expect(_wholesaleChip(tester).onSelected, isNull);
    expect(
      find.text('Wholesale price not configured for this product'),
      findsOneWidget,
    );
    // Unconfigured chips carry no price suffix.
    expect(find.text('Wholesale price'), findsOneWidget);

    // A tap on a disabled chip never lands on the field.
    await tester.tap(find.byKey(const Key('invoice-line-ref-wholesale')));
    await tester.pump();
    expect(_priceFieldText(tester), '500');

    // The regular reference stays usable.
    await tester.tap(find.byKey(const Key('invoice-line-ref-regular')));
    await tester.pump();
    expect(_priceFieldText(tester), '500');
    expect(_regularChip(tester).selected, isTrue);
  });

  testWidgets('wholesale min qty set without a wholesale price is also '
      'treated as unconfigured', (tester) async {
    final dio = MockDio();
    _stub(
      dio,
      searchItem: _productJson(wholesalePrice: null, wholesaleMinQty: 10),
    );
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);

    expect(_wholesaleChip(tester).onSelected, isNull);
    expect(
      find.text('Wholesale price not configured for this product'),
      findsOneWidget,
    );
  });

  testWidgets('arabic: the price field is labeled سعر الوحدة (دج)',
      (tester) async {
    final dio = MockDio();
    _stub(dio, searchItem: _productJson());
    await _pumpLineDialog(tester, dio: dio, locale: AppLocale.ar);
    await _pickProduct(tester);

    expect(find.text('سعر الوحدة (دج)'), findsOneWidget);
    expect(
      find.byKey(const Key('invoice-line-reference-prices')),
      findsOneWidget,
    );
    expect(find.text('الأسعار المرجعية'), findsOneWidget);
  });

  testWidgets(
      'variant option: regular shows the variant context price, wholesale '
      'is never offered, field keeps the entered price', (tester) async {
    final dio = MockDio();
    _stub(dio, searchItem: _productJson());
    await _pumpLineDialog(tester, dio: dio);
    await _pickProduct(tester);
    await _pickVariant(tester);

    expect(_priceFieldText(tester), '500'); // untouched, no repricing
    expect(_regularChip(tester).selected, isFalse); // selection reset
    expect(find.text('Regular price: ${_m('450 DA')}'), findsOneWidget);
    expect(
      find.byKey(const Key('invoice-line-ref-wholesale')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('invoice-line-wholesale-unavailable')),
      findsNothing,
    );

    await tester.enterText(find.byKey(const Key('invoice-line-qty')), '2');
    await tester.pump();
    expect(find.text('Line total: ${_m('1 000 DA')}'), findsOneWidget);
  });

  testWidgets(
      'edit round-trip hydrates references from GET /products/{id} and '
      'keeps the persisted price', (tester) async {
    final dio = MockDio();
    _stub(dio, detail: _productJson());
    await _pumpLineDialog(
      tester,
      dio: dio,
      initial: const DraftInvoiceLine(
        productId: 'prod-1',
        productName: 'Kawkaw',
        description: 'Kawkaw',
        quantity: '2',
        unitPriceHt: '350',
        tvaRate: 0,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invoice-line-reference-prices')), findsOneWidget);
    expect(find.text('Regular price: ${_m('500 DA')}'), findsOneWidget);
    expect(find.text('Wholesale price: ${_m('400 DA')}'), findsOneWidget);
    // The persisted price is untouched — references are informational
    // until a chip is applied.
    expect(_priceFieldText(tester), '350');
    expect(_regularChip(tester).selected, isFalse);
    expect(_wholesaleChip(tester).selected, isFalse);

    await tester.tap(find.byKey(const Key('invoice-line-ref-regular')));
    await tester.pump();
    expect(_priceFieldText(tester), '500');
  });

  testWidgets(
      'edit round-trip fetch failure hides references but the line still '
      'saves', (tester) async {
    final dio = MockDio();
    _stub(dio, detailFails: true);
    await _pumpLineDialog(
      tester,
      dio: dio,
      initial: const DraftInvoiceLine(
        productId: 'prod-1',
        productName: 'Kawkaw',
        description: 'Kawkaw',
        quantity: '2',
        unitPriceHt: '350',
        tvaRate: 0,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('invoice-line-reference-prices')),
      findsNothing,
    );

    final line = await _submit(tester);
    expect(line, isNotNull);
    expect(line!.unitPriceHt, '350');
    expect(line.toPayload()['unit_price_ht'], '350');
  });

  testWidgets('free-text line has no reference section', (tester) async {
    final dio = MockDio();
    _stub(dio);
    await _pumpLineDialog(tester, dio: dio);

    expect(
      find.byKey(const Key('invoice-line-reference-prices')),
      findsNothing,
    );
    // Free text still uses the same unit-price label.
    expect(find.text('Unit Price (DA)'), findsOneWidget);
  });
}
