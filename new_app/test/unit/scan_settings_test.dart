// Configurable scan actions (POS): the two client-local toggles.
//
// Both OFF by default, independent of each other, and persisted through
// SharedPreferences with the same synchronous-read pattern as
// app_locale / app_theme_mode (ScanSettingsNotifier reads its keys in the
// constructor so the POS scan hot path never races an async first load).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/scan_settings_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('defaults', () {
    test('both scan actions are OFF without stored prefs', () {
      final notifier = ScanSettingsNotifier();

      expect(notifier.state.openAddProductOnUnknownBarcode, isFalse);
      expect(notifier.state.openAdjustStockOnOutOfStockScan, isFalse);
    });

    test('both scan actions are OFF with empty stored prefs', () async {
      final prefs = await SharedPreferences.getInstance();

      final notifier = ScanSettingsNotifier(prefs);

      expect(notifier.state.openAddProductOnUnknownBarcode, isFalse);
      expect(notifier.state.openAdjustStockOnOutOfStockScan, isFalse);
    });
  });

  group('independence', () {
    test('toggling one setting never moves the other', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ScanSettingsNotifier(prefs);

      notifier.setOpenAddProductOnUnknownBarcode(true);
      expect(notifier.state.openAddProductOnUnknownBarcode, isTrue);
      expect(notifier.state.openAdjustStockOnOutOfStockScan, isFalse);

      notifier.setOpenAdjustStockOnOutOfStockScan(true);
      expect(notifier.state.openAddProductOnUnknownBarcode, isTrue);
      expect(notifier.state.openAdjustStockOnOutOfStockScan, isTrue);

      notifier.setOpenAddProductOnUnknownBarcode(false);
      expect(notifier.state.openAddProductOnUnknownBarcode, isFalse);
      expect(notifier.state.openAdjustStockOnOutOfStockScan, isTrue);
    });
  });

  group('persistence', () {
    test('setters write their own SharedPreferences keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ScanSettingsNotifier(prefs);

      notifier.setOpenAddProductOnUnknownBarcode(true);
      notifier.setOpenAdjustStockOnOutOfStockScan(true);

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
        isTrue,
      );
      // The keys are the documented spec names — a rename would silently
      // reset every device's stored preference.
      expect(
        ScanSettingsNotifier.openAddProductOnUnknownBarcodeKey,
        'open_add_product_on_unknown_barcode',
      );
      expect(
        ScanSettingsNotifier.openAdjustStockOnOutOfStockScanKey,
        'open_adjust_stock_on_out_of_stock_scan',
      );
    });

    test('a new notifier restores each saved setting independently',
        () async {
      final prefs = await SharedPreferences.getInstance();
      ScanSettingsNotifier(prefs)
          .setOpenAddProductOnUnknownBarcode(true);

      final restarted = ScanSettingsNotifier(await SharedPreferences.getInstance());

      expect(restarted.state.openAddProductOnUnknownBarcode, isTrue);
      expect(restarted.state.openAdjustStockOnOutOfStockScan, isFalse);
    });

    test('turning a setting off persists the off state', () async {
      final prefs = await SharedPreferences.getInstance();
      final notifier = ScanSettingsNotifier(prefs);
      notifier.setOpenAdjustStockOnOutOfStockScan(true);
      notifier.setOpenAdjustStockOnOutOfStockScan(false);

      final restarted =
          ScanSettingsNotifier(await SharedPreferences.getInstance());

      expect(restarted.state.openAdjustStockOnOutOfStockScan, isFalse);
      expect(
        prefs.getBool(
          ScanSettingsNotifier.openAdjustStockOnOutOfStockScanKey,
        ),
        isFalse,
      );
    });
  });

  group('provider', () {
    test('the un-overridden provider starts from defaults', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final settings = container.read(scanSettingsProvider);

      expect(settings.openAddProductOnUnknownBarcode, isFalse);
      expect(settings.openAdjustStockOnOutOfStockScan, isFalse);
    });
  });

  group('localization', () {
    const keys = <String>[
      'settings_scan_actions',
      'open_add_product_on_unknown_barcode',
      'open_add_product_on_unknown_barcode_desc',
      'open_adjust_stock_on_out_of_stock_scan',
      'open_adjust_stock_on_out_of_stock_scan_desc',
    ];

    test('every scan-action key exists in all three locales', () {
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
