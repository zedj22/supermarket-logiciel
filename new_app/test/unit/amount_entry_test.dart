// Weight/length AMOUNT-entry math — exact scaled (×1000) conversions.
//
// Guards the Klick POS amount-entry contract:
// - amount → quantity is an EXACT HALF-UP division (no binary floats);
// - quantity → actual money is recomputed from the ROUNDED quantity —
//   the actual charge is never the raw requested amount;
// - unusable operands (amount ≤ 0, price ≤ 0) return null, never a
//   silent 0;
// - the weight/length vocabulary is exactly {kg, gram, meter}, matched
//   on `unit_type` codes — never translated labels.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/amount_entry.dart';
import 'package:supermarket_pos/core/quantity_expression.dart';

void main() {
  group('isAmountEntryUnit', () {
    test('weight and length codes are true (case-insensitive)', () {
      expect(isAmountEntryUnit('kg'), isTrue);
      expect(isAmountEntryUnit('KG'), isTrue);
      expect(isAmountEntryUnit('kg '.trim()), isTrue);
      expect(isAmountEntryUnit('gram'), isTrue);
      expect(isAmountEntryUnit('Gram'), isTrue);
      expect(isAmountEntryUnit('meter'), isTrue);
      expect(isAmountEntryUnit('METER'), isTrue);
    });

    test('count and volume units are false', () {
      expect(isAmountEntryUnit('piece'), isFalse);
      expect(isAmountEntryUnit('box'), isFalse);
      expect(isAmountEntryUnit('pack'), isFalse);
      expect(isAmountEntryUnit('liter'), isFalse);
      expect(isAmountEntryUnit('milliliter'), isFalse);
    });

    test('unknown / empty / null are false', () {
      expect(isAmountEntryUnit('cm'), isFalse); // not in the vocabulary
      expect(isAmountEntryUnit(''), isFalse);
      expect(isAmountEntryUnit(null), isFalse);
    });
  });

  group('amountToQuantityScaled', () {
    test('exact division — 100 DA at 250 → 0.400', () {
      expect(
        amountToQuantityScaled(amountScaled: 100000, priceScaled: 250000),
        400,
      );
    });

    test('HALF-UP to 3 decimals — 100 DA at 300 → 0.333', () {
      expect(
        amountToQuantityScaled(amountScaled: 100000, priceScaled: 300000),
        333,
      );
    });

    test('HALF-UP rounds UP on the exact .5 tie', () {
      // 0.001 ÷ 0.016 = 0.0625 → 0.063 (half-up, not banker's).
      expect(
        amountToQuantityScaled(amountScaled: 1, priceScaled: 16),
        63,
      );
    });

    test('whole units — 250 DA at 250 → 1.000', () {
      expect(
        amountToQuantityScaled(amountScaled: 250000, priceScaled: 250000),
        1000,
      );
    });

    test('below one representable unit → 0 (caller rejects)', () {
      // 1 centime at 1000 DA → 0.0001 → rounds to 0 at 3 decimals.
      expect(
        amountToQuantityScaled(amountScaled: 1, priceScaled: 1000000),
        0,
      );
    });

    test('unusable operands return null — never a silent 0', () {
      expect(
        amountToQuantityScaled(amountScaled: 0, priceScaled: 250000),
        isNull,
      );
      expect(
        amountToQuantityScaled(amountScaled: -5000, priceScaled: 250000),
        isNull,
      );
      expect(
        amountToQuantityScaled(amountScaled: 100000, priceScaled: 0),
        isNull,
      );
      expect(
        amountToQuantityScaled(amountScaled: 100000, priceScaled: -1),
        isNull,
      );
    });
  });

  group('quantityToAmountScaled', () {
    test('exact — 0.400 × 250 → 100.000', () {
      expect(
        quantityToAmountScaled(quantityScaled: 400, priceScaled: 250000),
        100000,
      );
    });

    test('recomputed from the ROUNDED quantity — 0.333 × 300 → 99.900', () {
      // The requested 100.000 becomes 99.900 — the cashier must see this
      // actual total before confirming, never a silent 100.
      expect(
        quantityToAmountScaled(quantityScaled: 333, priceScaled: 300000),
        99900,
      );
    });

    test('HALF-UP on money — 0.063 × 0.016 → 0.001', () {
      // 0.063 × 0.016 = 0.001008 → 0.001 at the 3-decimal money domain.
      expect(
        quantityToAmountScaled(quantityScaled: 63, priceScaled: 16),
        1,
      );
    });

    test('unusable operands return null', () {
      expect(
        quantityToAmountScaled(quantityScaled: 0, priceScaled: 250000),
        isNull,
      );
      expect(
        quantityToAmountScaled(quantityScaled: -400, priceScaled: 250000),
        isNull,
      );
      expect(
        quantityToAmountScaled(quantityScaled: 400, priceScaled: 0),
        isNull,
      );
    });
  });

  group('round-trip consistency with the POS quantity domain', () {
    test('computed quantity text feeds posScaled/posScaledText unchanged', () {
      final qtyScaled = amountToQuantityScaled(
        amountScaled: 100000, // 100
        priceScaled: 250000, // 250
      )!;
      final text = posScaledText(qtyScaled);
      expect(text, '0.4');
      expect(posScaled(text), qtyScaled);
    });

    test('actual ≤ requested when rounding down; actual ≠ requested '
        'when half-up rounds up', () {
      final down = amountToQuantityScaled(
        amountScaled: 100000,
        priceScaled: 300000,
      )!;
      expect(
        quantityToAmountScaled(
              quantityScaled: down,
              priceScaled: 300000,
            )! <
            100000,
        isTrue,
      );
      // 0.001 DA at 2.000 → quotient 0.0005 HALF-UP → 0.001 → actual 0.002
      // — the requested amount is NOT the charge; the dialog must show it.
      final up = amountToQuantityScaled(
        amountScaled: 1,
        priceScaled: 2000,
      )!;
      expect(up, 1);
      expect(
        quantityToAmountScaled(quantityScaled: up, priceScaled: 2000)! > 1,
        isTrue,
      );
    });
  });
}
