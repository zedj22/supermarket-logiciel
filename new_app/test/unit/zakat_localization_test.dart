// Zakat localization — every dynamic key family resolves in ar/fr/en.
//
// The coverage test already scans the families statically; this file
// pins the exact enum/warning/payment vocabularies the zakat feature can
// produce (mirroring `app/domain/zakat.py` + `app/printing/labels.py`)
// so a new backend value with no translation fails here with a precise
// message.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Every warning code `calculate_zakat()` can emit (labels.py keys).
const _warningCodes = <String>[
  'missing_nisab',
  'missing_hawl_start',
  'hawl_start_after_date',
  'hawl_not_completed',
  'missing_inventory',
  'inventory_override_applied',
  'inventory_override_no_reason',
  'inventory_excluded_lines',
  'negative_stock_lines',
  'missing_cash',
  'cash_provided_empty',
  'missing_receivables',
  'doubtful_excluded',
  'receivables_exceed_ledger',
  'debt_due_only_skipped',
  'debt_no_deduction_applied',
  'duplicate_label',
  'negative_net_clamped',
  'provisional_result',
  'below_nisab',
  'gold_price_manual',
  'wholesale_retail_fallback',
];

void main() {
  group('zakat dynamic keys (ar/fr/en)', () {
    test('every warning code resolves to a non-key translation', () {
      for (final code in _warningCodes) {
        final key = 'zakat_warn_$code';
        for (final locale in _locales) {
          final value = AppStrings.t(key, locale);
          expect(value, isNot(key), reason: '$key@$locale untranslated');
        }
      }
    });

    test('debt-treatment / basis / status / nisab-source keys resolve', () {
      const families = <String, List<String>>{
        'zakat_method_': ['deduct_all', 'deduct_due_only', 'no_deduction'],
        'zakat_basis_': ['market', 'cost', 'wholesale', 'override'],
        'zakat_status_': ['final', 'provisional'],
        'zakat_nisab_source_': ['gold_price', 'manual', 'none'],
        'zakat_pay_': ['cash', 'transfer', 'cheque', 'other'],
        'zakat_missing_': [
          'nisab',
          'hawl_start',
          'inventory',
          'cash',
          'receivables',
        ],
        'zakat_eligibility_': [
          'below_nisab',
          'hawl_incomplete',
          'not_eligible',
        ],
      };
      families.forEach((prefix, values) {
        for (final value in values) {
          final key = '$prefix$value';
          for (final locale in _locales) {
            final resolved = AppStrings.t(key, locale);
            expect(resolved, isNot(key), reason: '$key@$locale untranslated');
          }
        }
      });
    });

    test('screen chrome keys resolve', () {
      const keys = [
        'zakat',
        'zakat_title',
        'zakat_tab_calculator',
        'zakat_tab_history',
        'zakat_calculate',
        'zakat_save',
        'zakat_pdf',
        'zakat_disclaimer',
        'zakat_stock_qty',
        'zakat_stock_cost_value',
        'zakat_stock_market_value',
        'zakat_stock_only_zakat',
        'zakat_stock_only_note',
        'zakat_idempotency_conflict',
        'zakat_calculation_not_found',
        'zakat_payment_title',
        'zakat_payment_done',
        'reset',
        'notes',
      ];
      for (final key in keys) {
        for (final locale in _locales) {
          final resolved = AppStrings.t(key, locale);
          expect(resolved, isNot(key), reason: '$key@$locale untranslated');
        }
      }
    });

    test('arabic warning texts match the backend labels.py wording', () {
      // Spot-check the ministry-reference disclaimer + a few warnings so
      // the on-screen text and the PDF report never diverge.
      expect(
        AppStrings.t('zakat_disclaimer', 'ar'),
        contains('marw.gov.dz'),
      );
      expect(
        AppStrings.t('zakat_warn_below_nisab', 'ar'),
        contains('النصاب'),
      );
      expect(
        AppStrings.t('zakat_warn_doubtful_excluded', 'ar'),
        contains('المشكوك'),
      );
      expect(
        AppStrings.t('zakat_rate_note', 'en'),
        '(Amount × 2.5) / 100',
      );
    });
  });
}
