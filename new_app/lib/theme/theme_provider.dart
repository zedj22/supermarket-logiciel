import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_theme_mode.dart';

class ThemeState {
  final AppThemeMode mode;

  const ThemeState({this.mode = AppThemeMode.dark});

  ThemeState copyWith({AppThemeMode? mode}) {
    return ThemeState(mode: mode ?? this.mode);
  }
}

class ThemeNotifier extends StateNotifier<ThemeState> {
  ThemeNotifier() : super(const ThemeState());

  void setTheme(AppThemeMode mode) {
    state = state.copyWith(mode: mode);
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
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeState>((ref) {
  return ThemeNotifier();
});
