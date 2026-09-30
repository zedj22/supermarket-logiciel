// Phase 13 (Expenses) localization coverage across ar/fr/en.
//
// Contract (analysis §15): the 40 Phase 13 keys × 3 locales = 120 map
// entries all resolve to a real translation (never the raw key —
// `AppStrings.t` falls back to the key itself, which would render
// `expense_title_required` literally on screen), and the three maps are
// actually localized.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/expenses/expense_models.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 13 (screen header + summary, editor fields,
/// filters, statuses, cancellation and the backend error code).
const _phase13Keys = [
  // Screen header + summary
  'expenses_subtitle',
  'expense_count',
  'expense_total',
  'expense_total_drawer',
  'expense_total_external',
  'expense_empty',
  // Create / edit dialog
  'expense_add',
  'expense_title_label',
  'expense_title_hint',
  'expense_title_required',
  'expense_category_label',
  'expense_amount_label',
  'expense_amount_hint',
  'expense_amount_invalid',
  'expense_paid_from_drawer',
  'expense_paid_external',
  'expense_note_label',
  'expense_submit',
  'expense_saved',
  'expense_save_failed',
  'expense_replay',
  // Filters
  'expense_search_hint',
  'expense_filter_payment',
  'expense_filter_all_categories',
  'expense_date_range',
  // Lifecycle statuses
  'expense_status_posted',
  'expense_status_cancelled',
  // Cancellation
  'expense_cancel_action',
  'expense_cancel_title',
  'expense_cancel_confirm',
  'expense_cancelled_success',
  'expense_already_cancelled',
  // Backend error code → localized headline
  'error_expense_not_found',
  // Category labels (ExpenseCategory enum, GATE 4)
  'category_rent',
  'category_utilities',
  'category_salary',
  'category_maintenance',
  'category_supplies',
  'category_transport',
  'category_other',
];

/// Existing keys the expenses UI reuses (must not regress).
const _reusedKeys = [
  'expenses',
  'permission_denied',
  'api_error_retry',
  'network_error_retry',
  'validation_error',
  'session_expired_login',
  'error_idempotency_conflict',
  'refresh',
  'retry',
  'cancel',
  'close',
  'from',
  'to',
  'all',
  'clear',
  'category',
  'currency',
  'reason',
  'reason_required',
];

void main() {
  group('Phase 13 expense strings', () {
    test('exactly 40 Phase 13 keys are under test (120 entries)', () {
      expect(_phase13Keys, hasLength(40));
    });

    for (final locale in _locales) {
      test('every Phase 13 key exists and is non-empty in "$locale"', () {
        for (final key in _phase13Keys) {
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

    test('every ExpenseCategory code has a localized label', () {
      for (final locale in _locales) {
        for (final code in kExpenseCategories) {
          final key = expenseCategoryKey(code);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing category label $key@$locale',
          );
        }
      }
    });

    test('both lifecycle statuses have a localized label', () {
      for (final locale in _locales) {
        for (final status in ['posted', 'cancelled']) {
          final key = expenseStatusKey(status);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing status label $key@$locale',
          );
        }
      }
    });

    test('Arabic and English Phase 13 translations differ', () {
      var translated = 0;
      for (final key in _phase13Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase13Keys.length ~/ 2));
    });

    test('French and English Phase 13 translations differ', () {
      var translated = 0;
      for (final key in _phase13Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase13Keys.length ~/ 2));
    });
  });
}
