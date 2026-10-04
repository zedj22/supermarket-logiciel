// Phase 17 (§17.5) — theme system.
//
// "All themes work" is three separate guarantees:
//
//  1. every `AppThemeMode` resolves to a real, distinguishable [ThemeData]
//     (`AppTheme.forMode` is the single mapping — `main.dart` and the
//     settings shell share it, so a new mode cannot half-exist);
//  2. every mode persists and survives a cold start, and a corrupt value
//     degrades to the default instead of throwing;
//  3. every mode is *readable* — a theme whose text disappears against its
//     own card renders, but it does not work.  WCAG AA is 4.5:1 for body
//     text and 3:1 for large/bold text, icons and button labels; the gate
//     below asserts AA for primary text and 3:1 for everything else, and
//     prints the measured ratios so a regression is visible, not silent.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

const _expectedBrightness = <AppThemeMode, Brightness>{
  AppThemeMode.dark: Brightness.dark,
  AppThemeMode.light: Brightness.light,
  AppThemeMode.grey: Brightness.dark,
};

double _luminance(Color color) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('mode → ThemeData (Phase 17 §17.5)', () {
    testWidgets('every AppThemeMode resolves through AppTheme.forMode',
        (tester) async {
      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        expect(
          theme.brightness,
          _expectedBrightness[mode],
          reason: '$mode has the wrong brightness',
        );
        expect(theme, isA<ThemeData>());
      }
    });

    testWidgets('the three themes are visually distinct', (tester) async {
      final themes = <AppThemeMode, ThemeData>{
        for (final mode in AppThemeMode.values) mode: AppTheme.forMode(mode),
      };

      final backgrounds = themes.values
          .map((t) => t.scaffoldBackgroundColor)
          .toSet();
      expect(
        backgrounds.length,
        AppThemeMode.values.length,
        reason: 'two modes share a scaffold background — switching between '
            'them would look like nothing happened: $backgrounds',
      );

      final primaries =
          themes.values.map((t) => t.colorScheme.primary).toSet();
      expect(
        primaries.length,
        AppThemeMode.values.length,
        reason: 'two modes share an accent colour: $primaries',
      );
    });

    testWidgets('every theme defines the surfaces the app actually draws on',
        (tester) async {
      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final components = <String, Object?>{
          'appBarTheme': theme.appBarTheme.backgroundColor,
          'cardTheme': theme.cardTheme.color,
          'scaffoldBackgroundColor': theme.scaffoldBackgroundColor,
          'inputDecorationTheme.fillColor':
              theme.inputDecorationTheme.fillColor,
          'elevatedButtonTheme':
              theme.elevatedButtonTheme.style?.backgroundColor,
          'textTheme.bodyMedium': theme.textTheme.bodyMedium?.color,
          'textTheme.bodySmall': theme.textTheme.bodySmall?.color,
          'textTheme.titleMedium': theme.textTheme.titleMedium?.color,
        };
        final missing =
            components.entries.where((e) => e.value == null).map((e) => e.key);
        expect(
          missing,
          isEmpty,
          reason: '$mode leaves these unthemed (they fall back to the '
              'default light palette): $missing',
        );
        expect(theme.inputDecorationTheme.filled, isTrue,
            reason: '$mode must keep its inputs filled, not transparent');
      }
    });
  });

  group('every theme is readable', () {
    testWidgets('primary text meets WCAG AA against its own surfaces',
        (tester) async {
      final failures = <String>[];
      final measured = <String>[];

      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final text = theme.colorScheme.onSurface;
        final surfaces = <String, Color>{
          'surface': theme.colorScheme.surface,
          'background': theme.scaffoldBackgroundColor,
          'card': theme.cardTheme.color ?? theme.colorScheme.surface,
        };
        for (final entry in surfaces.entries) {
          final ratio = contrast(text, entry.value);
          measured.add('  $mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          if (ratio < 4.5) {
            failures.add('$mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          }
        }
      }

      // ignore: avoid_print
      print('WCAG AA primary text (need 4.5)\n${measured.join('\n')}');
      expect(
        failures,
        isEmpty,
        reason: 'primary text below 4.5:1 — unreadable: $failures',
      );
    });

    testWidgets('captions, buttons and accents stay legible (3:1)',
        (tester) async {
      final failures = <String>[];
      final measured = <String>[];

      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final card = theme.cardTheme.color ?? theme.colorScheme.surface;
        final bodySmall = theme.textTheme.bodySmall?.color ??
            theme.colorScheme.onSurface;
        final labelMedium = theme.textTheme.labelMedium?.color ??
            theme.colorScheme.onSurface;
        final checks = <String, (Color, Color)>{
          'bodySmall on card': (bodySmall, card),
          'labelMedium on background': (labelMedium, theme.scaffoldBackgroundColor),
          'button label on primary': (
            theme.colorScheme.onPrimary,
            theme.colorScheme.primary,
          ),
          'accent on background': (
            theme.colorScheme.primary,
            theme.scaffoldBackgroundColor,
          ),
        };
        for (final entry in checks.entries) {
          final ratio = contrast(entry.value.$1, entry.value.$2);
          measured.add('  $mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          if (ratio < 3.0) {
            failures.add('$mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          }
        }
      }

      // ignore: avoid_print
      print('WCAG 3:1 secondary text / controls (need 3.0)\n'
          '${measured.join('\n')}');
      expect(
        failures,
        isEmpty,
        reason: 'below 3:1 — a caption, button or accent disappears: '
            '$failures',
      );
    });
  });

  group('theme persists across a cold start', () {
    for (final mode in AppThemeMode.values) {
      test('setTheme("$mode") is what the next app start reads', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final notifier = ThemeNotifier(prefs);
        notifier.setTheme(mode);
        expect(
          prefs.getString(ThemeNotifier.prefsKey),
          mode.name,
          reason: 'the mode was not written to SharedPreferences',
        );
        expect(notifier.state.mode, mode);

        // A brand new notifier = a fresh process.
        final restarted = ThemeNotifier(prefs);
        expect(
          restarted.state.mode,
          mode,
          reason: 'the mode did not survive the restart',
        );
      });
    }

    test('an unknown stored value degrades to dark, never throws', () async {
      SharedPreferences.setMockInitialValues({
        ThemeNotifier.prefsKey: 'neon-zebra',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(ThemeNotifier(prefs).state.mode, AppThemeMode.dark);
    });

    test('a missing stored value defaults to dark', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(ThemeNotifier(prefs).state.mode, AppThemeMode.dark);
    });
  });
}
