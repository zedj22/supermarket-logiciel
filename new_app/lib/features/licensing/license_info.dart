import 'package:flutter/foundation.dart';

/// License mode reported by `GET /api/v1/system/info` (`license.mode`).
enum LicenseMode { trial, trialExpired, unknown }

/// License status reported by the same payload (`license.status`).
enum LicenseStatus { active, expired, unavailable }

/// Defensive client-side view of the server's `license` block (Phase L1-B
/// contract, informational only — the backend `license_guard` remains the
/// enforcement authority).
///
/// Parsing rules (§L1-C safety):
/// * a missing / non-map `license` field never infers an active license —
///   it yields [LicenseInfo.unknown];
/// * unrecognized enum values degrade to `unknown` / `unavailable` instead
///   of throwing;
/// * timestamps that are absent or unparsable become `null`;
/// * `remaining_seconds` is clamped to `>= 0`.
@immutable
class LicenseInfo {
  const LicenseInfo({
    required this.mode,
    required this.status,
    required this.trialActive,
    required this.trialExpired,
    required this.remainingSeconds,
    this.firstLaunchAt,
    this.expiresAt,
    this.observedAt,
    this.trialDays,
  });

  final LicenseMode mode;
  final LicenseStatus status;
  final bool trialActive;
  final bool trialExpired;
  final DateTime? firstLaunchAt;
  final DateTime? expiresAt;
  final DateTime? observedAt;
  final int remainingSeconds;
  final int? trialDays;

  /// No usable license information (old server, missing field, malformed
  /// payload). Never treated as active.
  const LicenseInfo.unknown()
      : mode = LicenseMode.unknown,
        status = LicenseStatus.unavailable,
        trialActive = false,
        trialExpired = false,
        remainingSeconds = 0,
        firstLaunchAt = null,
        expiresAt = null,
        observedAt = null,
        trialDays = null;

  /// Parses a `license` value; returns null when it is absent or not a map
  /// so callers can fall back to [LicenseInfo.unknown].
  static LicenseInfo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return LicenseInfo.fromJson(raw.cast<String, dynamic>());
  }

  /// Parses one system-info payload's `license` block. Never throws: any
  /// missing/malformed value degrades to the unknown (unavailable) state.
  static LicenseInfo fromSystemInfoPayload(Map<String, dynamic>? payload) {
    return tryParse(payload?['license']) ?? const LicenseInfo.unknown();
  }

  factory LicenseInfo.fromJson(Map<String, dynamic> json) {
    final status = _parseStatus(json['status']);
    final remaining = json['remaining_seconds'];
    return LicenseInfo(
      mode: _parseMode(json['mode']),
      status: status,
      trialActive: json['trial_active'] == true,
      trialExpired: json['trial_expired'] == true,
      firstLaunchAt: _parseTime(json['first_launch_at']),
      expiresAt: _parseTime(json['expires_at']),
      observedAt: _parseTime(json['observed_at']),
      remainingSeconds: remaining is int && remaining > 0 ? remaining : 0,
      trialDays: json['trial_days'] is int ? json['trial_days'] as int : null,
    );
  }

  static LicenseMode _parseMode(Object? raw) => switch (raw) {
        'trial' => LicenseMode.trial,
        'trial_expired' => LicenseMode.trialExpired,
        _ => LicenseMode.unknown,
      };

  static LicenseStatus _parseStatus(Object? raw) => switch (raw) {
        'active' => LicenseStatus.active,
        'expired' => LicenseStatus.expired,
        _ => LicenseStatus.unavailable,
      };

  static DateTime? _parseTime(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  /// Status as of [now]: an active trial whose `expires_at` has passed on
  /// this clock reads as expired (server-side `expired` always wins, and
  /// nothing ever upgrades to `active`).
  LicenseStatus effectiveStatusAt(DateTime now) {
    if (status != LicenseStatus.active) return status;
    final expires = expiresAt;
    if (expires != null && !expires.isAfter(now)) return LicenseStatus.expired;
    return LicenseStatus.active;
  }

  /// Time left as of [now], clamped to zero. Derived from the absolute
  /// `expires_at` when present (a snapshot stays correct as it ages), with
  /// the server-reported `remaining_seconds` as the fallback.
  Duration remainingAt(DateTime now) {
    final expires = expiresAt;
    if (expires != null) {
      final left = expires.difference(now);
      return left.isNegative ? Duration.zero : left;
    }
    return Duration(seconds: remainingSeconds);
  }
}
