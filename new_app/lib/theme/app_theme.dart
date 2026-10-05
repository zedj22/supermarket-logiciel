import 'package:flutter/material.dart';
import '../core/colors.dart';
import 'app_theme_mode.dart';

class AppTheme {
  AppTheme._();

  /// The one bundled family (declared under `flutter.fonts` in pubspec.yaml
  /// and shipped in `assets/fonts/`), so typography is identical on every
  /// machine and never depends on a network fetch the first time the app
  /// is opened.
  static const String fontFamily = 'IBMPlexSansArabic';

  /// Flutter's default Material sizes with [fontFamily] swapped in — the
  /// same base `GoogleFonts.cairoTextTheme()` used to produce, minus the
  /// request to fonts.gstatic.com.  Cached: it is brightness-independent
  /// and rebuilt on every theme switch otherwise.
  static final TextTheme _baseTextTheme =
      ThemeData.light().textTheme.apply(fontFamily: fontFamily);

  /// The single source of truth for mode → [ThemeData].
  ///
  /// `main.dart` and the settings shell used to carry their own copies of
  /// this switch, so a new mode could be wired up in one place and silently
  /// fall back to the default theme in another.
  static ThemeData forMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.dark:
        return dark();
      case AppThemeMode.light:
        return light();
      case AppThemeMode.grey:
        return grey();
    }
  }

  // ---------------------------------------------------------------------------
  // Typography hierarchy (Phase 17 UI polish)
  //
  // Seven rungs, one place. Screens pick a *rung*, never a raw size/weight,
  // so a page title looks like a page title everywhere and the table header
  // on Products is the same table header as on Reports.
  //
  //   display       KPI hero number / dashboard headline
  //   pageTitle     the H1 at the top of a screen
  //   sectionTitle  a labelled block inside a screen
  //   tableHeader   column labels, pinned above the rows
  //   body          primary reading text and table cells
  //   secondary     supporting text (descriptions, meta)
  //   caption       the smallest legal text (badges, units, footnotes)
  //
  // Every rung derives from the active [TextTheme], so it stays
  // brightness/color correct in light, dark and grey for free.
  // ---------------------------------------------------------------------------

  /// Big, bold, short: a KPI number. Never used for a sentence.
  static TextStyle display(ThemeData theme) =>
      (theme.textTheme.displaySmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.5,
      );

  /// Screen H1. Bold but not loud — it names the page, it is not the page.
  static TextStyle pageTitle(ThemeData theme) =>
      (theme.textTheme.headlineSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
      );

  /// H2 — a labelled block (Sales, COGS, Net profit…).
  static TextStyle sectionTitle(ThemeData theme) =>
      (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        height: 1.3,
      );

  /// Column labels. Small, semibold, slightly tracked so a header row reads
  /// as structure instead of as one more data row. 13px is the floor that
  /// still reads at 1366×768 in all three languages.
  static TextStyle tableHeader(ThemeData theme) =>
      (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        height: 1.3,
        letterSpacing: 0.3,
      );

  /// Primary reading text / table cell.
  static TextStyle body(ThemeData theme) =>
      (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(height: 1.4);

  /// Supporting text. Must clear WCAG AA on the surface it sits on — the
  /// mode palettes already guarantee that (see core/colors.dart).
  static TextStyle secondary(ThemeData theme) =>
      (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(height: 1.35);

  /// The smallest legal text: badges, units, footnotes.
  static TextStyle caption(ThemeData theme) =>
      (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(height: 1.3);

  /// Money / quantity / percent: fixed advance width so digits line up
  /// column to column, and never wraps. [size] lets a cell pick a step
  /// down without inventing a new rung.
  static TextStyle numeric(ThemeData theme, {double? size}) =>
      (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
        fontSize: size ?? 14,
        fontWeight: FontWeight.w600,
        height: 1.3,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        background: AppColors.darkBackground,
        surface: AppColors.darkSurface,
        card: AppColors.darkCard,
        border: AppColors.darkBorder,
        textPrimary: AppColors.darkTextPrimary,
        textSecondary: AppColors.darkTextSecondary,
        accent: AppColors.darkAccent,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.darkAccent,
          surface: AppColors.darkSurface,
          error: AppColors.error,
          onPrimary: Colors.white,
          onSurface: AppColors.darkTextPrimary,
        ),
      );

  static ThemeData light() => _build(
        brightness: Brightness.light,
        background: AppColors.lightBackground,
        surface: AppColors.lightSurface,
        card: AppColors.lightCard,
        border: AppColors.lightBorder,
        textPrimary: AppColors.lightTextPrimary,
        textSecondary: AppColors.lightTextSecondary,
        accent: AppColors.lightAccent,
        colorScheme: const ColorScheme.light(
          primary: AppColors.lightAccent,
          surface: AppColors.lightSurface,
          error: AppColors.error,
          onPrimary: Colors.white,
          onSurface: AppColors.lightTextPrimary,
        ),
      );

  static ThemeData grey() => _build(
        brightness: Brightness.dark,
        background: AppColors.greyBackground,
        surface: AppColors.greySurface,
        card: AppColors.greyCard,
        border: AppColors.greyBorder,
        textPrimary: AppColors.greyTextPrimary,
        textSecondary: AppColors.greyTextSecondary,
        accent: AppColors.greyAccent,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.greyAccent,
          surface: AppColors.greySurface,
          error: AppColors.error,
          onPrimary: Colors.white,
          onSurface: AppColors.greyTextPrimary,
        ),
      );

  /// One constructor for all three modes: a component theme added here is
  /// added to light, dark *and* grey at once, which is exactly the bug the
  /// old copy-pasted `dark() / light() / grey()` trio invited.
  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color card,
    required Color border,
    required Color textPrimary,
    required Color textSecondary,
    required Color accent,
    required ColorScheme colorScheme,
  }) {
    final isLight = brightness == Brightness.light;
    final textTheme = _textTheme(textPrimary, textSecondary);
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: background,
      colorScheme: colorScheme,
      cardColor: card,
      dividerColor: border,
      textTheme: textTheme,
      // Interaction states — most rows in the app are plain InkWells, so
      // without these a hovered row and a resting row are the same pixels.
      hoverColor: AppColors.hoverFill(accent, brightness),
      focusColor: AppColors.selectedFill(accent, brightness),
      highlightColor: AppColors.hoverFill(accent, brightness),
      splashColor: AppColors.hoverFill(accent, brightness),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: isLight ? 0.10 : 0.45),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        labelStyle: textTheme.bodyMedium?.copyWith(color: textSecondary),
        hintStyle: textTheme.bodyMedium?.copyWith(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          textStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      // `DataTable` (every report table) picks its header/body typography
      // and row chrome up from here instead of styling each column by hand.
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll<Color?>(
          isLight
              ? const Color(0xFFEDF1F6)
              : surface.withValues(alpha: 0.85),
        ),
        headingRowHeight: 44,
        headingTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          height: 1.3,
          letterSpacing: 0.3,
          color: textPrimary,
        ),
        dataTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: textPrimary,
        ),
        dataRowMinHeight: 40,
        dataRowMaxHeight: 56,
        dividerThickness: 1,
        columnSpacing: 16,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: textSecondary,
        labelStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: textTheme.titleSmall,
        indicatorColor: accent,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: border,
      ),
      dividerTheme: DividerThemeData(color: border),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.3),
        selectionHandleColor: accent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    );
  }

  static TextTheme _textTheme(Color primary, Color secondary) {
    final base = _baseTextTheme;
    // Weights are the hierarchy: Material's defaults are almost all w400,
    // which is why the old UI read as one flat wall of grey text. Sizes stay
    // at Material's scale (already density-tested) so nothing reflows — only
    // the rungs get heavier or lighter.
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.05,
        letterSpacing: -1,
      ),
      displayMedium: base.displayMedium?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.5,
      ),
      displaySmall: base.displaySmall?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.5,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: primary,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      titleMedium: base.titleMedium?.copyWith(
        color: primary,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleSmall: base.titleSmall?.copyWith(
        color: primary,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyLarge: base.bodyLarge?.copyWith(color: primary, height: 1.5),
      bodyMedium: base.bodyMedium?.copyWith(color: primary, height: 1.4),
      bodySmall: base.bodySmall?.copyWith(color: secondary, height: 1.35),
      labelLarge: base.labelLarge?.copyWith(
        color: primary,
        fontWeight: FontWeight.w600,
        height: 1.3,
        letterSpacing: 0.2,
      ),
      labelMedium: base.labelMedium?.copyWith(
        color: secondary,
        fontWeight: FontWeight.w600,
        height: 1.3,
        letterSpacing: 0.2,
      ),
      labelSmall: base.labelSmall?.copyWith(
        color: secondary,
        fontWeight: FontWeight.w600,
        height: 1.3,
        letterSpacing: 0.2,
      ),
    );
  }
}
