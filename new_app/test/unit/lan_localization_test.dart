// Phase 16 (§24) LAN / device localization coverage across ar/fr/en.
//
// Contract: every Phase 16 key × 3 locales resolves to a real translation
// (never the raw key — `AppStrings.t` falls back to the key itself, which
// would render `lan_connected` literally on the AppBar), the three maps are
// actually localized, and the reused generic keys the LAN flows call also
// resolve.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Every key introduced by Phase 16 (§24 key groups), in group order.
const _phase16Keys = [
  // Wizard / roles
  'lan_wizard_title',
  'lan_server_role',
  'lan_client_role',
  'lan_role_server_desc',
  'lan_role_client_desc',
  'lan_first_run_hint',
  // Discovery
  'lan_searching_server',
  'lan_search_timeout',
  'lan_server_found',
  'lan_server_not_supermarket',
  'lan_manual_entry',
  'lan_ip_label',
  'lan_port_label',
  'lan_connect',
  'lan_retry',
  'lan_cancel',
  // Confirm
  'lan_confirm_store',
  'lan_confirm_store_body',
  'lan_yes_connect',
  // Pairing
  'lan_pairing_code',
  'lan_enter_pairing_code',
  'lan_pairing_code_invalid',
  'lan_waiting_approval',
  'lan_waiting_seconds',
  'lan_pairing_approved',
  'lan_pairing_rejected',
  'lan_pairing_timeout',
  'lan_pairing_rejected_body',
  'lan_repair_required',
  // Devices screen
  'lan_devices_title',
  'lan_pending_devices',
  'lan_no_pending',
  'lan_approve',
  'lan_reject',
  'lan_revoke',
  'lan_revoke_confirm',
  'lan_device_last_seen',
  'lan_device_ip',
  'lan_device_version',
  'lan_status_pending',
  'lan_status_approved',
  'lan_status_rejected',
  'lan_status_revoked',
  'lan_registered_devices',
  'lan_no_registered',
  'lan_pairing_code_hint',
  'lan_generate_code',
  // Status chip
  'lan_connected',
  'lan_reconnecting',
  'lan_disconnected',
  'lan_degraded_db',
  'lan_connected_tooltip',
  // Reconnect / errors
  'lan_reconnect_title',
  'lan_reconnect_body',
  'lan_reconnect_now',
  'lan_server_unreachable',
  'lan_device_revoked_title',
  'lan_device_revoked_body',
  'lan_version_mismatch',
  'lan_server_changed',
  // Offline semantics (§15)
  'lan_offline_mutations_disabled',
];

/// Generic keys the Phase 16 screens CALL but did not introduce.
const _reusedKeys = [
  'retry',
  'refresh',
  'cancel',
  'permission_denied',
  'network_error_retry',
  'api_error_retry',
];

void main() {
  group('Phase 16 LAN/device strings', () {
    test('exactly 61 Phase 16 keys are under test (183 entries)', () {
      expect(_phase16Keys, hasLength(61));
      expect(_phase16Keys.toSet(), hasLength(61), reason: 'duplicate key');
      expect(_phase16Keys.length * _locales.length, 183);
    });

    for (final locale in _locales) {
      test('every Phase 16 key exists and is non-empty in "$locale"', () {
        for (final key in _phase16Keys) {
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

    test('Arabic and English Phase 16 translations differ', () {
      var translated = 0;
      for (final key in _phase16Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase16Keys.length ~/ 2));
    });

    test('French and English Phase 16 translations differ', () {
      var translated = 0;
      for (final key in _phase16Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase16Keys.length ~/ 2));
    });

    test('every Phase 16 key uses the lan_ prefix', () {
      for (final key in _phase16Keys) {
        expect(key, startsWith('lan_'), reason: 'non-prefixed key: $key');
      }
    });

    test('the countdown placeholder survives in every locale', () {
      for (final locale in _locales) {
        expect(
          AppStrings.t('lan_waiting_seconds', locale),
          contains('{s}'),
          reason: 'placeholder lost in $locale',
        );
      }
    });
  });
}
