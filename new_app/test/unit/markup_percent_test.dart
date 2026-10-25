// The ONE shared profit-percentage definition (`core/markup_percent.dart`).
//
//   markup = ((selling_price - cost_price) / cost_price) * 100
//
// Every screen that shows a profit percentage must go through this helper
// so the metric cannot drift back to `profit / price` anywhere:
//   * product form Pricing row  → `productFormProfitMarkup`
//   * product list column       → `productProfitMarkup`
//   * pack create/edit estimate → `_estimatedMarkup`
//   * pack detail estimate      → `PackModel.estimatedMarkupPercent`
//   * product/category reports  → `ProductReportRow.marginPct`
//
// Contract: NN.NN% (integer hundredths, truncated), `null` for a missing /
// unparsable / non-positive cost, absolute money values untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/markup_percent.dart';

void main() {
  group('markupPercent — profit as a percentage of cost', () {
    test('cost 2 000 / price 4 000 → 100%', () {
      expect(
        markupPercent(profitMilli: 2000000, costMilli: 2000000),
        '100.00%',
      );
    });

    test('cost 2 000 / price 3 000 → 50%', () {
      expect(markupPercent(profitMilli: 1000000, costMilli: 2000000), '50.00%');
    });

    test('cost 2 000 / price 2 500 → 25%', () {
      expect(markupPercent(profitMilli: 500000, costMilli: 2000000), '25.00%');
    });

    test('truncates in integer hundredths, never rounds up', () {
      // 12 / 18 = 66.666…% → 66.66% (report row: profit 12, COGS 18).
      expect(markupPercent(profitMilli: 12000, costMilli: 18000), '66.66%');
      // 1 / 3 = 33.333…% → 33.33%.
      expect(markupPercent(profitMilli: 1000, costMilli: 3000), '33.33%');
    });

    test('keeps negative markup when selling below cost', () {
      expect(markupPercent(profitMilli: -1000000, costMilli: 2000000), '-50.00%');
    });

    test('zero or missing cost never divides by zero', () {
      expect(markupPercent(profitMilli: 2000000, costMilli: 0), isNull);
      expect(markupPercent(profitMilli: 2000000, costMilli: -1), isNull);
      expect(markupPercent(profitMilli: 2000000, costMilli: null), isNull);
      expect(markupPercent(profitMilli: null, costMilli: 2000000), isNull);
    });
  });

  group('markupPercentRaw — from money strings', () {
    test('cost 2 000 / profit 2 000 → 100%', () {
      expect(
        markupPercentRaw(profitRaw: '2000', costRaw: '2000'),
        '100.00%',
      );
    });

    test('cost 2 000 / profit 1 000 → 50%', () {
      expect(markupPercentRaw(profitRaw: '1000', costRaw: '2000'), '50.00%');
    });

    test('cost 2 000 / profit 500 → 25%', () {
      expect(markupPercentRaw(profitRaw: '500', costRaw: '2000'), '25.00%');
    });

    test('pack-style figures: cost 240 / profit 80 → 33.33%', () {
      expect(markupPercentRaw(profitRaw: '80', costRaw: '240'), '33.33%');
    });

    test('grouped and decimal money strings parse', () {
      expect(markupPercentRaw(profitRaw: '1 000', costRaw: '2 000.000'),
          '50.00%');
    });

    test('missing, invalid or non-positive cost → null', () {
      expect(markupPercentRaw(profitRaw: '80', costRaw: null), isNull);
      expect(markupPercentRaw(profitRaw: null, costRaw: '240'), isNull);
      expect(markupPercentRaw(profitRaw: '80', costRaw: ''), isNull);
      expect(markupPercentRaw(profitRaw: '80', costRaw: 'abc'), isNull);
      expect(markupPercentRaw(profitRaw: '80', costRaw: '0'), isNull);
      expect(markupPercentRaw(profitRaw: '80', costRaw: '-240'), isNull);
      expect(markupPercentRaw(profitRaw: '-80', costRaw: '-240'), isNull);
      expect(markupPercentRaw(profitRaw: '80.1234', costRaw: '240'), isNull);
    });
  });

  group('profitAndMarkupRaw — absolute profit plus the percentage', () {
    test('cost 2 000 / price 4 000 → (2000.000, 100.00%)', () {
      expect(
        profitAndMarkupRaw(priceRaw: '4000', costRaw: '2000'),
        ('2000.000', '100.00%'),
      );
    });

    test('cost 2 000 / price 3 000 → (1000.000, 50.00%)', () {
      expect(
        profitAndMarkupRaw(priceRaw: '3000', costRaw: '2000'),
        ('1000.000', '50.00%'),
      );
    });

    test('cost 2 000 / price 2 500 → (500.000, 25.00%)', () {
      expect(
        profitAndMarkupRaw(priceRaw: '2500', costRaw: '2000'),
        ('500.000', '25.00%'),
      );
    });

    test('profit stays exact thousandths while markup truncates to 2dp', () {
      expect(
        profitAndMarkupRaw(priceRaw: '2000.5', costRaw: '2000'),
        ('0.500', '0.02%'),
      );
    });

    test('a zero cost keeps the profit but hides the percentage', () {
      expect(
        profitAndMarkupRaw(priceRaw: '4000', costRaw: '0'),
        ('4000.000', null),
      );
    });

    test('unparsable input yields (null, null) — no half-computed row', () {
      expect(profitAndMarkupRaw(priceRaw: '', costRaw: '2000'), (null, null));
      expect(profitAndMarkupRaw(priceRaw: '4000', costRaw: 'x'), (null, null));
      expect(profitAndMarkupRaw(priceRaw: null, costRaw: '2000'), (null, null));
    });
  });
}
