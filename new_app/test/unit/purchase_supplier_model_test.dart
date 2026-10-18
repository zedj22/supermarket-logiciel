// Optional-supplier purchase model normalization.
//
// Contract:
// - `supplier_id: null` and the legacy `''` both normalize to a NULL
//   supplierId (the field used to be non-nullable and defaulted to '');
// - a real id passes through untouched;
// - `supplier_name` stays as received (null = no supplier label).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/purchases/purchase_models.dart';

Map<String, dynamic> _purchaseJson(Map<String, dynamic> overrides) => {
      'id': 'p-1',
      'invoice_number': 'PO-0001',
      'status': 'draft',
      'supplier_id': 'supplier-1',
      'supplier_name': 'Atlas',
      'user_id': null,
      'subtotal': '100.000',
      'discount': '0.000',
      'total': '100.000',
      'paid': '0.000',
      'note': null,
      'device_id': null,
      'client_request_id': null,
      'purchase_date': null,
      'received_at': null,
      'cancelled_at': null,
      'created_at': null,
      'updated_at': null,
      'lines': <dynamic>[],
      'idempotent_replay': false,
      ...overrides,
    };

void main() {
  group('PurchaseModel.supplierId normalization', () {
    test('null supplier_id stays null', () {
      final purchase =
          PurchaseModel.fromJson(_purchaseJson({'supplier_id': null}));
      expect(purchase.supplierId, isNull);
      expect(purchase.supplierName, 'Atlas');
    });

    test("legacy '' supplier_id normalizes to null", () {
      final purchase =
          PurchaseModel.fromJson(_purchaseJson({'supplier_id': ''}));
      expect(purchase.supplierId, isNull);
    });

    test('null supplier_id with null name = no supplier at all', () {
      final purchase = PurchaseModel.fromJson(_purchaseJson({
        'supplier_id': null,
        'supplier_name': null,
      }));
      expect(purchase.supplierId, isNull);
      expect(purchase.supplierName, isNull);
    });

    test('a real supplier id passes through', () {
      final purchase =
          PurchaseModel.fromJson(_purchaseJson({'supplier_id': 's-42'}));
      expect(purchase.supplierId, 's-42');
    });
  });
}
