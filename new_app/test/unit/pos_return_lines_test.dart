// POS return mode — cart → independent-return line conversion.
//
// The builder is the single place that decides what the cart becomes on
// `POST /api/v1/returns`: base-unit quantities, merged (product, variant)
// buckets, packs rejected. These tests pin every rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_return_lines.dart';

CartLine _line({
  String? productId = 'p1',
  String? variantId,
  String? sellingUnitId,
  String? packId,
  String quantity = '1',
  String? unitMultiplier,
}) {
  return CartLine(
    productId: productId,
    variantId: variantId,
    sellingUnitId: sellingUnitId,
    packId: packId,
    name: 'Item',
    quantity: quantity,
    unitPrice: '10',
    unitMultiplier: unitMultiplier,
  );
}

void main() {
  group('buildPosReturnLines', () {
    test('empty cart is rejected with cart_empty', () {
      final result = buildPosReturnLines(const []);
      expect(result.isOk, isFalse);
      expect(result.errorKey, 'cart_empty');
      expect(result.lines, isEmpty);
    });

    test('a pack line anywhere blocks the whole return', () {
      final result = buildPosReturnLines([
        _line(productId: 'p1', quantity: '2'),
        _line(packId: 'pack-1', quantity: '1'),
      ]);
      expect(result.isOk, isFalse);
      expect(result.errorKey, 'pos_return_pack_not_supported');
      expect(result.lines, isEmpty);
    });

    test('plain product line keeps its quantity as base units', () {
      final result = buildPosReturnLines([
        _line(productId: 'p1', quantity: '2'),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines, hasLength(1));
      expect(result.lines.single.toJson(), {
        'product_id': 'p1',
        'quantity': '2',
      });
    });

    test('selling-unit quantity is converted to base units', () {
      final result = buildPosReturnLines([
        _line(
          productId: 'p1',
          sellingUnitId: 'unit-box',
          quantity: '2',
          unitMultiplier: '10',
        ),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines.single.toJson(), {
        'product_id': 'p1',
        'quantity': '20',
      });
    });

    test('variant line keeps its variant_id', () {
      final result = buildPosReturnLines([
        _line(
          productId: 'p1',
          variantId: 'var-1',
          quantity: '3',
        ),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines.single.toJson(), {
        'product_id': 'p1',
        'variant_id': 'var-1',
        'quantity': '3',
      });
    });

    test('same product + variant lines merge in exact scaled math', () {
      final result = buildPosReturnLines([
        _line(productId: 'p1', quantity: '3'),
        _line(
          productId: 'p1',
          sellingUnitId: 'unit-box',
          quantity: '1',
          unitMultiplier: '10',
        ),
        _line(productId: 'p1', quantity: '0.5'),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines, hasLength(1));
      expect(result.lines.single.quantity, '13.5');
    });

    test('different variants of one product stay separate lines', () {
      final result = buildPosReturnLines([
        _line(productId: 'p1', variantId: 'var-1', quantity: '1'),
        _line(productId: 'p1', variantId: 'var-2', quantity: '2'),
        _line(productId: 'p1', quantity: '4'),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines, hasLength(3));
      expect(result.lines[0].toJson(), {
        'product_id': 'p1',
        'variant_id': 'var-1',
        'quantity': '1',
      });
      expect(result.lines[1].toJson(), {
        'product_id': 'p1',
        'variant_id': 'var-2',
        'quantity': '2',
      });
      expect(result.lines[2].toJson(), {'product_id': 'p1', 'quantity': '4'});
    });

    test('output order is first-seen (product, variant) order', () {
      final result = buildPosReturnLines([
        _line(productId: 'p2', quantity: '1'),
        _line(productId: 'p1', quantity: '1'),
        _line(productId: 'p2', quantity: '1'),
      ]);
      expect(result.lines.map((l) => l.productId).toList(), ['p2', 'p1']);
    });

    test('zero / negative / unparsable quantities are rejected', () {
      for (final quantity in ['0', '-2', 'abc', '']) {
        final result = buildPosReturnLines([
          _line(productId: 'p1', quantity: quantity),
        ]);
        expect(result.isOk, isFalse, reason: 'quantity $quantity');
        expect(result.errorKey, 'invalid_qty');
      }
    });

    test('a line without a product id is rejected', () {
      final result = buildPosReturnLines([
        _line(productId: null, quantity: '1'),
      ]);
      expect(result.isOk, isFalse);
      expect(result.errorKey, 'error_return_line_invalid');
    });

    test('decimal quantities survive the base-unit conversion exactly', () {
      final result = buildPosReturnLines([
        _line(
          productId: 'p1',
          sellingUnitId: 'unit-bag',
          quantity: '2.5',
          unitMultiplier: '4',
        ),
      ]);
      expect(result.isOk, isTrue);
      expect(result.lines.single.quantity, '10');
    });
  });
}
