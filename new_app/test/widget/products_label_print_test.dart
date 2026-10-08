// Products barcode / price-label printing — selection mode + label dialog.
//
// Harness: the full-app login flow (as products_screen_test) so the real
// permission gating and screen wiring run, plus the Phase-15 preview
// seams (pdfPreviewProvider / printServiceProvider) so the
// preview-first confirm path executes without a rasterizer or printer.
//
// Prices are never sent by the client — the payload assertions pin that
// (§ price rule): items carry product_id + quantity only.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/print_document.dart';
import 'package:supermarket_pos/features/pos/print_service.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Stateful in-memory credential storage for the full-app login flow.
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
const _productsPath = '/api/v1/products';
const _categoriesPath = '/api/v1/categories';

const _p1 = '00000000-0000-0000-0000-0000000000p1';
const _p2 = '00000000-0000-0000-0000-0000000000p2';

Map<String, dynamic> _adminLoginBody() => {
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
              for (final s in [
                'product_view',
                'product_create',
                'product_update',
                'product_archive',
                'category_view',
                'category_manage',
              ])
                {'id': 'p-$s', 'scope': s, 'description': null},
            ],
          },
        ],
      },
    };

Map<String, dynamic> _productJson({
  required String id,
  required String name,
  required String barcode,
  String price = '100.0',
  String cost = '80.0',
  String quantity = '10.0',
  String? categoryId,
  String? categoryName,
}) =>
    {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': price,
      'cost': cost,
      'quantity': quantity,
      'low_stock_threshold': '5.0',
      'allow_negative_stock': false,
      'expiry_date': null,
      'image_path': null,
      'category_id': categoryId,
      'category_name': categoryName,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _productsBody({
  required List<Map<String, dynamic>> items,
  required int page,
  int total = 2,
  int pageSize = 1,
  int pages = 2,
}) =>
    {
      'items': items,
      'total': total,
      'page': page,
      'page_size': pageSize,
      'pages': pages,
    };

Map<String, dynamic> _appleBody() => _productJson(
      id: _p1,
      name: 'Apple Juice',
      barcode: '111222333',
      categoryId: '00000000-0000-0000-0000-0000000000c1',
      categoryName: 'Drinks',
    );

Map<String, dynamic> _breadBody() => _productJson(
      id: _p2,
      name: 'Bread',
      barcode: '444555666',
      price: '50.0',
      cost: '30.0',
      quantity: '20.0',
    );

Map<String, dynamic> _categoriesListBody() => {
      'items': [
        {
          'id': '00000000-0000-0000-0000-0000000000c1',
          'name': 'Drinks',
          'parent_id': null,
          'sort_order': 0,
          'product_count': 1,
          'is_archived': false,
          'archived_at': null,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
    };

Response<dynamic> okResponse(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      data: data,
      statusCode: 200,
    );

Response<dynamic> _bytes(String path, List<int> bytes, String filename) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: Uint8List.fromList(bytes),
      headers: Headers.fromMap(<String, List<String>>{
        'content-disposition': <String>['attachment; filename="$filename"'],
      }),
    );

DioException _envelope(int status, String code, String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: status,
        data: <String, dynamic>{
          'error': <String, dynamic>{'code': code, 'message': 'raw backend'},
        },
      ),
    );

/// App-flow stubs (login / products / categories) + a byte-POST stub for
/// `POST /api/v1/print/labels`. [labelsHandler] may return bytes or throw.
void _stub(
  MockDio dio, {
  Map<String, dynamic> Function(int page)? productsFor,
  List<Map<String, dynamic>>? queryLog,
  Response<dynamic> Function(String path, Map<String, dynamic> data)?
      labelsHandler,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get('/api/v1/auth/setup/check')).thenAnswer(
    (_) async => okResponse('/api/v1/auth/setup/check', {
      'setup_needed': false,
    }),
  );
  when(() => dio.get('/api/v1/auth/login-users')).thenAnswer(
    (_) async => okResponse('/api/v1/auth/login-users', {
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
    }),
  );
  when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
    (_) async => okResponse(_loginPath, _adminLoginBody()),
  );
  when(() => dio.post('/api/v1/auth/logout-token', data: any(named: 'data')))
      .thenAnswer(
    (_) async => okResponse('/api/v1/auth/logout-token', {
      'message': 'logged out',
    }),
  );
  when(
    () => dio.get(
      _productsPath,
      queryParameters: any(named: 'queryParameters'),
    ),
  ).thenAnswer((invocation) async {
    final params = invocation.namedArguments[#queryParameters];
    final page = params is Map ? (params['page'] as int? ?? 1) : 1;
    if (queryLog != null && params is Map<String, dynamic>) {
      queryLog.add(Map<String, dynamic>.from(params));
    }
    if (productsFor != null) {
      return okResponse(_productsPath, productsFor(page));
    }
    return okResponse(
      _productsPath,
      _productsBody(
        items: [_appleBody(), _breadBody()],
        page: 1,
        total: 2,
        pageSize: 40,
        pages: 1,
      ),
    );
  });
  when(
    () => dio.get(
      _categoriesPath,
      queryParameters: any(named: 'queryParameters'),
    ),
  ).thenAnswer(
    (_) async => okResponse(_categoriesPath, _categoriesListBody()),
  );

  // Byte endpoints are stubbed with the SAME generic argument the
  // production call uses — mocktail matches type arguments strictly.
  Future<Response<Uint8List>> answer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    final raw = invocation.namedArguments[#data];
    final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final out = labelsHandler?.call(path, data) ??
        _bytes(path, <int>[37, 80, 68, 70], 'labels_2026.pdf');
    return Response<Uint8List>(
      requestOptions: out.requestOptions,
      statusCode: out.statusCode,
      data: out.data is Uint8List ? out.data as Uint8List : null,
      headers: out.headers,
    );
  }

  when(() => dio.post<Uint8List>(any(), data: any(named: 'data')))
      .thenAnswer(answer);
  when(
    () => dio.post<Uint8List>(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(answer);
}

class _FakePdfPreview implements PdfPreviewBuilder {
  final List<Uint8List> received = <Uint8List>[];
  final List<String> papers = <String>[];

  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    required String filename,
  }) {
    received.add(bytes);
    papers.add(paper);
    return Text('preview:${bytes.length}:$paper:$filename');
  }
}

class _FakePrintService implements PrintService {
  final List<Uint8List> printedPdfs = <Uint8List>[];
  final List<String> printedPapers = <String>[];

  @override
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) async {
    printedPdfs.add(bytes);
    printedPapers.add(paper);
  }

  @override
  Future<void> printText(String text) async {}
}

class _FailingPrintService implements PrintService {
  @override
  Future<void> printPdf(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) async {
    throw const PrintServiceException('no printer available');
  }

  @override
  Future<void> printText(String text) async {}
}

Future<void> _pumpApp(
  WidgetTester tester,
  MockDio dio, {
  PdfPreviewBuilder? preview,
  PrintService? printer,
}) async {
  tester.view.physicalSize = const Size(2200, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        pdfPreviewProvider.overrideWithValue(preview ?? _FakePdfPreview()),
        printServiceProvider.overrideWithValue(printer ?? _FakePrintService()),
        // The real provider awaits a SharedPreferences platform channel
        // that never replies under `flutter test` — pin the identity so
        // the label dialog's deviceId read resolves deterministically.
        deviceIdProvider.overrideWith((ref) async => 'POS-1'),
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

  await tester.tap(find.text(AppStrings.t('products', 'ar')));
  await tester.pumpAndSettle();
}

Future<void> _enterLabelMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('products-print-labels')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  String countText(int n) => '$n ${AppStrings.t('labels_selected', 'ar')}';
  group('Products label selection mode', () {
    testWidgets('header swaps to count + cancel + disabled print; '
        'checkboxes appear per row and in the header', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpApp(tester, dio);

      expect(find.byKey(const Key('products-print-labels')), findsOneWidget);
      expect(find.byKey(const Key('product-label-check-$_p1')), findsNothing);

      await _enterLabelMode(tester);

      expect(find.byKey(const Key('products-label-count')), findsOneWidget);
      expect(find.text(countText(0)), findsOneWidget);
      expect(find.byKey(const Key('products-label-cancel')), findsOneWidget);
      expect(find.byKey(const Key('product-label-check-$_p1')), findsOneWidget);
      expect(find.byKey(const Key('product-label-check-$_p2')), findsOneWidget);
      expect(
        find.byKey(const Key('products-label-check-all')),
        findsOneWidget,
      );
      // Nothing selected → print stays disabled.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('products-print-action')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('row + tristate header checkboxes drive the count; '
        'cancel exits and clears', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpApp(tester, dio);
      await _enterLabelMode(tester);

      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();

      expect(find.text(countText(1)), findsOneWidget);
      // Mixed selection on this page → tristate header reads null.
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('products-label-check-all')),
            )
            .value,
        isNull,
      );

      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p2')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p2')));
      await tester.pumpAndSettle();

      expect(find.text(countText(2)), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('products-label-check-all')),
            )
            .value,
        isTrue,
      );

      // Header deselects the whole page.
      await tester.ensureVisible(
        find.byKey(const Key('products-label-check-all')),
      );
      await tester.tap(find.byKey(const Key('products-label-check-all')));
      await tester.pumpAndSettle();
      expect(find.text(countText(0)), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('products-label-check-all')),
            )
            .value,
        isFalse,
      );

      // Cancel leaves mode entirely.
      await tester.tap(find.byKey(const Key('products-label-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('products-label-count')), findsNothing);
      expect(
        find.byKey(const Key('product-label-check-$_p1')),
        findsNothing,
      );
      expect(find.byKey(const Key('products-print-labels')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selection survives paging (page 1 + page 2 both counted)',
        (tester) async {
      final dio = MockDio();
      _stub(
        dio,
        productsFor: (page) => _productsBody(
          items: [page == 1 ? _appleBody() : _breadBody()],
          page: page,
        ),
      );
      await _pumpApp(tester, dio);
      await _enterLabelMode(tester);

      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();
      expect(find.text(countText(1)), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('products-next-page')));
      await tester.tap(find.byKey(const Key('products-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('Bread'), findsOneWidget);

      // Count carried over although p1 is off-page now.
      expect(find.text(countText(1)), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p2')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p2')));
      await tester.pumpAndSettle();
      expect(find.text(countText(2)), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('products-prev-page')));
      await tester.tap(find.byKey(const Key('products-prev-page')));
      await tester.pumpAndSettle();

      // Back on page 1: p1 is STILL selected.
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const Key('product-label-check-$_p1')),
            )
            .value,
        isTrue,
      );
      expect(find.text(countText(2)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Print opens the dialog: qty steppers, remove row, total; '
        'cancel keeps selection', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpApp(tester, dio);
      await _enterLabelMode(tester);

      for (final id in [_p1, _p2]) {
        await tester.ensureVisible(find.byKey(Key('product-label-check-$id')));
        await tester.tap(find.byKey(Key('product-label-check-$id')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('products-print-action')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('label-print-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('label-row-$_p1')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('label-total-count')))
            .data,
        '${AppStrings.t('labels_total', 'ar')}: 2',
      );

      // +1 on the first product → total 3, value reads 2.
      await tester.tap(find.byKey(const Key('label-qty-inc-$_p1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('label-qty-value-$_p1')))
            .data,
        '2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('label-total-count')))
            .data,
        '${AppStrings.t('labels_total', 'ar')}: 3',
      );

      // −1 back to 1 (disabled below 1).
      await tester.tap(find.byKey(const Key('label-qty-dec-$_p1')));
      await tester.pumpAndSettle();

      // Remove the second row → total drops to 1.
      await tester.tap(find.byKey(const Key('label-row-remove-$_p2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('label-row-$_p2')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('label-total-count')))
            .data,
        '${AppStrings.t('labels_total', 'ar')}: 1',
      );

      // Close the dialog — selection mode is untouched (both rows still
      // selected; qty/remove above were dialog-local and discarded).
      await tester.tap(find.byKey(const Key('label-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('label-print-dialog')), findsNothing);
      expect(find.text(countText(2)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Label batch → preview → print', () {
    testWidgets('posts items + layout (NO price) and prints the previewed '
        'bytes, then exits selection mode', (tester) async {
      final dio = MockDio();
      late Map<String, dynamic> sent;
      _stub(
        dio,
        labelsHandler: (path, data) {
          expect(path, kPrintLabelsPath);
          sent = data;
          return _bytes(path, <int>[37, 80, 68, 70], 'labels_2026.pdf');
        },
      );
      final preview = _FakePdfPreview();
      final printer = _FakePrintService();
      await _pumpApp(tester, dio, preview: preview, printer: printer);

      await _enterLabelMode(tester);
      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('products-print-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('label-print-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('label-dialog-print')));
      await tester.pumpAndSettle();

      // Fetch payload: product + quantity only — the client never sends a
      // price (server resolves promo vs retail, § price rule).
      expect(sent['paper'], 'A4');
      expect(sent['locale'], 'ar');
      expect(sent['device_id'], 'POS-1');
      final items = (sent['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(1));
      expect(items.single['product_id'], _p1);
      expect(items.single['quantity'], 1);
      expect(items.single.containsKey('price'), isFalse);
      final layout = sent['layout'] as Map<String, dynamic>;
      expect(layout['label_width_mm'], 50.0);
      expect(layout['label_height_mm'], 30.0);
      expect(layout.containsKey('columns'), isFalse); // auto-fit grid
      expect(layout.containsKey('rows'), isFalse);

      // Preview-first: the fake rasterizer received the fetched bytes.
      expect(find.byKey(const Key('print-preview-dialog')), findsOneWidget);
      expect(
        find.textContaining('labels_2026.pdf'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();

      expect(printer.printedPdfs, hasLength(1));
      expect(printer.printedPapers, ['A4']);
      expect(printer.printedPdfs.single, preview.received.single);

      // Pop(true) → screen exits selection mode.
      expect(find.byKey(const Key('label-print-dialog')), findsNothing);
      expect(find.byKey(const Key('products-label-count')), findsNothing);
      expect(
        find.byKey(const Key('product-label-check-$_p1')),
        findsNothing,
      );
      expect(find.byKey(const Key('products-print-labels')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-numeric layout field → inline validation_error, '
        'no POST', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpApp(tester, dio);
      await _enterLabelMode(tester);
      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('products-print-action')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('label-field-width')),
        'abc',
      );
      await tester.tap(find.byKey(const Key('label-dialog-print')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('label-print-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('validation_error', 'ar')),
        findsOneWidget,
      );
      verifyNever(
        () => dio.post<Uint8List>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      );
      // Still inside the label dialog.
      expect(find.byKey(const Key('label-print-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('backend 422 on fetch → localized preview error; '
        'dismissing preview keeps the dialog and mode', (tester) async {
      final dio = MockDio();
      _stub(
        dio,
        labelsHandler: (path, data) =>
            throw _envelope(422, 'VALIDATION_ERROR', path),
      );
      await _pumpApp(tester, dio);
      await _enterLabelMode(tester);
      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('products-print-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('label-dialog-print')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('print-preview-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('validation_error', 'ar')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.byKey(const Key('print-preview-confirm')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('print-preview-cancel')));
      await tester.pumpAndSettle();

      // Back on the label dialog, still in selection mode — neutral.
      expect(find.byKey(const Key('label-print-dialog')), findsOneWidget);
      expect(find.byKey(const Key('products-label-count')), findsOneWidget);
      expect(
        find.text(AppStrings.t('print_failed', 'ar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('system print failure → inline print_failed, '
        'dialog stays open (never "success")', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpApp(tester, dio, printer: _FailingPrintService());
      await _enterLabelMode(tester);
      await tester.ensureVisible(
        find.byKey(const Key('product-label-check-$_p1')),
      );
      await tester.tap(find.byKey(const Key('product-label-check-$_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('products-print-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('label-dialog-print')));
      await tester.pumpAndSettle();

      // Preview confirmed → printPdf throws → inline error, no pop.
      await tester.tap(find.byKey(const Key('print-preview-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print-preview-dialog')), findsNothing);
      expect(find.byKey(const Key('label-print-error')), findsOneWidget);
      expect(
        find.textContaining(AppStrings.t('print_failed', 'ar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('label-print-dialog')), findsOneWidget);
      expect(find.byKey(const Key('products-label-count')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
