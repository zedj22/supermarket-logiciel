// F8 + SPACE — the two POS payment shortcuts.
//
// Both keys funnel into the SAME branch of `_handleShortcut`, so they can
// never diverge; the focus rules keep them out of text fields and dialogs,
// and the existing single-attempt guard keeps a double press from producing
// two checkout requests.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
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
  Future<List<String>> readUserRoles() async => const ['cashier'];

  @override
  Future<List<String>> readUserPermissions() async => const [];

  @override
  Future<void> clearAll() async {}
}

const _scopes = <String>['pos_sale', 'product_view'];

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

Map<String, dynamic> _saleJson() => <String, dynamic>{
      'id': 'sale-1',
      'invoice_number': 'INV-1',
      'status': 'completed',
      'subtotal': '10.000',
      'discount': '0.000',
      'total': '10.000',
      'paid': '10.000',
      'change': '0.000',
      'debt': '0.000',
      'payment_method': 'cash',
    };

class _Api {
  int salePosts = 0;
}

void _mockDio(MockDio dio, _Api api, {Completer<Response<dynamic>>? salesGate}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer(
    (invocation) async => _ok(
      invocation.positionalArguments.first as String? ?? '',
      <String, Object>{'items': <dynamic>[], 'total': 0},
    ),
  );
  when(() => dio.get(any())).thenAnswer(
    (invocation) async => _ok(
      invocation.positionalArguments.first as String? ?? '',
      <String, Object>{'items': <dynamic>[], 'total': 0},
    ),
  );

  Future<Response<dynamic>> postAnswer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == '/api/v1/sales') {
      api.salePosts++;
      if (salesGate != null) return salesGate.future;
      return _ok(path, _saleJson());
    }
    return _ok(path, <String, dynamic>{});
  }

  // Checkout sends `data` AND `options` — stub the exact call shape.
  when(
    () => dio.post(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer(postAnswer);
  when(() => dio.post(any(), data: any(named: 'data')))
      .thenAnswer(postAnswer);
  when(() => dio.post(any())).thenAnswer(postAnswer);
}

AuthUser _user() => AuthUser(
      id: 'u-1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<ProviderContainer> _pumpPos(
  WidgetTester tester,
  MockDio dio, {
  int lines = 1,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final cart = PosCartNotifier(dio, () => 'en', () async => 'pos-test');
  for (var i = 0; i < lines; i++) {
    cart.addLine(CartLine(
      productId: 'p$i',
      name: 'Product $i',
      quantity: '1',
      unitPrice: '10',
      availableStock: '20',
    ));
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user()),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
        posCartProvider.overrideWith((ref) => cart),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: PosScreen()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(
    tester.element(find.byKey(const Key('pos-screen'))),
    listen: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets('F8 opens the SAME payment dialog SPACE does', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    await _pumpPos(tester, dio);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('payment-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-dialog')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('payment-cancel')));
    await tester.pumpAndSettle();
    expect(api.salePosts, 0, reason: 'opening the dialog charges nothing');
  });

  testWidgets('F8 declines while the cashier is typing a query',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    await _pumpPos(tester, dio);

    await tester.enterText(
      find.byKey(const Key('pos-search-field')),
      'bread',
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('payment-dialog')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pos-search-field')))
          .controller!
          .text,
      'bread',
    );
    expect(api.salePosts, 0);
  });

  testWidgets('F8 inside an open dialog changes nothing', (tester) async {
    final dio = MockDio();
    final api = _Api();
    _mockDio(dio, api);
    await _pumpPos(tester, dio);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-dialog')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-dialog')), findsOneWidget);
    expect(api.salePosts, 0);

    await tester.tap(find.byKey(const Key('payment-cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('F8 with Quick sale ON completes ONE sale for a double press',
      (tester) async {
    final dio = MockDio();
    final api = _Api();
    final gate = Completer<Response<dynamic>>();
    _mockDio(dio, api, salesGate: gate);
    final container = await _pumpPos(tester, dio);
    container.read(posSettingsProvider.notifier).setQuickSaleWithSpace(true);
    await tester.pump();

    // Two presses with no frame in between: the second one lands while the
    // first checkout is in flight.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();

    expect(api.salePosts, 1, reason: 'one attempt, one request');

    gate.complete(_ok('/api/v1/sales', _saleJson()));
    await tester.pumpAndSettle();

    expect(api.salePosts, 1);
    expect(container.read(posCartProvider).lines, isEmpty,
        reason: 'the confirmed sale clears the cart');
  });
}
