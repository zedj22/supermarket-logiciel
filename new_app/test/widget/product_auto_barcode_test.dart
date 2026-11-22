// Automatic barcode: the product form surfaces the code the backend minted.
//
// Contract: when the operator leaves the barcode field empty, the create
// response carries the generated EAN-13 and the form announces it (the
// code is otherwise invisible until the product list is searched). A
// barcode the operator typed is echoed unchanged and is NOT announced as
// generated.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

const _productsPath = '/api/v1/products';
const _setupPath = '/api/v1/auth/setup/check';
const _mePath = '/api/v1/auth/me';
const _generatedBarcode = '2001234567894';

const _scopes = ['product_view', 'product_create', 'product_update'];

Map<String, dynamic> _createdProduct(String barcode) => {
      'id': '00000000-0000-0000-0000-0000000000c1',
      'name': 'Yaourt',
      'barcode': barcode,
      'sku': null,
      'description': null,
      'unit': 'piece',
      'price': '120',
      'cost': '80',
      'avg_cost': '80',
      'quantity': '0',
      'low_stock_threshold': '5',
      'allow_negative_stock': false,
      'wholesale_price': null,
      'wholesale_min_qty': null,
      'vat_rate': 0,
      'expiry_date': null,
      'image_path': null,
      'category_id': null,
      'category_name': null,
      'is_archived': false,
      'archived_at': null,
      'created_at': '2026-11-21T10:00:00Z',
      'updated_at': '2026-11-21T10:00:00Z',
    };

Response<dynamic> _ok(String path, Object? data) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void _stub(MockDio dio, {required String responseBarcode}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, {
      'items': <dynamic>[],
      'total': 0,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    });
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == _setupPath) return _ok(path, {'setup_needed': false});
    if (path == _mePath) {
      return _ok(path, {
        'id': 'admin-1',
        'full_name': 'Admin',
        'is_active': true,
        'permissions': _scopes,
        'roles': ['admin'],
      });
    }
    return _ok(path, {'items': <dynamic>[], 'total': 0});
  });

  when(() => dio.post(_productsPath, data: any(named: 'data'))).thenAnswer(
    (_) async => _ok(_productsPath, _createdProduct(responseBarcode)),
  );
}

Future<void> _pumpForm(WidgetTester tester, MockDio dio) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  const user = AuthUser(
    id: 'admin-1',
    fullName: 'Admin',
    isActive: true,
    roles: ['admin'],
    permissions: _scopes,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        currentUserProvider.overrideWithValue(user),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-create'),
              onPressed: () => showProductFormDialog(context),
              child: const Text('new'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  await tester.tap(find.byKey(const Key('open-create')));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('product-name-field')), 'Yaourt');
  await tester.enterText(find.byKey(const Key('product-price-field')), '120');
  await tester.pump();
  await tester.tap(find.byKey(const Key('product-form-submit')));
  await tester.pumpAndSettle();
}

/// The JSON body the form actually put on the wire.
Map<String, dynamic> _sentPayload(MockDio dio) {
  final captured = verify(
    () => dio.post(_productsPath, data: captureAny(named: 'data')),
  ).captured;
  return Map<String, dynamic>.from(captured.single as Map);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an empty barcode field announces the generated EAN-13',
      (tester) async {
    final dio = MockDio();
    _stub(dio, responseBarcode: _generatedBarcode);
    await _pumpForm(tester, dio);

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('product-barcode-field')))
          .controller
          ?.text,
      isEmpty,
    );

    await _submit(tester);

    // An empty field never puts a (blank) barcode on the wire — the request
    // leaves generation entirely to the backend.
    final payload = _sentPayload(dio);
    expect(payload.containsKey('barcode'), isFalse);

    // The dialog closed on success…
    expect(find.byKey(const Key('product-form-dialog')), findsNothing);
    // …and the generated code is visible, not hidden behind another search.
    expect(
      find.textContaining(
        '${AppStrings.t('product_created', 'en')} · '
        '${AppStrings.t('barcode', 'en')}: $_generatedBarcode',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a typed barcode is used verbatim and not announced as generated',
      (tester) async {
    final dio = MockDio();
    _stub(dio, responseBarcode: '6130000112233');
    await _pumpForm(tester, dio);

    await tester.enterText(
      find.byKey(const Key('product-barcode-field')),
      '6130000112233',
    );
    await _submit(tester);

    // A typed code travels verbatim: the backend stores it as-is.
    expect(_sentPayload(dio)['barcode'], '6130000112233');

    expect(
      find.textContaining('${AppStrings.t('barcode', 'en')}:'),
      findsNothing,
      reason: 'only an auto-generated code is announced',
    );
    expect(
      find.text(AppStrings.t('product_created', 'en')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a whitespace-only barcode counts as empty and is generated',
      (tester) async {
    final dio = MockDio();
    _stub(dio, responseBarcode: _generatedBarcode);
    await _pumpForm(tester, dio);

    await tester.enterText(
      find.byKey(const Key('product-barcode-field')),
      '    ',
    );
    await _submit(tester);

    expect(_sentPayload(dio).containsKey('barcode'), isFalse);
    expect(
      find.textContaining(_generatedBarcode),
      findsOneWidget,
      reason: 'the generated code is still announced',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening a created product shows its generated barcode',
      (tester) async {
    final dio = MockDio();
    _stub(dio, responseBarcode: _generatedBarcode);
    await _pumpForm(tester, dio);
    await _submit(tester);
    expect(_sentPayload(dio).containsKey('barcode'), isFalse);

    // The product list now holds what the backend returned; editing it seeds
    // the field from that stored value (no loss, no second generation).
    final created = ProductModel.fromJson(_createdProduct(_generatedBarcode));
    expect(created.barcode, _generatedBarcode);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          currentUserProvider.overrideWithValue(
            const AuthUser(
              id: 'admin-1',
              fullName: 'Admin',
              isActive: true,
              roles: ['admin'],
              permissions: _scopes,
            ),
          ),
          localeProvider
              .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-edit'),
                onPressed: () => showProductFormDialog(
                  context,
                  product: created,
                ),
                child: const Text('edit'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-edit')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('product-barcode-field')))
          .controller
          ?.text,
      _generatedBarcode,
    );
    expect(tester.takeException(), isNull);
  });
}
