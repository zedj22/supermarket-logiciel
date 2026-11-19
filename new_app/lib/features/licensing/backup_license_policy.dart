// Phase L1-D — the backup surface a licence state may show.
//
// The backend `license_guard` + `BackupService` are the enforcement
// authority; this file is the *presentation* half of the same §4.4
// matrix, so the UI can explain a restriction before the operator hits
// it.  It never grants anything: a disabled button is a courtesy, and
// every request still comes back from the server with
// `trial_upload_forbidden` / `trial_restore_forbidden` / `trial_expired`
// if the client's snapshot is stale.
//
// State comes from [licenseStatusProvider], which the shared ApiClient
// feeds from every `GET /system/info` response (Phase L1-C) — one
// existing flow, no extra request of our own and no polling.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'license_info.dart';
import 'license_providers.dart';

/// Which part of the backup catalogue the current licence state allows.
///
/// [unknown] means "the server has not told us anything yet" (no
/// system-info response, or a server that predates the licence block).
/// Nothing is inferred from it: the buttons stay enabled and the backend
/// decides — a licensing check that guessed here would either lock a
/// healthy install or claim access it cannot grant.
enum BackupLicenseGate {
  /// No usable licence information — backend decides, nothing disabled.
  unknown,

  /// Free Trial running: create/download are open, upload/restore are not.
  trialActive,

  /// Trial elapsed: only listing and downloading existing backups remain.
  trialExpired,
}

/// The §4.4 matrix as the UI sees it — one row per [BackupLicenseGate].
@immutable
class BackupPermissions {
  const BackupPermissions({
    required this.canCreate,
    required this.canList,
    required this.canDownload,
    required this.canInspect,
    required this.canUpload,
    required this.canRestore,
  });

  /// Everything available (unknown gate, or a future Lifetime licence).
  const BackupPermissions.all()
      : canCreate = true,
        canList = true,
        canDownload = true,
        canInspect = true,
        canUpload = true,
        canRestore = true;

  final bool canCreate;
  final bool canList;
  final bool canDownload;
  final bool canInspect;
  final bool canUpload;
  final bool canRestore;

  /// Explanation key shown while the gate is not [BackupLicenseGate.unknown],
  /// or `null` when there is nothing to explain.
  String? noticeKeyFor(BackupLicenseGate gate) => switch (gate) {
        BackupLicenseGate.trialActive => 'backup_license_trial_notice',
        BackupLicenseGate.trialExpired => 'backup_license_expired_notice',
        BackupLicenseGate.unknown => null,
      };
}

/// Derives the gate from the server's `license` block.
///
/// An expired snapshot never upgrades: once `expires_at` has passed (or
/// the server reported `trial_expired`) the gate stays closed even if the
/// cached `mode` still says `trial`.
BackupLicenseGate backupLicenseGateFor(LicenseInfo? info, {DateTime? now}) {
  if (info == null) return BackupLicenseGate.unknown;
  final effective = info.effectiveStatusAt(now ?? DateTime.now());
  final expired = info.mode == LicenseMode.trialExpired ||
      info.trialExpired ||
      effective == LicenseStatus.expired;
  if (expired) return BackupLicenseGate.trialExpired;
  if (info.mode == LicenseMode.trial || info.trialActive) {
    return BackupLicenseGate.trialActive;
  }
  return BackupLicenseGate.unknown;
}

/// The backup actions [gate] shows as available.
BackupPermissions backupPermissionsFor(BackupLicenseGate gate) =>
    switch (gate) {
      BackupLicenseGate.unknown => const BackupPermissions.all(),
      // D6: export stays available, the two write-into-this-install
      // operations do not.
      BackupLicenseGate.trialActive => const BackupPermissions(
          canCreate: true,
          canList: true,
          canDownload: true,
          canInspect: true,
          canUpload: false,
          canRestore: false,
        ),
      // D3: read-only data rescue — list and download stay open so an
      // expired install can still get its data off the server.
      BackupLicenseGate.trialExpired => const BackupPermissions(
          canCreate: false,
          canList: true,
          canDownload: true,
          canInspect: false,
          canUpload: false,
          canRestore: false,
        ),
    };

/// Live gate for the UI, fed by the existing system-info flow.
final backupLicenseGateProvider = Provider<BackupLicenseGate>((ref) {
  return backupLicenseGateFor(ref.watch(licenseStatusProvider));
});
