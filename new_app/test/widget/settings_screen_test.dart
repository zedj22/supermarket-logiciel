import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

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
}

class _SettingsHarness extends ConsumerWidget {
  const _SettingsHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final mode = ref.watch(themeProvider).mode;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: switch (mode) {
        AppThemeMode.dark => AppTheme.dark(),
        AppThemeMode.light => AppTheme.light(),
        AppThemeMode.grey => AppTheme.grey(),
      },
      locale: locale.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: const SettingsScreen(),
    );
  }
}
