// Phase L1-C — LicenseInfo parsing: the defensive, never-throw contract.
//
// The `license` block of `GET /api/v1/system/info` (Phase L1-B) is
// informational only; the backend license_guard stays the enforcement
// authority. These tests pin the client-side safety rules: a missing or
// malformed license never reads as active, unknown enums degrade instead
// of throwing, null/unparsable timestamps stay null, and
// `remaining_seconds` is clamped to >= 0.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/about/about_providers.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';

Map<String, dynamic> _activePayload() => <String, dynamic>{
      'mode': 'trial',
      'status': 'active',
      'trial_active': true,
      'trial_expired': false,
      'first_launch_at': '2026-01-01T00:00:00Z',
      'expires_at': '2026-01-15T00:00:00Z',
      'observed_at': '2026-01-05T12:00:00Z',
      'remaining_seconds': 864000,
      'trial_days': 14,
    };

void main() {
  group('LicenseInfo.fromJson — well-formed payloads', () {
    test('parses an active trial completely', () {
      final license = LicenseInfo.fromJson(_activePayload());
      expect(license.mode, LicenseMode.trial);
      expect(license.status, LicenseStatus.active);
      expect(license.trialActive, isTrue);
      expect(license.trialExpired, isFalse);
      expect(license.firstLaunchAt, DateTime.parse('2026-01-01T00:00:00Z'));
      expect(license.expiresAt, DateTime.parse('2026-01-15T00:00:00Z'));
      expect(license.observedAt, DateTime.parse('2026-01-05T12:00:00Z'));
      expect(license.remainingSeconds, 864000);
      expect(license.trialDays, 14);
    });

    test('parses an expired trial', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial_expired',
        'status': 'expired',
        'trial_active': false,
        'trial_expired': true,
        'first_launch_at': '2026-01-01T00:00:00Z',
        'expires_at': '2026-01-15T00:00:00Z',
        'observed_at': '2026-01-20T00:00:00Z',
        'remaining_seconds': 0,
        'trial_days': 14,
      });
      expect(license.mode, LicenseMode.trialExpired);
      expect(license.status, LicenseStatus.expired);
      expect(license.trialExpired, isTrue);
      expect(license.remainingSeconds, 0);
    });
  });

  group('LicenseInfo.fromJson — defensive degradation', () {
    test('missing fields degrade to unknown/unavailable, never active', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{});
      expect(license.mode, LicenseMode.unknown);
      expect(license.status, LicenseStatus.unavailable);
      expect(license.trialActive, isFalse);
      expect(license.trialExpired, isFalse);
      expect(license.remainingSeconds, 0);
      expect(license.expiresAt, isNull);
      expect(license.firstLaunchAt, isNull);
      expect(license.observedAt, isNull);
      expect(license.trialDays, isNull);
      expect(license.status, isNot(LicenseStatus.active));
    });

    test('unknown enum values degrade instead of throwing', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'perpetual',
        'status': 'suspended',
        'trial_active': 'yes',
        'trial_expired': 1,
        'remaining_seconds': 100,
      });
      expect(license.mode, LicenseMode.unknown);
      expect(license.status, LicenseStatus.unavailable);
      expect(license.trialActive, isFalse,
          reason: 'only literal true counts as trial_active');
      expect(license.trialExpired, isFalse);
    });

    test('null and unparsable timestamps become null', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'first_launch_at': null,
        'expires_at': 'not-a-timestamp',
        'observed_at': 42,
        'remaining_seconds': 10,
      });
      expect(license.firstLaunchAt, isNull);
      expect(license.expiresAt, isNull);
      expect(license.observedAt, isNull);
    });

    test('negative remaining_seconds is clamped to 0', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'remaining_seconds': -3600,
      });
      expect(license.remainingSeconds, 0);
    });

    test('non-int remaining_seconds becomes 0', () {
      for (final raw in <Object?>['1200', null, 12.5, true]) {
        final license = LicenseInfo.fromJson(<String, dynamic>{
          'mode': 'trial',
          'status': 'active',
          'remaining_seconds': raw,
        });
        expect(license.remainingSeconds, 0, reason: 'raw: $raw');
      }
    });

    test('non-int trial_days becomes null', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'trial_days': 'fourteen',
      });
      expect(license.trialDays, isNull);
    });
  });

  group('LicenseInfo.tryParse / fromSystemInfoPayload', () {
    test('tryParse returns null for absent or non-map values', () {
      expect(LicenseInfo.tryParse(null), isNull);
      expect(LicenseInfo.tryParse('trial'), isNull);
      expect(LicenseInfo.tryParse(7), isNull);
      expect(LicenseInfo.tryParse(<Object?>[1, 2]), isNull);
    });

    test('tryParse returns a LicenseInfo for a map', () {
      final license = LicenseInfo.tryParse(_activePayload());
      expect(license, isNotNull);
      expect(license!.status, LicenseStatus.active);
    });

    test('a payload without a license field yields the unknown sentinel', () {
      final license = LicenseInfo.fromSystemInfoPayload(
        <String, dynamic>{'name': 'Store', 'version': '1.0'},
      );
      expect(license.mode, LicenseMode.unknown);
      expect(license.status, LicenseStatus.unavailable);
      expect(license.status, isNot(LicenseStatus.active));
    });

    test('a null payload yields the unknown sentinel', () {
      expect(
        LicenseInfo.fromSystemInfoPayload(null).status,
        LicenseStatus.unavailable,
      );
    });

    test('a non-map license field yields the unknown sentinel', () {
      final license = LicenseInfo.fromSystemInfoPayload(
        <String, dynamic>{'license': 'active'},
      );
      expect(license.status, LicenseStatus.unavailable);
      expect(license.mode, LicenseMode.unknown);
    });

    test('a well-formed license field is parsed through', () {
      final license = LicenseInfo.fromSystemInfoPayload(
        <String, dynamic>{'license': _activePayload()},
      );
      expect(license.status, LicenseStatus.active);
      expect(license.mode, LicenseMode.trial);
      expect(license.trialDays, 14);
    });
  });

  group('LicenseInfo.unknown sentinel', () {
    test('is unavailable with zeroed fields and never active', () {
      const license = LicenseInfo.unknown();
      expect(license.mode, LicenseMode.unknown);
      expect(license.status, LicenseStatus.unavailable);
      expect(license.trialActive, isFalse);
      expect(license.trialExpired, isFalse);
      expect(license.remainingSeconds, 0);
      expect(license.expiresAt, isNull);
      expect(license.firstLaunchAt, isNull);
      expect(license.observedAt, isNull);
      expect(license.trialDays, isNull);
    });
  });

  group('effectiveStatusAt', () {
    LicenseInfo activeWithExpiry(DateTime expiresAt) => LicenseInfo(
          mode: LicenseMode.trial,
          status: LicenseStatus.active,
          trialActive: true,
          trialExpired: false,
          remainingSeconds: 100,
          expiresAt: expiresAt,
        );

    test('an active trial with a future expiry stays active', () {
      final now = DateTime.parse('2026-01-10T00:00:00Z');
      final license = activeWithExpiry(DateTime.parse('2026-01-15T00:00:00Z'));
      expect(license.effectiveStatusAt(now), LicenseStatus.active);
    });

    test('an active trial whose expiry has passed reads as expired', () {
      final now = DateTime.parse('2026-01-16T00:00:00Z');
      final license = activeWithExpiry(DateTime.parse('2026-01-15T00:00:00Z'));
      expect(license.effectiveStatusAt(now), LicenseStatus.expired);
    });

    test('an expiry exactly equal to now is expired', () {
      final now = DateTime.parse('2026-01-15T00:00:00Z');
      final license = activeWithExpiry(now);
      expect(license.effectiveStatusAt(now), LicenseStatus.expired);
    });

    test('server-side expired never upgrades to active', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial_expired',
        'status': 'expired',
        'trial_expired': true,
        'expires_at': '2099-01-01T00:00:00Z',
      });
      expect(
        license.effectiveStatusAt(DateTime.parse('2026-01-01T00:00:00Z')),
        LicenseStatus.expired,
      );
    });

    test('unavailable stays unavailable', () {
      expect(
        const LicenseInfo.unknown()
            .effectiveStatusAt(DateTime.parse('2026-01-01T00:00:00Z')),
        LicenseStatus.unavailable,
      );
    });

    test('active without an expiry timestamp stays active', () {
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'remaining_seconds': 60,
      });
      expect(
        license.effectiveStatusAt(DateTime.parse('2099-01-01T00:00:00Z')),
        LicenseStatus.active,
      );
    });
  });

  group('remainingAt', () {
    test('derives from expires_at when present', () {
      final now = DateTime.parse('2026-01-10T00:00:00Z');
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'expires_at': '2026-01-12T00:00:00Z',
        'remaining_seconds': 999999,
      });
      expect(license.remainingAt(now), const Duration(days: 2));
    });

    test('clamps at zero once the expiry has passed', () {
      final now = DateTime.parse('2026-02-01T00:00:00Z');
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'expires_at': '2026-01-15T00:00:00Z',
      });
      expect(license.remainingAt(now), Duration.zero);
    });

    test('falls back to remaining_seconds without an expiry', () {
      final now = DateTime.parse('2026-01-10T00:00:00Z');
      final license = LicenseInfo.fromJson(<String, dynamic>{
        'mode': 'trial',
        'status': 'active',
        'remaining_seconds': 120,
      });
      expect(license.remainingAt(now), const Duration(seconds: 120));
    });
  });

  group('SystemInfo backward compatibility (additive license field)', () {
    test('a pre-L1-C payload without license still parses', () {
      final info = SystemInfo.fromJson(<String, dynamic>{
        'name': 'Supermarket Pro',
        'version': '0.1.0',
        'environment': 'dev',
        'protocol': 1,
      });
      expect(info.name, 'Supermarket Pro');
      expect(info.version, '0.1.0');
      expect(info.license, isNull,
          reason: 'older servers simply have no license block');
    });

    test('a L1-B payload carries the parsed license through', () {
      final info = SystemInfo.fromJson(<String, dynamic>{
        'name': 'Supermarket Pro',
        'version': '0.1.0',
        'license': _activePayload(),
      });
      expect(info.license, isNotNull);
      expect(info.license!.status, LicenseStatus.active);
      expect(info.license!.trialDays, 14);
    });

    test('a malformed license never breaks SystemInfo parsing', () {
      final info = SystemInfo.fromJson(<String, dynamic>{
        'name': 'Store',
        'version': '1.0',
        'license': 'broken',
      });
      expect(info.name, 'Store');
      expect(info.license, isNull);
    });
  });
}
