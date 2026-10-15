// Phase 11 (Purchases) localization coverage across ar/fr/en.
//
// Contract: every Phase 11 purchase key resolves to a real translation
// in all three locales (never the raw key), and the three maps are
// actually localized (values differ across locales).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 11 for purchases (must exist in
/// _arabic / _french / _english).
const _phase11PurchaseKeys = [
  'purchases',
  'add_purchase',
  'edit_purchase',
  'purchase_draft_saved',
  'purchase_received',
  'purchase_updated',
  'purchase_deleted',
  'purchase_cancelled',
  'save_draft',
  'save_and_receive',
  'receive',
  'cancel_purchase',
  'delete_draft',
  'receive_purchase_confirm',
  'cancel_purchase_confirm',
  'delete_draft_confirm',
  'purchase_not_found',
  'purchase_already_received',
  'purchase_already_cancelled',
  'invalid_purchase_state',
  'purchase_line_invalid',
  'purchase_status_draft',
  'purchase_status_received',
  'purchase_status_cancelled',
  'select_product',
  'line_no_variant',
  'invalid_qty',
  'purchase_requires_lines',
  'paid_exceeds_total',
  'discount_exceeds_subtotal',
  'no_purchases',
  'purchase_detail',
  'add_line',
  'edit_line',
  'purchase_lines',
  'supplier',
  'paid',
  'remaining',
  'received_at',
  'cancelled_at',
  'change_product',
];

/// Purchase total-cost mode keys (checkbox, hint, live preview).
const _totalCostKeys = [
  'purchase_total_cost',
  'purchase_total_cost_hint',
  'purchase_preview_total_qty',
];

/// Existing keys Phase 11 purchase screens depend on (must not regress).
const _reusedKeys = [
  'search',
  'search_products',
  'status',
  'all',
  'total',
  'subtotal',
  'discount',
  'quantity',
  'unit_cost',
  'line_total',
  'note',
  'save',
  'cancel',
  'edit',
  'delete',
  'close',
  'no_data',
  'retry',
  'refresh',
  'invoice_number',
  'date',
  'base',
  'variant',
  'purchase_unit',
  'purchase_units_hint',
  'base_unit',
  'select',
  'stock_quantity',
  'no_products_found',
  'field_required',
  'invalid_amount',
  'stock_conflict',
  'permission_denied',
  'network_error_retry',
  'api_error_retry',
  'validation_error',
];

void main() {
  group('Phase 11 purchase strings', () {
    for (final locale in _locales) {
      test('every purchase key exists and is non-empty in "$locale"', () {
        for (final key in _phase11PurchaseKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });

      test('every reused key resolves in "$locale"', () {
        for (final key in _reusedKeys) {
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

    test('purchase key set is identical across ar / fr / en', () {
      final maps = <String, Map<String, String>>{};
      for (final locale in _locales) {
        maps[locale] = {
          for (final key in _phase11PurchaseKeys) key: AppStrings.t(key, locale),
        };
      }
      for (final key in _phase11PurchaseKeys) {
        final values = _locales
            .map((l) => maps[l]![key]!)
            .where((v) => v != key && v.isNotEmpty)
            .toList();
        expect(
          values.length,
          3,
          reason: 'key not defined in every locale: $key',
        );
      }
    });

    test('Arabic and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in _phase11PurchaseKeys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase11PurchaseKeys.length ~/ 2));
    });

    test('French and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in _phase11PurchaseKeys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase11PurchaseKeys.length ~/ 2));
    });

    test('Arabic values contain Arabic script (no copy-paste English)', () {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      var withArabic = 0;
      for (final key in _phase11PurchaseKeys) {
        if (arabic.hasMatch(AppStrings.t(key, 'ar'))) withArabic++;
      }
      expect(withArabic, greaterThan(_phase11PurchaseKeys.length ~/ 2));
    });

    test('lifecycle status labels match the phase 11 spec', () {
      const expected = {
        'ar': {
          'purchase_status_draft': 'مسودة',
          'purchase_status_received': 'مستلم',
          'purchase_status_cancelled': 'ملغي',
        },
        'fr': {
          'purchase_status_draft': 'Brouillon',
          'purchase_status_received': 'Reçu',
          'purchase_status_cancelled': 'Annulé',
        },
        'en': {
          'purchase_status_draft': 'Draft',
          'purchase_status_received': 'Received',
          'purchase_status_cancelled': 'Cancelled',
        },
      };
      expected.forEach((locale, entries) {
        entries.forEach((key, value) {
          expect(
            AppStrings.t(key, locale),
            value,
            reason: '$key@$locale',
          );
        });
      });
    });

    test('lifecycle action labels exist in every locale', () {
      for (final key in [
        'save_draft',
        'save_and_receive',
        'receive',
        'cancel_purchase',
        'delete_draft',
      ]) {
        for (final locale in _locales) {
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: '$key@$locale',
          );
        }
      }
    });

    test('structured purchase error codes resolve to localized copy', () {
      // Codes must map to real translations — the purchases error
      // mapper looks these keys up by envelope code.
      const errorKeys = [
        'purchase_already_received',
        'purchase_already_cancelled',
        'invalid_purchase_state',
        'purchase_line_invalid',
        'purchase_not_found',
        'stock_conflict',
        'validation_error',
      ];
      for (final key in errorKeys) {
        for (final locale in _locales) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing: $key@$locale');
          expect(value, isNot(key), reason: 'untranslated: $key@$locale');
        }
      }
    });

    test('total-cost mode labels exist in every locale', () {
      for (final key in _totalCostKeys) {
        for (final locale in _locales) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(value, isNot(key), reason: 'untranslated: $key@$locale');
        }
      }
    });

    test('total-cost checkbox label matches the feature spec', () {
      expect(AppStrings.t('purchase_total_cost', 'ar'), 'التكلفة الإجمالية');
      expect(AppStrings.t('purchase_total_cost', 'fr'), 'Coût total');
      expect(AppStrings.t('purchase_total_cost', 'en'), 'Total cost');
    });
  });
}
