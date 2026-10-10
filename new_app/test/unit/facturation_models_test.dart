// Phase 8 facturation — model unit tests.
//
// Decimal-string money, integer-milli display math, draft-line payload
// shaping, and JSON round-trips for every wire model.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/facturation/facturation_models.dart';

void main() {
  group('qtyToMilli', () {
    test('parses whole and fractional quantities', () {
      expect(qtyToMilli('1'), 1000);
      expect(qtyToMilli('2.5'), 2500);
      expect(qtyToMilli('0.125'), 125);
      expect(qtyToMilli('10.000'), 10000);
    });

    test('rejects empty, negative, and over-precision input', () {
      expect(qtyToMilli(''), isNull);
      expect(qtyToMilli('-1'), isNull);
      expect(qtyToMilli('1.0001'), isNull);
      expect(qtyToMilli('abc'), isNull);
    });
  });

  group('pctToMilli', () {
    test('parses percentages in thousandths', () {
      expect(pctToMilli('0'), 0);
      expect(pctToMilli('10'), 10000);
      expect(pctToMilli('10.5'), 10500);
      expect(pctToMilli('100'), 100000);
    });

    test('rejects empty, over-100, and malformed input', () {
      expect(pctToMilli(''), isNull);
      expect(pctToMilli('101'), isNull);
      expect(pctToMilli('abc'), isNull);
    });
  });

  group('DraftInvoiceLine display math', () {
    test('line HT without discount: qty × price', () {
      const line = DraftInvoiceLine(
        description: 'Widget',
        quantity: '2',
        unitPriceHt: '10.000',
        tvaRate: 19,
      );
      expect(line.lineHtMilli, 20000);
      expect(line.lineHt, '20.000');
      // 19% of 20.000 = 3.800
      expect(line.lineTvaMilli, 3800);
      expect(line.lineTva, '3.800');
    });

    test('line HT with 10% discount', () {
      const line = DraftInvoiceLine(
        description: 'Widget',
        quantity: '1',
        unitPriceHt: '100.000',
        tvaRate: 0,
        discountPct: '10',
      );
      expect(line.lineHtMilli, 90000);
      expect(line.lineHt, '90.000');
      expect(line.lineTvaMilli, 0);
    });

    test('line with fractional quantity', () {
      const line = DraftInvoiceLine(
        description: 'Weighted',
        quantity: '1.5',
        unitPriceHt: '4.000',
        tvaRate: 9,
      );
      expect(line.lineHtMilli, 6000);
      // 9% of 6.000 = 0.540
      expect(line.lineTvaMilli, 540);
    });

    test('zero for unparseable inputs (display only)', () {
      const line = DraftInvoiceLine(
        description: 'Broken',
        quantity: 'x',
        unitPriceHt: 'y',
      );
      expect(line.lineHtMilli, 0);
      expect(line.lineTvaMilli, 0);
    });
  });

  group('DraftInvoiceLine.toPayload', () {
    test('product line: product_id + qty + optional prefill overrides', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        productName: 'Widget',
        description: 'Widget',
        quantity: '2',
        unitPriceHt: '10.000',
        tvaRate: 19,
        discountPct: '5',
      );
      final payload = line.toPayload();
      expect(payload['product_id'], 'p1');
      expect(payload['quantity'], '2');
      expect(payload['unit_price_ht'], '10.000');
      expect(payload['tva_rate'], '19');
      expect(payload['discount_pct'], '5');
      // description is NOT sent for product lines (server prefills).
      expect(payload.containsKey('description'), isFalse);
    });

    test('free-text line: description + unit_price_ht + tva_rate required', () {
      const line = DraftInvoiceLine(
        description: 'Custom service',
        quantity: '1',
        unitPriceHt: '50.000',
        tvaRate: 0,
      );
      final payload = line.toPayload();
      expect(payload.containsKey('product_id'), isFalse);
      expect(payload['description'], 'Custom service');
      expect(payload['quantity'], '1');
      expect(payload['unit_price_ht'], '50.000');
      expect(payload['tva_rate'], '0');
      expect(payload['discount_pct'], '0');
    });

    test('empty discount defaults to "0"', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        description: 'Widget',
        quantity: '1',
        unitPriceHt: '1.000',
      );
      expect(line.toPayload()['discount_pct'], '0');
    });
  });

  group('InvoiceClientModel.fromJson', () {
    test('parses full fiscal identity', () {
      final model = InvoiceClientModel.fromJson({
        'id': 'ic1',
        'name': 'SARL Example',
        'address': '1 Rue de la Paix',
        'wilaya': 'Alger',
        'phone': '0555112233',
        'nif': 'NIF-001',
        'rc': 'RC-002',
        'ai': 'AI-003',
        'nis': 'NIS-004',
        'is_archived': false,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-02T00:00:00Z',
      });
      expect(model.id, 'ic1');
      expect(model.name, 'SARL Example');
      expect(model.wilaya, 'Alger');
      expect(model.nif, 'NIF-001');
      expect(model.rc, 'RC-002');
      expect(model.ai, 'AI-003');
      expect(model.nis, 'NIS-004');
      expect(model.isArchived, isFalse);
      expect(model.createdAt, isNotNull);
    });

    test('defaults optional fields to null', () {
      final model = InvoiceClientModel.fromJson({'id': 'ic2', 'name': 'X'});
      expect(model.address, isNull);
      expect(model.wilaya, isNull);
      expect(model.nif, isNull);
      expect(model.isArchived, isFalse);
    });
  });

  group('InvoiceDocumentModel.fromJson', () {
    test('parses identity, flags, lines and server totals', () {
      final model = InvoiceDocumentModel.fromJson({
        'id': 'd1',
        'doc_type': 'FAC',
        'year': 2026,
        'number': 'FAC-2026-0001',
        'document_date': '2026-03-15',
        'client_id': 'ic1',
        'client': {
          'id': 'ic1',
          'name': 'SARL Example',
          'address': null,
          'wilaya': null,
          'phone': null,
          'nif': null,
          'rc': null,
          'ai': null,
          'nis': null,
          'is_archived': false,
          'created_at': null,
          'updated_at': null,
        },
        'payment_method': 'cash',
        'notes': 'hello',
        'show_discount': true,
        'show_tva': true,
        'show_timbre': false,
        'show_payment_method': true,
        'show_amount_words': true,
        'lines': [
          {
            'id': 'l1',
            'product_id': 'p1',
            'description': 'Widget',
            'quantity': '2',
            'unit_price_ht': '10.000',
            'tva_rate': '19.000',
            'discount_pct': '0.000',
            'position': 0,
            'total_ht': '20.000',
            'total_tva': '3.800',
          },
        ],
        'totals': {
          'total_ht': '20.000',
          'total_tva': '3.800',
          'total_ttc': '23.800',
          'timbre': '1.000',
          'net_a_payer': '24.800',
        },
        'amount_in_words': 'vingt-quatre dinars…',
        'created_at': '2026-03-15T10:00:00Z',
        'updated_at': null,
      });
      expect(model.id, 'd1');
      expect(model.docType, DocTypeValue.fac);
      expect(model.number, 'FAC-2026-0001');
      expect(model.client?.name, 'SARL Example');
      expect(model.showTimbre, isFalse);
      expect(model.lines, hasLength(1));
      expect(model.lines.first.tvaRate, '19.000');
      expect(model.totals.netAPayer, '24.800');
      expect(model.amountInWords, isNotEmpty);
    });
  });

  group('InvoiceDocumentPreviewModel.fromJson', () {
    test('parses dry-run response (proposed number, no ids)', () {
      final model = InvoiceDocumentPreviewModel.fromJson({
        'document_date': '2026-03-15',
        'year': 2026,
        'number': 'FAC-2026-0042',
        'client_id': 'ic1',
        'client': {
          'id': 'ic1',
          'name': 'SARL Example',
          'is_archived': false,
        },
        'lines': [
          {
            'product_id': null,
            'description': 'Free text',
            'quantity': '1',
            'unit_price_ht': '100.000',
            'tva_rate': '0.000',
            'discount_pct': '0.000',
            'position': 0,
            'total_ht': '100.000',
            'total_tva': '0.000',
          },
        ],
        'totals': {
          'total_ht': '100.000',
          'total_tva': '0.000',
          'total_ttc': '100.000',
          'timbre': '1.000',
          'net_a_payer': '101.000',
        },
        'amount_in_words': 'cent-un dinars…',
      });
      expect(model.number, 'FAC-2026-0042');
      expect(model.year, 2026);
      expect(model.lines, hasLength(1));
      expect(model.lines.first.productId, isNull);
      expect(model.totals.netAPayer, '101.000');
    });
  });

  group('domain value sets', () {
    test('doc types and payment methods match backend membership', () {
      expect(DocTypeValue.all, ['FAC', 'DEV', 'PRO', 'BC', 'BL']);
      expect(PaymentMethodValue.all, ['cash', 'transfer', 'cheque']);
      expect(kTvaRates, [0, 9, 19]);
    });
  });

  // ---------------------------------------------------------------------
  // Stage 3A — option identity (variant / selling unit / pack)
  // ---------------------------------------------------------------------

  group('DraftInvoiceLine option payloads', () {
    test('variant line: product_id + variant_id, no unit/pack keys', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        productName: 'Coca Cola',
        variantId: 'v1',
        variantName: 'Big',
        description: 'Coca Cola · Big',
        quantity: '2',
        unitPriceHt: '120.000',
        tvaRate: 19,
      );
      final payload = line.toPayload();
      expect(payload['product_id'], 'p1');
      expect(payload['variant_id'], 'v1');
      expect(payload.containsKey('selling_unit_id'), isFalse);
      expect(payload.containsKey('pack_id'), isFalse);
      expect(payload['quantity'], '2');
      // description is NOT sent — the server prefills "Product · Variant".
      expect(payload.containsKey('description'), isFalse);
    });

    test('selling-unit line: product_id + selling_unit_id, no variant', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        sellingUnitId: 'u1',
        sellingUnitName: 'Box',
        description: 'Coca Cola · Box',
        quantity: '1',
        unitPriceHt: '2200.000',
        tvaRate: 19,
      );
      final payload = line.toPayload();
      expect(payload['product_id'], 'p1');
      expect(payload['selling_unit_id'], 'u1');
      expect(payload.containsKey('variant_id'), isFalse);
      expect(payload.containsKey('pack_id'), isFalse);
    });

    test('pack line: pack_id only — no product/variant/unit keys', () {
      // Empty price + null tva → the server's pack prefill wins.
      const line = DraftInvoiceLine(
        packId: 'k1',
        packName: 'Pack Promo',
        description: 'Pack Promo',
        quantity: '1',
        unitPriceHt: '',
      );
      final payload = line.toPayload();
      expect(payload['pack_id'], 'k1');
      expect(payload.containsKey('product_id'), isFalse);
      expect(payload.containsKey('variant_id'), isFalse);
      expect(payload.containsKey('selling_unit_id'), isFalse);
      expect(payload['quantity'], '1');
      // Pack lines are NOT free-text: description is optional (server
      // prefills the pack name) but sent when the user typed one.
      expect(payload.containsKey('description'), isFalse);
      expect(payload.containsKey('unit_price_ht'), isFalse);
      expect(payload.containsKey('tva_rate'), isFalse);
      expect(payload['discount_pct'], '0');
    });

    test('pack line with user overrides sends price and tva', () {
      const line = DraftInvoiceLine(
        packId: 'k1',
        description: 'Pack Promo',
        quantity: '2',
        unitPriceHt: '260.000',
        tvaRate: 19,
      );
      final payload = line.toPayload();
      expect(payload['unit_price_ht'], '260.000');
      expect(payload['tva_rate'], '19');
    });

    test('variant and selling unit are mutually exclusive in payload', () {
      // The dialog clears the sibling on selection; the payload guard
      // sends both only when both are somehow present (server rejects).
      const line = DraftInvoiceLine(
        productId: 'p1',
        variantId: 'v1',
        sellingUnitId: 'u1',
        description: 'Coca Cola',
        quantity: '1',
        unitPriceHt: '1.000',
        tvaRate: 0,
      );
      final payload = line.toPayload();
      expect(payload['variant_id'], 'v1');
      expect(payload['selling_unit_id'], 'u1');
    });

    test('isFreeText excludes pack lines', () {
      const packLine = DraftInvoiceLine(
        packId: 'k1',
        description: 'Pack',
        quantity: '1',
        unitPriceHt: '10.000',
      );
      expect(packLine.isFreeText, isFalse);
      expect(packLine.isPackLine, isTrue);

      const freeText = DraftInvoiceLine(
        description: 'Services',
        quantity: '1',
        unitPriceHt: '50.000',
        tvaRate: 9,
      );
      expect(freeText.isFreeText, isTrue);
      expect(freeText.isPackLine, isFalse);

      const variantLine = DraftInvoiceLine(
        productId: 'p1',
        variantId: 'v1',
        description: 'Coca Cola · Big',
        quantity: '1',
        unitPriceHt: '1.000',
      );
      expect(variantLine.isFreeText, isFalse);
    });

    test('copyWith clearOption resets variant and unit, keeps product', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        productName: 'Coca',
        variantId: 'v1',
        variantName: 'Big',
        description: 'Coca · Big',
        quantity: '1',
        unitPriceHt: '1.000',
        tvaRate: 19,
      );
      final cleared = line.copyWith(clearOption: true);
      expect(cleared.productId, 'p1');
      expect(cleared.variantId, isNull);
      expect(cleared.variantName, isNull);
      expect(cleared.sellingUnitId, isNull);
      expect(cleared.tvaRate, 19);
    });

    test('copyWith clearProduct resets product, options and pack', () {
      const line = DraftInvoiceLine(
        productId: 'p1',
        variantId: 'v1',
        packId: 'k1',
        description: 'X',
        quantity: '1',
        unitPriceHt: '1.000',
      );
      final cleared = line.copyWith(clearProduct: true);
      expect(cleared.productId, isNull);
      expect(cleared.variantId, isNull);
      expect(cleared.packId, isNull);
      expect(cleared.packName, isNull);
    });
  });

  group('InvoiceLineModel.fromJson option ids', () {
    test('parses variant_id, selling_unit_id and pack_id', () {
      final line = InvoiceLineModel.fromJson({
        'id': 'l1',
        'product_id': 'p1',
        'variant_id': 'v1',
        'selling_unit_id': null,
        'pack_id': null,
        'description': 'Coca Cola · Big',
        'quantity': '2',
        'unit_price_ht': '120.000',
        'tva_rate': '19.000',
        'discount_pct': '0.000',
        'position': 0,
        'total_ht': '240.000',
        'total_tva': '45.600',
      });
      expect(line.variantId, 'v1');
      expect(line.sellingUnitId, isNull);
      expect(line.packId, isNull);
    });

    test('pack line: product_id null, pack_id set', () {
      final line = InvoiceLineModel.fromJson({
        'id': 'l2',
        'product_id': null,
        'variant_id': null,
        'selling_unit_id': null,
        'pack_id': 'k1',
        'description': 'Pack Promo',
        'quantity': '1',
        'unit_price_ht': '250.000',
        'tva_rate': '0.000',
        'discount_pct': '0.000',
        'position': 0,
        'total_ht': '250.000',
        'total_tva': '0.000',
      });
      expect(line.productId, isNull);
      expect(line.packId, 'k1');
    });

    test('legacy line without option keys defaults to null', () {
      final line = InvoiceLineModel.fromJson({
        'id': 'l3',
        'product_id': 'p1',
        'description': 'Widget',
        'quantity': '1',
        'unit_price_ht': '10.000',
        'tva_rate': '19.000',
        'discount_pct': '0.000',
        'position': 0,
        'total_ht': '10.000',
        'total_tva': '1.900',
      });
      expect(line.variantId, isNull);
      expect(line.sellingUnitId, isNull);
      expect(line.packId, isNull);
    });
  });

  group('InvoiceLinePreviewModel.fromJson option ids', () {
    test('parses the same option identity as the persisted line', () {
      final line = InvoiceLinePreviewModel.fromJson({
        'product_id': 'p1',
        'variant_id': null,
        'selling_unit_id': 'u1',
        'pack_id': null,
        'description': 'Coca Cola · Box',
        'quantity': '1',
        'unit_price_ht': '2200.000',
        'tva_rate': '19.000',
        'discount_pct': '0.000',
        'position': 0,
        'total_ht': '2200.000',
        'total_tva': '418.000',
      });
      expect(line.sellingUnitId, 'u1');
      expect(line.variantId, isNull);
      expect(line.packId, isNull);
    });
  });
}
