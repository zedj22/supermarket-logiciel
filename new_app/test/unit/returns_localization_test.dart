// Phase 12 (Returns & Voids) localization coverage across ar/fr/en.
//
// Contract (GATE 21): every Phase 12 key resolves to a real translation
// in all three locales (never the raw key — `AppStrings.t` falls back to
// the key itself, which would render `entry_type_sale_void` literally on
// screen), and the three maps are actually localized.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 12 (void, return workflow, errors, ledger
/// entry types and the sale_void movement label).
const _phase12Keys = [
  // Void
  'void_invoice',
  'void_confirm',
  'void_confirm_question',
  'void_reason_label',
  'void_reason_required',
  'void_success',
  'status_void',
  // Return workflow
  'returns_history',
  'return_create',
  'return_mode_linked',
  'return_mode_independent',
  'return_search_invoice',
  'return_search_product',
  'return_search_hint',
  'return_select_product',
  // Return Products multi-product workflow (fix round 1)
  'return_products',
  'return_scan_product',
  'return_selected_products',
  'return_sold_quantity',
  'return_returnable',
  'return_fully_returned',
  'return_qty_label',
  'return_remove',
  'return_add_product',
  'return_no_products',
  'return_product_not_found',
  'return_scan_merged',
  'return_reason_optional',
  'return_reason_none',
  'return_lines',
  'return_no_lines',
  'return_remaining',
  'return_already',
  'return_no_quantity',
  'return_qty_exceeds_sold',
  'return_reason_label',
  'return_reason_required',
  'return_reason',
  'return_all_reasons',
  'return_reason_defective',
  'return_reason_wrong_item',
  'return_reason_customer_change',
  'return_reason_expired',
  'return_reason_other',
  'return_note',
  'return_submit',
  'return_success',
  'return_replay',
  'return_refund_total',
  'return_credit_reversed',
  'return_cash_pending',
  'return_date',
  'no_returns',
  'return_not_found',
  'return_number_copied',
  'copy_return_number',
  'ok',
  // Backend error codes → localized headline
  'error_sale_already_void',
  'error_sale_not_voidable',
  'error_sale_has_returns',
  'error_return_exceeds_sold',
  'error_return_pack_not_whole',
  'error_return_line_invalid',
  'error_idempotency_conflict',
  'return_conflict',
  // Ledger / movement labels (backend entry_type & movement_type)
  'entry_type_sale_void',
  'entry_type_sale_refund',
  'movement_sale_void',
];

/// Existing keys the returns/void UI reuses (must not regress).
const _reusedKeys = [
  'permission_denied',
  'api_error_retry',
  'network_error_retry',
  'validation_error',
  'session_expired_login',
  'refresh',
  'retry',
  'cancel',
  'close',
  'invoice_number',
  'status',
  'total',
  'discount',
  'no_data',
  'invalid_qty',
  'currency',
];

void main() {
  group('Phase 12 returns/voids strings', () {
    for (final locale in _locales) {
      test('every Phase 12 key exists and is non-empty in "$locale"', () {
        for (final key in _phase12Keys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });

      test('reused keys still resolve in "$locale"', () {
        for (final key in _reusedKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing: $key@$locale');
          expect(value, isNot(key), reason: 'raw key: $key@$locale');
        }
      });
    }

    test('Arabic and English Phase 12 translations differ', () {
      var translated = 0;
      for (final key in _phase12Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase12Keys.length ~/ 2));
    });

    test('French and English Phase 12 translations differ', () {
      var translated = 0;
      for (final key in _phase12Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase12Keys.length ~/ 2));
    });

    test('every reason code has a localized label in all three locales', () {
      const reasons = [
        'defective',
        'wrong_item',
        'customer_change',
        'expired',
        'other',
      ];
      for (final locale in _locales) {
        for (final reason in reasons) {
          final key = 'return_reason_$reason';
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing reason label $key@$locale',
          );
        }
      }
    });
  });
}
