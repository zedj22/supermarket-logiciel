// Product form Pricing row — live profit / markup display.
//
// The percentage under the Pricing section is MARKUP ON COST
// (`((price - cost) / cost) * 100`), not the gross margin on the selling
// price that the products table shows:
//   cost 2 000 / price 4 000 → profit 2 000, markup 100% (never 50%).
// Profit stays `price - cost`; the percentage is display-only like every
// other figure in this dialog (nothing is persisted).
//
// Also pinned here: a zero / empty / unparsable cost shows no percentage
// at all (no division by zero, no misleading number), and the label is
// localized in ar / fr / en.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

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
  Future<void> saveUserName(String userName) async {}

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

/// Cost visibility (`canSeeCost`) is gated on `product_update`.
const _scopes = ['product_view', 'product_update', 'product_create'];

const _priceKey = Key('product-price-field');
const _costKey = Key('product-cost-field');
const _profitKey = Key('product-form-profit');
const _markupKey = Key('product-form-markup');

void _stub(MockDio dio, {List<String> scopes = _scopes}) {
  Response<dynamic> ok(String path, Object? data) => Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: data,
      );

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer(
    (invocation) async => ok(
      invocation.positionalArguments.first as String? ?? '',
      {'items': <dynamic>[], 'total': 0, 'page': 1, 'page_size': 100,
       'pages': 1},
    ),
  );
  when(() => dio.get(any())).thenAnswer(
    (invocation) async => ok(
      invocation.positionalArguments.first as String? ?? '',
      {'items': <dynamic>[], 'total': 0},
    ),
  );
  // Session restore: the dialog's permission gates read the auth state,
  // so verify-token must answer with the scopes under test.
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async => ok(
      invocation.positionalArguments.first as String? ?? '',
      {
        'valid': true,
        'user': {
          'id': '00000000-0000-0000-0000-0000000000a1',
          'full_name': 'Admin',
          'is_active': true,
          'permissions': scopes,
          'roles': [
            {
              'name': 'admin',
              'permissions': [for (final s in scopes) {'scope': s}],
            },
          ],
        },
      },
    ),
  );
}

Future<void> _pumpForm(
  WidgetTester tester,
  MockDio dio, {
  AppLocale locale = AppLocale.en,
  List<String> scopes = _scopes,
}) async {
  final storage = FakeCredentialStorage();
  await storage.saveToken('tok');
  await storage.saveUserPermissions(scopes);
  await storage.saveUserRoles(const ['admin']);

  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(storage),
        localeProvider.overrideWith((_) => LocaleNotifier()..setLocale(locale)),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: const Scaffold(body: ProductFormDialog()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('product-form-dialog')), findsOneWidget);
}

Future<void> _open(
  WidgetTester tester, {
  AppLocale locale = AppLocale.en,
  List<String> scopes = _scopes,
}) async {
  final dio = MockDio();
  _stub(dio, scopes: scopes);
  await _pumpForm(tester, dio, locale: locale, scopes: scopes);
}

String _figure(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data ?? '';

Future<void> _type(
  WidgetTester tester, {
  required String price,
  required String cost,
}) async {
  await tester.enterText(find.byKey(_priceKey), price);
  await tester.enterText(find.byKey(_costKey), cost);
  await tester.pump();
}

void main() {
  group('product form markup on cost (Pricing row)', () {
    testWidgets('cost 2 000 / price 4 000 shows profit 2 000 and 100%', (
      tester,
    ) async {
      await _open(tester);
      await _type(tester, price: '4000', cost: '2000');

      expect(_figure(tester, _profitKey), '2000.000');
      expect(_figure(tester, _markupKey), '100.00%');
      // The margin-on-price figure must never be rendered here.
      expect(_figure(tester, _markupKey), isNot('50.00%'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('cost 2 000 / price 3 000 shows 50% and price 2 500 shows '
        '25%', (tester) async {
      await _open(tester);

      await _type(tester, price: '3000', cost: '2000');
      expect(_figure(tester, _profitKey), '1000.000');
      expect(_figure(tester, _markupKey), '50.00%');

      await _type(tester, price: '2500', cost: '2000');
      expect(_figure(tester, _profitKey), '500.000');
      expect(_figure(tester, _markupKey), '25.00%');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero cost keeps the profit but shows no percentage', (
      tester,
    ) async {
      await _open(tester);
      await _type(tester, price: '4000', cost: '0');

      expect(_figure(tester, _profitKey), '4000.000');
      expect(_figure(tester, _markupKey), '—');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty cost shows no figures (never a partial guess)', (
      tester,
    ) async {
      await _open(tester);
      await _type(tester, price: '4000', cost: '');

      expect(_figure(tester, _profitKey), '—');
      expect(_figure(tester, _markupKey), '—');
      expect(tester.takeException(), isNull);
    });

    testWidgets('selling below cost reports negative profit and markup', (
      tester,
    ) async {
      await _open(tester);
      await _type(tester, price: '2000', cost: '3000');

      expect(_figure(tester, _profitKey), '-1000.000');
      expect(_figure(tester, _markupKey), '-33.33%');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the row only renders for users who may see the cost', (
      tester,
    ) async {
      await _open(tester, scopes: const ['product_view']);

      expect(find.byKey(_costKey), findsNothing);
      expect(find.byKey(_profitKey), findsNothing);
      expect(find.byKey(_markupKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('markup label localization', () {
    for (final locale in [AppLocale.ar, AppLocale.fr, AppLocale.en]) {
      testWidgets('the percentage is labeled "$locale"', (tester) async {
        await _open(tester, locale: locale);
        final code = locale.name;

        expect(
          find.text(AppStrings.t('markup', code)),
          findsOneWidget,
          reason: 'markup label missing for $code',
        );
        // The products-table margin label must not label this figure.
        expect(
          find.text(AppStrings.t('margin', code)),
          findsNothing,
          reason: 'the form shows markup on cost, not the margin',
        );

        await _type(tester, price: '4000', cost: '2000');
        expect(_figure(tester, _markupKey), '100.00%');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Arabic renders the figures without exceptions', (tester) async {
      await _open(tester, locale: AppLocale.ar);
      await _type(tester, price: '4000', cost: '2000');

      expect(find.text('هامش على التكلفة'), findsOneWidget);
      expect(_figure(tester, _profitKey), '2000.000');
      expect(_figure(tester, _markupKey), '100.00%');
      expect(tester.takeException(), isNull);
    });
  });
}
