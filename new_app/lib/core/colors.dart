import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Dark theme
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkCard = Color(0xFF2D2D2D);
  static const Color darkBorder = Color(0xFF404040);
  static const Color darkTextPrimary = Color(0xFFE0E0E0);
  static const Color darkTextSecondary = Color(0xFF9E9E9E);
  static const Color darkAccent = Color(0xFF2196F3);

  // Light theme
  //
  // Secondary text sits on the #F5F5F5 scaffold: 0xFF757575 measured 4.23:1
  // there, just under the WCAG AA 4.5:1 body-text floor. 0xFF6E6E6E gives
  // 4.68:1 on the scaffold and 5.10:1 on white cards — the same neutral
  // grey, two steps darker.
  static const Color lightBackground = Color(0xFFF5F5F5);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFE0E0E0);
  static const Color lightTextPrimary = Color(0xFF212121);
  static const Color lightTextSecondary = Color(0xFF6E6E6E);
  static const Color lightAccent = Color(0xFF1976D2);

  // Grey theme
  //
  // Secondary text sits on the #333333 card: 0xFF808080 measured 3.20:1,
  // well under WCAG AA. 0xFF9E9E9E gives 4.72:1 on the card (and 5.36:1 on
  // the surface) and matches the dark theme's secondary, so the two dark
  // palettes stay consistent.
  static const Color greyBackground = Color(0xFF1A1A1A);
  static const Color greySurface = Color(0xFF2A2A2A);
  static const Color greyCard = Color(0xFF333333);
  static const Color greyBorder = Color(0xFF4A4A4A);
  static const Color greyTextPrimary = Color(0xFFD0D0D0);
  static const Color greyTextSecondary = Color(0xFF9E9E9E);
  static const Color greyAccent = Color(0xFF607D8B);

  // Semantic colors
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFF9800);
  static const Color error = Color(0xFFF44336);
  static const Color info = Color(0xFF2196F3);

  // The three states a *financial* figure or a *stock* number can carry.
  // They are hues, not text colors: never paint body copy with them
  // directly — resolve through [onTint] for the foreground instead.
  static const Color positive = success;
  static const Color negative = error;
  static const Color attention = warning;

  /// Fill alpha for a semantic tint on the current surface.
  ///
  /// Light surfaces are near-white, so a weak tint reads as "nothing";
  /// the two dark palettes are already low-luminance and need less paint.
  static double tintAlpha(Brightness brightness) =>
      brightness == Brightness.light ? 0.14 : 0.20;

  /// A readable foreground for text/icons sitting on [tint]-ed fill of the
  /// same accent. Derived through HSL rather than hand-picked so every
  /// accent (success, warning, error, info, report tones) stays legible in
  /// light, dark *and* grey without a per-accent table.
  static Color onTint(Color accent, Brightness brightness) {
    final hsl = HSLColor.fromColor(accent);
    if (brightness == Brightness.light) {
      // Darken: a 4.5:1 foreground on the pale tint.
      return hsl
          .withLightness((hsl.lightness * 0.55).clamp(0.0, 1.0))
          .withSaturation((hsl.saturation * 1.05).clamp(0.0, 1.0))
          .toColor();
    }
    // Lighten: the tint is dark, so lift the hue back up.
    return hsl
        .withLightness((hsl.lightness * 1.25 + 0.16).clamp(0.0, 1.0))
        .toColor();
  }

  /// One tinted fill for a semantic accent, brightness aware.
  static Color tint(Color accent, Brightness brightness) =>
      accent.withValues(alpha: tintAlpha(brightness));

  /// Row hover / selected fills — a wash of the *theme* accent, never a
  /// hardcoded hue, so light/dark/grey all inherit it.
  static Color hoverFill(Color accent, Brightness brightness) =>
      accent.withValues(alpha: brightness == Brightness.light ? 0.07 : 0.12);

  static Color selectedFill(Color accent, Brightness brightness) =>
      accent.withValues(alpha: brightness == Brightness.light ? 0.12 : 0.20);

  // ---------------------------------------------------------------------------
  // Categorical identity (categories, brands) — deliberately *not* theme
  // colors. A category keeps the same hue for ever, in every theme, because
  // the hue *is* the identifier; the ramps above express state instead.
  // ---------------------------------------------------------------------------

  static const List<Color> categoryPalette = <Color>[
    Color(0xFF5B8FF9),
    Color(0xFF5AD8A6),
    Color(0xFF5D7092),
    Color(0xFFF6BD16),
    Color(0xFFE8684A),
    Color(0xFF6DC8EC),
    Color(0xFF9270CA),
    Color(0xFFFF9D4D),
  ];

  /// Deterministic palette pick from an identity string (stable across
  /// sessions and devices, no schema change).
  static Color categoryIdentity(String identity) {
    var hash = 0;
    for (final unit in identity.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return categoryPalette[hash % categoryPalette.length];
  }
}
