// Phase 10 — pack models, cart pack lines and pack stock-bucket rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/packs/pack_models.dart';
import 'package:supermarket_pos/features/packs/packs_providers.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_quantity.dart';

void main() {
  group('PackModel', () {
    test('parses a list row (no components) with informational sum_of_parts',
        () {
      final pack = PackModel.fromJson({
        'id': 'pack-1',
        'name': 'Family Pack',
        'barcode': '777',
        'price': '250.0',
        'is_active': true,
        'is_archived': false,
        'components_count': 3,
        'sum_of_parts': '300.0',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      expect(pack.name, 'Family Pack');
      expect(pack.price, '250.0');
      expect(pack.componentsCount, 3);
      expect(pack.sumOfParts, '300.0');
      expect(pack.isSaleable, isTrue);
      expect(pack.components, isEmpty);
    });

    test('detail carries resolved components', () {
      final pack = PackModel.fromJson({
        'id': 'pack-2',
        'name': 'Weekend Box',
        'price': '100',
        'is_active': true,
        'is_archived': false,
        'components_count': 2,
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Bread',
            'product_unit': 'piece',
            'product_price': '50',
            'quantity': '2',
          },
          {
            'product_id': 'p2',
            'product_name': 'Milk',
            'product_unit': 'liter',
            'product_price': '25',
            'quantity': '1',
          },
        ],
      });
      expect(pack.components, hasLength(2));
      expect(pack.components.first.productName, 'Bread');
      expect(pack.components.first.quantity, '2');
    });

    test('archived or inactive pack is not saleable (GATE 8)', () {
      final archived = PackModel.fromJson({
        'id': 'p',
        'name': 'Old',
        'is_active': false,
        'is_archived': true,
      });
      expect(archived.isSaleable, isFalse);

      final inactive = PackModel.fromJson({
        'id': 'p',
        'name': 'Paused',
        'is_active': false,
        'is_archived': false,
      });
      expect(inactive.isSaleable, isFalse);
    });
  });

  group('PackModel fix round (selling unit + estimate)', () {
    test('parses the informational estimate fields from the detail payload',
        () {
      final pack = PackModel.fromJson({
        'id': 'pack-1',
        'name': 'Family Pack',
        'price': '320',
        'is_active': true,
        'is_archived': false,
        'estimated_cost': '240',
        'estimated_profit': '80',
        'estimated_margin_percent': '25',
      });
      expect(pack.estimatedCost, '240');
      expect(pack.estimatedProfit, '80');
      expect(pack.estimatedMarginPercent, '25');
    });

    test('list rows without an estimate keep null (no fake numbers)', () {
      final pack = PackModel.fromJson({
        'id': 'pack-1',
        'name': 'Family Pack',
        'price': '320',
        'is_active': true,
        'is_archived': false,
      });
      expect(pack.estimatedCost, isNull);
      expect(pack.estimatedProfit, isNull);
      expect(pack.estimatedMarginPercent, isNull);
    });

    test('a component pinned to a selling unit keeps base + unit quantities',
        () {
      final pack = PackModel.fromJson({
        'id': 'pack-2',
        'name': 'Weekend Box',
        'price': '100',
        'is_active': true,
        'is_archived': false,
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Sugar',
            'product_unit': 'piece',
            'product_price': '10',
            'quantity': '48',
            'selling_unit_id': 'su-box',
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': '24',
            'unit_quantity': '2',
            'base_quantity': '48',
            'avg_cost': '5',
          },
        ],
      });
      final component = pack.components.single;
      expect(component.productName, 'Sugar');
      // GATE 2: `quantity` stays BASE units (stock / availability / sale).
      expect(component.quantity, '48');
      expect(component.baseQuantity, '48');
      expect(component.hasSellingUnit, isTrue);
      expect(component.sellingUnitId, 'su-box');
      expect(component.sellingUnitName, 'Box');
      expect(component.sellingUnitMultiplier, '24');
      expect(component.unitQuantity, '2');
      expect(component.multiplier, 24);
      expect(component.avgCost, '5');
    });

    test('a legacy component has no unit identity and reads as base units',
        () {
      final pack = PackModel.fromJson({
        'id': 'pack-3',
        'name': 'Legacy',
        'price': '100',
        'is_active': true,
        'is_archived': false,
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Sugar',
            'product_unit': 'piece',
            'product_price': '10',
            'quantity': '48',
          },
        ],
      });
      final component = pack.components.single;
      expect(component.hasSellingUnit, isFalse);
      expect(component.sellingUnitId, isNull);
      expect(component.unitQuantity, '48');
      expect(component.baseQuantity, '48');
      expect(component.multiplier, 1);
      expect(component.avgCost, '0');
    });
  });

  group('PackAvailabilityModel', () {
    test('parses saleable availability with component rows', () {
      final availability = PackAvailabilityModel.fromJson({
        'pack_id': 'pack-1',
        'pack_name': 'Family Pack',
        'price': '250.0',
        'is_active': true,
        'is_archived': false,
        'quantity': '2',
        'saleable': true,
        'max_pack_quantity': '3',
        'sum_of_parts': '300.0',
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Bread',
            'product_unit': 'piece',
            'required_per_pack': '2',
            'required_quantity': '4',
            'available_quantity': '6',
            'ok': true,
          },
        ],
        'errors': [],
      });
      expect(availability.saleable, isTrue);
      expect(availability.maxPackQuantity, '3');
      expect(availability.components.single.ok, isTrue);
      expect(availability.components.single.requiredQuantity, '4');
      expect(availability.errors, isEmpty);
    });

    test('parses a blocked availability with localized backend errors', () {
      final availability = PackAvailabilityModel.fromJson({
        'pack_id': 'pack-1',
        'pack_name': 'Family Pack',
        'price': '250.0',
        'is_active': false,
        'is_archived': false,
        'quantity': '1',
        'saleable': false,
        'max_pack_quantity': '0',
        'components': [],
        'errors': ['Pack is not active'],
      });
      expect(availability.saleable, isFalse);
      expect(availability.maxPackQuantity, '0');
      expect(availability.errors.single, 'Pack is not active');
    });

    test('parses the pinned unit fields for the conversion line', () {
      final availability = PackAvailabilityModel.fromJson({
        'pack_id': 'pack-1',
        'pack_name': 'Family Pack',
        'price': '320',
        'is_active': true,
        'is_archived': false,
        'quantity': '1',
        'saleable': true,
        'max_pack_quantity': '4',
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Sugar',
            'product_unit': 'piece',
            'required_per_pack': '48',
            'required_quantity': '48',
            'available_quantity': '240',
            'ok': true,
            'selling_unit_id': 'su-box',
            'selling_unit_name': 'Box',
            'selling_unit_multiplier': '24',
            'unit_quantity': '2',
            'required_unit_quantity': '2',
          },
        ],
        'errors': [],
      });
      final component = availability.components.single;
      expect(component.hasSellingUnit, isTrue);
      expect(component.sellingUnitId, 'su-box');
      expect(component.sellingUnitName, 'Box');
      expect(component.sellingUnitMultiplier, '24');
      expect(component.unitQuantity, '2');
      expect(component.requiredUnitQuantity, '2');
      // Base values stay authoritative for stock maths.
      expect(component.requiredQuantity, '48');
      expect(component.availableQuantity, '240');
    });

    test('an availability row without unit identity falls back to base',
        () {
      final availability = PackAvailabilityModel.fromJson({
        'pack_id': 'pack-1',
        'pack_name': 'Family Pack',
        'price': '320',
        'is_active': true,
        'is_archived': false,
        'quantity': '1',
        'saleable': true,
        'max_pack_quantity': '4',
        'components': [
          {
            'product_id': 'p1',
            'product_name': 'Sugar',
            'product_unit': 'piece',
            'required_per_pack': '48',
            'required_quantity': '48',
            'available_quantity': '240',
            'ok': true,
          },
        ],
        'errors': [],
      });
      final component = availability.components.single;
      expect(component.hasSellingUnit, isFalse);
      expect(component.unitQuantity, '48');
      expect(component.requiredUnitQuantity, '48');
    });
  });

  group('PackPickResult', () {
    test('carries everything the POS cart line needs', () {
      const result = PackPickResult(
        packId: 'pack-1',
        name: 'Family Pack',
        barcode: '777',
        price: '250',
        quantity: '2',
        maxPackQuantity: '3',
        componentsSummary: 'Components: Bread · Milk',
      );
      expect(result.packId, 'pack-1');
      expect(result.quantity, '2');
      expect(result.maxPackQuantity, '3');
      expect(result.componentsSummary, isNotEmpty);
    });
  });

  group('packApiCodeMessage', () {
    test('maps every Phase 10 backend code to a localized headline', () {
      expect(packApiCodeMessage('PACK_INACTIVE', 'en'), isNotNull);
      expect(packApiCodeMessage('PACK_STOCK_INSUFFICIENT', 'en'), isNotNull);
      expect(packApiCodeMessage('PACK_COMPONENT_DUPLICATE', 'en'), isNotNull);
      expect(packApiCodeMessage('OTHER_CODE', 'en'), isNull);
    });
  });

  group('CartLine pack lines', () {
    const packLine = CartLine(
      packId: 'pack-1',
      name: 'Family Pack',
      quantity: '2',
      unitPrice: '250',
      productUnit: 'pack',
      unitName: 'pack',
      availableStock: '3',
      componentsSummary: 'Components: Bread · Milk',
    );

    test('isPack is true and the key never collides with a product line', () {
      const productLine = CartLine(productId: 'pack-1', name: 'Bread');
      expect(packLine.isPack, isTrue);
      expect(productLine.isPack, isFalse);
      expect(packLine.key, 'pack:pack-1');
      expect(packLine.key, isNot(productLine.key));
    });

    test('toSaleJson sends pack_id and never product_id (GATE 6)', () {
      final json = packLine.toSaleJson();
      expect(json['pack_id'], 'pack-1');
      expect(json.containsKey('product_id'), isFalse);
      expect(json['quantity'], '2');
      expect(json['unit_price'], '250');
      // Display metadata stays out of the sale payload.
      expect(json.containsKey('components_summary'), isFalse);
      expect(json.containsKey('product_name'), isFalse);
    });

    test('hold snapshot keeps pack_id, product_id null and the summary',
        () {
      final json = packLine.toJson();
      expect(json['pack_id'], 'pack-1');
      expect(json['product_id'], isNull);
      expect(json['components_summary'], 'Components: Bread · Milk');
      expect(json['product_name'], 'Family Pack');
    });

    test('fromJson restores a pack line from a hold snapshot', () {
      final line = CartLine.fromJson({
        'product_id': null,
        'pack_id': 'pack-1',
        'product_name': 'Family Pack',
        'quantity': '2',
        'unit_price': '250',
        'line_discount': '0',
        'components_summary': 'Components: Bread',
        'available_stock': '3',
      });
      expect(line.isPack, isTrue);
      expect(line.packId, 'pack-1');
      expect(line.productId, isNull);
      expect(line.key, 'pack:pack-1');
      expect(line.componentsSummary, 'Components: Bread');
      expect(line.availableStock, '3');
    });

    test('copyWith keeps the pack identity', () {
      final merged = packLine.copyWith(quantity: '3');
      expect(merged.packId, 'pack-1');
      expect(merged.key, 'pack:pack-1');
      expect(merged.componentsSummary, packLine.componentsSummary);
      expect(merged.lineTotal, closeTo(750, 0.001));
    });
  });

  group('posSameStockBucket (Phase 10)', () {
    test('two lines of the same pack share one bucket', () {
      const a = CartLine(packId: 'pack-1', name: 'Family Pack');
      const b = CartLine(packId: 'pack-1', name: 'Family Pack');
      expect(posSameStockBucket(a, b), isTrue);
    });

    test('different packs never share a bucket', () {
      const a = CartLine(packId: 'pack-1', name: 'A');
      const b = CartLine(packId: 'pack-2', name: 'B');
      expect(posSameStockBucket(a, b), isFalse);
    });

    test('a pack line and a product line never share a bucket', () {
      const pack = CartLine(packId: 'pack-1', name: 'Family Pack');
      const product = CartLine(productId: 'pack-1', name: 'Same id product');
      expect(posSameStockBucket(pack, product), isFalse);
      expect(posSameStockBucket(product, pack), isFalse);
    });

    test('product lines keep the product + variant rule', () {
      const a = CartLine(productId: 'p1', variantId: 'v1', name: 'A');
      const sameBucket = CartLine(productId: 'p1', variantId: 'v1', name: 'B');
      const otherVariant = CartLine(productId: 'p1', variantId: 'v2', name: 'C');
      expect(posSameStockBucket(a, sameBucket), isTrue);
      expect(posSameStockBucket(a, otherVariant), isFalse);
    });
  });

  group('PriceOverrideModel identity', () {
    test('product overrides keep their legacy product id identity', () {
      const o = PriceOverrideModel(
        lineIndex: 0,
        productId: 'p1',
        requestedUnitPrice: '9',
        appliedUnitPrice: '10',
      );
      expect(o.identity, 'p1');
      final named = o.withProductName('Bread');
      expect(named.identity, 'p1');
      expect(named.productName, 'Bread');
      expect(named.packId, isNull);
    });

    test('pack overrides resolve by pack id', () {
      final json = PriceOverrideModel.fromJson({
        'line_index': 1,
        'product_id': null,
        'pack_id': 'pack-1',
        'requested_unit_price': '200',
        'applied_unit_price': '250',
      });
      expect(json.identity, 'pack:pack-1');
      expect(json.productId, isNull);
      expect(json.packId, 'pack-1');
      expect(json.lineIndex, 1);
    });
  });
}
