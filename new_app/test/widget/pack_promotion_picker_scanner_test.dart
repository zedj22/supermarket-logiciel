// Pack + Promotion product-picker barcode scanner regression.
//
// Both dialogs gained the SAME proven integration the Purchase and
// Facturation pickers already use (`BarcodeScanHandler.forTextController`
// on the picker's search field — see product_picker_scanner_test.dart):
// a completed keyboard-wedge burst is captured by the gateway, normalized
// (US character digits, AZERTY layout symbols, Arabic-Indic digits) and
// dispatched exactly once to the picker, which searches the barcode
// immediately and shows the matching product for the existing selection
// workflow (tap-to-pick for Pack, tick + confirm for Promotion).
//
// Covered:
// - a physical-scanner-style burst reaches the correct picker (one
//   handler registered, one products/search request per burst);
// - the scan finds the product and the existing selection workflow is
//   unchanged (Pack: tap pops the product; Promotion: tick + confirm
//   returns it);
// - one burst is processed exactly once; consecutive scans each search
//   their own code;
// - ordinary manual typing keeps searching and is never dispatched as a
//   scan;
// - an AZERTY foreign-layout burst (digit-6 arrives as `-`) still
//   dispatches as a scan — the shortcut-owned symbol never leaks;
// - ar / fr / en: localized title, hint and cancel labels, RTL in Arabic,
//   and a scan normalizes identically in every UI language.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/packs/pack_form_dialog.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/products_providers.dart'
    show kSearchDebounce;
import 'package:supermarket_pos/features/promotions/promotion_form_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/wedge_scanner.dart';

class _MockDio extends Mock implements Dio {}

const _codeA = '8718114202402';
const _codeB = '3600520530012'; // contains a 6 — AZERTY digit-6 is `-`

const _azerty = <String, String>{
  '1': '&',
  '2': 'é',
  '3': '"',
  '4': "'",
  '5': '(',
  '6': '-',
  '7': 'è',
  '8': '_',
  '9': 'ç',
  '0': 'à',
};

Map<String, dynamic> _product(
  String id,
  String name, {
  String? barcode,
}) => {
  'id': id,
  'name': name,
  'barcode': barcode,
  'unit': 'piece',
  'price': '10',
  'avg_cost': '5',
  'quantity': '20',
  'is_archived': false,
};

const _all = [
  {'id': 'p7', 'name': 'Olive Oil', 'barcode': _codeA},
  {'id': 'p8', 'name': 'Sugar', 'barcode': _codeB},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final gateway = BarcodeScannerGateway.instance;

  setUp(gateway.resetForTest);
  tearDown(gateway.resetForTest);

  void stubSearch(_MockDio dio, List<Map<String, dynamic>> requests) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.single as String;
      final params = Map<String, dynamic>.from(
        invocation.namedArguments[#queryParameters] as Map,
      );
      requests.add({'path': path, ...params});
      final q = (params['q'] as String? ?? '').trim().toLowerCase();
      final items = [
        for (final p in _all)
          if (q.isEmpty ||
              p['barcode'] == q ||
              (p['name'] as String).toLowerCase().contains(q))
            {
              ..._product(
                p['id'] as String,
                p['name'] as String,
                barcode: p['barcode'],
              ),
            },
      ];
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'items': items, 'total': items.length},
      );
    });
  }

  Future<void> pumpPicker(
    WidgetTester tester,
    _MockDio dio,
    Future<dynamic> Function(BuildContext) openPicker, {
    AppLocale locale = AppLocale.en,
  }) async {
    // Wide surface like pack_form_dialog_test: the FR pack picker's
    // longer labels must never overflow the dialog in these checks.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          localeProvider
              .overrideWith((_) => LocaleNotifier()..setLocale(locale)),
        ],
        child: MaterialApp(
          locale: Locale(locale.name),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-picker'),
                onPressed: () => openPicker(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-picker')));
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> scans(List<Map<String, dynamic>> requests) =>
      requests
          .where((r) => r['path'] == '/api/v1/products/search')
          .where((r) => ((r['q'] as String?) ?? '').length >= 6)
          .toList();

  Future<void> sendUsScan(WidgetTester tester, String code) async {
    await sendWedgeScan(tester, code);
    await tester.pumpAndSettle();
  }

  Future<void> sendAzertyScan(WidgetTester tester, String code) async {
    BarcodeScannerGateway.experimentalPhysicalDigitCapture = true;
    addTearDown(() {
      BarcodeScannerGateway.experimentalPhysicalDigitCapture = false;
    });
    await sendForeignWedgeScan(tester, code, characters: _azerty);
    await tester.pumpAndSettle();
  }

  group('Pack product picker — scanner', () {
    testWidgets('a US wedge scan searches the barcode exactly once', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPackProductPicker(context),
      );

      await sendUsScan(tester, _codeA);

      expect(BarcodeScannerGateway.instance.handlerCount, 1);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('pack-product-picker-search')),
            )
            .controller!
            .text,
        _codeA,
      );
      // Exactly ONE dispatch: one burst, one search request.
      expect(scans(requests), hasLength(1));
      expect(scans(requests).single['q'], _codeA);
      expect(find.byKey(const Key('pack-product-option-p7')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an AZERTY burst (digit-6 arrives as -) dispatches as a scan, '
      'never as a shortcut',
      (tester) async {
        final requests = <Map<String, dynamic>>[];
        final dio = _MockDio();
        stubSearch(dio, requests);
        await pumpPicker(
          tester,
          dio,
          (context) => showPackProductPicker(context),
        );

        await sendAzertyScan(tester, _codeB);

        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('pack-product-picker-search')),
              )
              .controller!
              .text,
          _codeB,
        );
        expect(scans(requests), hasLength(1));
        expect(scans(requests).single['q'], _codeB);
        expect(find.byKey(const Key('pack-product-option-p8')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the same code scanned twice searches once per burst', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPackProductPicker(context),
      );

      await sendUsScan(tester, _codeA);
      expect(scans(requests), hasLength(1));

      await sendUsScan(tester, _codeA);
      expect(scans(requests), hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a consecutive scan of another code replaces the query', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPackProductPicker(context),
      );

      await sendUsScan(tester, _codeA);
      expect(find.byKey(const Key('pack-product-option-p7')), findsOneWidget);

      await sendUsScan(tester, _codeB);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('pack-product-picker-search')),
            )
            .controller!
            .text,
        _codeB,
      );
      expect(scans(requests), hasLength(2));
      expect(find.byKey(const Key('pack-product-option-p8')), findsOneWidget);
      expect(find.byKey(const Key('pack-product-option-p7')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual typing still searches and never dispatches a scan', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPackProductPicker(context),
      );

      await tester.enterText(
        find.byKey(const Key('pack-product-picker-search')),
        'Olive',
      );
      await tester.pump(kSearchDebounce);
      await tester.pumpAndSettle();

      final searchRequests = requests
          .where((r) => r['path'] == '/api/v1/products/search')
          .where((r) => ((r['q'] as String?) ?? '') == 'Olive')
          .toList();
      expect(searchRequests, hasLength(1));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('pack-product-picker-search')),
            )
            .controller!
            .text,
        'Olive',
      );
      // Typing never produced a scan-shaped dispatch.
      expect(scans(requests), isEmpty);
      expect(find.byKey(const Key('pack-product-option-p7')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a scan result tap still picks the product (workflow kept)', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      ProductModel? picked;
      await pumpPicker(
        tester,
        dio,
        (context) async => picked = await showPackProductPicker(context),
      );

      await sendUsScan(tester, _codeA);
      await tester.tap(find.byKey(const Key('pack-product-option-p7')));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.id, 'p7');
      expect(picked!.name, 'Olive Oil');
      expect(find.byKey(const Key('pack-product-picker')), findsNothing);
      // The dialog unregisters its handler on dispose.
      expect(BarcodeScannerGateway.instance.handlerCount, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('Promotion product picker — scanner', () {
    testWidgets('a US wedge scan searches the barcode exactly once', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPromotionProductPicker(context),
      );

      await sendUsScan(tester, _codeA);

      expect(BarcodeScannerGateway.instance.handlerCount, 1);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('promotion-product-picker-search')),
            )
            .controller!
            .text,
        _codeA,
      );
      expect(scans(requests), hasLength(1));
      expect(scans(requests).single['q'], _codeA);
      expect(
        find.byKey(const Key('promotion-product-option-p7')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an AZERTY burst (digit-6 arrives as -) dispatches as a scan, '
      'never as a shortcut',
      (tester) async {
        final requests = <Map<String, dynamic>>[];
        final dio = _MockDio();
        stubSearch(dio, requests);
        await pumpPicker(
          tester,
          dio,
          (context) => showPromotionProductPicker(context),
        );

        await sendAzertyScan(tester, _codeB);

        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('promotion-product-picker-search')),
              )
              .controller!
              .text,
          _codeB,
        );
        expect(scans(requests), hasLength(1));
        expect(scans(requests).single['q'], _codeB);
        expect(
          find.byKey(const Key('promotion-product-option-p8')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the same code scanned twice searches once per burst', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPromotionProductPicker(context),
      );

      await sendUsScan(tester, _codeA);
      expect(scans(requests), hasLength(1));

      await sendUsScan(tester, _codeA);
      expect(scans(requests), hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a consecutive scan of another code replaces the query', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPromotionProductPicker(context),
      );

      await sendUsScan(tester, _codeA);
      expect(
        find.byKey(const Key('promotion-product-option-p7')),
        findsOneWidget,
      );

      await sendUsScan(tester, _codeB);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('promotion-product-picker-search')),
            )
            .controller!
            .text,
        _codeB,
      );
      expect(scans(requests), hasLength(2));
      expect(
        find.byKey(const Key('promotion-product-option-p8')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('promotion-product-option-p7')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual typing still searches and never dispatches a scan', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final dio = _MockDio();
      stubSearch(dio, requests);
      await pumpPicker(
        tester,
        dio,
        (context) => showPromotionProductPicker(context),
      );

      await tester.enterText(
        find.byKey(const Key('promotion-product-picker-search')),
        'Olive',
      );
      await tester.pump(kSearchDebounce);
      await tester.pumpAndSettle();

      final searchRequests = requests
          .where((r) => r['path'] == '/api/v1/products/search')
          .where((r) => ((r['q'] as String?) ?? '') == 'Olive')
          .toList();
      expect(searchRequests, hasLength(1));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('promotion-product-picker-search')),
            )
            .controller!
            .text,
        'Olive',
      );
      expect(scans(requests), isEmpty);
      expect(
        find.byKey(const Key('promotion-product-option-p7')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'scan + tick + confirm returns the product (multi-select kept)',
      (tester) async {
        final requests = <Map<String, dynamic>>[];
        final dio = _MockDio();
        stubSearch(dio, requests);
        List<ProductModel>? picked;
        await pumpPicker(
          tester,
          dio,
          (context) async => picked = await showPromotionProductPicker(context),
        );

        await sendUsScan(tester, _codeA);
        await tester.tap(
          find.byKey(const Key('promotion-product-option-p7')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('promotion-product-picker-confirm')),
        );
        await tester.pumpAndSettle();

        expect(picked, isNotNull);
        expect(picked!.single.id, 'p7');
        expect(picked!.single.name, 'Olive Oil');
        expect(
          find.byKey(const Key('promotion-product-picker')),
          findsNothing,
        );
        expect(BarcodeScannerGateway.instance.handlerCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Pack + Promotion pickers — AR / FR / EN', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      final code = locale.name;

      testWidgets('Pack picker localizes and scans in $locale', (
        tester,
      ) async {
        final requests = <Map<String, dynamic>>[];
        final dio = _MockDio();
        stubSearch(dio, requests);
        await pumpPicker(
          tester,
          dio,
          (context) => showPackProductPicker(context),
          locale: locale,
        );

        expect(
          find.text(AppStrings.t('select_pack_product', code)),
          findsOneWidget,
        );
        expect(find.text(AppStrings.t('search', code)), findsOneWidget);
        expect(find.text(AppStrings.t('cancel', code)), findsOneWidget);
        expect(
          tester
              .widget<Directionality>(
                find
                    .ancestor(
                      of: find.byKey(const Key('pack-product-picker')),
                      matching: find.byType(Directionality),
                    )
                    .first,
              )
              .textDirection,
          locale == AppLocale.ar ? TextDirection.rtl : TextDirection.ltr,
        );

        // Normalization does not depend on the UI language.
        await sendAzertyScan(tester, _codeB);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('pack-product-picker-search')),
              )
              .controller!
              .text,
          _codeB,
        );
        expect(scans(requests), hasLength(1));
        expect(
          find.byKey(const Key('pack-product-option-p8')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('Promotion picker localizes and scans in $locale', (
        tester,
      ) async {
        final requests = <Map<String, dynamic>>[];
        final dio = _MockDio();
        stubSearch(dio, requests);
        await pumpPicker(
          tester,
          dio,
          (context) => showPromotionProductPicker(context),
          locale: locale,
        );

        expect(
          find.text(AppStrings.t('promotion_select_products', code)),
          findsOneWidget,
        );
        expect(find.text(AppStrings.t('search', code)), findsOneWidget);
        expect(find.text(AppStrings.t('cancel', code)), findsOneWidget);
        expect(
          tester
              .widget<Directionality>(
                find
                    .ancestor(
                      of: find.byKey(const Key('promotion-product-picker')),
                      matching: find.byType(Directionality),
                    )
                    .first,
              )
              .textDirection,
          locale == AppLocale.ar ? TextDirection.rtl : TextDirection.ltr,
        );

        await sendAzertyScan(tester, _codeB);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('promotion-product-picker-search')),
              )
              .controller!
              .text,
          _codeB,
        );
        expect(scans(requests), hasLength(1));
        expect(
          find.byKey(const Key('promotion-product-option-p8')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
