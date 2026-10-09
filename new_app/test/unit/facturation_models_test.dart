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
}
