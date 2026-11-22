// Enter saves the product form — the same single pathway as the Save button.
//
// Contract under test:
//  * Enter in any single-line field runs `_submit` (create AND edit), so the
//    keyboard and the mouse cannot diverge;
//  * one Enter = one request: a second Enter, or Enter while the first save
//    is still in flight, never creates a second product;
//  * validation still wins — an invalid form keeps the dialog open and shows
//    the error, and nothing is sent;
//  * the barcode contract is untouched (empty field → backend generates and
//    the code is announced; a typed code travels verbatim);
//  * the multiline description keeps Enter for a newline, and an open
//    dropdown keeps Enter for its own menu — neither can save by accident.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
const _productId = '00000000-0000-0000-0000-0000000000c1';

const _scopes = ['product_view', 'product_create', 'product_update'];

Map<String, dynamic> _productJson({
  String name = 'Yaourt',
  String barcode = _generatedBarcode,
}) =>
    {
      'id': _productId,
      'name': name,
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

/// Stubs every non-product call the form makes (categories, permissions, …)
/// and hands product writes to [onCreate] / [onUpdate].
void _stub(
  MockDio dio, {
  Future<Response<dynamic>> Function()? onCreate,
  Future<Response<dynamic>> Function()? onUpdate,
  String responseBarcode = _generatedBarcode,
}) {
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
    (_) async => onCreate != null
        ? await onCreate()
        : _ok(_productsPath, _productJson(barcode: responseBarcode)),
  );

  when(() => dio.put(any(), data: any(named: 'data'))).thenAnswer(
    (_) async => onUpdate != null
        ? await onUpdate()
        : _ok('$_productsPath/$_productId', _productJson(name: 'Yaourt')),
  );
}

Future<void> _pumpForm(
  WidgetTester tester,
  MockDio dio, {
  ProductModel? product,
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
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
        localeProvider
            .overrideWith((_) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('open-form'),
              onPressed: () => showProductFormDialog(context, product: product),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-form')));
  await tester.pumpAndSettle();
}

/// A real hardware Enter key, the way an operator presses it.
Future<void> _pressEnter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

Future<void> _fillValidForm(
  WidgetTester tester, {
  String name = 'Yaourt',
}) async {
  await tester.enterText(find.byKey(const Key('product-name-field')), name);
  await tester.enterText(find.byKey(const Key('product-price-field')), '120');
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Enter submits', () {
    testWidgets('Enter in the price field saves a NEW product', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await _pressEnter(tester);

      verify(() => dio.post(_productsPath, data: any(named: 'data')))
          .called(1);
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter in the name field saves too (any single-line field)',
        (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await tester.showKeyboard(find.byKey(const Key('product-name-field')));
      await _pressEnter(tester);

      verify(() => dio.post(_productsPath, data: any(named: 'data')))
          .called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter saves an EDITED product through the same pathway',
        (tester) async {
      final dio = MockDio();
      _stub(dio);
      final product = ProductModel.fromJson(_productJson());
      await _pumpForm(tester, dio, product: product);

      // Edit mode is prefilled — only the name changes.
      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Yaourt nature',
      );
      await tester.pump();
      await _pressEnter(tester);

      verify(() => dio.put('$_productsPath/$_productId',
          data: any(named: 'data'))).called(1);
      verifyNever(() => dio.post(_productsPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('validation and the save guard', () {
    testWidgets('an invalid form does not save and stays open', (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);

      // No name → `_validate` fails before any request.
      await _pressEnter(tester);

      verifyNever(() => dio.post(_productsPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('product-form-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('three Enter presses while saving send exactly one request',
        (tester) async {
      final dio = MockDio();
      final gate = Completer<void>();
      _stub(dio, onCreate: () async {
        await gate.future;
        return _ok(_productsPath, _productJson());
      });
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      // The save button is already disabled while in flight…
      final saveButton = tester.widget<ElevatedButton>(
        find.byKey(const Key('product-form-submit')),
      );
      expect(saveButton.onPressed, isNull);

      gate.complete();
      await tester.pumpAndSettle();

      verify(() => dio.post(_productsPath, data: any(named: 'data')))
          .called(1);
      expect(find.byKey(const Key('product-form-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter after a failed save does not duplicate anything',
        (tester) async {
      final dio = MockDio();
      var calls = 0;
      _stub(dio, onCreate: () async {
        calls++;
        // Real Dio turns a 5xx into a thrown DioException — a bare 500
        // `Response` would be parsed as a product, not rejected.
        throw DioException(
          requestOptions: RequestOptions(path: _productsPath),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: _productsPath),
            statusCode: 500,
            data: {'detail': 'boom'},
          ),
          type: DioExceptionType.badResponse,
        );
      });
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await _pressEnter(tester);
      // The dialog stays open with the server message on screen.
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('product-form-error')), findsOneWidget);

      await _pressEnter(tester);
      expect(calls, 2, reason: 'a retry is a real second attempt, one per Enter');
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the barcode contract survives the keyboard path', () {
    testWidgets('an empty barcode field still generates one and announces it',
        (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await _pressEnter(tester);

      final payload = verify(
        () => dio.post(_productsPath, data: captureAny(named: 'data')),
      ).captured.single as Map;
      expect(payload.containsKey('barcode'), isFalse);
      expect(
        find.textContaining('${AppStrings.t('barcode', 'en')}: $_generatedBarcode'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a typed barcode travels verbatim', (tester) async {
      final dio = MockDio();
      _stub(dio, responseBarcode: '6130000112233');
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);
      await tester.enterText(
        find.byKey(const Key('product-barcode-field')),
        '6130000112233',
      );
      await tester.pump();

      await _pressEnter(tester);

      final payload = verify(
        () => dio.post(_productsPath, data: captureAny(named: 'data')),
      ).captured.single as Map;
      expect(payload['barcode'], '6130000112233');
      expect(tester.takeException(), isNull);
    });
  });

  group('controls that own Enter keep it', () {
    testWidgets('Enter in the multiline description is a newline, never a save',
        (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      final description = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 2,
      );
      await tester.enterText(description, 'Ligne');
      await _pressEnter(tester);

      verifyNever(() => dio.post(_productsPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      // The field keeps its own Enter (a newline, inserted by the IME on
      // desktop). What matters here is that the dialog did not save.
      final field = tester.widget<TextField>(description);
      expect(field.controller!.text, 'Ligne');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an open dropdown consumes Enter and does not save',
        (tester) async {
      final dio = MockDio();
      _stub(dio);
      await _pumpForm(tester, dio);
      await _fillValidForm(tester);

      await tester.tap(find.byKey(const Key('product-unit-field')));
      await tester.pumpAndSettle();
      // The menu is up…
      expect(find.text(AppStrings.unitLabel('kg', 'en')), findsWidgets);

      await _pressEnter(tester);

      verifyNever(() => dio.post(_productsPath, data: any(named: 'data')));
      expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
