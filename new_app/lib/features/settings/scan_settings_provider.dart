// Configurable POS scan actions (client-local, SharedPreferences).
//
// Two INDEPENDENT toggles, both OFF by default:
//   * [ScanSettings.openAddProductOnUnknownBarcode] — a definitive barcode
//     lookup miss on a scan-shaped code opens the existing Add Product
//     form with the code prefilled (instead of the not-found toast);
//   * [ScanSettings.openAdjustStockOnOutOfStockScan] — a scan-driven add
//     the stock rules rejected opens the existing Adjust Stock dialog
//     (instead of the out-of-stock toast).
//
// Persistence follows the app_locale / app_theme_mode pattern: a
// StateNotifier that reads its keys SYNCHRONOUSLY in the constructor (the
// POS scan hot path watches the provider — never an async first load that
// could race the first scan), with main.dart overriding the provider with
// the already-loaded SharedPreferences instance.
//
// Deliberately NOT part of the server-owned StoreSettings surface: these
// are per-device operator preferences, so they never touch the backend,
// the database schema, or any migration.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScanSettings {
  final bool openAddProductOnUnknownBarcode;
  final bool openAdjustStockOnOutOfStockScan;

  const ScanSettings({
    this.openAddProductOnUnknownBarcode = false,
    this.openAdjustStockOnOutOfStockScan = false,
  });

  ScanSettings copyWith({
    bool? openAddProductOnUnknownBarcode,
    bool? openAdjustStockOnOutOfStockScan,
  }) {
    return ScanSettings(
      openAddProductOnUnknownBarcode: openAddProductOnUnknownBarcode ??
          this.openAddProductOnUnknownBarcode,
      openAdjustStockOnOutOfStockScan: openAdjustStockOnOutOfStockScan ??
          this.openAdjustStockOnOutOfStockScan,
    );
  }
}

class ScanSettingsNotifier extends StateNotifier<ScanSettings> {
  static const openAddProductOnUnknownBarcodeKey =
      'open_add_product_on_unknown_barcode';
  static const openAdjustStockOnOutOfStockScanKey =
      'open_adjust_stock_on_out_of_stock_scan';

  final SharedPreferences? _prefs;

  ScanSettingsNotifier([SharedPreferences? prefs])
      : _prefs = prefs,
        super(ScanSettings(
          openAddProductOnUnknownBarcode:
              prefs?.getBool(openAddProductOnUnknownBarcodeKey) ?? false,
          openAdjustStockOnOutOfStockScan:
              prefs?.getBool(openAdjustStockOnOutOfStockScanKey) ?? false,
        ));

  void setOpenAddProductOnUnknownBarcode(bool value) {
    state = state.copyWith(openAddProductOnUnknownBarcode: value);
    _prefs?.setBool(openAddProductOnUnknownBarcodeKey, value);
  }

  void setOpenAdjustStockOnOutOfStockScan(bool value) {
    state = state.copyWith(openAdjustStockOnOutOfStockScan: value);
    _prefs?.setBool(openAdjustStockOnOutOfStockScanKey, value);
  }
}

final scanSettingsProvider =
    StateNotifierProvider<ScanSettingsNotifier, ScanSettings>((ref) {
  return ScanSettingsNotifier();
});
