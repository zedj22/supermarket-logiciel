// RTL bidi isolation regression tests (W7) — REAL widgets.
//
// Contract: standalone numeric strings keep `numericText()`; mixed
// Arabic+number strings use plain `Text` with `bidiIsolateLtr()` around
// each numeric segment. Isolates prevent digit-group reordering in RTL
// paragraphs (bidi rule W7: a numeric group adjacent to Arabic text swaps
// unless isolated).
//
// Covered here (pumped directly, no full-app harness):
// - ZakatWarningTile — server detail values isolated after the label;
// - ZakatResultRow — label column untouched, value column is numericText.
//
// Screens already covered by updated exact-string assertions in their own
// suites: clients detail/history (clients_screen_test), invoice line
// (invoice_line_price_reference_test), facturation form lines
// (facturation_screen_test), quantity dialog (pos_weight_amount_entry_
// test + pos_screen_test), POS cart counts / base price / sale snapshots
// (pos_screen_test).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/features/zakat/zakat_models.dart';
import 'package:supermarket_pos/features/zakat/zakat_widgets.dart';
import 'package:supermarket_pos/main.dart';

String _i(String v) => bidiIsolateLtr(v);

Future<void> _pumpAr(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('ZakatWarningTile (real widget)', () {
    testWidgets(
        'grouped server detail values render as LTR isolates after the '
        'Arabic label', (tester) async {
      await _pumpAr(
        tester,
        const ZakatWarningTile(
          warning: ZakatWarning(
            code: 'BELOW_NISAB',
            detail: {'nisab': '1 200', 'threshold': '3 400'},
          ),
          testKey: Key('warning-tile'),
        ),
      );

      final text = tester.widget<Text>(find.byKey(const Key('warning-tile'))).data!;
      expect(text, contains(_i('1 200')));
      expect(text, contains(_i('3 400')));
      expect(text, contains('\u2066'), reason: 'LRI must open each isolate');
      expect(text, contains('\u2069'), reason: 'PDI must close each isolate');
    });

    testWidgets('empty detail renders the bare label (no isolate chars)',
        (tester) async {
      await _pumpAr(
        tester,
        const ZakatWarningTile(
          warning: ZakatWarning(code: 'BELOW_NISAB'),
          testKey: Key('warning-tile'),
        ),
      );

      final text = tester.widget<Text>(find.byKey(const Key('warning-tile'))).data!;
      expect(text, isNot(contains('\u2066')));
      expect(text, isNot(contains('\u2069')));
    });
  });

  group('ZakatResultRow (real widget)', () {
    testWidgets('value column stays numericText (standalone numbers)', (
      tester,
    ) async {
      await _pumpAr(
        tester,
        const ZakatResultRow(
          labelKey: 'zakat_total',
          value: '12 345.00',
          testKey: Key('result-row'),
        ),
      );

      // numericText wraps the string — data must be the raw value with
      // no isolate characters (standalone-number contract).
      final text = tester.widget<Text>(find.byKey(const Key('result-row'))).data!;
      expect(text, '12 345.00');
      expect(text, isNot(contains('\u2066')));
    });
  });
}
