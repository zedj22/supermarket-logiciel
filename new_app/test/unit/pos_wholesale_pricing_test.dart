// Phase 17 pricing — wholesale re-pricing of a POS cart line.
//
// Dart mirror of `app/domain/wholesale.py`: only a BASE-unit line that
// prices off `products.price` (`retailPrice` set, `unitMultiplier` null) is
// ever eligible, the threshold is compared against that line's own quantity,
// and the configured wholesale price is returned verbatim. A custom selling
// unit (Box = 24 Piece) NEVER goes wholesale — its multiplier converts
// quantity for inventory only. The server still computes the authoritative
// price at checkout — this covers what the cashier SEES.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_quantity.dart';

/// A retail-branch line (retailPrice == unitPrice, the construction
/// invariant `_retailPriceOf` maintains in pos_screen.dart).
CartLine retailLine({
  String quantity = '1',
  String unitPrice = '100',
  String retail = '100',
  String wholesale = '80',
  String min = '5',
  String? unitMultiplier,
  String lineDiscount = '0',
}) =>
    CartLine(
      productId: 'p1',
      name: 'Rice',
      quantity: quantity,
      unitPrice: unitPrice,
      lineDiscount: lineDiscount,
      retailPrice: retail,
      wholesalePrice: wholesale,
      wholesaleMinQty: min,
      unitMultiplier: unitMultiplier,
      availableStock: '999',
    );

PosCartNotifier newNotifier() =>
    PosCartNotifier(Dio(), () => 'en', () async => 'pos-test');

void main() {
  group('priceFor — retail branch', () {
    test('below the threshold keeps the retail price', () {
      expect(retailLine(quantity: '4').priceFor('4'), '100');
      expect(retailLine(quantity: '4.999').priceFor('4.999'), '100');
    });

    test('the threshold itself is inclusive', () {
      expect(retailLine(quantity: '5').priceFor('5'), '80');
    });

    test('above the threshold takes the wholesale price', () {
      expect(retailLine(quantity: '6').priceFor('6'), '80');
      expect(retailLine(quantity: '100.5').priceFor('100.5'), '80');
    });

    test('wholesale price is returned VERBATIM (never x multiplier)', () {
      // Base unit: the threshold quantity IS the line quantity.
      final piece = retailLine(
        quantity: '5',
        unitPrice: '80.000',
        retail: '100.000',
        wholesale: '80.000',
      );
      expect(piece.priceFor('5'), '80.000');

      // A Box line keeps ITS price verbatim — no wholesale to return.
      final box = retailLine(
        unitPrice: '2400.000',
        retail: '100.000',
        wholesale: '80.000',
        unitMultiplier: '24',
      );
      expect(box.priceFor('10'), '2400.000');
    });

    test('fractional quantities compare exactly (scaled integers)', () {
      // Base unit: the line quantity is the threshold quantity, decimals
      // included (0.2 < 2.499 < 2.5 <= 2.501 — 3-decimal POS scale).
      expect(retailLine(min: '2.5').priceFor('0.2'), '100');
      expect(retailLine(min: '2.5').priceFor('2.499'), '100');
      expect(retailLine(min: '2.5').priceFor('2.5'), '80');
      expect(retailLine(min: '2.5').priceFor('2.501'), '80');
    });
  });

  group('priceFor — base unit, retail 200 / wholesale 180 from 5', () {
    CartLine pieceLine({String quantity = '1'}) => CartLine(
          productId: 'p1',
          name: 'Rice',
          quantity: quantity,
          unitPrice: '200',
          retailPrice: '200',
          wholesalePrice: '180',
          wholesaleMinQty: '5',
          availableStock: '999',
        );

    double total(String qty) => pieceLine(quantity: qty)
        .copyWith(quantity: qty)
        .lineTotal;

    test('1 / 4 Piece keep retail 200 (totals 200 / 800)', () {
      expect(pieceLine(quantity: '1').priceFor('1'), '200');
      expect(pieceLine(quantity: '4').priceFor('4'), '200');
      expect(total('1'), 200.0);
      expect(total('4'), 800.0);
    });

    test('5 / 10 Piece take wholesale 180 (totals 900 / 1800)', () {
      expect(pieceLine(quantity: '5').priceFor('5'), '180');
      expect(pieceLine(quantity: '10').priceFor('10'), '180');
      expect(total('5'), 900.0);
      expect(total('10'), 1800.0);
      expect(pieceLine(quantity: '5').copyWith(quantity: '5').wholesaleApplied,
          isTrue);
    });
  });

  group('priceFor — custom selling units never go wholesale', () {
    // Retail 200, wholesale 180 from 5 Piece, Box = 24 Piece.
    CartLine boxLine({String quantity = '1'}) => CartLine(
          productId: 'p1',
          name: 'Rice',
          sellingUnitId: 'box-1',
          unitName: 'Box',
          quantity: quantity,
          unitPrice: '200',
          retailPrice: '200',
          wholesalePrice: '180',
          wholesaleMinQty: '5',
          unitMultiplier: '24',
          availableStock: '999',
        );

    double total(String qty) =>
        boxLine(quantity: qty).copyWith(quantity: qty).lineTotal;

    test('the multiplier never qualifies a Box line for wholesale', () {
      final oneBox = boxLine(quantity: '1');
      expect(oneBox.wholesaleEligible, isFalse);
      expect(oneBox.priceFor('1'), '200');
      expect(oneBox.wholesaleApplied, isFalse);

      // 5 Box = 120 base units and 10 Box = 240 — both far past the
      // threshold of 5, and both still charge retail 200.
      expect(boxLine(quantity: '5').priceFor('5'), '200');
      expect(boxLine(quantity: '10').priceFor('10'), '200');
      expect(boxLine(quantity: '10').wholesaleEligible, isFalse);
    });

    test('Box totals stay retail while the base quantity still converts', () {
      for (final (qty, expectedTotal, expectedBase) in [
        (1, 200.0, 24.0),
        (5, 1000.0, 120.0),
        (10, 2000.0, 240.0),
      ]) {
        final line = boxLine(quantity: '$qty');
        expect(total('$qty'), expectedTotal, reason: '$qty Box total');
        // Inventory conversion only — never a price multiplier.
        expect(
          double.parse(line.quantity) * double.parse(line.unitMultiplier!),
          expectedBase,
          reason: '$qty Box base quantity',
        );
        expect(line.wholesaleApplied, isFalse);
      }
    });

    test('a quantity edit on a Box line never re-prices it', () {
      final line = boxLine(quantity: '1');
      final edited = line.copyWith(quantity: '10');
      expect(edited.unitPrice, '200');
      expect(edited.wholesaleApplied, isFalse);
      expect(edited.lineTotal, 2000.0);
    });

    test('a legacy snapshot stamp cannot re-enable wholesale', () {
      // A hold saved before this rule still carries retailPrice + multiplier;
      // the multiplier alone must keep the line off the wholesale branch.
      final legacy = boxLine(quantity: '5');
      expect(legacy.retailPrice, '200');
      expect(legacy.wholesaleEligible, isFalse);
      expect(legacy.copyWith(quantity: '10').unitPrice, '200');
    });
  });

  group('priceFor — lines wholesale must never touch', () {
    test('an explicit variant / selling-unit price keeps its price', () {
      const line = CartLine(
        productId: 'p1',
        name: 'Rice',
        quantity: '1',
        unitPrice: '550',
        wholesalePrice: '80',
        wholesaleMinQty: '5',
        unitMultiplier: '24',
        availableStock: '999',
      );
      expect(line.retailPrice, isNull);
      expect(line.wholesaleEligible, isFalse);
      expect(line.priceFor('999'), '550');
      expect(line.copyWith(quantity: '999').unitPrice, '550');
    });

    test('a pack line keeps its price', () {
      const pack = CartLine(
        packId: 'pack-1',
        name: 'Family Pack',
        quantity: '1',
        unitPrice: '500',
        availableStock: '999',
      );
      expect(pack.wholesaleEligible, isFalse);
      expect(pack.copyWith(quantity: '40').unitPrice, '500');
    });
  });

  group('priceFor — disabled wholesale is never an error', () {
    test('missing wholesale price keeps retail', () {
      expect(retailLine(wholesale: '').priceFor('50'), '100');
      final noPrice = CartLine(
        productId: 'p1',
        name: 'Rice',
        unitPrice: '100',
        retailPrice: '100',
        wholesaleMinQty: '5',
        availableStock: '999',
      );
      expect(noPrice.wholesaleEligible, isFalse);
      expect(noPrice.priceFor('50'), '100');
    });

    test('missing / zero / negative minimum keeps retail', () {
      expect(retailLine(min: '').priceFor('50'), '100');
      expect(retailLine(min: '0').priceFor('50'), '100');
      expect(retailLine(min: '-3').priceFor('50'), '100');
      expect(retailLine(min: 'abc').priceFor('50'), '100');
    });

    test('negative or malformed wholesale price keeps retail', () {
      expect(retailLine(wholesale: '-5').priceFor('50'), '100');
      expect(retailLine(wholesale: 'abc').priceFor('50'), '100');
    });

    test('unparsable quantity keeps retail', () {
      expect(retailLine().priceFor('abc'), '100');
      expect(retailLine().priceFor(''), '100');
    });
  });

  group('copyWith — the single re-pricing path', () {
    test('raising the quantity across the threshold applies wholesale', () {
      final line = retailLine(quantity: '1');
      final crossed = line.copyWith(quantity: '5');
      expect(crossed.unitPrice, '80');
      expect(crossed.quantity, '5');
      expect(crossed.wholesaleApplied, isTrue);
    });

    test('dropping back below the threshold returns to retail', () {
      final line = retailLine(quantity: '1').copyWith(quantity: '6');
      expect(line.unitPrice, '80');
      final dropped = line.copyWith(quantity: '2');
      expect(dropped.unitPrice, '100');
      expect(dropped.wholesaleApplied, isFalse);
    });

    test('a quantity edit keeps the line discount', () {
      final line = retailLine(lineDiscount: '10').copyWith(quantity: '5');
      expect(line.lineDiscount, '10');
      expect(line.unitPrice, '80');
    });

    test('an explicit unitPrice argument still wins', () {
      final line = retailLine().copyWith(quantity: '5', unitPrice: '90');
      expect(line.unitPrice, '90');
    });

    test('editing only the discount never re-prices the line', () {
      final line = retailLine(quantity: '9').copyWith(lineDiscount: '10');
      expect(line.unitPrice, '100');
      expect(line.lineDiscount, '10');
    });
  });

  group('wholesaleEligible / wholesaleApplied', () {
    test('eligible = retail branch + both halves + minimum > 0', () {
      expect(retailLine().wholesaleEligible, isTrue);
      expect(retailLine(min: '0').wholesaleEligible, isFalse);
      expect(retailLine(wholesale: '-1').wholesaleEligible, isFalse);
      expect(
        const CartLine(productId: 'p1', name: 'x', unitPrice: '10')
            .wholesaleEligible,
        isFalse,
      );
    });

    test('applied only while the line is cheaper than retail', () {
      final atWholesale = retailLine(quantity: '5', unitPrice: '80');
      expect(atWholesale.wholesaleApplied, isTrue);

      final atRetail = retailLine(quantity: '1', unitPrice: '100');
      expect(atRetail.wholesaleApplied, isFalse);

      // A wholesale rule equal to retail changes nothing → no cue.
      final noop = retailLine(
        wholesale: '100',
        retail: '100',
        unitPrice: '100',
      );
      expect(noop.wholesaleEligible, isTrue);
      expect(noop.wholesaleApplied, isFalse);
    });
  });

  group('hold snapshot round trip', () {
    test('toJson carries the wholesale snapshot', () {
      final json = retailLine().toJson();
      expect(json['retail_price'], '100');
      expect(json['wholesale_price'], '80');
      expect(json['wholesale_min_qty'], '5');
    });

    test('toJson keeps explicit nulls for lines wholesale never touches', () {
      final json = const CartLine(productId: 'p1', name: 'x').toJson();
      expect(json.containsKey('retail_price'), isTrue);
      expect(json['retail_price'], isNull);
      expect(json['wholesale_price'], isNull);
      expect(json['wholesale_min_qty'], isNull);
    });

    test('a restored line still re-prices on the next quantity edit', () {
      final saved = retailLine(quantity: '5', unitPrice: '80');
      final restored = CartLine.fromJson(saved.toJson());
      expect(restored.retailPrice, '100');
      expect(restored.wholesalePrice, '80');
      expect(restored.wholesaleMinQty, '5');
      expect(restored.unitPrice, '80');
      // Crossing back down must return to retail after a restore, and
      // crossing up again must return to wholesale.
      expect(restored.copyWith(quantity: '1').unitPrice, '100');
      expect(restored.copyWith(quantity: '5').unitPrice, '80');
    });

    test('toSaleJson stays on the sale API contract', () {
      final sale = retailLine(quantity: '5', unitPrice: '80').toSaleJson();
      expect(sale.containsKey('retail_price'), isFalse);
      expect(sale.containsKey('wholesale_price'), isFalse);
      expect(sale.containsKey('wholesale_min_qty'), isFalse);
      expect(sale['unit_price'], '80');
    });
  });

  group('cart notifier — real quantity flows', () {
    test('updateLine re-prices when the quantity crosses the threshold', () {
      final notifier = newNotifier();
      notifier.addLine(retailLine(quantity: '1'));
      final key = notifier.state.lines.single.key;

      notifier.updateLine(key, quantity: '5');
      expect(notifier.state.lines.single.unitPrice, '80');

      notifier.updateLine(key, quantity: '2');
      expect(notifier.state.lines.single.unitPrice, '100');
    });

    test('merging a second scan into the line crosses the threshold', () {
      final notifier = newNotifier();
      notifier.addLine(retailLine(quantity: '3'));
      notifier.addLine(retailLine(quantity: '3'));
      final merged = notifier.state.lines.single;
      expect(merged.quantity, '6.0');
      expect(merged.unitPrice, '80');
    });

    test('a first add typed at/above the threshold starts at wholesale', () {
      final notifier = newNotifier();
      final applied = applyAddingLine(
        notifier: notifier,
        cart: notifier.state,
        newLine: retailLine(quantity: '1'),
        rawInput: '6',
        loc: 'en',
      );
      expect(applied, isTrue);
      expect(notifier.state.lines.single.unitPrice, '80');
    });

    test('an explicit-price line never re-prices in the cart', () {
      const explicit = CartLine(
        productId: 'p1',
        name: 'Rice',
        quantity: '1',
        unitPrice: '550',
        availableStock: '999',
      );
      final notifier = newNotifier();
      notifier.addLine(explicit);
      final key = notifier.state.lines.single.key;
      notifier.updateLine(key, quantity: '50');
      expect(notifier.state.lines.single.unitPrice, '550');
    });
  });
}
