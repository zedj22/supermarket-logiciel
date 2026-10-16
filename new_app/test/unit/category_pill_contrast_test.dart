// Category pill contrast — deterministic foreground selection.
//
// The pill paints the category hue as a 14% wash over the theme surface
// and must keep the label readable in light, dark and grey themes. The
// helper darkens (light theme) or lifts (dark/grey) the SAME hue until
// it clears WCAG AA 4.5:1 against the composited background — these
// tests pin that behavior for every palette color plus representative
// off-palette extremes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/colors.dart';

/// The exact background the pill paints: category at 14% over surface.
Color _compositedBackground(Color category, Brightness brightness) {
  final surface = brightness == Brightness.light
      ? AppColors.lightSurface
      : AppColors.darkSurface;
  return Color.lerp(surface, category, 0.14)!;
}

void main() {
  const brightnesses = [Brightness.light, Brightness.dark];

  // Light yellow / orange / red / purple (the screenshot offenders and
  // their neighbors) plus the full deterministic palette.
  final colors = <Color>[
    ...AppColors.categoryPalette,
    const Color(0xFFFFF176), // pale yellow (off-palette extreme)
    const Color(0xFFFF6F00), // deep orange
    const Color(0xFF222222), // near-black category
    const Color(0xFFFFF8E1), // near-white category
  ];

  group('AppColors.categoryPillForeground', () {
    test('clears WCAG AA 4.5:1 on the composited pill in every theme',
        () {
      for (final category in colors) {
        for (final brightness in brightnesses) {
          final fg = AppColors.categoryPillForeground(category, brightness);
          final bg = _compositedBackground(category, brightness);
          final ratio = AppColors.contrastRatio(fg, bg);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: 'category ${category.toARGB32().toRadixString(16)} '
                '@$brightness gives only ${ratio.toStringAsFixed(2)}:1',
          );
        }
      }
    });

    test('is deterministic (same inputs, same output)', () {
      for (final category in colors) {
        for (final brightness in brightnesses) {
          expect(
            AppColors.categoryPillForeground(category, brightness),
            AppColors.categoryPillForeground(category, brightness),
          );
        }
      }
    });

    test('light theme darkens the hue; dark theme lifts it', () {
      for (final category in AppColors.categoryPalette) {
        final lightFg =
            AppColors.categoryPillForeground(category, Brightness.light);
        final darkFg =
            AppColors.categoryPillForeground(category, Brightness.dark);
        final lightBg = _compositedBackground(category, Brightness.light);
        final darkBg = _compositedBackground(category, Brightness.dark);
        expect(
          lightFg.computeLuminance(),
          lessThan(lightBg.computeLuminance()),
          reason: 'light theme must produce a DARK foreground',
        );
        expect(
          darkFg.computeLuminance(),
          greaterThan(darkBg.computeLuminance()),
          reason: 'dark/grey themes must produce a LIGHT foreground',
        );
      }
    });

    test('keeps the category hue (identity survives the contrast step)',
        () {
      for (final category in AppColors.categoryPalette) {
        final original = HSLColor.fromColor(category);
        for (final brightness in brightnesses) {
          final fg = HSLColor.fromColor(
            AppColors.categoryPillForeground(category, brightness),
          );
          if (fg.lightness <= 0.03 || fg.lightness >= 0.97) {
            // Degenerate black/white endpoint — hue is meaningless there
            // (the saturation/luminance tests still pin legibility).
            continue;
          }
          // Hue is preserved exactly by withLightness; tiny drift comes
          // only from HSL↔RGB float round-tripping (< 1°, far below any
          // perceptible palette swap).
          expect(
            (fg.hue - original.hue).abs(),
            lessThanOrEqualTo(1.0),
            reason: 'hue drifted for '
                '${category.toARGB32().toRadixString(16)}'
                '@$brightness',
          );
          expect(fg.saturation, greaterThan(0.0));
        }
      }
    });

    test('the old lerp-with-white formula fails the yellow case', () {
      // Documents the bug being fixed: the previous foreground for the
      // light-yellow palette entry was illegible on light themes.
      const yellow = Color(0xFFF6BD16);
      final oldFg = Color.lerp(yellow, Colors.white, 0.15)!;
      final bg = _compositedBackground(yellow, Brightness.light);
      expect(AppColors.contrastRatio(oldFg, bg), lessThan(4.5));
      // And the new helper clears it.
      expect(
        AppColors.contrastRatio(
          AppColors.categoryPillForeground(yellow, Brightness.light),
          bg,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('AppColors.contrastRatio', () {
    test('black on white is 21:1; identical colors are 1:1', () {
      expect(AppColors.contrastRatio(Colors.black, Colors.white),
          closeTo(21.0, 0.01));
      expect(AppColors.contrastRatio(Colors.white, Colors.white), 1.0);
    });
  });
}
