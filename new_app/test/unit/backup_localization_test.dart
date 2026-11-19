// Phase 17 (§17.2) backup localization coverage across ar/fr/en.
//
// Same contract as §17.1: every Phase 17.2 key × 3 locales resolves to a
// real translation (never the raw key — `AppStrings.t` falls back to the
// key itself, which would print `backup_restore_failed` on screen), the
// three maps are actually localized, and the generic keys the backup flows
// reuse also resolve.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 17.2 — the Backups card, its create/restore
/// confirmations and the failure headlines.
const _phase172Keys = [
  'backups',
  'backup_create',
  'backup_created',
  'backup_create_failed',
  'backup_empty',
  'backup_restore',
  'backup_restore_confirm',
  'backup_restore_warning',
  'backup_restored',
  'backup_restore_failed',
  'backup_load_failed',
  'backup_failed',
  'backup_tools_missing',
  'not_found',
];

/// Generic keys the backups card CALLS but did not introduce.
const _reusedKeys = [
  'cancel',
  'confirm',
  'network_error_retry',
  'authentication_failed',
  'permission_denied',
  'validation_error',
  'api_error_retry',
];

void main() {
  group('Phase 17.2 backup strings', () {
    test('exactly 14 Phase 17.2 keys are under test (42 entries)', () {
      expect(_phase172Keys, hasLength(14));
      expect(_phase172Keys.toSet(), hasLength(14), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every Phase 17.2 key exists and is non-empty in "$locale"', () {
        for (final key in _phase172Keys) {
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

    test('Arabic and English Phase 17.2 translations differ', () {
      var translated = 0;
      for (final key in _phase172Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase172Keys.length ~/ 2));
    });

    test('French and English Phase 17.2 translations differ', () {
      var translated = 0;
      for (final key in _phase172Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase172Keys.length ~/ 2));
    });

    test('the destructive warning is spelled out in every locale', () {
      for (final locale in _locales) {
        final warning = AppStrings.t('backup_restore_warning', locale);
        expect(warning.length, greaterThan(40),
            reason: 'a vague warning is worse than none at $locale');
      }
    });
  });

  // Phase L3 (audit §8): the confirm dialog must spell out the full
  // blast radius (users/sessions/devices reset, licence kept), in all
  // three locales — the parity test only proves the keys exist.
  group('Phase L3 restore side-effects notice', () {
    test('resolves in every locale and is actually localized', () {
      final values = <String, String>{};
      for (final locale in _locales) {
        final value = AppStrings.t('backup_restore_side_effects', locale);
        expect(value, isNotEmpty, reason: 'missing/empty at $locale');
        expect(
          value,
          isNot('backup_restore_side_effects'),
          reason: 'raw key printed at $locale',
        );
        expect(
          value.length,
          greaterThan(60),
          reason: 'the side effects must be spelled out at $locale',
        );
        values[locale] = value;
      }
      expect(values.values.toSet(), hasLength(3),
          reason: 'the three locales must differ');
    });
  });
}
