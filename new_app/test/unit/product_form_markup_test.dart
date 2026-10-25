// Profit percentage across the product screens — markup ON COST, never
// margin on the selling price.
//
// Contract under test (`productFormProfitMarkup` and the products-table
// `productProfitMarkup`, both display only, both delegating to the shared
// `core/markup_percent.dart` helper):
//   profit = price - cost                       (exact thousandths)
//   markup = ((price - cost) / cost) * 100      (NN.NN%, integer hundredths)
//
// Worked examples from the spec:
//   cost 2 000 / price 4 000 → profit 2 000, markup 100%
//   cost 2 000 / price 3 000 → profit 1 000, markup  50%
//   cost 2 000 / price 2 500 → profit   500, markup  25%
//
// The product form and the product LIST now read the SAME metric, so the
// two can never diverge: cost 2 000 / price 4 000 is 100% in both places.
// The only remaining profit-as-a-percentage-of-revenue figure in the app
// is the Financial report's net-margin KPI, which is covered by
// `reports_csv_test.dart` / `reports_screen_test.dart`.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/products/models.dart';
import 'package:supermarket_pos/features/products/product_form_dialog.dart';
import 'package:supermarket_pos/features/products/products_screen.dart';

(String?, String?) _form(String price, String cost) =>
    productFormProfitMarkup(price, cost);

(String?, String?) _table(String price, String cost) => productProfitMarkup(
      ProductModel(id: 'p1', name: 'Item', price: price, cost: cost),
    );

String? _tableMarkup(String price, String cost) => _table(price, cost).$2;

void main() {
  group('productFormProfitMarkup — markup on cost', () {
    test('cost 2 000 / price 4 000 → profit 2 000, markup 100%', () {
      expect(_form('4000', '2000'), ('2000.000', '100.00%'));
    });

    test('cost 2 000 / price 3 000 → profit 1 000, markup 50%', () {
      expect(_form('3000', '2000'), ('1000.000', '50.00%'));
    });

    test('cost 2 000 / price 2 500 → profit 500, markup 25%', () {
      expect(_form('2500', '2000'), ('500.000', '25.00%'));
    });

    test('decimal cost keeps thousandths precision and truncates to 2dp', () {
      // 500.000 / 1 999.500 = 25.0062…% → 25.00% (integer hundredths).
      expect(_form('2499.5', '1999.5'), ('500.000', '25.00%'));
      // 0.500 / 2 000 = 0.025% → truncated to 0.02%, never rounded up.
      expect(_form('2000.5', '2000'), ('0.500', '0.02%'));
    });

    test('space-grouped display input parses identically', () {
      expect(_form('4 000', '2 000'), ('2000.000', '100.00%'));
    });

    test('a zero cost never divides by zero', () {
      expect(_form('4000', '0'), ('4000.000', null));
      expect(_form('0', '0'), ('0.000', null));
    });

    test('an unparsable or empty cost yields no figures at all', () {
      expect(_form('4000', ''), (null, null));
      expect(_form('4000', 'abc'), (null, null));
      expect(_form('', '2000'), (null, null));
      expect(_form('abc', '2000'), (null, null));
      // moneyToMilli rejects negatives and >3 decimals instead of
      // rounding client-side.
      expect(_form('4000', '-1'), (null, null));
      expect(_form('4000', '2000.1234'), (null, null));
    });

    test('selling below cost reports a negative profit and markup', () {
      expect(_form('2000', '3000'), ('-1000.000', '-33.33%'));
      expect(_form('0', '1000'), ('-1000.000', '-100.00%'));
    });
  });

  group('product list — the same markup-on-cost metric as the form', () {
    test('cost 2 000 / price 4 000 → list shows 100.00%, not a 50% margin',
        () {
      expect(_form('4000', '2000').$2, '100.00%');
      expect(_tableMarkup('4000', '2000'), '100.00%');
      // The margin-on-price figure must never leak back into the list.
      expect(_tableMarkup('4000', '2000'), isNot('50.00%'));
    });

    test('cost 2 000 / price 3 000 → list shows 50.00% (was 33.33%)', () {
      expect(_form('3000', '2000').$2, '50.00%');
      expect(_tableMarkup('3000', '2000'), '50.00%');
      expect(_tableMarkup('3000', '2000'), isNot('33.33%'));
    });

    test('cost 2 000 / price 2 500 → list shows 25.00%', () {
      expect(_tableMarkup('2500', '2000'), '25.00%');
    });

    test('a zero cost hides the list percentage (never divide by zero)', () {
      expect(_tableMarkup('4000', '0'), isNull);
      expect(_table('4000', '0').$1, '4000.000'); // absolute profit stands
    });

    test('a zero price is still a defined (negative) markup on cost', () {
      expect(_tableMarkup('0', '2000'), '-100.00%');
      expect(_table('0', '2000'), ('-2000.000', '-100.00%'));
    });

    test('the form profit matches the list profit for the same product', () {
      for (final pair in const [
        ('4000', '2000'),
        ('3000', '2000'),
        ('1000.5', '999.25'),
      ]) {
        final (formProfit, _) = _form(pair.$1, pair.$2);
        final (tableProfit, _) = _table(pair.$1, pair.$2);
        expect(formProfit, tableProfit, reason: 'profit must not diverge');
      }
    });
  });
}
