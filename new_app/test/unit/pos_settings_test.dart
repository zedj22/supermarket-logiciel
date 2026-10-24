// Configurable POS operator preference: quick sale with Space.
//
// OFF by default (an installation that never saved a value keeps the
// ordinary Space → payment-dialog behaviour bit-for-bit), persisted
// through SharedPreferences with the same synchronous-read pattern as
// scan_settings / app_locale / app_theme_mode (PosSettingsNotifier reads
// its key in the constructor so the POS keyboard hot path never races an
// async first load).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('defaults', () {
    test('quick sale with Space is OFF without stored prefs', () {
      final notifier = PosSettingsNotifier();

      expect(notifier.state.quickSaleWithSpace, isFalse);
    });

    test('quick sale with Space is OFF with empty stored prefs', () async {
      final prefs = await SharedPreferences.getInstance();

      final notifier = PosSettingsNotifier(prefs);

      expect(notifier.state.quickSaleWithSpace, isFalse);
    });
  });

  group('persistence', () {
    test('the setter writes its own SharedPreferences key', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = PosSettingsNotifier(prefs);

      notifier.setQuickSaleWithSpace(true);

      expect(
        prefs.getBool(PosSettingsNotifier.quickSaleWithSpaceKey),
        isTrue,
      );
      // The key is the documented spec name — a rename would silently
      // reset every device's stored preference.
      expect(
        PosSettingsNotifier.quickSaleWithSpaceKey,
        'quick_sale_with_space',
      );
    });

    test('a new notifier restores the saved setting', () async {
      final prefs = await SharedPreferences.getInstance();
      PosSettingsNotifier(prefs).setQuickSaleWithSpace(true);

      final restarted =
          PosSettingsNotifier(await SharedPreferences.getInstance());

      expect(restarted.state.quickSaleWithSpace, isTrue);
    });

    test('turning the setting off persists the off state', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = PosSettingsNotifier(prefs);
      notifier.setQuickSaleWithSpace(true);
      notifier.setQuickSaleWithSpace(false);

      final restarted =
          PosSettingsNotifier(await SharedPreferences.getInstance());

      expect(restarted.state.quickSaleWithSpace, isFalse);
      expect(
        prefs.getBool(PosSettingsNotifier.quickSaleWithSpaceKey),
        isFalse,
      );
    });
  });

  group('provider', () {
    test('the un-overridden provider starts from defaults', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final settings = container.read(posSettingsProvider);

      expect(settings.quickSaleWithSpace, isFalse);
    });
  });

  group('localization', () {
    const keys = <String>[
      'settings_pos_actions',
      'quick_sale_with_space',
      'quick_sale_with_space_desc',
      'sc_a_quick_sale',
      'sc_d_quick_sale',
    ];

    test('every quick-sale key exists in all three locales', () {
      for (final key in keys) {
        for (final loc in const ['ar', 'fr', 'en']) {
          final value = AppStrings.t(key, loc);
          expect(
            value,
            isNotEmpty,
            reason: '$key must translate for $loc',
          );
          expect(
            value,
            isNot(equals(key)),
            reason: '$key must not fall back to the raw key for $loc',
          );
        }
      }
    });

    test('the three locales never share a translation for the labels', () {
      // Guards against a copy-paste that would pin one language's text
      // into another map (the parity test only compares key counts).
      for (final key in keys) {
        final ar = AppStrings.t(key, 'ar');
        final fr = AppStrings.t(key, 'fr');
        final en = AppStrings.t(key, 'en');
        expect(ar, isNot(fr), reason: '$key ar/fr differ');
        expect(fr, isNot(en), reason: '$key fr/en differ');
        expect(ar, isNot(en), reason: '$key ar/en differ');
      }
    });
  });
}
