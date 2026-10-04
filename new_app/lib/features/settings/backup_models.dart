import 'package:flutter/foundation.dart';

/// One server-side backup — the `GET /api/v1/backups` item and the body of
/// `POST /api/v1/backups` (Phase 17, §17.2).
///
/// Backups live on the **server's disk**, not in the app: this client only
/// lists them and asks the server to take or replay one.  Nothing here is
/// ever uploaded or downloaded locally.
@immutable
class BackupInfo {
  const BackupInfo({
    required this.id,
    required this.filename,
    required this.size,
    required this.createdAt,
    this.sha256,
    this.schemaRevision,
    this.pgDumpVersion,
    this.appVersion,
  });

  /// Relative path of the list + create endpoints.  Restore appends
  /// `/<id>/restore`.
  static const String backupsPath = '/api/v1/backups';

  final int id;
  final String filename;
  final int size;
  final DateTime createdAt;

  /// SHA-256 recorded at creation; the server re-checks it before a restore.
  final String? sha256;
  final String? schemaRevision;
  final String? pgDumpVersion;
  final String? appVersion;

  factory BackupInfo.fromJson(Map<String, dynamic> json) {
    return BackupInfo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      filename: json['filename'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sha256: json['sha256'] as String?,
      schemaRevision: json['schema_revision'] as String?,
      pgDumpVersion: json['pg_dump_version'] as String?,
      appVersion: json['app_version'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BackupInfo &&
          other.id == id &&
          other.filename == filename &&
          other.size == size &&
          other.createdAt == createdAt);

  @override
  int get hashCode => Object.hash(id, filename, size, createdAt);

  @override
  String toString() =>
      'BackupInfo(id: $id, filename: $filename, size: $size)';
}

/// Parses the `items` array of `GET /api/v1/backups`.
List<BackupInfo> parseBackupList(dynamic data) {
  if (data is! Map<String, dynamic>) return const <BackupInfo>[];
  final items = data['items'];
  if (items is! List) return const <BackupInfo>[];
  return items
      .whereType<Map<String, dynamic>>()
      .map(BackupInfo.fromJson)
      .toList(growable: false);
}

/// Human-readable byte size — a backup is tens of MB, so raw bytes are noise.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const kb = 1024.0;
  const mb = kb * 1024;
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  if (bytes < mb * 1024) {
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (mb * 1024)).toStringAsFixed(2)} GB';
}

/// `YYYY-MM-DD HH:mm` in the device's local time, deliberately
/// locale-neutral: an ISO-ish timestamp reads the same in ar/fr/en and is
/// what the operator compares against a file name.
String formatBackupDate(DateTime value) {
  final local = value.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  if (local.millisecondsSinceEpoch == 0) return '—';
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
