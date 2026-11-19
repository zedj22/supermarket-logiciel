// Global readability pass — UI presentation only.
//
// Three contracts the redesign has to keep, none of which touch business
// logic, the API, or the shortcut bindings themselves:
//
//  1. the type ramp has floors.  Sizes below 12px do not read at 1366×768
//     in Arabic, so no rung in any theme may sit under them, and the named
//     rungs land on the documented sizes (title 24–28, section 18–20,
//     table header 13–14 bold, body 14–16, secondary 12–13);
//  2. the keyboard map renders *every* row as a real widget — it is a
//     help surface, so `Space` has to be findable even when it is below
//     the fold — in three columns (key / action+meaning / scope);
//  3. the map fits the window: it grows with the viewport and never runs
//     past it, in LTR and in RTL, at the four supported desktop sizes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/shell/shortcuts_help_dialog.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';

/// Every named rung, so a new theme mode cannot quietly lose a size.
Map<String, TextStyle?> _rungs(ThemeData theme) => <String, TextStyle?>{
      'pageTitle': AppTheme.pageTitle(theme),
      'sectionTitle': AppTheme.sectionTitle(theme),
      'tableHeader': AppTheme.tableHeader(theme),
      'body': AppTheme.body(theme),
      'secondary': AppTheme.secondary(theme),
      'caption': AppTheme.caption(theme),
      'numeric': AppTheme.numeric(theme),
    };

Future<void> _openMap(
  WidgetTester tester, {
  required Size size,
  Locale locale = const Locale('en'),
  AppThemeMode mode = AppThemeMode.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    // The dialog reads the quick-sale setting (it swaps the Space row's
    // meaning when ON), so it is a ConsumerWidget and needs a scope.
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.forMode(mode),
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-shortcuts'),
                onPressed: () => showShortcutsDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('open-shortcuts')));
  await tester.pumpAndSettle();
}

/// Sizes only exist once `MaterialApp` has merged the localizations' type
/// ramp into the theme — a raw `ThemeData` carries the family and the
/// weights but no `fontSize`, so the rungs have to be read from a theme
/// that is actually mounted (the same trick `table_headers_test` uses).
Future<ThemeData> _resolvedTheme(
  WidgetTester tester,
  AppThemeMode mode,
) async {
  ThemeData? resolved;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.forMode(mode),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: Builder(
        builder: (context) {
          resolved = Theme.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return resolved!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('type ramp floors (readability, all three themes)', () {
    for (final mode in AppThemeMode.values) {
      testWidgets('no text style in $mode drops under 12px', (tester) async {
        final theme = await _resolvedTheme(tester, mode);
        final styles = <String, TextStyle?>{
          'displayLarge': theme.textTheme.displayLarge,
          'displayMedium': theme.textTheme.displayMedium,
          'displaySmall': theme.textTheme.displaySmall,
          'headlineLarge': theme.textTheme.headlineLarge,
          'headlineMedium': theme.textTheme.headlineMedium,
          'headlineSmall': theme.textTheme.headlineSmall,
          'titleLarge': theme.textTheme.titleLarge,
          'titleMedium': theme.textTheme.titleMedium,
          'titleSmall': theme.textTheme.titleSmall,
          'bodyLarge': theme.textTheme.bodyLarge,
          'bodyMedium': theme.textTheme.bodyMedium,
          'bodySmall': theme.textTheme.bodySmall,
          'labelLarge': theme.textTheme.labelLarge,
          'labelMedium': theme.textTheme.labelMedium,
          'labelSmall': theme.textTheme.labelSmall,
        };
        final tooSmall = styles.entries
            .where((e) => (e.value?.fontSize ?? 0) < 12)
            .map((e) => '${e.key}=${e.value?.fontSize}');
        expect(
          tooSmall,
          isEmpty,
          reason: '$mode renders these under the 12px readability floor: '
              '$tooSmall',
        );
      });

      testWidgets('the named rungs land on the documented sizes in $mode',
          (tester) async {
        final theme = await _resolvedTheme(tester, mode);
        final rungs = _rungs(theme);

        expect(rungs['pageTitle']!.fontSize!, inInclusiveRange(24, 28));
        expect(rungs['pageTitle']!.fontWeight, FontWeight.w700);

        expect(rungs['sectionTitle']!.fontSize!, inInclusiveRange(18, 20));
        expect(rungs['sectionTitle']!.fontWeight, FontWeight.w700);

        expect(rungs['tableHeader']!.fontSize!, inInclusiveRange(13, 14));
        expect(rungs['tableHeader']!.fontWeight, FontWeight.w700);

        expect(rungs['body']!.fontSize!, inInclusiveRange(14, 16));
        expect(rungs['secondary']!.fontSize!, inInclusiveRange(12, 13));
        expect(rungs['caption']!.fontSize!, inInclusiveRange(12, 13));
        expect(rungs['numeric']!.fontSize!, inInclusiveRange(15, 18));
        expect(rungs['numeric']!.fontFeatures, isNotEmpty,
            reason: 'numbers must keep tabular figures to line up');
      });
    }
  });

  group('keyboard shortcuts map — three columns, every row present', () {
    testWidgets('renders key / action+meaning / scope for all 21 rows',
        (tester) async {
      await _openMap(tester, size: const Size(1280, 720));

      expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);

      // The three column labels; the description now rides under the
      // action instead of owning a fourth, too-narrow column.
      expect(find.text(AppStrings.t('shortcuts_col_key', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('shortcuts_col_action', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('shortcuts_col_scope', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('shortcuts_col_desc', 'en')),
        findsNothing,
      );

      // Every row is built, not lazily materialised: 8 shell rows and 13
      // POS rows, each carrying its own scope label.
      expect(
        find.text(AppStrings.t('shortcuts_scope_global', 'en')),
        findsNWidgets(8),
      );
      expect(
        find.text(AppStrings.t('shortcuts_scope_pos', 'en')),
        findsNWidgets(13),
      );

      // Keys the tests and cashiers reach for specifically.
      expect(find.text('Space / F8'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
      expect(find.text('+'), findsWidgets);

      // The Shift combos sit next to their base keys and carry the same
      // action labels as the buttons they mirror.
      expect(find.text('Shift+F6'), findsOneWidget);
      expect(find.text('Shift+F7'), findsOneWidget);
      expect(find.text(AppStrings.t('add_client', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('loyalty_redeem', 'en')),
        findsOneWidget,
      );

      // The meaning is kept — it is the whole point of the column.
      expect(find.text(AppStrings.t('sc_d_payment', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('sc_d_refresh', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('sc_d_add_customer', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('sc_d_use_points', 'en')),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('the action is the strong line, the meaning is secondary', (
      tester,
    ) async {
      await _openMap(tester, size: const Size(1280, 720));

      final action = tester.widget<Text>(
        find.text(AppStrings.t('sc_a_refresh', 'en')),
      );
      final meaning = tester.widget<Text>(
        find.text(AppStrings.t('sc_d_refresh', 'en')),
      );
      expect(action.style!.fontSize!, greaterThan(meaning.style!.fontSize!));
      expect(action.style!.fontWeight, FontWeight.w600);
      expect(
        action.style!.fontWeight!.value,
        greaterThan(meaning.style!.fontWeight!.value),
        reason: 'the meaning is lighter than the action it explains',
      );

      final key = tester.widget<Text>(find.text('F5'));
      expect(key.style!.fontSize!, greaterThanOrEqualTo(14));
      expect(key.style!.fontWeight, FontWeight.w700);
    });

    testWidgets('fits the window at every supported size and closes', (
      tester,
    ) async {
      for (final entry in <String, Size>{
        '1280x720': const Size(1280, 720),
        '1366x768': const Size(1366, 768),
        '1600x900': const Size(1600, 900),
        '1920x1080': const Size(1920, 1080),
        '800x600': const Size(800, 600),
      }.entries) {
        await _openMap(tester, size: entry.value);

        // The dialog card keeps its 40px inset on every side, so the
        // content box is what proves the map never runs off the window.
        final contentRect = tester.getRect(
          find.byKey(const Key('shortcuts-dialog-content')),
        );
        expect(
          contentRect.width,
          lessThanOrEqualTo(entry.value.width - 80),
          reason: 'the map must never be wider than its window '
              '(${entry.key})',
        );
        expect(
          contentRect.bottom,
          lessThanOrEqualTo(entry.value.height - 40),
          reason: 'title + body + close button must stay on screen '
              '(${entry.key})',
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('shortcuts-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shortcuts-dialog')), findsNothing);
      }
    });

    testWidgets('grows with the window instead of keeping a fixed width', (
      tester,
    ) async {
      await _openMap(tester, size: const Size(800, 600));
      final small = tester
          .getSize(find.byKey(const Key('shortcuts-dialog-content')))
          .width;
      await tester.tap(find.byKey(const Key('shortcuts-close')));
      await tester.pumpAndSettle();

      await _openMap(tester, size: const Size(1920, 1080));
      final large = tester
          .getSize(find.byKey(const Key('shortcuts-dialog-content')))
          .width;

      expect(large, greaterThan(small),
          reason: 'a 1920px window gets a wider map than an 800px one');
    });

    testWidgets('renders in Arabic under RTL without overflow', (tester) async {
      await _openMap(
        tester,
        size: const Size(1366, 768),
        locale: const Locale('ar'),
      );

      // Ambient direction flipped …
      final direction = Directionality.of(
        tester.element(find.byKey(const Key('shortcuts-dialog'))),
      );
      expect(direction, TextDirection.rtl);

      // … but the key symbols are still the exact labels, and the map
      // still renders every row without throwing.
      expect(find.text('Space / F8'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);
      expect(find.text('Shift+F6'), findsOneWidget);
      expect(find.text('Shift+F7'), findsOneWidget);
      expect(
        find.text(AppStrings.t('shortcuts_scope_pos', 'ar')),
        findsNWidgets(13),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in French (the longest scope label)', (tester) async {
      await _openMap(
        tester,
        size: const Size(1280, 720),
        locale: const Locale('fr'),
      );

      // "Toutes les pages" is the longest scope string in the app — it
      // must fit its column rather than push the table apart.
      expect(
        find.text(AppStrings.t('shortcuts_scope_global', 'fr')),
        findsNWidgets(8),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('all three theme modes draw the map legibly', (tester) async {
      for (final mode in AppThemeMode.values) {
        await _openMap(
          tester,
          size: const Size(1366, 768),
          mode: mode,
        );
        expect(find.byKey(const Key('shortcuts-dialog')), findsOneWidget);
        expect(find.text('Space / F8'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('shortcuts-close')));
        await tester.pumpAndSettle();
      }
    });
  });
}
