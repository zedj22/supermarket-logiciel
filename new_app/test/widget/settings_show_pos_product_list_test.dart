// Settings → POS actions → "Show Product List in POS".
//
// The toggle is the ONLY way in or out of the legacy catalog layout:
//  * OFF is the shipped default (scanner-first POS);
//  * flipping it ON/OFF updates the shared `posSettingsProvider` state the
//    POS screen reads, so both modes are reachable without a restart;
//  * its label and description are localized in ar / fr / en.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const _toggleKey = Key('settings-show-pos-product-list');

const _admin = AuthUser(
  id: '00000000-0000-0000-0000-0000000000a1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: ['settings_manage', 'pos_sale'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> pumpSettings(
    WidgetTester tester, {
    AppLocale locale = AppLocale.en,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final adapter = FakeJsonAdapter(
      (options) async => (statusCode: 200, body: kDefaultSettingsJson),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          themeProvider.overrideWith(
            (ref) => ThemeNotifier(prefs)..setTheme(AppThemeMode.light),
          ),
          currentUserProvider.overrideWithValue(_admin),
          posSettingsProvider.overrideWith(
            (ref) => PosSettingsNotifier(prefs),
          ),
          apiClientProvider.overrideWithValue(
            ApiClient(dio: fakeDio(adapter)),
          ),
        ],
        child: const _Harness(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
  }

  testWidgets('the toggle exists, is off by default and flips the POS mode',
      (tester) async {
    final container = await pumpSettings(tester);

    final tile = tester.widget<SwitchListTile>(find.byKey(_toggleKey));
    expect(tile.value, isFalse);
    expect(container.read(posSettingsProvider).showPosProductList, isFalse);

    await tester.ensureVisible(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(container.read(posSettingsProvider).showPosProductList, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byKey(_toggleKey)).value,
      isTrue,
    );

    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    expect(container.read(posSettingsProvider).showPosProductList, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the toggle writes the persisted key', (tester) async {
    await pumpSettings(tester);

    await tester.ensureVisible(find.byKey(_toggleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_toggleKey));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PosSettingsNotifier.showPosProductListKey), isTrue);
  });

  for (final locale in <AppLocale>[AppLocale.ar, AppLocale.fr, AppLocale.en]) {
    testWidgets('label and description are localized (${locale.name})',
        (tester) async {
      await pumpSettings(tester, locale: locale);

      expect(find.byKey(_toggleKey), findsOneWidget);
      expect(
        find.text(AppStrings.t('show_pos_product_list', locale.name)),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('show_pos_product_list_desc', locale.name)),
        findsOneWidget,
      );
      // Never the raw key fallback.
      expect(find.text('show_pos_product_list'), findsNothing);
      expect(find.text('pos_scan_field_hint'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _Harness extends ConsumerWidget {
  const _Harness();

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
