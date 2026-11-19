// Receipt printing mode (Settings → Receipt) — new, independent dropdown.
//
// Contract under test:
//  * the dropdown offers exactly the three documented modes and is
//    localized in ar/fr/en;
//  * the Minimum Receipt Amount input exists ONLY for
//    `Open Print Window When Amount Is Reached`;
//  * an existing installation (payload without the new keys) reads as
//    Disabled with no threshold input;
//  * the selected mode + threshold persist through the existing
//    `GET/PUT /api/v1/settings` form, alongside — never instead of — the
//    legacy `ask_before_print` / `auto_print_invoice` values;
//  * an invalid threshold cannot be saved.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const Key _modeDropdownKey = Key('settings-receipt-print-mode');
const Key _minAmountKey = Key('settings-receipt-min-amount');
const Key _saveKey = Key('settings-save-button');

const Map<String, Object> _legacyFixture = <String, Object>{
  'store_name': 'Supermarket Pro',
  'store_phone': '',
  'store_address': '',
  'invoice_footer': '',
  'default_paper': '80mm',
  'ask_before_print': true,
  'auto_print_invoice': false,
  'receipt_print_mode': 'ask_above_threshold',
  'receipt_min_amount': 500,
  'allow_debt': true,
  'low_stock_threshold': 5,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<FakeJsonAdapter> pumpSettings(
    WidgetTester tester, {
    Map<String, Object> json = kDefaultSettingsJson,
    AppLocale locale = AppLocale.en,
  }) async {
    final adapter = _fixtureAdapter(json);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          themeProvider.overrideWith(
            (ref) => ThemeNotifier(prefs)..setTheme(AppThemeMode.dark),
          ),
          currentUserProvider.overrideWithValue(_admin),
          apiClientProvider.overrideWithValue(
            ApiClient(dio: fakeDio(adapter)),
          ),
        ],
        child: const _SettingsHarness(),
      ),
    );
    await tester.pumpAndSettle();
    return adapter;
  }

  group('Receipt printing mode setting', () {
    testWidgets('an existing installation reads as Disabled with no threshold '
        'input', (tester) async {
      // A pre-upgrade payload: neither new key is present.
      await pumpSettings(tester);

      expect(find.byKey(_modeDropdownKey), findsOneWidget);
      expect(find.text(AppStrings.t('receipt_print_mode_disabled', 'en')),
          findsOneWidget);
      expect(find.byKey(_minAmountKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the dropdown offers exactly the three documented modes',
        (tester) async {
      await pumpSettings(tester);

      await _tap(tester, find.byKey(_modeDropdownKey));

      for (final key in const <String>[
        'receipt_print_mode_disabled',
        'receipt_print_mode_auto_print',
        'receipt_print_mode_ask_above_threshold',
      ]) {
        expect(find.text(AppStrings.t(key, 'en')), findsWidgets,
            reason: 'missing option $key');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing Automatically print hides the threshold input and '
        'keeps the legacy toggles untouched', (tester) async {
      final adapter = await pumpSettings(tester, json: _legacyFixture);

      // Seeded from the server: the gated mode shows its threshold.
      expect(find.byKey(_minAmountKey), findsOneWidget);
      expect(find.text('500'), findsOneWidget);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_auto_print', 'en'),
      );
      expect(find.byKey(_minAmountKey), findsNothing);

      await _tap(tester, find.byKey(_saveKey));
      final body = Map<String, dynamic>.from(
        adapter.requests.lastWhere((r) => r.method == 'PUT').data as Map,
      );

      expect(body['receipt_print_mode'], 'auto_print');
      expect(body['receipt_min_amount'], 500,
          reason: 'the stored threshold survives a mode-only change');
      expect(body['ask_before_print'], isTrue,
          reason: 'legacy print setting must not be clobbered');
      expect(body['auto_print_invoice'], isFalse);
      expect(find.text(AppStrings.t('settings_saved', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the gated mode saves the typed threshold through the '
        'existing settings PUT', (tester) async {
      final adapter = await pumpSettings(tester);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      expect(find.byKey(_minAmountKey), findsOneWidget);

      await _enterText(tester, find.byKey(_minAmountKey), '750.5');
      await _tap(tester, find.byKey(_saveKey));

      final body = Map<String, dynamic>.from(
        adapter.requests.lastWhere((r) => r.method == 'PUT').data as Map,
      );
      expect(body['receipt_print_mode'], 'ask_above_threshold');
      expect(body['receipt_min_amount'], 750.5);
      expect(body['default_paper'], '80mm',
          reason: 'unrelated printing settings ride along unchanged');
      expect(body['ask_before_print'], isFalse);
      expect(body['auto_print_invoice'], isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero threshold is valid (prints whatever the total is)',
        (tester) async {
      final adapter = await pumpSettings(tester);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      await _enterText(tester, find.byKey(_minAmountKey), '0');

      final save = find.byKey(_saveKey);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await _tap(tester, save);

      final body = Map<String, dynamic>.from(
        adapter.requests.lastWhere((r) => r.method == 'PUT').data as Map,
      );
      expect(body['receipt_min_amount'], 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an invalid or negative threshold cannot be saved',
        (tester) async {
      final adapter = await pumpSettings(tester);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );

      await _enterText(tester, find.byKey(_minAmountKey), 'abc');
      expect(tester.widget<FilledButton>(find.byKey(_saveKey)).onPressed, isNull);
      expect(
        find.text(AppStrings.t('validation_error', 'en')),
        findsWidgets,
      );

      await _enterText(tester, find.byKey(_minAmountKey), '-5');
      expect(tester.widget<FilledButton>(find.byKey(_saveKey)).onPressed, isNull);

      // A new threshold alone enables the save (value changes are tracked).
      await _enterText(tester, find.byKey(_minAmountKey), '250');
      expect(
        tester.widget<FilledButton>(find.byKey(_saveKey)).onPressed,
        isNotNull,
      );
      expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the option labels follow the active locale (ar)', // 
        (tester) async {
      await pumpSettings(tester, json: _legacyFixture, locale: AppLocale.ar);

      expect(find.text(AppStrings.t('receipt_print_mode', 'ar')),
          findsOneWidget);
      expect(
        find.text(AppStrings.t('receipt_print_mode_ask_above_threshold', 'ar')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('receipt_min_amount', 'ar')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the option labels follow the active locale (fr)', // 
        (tester) async {
      await pumpSettings(tester, json: _legacyFixture, locale: AppLocale.fr);

      expect(find.text(AppStrings.t('receipt_print_mode', 'fr')),
          findsOneWidget);
      expect(
        find.text(AppStrings.t('receipt_print_mode_ask_above_threshold', 'fr')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('receipt_min_amount', 'fr')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: [settingsManageScope],
);

/// GET returns [json]; PUT echoes its body back (what the backend does).
FakeJsonAdapter _fixtureAdapter(Map<String, Object> json) =>
    FakeJsonAdapter((options) async {
      if (options.method == 'PUT') {
        return (
          statusCode: 200,
          body: Map<String, dynamic>.from(options.data as Map),
        );
      }
      return (statusCode: 200, body: json);
    });

Future<void> _selectMode(WidgetTester tester, String label) async {
  final dropdown = find.byKey(_modeDropdownKey);
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _enterText(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _SettingsHarness extends ConsumerWidget {
  const _SettingsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final mode = ref.watch(themeProvider).mode;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forMode(mode),
      locale: locale.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: const Scaffold(body: SettingsScreen()),
    );
  }
}
