import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

void main() {
  group('ThemeState', () {
    test('defaults to dark mode', () {
      const state = ThemeState();
      expect(state.mode, AppThemeMode.dark);
    });

    test('copyWith overrides mode', () {
      const state = ThemeState();
      final light = state.copyWith(mode: AppThemeMode.light);
      expect(light.mode, AppThemeMode.light);
    });
  });

  group('ThemeNotifier', () {
    test('defaults to dark mode', () {
      final notifier = ThemeNotifier();
      expect(notifier.state.mode, AppThemeMode.dark);
    });

    test('setTheme changes mode', () {
      final notifier = ThemeNotifier();
      notifier.setTheme(AppThemeMode.light);
      expect(notifier.state.mode, AppThemeMode.light);
    });

    test('cycleTheme cycles through modes', () {
      final notifier = ThemeNotifier();
      expect(notifier.state.mode, AppThemeMode.dark);

      notifier.cycleTheme();
      expect(notifier.state.mode, AppThemeMode.light);

      notifier.cycleTheme();
      expect(notifier.state.mode, AppThemeMode.grey);

      notifier.cycleTheme();
      expect(notifier.state.mode, AppThemeMode.dark);
    });
  });
}
