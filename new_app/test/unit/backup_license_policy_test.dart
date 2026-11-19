// Phase L1-D — the §4.4 backup matrix as the *presentation* half.
//
// The backend (`license_guard` + `BackupService`) is the enforcement
// authority; these tests pin the client-side mirror so the UI can never
// claim an action the server will refuse, nor hide one it allows.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/licensing/backup_license_policy.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';

LicenseInfo _trial({
  LicenseMode mode = LicenseMode.trial,
  LicenseStatus status = LicenseStatus.active,
  bool trialActive = true,
  bool trialExpired = false,
  DateTime? expiresAt,
}) {
  return LicenseInfo(
    mode: mode,
    status: status,
    trialActive: trialActive,
    trialExpired: trialExpired,
    remainingSeconds: 60 * 60 * 24,
    expiresAt: expiresAt ?? DateTime.now().add(const Duration(days: 2)),
    trialDays: 14,
  );
}

void main() {
  group('backupLicenseGateFor', () {
    test('a server that never sent a licence block stays unknown', () {
      expect(
        backupLicenseGateFor(null),
        BackupLicenseGate.unknown,
        reason: 'nothing is inferred without a system-info answer',
      );
      expect(
        backupLicenseGateFor(const LicenseInfo.unknown()),
        BackupLicenseGate.unknown,
      );
    });

    test('a running trial is trialActive', () {
      expect(backupLicenseGateFor(_trial()), BackupLicenseGate.trialActive);
    });

    test('a trial whose expires_at has already passed is never active', () {
      final gate = backupLicenseGateFor(
        _trial(expiresAt: DateTime.now().subtract(const Duration(minutes: 1))),
      );
      expect(
        gate,
        BackupLicenseGate.trialExpired,
        reason: 'the snapshot ages in place — no clock upgrades it back',
      );
    });

    test('the server saying trial_expired wins over an active snapshot', () {
      final gate = backupLicenseGateFor(
        _trial(
          mode: LicenseMode.trialExpired,
          trialActive: false,
          trialExpired: true,
          status: LicenseStatus.expired,
          expiresAt: DateTime.now().add(const Duration(days: 5)),
        ),
      );
      expect(gate, BackupLicenseGate.trialExpired);
    });

    test('an explicit trial_expired flag closes the gate', () {
      expect(
        backupLicenseGateFor(_trial(trialExpired: true)),
        BackupLicenseGate.trialExpired,
      );
    });

    test('an expired status alone closes the gate', () {
      expect(
        backupLicenseGateFor(_trial(status: LicenseStatus.expired)),
        BackupLicenseGate.trialExpired,
      );
    });
  });

  group('backupPermissionsFor — §4.4 matrix', () {
    test('unknown keeps every action available (the server decides)', () {
      final gate = backupPermissionsFor(BackupLicenseGate.unknown);
      const all = BackupPermissions.all();
      expect(gate.canCreate, all.canCreate);
      expect(gate.canList, all.canList);
      expect(gate.canDownload, all.canDownload);
      expect(gate.canInspect, all.canInspect);
      expect(gate.canUpload, all.canUpload);
      expect(gate.canRestore, all.canRestore);
      expect(gate.canCreate, isTrue);
      expect(gate.canUpload, isTrue);
      expect(gate.canRestore, isTrue);
    });

    test('trial active = export only', () {
      final perms = backupPermissionsFor(BackupLicenseGate.trialActive);
      expect(perms.canCreate, isTrue);
      expect(perms.canList, isTrue);
      expect(perms.canDownload, isTrue);
      expect(perms.canInspect, isTrue);
      expect(perms.canUpload, isFalse);
      expect(perms.canRestore, isFalse);
    });

    test('trial expired = read-only data rescue', () {
      final perms = backupPermissionsFor(BackupLicenseGate.trialExpired);
      expect(perms.canList, isTrue);
      expect(perms.canDownload, isTrue);
      expect(perms.canCreate, isFalse);
      expect(perms.canInspect, isFalse);
      expect(perms.canUpload, isFalse);
      expect(perms.canRestore, isFalse);
    });
  });

  group('notice keys', () {
    test('each restricted gate explains itself, unknown says nothing', () {
      expect(
        backupPermissionsFor(BackupLicenseGate.trialActive)
            .noticeKeyFor(BackupLicenseGate.trialActive),
        'backup_license_trial_notice',
      );
      expect(
        backupPermissionsFor(BackupLicenseGate.trialExpired)
            .noticeKeyFor(BackupLicenseGate.trialExpired),
        'backup_license_expired_notice',
      );
      expect(
        backupPermissionsFor(BackupLicenseGate.unknown)
            .noticeKeyFor(BackupLicenseGate.unknown),
        isNull,
        reason: 'an unrestricted surface shows no restriction notice',
      );
    });
  });

  group('backupLicenseGateProvider', () {
    test('follows the licence snapshot the system-info flow writes', () {
      final container = ProviderContainer(
        overrides: [
          licenseStatusProvider.overrideWith((ref) => _trial()),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(backupLicenseGateProvider),
          BackupLicenseGate.trialActive);
    });

    test('an expired snapshot yields the expired gate', () {
      final container = ProviderContainer(
        overrides: [
          licenseStatusProvider.overrideWith(
            (ref) => _trial(expiresAt: DateTime.now().subtract(
              const Duration(days: 1),
            )),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(backupLicenseGateProvider),
          BackupLicenseGate.trialExpired);
    });

    test('no snapshot yet yields unknown, not a guess', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(backupLicenseGateProvider),
          BackupLicenseGate.unknown);
    });
  });
}
