// Phase A — the Scan diagnostics card in Settings.
//
// What matters here:
//  * the card mounts for every operator and offers Start/Stop/Clear/Copy;
//  * it contains NO TextField and never intercepts a keystroke (a wedge
//    digit still passes with handled=false while the panel is mounted);
//  * the copy action exports ONLY the redacted report;
//  * every label is localized (en/ar/fr).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/scan_capture_recorder.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/settings/scan_diagnostics_panel.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';

import '../helpers/wedge_scanner.dart';

Future<void> _pump(
  WidgetTester tester, {
  AppLocale locale = AppLocale.en,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localeProvider.overrideWith(
          (ref) => LocaleNotifier()..setLocale(locale),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: SingleChildScrollView(child: ScanDiagnosticsSection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final recorder = ScanCaptureRecorder.instance;

  setUp(() {
    recorder.stop();
    recorder.clear();
  });

  tearDown(() {
    recorder.stop();
    if (!recorder.isDisposed) recorder.clear();
  });

  group('Scan diagnostics card', () {
    testWidgets('renders with Start armed and Stop/Clear/Copy disabled',
        (tester) async {
      await _pump(tester);

      expect(
        find.text(AppStrings.t('settings_scan_diagnostics', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_desc', 'en')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('settings-scan-diag-start')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.byKey(const Key('settings-scan-diag-empty')),
        findsOneWidget,
      );
      expect(recorder.isActive, isFalse);
    });

    testWidgets('the panel contains no TextField', (tester) async {
      await _pump(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('Start/Stop toggle the session; events count live',
        (tester) async {
      await _pump(tester);

      await _tap(tester, find.byKey(const Key('settings-scan-diag-start')));
      expect(recorder.isActive, isTrue);
      expect(
        find.text(AppStrings.t('scan_diagnostics_status_running', 'en')),
        findsOneWidget,
      );

      // One wedge digit = key-down + key-up = two observed events.
      await tester.sendKeyEvent(digitKey('5'));
      await tester.pump();
      expect(
        find.text(
          '${AppStrings.t('scan_diagnostics_total', 'en')}: 2'
          '   ${AppStrings.t('scan_diagnostics_dropped', 'en')}: 0',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-scan-diag-cat-digit-down')),
        findsOneWidget,
      );

      await _tap(tester, find.byKey(const Key('settings-scan-diag-stop')));
      expect(recorder.isActive, isFalse);
      expect(
        find.text(AppStrings.t('scan_diagnostics_status_idle', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('a mounted panel does not intercept scanner keystrokes',
        (tester) async {
      await _pump(tester);
      await _tap(tester, find.byKey(const Key('settings-scan-diag-start')));

      // Handled=false: the event still flows to the focus system.
      expect(await tester.sendKeyEvent(digitKey('7')), isFalse);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      await tester.pump();
      expect(
        recorder.totalEvents,
        4,
        reason: 'digit down+up, enter down+up — all observed, none consumed',
      );
    });

    testWidgets('Clear empties the history and shows the empty hint',
        (tester) async {
      await _pump(tester);
      await _tap(tester, find.byKey(const Key('settings-scan-diag-start')));
      await tester.sendKeyEvent(digitKey('4'));
      await tester.pump();
      expect(recorder.totalEvents, 2);

      await _tap(tester, find.byKey(const Key('settings-scan-diag-clear')));
      expect(recorder.totalEvents, 0);
      expect(
        find.byKey(const Key('settings-scan-diag-empty')),
        findsOneWidget,
      );
    });

    testWidgets('Copy report writes the redacted export and confirms',
        (tester) async {
      final clipboardCalls = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCalls.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await _pump(tester);
      await _tap(tester, find.byKey(const Key('settings-scan-diag-start')));
      await tester.sendKeyEvent(digitKey('9'));
      await tester.pump();

      await _tap(tester, find.byKey(const Key('settings-scan-diag-copy')));
      expect(clipboardCalls, hasLength(1));
      final text = (clipboardCalls.single as Map)['text'] as String;
      expect(text, contains('Klick POS scan diagnostics (redacted)'));
      // The clipboard received EXACTLY the redacted report — nothing more.
      expect(text, recorder.buildExport());
      expect(text, isNot(contains('suffix3')));
      expect(text, isNot(contains('character')));
      expect(
        find.text(AppStrings.t('scan_diagnostics_copied', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('labels are localized in Arabic', (tester) async {
      await _pump(tester, locale: AppLocale.ar);
      expect(
        find.text(AppStrings.t('settings_scan_diagnostics', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_start', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_status_idle', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_no_events', 'ar')),
        findsOneWidget,
      );
    });

    testWidgets('labels are localized in French', (tester) async {
      await _pump(tester, locale: AppLocale.fr);
      expect(
        find.text(AppStrings.t('settings_scan_diagnostics', 'fr')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_start', 'fr')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_status_idle', 'fr')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('scan_diagnostics_no_events', 'fr')),
        findsOneWidget,
      );
    });
  });
}
