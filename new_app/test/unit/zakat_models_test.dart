// Zakat models — wire contract, money-as-strings, key helpers.
//
// The client never multiplies money: every figure travels as the
// backend's decimal string and the helpers only build localization keys
// mirroring `app/domain/zakat.py` enum values / warning codes.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/zakat/zakat_models.dart';

void main() {
  group('ZakatCalculationInput.toJson', () {
    test('omits empty optionals and trims notes', () {
      const input = ZakatCalculationInput(
        zakatDate: '2026-10-16',
        notes: '  hello  ',
      );
      final json = input.toJson();
      expect(json['zakat_date'], '2026-10-16');
      expect(json['inventory_basis'], 'market');
      expect(json['debt_treatment'], 'deduct_all');
      expect(json['use_imported_inventory'], true);
      expect(json['cash_provided'], false);
      expect(json['notes'], 'hello');
      expect(json.containsKey('hawl_start_date'), isFalse);
      expect(json.containsKey('gold_price_per_gram'), isFalse);
      expect(json.containsKey('nisab_override'), isFalse);
      expect(json.containsKey('collectible_receivables'), isFalse);
      expect(json.containsKey('cash_items'), isFalse);
      expect(json.containsKey('liability_items'), isFalse);
    });

    test('override basis carries value + reason only when set', () {
      const withReason = ZakatCalculationInput(
        zakatDate: '2026-10-16',
        inventoryBasis: 'override',
        inventoryOverrideValue: '5000.000',
        inventoryOverrideReason: ' stocktake ',
      );
      final json = withReason.toJson();
      expect(json['inventory_override_value'], '5000.000');
      expect(json['inventory_override_reason'], 'stocktake');

      const without = ZakatCalculationInput(
        zakatDate: '2026-10-16',
        inventoryBasis: 'override',
      );
      final bare = without.toJson();
      expect(bare.containsKey('inventory_override_value'), isFalse);
      expect(bare.containsKey('inventory_override_reason'), isFalse);
    });

    test('line items serialize label/amount/due', () {
      const input = ZakatCalculationInput(
        zakatDate: '2026-10-16',
        cashProvided: true,
        cashItems: [ZakatLineInput(label: 'Caisse', amount: '120.500')],
        liabilityItems: [
          ZakatLineInput(label: 'Fournisseur', amount: '300', due: false),
          ZakatLineInput(label: 'Dette', amount: '50'),
        ],
      );
      final json = input.toJson();
      final cash = (json['cash_items'] as List).cast<Map<String, dynamic>>();
      expect(cash.single['label'], 'Caisse');
      expect(cash.single['amount'], '120.500');
      expect(cash.single.containsKey('due'), isFalse);

      final liabilities =
          (json['liability_items'] as List).cast<Map<String, dynamic>>();
      expect(liabilities.first['due'], false);
      expect(liabilities.last.containsKey('due'), isFalse);
    });

    test('fromJson round-trips a full payload', () {
      const input = ZakatCalculationInput(
        zakatDate: '2026-10-16',
        hawlStartDate: '2025-10-01',
        goldPricePerGram: '27000',
        inventoryBasis: 'cost',
        useImportedInventory: false,
        excludedProductIds: ['p1', 'p2'],
        cashProvided: true,
        cashItems: [ZakatLineInput(label: 'Caisse', amount: '10')],
        collectibleReceivables: '200.000',
        doubtfulReceivables: '50.000',
        debtTreatment: 'deduct_due_only',
        liabilityItems: [
          ZakatLineInput(label: 'AP', amount: '80.000', due: true),
        ],
        notes: 'n1',
      );
      final back = ZakatCalculationInput.fromJson(input.toJson());
      expect(back.zakatDate, input.zakatDate);
      expect(back.hawlStartDate, input.hawlStartDate);
      expect(back.goldPricePerGram, input.goldPricePerGram);
      expect(back.inventoryBasis, 'cost');
      expect(back.useImportedInventory, isFalse);
      expect(back.excludedProductIds, ['p1', 'p2']);
      expect(back.cashProvided, isTrue);
      expect(back.cashItems.single.amount, '10');
      expect(back.collectibleReceivables, '200.000');
      expect(back.doubtfulReceivables, '50.000');
      expect(back.debtTreatment, 'deduct_due_only');
      expect(back.liabilityItems.single.due, isTrue);
      expect(back.notes, 'n1');
    });
  });

  group('ZakatResult.fromJson', () {
    Map<String, dynamic> resultJson() => <String, dynamic>{
          'zakat_date': '2026-10-16',
          'status': 'final',
          'missing_fields': <dynamic>[],
          'warnings': [
            {
              'code': 'BELOW_NISAB',
              'detail': {'net': '100.000', 'nisab': '2295000.000'},
            },
            {'code': 'DUPLICATE_LABEL', 'detail': <String, dynamic>{}},
          ],
          'hawl_start_date': '2025-10-01',
          'hawl_days_elapsed': 380,
          'hawl_completed': true,
          'gold_price_per_gram': '27000.000',
          'nisab_amount': '2295000.000',
          'nisab_source': 'gold_price',
          'inventory_basis': 'market',
          'inventory_value': '5000.000',
          'inventory_source': 'imported',
          'inventory_imported_value': '5000.000',
          'inventory_excluded_value': '0.000',
          'inventory_product_count': 12,
          'inventory_included_count': 12,
          'cash_provided': true,
          'cash_total': '300.000',
          'cash_item_count': 1,
          'collectible_receivables': '200.000',
          'doubtful_receivables': '50.000',
          'other_receivables_total': '0.000',
          'receivables_included_total': '200.000',
          'receivable_item_count': 0,
          'debt_treatment': 'deduct_all',
          'liabilities_total_entered': '400.000',
          'deductions_applied': '400.000',
          'liabilities_skipped_amount': '0.000',
          'liabilities_skipped_count': 0,
          'liability_item_count': 1,
          'net_zakatable': '5100.000',
          'zakat_rate': '0.025',
          'zakat_due': '127.500',
          'provisional_zakat_due': null,
          'reaches_nisab': false,
          'eligibility_reasons': ['BELOW_NISAB'],
        };

    test('parses money as strings and maps warnings to label keys', () {
      final result = ZakatResult.fromJson(resultJson());
      expect(result.status, 'final');
      expect(result.isProvisional, isFalse);
      expect(result.netZakatable, '5100.000');
      expect(result.zakatDue, '127.500');
      expect(result.nisabAmount, '2295000.000');
      expect(result.nisabSource, 'gold_price');
      expect(result.warnings, hasLength(2));
      expect(result.warnings.first.labelKey, 'zakat_warn_below_nisab');
      expect(result.warnings.first.detail['net'], '100.000');
      expect(result.warnings.last.labelKey, 'zakat_warn_duplicate_label');
      expect(result.eligibilityReasons, ['BELOW_NISAB']);
    });

    test('provisional result keeps zakat_due null and carries a warning', () {
      final json = resultJson()
        ..['status'] = 'provisional'
        ..['zakat_due'] = null
        ..['provisional_zakat_due'] = '127.500'
        ..['missing_fields'] = ['nisab', 'cash'];
      final result = ZakatResult.fromJson(json);
      expect(result.isProvisional, isTrue);
      expect(result.zakatDue, isNull);
      expect(result.provisionalZakatDue, '127.500');
      expect(result.missingFields, ['nisab', 'cash']);
    });
  });

  group('ZakatContext.fromJson', () {
    test('parses official reference + imported totals + ledgers', () {
      final context = ZakatContext.fromJson(<String, dynamic>{
        'store_name': 'Klick Market',
        'store_phone': '0555',
        'store_address': 'Alger',
        'today': '2026-10-16',
        'official_nisab_reference': {
          'hijri_year': 1447,
          'amount': '2295000.000',
          'gold_price_per_gram': '27000.000',
          'purity': '18k',
          'source': 'AGENOR',
          'note': 'official',
        },
        'defaults': {
          'zakat_rate': '0.025',
          'hawl_days': 354,
          'nisab_gold_grams': '85',
          'inventory_basis': 'market',
          'debt_treatment': 'deduct_all',
        },
        'inventory': {
          'product_count': 3,
          'total_market_value': '900.000',
          'total_cost_value': '600.000',
          'truncated': false,
          'lines': <dynamic>[],
        },
        'receivables_reference': {
          'ledger_total': '1500.000',
          'debtor_count': 2,
          'debtors': <dynamic>[],
        },
        'liabilities_reference': {
          'supplier_balance_total': '800.000',
          'supplier_count': 1,
          'suppliers': <dynamic>[],
        },
      });
      expect(context.storeName, 'Klick Market');
      expect(context.today, '2026-10-16');
      expect(context.officialNisabReference.hijriYear, 1447);
      expect(context.officialNisabReference.amount, '2295000.000');
      expect(context.defaults.hawlDays, 354);
      expect(context.inventory.totalMarketValue, '900.000');
      expect(context.receivablesReference.ledgerTotal, '1500.000');
      expect(context.liabilitiesReference.supplierBalanceTotal, '800.000');
    });
  });

  group('history + detail models', () {
    test('summary parses money and tri-state booleans', () {
      final summary = ZakatCalculationSummary.fromJson(<String, dynamic>{
        'id': 'z1',
        'zakat_date': '2026-10-16',
        'status': 'final',
        'net_zakatable': '5100.000',
        'zakat_due': '127.500',
        'provisional_zakat_due': null,
        'nisab_amount': '2295000.000',
        'reaches_nisab': false,
        'hawl_completed': true,
        'payments_total': '100.000',
        'notes': null,
        'created_by': 'u1',
        'created_at': '2026-10-16T10:00:00Z',
      });
      expect(summary.id, 'z1');
      expect(summary.zakatDue, '127.500');
      expect(summary.paymentsTotal, '100.000');
      expect(summary.reachesNisab, isFalse);
      expect(summary.hawlCompleted, isTrue);
    });

    test('page envelope parses items + pagination', () {
      final page = ZakatCalculationPage.fromJson(<String, dynamic>{
        'items': [
          {
            'id': 'z1',
            'zakat_date': '2026-10-16',
            'status': 'final',
            'net_zakatable': '1.000',
            'payments_total': '0.000',
            'created_at': '2026-10-16T10:00:00Z',
          },
        ],
        'total': 41,
        'page': 2,
        'page_size': 40,
        'pages': 2,
      });
      expect(page.items, hasLength(1));
      expect(page.total, 41);
      expect(page.page, 2);
      expect(page.pages, 2);
    });

    test('detail carries stored result + inputs + payments', () {
      final detail = ZakatCalculationDetail.fromJson(<String, dynamic>{
        'id': 'z1',
        'zakat_date': '2026-10-16',
        'status': 'final',
        'net_zakatable': '5100.000',
        'zakat_due': '127.500',
        'payments_total': '50.000',
        'created_at': '2026-10-16T10:00:00Z',
        'result': {
          'zakat_date': '2026-10-16',
          'status': 'final',
          'missing_fields': <dynamic>[],
          'warnings': <dynamic>[],
          'net_zakatable': '5100.000',
          'zakat_rate': '0.025',
          'zakat_due': '127.500',
          'inventory_basis': 'market',
          'inventory_source': 'imported',
          'debt_treatment': 'deduct_all',
        },
        'inputs': {
          'zakat_date': '2026-10-16',
          'inventory_basis': 'market',
          'debt_treatment': 'deduct_all',
          'use_imported_inventory': true,
          'cash_provided': true,
        },
        'payments': [
          {
            'id': 'p1',
            'calculation_id': 'z1',
            'amount': '50.000',
            'method': 'cash',
            'paid_at': '2026-10-16',
            'note': null,
            'created_by': 'u1',
            'created_at': '2026-10-16T11:00:00Z',
          },
        ],
      });
      expect(detail.result.netZakatable, '5100.000');
      expect(detail.inputs.zakatDate, '2026-10-16');
      expect(detail.payments.single.method, 'cash');
      expect(detail.payments.single.amount, '50.000');
    });
  });

  group('label key helpers', () {
    test('build keys mirroring backend enum values', () {
      expect(zakatStatusKey('final'), 'zakat_status_final');
      expect(zakatStatusKey('provisional'), 'zakat_status_provisional');
      expect(zakatNisabSourceKey('gold_price'), 'zakat_nisab_source_gold_price');
      expect(zakatNisabSourceKey(null), 'zakat_nisab_source_none');
      expect(zakatBasisKey('market'), 'zakat_basis_market');
      expect(zakatMethodKey('deduct_all'), 'zakat_method_deduct_all');
      expect(zakatPaymentMethodKey('cheque'), 'zakat_pay_cheque');
      expect(zakatMissingFieldKey('hawl_start'), 'zakat_missing_hawl_start');
      expect(
        zakatEligibilityKey('HAWL_INCOMPLETE'),
        'zakat_eligibility_hawl_incomplete',
      );
    });
  });
}
