// Phase 8 Step 3 — POS localization coverage across ar/fr/en.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

void main() {
  const posKeys = [
    'pos_subtitle',
    'search_products',
    'scan_barcode_hint',
    'no_products_found',
    'out_of_stock',
    'add_to_cart',
    'cart_empty',
    'cart_empty_hint',
    'remove_line',
    'line_discount',
    'invoice_discount',
    'discount',
    'payment',
    'payment_method',
    'card',
    'partial',
    'amount_paid',
    'amount_due',
    'change',
    'debt',
    'pay',
    'checkout',
    'processing',
    'sale_completed',
    'sale_failed',
    'keep_cart',
    'clear_cart',
    'clear_cart_confirm',
    'customer',
    'select_customer',
    'customer_required',
    'walk_in_customer',
    'search_customers',
    'no_customers_found',
    'select',
    'held_sales',
    'hold_sale',
    'restore_hold',
    'delete_hold',
    'no_holds',
    'hold_saved',
    'hold_restored',
    'favorites',
    'add_favorite',
    'remove_favorite',
    'no_favorites',
    'sale_history',
    'invoice_number',
    'load_sale',
    'no_sales',
    'sale_detail',
    'print',
    'reprint',
    'print_preview',
    'print_failed',
    'copy_invoice',
    'invoice_copied',
    'close',
    'price_override_notice',
    'price_override_dialog_title',
    'price_override_explanation',
    'price_override_client_price',
    'price_override_server_price',
    'price_override_acknowledge',
    'stock_conflict',
    'permission_discount',
    'permission_credit',
    'search_focus',
    'payment_shortcut',
    'hold_shortcut',
    'holds_shortcut',
    'history_shortcut',
    'customer_shortcut',
    'discount_shortcut',
    'clear_shortcut',
    'ready',
    'items_count',
    'line_total',
    'quick_pay',
    'confirm_payment',
    'payment_method_cash_hint',
    'payment_method_card_hint',
    'payment_method_partial_hint',
    'payment_method_credit_hint',
    'invalid_amount',
    'paid_too_low',
    'empty_cart_title',
    'sale_loaded_from_hold',
    'archive_product_pos',
    'show_all_favorites',
    'device',
    'unit_price',
    'base_price',
    'total_label',
    'subtotal_label',
    'catalog_view_grid',
    'catalog_view_list',
    'select_and_add',
    'picker_keyboard_hint',
    'select_unit_hint',
    'select_variant_hint',
    'variant',
    'base_unit',
    'selling_unit',
    'cart_title',
    'cart_no_items',
    'lines_word',
    'units_word',
    'currency',
    'qty_decrease',
    'qty_increase',
    'enter_quantity',
    'retry',
    'network_error_retry',
    'api_error_retry',
    'permission_denied',
    'session_expired_login',
    'validation_error',
    'stock_conflict',
    'cannot_add_out_of_stock',
    // UX FIX #12 — quantity expressions / short base label.
    'invalid_quantity_expression',
    'quantity_too_large',
    'base',
  ];

  group('Phase 8 POS strings', () {
    for (final locale in ['ar', 'fr', 'en']) {
      test('every POS key exists and is non-empty in "$locale"', () {
        for (final key in posKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });
    }

    test('Arabic and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in posKeys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(posKeys.length ~/ 2));
    });

    test('French and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in posKeys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(posKeys.length ~/ 2));
    });

    test('existing payment method keys reused from base set', () {
      expect(AppStrings.t('cash', 'ar'), isNotEmpty);
      expect(AppStrings.t('cash', 'fr'), isNotEmpty);
      expect(AppStrings.t('cash', 'en'), isNotEmpty);
      expect(AppStrings.t('credit', 'en'), isNotEmpty);
    });
  });

  // Phase 12 — the void / return actions exposed from the sale detail
  // dialog. Full coverage lives in returns_localization_test.dart; this
  // group pins the POS-facing subset to the same three-locale contract.
  group('Phase 12 POS keys (sale detail void + return)', () {
    const phase12PosKeys = [
      'void_invoice',
      'void_confirm',
      'void_confirm_question',
      'void_reason_label',
      'void_reason_required',
      'void_success',
      'status_void',
      'return_create',
      'return_mode_linked',
      'return_success',
      'return_replay',
      'return_refund_total',
      'return_credit_reversed',
      'return_cash_pending',
      'return_reason_label',
      'return_reason_required',
      'return_qty_exceeds_sold',
      'error_sale_already_void',
      'error_sale_has_returns',
      'entry_type_sale_void',
      'entry_type_sale_refund',
      'movement_sale_void',
    ];

    for (final locale in ['ar', 'fr', 'en']) {
      test('every Phase 12 POS key exists in "$locale"', () {
        for (final key in phase12PosKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });
    }
  });
}
