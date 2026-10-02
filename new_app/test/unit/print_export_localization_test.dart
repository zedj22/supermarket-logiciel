// Phase 15 (§14) print/export localization coverage across ar/fr/en.
//
// Contract: every Phase 15 key × 3 locales resolves to a real translation
// (never the raw key — `AppStrings.t` falls back to the key itself, which
// would render `print_render_failed` literally on screen), the three maps
// are actually localized, and the reused generic keys the print/export
// flows call (dialog actions + shared error headlines) also resolve.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 15: the print preview dialog (§6.2 E) and the
/// unified export formats + typed export error headlines (§12.1 / §16.1).
const _phase15Keys = [
  // Print preview dialog
  'print_dialog_title',
  'paper_80mm',
  'paper_a4',
  'save_pdf',
  'pdf_saved',
  'print_preview_failed',
  'print_render_failed',
  'missing_font',
  'print_failed',
  // Unified export dialog + flows
  'export_title',
  'export_csv',
  'export_xlsx',
  'export_pdf',
  'export_done',
  'export_failed',
  'export_format_unsupported',
  'export_row_limit',
  'export_too_large',
  'export_render_failed',
];

/// Generic keys the Phase 15 screens CALL but did not introduce — they
/// must keep resolving in every locale the dialog can render in.
const _reusedKeys = [
  'print',
  'retry',
  'cancel',
  'validation_error',
  'permission_denied',
  'session_expired_login',
  'api_error_retry',
  'network_error_retry',
];

void main() {
  group('Phase 15 print/export strings', () {
    test('exactly 19 Phase 15 keys are under test (57 entries)', () {
      expect(_phase15Keys, hasLength(19));
      expect(_phase15Keys.toSet(), hasLength(19), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every Phase 15 key exists and is non-empty in "$locale"', () {
        for (final key in _phase15Keys) {
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

    test('Arabic and English Phase 15 translations differ', () {
      var translated = 0;
      for (final key in _phase15Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase15Keys.length ~/ 2));
    });

    test('French and English Phase 15 translations differ', () {
      var translated = 0;
      for (final key in _phase15Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase15Keys.length ~/ 2));
    });
  });
}
