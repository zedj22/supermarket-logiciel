// Method 2 — automatic sell-unit (bundle) pricing.
//
// Product used throughout: 500 DA per piece, sell unit "Box" = 4 pieces at
// 1 900 DA. The required table is
//
//   1→500 2→1000 3→1500 4→1900 5→2400 6→2900
//   7→3400 8→3800 9→4300 10→4800 11→5300 12→5700
//
// These are PURE tests of the pricing core plus the CartLine that carries
// it: the cart total, the persisted sale payload and the invoice all read
// the values asserted here (see the widget group in pos_screen_test.dart
// and backend/tests/unit/test_automatic_sell_unit_pricing.py for the
// end-to-end contract).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/sell_unit_pricing.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';
import 'package:supermarket_pos/features/pos/pos_sell_unit_pricing.dart';
import 'package:supermarket_pos/features/products/models.dart';

const _plan = AutoSellUnitPricing(
  bundleQuantity: '4',
  bundlePrice: '1900',
  unitPrice: '500',
);

/// The table from the specification, as exact strings.
const _expectedTotals = <String, String>{
  '1': '500',
  '2': '1000',
  '3': '1500',
  '4': '1900',
  '5': '2400',
  '6': '2900',
  '7': '3400',
  '8': '3800',
  '9': '4300',
  '10': '4800',
  '11': '5300',
  '12': '5700',
};

/// The matching line discount (regular value − bundle total).
const _expectedDiscounts = <String, String>{
  '1': '0',
  '2': '0',
  '3': '0',
  '4': '100',
  '5': '100',
  '6': '100',
  '7': '100',
  '8': '200',
  '9': '200',
  '10': '200',
  '11': '200',
  '12': '300',
};

SellingUnitModel _unit({
  String id = 'su-box',
  String name = 'Box',
  String multiplier = '4',
  String? sellingPrice = '1900',
  bool isBaseUnit = false,
  bool isArchived = false,
}) =>
    SellingUnitModel(
      id: id,
      productId: 'p1',
      name: name,
      unitType: 'box',
      multiplier: multiplier,
      sellingPrice: sellingPrice,
      effectivePrice: sellingPrice ?? '500',
      isBaseUnit: isBaseUnit,
      isArchived: isArchived,
      availableBaseQty: '20',
      availableSellingQty: '5',
    );

/// An automatic line built exactly the way the POS builds one: at ONE unit
/// (discount 0), then moved to [quantity] through the same copyWith funnel
/// a scan merge, a `+` press or a typed quantity uses.
CartLine _autoLine({String quantity = '1', String unitPrice = '500'}) =>
    CartLine(
      productId: 'p1',
      name: 'Bread',
      quantity: '1',
      unitPrice: unitPrice,
      autoBundleQuantity: '4',
      autoBundlePrice: '1900',
    ).copyWith(quantity: quantity);

void main() {
  group('bundle arithmetic (pure)', () {
    test('bundle count and remainder follow floor/percent semantics', () {
      expect(
        sellUnitBundleCount(quantity: '3', bundleQuantity: '4'),
        0,
      );
      expect(sellUnitRemainder(quantity: '3', bundleQuantity: '4'), 3000);
      expect(sellUnitBundleCount(quantity: '4', bundleQuantity: '4'), 1);
      expect(sellUnitRemainder(quantity: '4', bundleQuantity: '4'), 0);
      expect(sellUnitBundleCount(quantity: '7', bundleQuantity: '4'), 1);
      expect(sellUnitRemainder(quantity: '7', bundleQuantity: '4'), 3000);
      expect(sellUnitBundleCount(quantity: '12', bundleQuantity: '4'), 3);
      expect(sellUnitRemainder(quantity: '12', bundleQuantity: '4'), 0);
    });

    test('every quantity 1..12 totals the specified amount', () {
      for (final entry in _expectedTotals.entries) {
        expect(
          autoSellUnitTotal(_plan, entry.key),
          entry.value,
          reason: 'quantity ${entry.key}',
        );
      }
    });

    test('the discount is exactly the bundle saving, never negative', () {
      for (final entry in _expectedDiscounts.entries) {
        expect(
          autoSellUnitDiscount(_plan, entry.key),
          entry.value,
          reason: 'quantity ${entry.key}',
        );
      }
    });

    test('discount never exceeds the line gross (backend validation rule)', () {
      for (var q = 1; q <= 40; q++) {
        final quantity = '$q';
        final total = double.parse(autoSellUnitTotal(_plan, quantity)!);
        final discount = double.parse(autoSellUnitDiscount(_plan, quantity));
        expect(discount, greaterThanOrEqualTo(0));
        expect(discount, lessThanOrEqualTo(q * 500));
        expect(q * 500 - discount, closeTo(total, 0.0001));
      }
    });

    test('fractional quantities keep exact scaled arithmetic', () {
      // 1.5 units of a 3-unit bundle at 1 000 for 3 units of 500:
      // 0 bundles + 1.5 × 500 = 750, no discount.
      const fractional = AutoSellUnitPricing(
        bundleQuantity: '3',
        bundlePrice: '1000',
        unitPrice: '500',
      );
      expect(autoSellUnitTotal(fractional, '1.5'), '750');
      expect(autoSellUnitTotal(fractional, '3'), '1000');
      expect(autoSellUnitTotal(fractional, '4.5'), '1750');
      expect(autoSellUnitDiscount(fractional, '4.5'), '500');
    });

    test('a bundle that saves nothing is rejected', () {
      const noSaving = AutoSellUnitPricing(
        bundleQuantity: '4',
        bundlePrice: '2000',
        unitPrice: '500',
      );
      expect(autoSellUnitIsDiscounted(noSaving), isFalse);
      expect(autoSellUnitTotal(noSaving, '8'), isNull);
      expect(autoSellUnitDiscount(noSaving, '8'), '0');
    });

    test('a one-unit bundle is never a discount', () {
      const single = AutoSellUnitPricing(
        bundleQuantity: '1',
        bundlePrice: '400',
        unitPrice: '500',
      );
      expect(autoSellUnitIsDiscounted(single), isFalse);
      expect(autoSellUnitTotal(single, '5'), isNull);
    });

    test('unparsable configuration falls back safely', () {
      const broken = AutoSellUnitPricing(
        bundleQuantity: 'four',
        bundlePrice: '1900',
        unitPrice: '500',
      );
      expect(autoSellUnitIsDiscounted(broken), isFalse);
      expect(autoSellUnitTotal(broken, '4'), isNull);
      expect(autoSellUnitDiscount(broken, '4'), '0');
    });
  });

  group('choosing the bundle (resolveAutoSellUnit)', () {
    test('the discounting bundle is selected', () {
      final plan = resolveAutoSellUnit(
        [_unit()],
        unitPrice: '500',
      );
      expect(plan, isNotNull);
      expect(plan!.bundleQuantity, '4');
      expect(plan.bundlePrice, '1900');
      expect(plan.unitPrice, '500');
    });

    test('archived, base and non-discounting units are ignored', () {
      final plan = resolveAutoSellUnit(
        [
          _unit(id: 'archived', isArchived: true),
          _unit(id: 'base', isBaseUnit: true, multiplier: '1'),
          _unit(id: 'same-price', multiplier: '4', sellingPrice: '2000'),
          _unit(id: 'no-price', sellingPrice: null),
        ],
        unitPrice: '500',
      );
      expect(plan, isNull, reason: 'no unit offers a real saving');
    });

    test('the best saving wins regardless of list order', () {
      final plan = resolveAutoSellUnit(
        [
          _unit(id: 'box4', multiplier: '4', sellingPrice: '1900'), // saves 100
          _unit(id: 'box12', name: 'Carton', multiplier: '12', sellingPrice: '5500'),
        ],
        unitPrice: '500',
      ); // carton saves 500
      expect(plan!.bundleQuantity, '12');
      expect(plan.bundlePrice, '5500');
    });

    test('a product without sell units resolves to null', () {
      expect(resolveAutoSellUnit(const [], unitPrice: '500'), isNull);
    });
  });

  group('CartLine carrying the plan', () {
    test('only auto lines carry a plan', () {
      expect(_autoLine().autoPriced, isTrue);
      expect(
        const CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '4',
          unitPrice: '500',
        ).autoPriced,
        isFalse,
      );
    });

    test('a quantity change re-derives the discount both ways', () {
      final one = _autoLine();
      expect(one.lineTotal, 500);
      expect(one.lineDiscount, '0');

      final four = one.copyWith(quantity: '4');
      expect(four.lineDiscount, '100');
      expect(four.lineTotal, 1900);

      final five = four.copyWith(quantity: '5');
      expect(five.lineDiscount, '100');
      expect(five.lineTotal, 2400);

      final backToThree = four.copyWith(quantity: '3');
      expect(backToThree.lineDiscount, '0',
          reason: 'no stale discount below one complete bundle');
      expect(backToThree.lineTotal, 1500);

      final eight = five.copyWith(quantity: '8');
      expect(eight.lineDiscount, '200');
      expect(eight.lineTotal, 3800);
    });

    test('an explicit manual discount still wins', () {
      final line = _autoLine(quantity: '4').copyWith(lineDiscount: '50');
      expect(line.lineDiscount, '50');
      expect(line.lineTotal, 1950);
    });

    test('the unit price and unit identity never change', () {
      final line = _autoLine(quantity: '12');
      expect(line.unitPrice, '500');
      expect(line.unitMultiplier, isNull);
      expect(line.sellingUnitId, isNull);
      expect(line.quantity, '12');
      expect(line.lineTotal, 5700);
    });

    group('persistence', () {
      test('the sale payload is quantity × regular price − derived discount',
          () {
        final line = _autoLine(quantity: '5');
        final sale = line.toSaleJson();
        expect(sale['quantity'], '5');
        expect(sale['unit_price'], '500');
        expect(sale['line_discount'], '100');
        // The backend computes line_gross = unit_price × quantity and
        // line_total = line_gross − line_discount
        // (backend/app/services/sale.py::_apply_line_discount).
        final gross = 5 * 500;
        expect(
          gross - double.parse(sale['line_discount'] as String),
          2400,
        );
      });

      test('the bundle plan survives a hold round trip', () {
        final line = _autoLine(quantity: '8');
        final restored = CartLine.fromJson(
          Map<String, dynamic>.from(line.toJson()),
        );
        expect(restored.autoPriced, isTrue);
        expect(restored.autoBundleQuantity, '4');
        expect(restored.autoBundlePrice, '1900');
        expect(restored.lineDiscount, '200');
        expect(restored.lineTotal, 3800);
        // …and still re-derives after the restore.
        expect(restored.copyWith(quantity: '12').lineTotal, 5700);
      });

      test('a plain line stays plain through the round trip', () {
        const plain = CartLine(
          productId: 'p1',
          name: 'Bread',
          quantity: '4',
          unitPrice: '500',
        );
        final restored = CartLine.fromJson(
          Map<String, dynamic>.from(plain.toJson()),
        );
        expect(restored.autoPriced, isFalse);
        expect(restored.lineTotal, 2000);
      });
    });

    test('cart totals use the discounted line total', () {
      final cart = PosCartState(
        lines: [
          _autoLine(quantity: '4'),
          _autoLine(quantity: '5'),
        ],
      );
      final totals = cart.totals;
      // 9 units × 500 = 4500 gross, less the two derived bundle discounts
      // (100 each) → 4300, which is 1900 + 2400: the same amount the sale
      // payload persists and the invoice prints.
      expect(totals.subtotal, 4300);
      expect(totals.total, 4300);
    });
  });
}
