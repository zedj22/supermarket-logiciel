// Shift+F6 / Shift+F7 — the POS dialog shortcuts.
//
// - Shift+F6 opens the SHARED client form (client-form-dialog) straight
//   from the workspace — no picker first — gated by customer_manage: a
//   denied permission toasts permission_denied and opens NOTHING;
// - a successful create selects the customer for THIS sale, re-loads the
//   customer-search data AFTER the create POST (stale query reset, fresh
//   record in the list) and hands focus back to the search field; cancel
//   changes nothing;
// - the combo declines while a query is actually being typed (the shared
//   focus gate) — the text survives untouched;
// - Shift+F7 runs the redemption button's OWN flow: eligibility re-checked
//   in the ONE redemption method, the ONE loyalty dialog, the discount
//   applied only on Confirm; a double press never stacks a second dialog;
// - exact-modifier matching keeps the plain F6 picker / F7 invoice-discount
//   dialogs out of every Shift-combo press (they would have to fire too —
//   CallbackShortcuts invokes every matching activator);
// - dialog inputs never reach the page's bindings: their route scopes own
//   the keys before this layer is consulted.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pos_catalog_mode.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/loyalty/loyalty_providers.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';

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
  Future<List<String>> readUserRoles() async => ['cashier'];

  @override
  Future<List<String>> readUserPermissions() async => [];

  @override
  Future<void> clearAll() async {}
}

class _FakePdfPreview implements PdfPreviewBuilder {
  @override
  Widget build(
    Uint8List bytes, {
    required String paper,
    String? filename,
  }) =>
        const Text('pdf');
}

const _customerId = 'cust-1';
const _customersPath = '/api/v1/customers';
const _searchPath = '$_customersPath/search';

/// The scopes a normal cashier holds — customer_manage INCLUDED (the F6
/// form's gate) and pos_discount INCLUDED (the plain-F7 discount dialog:
/// were it to double-fire on a Shift+F7 press, its dialog would show up).
const _scopes = <String>[
  'pos_sale',
  'pos_discount',
  'product_view',
  'customer_view',
  'customer_manage',
];

Response<dynamic> _ok(String path, Object? data, {int status = 200}) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    );

/// Balance with ONE redeemable reward → the redemption entry unlocks
/// (server gate: available_rewards > 0). [eligible] false serves the
/// disabled-button contract.
Map<String, Object> _balanceJson({bool eligible = true}) => <String, Object>{
      'customer_id': _customerId,
      'has_account': true,
      'points_balance': '130.000',
      'cashback_balance': '25.000',
      'available_rewards': eligible ? 1 : 0,
      'remaining_points': '30.000',
      'min_reward_points': 100,
    };

/// The create answer's shape — the same CustomerModel JSON the clients
/// pages POST against (String balance, timestamps, debt ceiling).
Map<String, dynamic> _customerJson({
  String id = 'c-new',
  String name = 'Fresh Customer',
  String? phone,
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'phone': phone,
      'address': null,
      'balance': '0.000',
      'debt_ceiling': '0.000',
      'is_archived': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, Object> _listBody(List<Map<String, dynamic>> items) =>
    <String, Object>{
      'items': items,
      'total': items.length,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };

class _Api {
  /// 'GET /path' / 'POST /path' in invocation order.
  final List<String> events = <String>[];
}

/// One catch-all stub per verb with an event log (refresh-AFTER-create
/// assertions) plus the loyalty session/preview answers. The customer
/// search answer only contains the new record AFTER the create POST — the
/// refreshed-list assertion would otherwise pass without any reload.
void _mockPosDio(
  MockDio dio,
  _Api api, {
  bool loyaltyEligible = true,
}) {
  Object? getBody(String path) {
    if (path.startsWith('/api/v1/customers/') && path.endsWith('/loyalty')) {
      return _balanceJson(eligible: loyaltyEligible);
    }
    if (path == _searchPath) {
      final created = api.events.contains('POST $_customersPath');
      return _listBody(
        created ? <Map<String, dynamic>>[_customerJson()] : const [],
      );
    }
    return _listBody(const []);
  }

  Object? postBody(String path, Object? data) {
    if (path.endsWith('/loyalty/preview')) {
      final map = Map<String, dynamic>.from((data as Map?) ?? const {});
      final gross = double.parse('${map['gross_total']}');
      final percent = ((map['reward_percent'] as num?) ?? 0).toDouble();
      final discount = gross * percent / 100;
      return <String, Object>{
        'customer_id': map['customer_id'],
        'gross_total': map['gross_total'],
        'reward_percent': percent,
        'reward_discount': discount.toStringAsFixed(3),
        'amount_due': (gross - discount).toStringAsFixed(3),
        'available_rewards': loyaltyEligible ? 1 : 0,
        'remaining_points': '30.000',
        'min_reward_points': 100,
        'max_reward_discount_percent': '20.000',
        'points_balance': '130.000',
        'cashback_balance': '25.000',
        'points_earned': '0.960',
        'cashback_earned': '0.500',
        'points_after_sale': '130.960',
        'reward_eligible': loyaltyEligible,
      };
    }
    return <String, dynamic>{};
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());

  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('GET $path');
    return _ok(path, getBody(path));
  });

  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('GET $path');
    return _ok(path, getBody(path));
  });

  Future<Response<dynamic>> postAnswer(Invocation invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    api.events.add('POST $path');
    final data = invocation.namedArguments[#data];
    if (path == _customersPath) {
      final payload = Map<String, dynamic>.from((data as Map?) ?? const {});
      return _ok(
        path,
        _customerJson(
          name: '${payload['name']}',
          phone: payload['phone'] as String?,
        ),
        status: 201,
      );
    }
    return _ok(path, postBody(path, data));
  }

  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(postAnswer);
  when(() => dio.post(any())).thenAnswer(postAnswer);
  when(() => dio.delete(any())).thenAnswer(
    (_) async => _ok('/deleted', <String, dynamic>{}, status: 204),
  );
}

AuthUser _user(List<String> scopes) => AuthUser(
      id: 'u-1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: scopes,
    );

Future<ProviderContainer> _pumpPos(
  WidgetTester tester, {
  required MockDio dio,
  int lines = 1,
  List<String> permissions = _scopes,
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
    ));
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user(permissions)),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
        pdfPreviewProvider.overrideWithValue(_FakePdfPreview()),
        posCartProvider.overrideWith((ref) => cart),
        posCatalogMode(),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
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

/// Attaches the customer AFTER the screen is up — the real user flow
/// (ref.listen → balance + preview → loyalty block).
Future<void> _attachCustomer(
  WidgetTester tester,
  ProviderContainer container,
) async {
  container.read(posCartProvider.notifier).setCustomer(const PosCustomer(
        id: _customerId,
        name: 'Loyal Customer',
        phone: '0555 12 34 56',
      ));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
}

/// One Shift-combo activation: the modifier held across the key's own
/// down/up cycle (sendKeyEvent carries no modifier arguments).
Future<void> _pressCombo(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

/// Value key of the focused TextField, if any — the post-dialog focus
/// assertions (the combo hands primary focus back to the search field).
String? focusedFieldKey(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final field = context.widget is TextField
      ? context.widget as TextField
      : context.findAncestorWidgetOfExactType<TextField>();
  final key = field?.key;
  return key is ValueKey<String> ? key.value : null;
}

String searchBoxText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('pos-search-field'))).controller!.text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('Shift+F6 — add customer', () {
    testWidgets(
        'opens the shared customer form directly — never the plain-F6 '
        'picker, posts nothing', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio);

      await _pressCombo(tester, LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);
      expect(find.byKey(const Key('client-name-field')), findsOneWidget);
      expect(
        find.byKey(const Key('customer-picker-dialog')),
        findsNothing,
        reason: 'the exact-modifier match keeps the plain-F6 picker out',
      );
      expect(
        api.events.where((e) => e.startsWith('POST')),
        isEmpty,
        reason: 'opening posts nothing',
      );
      expect(container.read(posCartProvider).customer, isNull);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('client-form-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
    });

    testWidgets('denied without customer_manage: toasts permission_denied '
        'and opens no form', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      await _pumpPos(
        tester,
        dio: dio,
        permissions: const ['pos_sale', 'product_view', 'customer_view'],
      );

      await _pressCombo(tester, LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(
        find.text(AppStrings.t('permission_denied', 'en')),
        findsOneWidget,
        reason: 'the same generic toast every gated action shows',
      );
      expect(api.events.where((e) => e.startsWith('POST')), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets(
        'create: selects the customer, re-loads the search data AFTER the '
        'POST and restores search focus', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio, lines: 2);
      container.read(posCartProvider.notifier).setInvoiceDiscount('3');
      // A non-empty picker query proves the refresh RESETS it.
      container.read(customerSearchProvider.notifier).setQuery('junk');
      await tester.pump();

      await _pressCombo(tester, LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('client-name-field')));
      await tester.enterText(
        find.byKey(const Key('client-name-field')),
        'Fresh Customer',
      );
      await tester.ensureVisible(find.byKey(const Key('client-phone-field')));
      await tester.enterText(
        find.byKey(const Key('client-phone-field')),
        '0555123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('client-form-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(find.byKey(const Key('client-form-success-toast')), findsOneWidget);

      final cart = container.read(posCartProvider);
      expect(cart.customer?.id, 'c-new');
      expect(cart.customer?.name, 'Fresh Customer');
      expect(cart.lines, hasLength(2));
      expect(cart.lines.every((l) => l.quantity == '1'), isTrue);
      expect(cart.invoiceDiscount, '3',
          reason: 'the sale around the create is untouched');

      final postAt = api.events.indexOf('POST $_customersPath');
      expect(postAt, greaterThan(-1));
      final afterCreate = api.events.sublist(postAt + 1);
      expect(
        afterCreate.where(
          (e) => e == 'GET $_searchPath' || e == 'GET $_customersPath',
        ),
        isNotEmpty,
        reason: 'the customer-search data is reloaded AFTER the create POST',
      );

      final search = container.read(customerSearchProvider);
      expect(search.query, '', reason: 'the stale query was reset');
      expect(
        search.items.single.id,
        'c-new',
        reason: 'the refreshed list holds the new record (F6 shows it)',
      );

      expect(
        focusedFieldKey(tester),
        'pos-search-field',
        reason: 'the next keyboard-wedge burst is armed again',
      );
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets(
        'cancel: no create, no selection, cart intact, focus restored',
        (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio, lines: 1);

      await _pressCombo(tester, LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('client-form-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('client-form-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(api.events.where((e) => e.startsWith('POST')), isEmpty);
      final cart = container.read(posCartProvider);
      expect(cart.customer, isNull);
      expect(cart.lines, hasLength(1));
      expect(focusedFieldKey(tester), 'pos-search-field');
      expect(tester.takeException(), isNull);
    });

    testWidgets('declines while a query is being typed — the text survives',
        (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      await _pumpPos(tester, dio: dio);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bread',
      );
      await tester.pump();

      await _pressCombo(tester, LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('client-form-dialog')), findsNothing);
      expect(find.byKey(const Key('customer-picker-dialog')), findsNothing);
      expect(searchBoxText(tester), 'bread');
      expect(api.events.where((e) => e.startsWith('POST')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('Shift+F7 — use points', () {
    testWidgets(
        'opens the ONE redemption dialog, applies nothing until Confirm, '
        'then once — the plain-F7 discount dialog stays out', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await _pressCombo(tester, LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('invoice-discount-dialog')),
        findsNothing,
        reason: 'the exact-modifier match keeps the plain-F7 dialog out',
      );
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0,
          reason: 'opening applies nothing');
      expect(container.read(posCartProvider).invoiceDiscount, '0');

      await tester.enterText(
        find.byKey(const Key('pos-loyalty-reward-input')),
        '5',
      );
      await tester.pumpAndSettle();
      expect(
        container.read(posLoyaltyProvider).rewardPercent,
        0.0,
        reason: 'browsing a percent inside the dialog stays local',
      );

      await tester.tap(find.byKey(const Key('pos-loyalty-dialog-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(container.read(posLoyaltyProvider).rewardPercent, 5.0);
      expect(container.read(posCartProvider).invoiceDiscount, '0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('ineligible session: declines like the disabled button — no '
        'dialog, no invoice-discount dialog either', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api, loyaltyEligible: false);
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await _pressCombo(tester, LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('declines while a query is being typed — the text survives',
        (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      await tester.enterText(
        find.byKey(const Key('pos-search-field')),
        'bread',
      );
      await tester.pump();

      await _pressCombo(tester, LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
      expect(find.byKey(const Key('invoice-discount-dialog')), findsNothing);
      expect(searchBoxText(tester), 'bread');
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'two presses in one dispatch window and a press from inside the '
        'open dialog never stack a second dialog', (tester) async {
      final dio = MockDio();
      final api = _Api();
      _mockPosDio(dio, api);
      final container = await _pumpPos(tester, dio: dio, lines: 3);
      await _attachCustomer(tester, container);

      // Two full combos with NO frame between them: the second key-down
      // reaches the still-built page bindings while the first push is
      // pending — _redemptionOpen must reject it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await tester.sendKeyEvent(LogicalKeyboardKey.f7);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('pos-loyalty-dialog')),
        findsOneWidget,
        reason: 'the stack guard + the dialog route scope keep ONE dialog',
      );

      // The dialog owns focus now — its route scope sits outside the page
      // bindings, so another combo changes nothing either.
      await _pressCombo(tester, LogicalKeyboardKey.f7);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsOneWidget);
      expect(container.read(posLoyaltyProvider).rewardPercent, 0.0);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-loyalty-dialog')), findsNothing);
    });
  });
}
