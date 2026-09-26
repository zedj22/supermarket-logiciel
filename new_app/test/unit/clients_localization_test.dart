// Phase 9 (Customers / Debts) localization coverage across ar/fr/en.
//
// Contract: every Phase 9 UI key resolves to a real translation in all
// three locales (never the raw key), and the three maps are actually
// localized (values differ across locales).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 9 (must exist in _arabic / _french / _english).
const _phase9Keys = [
  'balance',
  'debt_ceiling',
  'over_limit_hint',
  'archive',
  'add_client',
  'edit_client',
  'client_created',
  'client_updated',
  'client_archived',
  'archive_client_confirm',
  'customer_outstanding_debt',
  'customer_not_found',
  'customer_is_archived',
  'record_payment',
  'record_debt_payment',
  'payment_success',
  'debt_payment_exceeds',
  'pay_all',
  'remaining_after',
  'amount',
  'note_hint',
  'debt_history',
  'entry_type_sale',
  'entry_type_payment',
  'entry_type_full_payment',
  'entry_type_adjustment',
  'balance_after',
  'debt_summary',
  'total_debt',
  'customers_with_debt',
  'show_archived',
  'select_client_hint',
  'no_debt_records',
  'field_required',
];

/// Existing keys Phase 9 screens depend on (must not regress).
const _reusedKeys = [
  'clients',
  'debts',
  'search',
  'total',
  'name',
  'phone',
  'address',
  'save',
  'cancel',
  'edit',
  'no_data',
  'loading',
  'retry',
  'refresh',
  'archived',
  'note',
  'invoice_number',
  'select_customer',
  'permission_denied',
  'network_error_retry',
  'api_error_retry',
  'validation_error',
  'session_expired_login',
  'invalid_amount',
  'customer',
  'debt',
  'payment',
  'confirm',
];

void main() {
  group('Phase 9 strings', () {
    for (final locale in _locales) {
      test('every Phase 9 key exists and is non-empty in "$locale"', () {
        for (final key in _phase9Keys) {
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

    test('Phase 9 key set is identical across ar / fr / en', () {
      final maps = <String, Map<String, String>>{};
      // AppStrings.t falls back to the key itself, so compare via the
      // public translate API — a missing key would return the key text
      // (already asserted above) — here assert explicit equality of
      // "defined" status for every key/locale pair.
      for (final locale in _locales) {
        maps[locale] = {
          for (final key in _phase9Keys) key: AppStrings.t(key, locale),
        };
      }
      for (final key in _phase9Keys) {
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
      for (final key in _phase9Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase9Keys.length ~/ 2));
    });

    test('French and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in _phase9Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase9Keys.length ~/ 2));
    });

    test('Arabic values contain Arabic script (no copy-paste English)', () {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      var withArabic = 0;
      for (final key in _phase9Keys) {
        if (arabic.hasMatch(AppStrings.t(key, 'ar'))) withArabic++;
      }
      expect(withArabic, greaterThan(_phase9Keys.length ~/ 2));
    });

    test('entry_type keys cover every ledger entry type', () {
      for (final type in ['sale', 'payment', 'full_payment', 'adjustment']) {
        for (final locale in _locales) {
          final value = AppStrings.t('entry_type_$type', locale);
          expect(value, isNot('entry_type_$type'));
        }
      }
    });

    test('debt history labels match the phase 9 spec', () {
      const expected = {
        'ar': {
          'entry_type_sale': 'إنشاء دين / بيع آجل',
          'entry_type_payment': 'دفعة',
          'entry_type_full_payment': 'تسديد كامل',
          'entry_type_adjustment': 'تسوية',
          'balance_after': 'الرصيد بعد',
        },
        'fr': {
          'entry_type_sale': 'Dette créée / Vente à crédit',
          'entry_type_payment': 'Paiement',
          'entry_type_full_payment': 'Paiement intégral',
          'entry_type_adjustment': 'Ajustement',
          'balance_after': 'Solde après',
        },
        'en': {
          'entry_type_sale': 'Debt Created / Credit Sale',
          'entry_type_payment': 'Payment',
          'entry_type_full_payment': 'Full Payment',
          'entry_type_adjustment': 'Adjustment',
          'balance_after': 'Balance after',
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
