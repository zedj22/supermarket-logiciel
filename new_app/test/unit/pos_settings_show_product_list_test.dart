// `show_pos_product_list` persistence (SharedPreferences, per device).
//
// Default is FALSE for every installation — new and existing — so the POS
// starts scanner-first with the catalog hidden. Toggling from Settings
// survives a restart, and an installation that saved OTHER POS preferences
// keeps the safe default.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/settings/pos_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to false on a fresh install', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    final settings = PosSettingsNotifier(prefs);

    expect(settings.state.showPosProductList, isFalse);
    expect(settings.state.quickSaleWithSpace, isFalse);
    expect(prefs.getBool(PosSettingsNotifier.showPosProductListKey), isNull,
        reason: 'nothing is written until the operator chooses');
  });

  test('defaults to false on an existing install that saved other settings',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PosSettingsNotifier.quickSaleWithSpaceKey: true,
      PosSettingsNotifier.sellUnitPricingModeKey: 'automatic',
    });
    final prefs = await SharedPreferences.getInstance();

    final settings = PosSettingsNotifier(prefs);

    expect(settings.state.showPosProductList, isFalse,
        reason: 'a pre-upgrade installation receives the safe default');
    expect(settings.state.quickSaleWithSpace, isTrue,
        reason: 'no other preference is disturbed');
    expect(
      settings.state.sellUnitPricingMode,
      SellUnitPricingMode.automatic,
    );
  });

  test('ON survives Save → reopen → restart', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    PosSettingsNotifier(prefs).setShowPosProductList(true);

    expect(prefs.getBool(PosSettingsNotifier.showPosProductListKey), isTrue);
    // Re-opening Settings reads the same notifier; "restart" is a fresh
    // notifier built from the same persisted store.
    expect(PosSettingsNotifier(prefs).state.showPosProductList, isTrue);
  });

  test('OFF survives Save → reopen → restart', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PosSettingsNotifier.showPosProductListKey: true,
    });
    final prefs = await SharedPreferences.getInstance();

    final settings = PosSettingsNotifier(prefs);
    expect(settings.state.showPosProductList, isTrue);
    settings.setShowPosProductList(false);

    expect(prefs.getBool(PosSettingsNotifier.showPosProductListKey), isFalse);
    expect(PosSettingsNotifier(prefs).state.showPosProductList, isFalse);
  });

  test('copyWith keeps the value unless it is replaced', () {
    const settings = PosSettings(showPosProductList: true);

    expect(
      settings.copyWith(quickSaleWithSpace: true).showPosProductList,
      isTrue,
    );
    expect(
      settings.copyWith(showPosProductList: false).showPosProductList,
      isFalse,
    );
    expect(const PosSettings().showPosProductList, isFalse,
        reason: 'the constructor default is the scanner-first layout');
  });
}
