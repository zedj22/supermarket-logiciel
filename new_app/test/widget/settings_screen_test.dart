import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/scan_settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> pumpSettingsApp(
    WidgetTester tester, {
    AppLocale locale = AppLocale.ar,
    AppThemeMode mode = AppThemeMode.dark,
    SharedPreferences? prefs,
    AuthUser? user,
    FakeJsonAdapter? adapter,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          themeProvider.overrideWith(
            (ref) => ThemeNotifier(prefs)..setTheme(mode),
          ),
          if (user != null)
            currentUserProvider.overrideWithValue(user),
          if (adapter != null)
            apiClientProvider.overrideWithValue(
              ApiClient(dio: fakeDio(adapter)),
            ),
        ],
        child: const _SettingsHarness(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  group('Settings screen', () {
    testWidgets('renders language and theme controls with localized labels',
        (tester) async {
      await pumpSettingsApp(tester, locale: AppLocale.ar);

      expect(find.text(AppStrings.t('settings', 'ar')), findsOneWidget);
      expect(find.text(AppStrings.t('language', 'ar')), findsOneWidget);
      expect(find.text(AppStrings.t('theme', 'ar')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-language-dropdown')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-theme-dark')), findsOneWidget);
      expect(find.byKey(const Key('settings-theme-light')), findsOneWidget);
      expect(find.byKey(const Key('settings-theme-grey')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switches language ar → fr and updates labels + direction',
        (tester) async {
      final container = await pumpSettingsApp(tester, locale: AppLocale.ar);

      expect(
        Directionality.of(tester.element(find.byType(SettingsScreen))),
        TextDirection.rtl,
      );

      await tester.tap(find.byKey(const Key('settings-language-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Français').last);
      await tester.pumpAndSettle();

      expect(container.read(localeProvider).locale, AppLocale.fr);
      expect(find.text(AppStrings.t('settings', 'fr')), findsOneWidget);
      expect(find.text(AppStrings.t('language', 'fr')), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.byType(SettingsScreen))),
        TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('switches language to English', (tester) async {
      final container = await pumpSettingsApp(tester, locale: AppLocale.ar);

      await tester.tap(find.byKey(const Key('settings-language-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();

      expect(container.read(localeProvider).locale, AppLocale.en);
      expect(find.text(AppStrings.t('settings', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('applies Arabic RTL after selecting العربية', (tester) async {
      final container = await pumpSettingsApp(tester, locale: AppLocale.en);

      expect(
        Directionality.of(tester.element(find.byType(SettingsScreen))),
        TextDirection.ltr,
      );

      await tester.tap(find.byKey(const Key('settings-language-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('العربية').last);
      await tester.pumpAndSettle();

      expect(container.read(localeProvider).locale, AppLocale.ar);
      expect(
        Directionality.of(tester.element(find.byType(SettingsScreen))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('theme selection applies light / dark / grey ThemeData',
        (tester) async {
      final container = await pumpSettingsApp(tester, mode: AppThemeMode.dark);

      expect(
        Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
        Brightness.dark,
      );

      await tester.tap(find.byKey(const Key('settings-theme-light')));
      await tester.pumpAndSettle();
      expect(container.read(themeProvider).mode, AppThemeMode.light);
      expect(
        Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
        Brightness.light,
      );

      await tester.tap(find.byKey(const Key('settings-theme-grey')));
      await tester.pumpAndSettle();
      expect(container.read(themeProvider).mode, AppThemeMode.grey);
      expect(
        Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Locale persistence', () {
    test('setLocale writes SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = LocaleNotifier(prefs);

      notifier.setLocale(AppLocale.fr);

      expect(prefs.getString(LocaleNotifier.prefsKey), 'fr');
    });

    test('new LocaleNotifier restores saved locale', () async {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(LocaleNotifier.prefsKey, 'en');

      final notifier = LocaleNotifier(await SharedPreferences.getInstance());

      expect(notifier.state.locale, AppLocale.en);
      expect(notifier.state.flutterLocale, const Locale('en'));
    });

    test('invalid saved locale falls back to Arabic', () async {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(LocaleNotifier.prefsKey, 'xx');

      final notifier = LocaleNotifier(await SharedPreferences.getInstance());

      expect(notifier.state.locale, AppLocale.ar);
    });

    test('cycleLocale persists each step', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = LocaleNotifier(prefs);

      notifier.cycleLocale();
      expect(prefs.getString(LocaleNotifier.prefsKey), 'fr');
      notifier.cycleLocale();
      expect(prefs.getString(LocaleNotifier.prefsKey), 'en');
      notifier.cycleLocale();
      expect(prefs.getString(LocaleNotifier.prefsKey), 'ar');
    });
  });

  group('Theme persistence', () {
    test('setTheme writes SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ThemeNotifier(prefs);

      notifier.setTheme(AppThemeMode.light);

      expect(prefs.getString(ThemeNotifier.prefsKey), 'light');
    });

    test('new ThemeNotifier restores saved mode', () async {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(ThemeNotifier.prefsKey, 'grey');

      final notifier = ThemeNotifier(await SharedPreferences.getInstance());

      expect(notifier.state.mode, AppThemeMode.grey);
    });

    test('invalid saved theme falls back to dark', () async {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString(ThemeNotifier.prefsKey, 'neon');

      final notifier = ThemeNotifier(await SharedPreferences.getInstance());

      expect(notifier.state.mode, AppThemeMode.dark);
    });

    test('cycleTheme persists each step', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ThemeNotifier(prefs);

      notifier.cycleTheme();
      expect(prefs.getString(ThemeNotifier.prefsKey), 'light');
      notifier.cycleTheme();
      expect(prefs.getString(ThemeNotifier.prefsKey), 'grey');
      notifier.cycleTheme();
      expect(prefs.getString(ThemeNotifier.prefsKey), 'dark');
    });
  });

  // -----------------------------------------------------------------------
  // Phase 17 §17.1 — server-owned store settings
  // -----------------------------------------------------------------------

  group('Store settings (Phase 17)', () {
    testWidgets('hidden for a user without settings_manage, and never '
        'issues a request', (tester) async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 200, body: kDefaultSettingsJson),
      );

      await pumpSettingsApp(
        tester,
        user: _userWith(const []),
        adapter: adapter,
      );

      expect(find.byKey(const Key('settings-store-name')), findsNothing);
      expect(find.byKey(const Key('settings-save-button')), findsNothing);
      expect(adapter.requests, isEmpty,
          reason: 'a non-manager must not trigger a settings GET');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an admin sees the section with the loaded values',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: _echoAdapter(),
        locale: AppLocale.en,
      );

      expect(find.byKey(const Key('settings-store-name')), findsOneWidget);
      expect(find.text('Supermarket Pro'), findsOneWidget);
      expect(
        find.text(AppStrings.t('store_name', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('allow_debt', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('save stays disabled until a field actually changes',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: _echoAdapter(),
        locale: AppLocale.en,
      );

      final save = find.byKey(const Key('settings-save-button'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      await _enterText(
        tester,
        find.byKey(const Key('settings-store-name')),
        'Boutique Centrale',
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    });

    testWidgets('a successful save PUTs the form and reports saved',
        (tester) async {
      final adapter = _echoAdapter();
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
        locale: AppLocale.en,
      );

      await _enterText(
        tester,
        find.byKey(const Key('settings-store-name')),
        'Boutique Centrale',
      );
      await _tap(tester, find.byKey(const Key('settings-save-button')));

      final put = adapter.requests
          .lastWhere((r) => r.method == 'PUT');
      expect(put.path, '/api/v1/settings');
      final body = Map<String, dynamic>.from(put.data as Map);
      expect(body['store_name'], 'Boutique Centrale');
      expect(body['allow_debt'], isTrue);

      expect(find.text(AppStrings.t('settings_saved', 'en')), findsOneWidget);
      expect(find.byKey(const Key('settings-error-banner')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a failed save shows the failure banner, keeps the typed value '
        'and never claims success', (tester) async {
      final adapter = FakeJsonAdapter((options) async {
        if (options.method == 'PUT') {
          return (
            statusCode: 403,
            body: <String, Object>{
              'error': <String, Object>{
                'code': 'FORBIDDEN',
                'message': 'Insufficient permissions',
              },
            },
          );
        }
        return (statusCode: 200, body: kDefaultSettingsJson);
      });
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
        locale: AppLocale.en,
      );

      await _enterText(
        tester,
        find.byKey(const Key('settings-store-name')),
        'Boutique Centrale',
      );
      await _tap(tester, find.byKey(const Key('settings-save-button')));

      expect(find.byKey(const Key('settings-error-banner')), findsOneWidget);
      expect(
        find.text(
          '${AppStrings.t('settings_save_failed', 'en')} — '
          'Insufficient permissions',
        ),
        findsOneWidget,
      );
      expect(find.text('Boutique Centrale'), findsOneWidget,
          reason: 'the operator\'s typing must survive a failed save');
      expect(find.text(AppStrings.t('settings_saved', 'en')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load offers a retry that recovers', (tester) async {
      var failNext = true;
      final adapter = FakeJsonAdapter((options) async {
        if (failNext) {
          return (statusCode: 500, body: _errorBody('down'));
        }
        return (statusCode: 200, body: kDefaultSettingsJson);
      });
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
        locale: AppLocale.en,
      );

      expect(find.byKey(const Key('settings-load-error')), findsOneWidget);
      // Phase E: the loyalty card loads through the same adapter and shows
      // its OWN load error here — scope the message to the store card.
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-load-error')),
          matching: find.text(AppStrings.t('settings_load_failed', 'en')),
        ),
        findsOneWidget,
      );

      failNext = false;
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const Key('settings-load-error')),
          matching: find.byType(FilledButton),
        ),
      );

      expect(find.byKey(const Key('settings-load-error')), findsNothing);
      expect(find.text('Supermarket Pro'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the toggles are editable and are sent on save',
        (tester) async {
      final adapter = _echoAdapter();
      await pumpSettingsApp(
        tester,
        user: _admin,
        adapter: adapter,
        locale: AppLocale.en,
      );

      final debt = find.byKey(const Key('settings-allow-debt'));
      expect(
        tester.widget<SwitchListTile>(debt).value,
        isTrue,
      );
      await _tap(tester, debt);
      expect(tester.widget<SwitchListTile>(debt).value, isFalse);

      await _tap(tester, find.byKey(const Key('settings-save-button')));

      final put = adapter.requests.lastWhere((r) => r.method == 'PUT');
      final body = Map<String, dynamic>.from(put.data as Map);
      expect(body['allow_debt'], isFalse);
    });

    testWidgets('shows the Storage & Data Usage entry for settings_manage',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _userWith(const [settingsManageScope]),
        adapter: _echoAdapter(),
      );

      expect(find.byKey(const Key('settings-storage-title')), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-open')), findsOneWidget);
      expect(find.text(AppStrings.t('storage_usage', 'ar')), findsOneWidget);
      expect(find.text(AppStrings.t('storage_open', 'ar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides the storage entry from users without settings_manage',
        (tester) async {
      await pumpSettingsApp(
        tester,
        user: _userWith(const ['pos_sale']),
      );

      expect(find.byKey(const Key('settings-storage-title')), findsNothing);
      expect(find.byKey(const Key('settings-storage-open')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // Configurable scan actions — client-local POS preferences: both OFF by
  // default, independent, persisted in SharedPreferences, and visible to
  // every user (like language/theme — never permission-gated).
  // -----------------------------------------------------------------------

  group('Scan actions settings', () {
    Future<ProviderContainer> pumpScanActions(
      WidgetTester tester, {
      AppLocale locale = AppLocale.en,
      SharedPreferences? prefs,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localeProvider.overrideWith(
              (ref) => LocaleNotifier(prefs)..setLocale(locale),
            ),
            themeProvider.overrideWith((ref) => ThemeNotifier(prefs)),
            scanSettingsProvider.overrideWith(
              (ref) => ScanSettingsNotifier(prefs),
            ),
          ],
          child: const _SettingsHarness(),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
    }

    testWidgets(
        'renders both scan-action toggles localized and OFF by default '
        'for any user', (tester) async {
      await pumpScanActions(tester, locale: AppLocale.en);

      final add = find.byKey(
        const Key('settings-open-add-product-on-unknown-barcode'),
      );
      final adjust = find.byKey(
        const Key('settings-open-adjust-stock-on-out-of-stock-scan'),
      );
      expect(add, findsOneWidget);
      expect(adjust, findsOneWidget);
      expect(tester.widget<SwitchListTile>(add).value, isFalse);
      expect(tester.widget<SwitchListTile>(adjust).value, isFalse);
      expect(
        find.text(AppStrings.t('settings_scan_actions', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('open_add_product_on_unknown_barcode', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(
          AppStrings.t('open_add_product_on_unknown_barcode_desc', 'en'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('open_adjust_stock_on_out_of_stock_scan', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(
          AppStrings.t('open_adjust_stock_on_out_of_stock_scan_desc', 'en'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the localized Arabic labels too', (tester) async {
      await pumpScanActions(tester, locale: AppLocale.ar);

      expect(
        find.text(AppStrings.t('settings_scan_actions', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('open_add_product_on_unknown_barcode', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('open_adjust_stock_on_out_of_stock_scan', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'each toggle writes its own SharedPreferences key and the '
        'switches stay independent', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final container = await pumpScanActions(tester, prefs: prefs);

      final add = find.byKey(
        const Key('settings-open-add-product-on-unknown-barcode'),
      );
      final adjust = find.byKey(
        const Key('settings-open-adjust-stock-on-out-of-stock-scan'),
      );

      await _tap(tester, add);
      expect(tester.widget<SwitchListTile>(add).value, isTrue);
      expect(tester.widget<SwitchListTile>(adjust).value, isFalse);
      expect(
        prefs.getBool(
          ScanSettingsNotifier.openAddProductOnUnknownBarcodeKey,
        ),
        isTrue,
      );
      expect(
        prefs.getBool(
          ScanSettingsNotifier.openAdjustStockOnOutOfStockScanKey,
        ),
        isNull,
        reason: 'toggling one setting must never write the other key',
      );
      expect(
        container.read(scanSettingsProvider).openAddProductOnUnknownBarcode,
        isTrue,
      );
      expect(
        container.read(scanSettingsProvider).openAdjustStockOnOutOfStockScan,
        isFalse,
      );

      await _tap(tester, adjust);
      expect(tester.widget<SwitchListTile>(adjust).value, isTrue);
      expect(tester.widget<SwitchListTile>(add).value, isTrue);
      expect(
        prefs.getBool(
          ScanSettingsNotifier.openAdjustStockOnOutOfStockScanKey,
        ),
        isTrue,
      );

      // Turning one back off never moves the other.
      await _tap(tester, add);
      expect(tester.widget<SwitchListTile>(add).value, isFalse);
      expect(tester.widget<SwitchListTile>(adjust).value, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stored true restores ON after a restart-style remount',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ScanSettingsNotifier.openAddProductOnUnknownBarcodeKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await pumpScanActions(tester, prefs: prefs);

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(
                const Key('settings-open-add-product-on-unknown-barcode'),
              ),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(
                const Key('settings-open-adjust-stock-on-out-of-stock-scan'),
              ),
            )
            .value,
        isFalse,
        reason: 'the two settings restore independently',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

AuthUser _userWith(List<String> permissions) => AuthUser(
      id: 'u-1',
      fullName: 'Test User',
      isActive: true,
      roles: const ['cashier'],
      permissions: permissions,
    );

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: [settingsManageScope],
);

Map<String, Object> _errorBody(String message) => <String, Object>{
      'error': <String, Object>{'code': 'INTERNAL', 'message': message},
    };

/// GET returns the fixture; PUT echoes its body back (that is what the
/// backend does — it answers with the stored settings).
FakeJsonAdapter _echoAdapter() => FakeJsonAdapter((options) async {
      if (options.method == 'PUT') {
        return (
          statusCode: 200,
          body: Map<String, dynamic>.from(options.data as Map),
        );
      }
      return (statusCode: 200, body: kDefaultSettingsJson);
    });

/// Scrolls a field into view, focuses it and types — settings now lives in
/// a scroll view, so an off-screen tap would silently miss.
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
      // A Scaffold is what the real shell provides — the settings screen
      // raises a SnackBar after a successful save.
      home: const Scaffold(body: SettingsScreen()),
    );
  }
}
