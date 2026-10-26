import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/barcode_scanner.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/facturation/facturation_pickers.dart';
import 'package:supermarket_pos/features/purchases/purchase_pickers.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/wedge_scanner.dart';

class _MockDio extends Mock implements Dio {}

const _barcode = '8718114202402';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final gateway = BarcodeScannerGateway.instance;

  setUp(gateway.resetForTest);
  tearDown(gateway.resetForTest);

  Future<void> pumpPicker(
    WidgetTester tester,
    _MockDio dio,
    Future<dynamic> Function(BuildContext) openPicker,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        ],
        child: MaterialApp(
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
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {
          'items': [
            {
              'id': 'p7',
              'name': 'Olive Oil',
              'barcode': _barcode,
              'unit': 'piece',
              'price': '10',
              'quantity': '20',
              'is_archived': false,
            },
          ],
          'total': 1,
        },
      );
    });
  }

  Future<void> assertAzertyBarcodeSearch(
    WidgetTester tester, {
    required Finder searchField,
    required Finder result,
    required List<Map<String, dynamic>> requests,
  }) async {
    expect(searchField, findsOneWidget);
    BarcodeScannerGateway.experimentalPhysicalDigitCapture = true;
    addTearDown(() {
      BarcodeScannerGateway.experimentalPhysicalDigitCapture = false;
    });
    await sendForeignWedgeScan(tester, _barcode, characters: _azerty);
    await tester.pumpAndSettle();

    expect(result, findsOneWidget);
    final scanRequests = requests.where((r) => r['q'] == _barcode).toList();
    expect(scanRequests, hasLength(1));
    expect(
      tester.widget<TextField>(searchField).controller!.text,
      _barcode,
    );
    expect(tester.takeException(), isNull);
  }

  testWidgets('Purchase product picker searches a normalized AZERTY scan',
      (tester) async {
    final requests = <Map<String, dynamic>>[];
    final dio = _MockDio();
    stubSearch(dio, requests);
    await pumpPicker(
      tester,
      dio,
      (context) => showPurchaseProductPicker(context),
    );

    await assertAzertyBarcodeSearch(
      tester,
      searchField: find.byKey(const Key('purchase-product-picker-search')),
      result: find.byKey(const Key('purchase-product-option-p7')),
      requests: requests,
    );
    expect(BarcodeScannerGateway.instance.handlerCount, 1);
  });

  testWidgets('Facturation product picker searches a normalized AZERTY scan',
      (tester) async {
    final requests = <Map<String, dynamic>>[];
    final dio = _MockDio();
    stubSearch(dio, requests);
    await pumpPicker(
      tester,
      dio,
      (context) => showFacturationProductPicker(context),
    );

    await assertAzertyBarcodeSearch(
      tester,
      searchField:
          find.byKey(const Key('facturation-product-picker-search')),
      result: find.text('Olive Oil'),
      requests: requests,
    );
    expect(BarcodeScannerGateway.instance.handlerCount, 1);
  });
}
