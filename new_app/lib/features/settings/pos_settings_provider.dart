// Configurable POS operator preferences (client-local, SharedPreferences).
//
// Currently one toggle:
//   * [PosSettings.quickSaleWithSpace] — pressing SPACE in the POS
//     workspace completes the current valid sale directly (full cash
//     payment of the amount due through the EXISTING checkout pipeline)
//     instead of opening the payment dialog. OFF by default: an
//     installation that never saved a value keeps the ordinary
//     Space → payment-dialog behaviour bit-for-bit.
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

class PosSettings {
  final bool quickSaleWithSpace;

  const PosSettings({
    this.quickSaleWithSpace = false,
  });

  PosSettings copyWith({
    bool? quickSaleWithSpace,
  }) {
    return PosSettings(
      quickSaleWithSpace: quickSaleWithSpace ?? this.quickSaleWithSpace,
    );
  }
}

class PosSettingsNotifier extends StateNotifier<PosSettings> {
  static const quickSaleWithSpaceKey = 'quick_sale_with_space';

  final SharedPreferences? _prefs;

  PosSettingsNotifier([SharedPreferences? prefs])
      : _prefs = prefs,
        super(PosSettings(
          quickSaleWithSpace:
              prefs?.getBool(quickSaleWithSpaceKey) ?? false,
        ));

  void setQuickSaleWithSpace(bool value) {
    state = state.copyWith(quickSaleWithSpace: value);
    _prefs?.setBool(quickSaleWithSpaceKey, value);
  }
}

final posSettingsProvider =
    StateNotifierProvider<PosSettingsNotifier, PosSettings>((ref) {
  return PosSettingsNotifier();
});
