// Phase 17 — receipt item contract: the add path must not reach the printer.
//
// The 80mm receipt renders ONLY what `POST /api/v1/sales` accepts. The
// barcode path (Enter-in-search exact match → `_addProduct`) and the catalog
// path (product tile → `_addProduct`) share `_addCartLine`, so the same line
// has to produce byte-identical checkout payloads no matter which one the
// cashier used — display-only snapshots (name formatting, stock, base-unit
// price, multiplier) stay in `toJson()` (holds) and never leak into
// `toSaleJson()`.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';

void main() {
  group('CartLine.toSaleJson (Phase 17 receipt contract)', () {
    test('catalog add and barcode add send identical payloads', () {
      // Same product, same selection — only the display snapshots differ.
      const fromCatalog = CartLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        name: 'Coca Cola 1L',
        variantName: '1L',
        unitName: 'Bottle',
        quantity: '2',
        unitPrice: '160',
        lineDiscount: '0',
        barcode: '6130000112233',
        availableStock: '12',
        productUnit: 'liter',
        baseUnitPrice: '150',
        unitMultiplier: '1',
      );
      const fromBarcode = CartLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        name: 'Coca Cola 1L · 1L Bottle',
        quantity: '2',
        unitPrice: '160',
        lineDiscount: '0',
        barcode: '6130000112233',
        productUnit: 'liter',
      );

      expect(fromCatalog.toSaleJson(), fromBarcode.toSaleJson());
    });

    test('payload carries only checkout fields', () {
      const line = CartLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        name: 'Coca Cola 1L',
        variantName: '1L',
        unitName: 'Bottle',
        quantity: '2',
        unitPrice: '160',
        lineDiscount: '10',
        barcode: '6130000112233',
        availableStock: '12',
        productUnit: 'liter',
        baseUnitPrice: '150',
        unitMultiplier: '1',
        componentsSummary: '2 × Water',
      );
      const checkoutKeys = {
        'product_id',
        'pack_id',
        'variant_id',
        'selling_unit_id',
        'quantity',
        'unit_price',
        'line_discount',
        'barcode',
      };

      final payload = line.toSaleJson();
      expect(payload.keys.toSet().difference(checkoutKeys), isEmpty);
      expect(
        payload.keys.toSet(),
        containsAll(<String>[
          'product_id',
          'variant_id',
          'selling_unit_id',
          'quantity',
          'unit_price',
          'line_discount',
          'barcode',
        ]),
      );
      for (final displayKey in <String>[
        'product_name',
        'variant_name',
        'unit_name',
        'product_unit',
        'base_unit_price',
        'unit_multiplier',
        'components_summary',
        'available_stock',
      ]) {
        expect(payload, isNot(contains(displayKey)));
      }
    });

    test('hold snapshot keeps the display fields the payload drops', () {
      const line = CartLine(
        productId: 'p1',
        name: 'Coca Cola 1L',
        unitName: 'Bottle',
        quantity: '2',
        unitPrice: '160',
        barcode: '6130000112233',
      );

      expect(line.toJson()['product_name'], 'Coca Cola 1L');
      expect(line.toJson()['unit_name'], 'Bottle');
      expect(line.toSaleJson(), isNot(contains('product_name')));
      expect(line.toSaleJson(), isNot(contains('unit_name')));
    });

    test('barcode is sent only when the product carries one', () {
      const scanned = CartLine(
        productId: 'p1',
        name: 'Water',
        barcode: '6130000112233',
      );
      const manual = CartLine(productId: 'p1', name: 'Water');

      expect(scanned.toSaleJson()['barcode'], '6130000112233');
      expect(manual.toSaleJson(), isNot(contains('barcode')));
    });
  });
}
