import 'package:flutter/foundation.dart';

import 'license_info.dart';

/// `mode` of a `GET /api/v1/license/status` payload (Phase L2-A contract):
/// `lifetime` appears only once a stored license fully re-verifies.
enum LicenseSnapshotMode { lifetime, trial, trialExpired, unknown }

/// `status` of the same payload.
enum LicenseSnapshotStatus { active, expired, unavailable }

/// Client-side view of the additive `/api/v1/license/status` response —
/// the authoritative licensing snapshot (Phase L2-C), distinct from
/// [LicenseInfo], which carries only the trial block from `/system/info`.
///
/// Parsing rules mirror [LicenseInfo]'s defensive contract (§L1-C safety):
/// * a non-map payload yields `null` from [tryParse] — never a guess;
/// * unrecognized enum values degrade to `unknown` / `unavailable`;
/// * timestamps that are absent or unparsable become `null`;
/// * the nested `trial` block falls back to [LicenseInfo.unknown].
@immutable
class LicenseSnapshot {
  const LicenseSnapshot({
    required this.mode,
    required this.status,
    required this.trial,
    this.licenseType,
    this.licenseId,
    this.activatedAt,
  });

  final LicenseSnapshotMode mode;
  final LicenseSnapshotStatus status;
  final String? licenseType;
  final String? licenseId;
  final DateTime? activatedAt;

  /// Unchanged L1-B safe trial representation from `/system/info`.
  final LicenseInfo trial;

  /// True only for a fully verified Lifetime license: this is what lets
  /// the client stop presenting the installation as trial-limited
  /// (router gate, banner, status card) without ever being the authority
  /// — the backend `license_guard` remains that.
  bool get isLifetime =>
      mode == LicenseSnapshotMode.lifetime &&
      status == LicenseSnapshotStatus.active;

  /// Parses one response body; `null` when it is absent or not a map so
  /// callers can leave existing state untouched.
  static LicenseSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return LicenseSnapshot.fromJson(Map<String, dynamic>.from(raw));
  }

  factory LicenseSnapshot.fromJson(Map<String, dynamic> json) {
    return LicenseSnapshot(
      mode: _parseMode(json['mode']),
      status: _parseStatus(json['status']),
      licenseType: json['license_type'] is String
          ? json['license_type'] as String
          : null,
      licenseId: json['license_id'] is String ? json['license_id'] as String : null,
      activatedAt: _parseTime(json['activated_at']),
      trial: LicenseInfo.tryParse(json['trial']) ?? const LicenseInfo.unknown(),
    );
  }

  static LicenseSnapshotMode _parseMode(Object? raw) => switch (raw) {
        'lifetime' => LicenseSnapshotMode.lifetime,
        'trial' => LicenseSnapshotMode.trial,
        'trial_expired' => LicenseSnapshotMode.trialExpired,
        _ => LicenseSnapshotMode.unknown,
      };

  static LicenseSnapshotStatus _parseStatus(Object? raw) => switch (raw) {
        'active' => LicenseSnapshotStatus.active,
        'expired' => LicenseSnapshotStatus.expired,
        _ => LicenseSnapshotStatus.unavailable,
      };

  static DateTime? _parseTime(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
