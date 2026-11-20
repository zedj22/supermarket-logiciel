// POS return mode — cart panel Return button, mode banner, confirm/cancel,
// idempotent POST /api/v1/returns, cart kept until the server confirms.
//
// The flow reuses the existing ReturnsApi command side; these tests pin
// the POS wiring: permission gate, mode UI, payload shape (independent
// lines in base units), retry with the SAME client_request_id, and a
// cancel that never calls the API.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pos_catalog_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

class FakeCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => true;

  @override
  Future<String?> readToken() async => 'tok-pos';

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

const _productId = '00000000-0000-0000-0000-0000000000p1';
const _returnsPath = '/api/v1/returns';

const _scopes = <String>['pos_sale', 'pos_return', 'product_view'];

/// Bodies posted to POST /api/v1/returns (reset per mockReturnDio).
final List<Map<String, dynamic>> returnPostBodies = <Map<String, dynamic>>[];

Response<dynamic> _ok(String path, Object? data) => Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

Map<String, dynamic> _returnSuccessBody({bool replay = false}) => {
      'return': {
        'id': 'ret-1',
        'return_number': 'RET-001',
        'sale_id': null,
        'invoice_number': null,
        'customer_id': null,
        'user_id': 'u1',
        'reason': 'other',
        'subtotal': '20',
        'discount': '0',
        'total': '20',
        'note': null,
        'device_id': 'pos-test',
        'client_request_id': null,
        'return_date': '2026-01-01T10:00:00',
        'lines': <dynamic>[],
      },
      'idempotent_replay': replay,
      'refund_total': '20.00',
      'credit_reversed': '0',
      'cash_pending': '20.00',
    };

void _mockReturnDio(
  MockDio dio, {
  List<String> scopes = _scopes,
  int? returnsErrorStatus,
  bool returnsNetworkError = false,
  bool replaySuccess = false,
}) {
  returnPostBodies.clear();

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  Object? bodyFor(String path) {
    if (path == '/api/v1/products') {
      return {
        'items': [
          {
            'id': _productId,
            'name': 'Bread',
            'barcode': '111',
            'unit': 'piece',
            'price': '10.0',
            'cost': '5',
            'avg_cost': '5',
            'quantity': '20',
            'low_stock_threshold': '5',
            'allow_negative_stock': false,
            'category_id': null,
            'category_name': null,
            'image_path': null,
            'is_archived': false,
          },
        ],
        'total': 1,
      };
    }
    if (path == '/api/v1/pos/favorites' || path == '/api/v1/pos/holds') {
      return {'items': <dynamic>[], 'total': 0};
    }
    if (path == '/api/v1/settings') {
      return {'items': <dynamic>[]};
    }
    return {'items': <dynamic>[], 'total': 0};
  }

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, bodyFor(path));
  });

  Response<dynamic> postAnswer(Invocation invocation) {
    final path = invocation.positionalArguments.first as String? ?? '';
    if (path == '/api/v1/auth/login') {
      return _ok(path, {
        'access_token': 'tok-pos',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': '00000000-0000-0000-0000-0000000000b1',
          'full_name': 'Cashier',
          'is_active': true,
          'roles': [
            {
              'name': 'cashier',
              'permissions': [
                for (final s in scopes)
                  {'id': 'p-$s', 'scope': s, 'description': null},
              ],
            },
          ],
        },
      });
    }
    if (path == _returnsPath) {
      final data = invocation.namedArguments[#data];
      if (data is Map) {
        returnPostBodies.add(Map<String, dynamic>.from(data));
      }
      if (returnsNetworkError) {
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: path),
          reason: 'connection refused',
        );
      }
      if (returnsErrorStatus != null) {
        throw DioException(
          requestOptions: RequestOptions(path: path),
          type: DioExceptionType.badResponse,
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: returnsErrorStatus,
            data: {
              'error': {
                'code': 'RETURN_LINE_INVALID',
                'message': 'invalid return line',
              },
            },
          ),
        );
      }
      return _ok(path, _returnSuccessBody(replay: replaySuccess));
    }
    return _ok(path, <String, dynamic>{});
  }

  when(() => dio.post(any(), data: any(named: 'data')))
      .thenAnswer((invocation) async => postAnswer(invocation));
  when(() => dio.post(any())).thenAnswer(
    (invocation) async => postAnswer(invocation),
  );
  when(
    () => dio.post(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenAnswer((invocation) async => postAnswer(invocation));
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required MockDio dio,
  List<String> permissions = _scopes,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final user = AuthUser(
    id: '00000000-0000-0000-0000-0000000000b1',
    fullName: 'Cashier',
    isActive: true,
    roles: const ['cashier'],
    permissions: permissions,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(user),
        posCatalogMode(),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: PosScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byKey(const Key('pos-screen'))),
      listen: false,
    );

void _seedCart(
  WidgetTester tester, {
  String quantity = '2',
  String? unitMultiplier,
  String? sellingUnitId,
}) {
  _container(tester).read(posCartProvider.notifier).addLine(
        CartLine(
          productId: _productId,
          sellingUnitId: sellingUnitId,
          name: 'Bread',
          quantity: quantity,
          unitPrice: '10',
          unitMultiplier: unitMultiplier,
        ),
      );
}

void main() {
  group('POS return mode', () {
    testWidgets('Return button: hidden without permission, disabled when '
        'cart is empty, enabled with a line', (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio);
      await _pumpApp(
        tester,
        dio: dio,
        permissions: const ['pos_sale', 'product_view'],
      );

      expect(find.byKey(const Key('pos-return-button')), findsNothing);

      await _pumpApp(tester, dio: dio);
      expect(
        find.byKey(const Key('pos-return-button')),
        findsOneWidget,
        reason: 'pos_return button should show with the permission',
      );
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('pos-return-button')),
      );
      expect(button.onPressed, isNull); // empty cart → disabled

      _seedCart(tester);
      await tester.pump();
      final enabled = tester.widget<OutlinedButton>(
        find.byKey(const Key('pos-return-button')),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('entering the mode shows the banner + confirm/cancel, hides '
        'PAY, disables hold, keeps the lines', (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio);
      await _pumpApp(tester, dio: dio);
      _seedCart(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pump();

      expect(find.byKey(const Key('pos-return-banner')), findsOneWidget);
      expect(
        find.text(AppStrings.t('pos_return_mode', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pos-return-confirm-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-return-cancel-button')), findsOneWidget);
      expect(find.byKey(const Key('pos-pay-button')), findsNothing);
      // The Return entry button is gone while the mode owns the cart.
      expect(find.byKey(const Key('pos-return-button')), findsNothing);

      final hold = tester.widget<OutlinedButton>(
        find.byKey(const Key('pos-hold-button')),
      );
      expect(hold.onPressed, isNull);

      final cart = _container(tester).read(posCartProvider);
      expect(cart.returnMode, isTrue);
      expect(cart.lines, hasLength(1));
    });

    testWidgets('cancel exits the mode with the cart untouched and no API '
        'call', (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio);
      await _pumpApp(tester, dio: dio);
      _seedCart(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-return-cancel-button')));
      await tester.pump();

      expect(find.byKey(const Key('pos-return-banner')), findsNothing);
      expect(find.byKey(const Key('pos-pay-button')), findsOneWidget);
      expect(returnPostBodies, isEmpty);

      final cart = _container(tester).read(posCartProvider);
      expect(cart.returnMode, isFalse);
      expect(cart.lines, hasLength(1));
    });

    testWidgets('confirm posts ONE independent return (base units), clears '
        'the cart and shows the server refund', (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio);
      await _pumpApp(tester, dio: dio);
      // 2 base + 1 box (×10) of the same product merge to 12 base units.
      _seedCart(tester, quantity: '2');
      _container(tester).read(posCartProvider.notifier).addLine(
            CartLine(
              productId: _productId,
              sellingUnitId: 'unit-box',
              name: 'Bread (Box)',
              quantity: '1',
              unitPrice: '90',
              unitMultiplier: '10',
            ),
          );
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-return-confirm-button')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(returnPostBodies, hasLength(1));
      final payload = returnPostBodies.single;
      final clientRequestId = '${payload['client_request_id']}';
      expect(clientRequestId, startsWith('pos-ret-'));
      expect(payload['device_id'], isNotNull);
      expect(payload['lines'], [
        {'product_id': _productId, 'quantity': '12'},
      ]);

      expect(find.byKey(const Key('return-success-snackbar')), findsOneWidget);
      expect(
        find.text(AppStrings.t('return_success', 'en')),
        findsWidgets,
      );

      final cart = _container(tester).read(posCartProvider);
      expect(cart.isEmpty, isTrue);
      expect(cart.returnMode, isFalse);
      expect(cart.returnPending, isFalse);
      expect(cart.pendingReturnClientRequestId, isNull);
    });

    testWidgets('failure keeps cart + mode, shows the banner error, and the '
        'retry replays the SAME client_request_id', (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio, returnsErrorStatus: 500);
      await _pumpApp(tester, dio: dio);
      _seedCart(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-return-confirm-button')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(returnPostBodies, hasLength(1));
      expect(find.byKey(const Key('pos-return-banner-error')), findsOneWidget);
      expect(find.byKey(const Key('pos-return-confirm-button')), findsOneWidget);

      var cart = _container(tester).read(posCartProvider);
      expect(cart.isEmpty, isFalse);
      expect(cart.returnMode, isTrue);
      expect(cart.returnPending, isFalse);
      final firstId = '${cart.pendingReturnClientRequestId}';

      // Retry — the mock still fails, but the id must be replayed.
      await tester.tap(find.byKey(const Key('pos-return-confirm-button')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(returnPostBodies, hasLength(2));
      expect(
        returnPostBodies.last['client_request_id'],
        firstId,
      );
    });

    testWidgets('an idempotent replay response reports the replay notice',
        (tester) async {
      final dio = MockDio();
      _mockReturnDio(dio, replaySuccess: true);
      await _pumpApp(tester, dio: dio);
      _seedCart(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('pos-return-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-return-confirm-button')));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(
        find.text(AppStrings.t('return_replay', 'en')),
        findsWidgets,
      );
      expect(_container(tester).read(posCartProvider).isEmpty, isTrue);
    });
  });
}
