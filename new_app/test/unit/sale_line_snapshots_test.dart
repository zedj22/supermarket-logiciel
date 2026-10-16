// UX FIX #11 — sale line historical snapshots.
//
// Sale Detail / receipt must render only what the backend captured at
// checkout (variant name, selling unit name, multiplier) and must never
// need a catalog lookup. These are pure model + receipt-text tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/sale_detail_dialog.dart';

Map<String, dynamic> _baseLine({
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': 'line-1',
      'product_id': 'prod-1',
      'variant_id': null,
      'product_name': 'Rice Bag',
      'product_sku': 'RB-1',
      'product_barcode': null,
      'product_unit': 'piece',
      'unit_price': '550.00',
      'unit_cost': '400.00',
      'quantity': '2',
      'line_discount': '0',
      'line_total': '1100.00',
      ...extra,
    };

Map<String, dynamic> _saleJson(List<Map<String, dynamic>> lines) => {
      'id': 'sale-1',
      'invoice_number': 'INV-1',
      'customer_id': null,
      'status': 'completed',
      'subtotal': '1100.00',
      'discount': '0',
      'total': '1100.00',
      'paid': '1100.00',
      'change': '0',
      'debt': '0',
      'payment_method': 'cash',
      'device_id': null,
      'note': null,
      'sale_date': '2026-09-24T10:00:00',
      'lines': lines,
      'payments': [
        {'id': 'pay-1', 'method': 'cash', 'amount': '1100.00'},
      ],
      'idempotent_replay': false,
    };

void main() {
  group('SaleDetailLine snapshots (UX FIX #11)', () {
    test('legacy row without snapshot fields parses as nulls', () {
      final line = SaleDetailLine.fromJson(_baseLine());

      expect(line.variantName, isNull);
      expect(line.sellingUnitName, isNull);
      expect(line.sellingUnitMultiplier, isNull);
      expect(line.baseQuantity, isNull);
      expect(line.productName, 'Rice Bag');
      expect(line.productUnit, 'piece');
      expect(line.quantity, '2');
      expect(line.lineTotal, '1100.00');
    });

    test('variant snapshot parses from the sale line', () {
      final line = SaleDetailLine.fromJson(
        _baseLine(extra: {
          'variant_id': 'var-1',
          'variant_name': 'Cheddar',
        }),
      );

      expect(line.variantId, 'var-1');
      expect(line.variantName, 'Cheddar');
      expect(line.sellingUnitName, isNull);
      expect(line.sellingUnitMultiplier, isNull);
      expect(line.baseQuantity, isNull);
    });

    test('selling unit snapshot parses and yields base quantity', () {
      final line = SaleDetailLine.fromJson(
        _baseLine(extra: {
          'selling_unit_name': 'Box',
          'selling_unit_multiplier': '24.000',
        }),
      );

      expect(line.sellingUnitName, 'Box');
      expect(line.sellingUnitMultiplier, '24.000');
      expect(line.baseQuantity, 48);
      expect(line.variantName, isNull);
    });

    test('multiplier returned as a JSON number still parses', () {
      final line = SaleDetailLine.fromJson(
        _baseLine(extra: {
          'selling_unit_name': 'Box',
          'selling_unit_multiplier': 24.0,
        }),
      );

      expect(line.sellingUnitMultiplier, '24.0');
      expect(line.baseQuantity, 48);
    });

    test('client-supplied fake names are ignored when key is absent', () {
      // Backend derives snapshots server-side; an unknown key must not
      // survive into the model.
      final line = SaleDetailLine.fromJson(_baseLine());

      expect(line.productName, 'Rice Bag');
      expect(line.variantName, isNull);
      expect(line.sellingUnitName, isNull);
    });

    test('base quantity is null when multiplier is missing or invalid', () {
      final noMultiplier = SaleDetailLine.fromJson(
        _baseLine(extra: {'selling_unit_name': 'Box'}),
      );
      final badMultiplier = SaleDetailLine.fromJson(
        _baseLine(
          extra: {
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': 'not-a-number',
          },
        ),
      );

      expect(noMultiplier.baseQuantity, isNull);
      expect(badMultiplier.baseQuantity, isNull);
    });
  });

  group('buildReceiptText uses stored snapshots only', () {
    test('base-unit line keeps product unit and totals', () {
      final receipt =
          buildReceiptText(SaleDetail.fromJson(_saleJson([_baseLine()])), 'en');

      expect(receipt, contains('Rice Bag'));
      expect(receipt, contains('2 piece'));
      expect(receipt, contains('550.00'));
      // Presentation-only grouping: 1100.00 renders as `1 100.00`.
      expect(receipt, contains('1 100.00'));
      expect(receipt, isNot(contains('Box')));
      expect(receipt, isNot(contains('Base:')));
    });

    test('variant line shows the stored variant name', () {
      final receipt = buildReceiptText(
        SaleDetail.fromJson(_saleJson([
          _baseLine(extra: {
            'variant_id': 'var-1',
            'variant_name': 'Cheddar',
            'quantity': '1',
            'unit_price': '70.00',
            'line_total': '70.00',
          }),
        ])),
        'en',
      );

      expect(receipt, contains('Rice Bag (Cheddar)'));
      expect(receipt, contains('1 piece'));
      expect(receipt, contains('70.00'));
      expect(receipt, isNot(contains('Box')));
    });

    test('selling unit line shows stored unit + base quantity', () {
      final receipt = buildReceiptText(
        SaleDetail.fromJson(_saleJson([
          _baseLine(extra: {
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': '24.000',
            'quantity': '2',
            'unit_price': '550.00',
            'line_total': '1100.00',
          }),
        ])),
        'en',
      );

      expect(receipt, contains('2 Box'));
      expect(receipt, contains('550.00'));
      expect(receipt, contains('Base: 48 piece'));
      expect(receipt, contains('1 100.00'));
    });

    test('selling unit line in Arabic uses the localized base unit label', () {
      final receipt = buildReceiptText(
        SaleDetail.fromJson(_saleJson([
          _baseLine(extra: {
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': '24.000',
          }),
        ])),
        'ar',
      );

      expect(receipt, contains('2 Box'));
      expect(receipt, contains('48'));
      // Short "Base:" label (UX FIX #12), localized for the receipt.
      expect(AppStrings.t('base', 'ar'), isNot(AppStrings.t('base', 'en')));
      expect(receipt, contains('${AppStrings.t('base', 'ar')}: 48'));
    });

    test('fractional base quantity is formatted without trailing zeros', () {
      final receipt = buildReceiptText(
        SaleDetail.fromJson(_saleJson([
          _baseLine(extra: {
            'selling_unit_name': 'Case',
            'selling_unit_multiplier': '1.500',
            'quantity': '3',
          }),
        ])),
        'en',
      );

      expect(receipt, contains('Base: 4.5 piece'));
    });

    test('receipt never recomputes totals from snapshots', () {
      final sale = SaleDetail.fromJson(
        _saleJson([
          _baseLine(extra: {
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': '24.000',
          }),
        ]),
      );
      final receipt = buildReceiptText(sale, 'en');

      expect(receipt, contains('1 100.00'));
      expect(sale.total, '1100.00');
    });
  });
}
