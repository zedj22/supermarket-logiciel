// Purchase editor quick-add (product / supplier) + optional supplier.
//
// Contract:
// - the line dialog's "Add product" opens the full product form; on
//   create the fresh product is selected in place and the typed
//   quantity/cost survive; cancelling the form keeps the current
//   selection (no stock mutation happens from the quick-add itself);
// - the purchase form's "Add supplier" opens the full supplier form; on
//   create the fresh supplier is selected in place and the draft note
//   survives; cancelling keeps the previous selection;
// - supplier is OPTIONAL: the editor opens at "No supplier" and a draft
//   save POSTs supplier_id: null with no validation error;
// - the detail header reads "Supplier: No supplier" when the purchase
//   has none.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/purchases/purchase_detail_dialog.dart';
import 'package:supermarket_pos/features/purchases/purchase_form_dialog.dart';
import 'package:supermarket_pos/features/purchases/purchase_line_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

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
  Future<List<String>> readUserPermissions() async => const [
        'product_view',
        'product_create',
        'product_update',
        'category_view',
        'supplier_view',
        'supplier_manage',
        'purchase_create',
        'purchase_update',
      ];

  @override
  Future<void> clearAll() async {}
}

Map<String, dynamic> _productJson({
  String id = 'p-1',
  String name = 'Yoghurt',
}) =>
    {
      'id': id,
      'name': name,
      'barcode': '111222333',
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': '45.0',
      'cost': '30.0',
      'avg_cost': '30.0',
      'quantity': '0.0',
      'low_stock_threshold': '5.0',
      'allow_negative_stock': false,
      'wholesale_price': null,
      'wholesale_min_qty': null,
      'promotion': null,
      'vat_rate': 0,
      'expiry_date': null,
      'image_path': null,
      'category_id': null,
      'category_name': null,
      'is_archived': false,
    };

Map<String, dynamic> _createdProductJson() => _productJson(
      id: 'p-new',
      name: 'Fresh Yoghurt',
    );

Map<String, dynamic> _supplierJson({
  String id = 's-1',
  String name = 'Atlas',
}) =>
    {
      'id': id,
      'name': name,
      'phone': null,
      'address': null,
      'email': null,
      'contact_person': null,
      'notes': null,
      'balance': '0.000',
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _createdSupplierJson() => _supplierJson(
      id: 's-new',
      name: 'Atlas Quick',
    );

Map<String, dynamic> _createdPurchaseJson() => {
      'id': 'po-new',
      'invoice_number': 'PO-NEW',
      'status': 'draft',
      'supplier_id': null,
      'supplier_name': null,
      'user_id': 'u-1',
      'subtotal': '100.000',
      'discount': '0.000',
      'total': '100.000',
      'paid': '0.000',
      'note': null,
      'device_id': null,
      'client_request_id': null,
      'purchase_date': '2026-10-18T10:00:00Z',
      'received_at': null,
      'cancelled_at': null,
      'created_at': '2026-10-18T10:00:00Z',
      'updated_at': '2026-10-18T10:00:00Z',
      'lines': <dynamic>[],
      'idempotent_replay': false,
    };

Map<String, dynamic> _purchaseNoSupplierDetailJson() => {
      'id': 'p-no-supplier',
      'invoice_number': 'PO-777',
      'status': 'draft',
      'supplier_id': null,
      'supplier_name': null,
      'user_id': 'u-1',
      'subtotal': '100.000',
      'discount': '0.000',
      'total': '100.000',
      'paid': '0.000',
      'note': null,
      'device_id': null,
      'client_request_id': null,
      'purchase_date': null,
      'received_at': null,
      'cancelled_at': null,
      'created_at': '2026-10-18T10:00:00Z',
      'updated_at': '2026-10-18T10:00:00Z',
      'lines': <dynamic>[],
      'idempotent_replay': false,
    };

Map<String, dynamic> _listBody(List<Map<String, dynamic>> items) => {
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

class _Captures {
  final productPosts = <Map<String, dynamic>>[];
  final supplierPosts = <Map<String, dynamic>>[];
  final purchasePosts = <Map<String, dynamic>>[];
}

void _stubApi(MockDio dio, _Captures captures) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(
    () => dio.get(any(), queryParameters: any(named: 'queryParameters')),
  ).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == '/api/v1/categories') {
      return _ok(path, _listBody(const []));
    }
    if (path == '/api/v1/products') {
      return _ok(path, _listBody([_createdProductJson()]));
    }
    if (path == '/api/v1/products/search') {
      return _ok(path, _listBody([_productJson()]));
    }
    if (path == '/api/v1/suppliers') {
      return _ok(path, _listBody(const []));
    }
    if (path == '/api/v1/purchases') {
      return _ok(path, _listBody(const []));
    }
    // variants / purchase-units and anything else: empty choices.
    return _ok(path, _listBody(const []));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, _listBody(const []));
  });

  when(() => dio.get('/api/v1/purchases/p-no-supplier')).thenAnswer(
    (_) async => _ok(
      '/api/v1/purchases/p-no-supplier',
      _purchaseNoSupplierDetailJson(),
    ),
  );

  when(() => dio.post('/api/v1/products', data: any(named: 'data')))
      .thenAnswer((invocation) async {
    captures.productPosts
        .add(Map<String, dynamic>.from(invocation.namedArguments[#data] as Map));
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/products'),
      statusCode: 201,
      data: _createdProductJson(),
    );
  });

  when(() => dio.post('/api/v1/suppliers', data: any(named: 'data')))
      .thenAnswer((invocation) async {
    captures.supplierPosts
        .add(Map<String, dynamic>.from(invocation.namedArguments[#data] as Map));
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/suppliers'),
      statusCode: 201,
      data: _createdSupplierJson(),
    );
  });

  when(() => dio.post('/api/v1/purchases', data: any(named: 'data')))
      .thenAnswer((invocation) async {
    captures.purchasePosts
        .add(Map<String, dynamic>.from(invocation.namedArguments[#data] as Map));
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/purchases'),
      statusCode: 201,
      data: _createdPurchaseJson(),
    );
  });
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required MockDio dio,
  required void Function(BuildContext context) open,
  required Key openKey,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: openKey,
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(openKey));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets(
      'line dialog: quick-add product selects the created product and '
      'keeps the typed quantity/cost', (tester) async {
    final dio = MockDio();
    final captures = _Captures();
    _stubApi(dio, captures);

    await _pumpHost(
      tester,
      dio: dio,
      openKey: const Key('open-line-dialog'),
      open: (context) => showPurchaseLineDialog(context),
    );
    expect(find.byKey(const Key('purchase-line-dialog')), findsOneWidget);

    // Pick an existing product first (qty/cost only exist once a product
    // is selected), then type the line BEFORE quick-adding — it must
    // survive the nested form.
    await tester.tap(find.byKey(const Key('purchase-line-pick-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purchase-product-option-p-1')));
    await tester.pumpAndSettle();
    expect(find.text('Yoghurt'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '3');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '25');
    await tester.pump();

    await tester.tap(find.byKey(const Key('purchase-line-quick-add-product')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('product-name-field')));
    await tester.enterText(
      find.byKey(const Key('product-name-field')),
      'Fresh Yoghurt',
    );
    await tester.ensureVisible(find.byKey(const Key('product-price-field')));
    await tester.enterText(find.byKey(const Key('product-price-field')), '45');
    await tester.pump();

    await tester.tap(find.byKey(const Key('product-form-submit')));
    await tester.pumpAndSettle();

    // Product form closed; the created product is selected in place.
    expect(find.byKey(const Key('product-form-dialog')), findsNothing);
    expect(find.byKey(const Key('purchase-line-dialog')), findsOneWidget);
    expect(find.text('Fresh Yoghurt'), findsOneWidget);

    // Editor state survived the nested dialog.
    final qty = tester.widget<TextField>(
      find.byKey(const Key('purchase-line-qty')),
    );
    final cost = tester.widget<TextField>(
      find.byKey(const Key('purchase-line-cost')),
    );
    expect(qty.controller!.text, '3');
    expect(cost.controller!.text, '25');

    // The create POST carried the typed product data.
    expect(captures.productPosts, hasLength(1));
    expect(captures.productPosts.single['name'], 'Fresh Yoghurt');
    expect(captures.productPosts.single['price'], '45');
    // Seeded stock is zero — the quick-add never mutates stock.
    expect(captures.productPosts.single['quantity'], '0');
  });

  testWidgets(
      'line dialog: cancelling the quick-add product form keeps the '
      'current selection', (tester) async {
    final dio = MockDio();
    final captures = _Captures();
    _stubApi(dio, captures);

    await _pumpHost(
      tester,
      dio: dio,
      openKey: const Key('open-line-dialog'),
      open: (context) => showPurchaseLineDialog(context),
    );

    // Pick a product through the normal picker first.
    await tester.tap(find.byKey(const Key('purchase-line-pick-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purchase-product-option-p-1')));
    await tester.pumpAndSettle();
    expect(find.text('Yoghurt'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '4');
    await tester.pump();

    // Open the quick-add form, then cancel it.
    await tester.tap(find.byKey(const Key('purchase-line-quick-add-product')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('product-form-cancel')));
    await tester.pumpAndSettle();

    // Selection + typed quantity untouched; no create happened.
    expect(find.byKey(const Key('purchase-line-dialog')), findsOneWidget);
    expect(find.text('Yoghurt'), findsOneWidget);
    final qty = tester.widget<TextField>(
      find.byKey(const Key('purchase-line-qty')),
    );
    expect(qty.controller!.text, '4');
    expect(captures.productPosts, isEmpty);
  });

  testWidgets(
      'purchase form: quick-add supplier selects the created supplier and '
      'keeps the draft note', (tester) async {
    final dio = MockDio();
    final captures = _Captures();
    _stubApi(dio, captures);

    await _pumpHost(
      tester,
      dio: dio,
      openKey: const Key('open-purchase-form'),
      open: (context) => showPurchaseFormDialog(context),
    );
    expect(find.byKey(const Key('purchase-form-dialog')), findsOneWidget);

    // Supplier starts unset — the optional-supplier placeholder.
    expect(
      find.text(AppStrings.t('no_supplier', 'en')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('purchase-form-note')),
      'keep me',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('purchase-form-quick-add-supplier')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('supplier-form-dialog')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('supplier-name-field')));
    await tester.enterText(
      find.byKey(const Key('supplier-name-field')),
      'Atlas Quick',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('supplier-form-submit')));
    await tester.pumpAndSettle();

    // Supplier form closed; the created supplier is selected in place.
    expect(find.byKey(const Key('supplier-form-dialog')), findsNothing);
    expect(find.byKey(const Key('purchase-form-dialog')), findsOneWidget);
    expect(find.text('Atlas Quick'), findsOneWidget);
    expect(find.text('keep me'), findsOneWidget);

    expect(captures.supplierPosts, hasLength(1));
    expect(captures.supplierPosts.single['name'], 'Atlas Quick');
  });

  testWidgets(
      'purchase form: draft save without a supplier POSTs supplier_id: null',
      (tester) async {
    final dio = MockDio();
    final captures = _Captures();
    _stubApi(dio, captures);

    await _pumpHost(
      tester,
      dio: dio,
      openKey: const Key('open-purchase-form'),
      open: (context) => showPurchaseFormDialog(context),
    );

    // Add one line through the picker (supplier stays unset).
    await tester.tap(find.byKey(const Key('purchase-form-add-line')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purchase-line-pick-product')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('purchase-product-option-p-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('purchase-line-qty')), '2');
    await tester.enterText(find.byKey(const Key('purchase-line-cost')), '50');
    await tester.tap(find.byKey(const Key('purchase-line-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('purchase-form-line-0')), findsOneWidget);

    // No supplier selected — save still succeeds (supplier is optional).
    await tester.tap(find.byKey(const Key('purchase-form-save-draft')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('purchase-form-dialog')), findsNothing);
    expect(
      find.byKey(const Key('purchase-form-success-toast')),
      findsOneWidget,
    );

    expect(captures.purchasePosts, hasLength(1));
    final payload = captures.purchasePosts.single;
    expect(payload['supplier_id'], isNull);
    expect(payload['receive'], isFalse);
    final lines = payload['lines'] as List<dynamic>;
    expect(lines, hasLength(1));
  });

  testWidgets('detail header: "Supplier: No supplier" when there is none',
      (tester) async {
    final dio = MockDio();
    final captures = _Captures();
    _stubApi(dio, captures);

    await _pumpHost(
      tester,
      dio: dio,
      openKey: const Key('open-purchase-detail'),
      open: (context) => showPurchaseDetailDialog(
        context,
        purchaseId: 'p-no-supplier',
      ),
    );

    expect(find.byKey(const Key('purchase-detail-dialog')), findsOneWidget);
    expect(
      find.text('Supplier: ${AppStrings.t('no_supplier', 'en')}'),
      findsOneWidget,
    );
  });
}
