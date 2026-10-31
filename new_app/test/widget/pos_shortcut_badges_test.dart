// On-button keyboard badges — the POS action buttons advertise the SAME
// keys the page's CallbackShortcuts bindings answer.
//
// Contracts:
// - every chip renders a PosShortcutKeys constant — the same table the
//   shortcuts help map documents — so badge, map and binding cannot drift
//   apart (the map rows are asserted against the very same constants);
// - the label no longer embeds the key text (no "Customer (F6)" label
//   next to an [F6] chip): the key lives ONLY in the chip, and the
//   localized label stays a pure, translatable action name;
// - the PAY chip follows the quick-sale setting: Space opens payment by
//   default and is withdrawn from PAY while Quick sale (Space) is ON —
//   the key then quick-sells, and the help map swaps its Space row the
//   same way;
// - the customer picker's quick-add carries Shift+F6 — the combo that
//   opens this SAME form straight from the workspace;
// - ar/RTL renders the chips (key symbols are locale-free literals) with
//   no exceptions and no missing badges.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/shortcuts.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/pos/pdf_preview.dart';
import 'package:supermarket_pos/features/pos/pos_screen.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';
import 'package:supermarket_pos/features/settings/scan_settings_provider.dart';
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
  Future<void> saveUserName(String userName) async {}

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

/// One catch-all stub per verb — badges never assert API payloads, the
/// screen just needs its boot/search GETs to answer.
void _stubDio(MockDio dio) {
  Object? listBody(String path) {
    if (path.endsWith('/loyalty')) {
      return <String, Object>{
        'customer_id': 'c-1',
        'has_account': false,
        'points_balance': '0.000',
        'cashback_balance': '0.000',
        'available_rewards': 0,
        'remaining_points': '0.000',
        'min_reward_points': 100,
      };
    }
    return <String, Object>{
      'items': const <Map<String, dynamic>>[],
      'total': 0,
      'page': 1,
      'page_size': 40,
      'pages': 1,
    };
  }

  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any(), queryParameters: any(named: 'queryParameters')))
      .thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, listBody(path));
  });
  when(() => dio.get(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String? ?? '';
    return _ok(path, listBody(path));
  });
  when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', {}),
    );
  when(() => dio.post(any())).thenAnswer(
    (invocation) async =>
        _ok(invocation.positionalArguments.first as String? ?? '', {}),
  );
  when(() => dio.delete(any())).thenAnswer(
    (_) async => _ok('/deleted', <String, dynamic>{}, status: 204),
  );
}

AuthUser _user() => AuthUser(
      id: 'u-1',
      fullName: 'Cashier',
      isActive: true,
      roles: const ['cashier'],
      permissions: _scopes,
    );

Future<void> _pumpPos(
  WidgetTester tester, {
  required MockDio dio,
  AppLocale locale = AppLocale.en,
  TextDirection direction = TextDirection.ltr,
  Map<String, Object>? initialPrefs,
}) async {
  SharedPreferences.setMockInitialValues(
    initialPrefs ?? <String, Object>{},
  );
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
        currentUserProvider.overrideWithValue(_user()),
        localeProvider
            .overrideWith((ref) => LocaleNotifier()..setLocale(locale)),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        posSettingsProvider.overrideWith((ref) => PosSettingsNotifier(prefs)),
        pdfPreviewProvider.overrideWithValue(_FakePdfPreview()),
      ],
      child: MaterialApp(
        locale: Locale(locale.name),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Directionality(
          textDirection: direction,
          child: const Scaffold(body: PosScreen()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

/// The badge inside [buttonKey]: the chip must carry exactly [keys] and
/// nothing else may print that key inside the button.
Finder _badge(Key buttonKey, String keys) => find.descendant(
      of: find.byKey(buttonKey),
      matching: find.text(keys),
    );

/// The localized label inside [buttonKey], as its own Text widget.
Text _label(WidgetTester tester, Key buttonKey, String labelKey) {
  final locale = 'en';
  final finder = find.descendant(
    of: find.byKey(buttonKey),
    matching: find.text(AppStrings.t(labelKey, locale)),
  );
  return tester.widget<Text>(finder);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDio dio;

  setUp(() {
    dio = MockDio();
    _stubDio(dio);
  });

  group('on-button key badges', () {
    testWidgets(
        'every POS action button carries the key its binding answers',
        (tester) async {
      await _pumpPos(tester, dio: dio);

      final expected = <Key, (String, String)>{
        // button key               label key             badge key
        const Key('pos-select-customer'): (
          'customer_shortcut',
          PosShortcutKeys.chooseCustomer,
        ),
        const Key('pos-discount-button'): (
          'discount_shortcut',
          PosShortcutKeys.invoiceDiscount,
        ),
        const Key('pos-hold-button'): ('hold_shortcut', PosShortcutKeys.hold),
        const Key('pos-holds-button'): (
          'holds_shortcut',
          PosShortcutKeys.holds,
        ),
        const Key('pos-history-button'): (
          'history_shortcut',
          PosShortcutKeys.history,
        ),
        const Key('pos-loyalty-discount-button'): (
          'loyalty_redeem',
          PosShortcutKeys.useLoyaltyPoints,
        ),
        const Key('pos-pay-button'): (
          'payment_shortcut',
          PosShortcutKeys.payment,
        ),
      };

      for (final entry in expected.entries) {
        final (labelKey, badgeKey) = entry.value;
        expect(
          _badge(entry.key, badgeKey),
          findsOneWidget,
          reason: '${entry.key} must show the [$badgeKey] chip',
        );
        // The label is a pure action name — the key lives only in the chip
        // (no "Customer (F6)" duplication inside the localized string).
        final label = _label(tester, entry.key, labelKey);
        expect(
          label.data,
          isNot(contains(badgeKey)),
          reason: '${entry.key} label must not embed the key text',
        );
      }

      expect(tester.takeException(), isNull);
    });

    testWidgets('labels stay localized and key-free in ar too', (
      tester,
    ) async {
      await _pumpPos(tester, dio: dio, locale: AppLocale.ar);

      // Key symbols are locale-free: the Arabic screen shows the SAME
      // chip text as the English one.
      expect(
        _badge(const Key('pos-select-customer'), PosShortcutKeys.chooseCustomer),
        findsOneWidget,
      );
      expect(
        _badge(const Key('pos-pay-button'), PosShortcutKeys.payment),
        findsOneWidget,
      );
      final label = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('pos-pay-button')),
          matching: find.text(AppStrings.t('payment_shortcut', 'ar')),
        ),
      );
      expect(label.data, isNot(contains('Space')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('RTL: the chips render on the Arabic screen without '
        'exceptions', (tester) async {
      await _pumpPos(
        tester,
        dio: dio,
        locale: AppLocale.ar,
        direction: TextDirection.rtl,
      );

      for (final entry in <Key, String>{
        const Key('pos-select-customer'): PosShortcutKeys.chooseCustomer,
        const Key('pos-discount-button'): PosShortcutKeys.invoiceDiscount,
        const Key('pos-hold-button'): PosShortcutKeys.hold,
        const Key('pos-holds-button'): PosShortcutKeys.holds,
        const Key('pos-history-button'): PosShortcutKeys.history,
        const Key('pos-loyalty-discount-button'):
            PosShortcutKeys.useLoyaltyPoints,
        const Key('pos-pay-button'): PosShortcutKeys.payment,
      }.entries) {
        expect(
          _badge(entry.key, entry.value),
          findsOneWidget,
          reason: 'RTL ${entry.key} must still show ${entry.value}',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the PAY chip follows the quick-sale setting — Space is withdrawn '
        'from PAY while Quick sale (Space) is ON', (tester) async {
      await _pumpPos(
        tester,
        dio: dio,
        initialPrefs: <String, Object>{
          PosSettingsNotifier.quickSaleWithSpaceKey: true,
        },
      );

      expect(
        _badge(const Key('pos-pay-button'), PosShortcutKeys.payment),
        findsNothing,
        reason: 'Space no longer opens payment — the chip must not claim it',
      );
      // The label itself is untouched: PAY still says Pay.
      expect(
        find.descendant(
          of: find.byKey(const Key('pos-pay-button')),
          matching: find.text(AppStrings.t('payment_shortcut', 'en')),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the customer picker quick-add carries Shift+F6', (
      tester,
    ) async {
      await _pumpPos(tester, dio: dio);

      await tester.tap(find.byKey(const Key('pos-select-customer')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('customer-picker-dialog')), findsOneWidget);
      expect(
        _badge(const Key('customer-quick-add'), PosShortcutKeys.addCustomer),
        findsOneWidget,
        reason: 'the quick-add mirrors the Shift+F6 workspace combo',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('badge table ⇄ shortcuts map', () {
    testWidgets('the help map documents the very constants the badges '
        'render', (tester) async {
      await _pumpPos(tester, dio: dio);

      await tester.tap(find.byKey(const Key('pos-shortcuts-button')));
      await tester.pumpAndSettle();

      final map = find.byKey(const Key('shortcuts-dialog'));
      expect(map, findsOneWidget);
      for (final key in <String>[
        PosShortcutKeys.chooseCustomer,
        PosShortcutKeys.addCustomer,
        PosShortcutKeys.invoiceDiscount,
        PosShortcutKeys.useLoyaltyPoints,
        PosShortcutKeys.payment,
        PosShortcutKeys.hold,
        PosShortcutKeys.holds,
        PosShortcutKeys.history,
        PosShortcutKeys.clearCart,
      ]) {
        expect(
          find.descendant(of: map, matching: find.text(key)),
          findsOneWidget,
          reason: 'the map must document $key — the badges use the same '
              'table',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}
