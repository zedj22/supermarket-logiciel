// Phase 17 (§17.5) — theme system.
//
// "All themes work" is four separate guarantees:
//
//  1. every `AppThemeMode` resolves to a real, distinguishable [ThemeData]
//     (`AppTheme.forMode` is the single mapping — `main.dart` and the
//     settings shell share it, so a new mode cannot half-exist);
//  2. every mode persists and survives a cold start, and a corrupt value
//     degrades to the default instead of throwing;
//  3. every mode is *readable* — a theme whose text disappears against its
//     own card renders, but it does not work.  WCAG AA body text is 4.5:1
//     and large/bold text, icons and button labels are 3:1; the gates below
//     assert exactly that and print the measured ratios so a regression is
//     visible, not silent;
//  4. typography is deterministic and offline.  The app runs on an
//     isolated LAN, so a font fetched from fonts.gstatic.com fails on
//     every cold start and falls back to whatever the platform has — the
//     family is bundled in `assets/fonts/` instead.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

const _expectedBrightness = <AppThemeMode, Brightness>{
  AppThemeMode.dark: Brightness.dark,
  AppThemeMode.light: Brightness.light,
  AppThemeMode.grey: Brightness.dark,
};

/// [TextTheme] has no way to iterate its styles, so they are listed once
/// here and every style is checked rather than a hand-picked few.
Map<String, TextStyle?> _stylesOf(TextTheme t) => <String, TextStyle?>{
      'displayLarge': t.displayLarge,
      'displayMedium': t.displayMedium,
      'displaySmall': t.displaySmall,
      'headlineLarge': t.headlineLarge,
      'headlineMedium': t.headlineMedium,
      'headlineSmall': t.headlineSmall,
      'titleLarge': t.titleLarge,
      'titleMedium': t.titleMedium,
      'titleSmall': t.titleSmall,
      'bodyLarge': t.bodyLarge,
      'bodyMedium': t.bodyMedium,
      'bodySmall': t.bodySmall,
      'labelLarge': t.labelLarge,
      'labelMedium': t.labelMedium,
      'labelSmall': t.labelSmall,
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

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    testWidgets('body text — primary and secondary — meets WCAG AA (4.5:1)',
        (tester) async {
      const threshold = 4.5;
      final failures = <String>[];
      final measured = <String>[];

      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final card = theme.cardTheme.color ?? theme.colorScheme.surface;
        final secondary = theme.textTheme.bodySmall?.color ??
            theme.colorScheme.onSurface;

        final checks = <String, (Color, Color)>{
          'primary on surface': (theme.colorScheme.onSurface, theme.colorScheme.surface),
          'primary on background':
              (theme.colorScheme.onSurface, theme.scaffoldBackgroundColor),
          'primary on card': (theme.colorScheme.onSurface, card),
          'bodySmall on card': (secondary, card),
          'bodySmall on background':
              (secondary, theme.scaffoldBackgroundColor),
          'labelMedium on card':
              (theme.textTheme.labelMedium?.color ?? secondary, card),
          'labelMedium on background': (
            theme.textTheme.labelMedium?.color ?? secondary,
            theme.scaffoldBackgroundColor,
          ),
          'labelSmall on card':
              (theme.textTheme.labelSmall?.color ?? secondary, card),
        };

        for (final entry in checks.entries) {
          final ratio = contrast(entry.value.$1, entry.value.$2);
          measured.add('  $mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          if (ratio < threshold) {
            failures.add('$mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          }
        }
      }

      // ignore: avoid_print
      print('WCAG AA body text (need $threshold)\n${measured.join('\n')}');
      expect(
        failures,
        isEmpty,
        reason: 'body text below $threshold:1 — fails WCAG AA: $failures',
      );
    });

    testWidgets('buttons and accents stay legible (3:1)', (tester) async {
      const threshold = 3.0;
      final failures = <String>[];
      final measured = <String>[];

      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final checks = <String, (Color, Color)>{
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
          if (ratio < threshold) {
            failures.add('$mode ${entry.key}: ${ratio.toStringAsFixed(2)}');
          }
        }
      }

      // ignore: avoid_print
      print('WCAG 3:1 controls (need $threshold)\n${measured.join('\n')}');
      expect(
        failures,
        isEmpty,
        reason: 'below $threshold:1 — a button or accent disappears: '
            '$failures',
      );
    });
  });

  group('typography is bundled, never fetched', () {
    testWidgets('every text style in every theme carries the bundled family',
        (tester) async {
      for (final mode in AppThemeMode.values) {
        final theme = AppTheme.forMode(mode);
        final wrong = _stylesOf(theme.textTheme).entries
            .where((e) => e.value?.fontFamily != AppTheme.fontFamily)
            .map((e) => '${e.key}=${e.value?.fontFamily}');
        expect(
          wrong,
          isEmpty,
          reason:
              '$mode would render in a platform font: ${wrong.join(', ')}',
        );
      }
    });

    test('the family is declared in pubspec.yaml with both weights', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec,
        contains('family: ${AppTheme.fontFamily}'),
        reason: 'flutter.fonts must declare the bundled family',
      );
      expect(pubspec, contains('weight: 400'));
      expect(pubspec, contains('weight: 700'));
      expect(
        pubspec,
        isNot(contains('google_fonts')),
        reason: 'google_fonts pulls fonts from the network at runtime',
      );
    });

    test('the font files actually ship with the app', () {
      for (final file in [
        'assets/fonts/IBMPlexSansArabic-Regular.ttf',
        'assets/fonts/IBMPlexSansArabic-Bold.ttf',
      ]) {
        expect(
          File(file).existsSync(),
          isTrue,
          reason: '$file is missing — the app would silently lose its type',
        );
      }
    });

    test('nothing in lib/ reaches for a font over the network', () {
      final banned = RegExp(
        r'google_fonts|GoogleFonts|fonts\.gstatic\.com|allowRuntimeFetching',
      );
      final violations = <String>[];
      for (final file in _dartFiles('lib')) {
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          // Only code counts: a doc comment may legitimately name the
          // package it replaced.
          if (lines[i].trimLeft().startsWith('//')) continue;
          if (banned.hasMatch(lines[i])) {
            violations.add('${file.path.replaceAll('\\', '/')}:${i + 1}');
            break;
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'runtime font fetching on an offline LAN: $violations',
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
