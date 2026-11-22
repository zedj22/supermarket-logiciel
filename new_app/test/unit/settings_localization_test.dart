// Phase 17 (§17.1) settings localization coverage across ar/fr/en.
//
// Contract: every Phase 17.1 key × 3 locales resolves to a real translation
// (never the raw key — `AppStrings.t` falls back to the key itself, which
// would render `settings_save_failed` literally on screen), the three maps
// are actually localized, and the reused generic keys the settings flows
// call (field labels + error headlines) also resolve.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 17.1 — the server-owned store/receipt/POS
/// settings form plus its load/save feedback.
const _phase17Keys = [
  // Store identity
  'settings_store',
  'store_name',
  // Receipt
  'settings_receipt',
  'invoice_footer',
  'default_paper',
  'ask_before_print',
  'auto_print_invoice',
  // POS rules
  'settings_pos',
  'allow_debt',
  // Feedback
  'settings_saved',
  'settings_save_failed',
  'settings_load_failed',
];

/// Generic keys the settings screen CALLS but did not introduce — they must
/// keep resolving in every locale the screen can render in.
const _reusedKeys = [
  'settings',
  'language',
  'theme',
  'phone',
  'address',
  'low_stock_threshold',
  'save',
  'refresh',
  'retry',
  'loading',
  'validation_error',
  'permission_denied',
  'network_error_retry',
  'authentication_failed',
  'api_error_retry',
];

void main() {
  group('Phase 17.1 settings strings', () {
    test('exactly 12 Phase 17.1 keys are under test (36 entries)', () {
      expect(_phase17Keys, hasLength(12));
      expect(_phase17Keys.toSet(), hasLength(12), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every Phase 17.1 key exists and is non-empty in "$locale"', () {
        for (final key in _phase17Keys) {
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

    test('Arabic and English Phase 17.1 translations differ', () {
      var translated = 0;
      for (final key in _phase17Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase17Keys.length ~/ 2));
    });

    test('French and English Phase 17.1 translations differ', () {
      var translated = 0;
      for (final key in _phase17Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase17Keys.length ~/ 2));
    });
  });

  // Receipt printing mode (one dropdown + its threshold input) — the label,
  // the four option labels and the Minimum Receipt Amount field.
  group('Receipt printing mode strings', () {
    const optionKeys = [
      'receipt_print_mode_disabled',
      'receipt_print_mode_ask',
      'receipt_print_mode_auto_print',
      'receipt_print_mode_ask_above_threshold',
    ];

    const modeKeys = [
      'receipt_print_mode',
      ...optionKeys,
      'receipt_min_amount',
      // Save feedback for a backend that does not confirm the new columns.
      'settings_save_incomplete',
    ];

    test('exactly 7 keys are under test', () {
      expect(modeKeys, hasLength(7));
      expect(modeKeys.toSet(), hasLength(7), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every receipt printing mode key resolves in "$locale"', () {
        for (final key in modeKeys) {
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

    test('the four option labels differ inside each locale', () {
      for (final locale in _locales) {
        final labels = {
          for (final key in optionKeys) AppStrings.t(key, locale),
        };
        expect(labels, hasLength(4), reason: 'duplicate option label@$locale');
      }
    });

    test('Arabic, French and English mode labels all differ', () {
      final ar = AppStrings.t('receipt_print_mode', 'ar');
      final fr = AppStrings.t('receipt_print_mode', 'fr');
      final en = AppStrings.t('receipt_print_mode', 'en');
      expect({ar, fr, en}, hasLength(3));
    });
  });

  // Stage 1 (facturation legacy parity) — the Company Information section
  // introduces exactly two new keys; every field label it reuses must also
  // keep resolving in all three locales.
  group('Stage 1 company settings strings', () {
    const stage1Keys = [
      'settings_company',
      'rib',
    ];

    /// Field labels the company section REUSES — they predate Stage 1 but
    /// the section now depends on them.
    const reusedByCompany = [
      'wilaya',
      'email',
      'rc',
      'nif',
      'ai',
      'nis',
      'save',
    ];

    test('exactly 2 Stage 1 keys are under test', () {
      expect(stage1Keys, hasLength(2));
      expect(stage1Keys.toSet(), hasLength(2), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every Stage 1 key exists and is non-empty in "$locale"', () {
        for (final key in stage1Keys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });

      test('company field labels reused from earlier phases still resolve '
          'in "$locale"', () {
        for (final key in reusedByCompany) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing: $key@$locale');
          expect(value, isNot(key), reason: 'raw key: $key@$locale');
        }
      });
    }

    test('Arabic, French and English section titles all differ', () {
      final ar = AppStrings.t('settings_company', 'ar');
      final fr = AppStrings.t('settings_company', 'fr');
      final en = AppStrings.t('settings_company', 'en');
      expect({ar, fr, en}, hasLength(3), reason: 'untranslated title');
    });
  });
}
