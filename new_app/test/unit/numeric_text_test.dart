// LTR display for formatted numeric text (bidi isolation).
//
// Root cause under test: the app runs RTL (Arabic locale), and a
// space-grouped number is several EN runs separated by bidi-neutral
// spaces. In an RTL paragraph the Unicode bidi algorithm reorders those
// runs (and a trailing Latin currency suffix) visually —
// `217 915 895 577.85 DA` renders as `DA 577.85 915 895 217`.
// `numericText` renders the same string in a `Text` with an explicit
// `TextDirection.ltr` paragraph direction, so grouped digits and the
// `DA` / `%` suffix stay in logical order while the surrounding layout
// stays RTL.
//
// These tests assert the TEXT DIRECTION, not just the string content:
// the formatter already produces the right characters (covered by
// number_format_test.dart) — the bug was purely in how they were laid
// out under RTL.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/number_format.dart';
import 'package:supermarket_pos/core/numeric_text.dart';
import 'package:supermarket_pos/features/clients/customer_models.dart';

/// Renders [child] inside an RTL paragraph (the app's Arabic default)
/// and returns the pumped [Text] so the test can assert its direction.
Future<Text> pumpRtlText(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.rtl,
      child: Center(child: child),
    ),
  );
  return tester.widget<Text>(find.byType(Text));
}

/// A pure-number value with no currency suffix.
const _plainMoney = '217 915 895 577.85';
/// The full display string as the UI builds it (value + `DA` suffix).
const _moneyWithCurrency = '217 915 895 577.85 DA';
/// A negative grouped amount.
const _negativeMoney = '-1 234 567.89';
/// A percentage display.
const _percent = '2.5%';
/// An Arabic label followed by a grouped number.
const _arabicLabelled = 'الرصيد: 1 500';
/// A smaller grouped amount (the original reported symptom).
const _smallGrouped = '1 000';
/// A mid-size grouped amount.
const _midGrouped = '20 000';

void main() {
  group('numericText — paragraph direction', () {
    testWidgets('forces TextDirection.ltr even inside an RTL layout',
        (tester) async {
      final t = await pumpRtlText(tester, numericText(_moneyWithCurrency));
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, _moneyWithCurrency);
    });

    testWidgets('forwards data, key, style and textAlign unchanged',
        (tester) async {
      const k = Key('probe');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: numericText(
              _smallGrouped,
              key: k,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      );
      final t = tester.widget<Text>(find.byKey(k));
      expect(t.data, _smallGrouped);
      expect(t.textAlign, TextAlign.end);
      expect(t.style?.fontSize, 13);
      expect(t.textDirection, TextDirection.ltr);
    });

    testWidgets('renders inside an RTL card without flipping the layout',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('بطاقة'),
                    const SizedBox(width: 8),
                    numericText(_moneyWithCurrency),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      // The row is RTL (label on the right); only the value paragraph is LTR.
      final row = tester.widget<Row>(find.byType(Row));
      expect(row.textDirection, isNull); // inherits RTL from Directionality
      final t = tester.widget<Text>(
        find.text(_moneyWithCurrency),
      );
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, _moneyWithCurrency);
    });
  });

  group('numericText — required display strings', () {
    // These are the strings the task calls out; each must keep its
    // grouped digits and (where present) the `DA` / `%` suffix intact
    // under an LTR paragraph.
    const cases = <String, String>{
      'small grouped': _smallGrouped,
      'mid grouped': _midGrouped,
      'large with currency': _moneyWithCurrency,
      'negative grouped': _negativeMoney,
      'percent': _percent,
      'arabic label + number': _arabicLabelled,
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} renders LTR with data verbatim',
          (tester) async {
        final t = await pumpRtlText(tester, numericText(entry.value));
        expect(t.textDirection, TextDirection.ltr);
        expect(t.data, entry.value);
      });
    }
  });

  group('numericText — no formatting applied', () {
    // The helper is display-only: it must pass its input through
    // unchanged. Grouping, signs and decimals are the formatter's job
    // (number_format_test.dart), never the text-direction wrapper's.
    testWidgets('does not regroup or re-sign an already-grouped string',
        (tester) async {
      const input = '4 000 000.00 DA';
      final t = await pumpRtlText(tester, numericText(input));
      expect(t.data, input);
      expect(t.textDirection, TextDirection.ltr);
    });

    testWidgets('passes a plain number through unchanged', (tester) async {
      final t = await pumpRtlText(tester, numericText('0'));
      expect(t.data, '0');
      expect(t.textDirection, TextDirection.ltr);
    });
  });

  group('numericText — works with the real formatters', () {
    // Wire the shared formatter output straight into the helper and
    // assert the resulting Text is LTR — this is the exact call-site
    // pattern used across the app (`numericText(formatMoney(raw))`).
    testWidgets('formatMoney output renders LTR', (tester) async {
      final displayed = formatMoney('217915895577.85');
      expect(displayed, _plainMoney); // formatter contract (unchanged)
      final t = await pumpRtlText(
        tester,
        numericText('$displayed DA'),
      );
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, '$_plainMoney DA');
    });

    testWidgets('formatGrouped output renders LTR', (tester) async {
      final displayed = formatGrouped('1000');
      expect(displayed, _smallGrouped);
      final t = await pumpRtlText(tester, numericText(displayed));
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, _smallGrouped);
    });

    testWidgets('negative formatMoney output renders LTR', (tester) async {
      final displayed = formatMoney('-1234567.89');
      expect(displayed, _negativeMoney);
      final t = await pumpRtlText(
        tester,
        numericText('$displayed DA'),
      );
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, '$_negativeMoney DA');
    });

    testWidgets('percent suffix string renders LTR', (tester) async {
      final displayed = formatGrouped('2.5');
      expect(displayed, _percent.replaceAll('%', ''));
      final t = await pumpRtlText(tester, numericText('$displayed%'));
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, _percent);
    });
  });

  group('numericText — Arabic label + value (mixed string)', () {
    // A single Text whose content is one Arabic label token followed by
    // a grouped number: the whole paragraph is LTR so the number groups
    // and `DA` stay in logical order; the Arabic run still renders
    // right-to-left internally under the LTR paragraph. This is the
    // accepted whole-string approach (see ZakatResultRow, which uses the
    // split-widget pattern instead).
    testWidgets('Arabic label + number + DA renders LTR', (tester) async {
      const mixed = 'الرصيد: 1 500 DA';
      final t = await pumpRtlText(tester, numericText(mixed));
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, mixed);
    });

    testWidgets('label + zakat-style value renders LTR', (tester) async {
      const mixed = 'صافي الوعاء: 217 915 895 577.85 DA';
      final t = await pumpRtlText(tester, numericText(mixed));
      expect(t.textDirection, TextDirection.ltr);
      expect(t.data, mixed);
    });
  });

  group('numericText — real glyph order (RenderParagraph box proof)', () {
    // The Ahem test font still runs the real ICU bidi algorithm during
    // layout, so the box coordinates produced by RenderParagraph are
    // genuine visual-order evidence — not a Windows golden screenshot,
    // but real glyph placement, not just textDirection flags.
    //
    // The detector: locate the trailing ' DA' run and the last digit of
    // the amount; under correct LTR rendering that digit's box sits to
    // the LEFT of the DA box. Duplicated per test file to keep each
    // suite self-contained.
    bool digitsLeftOfDa(RenderParagraph paragraph, String text) {
      final daStart = text.lastIndexOf(' DA');
      final daBoxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: daStart + 1,
        extentOffset: text.length,
      ));
      final digitIdx =
          text.substring(0, daStart).lastIndexOf(RegExp('[0-9]'));
      final digitBoxes = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: digitIdx,
        extentOffset: digitIdx + 1,
      ));
      return digitBoxes.first.left < daBoxes.first.left;
    }

    const moneyStrings = <String>[
      '20 235.00 DA',
      '20 000 DA',
      '1 000 000.00 DA',
      '217 915 895 577.85 DA',
      '-1 234 567.89 DA',
    ];

    for (final money in moneyStrings) {
      testWidgets('LTR paragraph: digits left of DA — "$money"',
          (tester) async {
        await pumpRtlText(tester, numericText(money));
        final paragraph =
            tester.renderObject<RenderParagraph>(find.byType(Text));
        expect(
          digitsLeftOfDa(paragraph, money),
          isTrue,
          reason: '"$money" must keep its grouped digits left of DA '
              'inside an RTL layout',
        );
      });
    }

    testWidgets('RTL counter-proof: plain Text reorders DA to the far left',
        (tester) async {
      // The original reported bug: the same string under an RTL
      // paragraph renders as "DA 235.00 20". The box detector must SEE
      // that reversal — this proves it is not vacuously true.
      const money = '20 235.00 DA';
      await pumpRtlText(tester, const Text(money));
      final paragraph = tester.renderObject<RenderParagraph>(find.byType(Text));
      expect(
        digitsLeftOfDa(paragraph, money),
        isFalse,
        reason: 'plain Text under RTL must reproduce the reported '
            '"DA 235.00 20" reordering',
      );
      // DA is the leftmost glyph run of the whole line.
      final daBoxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 10, extentOffset: 12),
      );
      final allBoxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: money.length),
      );
      final minLeft =
          allBoxes.map((b) => b.left).reduce((a, b) => a < b ? a : b);
      expect(
        daBoxes.first.left,
        minLeft,
        reason: 'under RTL the DA run must be leftmost (the screenshot bug)',
      );
    });

    testWidgets('RTL card: Arabic label right of value; value order kept',
        (tester) async {
      const money = '20 235.00 DA';
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('الإجمالي'),
                    const SizedBox(width: 8),
                    numericText(money, key: const Key('money')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final labelRect = tester.getRect(find.text('الإجمالي'));
      final valueRect = tester.getRect(find.byKey(const Key('money')));
      expect(
        labelRect.left,
        greaterThan(valueRect.left),
        reason: 'RTL row keeps the Arabic label right of the value',
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('money')),
      );
      expect(digitsLeftOfDa(paragraph, money), isTrue);
    });
  });

  group('bidiIsolateLtr — Arabic label + money (bidi W7 regression)', () {
    // Root cause of the remaining Suppliers/Purchases screenshot bugs:
    // bidi rule W7 turns European digits into RTL runs when a strong
    // right-to-left character precedes them IN THE SAME PARAGRAPH — so
    // forcing the whole mixed sentence LTR (numericText) does NOT help:
    // `numericText('الرصيد: 2 000')` still renders `000 2`. The fix is a
    // zero-width LRI/PDI isolate around each money segment. These tests
    // use RenderParagraph box coordinates — real ICU bidi glyph order —
    // not textDirection flags.
    double? leftOf(RenderParagraph p, int base, int extent) => p
        .getBoxesForSelection(
          TextSelection(baseOffset: base, extentOffset: extent),
        )
        .first
        .left;

    /// True when the isolated [money] segment inside [text] is laid out
    /// in logical left-to-right order: first digit box left of the last
    /// digit box, and the last digit left of `DA` when present.
    bool moneyOrderOk(RenderParagraph p, String text, String money) {
      // +1 skips the leading LRI so digit offsets line up with the money.
      final start = text.indexOf(bidiIsolateLtr(money)) + 1;
      if (start <= 0) return false;
      final digits = RegExp('[0-9]').allMatches(money).toList();
      final first =
          leftOf(p, start + digits.first.start, start + digits.first.start + 1)!;
      final last =
          leftOf(p, start + digits.last.start, start + digits.last.start + 1)!;
      if (first > last) return false;
      final daAt = money.lastIndexOf(' DA');
      if (daAt >= 0) {
        final da = leftOf(p, start + daAt + 1, start + daAt + 3)!;
        if (last > da) return false;
      }
      return true;
    }

    Future<RenderParagraph> pumpRtlSentence(
      WidgetTester tester,
      String text,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: Text(text),
            ),
          ),
        ),
      );
      return tester.renderObject<RenderParagraph>(find.byType(Text));
    }

    testWidgets(
        'counter-proof: plain RTL Text reverses the groups of "2 000" '
        '(the original screenshot bug)', (tester) async {
      const s = 'الرصيد: 2 000'; // '2' at 8, '000' at 10..13
      final p = await pumpRtlSentence(tester, s);
      final two = leftOf(p, 8, 9)!;
      final zeros = leftOf(p, 10, 13)!;
      expect(two > zeros, isTrue,
          reason: 'detector must see the RTL reordering (000 then 2)');
    });

    testWidgets(
        'counter-proof: whole-string numericText STILL reverses the groups '
        'after an Arabic label (why the previous fix failed)', (tester) async {
      const s = 'الرصيد: 2 000';
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: numericText(s),
            ),
          ),
        ),
      );
      final p = tester.renderObject<RenderParagraph>(find.byType(Text));
      final two = leftOf(p, 8, 9)!;
      final zeros = leftOf(p, 10, 13)!;
      expect(two > zeros, isTrue,
          reason: 'W7: EN digits after the Arabic run become RTL even in '
              'an LTR paragraph — numericText cannot fix mixed sentences');
    });

    testWidgets('bidiIsolateLtr keeps "2 000" in order under RTL',
        (tester) async {
      final text = 'الرصيد: ${bidiIsolateLtr('2 000')}';
      final p = await pumpRtlSentence(tester, text);
      expect(moneyOrderOk(p, text, '2 000'), isTrue);
      // The Arabic label stays a natural RTL paragraph (no forced LTR).
      expect(tester.widget<Text>(find.byType(Text)).textDirection, isNull);
    });

    testWidgets('isolated "+2 000 DA" keeps sign, groups and DA in order',
        (tester) async {
      final text = 'شراء · ${bidiIsolateLtr('+2 000 DA')}';
      final p = await pumpRtlSentence(tester, text);
      expect(moneyOrderOk(p, text, '+2 000 DA'), isTrue);
    });

    testWidgets('isolated negative "-1 234.56 DA" keeps order under RTL',
        (tester) async {
      final text = 'دفع · ${bidiIsolateLtr('-1 234.56 DA')}';
      final p = await pumpRtlSentence(tester, text);
      expect(moneyOrderOk(p, text, '-1 234.56 DA'), isTrue);
    });

    testWidgets('multi-segment summary: both money segments stay in order',
        (tester) async {
      final text = 'إجمالي السطر: ${bidiIsolateLtr('2 000 DA')} · '
          'تكلفة الوحدة: ${bidiIsolateLtr('1 000 DA')}';
      final p = await pumpRtlSentence(tester, text);
      expect(moneyOrderOk(p, text, '2 000 DA'), isTrue);
      expect(moneyOrderOk(p, text, '1 000 DA'), isTrue);
    });

    testWidgets('isolated money also stays in order under an LTR layout',
        (tester) async {
      final text = 'Balance: ${bidiIsolateLtr('2 000 DA')}';
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: Text(text),
            ),
          ),
        ),
      );
      final p = tester.renderObject<RenderParagraph>(find.byType(Text));
      expect(moneyOrderOk(p, text, '2 000 DA'), isTrue);
    });

    testWidgets('bidiIsolateLtr adds only zero-width isolates (display-only)',
        (tester) async {
      const money = '2 000 DA';
      final wrapped = bidiIsolateLtr(money);
      expect(wrapped.length, money.length + 2);
      expect(wrapped.codeUnitAt(0), 0x2066, reason: 'leading LRI');
      expect(wrapped.codeUnitAt(wrapped.length - 1), 0x2069,
          reason: 'trailing PDI');
      // The formatted characters themselves are untouched between the
      // zero-width controls.
      expect(wrapped.substring(1, wrapped.length - 1), money);
      expect(wrapped.contains(' '), isTrue);
    });
  });
}
