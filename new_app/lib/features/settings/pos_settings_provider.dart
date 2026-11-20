// Configurable POS operator preferences (client-local, SharedPreferences).
//
// Currently two preferences:
//   * [PosSettings.quickSaleWithSpace] — pressing SPACE in the POS
//     workspace completes the current valid sale directly (full cash
//     payment of the amount due through the EXISTING checkout pipeline)
//     instead of opening the payment dialog. OFF by default: an
//     installation that never saved a value keeps the ordinary
//     Space → payment-dialog behaviour bit-for-bit.
//   * [PosSettings.sellUnitPricingMode] — how a product that has selling
//     units (Box ×4 at 1 900 DA, …) is priced in the cart:
//       - [SellUnitPricingMode.manual] (default, existing behaviour): the
//         cashier picks the unit/qty in the selling-unit dialog and the
//         chosen unit's own price is stamped on the line.
//       - [SellUnitPricingMode.automatic] (Method 2): no dialog, one
//         regular base unit per scan/add, and the line derives the bundle
//         discount from its quantity (core/sell_unit_pricing.dart).
//     Default is MANUAL so an existing installation behaves identically
//     until an administrator changes the setting.
//   * [PosSettings.showPosProductList] — scanner-first layout. OFF by
//     default: the POS product catalog is hidden, the cart owns the
//     workspace and the barcode field is scan-only (no name/description
//     search, never auto-focused). ON restores the existing catalog
//     layout exactly as it worked before.
//
// Persistence follows the app_locale / app_theme_mode / scan-settings
// pattern: a StateNotifier that reads its keys SYNCHRONOUSLY in the
// constructor (the POS keyboard hot path reads the provider — never an
// async first load that could race the first SPACE press), with main.dart
// overriding the provider with the already-loaded SharedPreferences
// instance.
//
// Deliberately NOT part of the server-owned StoreSettings surface: these
// are per-device operator preferences, so they never touch the backend,
// the database schema, or any migration.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a cart line is priced when the product has selling units.
///
/// Stored as its [apiValue] string (never as an enum index) so a future
/// value can be added without re-reading an old installation's integer.
enum SellUnitPricingMode {
  /// Method 1 — the cashier chooses unit and quantity in the picker
  /// (unchanged, default).
  manual('manual'),

  /// Method 2 — one base unit per add, bundle discount derived from the
  /// line quantity.
  automatic('automatic');

  final String apiValue;
  const SellUnitPricingMode(this.apiValue);

  /// Unknown or missing stored values fall back to [manual] — the safe,
  /// existing-behaviour default.
  static SellUnitPricingMode fromStorage(String? raw) {
    for (final mode in SellUnitPricingMode.values) {
      if (mode.apiValue == raw) return mode;
    }
    return SellUnitPricingMode.manual;
  }
}

class PosSettings {
  final bool quickSaleWithSpace;

  /// Whether the POS product catalog is shown beside the cart
  /// (`show_pos_product_list`). Default `false` — every installation,
  /// existing or new, starts scanner-first: the catalog is hidden, the
  /// barcode field stays scan-only, and the cart uses the whole workspace.
  final bool showPosProductList;

  /// Method 1 (manual picker, default) or Method 2 (automatic bundle).
  /// Read per add, never cached in the cart: a mode switch therefore
  /// applies to NEWLY added lines and leaves every existing cart line
  /// exactly as it was priced (see the Settings screen copy).
  final SellUnitPricingMode sellUnitPricingMode;

  const PosSettings({
    this.quickSaleWithSpace = false,
    this.sellUnitPricingMode = SellUnitPricingMode.manual,
    this.showPosProductList = false,
  });

  PosSettings copyWith({
    bool? quickSaleWithSpace,
    SellUnitPricingMode? sellUnitPricingMode,
    bool? showPosProductList,
  }) {
    return PosSettings(
      quickSaleWithSpace: quickSaleWithSpace ?? this.quickSaleWithSpace,
      sellUnitPricingMode: sellUnitPricingMode ?? this.sellUnitPricingMode,
      showPosProductList: showPosProductList ?? this.showPosProductList,
    );
  }
}

class PosSettingsNotifier extends StateNotifier<PosSettings> {
  static const quickSaleWithSpaceKey = 'quick_sale_with_space';
  static const sellUnitPricingModeKey = 'sell_unit_pricing_mode';

  /// `show_pos_product_list` — absent on every installation that never
  /// saved it, which is the documented `false` default.
  static const showPosProductListKey = 'show_pos_product_list';

  final SharedPreferences? _prefs;

  PosSettingsNotifier([SharedPreferences? prefs])
      : _prefs = prefs,
        super(PosSettings(
          quickSaleWithSpace:
              prefs?.getBool(quickSaleWithSpaceKey) ?? false,
          sellUnitPricingMode: SellUnitPricingMode.fromStorage(
            prefs?.getString(sellUnitPricingModeKey),
          ),
          showPosProductList:
              prefs?.getBool(showPosProductListKey) ?? false,
        ));

  void setQuickSaleWithSpace(bool value) {
    state = state.copyWith(quickSaleWithSpace: value);
    _prefs?.setBool(quickSaleWithSpaceKey, value);
  }

  /// Persists the catalog visibility. Purely presentational: the cart, the
  /// barcode pipeline and every shortcut are the same in both modes.
  void setShowPosProductList(bool value) {
    if (state.showPosProductList == value) return;
    state = state.copyWith(showPosProductList: value);
    _prefs?.setBool(showPosProductListKey, value);
  }

  /// Persists the chosen mode. The cart is NOT touched: existing lines keep
  /// the pricing they were built with (their own lines still re-derive a
  /// Method 2 bundle when their quantity changes, because that plan lives
  /// on the line, not in this setting).
  void setSellUnitPricingMode(SellUnitPricingMode mode) {
    if (state.sellUnitPricingMode == mode) return;
    state = state.copyWith(sellUnitPricingMode: mode);
    _prefs?.setString(sellUnitPricingModeKey, mode.apiValue);
  }
}

final posSettingsProvider =
    StateNotifierProvider<PosSettingsNotifier, PosSettings>((ref) {
  return PosSettingsNotifier();
});
