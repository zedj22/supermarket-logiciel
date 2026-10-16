// Purchase total-cost mode — pure math over the milli helpers.
//
// Contract (feature: per-line "Total cost"):
// - mode OFF: the entered cost IS the per-document-unit cost (existing
//   behavior preserved bit-for-bit);
// - mode ON: the entered cost is the TOTAL for the entered quantity and
//   the per-document-unit cost is derived (total ÷ qty, half-up);
// - box conversion follows the canonical rule: base qty = qty ×
//   multiplier, base unit cost = document unit cost ÷ multiplier —
//   the same convention the server applies on receive;
// - division by zero / invalid / empty input never produces a value.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/purchases/purchase_models.dart';

void main() {
  group('effectiveUnitCostMilli', () {
    test('mode off returns the entered cost unchanged (per-unit behavior)',
        () {
      expect(
        effectiveUnitCostMilli(
          quantity: '10',
          cost: '100',
          totalCostMode: false,
        ),
        100000,
      );
    });

    test('mode on: 10 pieces at total 100 → 10 per piece (Example A)',
        () {
      expect(
        effectiveUnitCostMilli(
          quantity: '10',
          cost: '100',
          totalCostMode: true,
        ),
        10000,
      );
    });

    test('mode on: 10 boxes at total 100 → 10 per box (Example B step 1)',
        () {
      expect(
        effectiveUnitCostMilli(
          quantity: '10',
          cost: '100',
          totalCostMode: true,
        ),
        10000,
      );
    });

    test('mode on rounds half-up to thousandths (100 ÷ 3 = 33.333)', () {
      expect(
        effectiveUnitCostMilli(
          quantity: '3',
          cost: '100',
          totalCostMode: true,
        ),
        33333,
      );
    });

    test('mode on with fractional quantity (100 ÷ 2.5 = 40)', () {
      expect(
        effectiveUnitCostMilli(
          quantity: '2.5',
          cost: '100',
          totalCostMode: true,
        ),
        40000,
      );
    });

    test('mode on rejects zero quantity instead of dividing by zero', () {
      expect(
        effectiveUnitCostMilli(
          quantity: '0',
          cost: '100',
          totalCostMode: true,
        ),
        isNull,
      );
    });

    test('mode on rejects missing/invalid quantity', () {
      expect(
        effectiveUnitCostMilli(
          quantity: '',
          cost: '100',
          totalCostMode: true,
        ),
        isNull,
      );
      expect(
        effectiveUnitCostMilli(
          quantity: 'abc',
          cost: '100',
          totalCostMode: true,
        ),
        isNull,
      );
    });

    test('invalid or empty cost is null in both modes', () {
      for (final totalMode in [true, false]) {
        expect(
          effectiveUnitCostMilli(
            quantity: '10',
            cost: '',
            totalCostMode: totalMode,
          ),
          isNull,
        );
        expect(
          effectiveUnitCostMilli(
            quantity: '10',
            cost: 'abc',
            totalCostMode: totalMode,
          ),
          isNull,
        );
        expect(
          effectiveUnitCostMilli(
            quantity: '10',
            cost: '1.2345',
            totalCostMode: totalMode,
          ),
          isNull,
        );
      }
    });

    test('zero total cost stays zero (explicit, not silent)', () {
      expect(
        effectiveUnitCostMilli(
          quantity: '10',
          cost: '0',
          totalCostMode: true,
        ),
        0,
      );
    });
  });

  group('baseQtyEquivalentMilli', () {
    test('10 boxes × 5 → 50 base pieces (Example B)', () {
      expect(baseQtyEquivalentMilli('10', '5'), 50000);
    });

    test('null multiplier means base units — quantity passes through', () {
      expect(baseQtyEquivalentMilli('10', null), 10000);
      expect(baseQtyEquivalentMilli('10', ''), 10000);
    });

    test('fractional quantity × multiplier rounds half-up', () {
      expect(baseQtyEquivalentMilli('2.5', '4'), 10000);
    });

    test('invalid quantity or non-positive multiplier is null', () {
      expect(baseQtyEquivalentMilli('abc', '5'), isNull);
      expect(baseQtyEquivalentMilli('10', '0'), isNull);
      expect(baseQtyEquivalentMilli('10', 'x'), isNull);
    });
  });

  group('baseUnitCostMilli', () {
    test('10 per box ÷ 5 → 2 per base piece (Example B)', () {
      expect(baseUnitCostMilli(10000, '5'), 2000);
    });

    test('100 per box ÷ 5 → 20 per base piece (Example C)', () {
      expect(baseUnitCostMilli(100000, '5'), 20000);
    });

    test('null/empty multiplier passes the cost through (base line)', () {
      expect(baseUnitCostMilli(100000, null), 100000);
      expect(baseUnitCostMilli(100000, ''), 100000);
    });

    test('rounds half-up to thousandths (33.333 ÷ 2 = 16.667)', () {
      expect(baseUnitCostMilli(33333, '2'), 16667);
    });

    test('null cost or invalid multiplier is null', () {
      expect(baseUnitCostMilli(null, '5'), isNull);
      expect(baseUnitCostMilli(10000, '0'), isNull);
      expect(baseUnitCostMilli(10000, 'x'), isNull);
    });
  });

  group('canonical persistence shape (DraftLine payload)', () {
    test('total-cost derivation lands in unit_cost, quantity untouched',
        () {
      // What the dialog does when the user saves 10 boxes at total 100:
      // the derived per-box cost (10) is what gets staged/sent.
      final derived = effectiveUnitCostMilli(
        quantity: '10',
        cost: '100',
        totalCostMode: true,
      )!;
      final line = DraftLine(
        productId: 'p1',
        productName: 'Lait',
        purchaseUnitId: 'u1',
        purchaseUnitName: 'Box',
        multiplier: '5',
        quantity: '10',
        unitCost: milliToMoney(derived),
      );
      expect(line.toPayload(), {
        'product_id': 'p1',
        'purchase_unit_id': 'u1',
        'quantity': '10',
        'unit_cost': '10.000',
      });
      // Line total stays document arithmetic: 10 × 10 = 100.
      expect(line.lineTotalMilli, 100000);
      expect(line.lineTotal, '100.000');
    });

    test('a saved line reloads with the canonical per-unit cost', () {
      // Server response for the Example B line — unit_cost is per box,
      // base_qty_equivalent and line_total are derived server-side.
      final model = PurchaseLineModel.fromJson({
        'id': 'l1',
        'product_id': 'p1',
        'product_name': 'Lait',
        'product_unit': 'piece',
        'purchase_unit_id': 'u1',
        'purchase_unit_name': 'Box',
        'unit_multiplier': '5',
        'quantity': '10',
        'unit_cost': '10',
        'base_qty_equivalent': '50',
        'line_total': '100',
      });
      expect(model.unitCost, '10');
      expect(model.unitMultiplier, '5');
      expect(model.baseQtyEquivalent, '50');
      expect(model.lineTotal, '100');
      // Reopening the editor with this line starts in per-unit mode and
      // shows the stored per-box cost — no reinterpretation happens.
      expect(
        effectiveUnitCostMilli(
          quantity: model.quantity,
          cost: model.unitCost,
          totalCostMode: false,
        ),
        10000,
      );
    });
  });
}
