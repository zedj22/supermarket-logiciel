// Phase 8 Step 3 — POS cart / payment math unit tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/pos/pos_models.dart';
import 'package:supermarket_pos/features/pos/pos_providers.dart';

void main() {
  group('CartLine', () {
    test('key groups product/variant/unit', () {
      const a = CartLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        name: 'A',
      );
      const b = CartLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        name: 'B',
      );
      const c = CartLine(productId: 'p1', name: 'C');
      expect(a.key, b.key);
      expect(a.key, isNot(c.key));
    });

    test('lineTotal = qty * price - lineDiscount', () {
      const line = CartLine(
        productId: 'p',
        name: 'X',
        quantity: '3',
        unitPrice: '10',
        lineDiscount: '5',
      );
      expect(line.lineTotal, closeTo(25, 0.001));
    });

    test('toSaleJson omits null ids and includes required fields', () {
      const line = CartLine(
        productId: 'p1',
        name: 'X',
        quantity: '2',
        unitPrice: '5.5',
        lineDiscount: '1',
        barcode: '123',
      );
      final json = line.toSaleJson();
      expect(json['product_id'], 'p1');
      expect(json['quantity'], '2');
      expect(json['unit_price'], '5.5');
      expect(json['line_discount'], '1');
      expect(json['barcode'], '123');
      expect(json.containsKey('variant_id'), isFalse);
      expect(json.containsKey('selling_unit_id'), isFalse);
      // Display metadata is never part of the POST /sales contract.
      expect(json.containsKey('product_name'), isFalse);
      expect(json.containsKey('base_unit_price'), isFalse);
      expect(json.containsKey('unit_multiplier'), isFalse);
    });

    // ── FIX #10B STEP 10 (1–6): hold snapshot serialization ──────────
    test('hold snapshot toJson contains product_name', () {
      const line = CartLine(productId: 'p1', name: 'eau');
      final json = line.toJson();
      expect(json.containsKey('product_name'), isTrue);
      expect(json['product_name'], 'eau');
    });

    test('hold snapshot toJson contains unit_name', () {
      const line = CartLine(
        productId: 'p1',
        name: 'eau',
        unitName: 'Fardeau',
      );
      final json = line.toJson();
      expect(json.containsKey('unit_name'), isTrue);
      expect(json['unit_name'], 'Fardeau');
      // Absent selling unit → explicit null, key still present.
      final base = const CartLine(productId: 'p2', name: 'Bread').toJson();
      expect(base.containsKey('unit_name'), isTrue);
      expect(base['unit_name'], isNull);
    });

    test('hold snapshot toJson contains variant_name', () {
      const line = CartLine(
        productId: 'p1',
        variantId: 'v1',
        name: 'eau · Small',
        variantName: 'Small',
      );
      final json = line.toJson();
      expect(json.containsKey('variant_name'), isTrue);
      expect(json['variant_name'], 'Small');
      final noVariant =
          const CartLine(productId: 'p2', name: 'Bread').toJson();
      expect(noVariant.containsKey('variant_name'), isTrue);
      expect(noVariant['variant_name'], isNull);
    });

    test('hold snapshot toJson contains base_unit_price', () {
      const line = CartLine(
        productId: 'p1',
        name: 'eau',
        baseUnitPrice: '55',
      );
      final json = line.toJson();
      expect(json.containsKey('base_unit_price'), isTrue);
      expect(json['base_unit_price'], '55');
    });

    test('hold snapshot toJson contains unit_multiplier', () {
      const line = CartLine(
        productId: 'p1',
        name: 'eau',
        unitMultiplier: '9',
      );
      final json = line.toJson();
      expect(json.containsKey('unit_multiplier'), isTrue);
      expect(json['unit_multiplier'], '9');
    });

    test('fromJson restores product name and full display metadata', () {
      final line = CartLine.fromJson({
        'product_id': 'p1',
        'variant_id': 'v1',
        'selling_unit_id': 'su-box',
        'product_name': 'eau · Small',
        'variant_name': 'Small',
        'unit_name': 'Box',
        'product_unit': 'piece',
        'quantity': '1',
        'unit_price': '550',
        'line_discount': '0',
        'base_unit_price': '55',
        'unit_multiplier': '10',
        'available_stock': '12',
      });
      expect(line.name, 'eau · Small');
      expect(line.variantName, 'Small');
      expect(line.unitName, 'Box');
      expect(line.productUnit, 'piece');
      expect(line.baseUnitPrice, '55');
      expect(line.unitMultiplier, '10');
      expect(line.availableStock, '12');
      expect(line.sellingUnitId, 'su-box');
    });

    test('fromJson parses hold/checkout cart items', () {
      final line = CartLine.fromJson({
        'product_id': 'p1',
        'variant_id': null,
        'selling_unit_id': 'u1',
        'product_name': 'Bread',
        'quantity': '1.5',
        'unit_price': '10',
        'line_discount': '0',
        'barcode': '999',
      });
      expect(line.productId, 'p1');
      expect(line.name, 'Bread');
      expect(line.quantity, '1.5');
      expect(line.unitPrice, '10');
      expect(line.sellingUnitId, 'u1');
    });

    test('copyWith only changes provided fields', () {
      const line = CartLine(
        productId: 'p',
        name: 'N',
        quantity: '1',
        unitPrice: '10',
      );
      final updated = line.copyWith(quantity: '4');
      expect(updated.quantity, '4');
      expect(updated.unitPrice, '10');
      expect(updated.name, 'N');
    });

    test('unit presentation snapshot survives copyWith; toSaleJson stays on '
        'API contract; hold toJson keeps display fields; total uses '
        'selling-unit price only', () {
      const line = CartLine(
        productId: 'p',
        name: 'Fromage',
        sellingUnitId: 'u-box',
        unitName: 'Box',
        quantity: '2',
        unitPrice: '550',
        productUnit: 'piece',
        baseUnitPrice: '60',
        unitMultiplier: '10',
      );
      final merged = line.copyWith(quantity: '4');
      expect(merged.baseUnitPrice, '60');
      expect(merged.unitMultiplier, '10');
      expect(merged.productUnit, 'piece');
      expect(merged.unitName, 'Box');

      final saleJson = merged.toSaleJson();
      expect(saleJson.containsKey('base_unit_price'), isFalse);
      expect(saleJson.containsKey('unit_multiplier'), isFalse);
      expect(saleJson.containsKey('product_name'), isFalse);
      expect(saleJson.containsKey('unit_name'), isFalse);

      // Hold snapshot keeps every display field for restore (STEP 3).
      final holdJson = merged.toJson();
      expect(holdJson['product_name'], 'Fromage');
      expect(holdJson['unit_name'], 'Box');
      expect(holdJson['base_unit_price'], '60');
      expect(holdJson['unit_multiplier'], '10');
      expect(holdJson['product_unit'], 'piece');

      // 4 Box × 550 = 2200 — never 40 Piece × 60 = 2400.
      expect(merged.lineTotal, closeTo(2200, 0.001));
    });
  });

  group('PaymentMethod', () {
    test('requiresCustomer only for partial and credit', () {
      expect(PaymentMethod.cash.requiresCustomer, isFalse);
      expect(PaymentMethod.card.requiresCustomer, isFalse);
      expect(PaymentMethod.partial.requiresCustomer, isTrue);
      expect(PaymentMethod.credit.requiresCustomer, isTrue);
    });

    test('apiValue matches backend contract', () {
      expect(PaymentMethod.cash.apiValue, 'cash');
      expect(PaymentMethod.card.apiValue, 'card');
      expect(PaymentMethod.partial.apiValue, 'partial');
      expect(PaymentMethod.credit.apiValue, 'credit');
    });
  });

  group('PaymentMath', () {
    test('change never negative', () {
      expect(PaymentMath.changeOf(paid: 100, total: 80), closeTo(20, 0.001));
      expect(PaymentMath.changeOf(paid: 50, total: 80), 0);
    });

    test('debt never negative', () {
      expect(PaymentMath.debtOf(paid: 50, total: 80), closeTo(30, 0.001));
      expect(PaymentMath.debtOf(paid: 100, total: 80), 0);
    });

    test('parse accepts decimals and rejects garbage', () {
      expect(PaymentMath.parse('12.34'), closeTo(12.34, 0.001));
      expect(PaymentMath.parse('abc'), 0);
      expect(PaymentMath.parse(''), 0);
    });

    test('cash requires paid >= total', () {
      expect(
        PaymentMath.validate(
          method: PaymentMethod.cash,
          total: 100,
          paid: 90,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        'paid_too_low',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.cash,
          total: 100,
          paid: 100,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        isNull,
      );
    });

    test('card requires paid == total', () {
      expect(
        PaymentMath.validate(
          method: PaymentMethod.card,
          total: 50,
          paid: 40,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        'invalid_amount',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.card,
          total: 50,
          paid: 50,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        isNull,
      );
    });

    test('partial requires customer, credit permission, 0 < paid < total', () {
      expect(
        PaymentMath.validate(
          method: PaymentMethod.partial,
          total: 100,
          paid: 40,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        'customer_required',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.partial,
          total: 100,
          paid: 40,
          hasCustomer: true,
          canDiscount: true,
          canCredit: false,
        ),
        'permission_credit',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.partial,
          total: 100,
          paid: 100,
          hasCustomer: true,
          canDiscount: true,
          canCredit: true,
        ),
        'invalid_amount',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.partial,
          total: 100,
          paid: 40,
          hasCustomer: true,
          canDiscount: true,
          canCredit: true,
        ),
        isNull,
      );
    });

    test('credit requires customer + permission + paid ≈ 0', () {
      expect(
        PaymentMath.validate(
          method: PaymentMethod.credit,
          total: 100,
          paid: 0,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        'customer_required',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.credit,
          total: 100,
          paid: 0,
          hasCustomer: true,
          canDiscount: true,
          canCredit: false,
        ),
        'permission_credit',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.credit,
          total: 100,
          paid: 10,
          hasCustomer: true,
          canDiscount: true,
          canCredit: true,
        ),
        'invalid_amount',
      );
      expect(
        PaymentMath.validate(
          method: PaymentMethod.credit,
          total: 100,
          paid: 0,
          hasCustomer: true,
          canDiscount: true,
          canCredit: true,
        ),
        isNull,
      );
    });

    test('empty cart rejected', () {
      expect(
        PaymentMath.validate(
          method: PaymentMethod.cash,
          total: 0,
          paid: 0,
          hasCustomer: false,
          canDiscount: true,
          canCredit: true,
        ),
        'empty_cart_title',
      );
    });

    group('amount due (loyalty reward discount)', () {
      test('amountDueOf subtracts the reward discount and floors at 0', () {
        expect(
          PaymentMath.amountDueOf(total: 100, rewardDiscount: 60),
          closeTo(40, 0.001),
        );
        expect(
          PaymentMath.amountDueOf(total: 100, rewardDiscount: 150),
          0,
        );
        expect(PaymentMath.amountDueOf(total: 100), closeTo(100, 0.001));
      });

      test('change and debt derive from the amount due, not the total', () {
        // total 100, reward discount 60 -> due 40
        expect(
          PaymentMath.changeOf(paid: 50, total: 100, rewardDiscount: 60),
          closeTo(10, 0.001),
        );
        expect(
          PaymentMath.changeOf(paid: 30, total: 100, rewardDiscount: 60),
          0,
        );
        expect(
          PaymentMath.debtOf(paid: 30, total: 100, rewardDiscount: 60),
          closeTo(10, 0.001),
        );
        expect(
          PaymentMath.debtOf(paid: 40, total: 100, rewardDiscount: 60),
          0,
        );
      });

      test('cash requires paid >= amount due', () {
        expect(
          PaymentMath.validate(
            method: PaymentMethod.cash,
            total: 100,
            paid: 39,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 60,
          ),
          'paid_too_low',
        );
        expect(
          PaymentMath.validate(
            method: PaymentMethod.cash,
            total: 100,
            paid: 40,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 60,
          ),
          isNull,
        );
        // Fully discounted: tendering 0 is valid cash.
        expect(
          PaymentMath.validate(
            method: PaymentMethod.cash,
            total: 100,
            paid: 0,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 100,
          ),
          isNull,
        );
      });

      test('card requires paid == amount due', () {
        expect(
          PaymentMath.validate(
            method: PaymentMethod.card,
            total: 100,
            paid: 50,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 60,
          ),
          'invalid_amount',
        );
        expect(
          PaymentMath.validate(
            method: PaymentMethod.card,
            total: 100,
            paid: 40,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 60,
          ),
          isNull,
        );
      });

      test('partial rejects a fully redeemed amount due', () {
        expect(
          PaymentMath.validate(
            method: PaymentMethod.partial,
            total: 100,
            paid: 0,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 100,
          ),
          'invalid_amount',
        );
        expect(
          PaymentMath.validate(
            method: PaymentMethod.partial,
            total: 100,
            paid: 30,
            hasCustomer: true,
            canDiscount: true,
            canCredit: true,
            rewardDiscount: 60,
          ),
          isNull,
        );
      });
    });
  });

  group('CheckoutResult / PriceOverride / models JSON', () {
    test('parses sale create response', () {
      final result = CheckoutResult.fromJson({
        'id': 'sale-1',
        'invoice_number': 'INV-001',
        'status': 'completed',
        'subtotal': '100.00',
        'discount': '10.00',
        'total': '90.00',
        'paid': '100.00',
        'change': '10.00',
        'debt': '0',
        'payment_method': 'cash',
        'idempotent_replay': false,
        'price_overrides': [
          {
            'line_index': 0,
            'product_id': 'p1',
            'requested_unit_price': '9',
            'applied_unit_price': '10',
          },
        ],
      });
      expect(result.invoiceNumber, 'INV-001');
      expect(result.total, '90.00');
      expect(result.priceOverrides, hasLength(1));
      expect(result.priceOverrides.first.appliedUnitPrice, '10');
      // Legacy response without loyalty keys: all five stay null.
      expect(result.amountDue, isNull);
      expect(result.loyaltyPointsEarned, isNull);
      expect(result.loyaltyCashbackEarned, isNull);
      expect(result.loyaltyPointsRedeemed, isNull);
      expect(result.loyaltyRedeemedValue, isNull);
    });

    test('parses the additive loyalty summary fields', () {
      final result = CheckoutResult.fromJson({
        'id': 'sale-3',
        'invoice_number': 'INV-003',
        'status': 'completed',
        'subtotal': '100.00',
        'discount': '0',
        'total': '100.00',
        'paid': '40.00',
        'change': '0',
        'debt': '0',
        'payment_method': 'cash',
        'amount_due': '40.000',
        'loyalty_points_earned': '0',
        'loyalty_cashback_earned': '0.000',
        'loyalty_points_redeemed': '60',
        'loyalty_redeemed_value': '60.000',
      });
      expect(result.amountDue, '40.000');
      expect(result.loyaltyPointsEarned, '0');
      expect(result.loyaltyCashbackEarned, '0.000');
      expect(result.loyaltyPointsRedeemed, '60');
      expect(result.loyaltyRedeemedValue, '60.000');
      // Carried through the override merge (receipt flow).
      final carried = result.withPriceOverrides(const []);
      expect(carried.amountDue, '40.000');
      expect(carried.loyaltyPointsRedeemed, '60');
    });

    test('price override response keeps requested and applied prices', () {
      final result = CheckoutResult.fromJson({
        'id': 'sale-2',
        'invoice_number': 'INV-002',
        'status': 'completed',
        'subtotal': '150.00',
        'discount': '0',
        'total': '150.00',
        'paid': '150.00',
        'change': '0',
        'debt': '0',
        'payment_method': 'cash',
        'price_overrides': [
          {
            'line_index': 0,
            'product_id': 'p9',
            'requested_unit_price': '99.00',
            'applied_unit_price': '150.00',
          },
        ],
      });
      final o = result.priceOverrides.single;
      expect(o.requestedUnitPrice, '99.00');
      expect(o.appliedUnitPrice, '150.00');
      expect(o.productName, isNull);
      final named = o.withProductName('Oil 1L');
      expect(named.productName, 'Oil 1L');
      expect(named.requestedUnitPrice, '99.00');
      expect(named.appliedUnitPrice, '150.00');
      final withNames = result.withPriceOverrides([named]);
      expect(withNames.priceOverrides.single.productName, 'Oil 1L');
      expect(withNames.invoiceNumber, 'INV-002');
    });

    test('parses PosCustomer', () {
      final c = PosCustomer.fromJson({
        'id': 'c1',
        'name': 'Alice',
        'phone': '0555',
        'balance': '12.5',
        'is_archived': false,
      });
      expect(c.name, 'Alice');
      expect(c.balance, closeTo(12.5, 0.001));
    });

    test('parses HoldModel with items', () {
      final hold = HoldModel.fromJson({
        'id': 'h1',
        'device_id': 'd1',
        'customer_id': null,
        'invoice_discount': '5',
        'note': 'park',
        'created_at': '2026-01-01T10:00:00',
        'items': [
          {
            'product_id': 'p1',
            'product_name': 'Milk',
            'quantity': '2',
            'unit_price': '3',
            'line_discount': '0',
          },
        ],
      });
      expect(hold.items, hasLength(1));
      expect(hold.invoiceDiscount, '5');
      expect(hold.items.first.name, 'Milk');
    });
  });

  group('PosCatalogViewMode persistence key', () {
    test('storage key and default values match contract', () {
      expect(kPosCatalogViewModeKey, 'pos_catalog_view_mode');
      expect(PosCatalogViewMode.grid.name, 'grid');
      expect(PosCatalogViewMode.list.name, 'list');
    });
  });
}
