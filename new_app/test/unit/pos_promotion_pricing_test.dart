// Phase 18 promotion pricing — the POS cart line's promotion snapshot.
//
// Dart mirror of `app/domain/promotion.py::promotional_unit_price` +
// `app/services/sale.py::_resolve_line` ordering: a promotion only ever
// discounts a line that prices off `products.price` (retail branch), the
// promotion price is the base BELOW the wholesale threshold (wholesale
// replaces it at/above the threshold), and the promotion cue and the
// wholesale cue are mutually exclusive. The server still computes the
// authoritative price at checkout — this covers what the cashier SEES.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

/// A promoted retail-branch line: retail 100, promotion 80, wholesale 60
/// from 5 — the Phase 17/18 precedence chain in one line.
CartLine promoLine({
  String quantity = '1',
  String unitPrice = '80',
  String retail = '100',
  String promo = '80',
  String? wholesale,
  String? min,
  String? unitMultiplier,
}) =>
    CartLine(
      productId: 'p1',
      name: 'Rice',
      quantity: quantity,
      unitPrice: unitPrice,
      retailPrice: retail,
      promotionPrice: promo,
      wholesalePrice: wholesale,
      wholesaleMinQty: min,
      unitMultiplier: unitMultiplier,
      availableStock: '999',
    );

PosCartNotifier newNotifier() =>
    PosCartNotifier(Dio(), () => 'en', () async => 'pos-test');

void main() {
  group('priceFor — promotion is the base, wholesale may replace it', () {
    test('below the threshold the promotion price wins over retail', () {
      final line = promoLine(quantity: '1', wholesale: '60', min: '5');
      expect(line.priceFor('1'), '80');
      expect(line.priceFor('4'), '80');
    });

    test('at/above the threshold wholesale replaces the promotion price', () {
      final line = promoLine(quantity: '5', wholesale: '60', min: '5');
      expect(line.priceFor('5'), '60');
      expect(line.priceFor('10'), '60');
    });

    test('no wholesale rule → the promotion price is the base', () {
      final line = promoLine(quantity: '50');
      expect(line.priceFor('50'), '80');
      expect(line.retailPrice, '100',
          reason: 'retail snapshot keeps the ORIGINAL price');
    });

    test('a promotion price equal to retail still returns retail', () {
      // Backend clamps fixed_price to retail — the base is unchanged.
      final line = promoLine(unitPrice: '100', promo: '100');
      expect(line.priceFor('3'), '100');
    });
  });

  group('priceFor — lines a promotion must never touch', () {
    test('an explicit selling-unit price keeps its price', () {
      const line = CartLine(
        productId: 'p1',
        name: 'Rice',
        quantity: '1',
        unitPrice: '550',
        promotionPrice: '80',
        availableStock: '999',
      );
      expect(line.retailPrice, isNull,
          reason: 'no retail snapshot → not the retail branch');
      expect(line.priceFor('999'), '550');
    });

    test('a custom selling unit keeps its price (no promo, no wholesale)', () {
      const line = CartLine(
        productId: 'p1',
        name: 'Rice',
        sellingUnitId: 'box-1',
        unitName: 'Box',
        quantity: '1',
        unitPrice: '2400',
        retailPrice: '100',
        promotionPrice: '80',
        unitMultiplier: '24',
        availableStock: '999',
      );
      // priceFor short-circuits on the multiplier — unchanged behavior.
      expect(line.priceFor('10'), '2400');
    });

    test('a pack line keeps its price', () {
      const pack = CartLine(
        packId: 'pack-1',
        name: 'Family Pack',
        quantity: '1',
        unitPrice: '500',
        promotionPrice: '400',
        availableStock: '999',
      );
      expect(pack.priceFor('40'), '500');
    });
  });

  group('promotionApplied / wholesaleApplied cues', () {
    test('promotionApplied while the line charges the promo price', () {
      final line = promoLine(quantity: '1', wholesale: '60', min: '5');
      expect(line.promotionApplied, isTrue);
      expect(line.wholesaleApplied, isFalse);
    });

    test('the cues are mutually exclusive at the wholesale threshold', () {
      final line = promoLine(
        quantity: '5',
        unitPrice: '60',
        wholesale: '60',
        min: '5',
      );
      expect(line.wholesaleApplied, isTrue);
      expect(line.promotionApplied, isFalse,
          reason: 'the line no longer charges the promo price');
    });

    test('wholesaleApplied compares against the PROMOTION base', () {
      // Wholesale equal to the promo price changes nothing → no cue.
      final noop = promoLine(
        unitPrice: '80',
        promo: '80',
        retail: '100',
        wholesale: '80',
        min: '5',
      );
      expect(noop.wholesaleEligible, isTrue);
      expect(noop.wholesaleApplied, isFalse);
      expect(noop.promotionApplied, isTrue);
    });

    test('no promotion snapshot → promotionApplied is false', () {
      const line = CartLine(
        productId: 'p1',
        name: 'Rice',
        quantity: '1',
        unitPrice: '100',
        retailPrice: '100',
        availableStock: '999',
      );
      expect(line.promotionApplied, isFalse);
      expect(line.promotionPrice, isNull);
    });

    test('a promo price at/above retail earns no cue', () {
      final line = promoLine(unitPrice: '100', promo: '100', retail: '100');
      expect(line.promotionApplied, isFalse);
    });
  });

  group('copyWith — the single re-pricing path', () {
    test('a quantity change re-prices retail → promotion → wholesale', () {
      final line = promoLine(quantity: '1', wholesale: '60', min: '5');
      expect(line.copyWith(quantity: '2').unitPrice, '80');
      expect(line.copyWith(quantity: '5').unitPrice, '60');
      final crossed = line.copyWith(quantity: '5');
      expect(crossed.wholesaleApplied, isTrue);
      expect(crossed.promotionApplied, isFalse);
      // Dropping back below the threshold returns to the PROMO price.
      expect(crossed.copyWith(quantity: '1').unitPrice, '80');
    });

    test('an explicit unitPrice argument still wins', () {
      final line = promoLine();
      expect(line.copyWith(quantity: '3', unitPrice: '70').unitPrice, '70');
    });

    test('the promotion snapshot survives every quantity edit', () {
      final line = promoLine(quantity: '1', wholesale: '60', min: '5');
      final edited = line.copyWith(quantity: '9');
      expect(edited.promotionPrice, '80');
      expect(edited.retailPrice, '100');
    });
  });

  group('hold snapshot round trip', () {
    test('toJson carries the promotion snapshot', () {
      final json = promoLine().toJson();
      expect(json['promotion_price'], '80');
      expect(json['retail_price'], '100');
    });

    test('a restored line still re-prices retail → promotion → wholesale', () {
      final saved = promoLine(quantity: '1', wholesale: '60', min: '5');
      final restored = CartLine.fromJson(saved.toJson());
      expect(restored.promotionPrice, '80');
      expect(restored.retailPrice, '100');
      expect(restored.unitPrice, '80');
      expect(restored.copyWith(quantity: '5').unitPrice, '60');
      expect(restored.copyWith(quantity: '1').unitPrice, '80');
    });

    test('toSaleJson stays on the sale API contract', () {
      final sale = promoLine().toSaleJson();
      expect(sale.containsKey('promotion_price'), isFalse);
      expect(sale.containsKey('retail_price'), isFalse);
      expect(sale['unit_price'], '80');
    });
  });

  group('cart notifier — promotion flows', () {
    test('updateLine re-prices promo → wholesale → promo', () {
      final notifier = newNotifier();
      notifier.addLine(promoLine(quantity: '1', wholesale: '60', min: '5'));
      final key = notifier.state.lines.single.key;

      notifier.updateLine(key, quantity: '5');
      expect(notifier.state.lines.single.unitPrice, '60');

      notifier.updateLine(key, quantity: '2');
      expect(notifier.state.lines.single.unitPrice, '80');
    });

    test('merging scans keeps the promotion snapshot', () {
      final notifier = newNotifier();
      notifier.addLine(promoLine(quantity: '3', wholesale: '60', min: '5'));
      notifier.addLine(promoLine(quantity: '3', wholesale: '60', min: '5'));
      final merged = notifier.state.lines.single;
      expect(merged.quantity, '6.0');
      expect(merged.promotionPrice, '80');
      expect(merged.unitPrice, '60');
    });
  });
}
