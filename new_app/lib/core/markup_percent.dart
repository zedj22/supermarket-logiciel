/// Shared markup-on-cost helper — the ONE definition of "profit
/// percentage" used across Klick POS.
///
/// ```
/// markup = ((selling_price - cost_price) / cost_price) * 100
/// ```
///
/// Examples (the contract every screen must honour):
///
/// | cost | price | profit | markup |
/// |------|-------|--------|--------|
/// | 2 000 | 4 000 | 2 000 | 100.00% |
/// | 2 000 | 3 000 | 1 000 |  50.00% |
/// | 2 000 | 2 500 |   500 |  25.00% |
///
/// This is deliberately NOT the gross margin (`profit / price`) the
/// accounting report uses: cost 2 000 / price 4 000 is a 100% markup and
/// a 50% margin. The app-wide user-facing profitability figure is always
/// the markup; margin-on-revenue survives only where it is an accounting
/// metric (the Financial report's net margin KPI).
///
/// Safety rules:
/// * cost `<= 0`, missing, or unparsable → `null` (never divide by zero,
///   never print a percentage that cannot mean anything);
/// * percentages are integer HUNDREDTHS of a percent, truncated — the
///   rounding convention already used by the product form and the
///   products table (40 / 60 → `66.66%`, never rounds up into a lie);
/// * money is parsed with [moneyToMilli] — exact thousandths, never
///   through `double`.
library;

import 'money.dart';

/// [profit / cost × 100] rendered `NN.NN%` — the shared markup-on-cost
/// figure, from integer thousandths.
///
/// `null` whenever the profit or the cost cannot be parsed, or the cost
/// is not strictly positive.
String? markupPercent({required int? profitMilli, required int? costMilli}) {
  if (profitMilli == null || costMilli == null || costMilli <= 0) return null;
  // Hundredths of a percent: 2 000 of cost → 4 000 reads "100.00%".
  final hundredths = (profitMilli * 10000) ~/ costMilli;
  final negative = hundredths < 0;
  final abs = hundredths.abs();
  return '${negative ? '-' : ''}'
      '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}%';
}

/// [profit / cost × 100] rendered `NN.NN%`, from raw money strings
/// (`'80'`, `'240.000'`).
///
/// `null` for empty/invalid money or a non-positive cost.
String? markupPercentRaw({required String? profitRaw, required String? costRaw}) {
  return markupPercent(
    profitMilli: profitRaw == null ? null : moneyToMilli(profitRaw),
    costMilli: costRaw == null ? null : moneyToMilli(costRaw),
  );
}

/// The two figures shown wherever a price and a cost sit side by side:
/// `(profit, markup)`.
///
/// * `profit` = `price - cost` in exact thousandths (`'4000' - '2000'` →
///   `'2000.000'`) — absolute profit, unchanged by this standardisation;
/// * `markup` = [markupPercent] of that profit on the cost.
///
/// Either half is `null` when its input cannot be parsed; `markup` is also
/// `null` when the cost is not strictly positive.
(String?, String?) profitAndMarkupRaw({
  required String? priceRaw,
  required String? costRaw,
}) {
  final priceMilli = priceRaw == null ? null : moneyToMilli(priceRaw);
  final costMilli = costRaw == null ? null : moneyToMilli(costRaw);
  if (priceMilli == null || costMilli == null) return (null, null);
  final profitMilli = priceMilli - costMilli;
  return (
    milliToMoney(profitMilli),
    markupPercent(profitMilli: profitMilli, costMilli: costMilli),
  );
}
