// Phase 11 (Suppliers) localization coverage across ar/fr/en.
//
// Contract: every Phase 11 supplier key resolves to a real translation
// in all three locales (never the raw key), and the three maps are
// actually localized (values differ across locales).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 11 for suppliers (must exist in
/// _arabic / _french / _english).
const _phase11SupplierKeys = [
  'suppliers',
  'add_supplier',
  'edit_supplier',
  'supplier_created',
  'supplier_updated',
  'supplier_archived',
  'archive_supplier_confirm',
  'supplier_not_found',
  'supplier_is_archived',
  'outstanding_supplier_balance',
  'supplier_payment_exceeds',
  'select_supplier_hint',
  'select_supplier',
  'supplier_ledger',
  'supplier_entry_type_purchase',
  'supplier_entry_type_payment',
  'supplier_entry_type_purchase_cancel',
  'record_supplier_payment',
  'supplier_payment_success',
  'contact_person',
  'email',
  'no_ledger_entries',
];

/// Existing keys Phase 11 supplier screens depend on (must not regress).
const _reusedKeys = [
  'balance',
  'name',
  'phone',
  'address',
  'note',
  'note_hint',
  'amount',
  'pay_all',
  'remaining_after',
  'record_payment',
  'balance_after',
  'invoice_number',
  'save',
  'cancel',
  'edit',
  'delete',
  'archive',
  'archived',
  'show_archived',
  'search',
  'total',
  'retry',
  'refresh',
  'no_data',
  'loading',
  'field_required',
  'invalid_amount',
  'permission_denied',
  'network_error_retry',
  'api_error_retry',
  'validation_error',
];

void main() {
  group('Phase 11 supplier strings', () {
    for (final locale in _locales) {
      test('every supplier key exists and is non-empty in "$locale"', () {
        for (final key in _phase11SupplierKeys) {
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

    test('supplier key set is identical across ar / fr / en', () {
      final maps = <String, Map<String, String>>{};
      for (final locale in _locales) {
        maps[locale] = {
          for (final key in _phase11SupplierKeys) key: AppStrings.t(key, locale),
        };
      }
      for (final key in _phase11SupplierKeys) {
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
      for (final key in _phase11SupplierKeys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase11SupplierKeys.length ~/ 2));
    });

    test('French and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in _phase11SupplierKeys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase11SupplierKeys.length ~/ 2));
    });

    test('Arabic values contain Arabic script (no copy-paste English)', () {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      var withArabic = 0;
      for (final key in _phase11SupplierKeys) {
        if (arabic.hasMatch(AppStrings.t(key, 'ar'))) withArabic++;
      }
      expect(withArabic, greaterThan(_phase11SupplierKeys.length ~/ 2));
    });

    test('supplier ledger entry-type keys cover every ledger type', () {
      for (final type in ['purchase', 'payment', 'purchase_cancel']) {
        for (final locale in _locales) {
          final value = AppStrings.t('supplier_entry_type_$type', locale);
          expect(value, isNot('supplier_entry_type_$type'));
          expect(value, isNotEmpty);
        }
      }
    });

    test('supplier ledger labels match the phase 11 spec', () {
      const expected = {
        'ar': {
          'supplier_entry_type_purchase': 'فاتورة شراء',
          'supplier_entry_type_payment': 'دفعة',
          'supplier_entry_type_purchase_cancel': 'إلغاء فاتورة شراء',
        },
        'fr': {
          'supplier_entry_type_purchase': 'Achat reçu',
          'supplier_entry_type_payment': 'Paiement',
          'supplier_entry_type_purchase_cancel': 'Achat annulé',
        },
        'en': {
          'supplier_entry_type_purchase': 'Purchase received',
          'supplier_entry_type_payment': 'Payment',
          'supplier_entry_type_purchase_cancel': 'Purchase cancelled',
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
  });
}
