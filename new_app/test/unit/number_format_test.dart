// Shared thousands-separator formatting (space grouping).
//
// Presentation-only contract:
// - integer digits group in sets of three from the right, separated by a
//   regular space,
// - sign, decimal separator and decimal digits are preserved verbatim,
// - non-plain numbers (identifiers, barcodes, dates, already-grouped text)
//   pass through unchanged,
// - parsing helpers accept grouped input without changing the value.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/number_format.dart';
import 'package:supermarket_pos/features/clients/customer_models.dart';
import 'package:supermarket_pos/features/facturation/facturation_format.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/stock/stock_screen.dart'
    show formatSignedQuantityChange;

void main() {
  group('formatGrouped', () {
    test('groups required spec examples', () {
      expect(formatGrouped('1000'), '1 000');
      expect(formatGrouped('1000000'), '1 000 000');
      expect(formatGrouped('218095577.85'), '218 095 577.85');
      expect(formatGrouped('5452389.446'), '5 452 389.446');
      expect(formatGrouped('4000000.00'), '4 000 000.00');
      expect(formatGrouped('-1234567.89'), '-1 234 567.89');
    });

    test('zero and small numbers need no grouping', () {
      expect(formatGrouped('0'), '0');
      expect(formatGrouped('0.00'), '0.00');
      expect(formatGrouped('7'), '7');
      expect(formatGrouped('999'), '999');
      expect(formatGrouped('999.999'), '999.999');
      expect(formatGrouped('-5'), '-5');
    });

    test('boundary values group exactly at 1000', () {
      expect(formatGrouped('1000'), '1 000');
      expect(formatGrouped('9999'), '9 999');
      expect(formatGrouped('10000'), '10 000');
      expect(formatGrouped('100000'), '100 000');
      expect(formatGrouped('1000000'), '1 000 000');
      expect(formatGrouped('1000000000'), '1 000 000 000');
    });

    test('decimal precision is preserved verbatim', () {
      expect(formatGrouped('1000.5'), '1 000.5');
      expect(formatGrouped('1000.50'), '1 000.50');
      expect(formatGrouped('1000.005'), '1 000.005');
      expect(formatGrouped('1234567.891'), '1 234 567.891');
      expect(formatGrouped('-1000'), '-1 000');
    });

    test('trims surrounding whitespace only', () {
      expect(formatGrouped('  1500  '), '1 500');
      expect(formatGrouped(''), '');
    });

    test('passes through non-plain numbers untouched', () {
      // Identifiers, dates and already-grouped text must never change.
      expect(formatGrouped('FAC-2026-0001'), 'FAC-2026-0001');
      expect(formatGrouped('INV-20261004-142659-926-0082'),
          'INV-20261004-142659-926-0082');
      expect(formatGrouped('2026-10-16'), '2026-10-16');
      expect(formatGrouped('1 500'), '1 500'); // already grouped → unchanged
      expect(formatGrouped('1,500'), '1,500'); // commas are never introduced
      expect(formatGrouped('12.34.56'), '12.34.56');
      expect(formatGrouped('abc'), 'abc');
      expect(formatGrouped('12a'), '12a');
      expect(formatGrouped('1e6'), '1e6');
      expect(formatGrouped('+1500'), '+1500');
    });

    test('is locale-independent (regular space in ar / fr / en)', () {
      for (final loc in ['ar', 'fr', 'en']) {
        expect(formatGrouped('218095577.85'), '218 095 577.85',
            reason: 'locale $loc');
      }
    });
  });

  group('formatGroupedFixed', () {
    test('formats doubles with fixed decimals + grouping', () {
      expect(formatGroupedFixed(4000000.0, 2), '4 000 000.00');
      expect(formatGroupedFixed(218095577.85, 2), '218 095 577.85');
      expect(formatGroupedFixed(1234.5, 2), '1 234.50');
      expect(formatGroupedFixed(0, 2), '0.00');
      expect(formatGroupedFixed(-1234567.89, 2), '-1 234 567.89');
    });
  });

  group('stripGrouping', () {
    test('restores the plain decimal string', () {
      expect(stripGrouping('218 095 577.85'), '218095577.85');
      expect(stripGrouping('1 000'), '1000');
      expect(stripGrouping('-1 234 567.89'), '-1234567.89');
      expect(stripGrouping('0.00'), '0.00');
      expect(stripGrouping('1500'), '1500'); // no-op on plain input
    });

    test('round-trips with formatGrouped', () {
      for (final raw in [
        '1000',
        '1000000',
        '218095577.85',
        '5452389.446',
        '4000000.00',
        '-1234567.89',
        '0',
      ]) {
        expect(stripGrouping(formatGrouped(raw)), raw);
      }
    });
  });

  group('formatMoney (display: trim + group)', () {
    test('keeps the existing small-value contract', () {
      expect(formatMoney('300.000'), '300');
      expect(formatMoney('120.500'), '120.5');
      expect(formatMoney('0.000'), '0');
      expect(formatMoney('120.050'), '120.05');
      expect(formatMoney('100'), '100');
      expect(formatMoney('0.001'), '0.001');
    });

    test('groups large values after the trailing-zero trim', () {
      expect(formatMoney('1500.000'), '1 500');
      expect(formatMoney('4500.000'), '4 500');
      expect(formatMoney('218095577.85'), '218 095 577.85');
      expect(formatMoney('4000000.00'), '4 000 000');
      expect(formatMoney('1000000'), '1 000 000');
    });
  });

  group('formatMoneyPlain (parse-safe: trim only)', () {
    test('never introduces a space', () {
      expect(formatMoneyPlain('1500.000'), '1500');
      expect(formatMoneyPlain('300.000'), '300');
      expect(formatMoneyPlain('120.500'), '120.5');
      expect(formatMoneyPlain('1000'), '1000');
      expect(formatMoneyPlain(''), '');
    });
  });

  group('moneyToMilli accepts grouped display values', () {
    test('grouped and plain parse to the same milli value', () {
      expect(moneyToMilli('1500'), 1500000);
      expect(moneyToMilli('1 500'), 1500000);
      expect(moneyToMilli('1 500.250'), 1500250);
      expect(moneyToMilli('218 095 577.85'), 218095577850);
      expect(moneyToMilli('218 095 577.850'), 218095577850);
      expect(moneyToMilli('218 095 577.8512'), null); // >3 decimals rejected
      expect(moneyToMilli(' 1 000 '), 1000000);
    });

    test('existing rejections still hold', () {
      expect(moneyToMilli('1,'), isNull);
      expect(moneyToMilli('1.2345'), isNull);
      expect(moneyToMilli('-5'), isNull);
      expect(moneyToMilli('NaN'), isNull);
      expect(moneyToMilli(''), isNull);
      expect(moneyToMilli('1 500 000.1234'), isNull);
    });

    test('formatMoneyPlain output is always re-parsable', () {
      for (final raw in ['1500.000', '0.001', '999.999', '12345.678']) {
        final plain = formatMoneyPlain(raw);
        expect(moneyToMilli(plain), moneyToMilli(raw), reason: raw);
      }
    });
  });

  group('PaymentMath', () {
    test('money() groups doubles with 2 decimals', () {
      expect(PaymentMath.money(4000000), '4 000 000.00');
      expect(PaymentMath.money(1500.5), '1 500.50');
      expect(PaymentMath.money(0), '0.00');
      expect(PaymentMath.money(-1234.5), '-1 234.50');
    });

    test('parse() accepts plain and grouped text identically', () {
      expect(PaymentMath.parse('1500'), 1500);
      expect(PaymentMath.parse('1 500'), 1500);
      expect(PaymentMath.parse('1500.25'), 1500.25);
      expect(PaymentMath.parse(''), 0);
      expect(PaymentMath.parse('abc'), 0);
    });

    test('money → parse round-trips the value', () {
      for (final v in [0.0, 7.0, 999.99, 1000.0, 1500.5, 218095577.85]) {
        expect(PaymentMath.parse(PaymentMath.money(v)), closeTo(v, 0.005),
            reason: '$v');
      }
    });
  });

  group('CartTotals display', () {
    test('subtotal / total / discount are grouped', () {
      const totals = CartTotals(
        subtotal: 1500000,
        invoiceDiscount: 1234.5,
        total: 1498765.5,
        lineCount: 3,
      );
      expect(totals.subtotalDisplay, '1 500 000.00');
      expect(totals.invoiceDiscountDisplay, '1 234.50');
      expect(totals.totalDisplay, '1 498 765.50');
    });
  });

  group('formatDisplayMoney (facturation)', () {
    test('groups behind the DA suffix in every locale', () {
      expect(formatDisplayMoney('1500.000', 'en'), '1 500 DA');
      expect(formatDisplayMoney('1500.000', 'fr'), '1 500 DA');
      expect(formatDisplayMoney('1500.000', 'ar'), '1 500 DA');
      expect(formatDisplayMoney('24.800', 'en'), '24.8 DA');
      expect(formatDisplayMoney('0', 'en'), '0 DA');
      // Idempotent guard: an already-suffixed string passes through.
      expect(formatDisplayMoney('1 500 DA', 'en'), '1 500 DA');
    });
  });

  group('formatSignedQuantityChange', () {
    test('groups magnitudes and keeps the sign convention', () {
      expect(formatSignedQuantityChange('5.000'), '+5.000');
      expect(formatSignedQuantityChange('1500'), '+1 500');
      expect(formatSignedQuantityChange('1500.250'), '+1 500.250');
      expect(formatSignedQuantityChange('+1500'), '+1 500');
      expect(formatSignedQuantityChange('-2000'), '-2 000');
      expect(formatSignedQuantityChange('0'), '0');
      expect(formatSignedQuantityChange('abc'), 'abc');
    });
  });
}
