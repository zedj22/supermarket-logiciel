// UX FIX #12 (FIX #3 / #4 / #6) — shared quantity rules.
//
// One parser, one stock guard, exact scaled arithmetic for every path
// that mutates a cart quantity.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_quantity.dart';

CartLine line({
  String productId = 'p1',
  String? variantId,
  String? sellingUnitId,
  String quantity = '1',
  String? availableStock = '10',
  String? unitMultiplier,
}) {
  return CartLine(
    productId: productId,
    variantId: variantId,
    sellingUnitId: sellingUnitId,
    name: 'Rice',
    quantity: quantity,
    availableStock: availableStock,
    unitMultiplier: unitMultiplier,
  );
}

PosCartState cart(List<CartLine> lines) => PosCartState(lines: lines);

void main() {
  group('A. quantity expression parsing (exact)', () {
    test('plain numbers keep the typed text', () {
      expect(parseQuantityExpression('10').value, 10);
      expect(parseQuantityExpression('10').text, '10');
      expect(parseQuantityExpression('2.5').text, '2.5');
      expect(parseQuantityExpression('0.500').text, '0.500');
      expect(parseQuantityExpression('  7  ').text, '7');
    });

    test('10*24 → 240 exactly', () {
      final result = parseQuantityExpression('10*24');
      expect(result.status, PosQuantityStatus.valid);
      expect(result.value, 240);
      expect(result.scaled, 240 * kPosQtyScale);
      expect(result.text, '240');
    });

    test('whitespace around operands is accepted', () {
      expect(parseQuantityExpression('10 * 24').value, 240);
      expect(parseQuantityExpression(' 10* 24 ').value, 240);
    });

    test('fractional operands round half up on the 3-decimal domain', () {
      // 1.5 * 1.5 = 2.25 → 2.250 (representable), 0.001*0.001 → 0 (rej.)
      expect(parseQuantityExpression('1.5*1.5').text, '2.25');
      expect(parseQuantityExpression('2.5*4').text, '10');
      expect(parseQuantityExpression('0.005*2').text, '0.01');
    });

    test('expressions never lose precision to binary floats', () {
      // 0.1 + 0.2 style bugs must not appear: 0.1*3 → 0.3 exactly.
      expect(parseQuantityExpression('0.1*3').text, '0.3');
      expect(posQuantityAdd('0.1', 0.2), '0.3');
      expect(posQuantityAdd('2.7', 1), '3.7');
      expect(posQuantityAdd('2.7', 1), isNot('3.6999999999999996'));
    });
  });

  group('B. rejected expressions', () {
    for (final raw in [
      '*',
      '10*',
      '*24',
      '10**24',
      '10*0',
      '0*10',
      '0',
      '00',
      '-2',
      '10*-4',
      'abc',
      '1,5',
      '1.5.5',
      '+5',
      '1e3',
      '',
      '   ',
    ]) {
      test('"$raw" is rejected', () {
        expect(parseQuantityExpression(raw).isValid, isFalse,
            reason: '"$raw" must not parse');
      });
    }

    test('zero / negative / malformed share one localized message', () {
      const loc = 'en';
      final invalid = AppStrings.t('invalid_quantity_expression', loc);
      expect(parseQuantityExpression('*').errorMessage(loc), invalid);
      expect(parseQuantityExpression('0').errorMessage(loc), invalid);
      expect(parseQuantityExpression('-2').errorMessage(loc), invalid);
      expect(parseQuantityExpression('').errorMessage(loc), invalid);
      expect(invalid, isNotEmpty);
    });

    test('over the maximum has its own message', () {
      final result = parseQuantityExpression('1000000');
      expect(result.status, PosQuantityStatus.tooLarge);
      expect(
        result.errorMessage('en'),
        AppStrings.t('quantity_too_large', 'en'),
      );
      // Exactly at the clamp stays valid.
      expect(parseQuantityExpression('999999').isValid, isTrue);
    });

    test('validateRequestedQuantity is the same rule (shared)', () {
      expect(validateRequestedQuantity('10*24', 'en'), isNull);
      expect(
        validateRequestedQuantity('10*', 'en'),
        AppStrings.t('invalid_quantity_expression', 'en'),
      );
      expect(validateRequestedQuantity('10*24', 'ar'), isNull);
      expect(
        validateRequestedQuantity('*', 'ar'),
        AppStrings.t('invalid_quantity_expression', 'ar'),
      );
    });
  });

  group('C. scaled helpers', () {
    test('posScaled parses plain decimals only', () {
      expect(posScaled('10'), 10 * kPosQtyScale);
      expect(posScaled('2.5'), 2500);
      expect(posScaled('0.001'), 1);
      expect(posScaled('0.0005'), isNull); // 4+ decimals out of domain
      expect(posScaled('-1'), isNull);
      expect(posScaled('1e3'), isNull);
      expect(posScaled(''), isNull);
      expect(posScaled(null), isNull);
    });

    test('posScaledText round-trips', () {
      expect(posScaledText(240 * kPosQtyScale), '240');
      expect(posScaledText(4500), '4.5');
      expect(posScaledText(48 * kPosQtyScale), '48');
    });

    test('posQuantityAdd clamps to the cart maximum', () {
      expect(
        posQuantityAdd('${kPosQuantityMax.toInt() - 1}', 5),
        '${kPosQuantityMax.toInt()}',
      );
      expect(posQuantityAdd('0', -1), '0');
    });
  });

  group('D. cross-line stock guard (impossible totals rejected)', () {
    test('only lines of the same product count toward its stock', () {
      // Another product with a huge quantity must not block this one.
      final allowed = canApplyQuantityChange(
        cart: cart([
          line(quantity: '7'),
          line(productId: 'p2', quantity: '999'),
        ]),
        prototype: line(quantity: '1'),
        existingKey: null,
        quantity: '3',
        loc: 'en',
      );
      expect(allowed, isNull); // 7 + 3 = 10 ≤ 10

      final blocked = canApplyQuantityChange(
        cart: cart([
          line(productId: 'p1', quantity: '7'),
          line(productId: 'p2', quantity: '999'),
        ]),
        prototype: line(productId: 'p1', quantity: '1'),
        existingKey: null,
        quantity: '5',
        loc: 'en',
      );
      expect(blocked, AppStrings.t('out_of_stock', 'en')); // 7 + 5 > 10
    });

    test('changing a line ignores its own current quantity', () {
      final error = canApplyQuantityChange(
        cart: cart([line(quantity: '10')]),
        prototype: line(quantity: '10'),
        existingKey: 'p1||',
        quantity: '10',
        loc: 'en',
      );
      expect(error, isNull);
    });

    test('selling-unit lines of one product share the stock bucket', () {
      final other = line(
        productId: 'p1',
        sellingUnitId: 'su-1',
        quantity: '2',
        unitMultiplier: '10',
      );
      final error = canApplyQuantityChange(
        cart: cart([other]),
        prototype: line(productId: 'p1', quantity: '1'),
        existingKey: null,
        quantity: '1',
        loc: 'en',
      );
      // 20 base units already committed + 1 > 10 in stock.
      expect(error, AppStrings.t('out_of_stock', 'en'));
    });

    test('different variants of one product do not share the bucket', () {
      final error = canApplyQuantityChange(
        cart: cart([
          line(productId: 'p1', variantId: 'v1', quantity: '10'),
        ]),
        prototype: line(productId: 'p1', variantId: 'v2', quantity: '1'),
        existingKey: null,
        quantity: '10',
        loc: 'en',
      );
      expect(error, isNull);
    });

    test('unknown stock never blocks', () {
      final error = canApplyQuantityChange(
        cart: cart([line(availableStock: null, quantity: '1000')]),
        prototype: line(availableStock: null),
        existingKey: null,
        quantity: '999999',
        loc: 'en',
      );
      expect(error, isNull);
    });

    test('a line already over stock can still be reduced', () {
      final error = canApplyQuantityChange(
        cart: cart([line(availableStock: '5', quantity: '9')]),
        prototype: line(availableStock: '5', quantity: '9'),
        existingKey: 'p1||',
        quantity: '4',
        loc: 'en',
      );
      expect(error, isNull);
      final stillBlocked = canApplyQuantityChange(
        cart: cart([line(availableStock: '5', quantity: '9')]),
        prototype: line(availableStock: '5', quantity: '9'),
        existingKey: 'p1||',
        quantity: '10',
        loc: 'en',
      );
      expect(stillBlocked, AppStrings.t('out_of_stock', 'en'));
    });

    test('impossible quantities are rejected before stock is even read', () {
      expect(
        canApplyQuantityChange(
          cart: cart(const []),
          prototype: line(),
          existingKey: null,
          quantity: '10*',
          loc: 'en',
        ),
        AppStrings.t('invalid_quantity_expression', 'en'),
      );
      expect(
        canApplyQuantityChange(
          cart: cart(const []),
          prototype: line(),
          existingKey: null,
          quantity: '1000000',
          loc: 'en',
        ),
        AppStrings.t('quantity_too_large', 'en'),
      );
    });
  });

  group('E. single-line stock rule (dialogs)', () {
    test('quantity × multiplier ≤ stock', () {
      expect(
        posQtyStockError(
          quantity: '3',
          availableStock: '50',
          unitMultiplier: null,
          loc: 'en',
        ),
        isNull,
      );
      expect(
        posQtyStockError(
          quantity: '6',
          availableStock: '5',
          unitMultiplier: null,
          loc: 'en',
        ),
        AppStrings.t('out_of_stock', 'en'),
      );
      // 5 boxes × 10 = 50 base units — exactly at stock.
      expect(
        posQtyStockError(
          quantity: '5',
          availableStock: '50',
          unitMultiplier: '10',
          loc: 'en',
        ),
        isNull,
      );
      expect(
        posQtyStockError(
          quantity: '5.1',
          availableStock: '50',
          unitMultiplier: '10',
          loc: 'en',
        ),
        AppStrings.t('out_of_stock', 'en'),
      );
    });

    test('unknown stock or unparsable quantity never blocks', () {
      expect(
        posQtyStockError(
          quantity: 'abc',
          availableStock: '10',
          unitMultiplier: null,
          loc: 'en',
        ),
        isNull,
      );
      expect(
        posQtyStockError(
          quantity: '99',
          availableStock: null,
          unitMultiplier: null,
          loc: 'en',
        ),
        isNull,
      );
    });

    test('base quantity of a selling-unit line is exact', () {
      expect(
        posRequestedBaseScaled(quantity: '2', unitMultiplier: '24'),
        48 * kPosQtyScale,
      );
      expect(
        posRequestedBaseScaled(quantity: '2.5', unitMultiplier: '4'),
        10 * kPosQtyScale,
      );
    });
  });

  group('F. shared localization keys', () {
    test('quantity messages exist in ar/fr/en', () {
      for (final locale in ['ar', 'fr', 'en']) {
        expect(
          AppStrings.t('invalid_quantity_expression', locale),
          isNotEmpty,
          reason: 'invalid_quantity_expression@$locale',
        );
        expect(
          AppStrings.t('quantity_too_large', locale),
          isNotEmpty,
          reason: 'quantity_too_large@$locale',
        );
      }
    });
  });
}
