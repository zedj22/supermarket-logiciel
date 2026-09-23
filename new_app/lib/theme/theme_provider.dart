import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme_mode.dart';

class ThemeState {
  final AppThemeMode mode;

  const ThemeState({this.mode = AppThemeMode.dark});

  ThemeState copyWith({AppThemeMode? mode}) {
    return ThemeState(mode: mode ?? this.mode);
  }
}

class ThemeNotifier extends StateNotifier<ThemeState> {
  static const prefsKey = 'app_theme_mode';

  final SharedPreferences? _prefs;

  ThemeNotifier([SharedPreferences? prefs])
      : _prefs = prefs,
        super(ThemeState(mode: _read(prefs)));

  static AppThemeMode _read(SharedPreferences? prefs) {
    final raw = prefs?.getString(prefsKey);
    if (raw == null || raw.isEmpty) return AppThemeMode.dark;
    for (final value in AppThemeMode.values) {
      if (value.name == raw) return value;
    }
    return AppThemeMode.dark;
  }

  void setTheme(AppThemeMode mode) {
    state = state.copyWith(mode: mode);
    _persist();
  }

  void cycleTheme() {
    switch (state.mode) {
      case AppThemeMode.dark:
        state = state.copyWith(mode: AppThemeMode.light);
        break;
      case AppThemeMode.light:
        state = state.copyWith(mode: AppThemeMode.grey);
        break;
      case AppThemeMode.grey:
        state = state.copyWith(mode: AppThemeMode.dark);
        break;
    }
    _persist();
  }

  void _persist() {
    _prefs?.setString(prefsKey, state.mode.name);
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeState>((ref) {
  return ThemeNotifier();
});
