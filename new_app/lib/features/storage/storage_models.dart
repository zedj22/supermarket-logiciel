// Storage & Data Usage — shared models for the local (this computer) and
// server sections of the storage page.
//
// Both scopes use the same shape so the UI renders one widget twice:
// a section is a scope label, a measurement timestamp, a list of
// categories (each either measured or unavailable-with-a-reason) and the
// capacity of the relevant disk volume.  Aggregation is derived here —
// `totalBytes` only ever sums available categories, and `complete` is
// false when a measurable category is missing — so a partial report can
// never be presented as an exact total.
import 'package:flutter/foundation.dart';

export 'package:supermarket_pos/features/settings/backup_models.dart'
    show formatBackupDate, formatBytes;

/// Measured on this computer (application files, saved exports, cache).
const String storageScopeLocal = 'local';

/// Measured by the backend on the machine that runs PostgreSQL.
const String storageScopeServer = 'server';

/// Stable category keys — backend JSON and the local probe both use them.
const String storageCategoryApplication = 'application';
const String storageCategoryExports = 'exports';
const String storageCategoryCacheTemp = 'cache_temp';
const String storageCategoryDatabase = 'database';
const String storageCategoryBackups = 'backups';
const String storageCategoryData = 'data';
const String storageCategoryLogs = 'logs';

/// The server tree is a partition: these keys arrive in this order.
const List<String> kServerStorageCategoryKeys = <String>[
  storageCategoryDatabase,
  storageCategoryApplication,
  storageCategoryBackups,
  storageCategoryData,
  storageCategoryCacheTemp,
  storageCategoryLogs,
];

/// What this computer can own: never the database (that is server-side).
const List<String> kLocalStorageCategoryKeys = <String>[
  storageCategoryApplication,
  storageCategoryExports,
  storageCategoryCacheTemp,
];

/// Reason codes shared with the backend response.
const String storageReasonMissing = 'missing';
const String storageReasonInMemory = 'in_memory';
const String storageReasonPermission = 'permission';
const String storageReasonTimeout = 'timeout';
const String storageReasonError = 'error';
const String storageReasonNotStored = 'not_stored';

/// Category key → `AppStrings` label key (literal keys so the localization
/// coverage test can verify every one of them in all three locales).
const Map<String, String> kStorageCategoryLabelKeys =
    <String, String>{
  storageCategoryDatabase: 'storage_cat_database',
  storageCategoryApplication: 'storage_cat_application',
  storageCategoryBackups: 'storage_cat_backups',
  storageCategoryData: 'storage_cat_data',
  storageCategoryCacheTemp: 'storage_cat_cache_temp',
  storageCategoryLogs: 'storage_cat_logs',
  storageCategoryExports: 'storage_cat_exports',
};

/// Reason code → `AppStrings` label key.
const Map<String, String> kStorageReasonLabelKeys = <String, String>{
  storageReasonMissing: 'storage_reason_missing',
  storageReasonInMemory: 'storage_reason_in_memory',
  storageReasonPermission: 'storage_reason_permission',
  storageReasonTimeout: 'storage_reason_timeout',
  storageReasonError: 'storage_reason_error',
  storageReasonNotStored: 'storage_reason_not_stored',
};

/// Defensive fallback: an unknown key still renders something readable.
String storageCategoryLabelKey(String key) =>
    kStorageCategoryLabelKeys[key] ?? 'storage_unavailable';

String storageReasonLabelKey(String? reason) =>
    kStorageReasonLabelKeys[reason ?? ''] ?? 'storage_unavailable';

/// One measured (or unavailable) storage category.
@immutable
class StorageCategory {
  const StorageCategory({
    required this.key,
    required this.available,
    this.bytes,
    this.reason,
  }) : assert(!available || bytes != null);

  const StorageCategory.unavailable(this.key, this.reason)
    : available = false,
      bytes = null;

  final String key;
  final bool available;
  final int? bytes;
  final String? reason;

  /// `not_stored` means "nothing lives here by design" (the backend logs
  /// to stdout only) — not a failed measurement, so it never makes a
  /// report incomplete.
  bool get isNotApplicable => reason == storageReasonNotStored;

  bool get isMeasurableAndUnavailable => !available && !isNotApplicable;

  factory StorageCategory.fromJson(Map<String, dynamic> json) {
    return StorageCategory(
      key: json['key'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      bytes: (json['bytes'] as num?)?.toInt(),
      reason: json['reason'] as String?,
    );
  }

  @override
  String toString() =>
      'StorageCategory($key, available: $available, bytes: $bytes)';
}

/// Capacity of the volume relevant to a section (read-only).
@immutable
class StorageDisk {
  const StorageDisk({
    required this.available,
    this.totalBytes,
    this.freeBytes,
    this.reason,
  });

  const StorageDisk.unavailable([this.reason = storageReasonError])
    : available = false,
      totalBytes = null,
      freeBytes = null;

  final bool available;
  final int? totalBytes;
  final int? freeBytes;
  final String? reason;

  factory StorageDisk.fromJson(Map<String, dynamic> json) {
    if (json['available'] != true) {
      return StorageDisk.unavailable(json['reason'] as String?);
    }
    return StorageDisk(
      available: true,
      totalBytes: (json['total_bytes'] as num?)?.toInt(),
      freeBytes: (json['free_bytes'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'StorageDisk(available: $available, total: $totalBytes)';
}

/// Everything the page shows for one computer (local) or the server.
@immutable
class StorageSection {
  const StorageSection({
    required this.scope,
    required this.measuredAt,
    required this.categories,
    this.disk,
  });

  final String scope;
  final DateTime? measuredAt;
  final List<StorageCategory> categories;
  final StorageDisk? disk;

  /// Sum of the *available* categories only — the categories are disjoint
  /// by construction (one partitioning walk per scope), so no byte is
  /// ever counted twice.
  int get totalBytes => categories.fold(
    0,
    (sum, category) => sum + (category.available ? (category.bytes ?? 0) : 0),
  );

  /// False when any measurable category is unavailable: the UI must then
  /// mark the total as partial instead of claiming exactness.
  bool get complete =>
      categories.every((c) => c.available || c.isNotApplicable);

  bool get hasUnavailable =>
      categories.any((category) => category.isMeasurableAndUnavailable);

  StorageCategory? category(String key) {
    for (final category in categories) {
      if (category.key == key) return category;
    }
    return null;
  }

  /// Parses `GET /api/v1/storage` (server scope).  The payload's own
  /// `complete`/`total_bytes` fields are ignored on purpose: totals are
  /// always re-derived from the category list right here.
  factory StorageSection.fromJson(String scope, Map<String, dynamic> json) {
    final rawCategories = json['categories'];
    return StorageSection(
      scope: scope,
      measuredAt: DateTime.tryParse(json['measured_at'] as String? ?? ''),
      categories: rawCategories is List
          ? rawCategories
                .whereType<Map<String, dynamic>>()
                .map(StorageCategory.fromJson)
                .toList(growable: false)
          : const <StorageCategory>[],
      disk: json['disk'] is Map<String, dynamic>
          ? StorageDisk.fromJson(json['disk'] as Map<String, dynamic>)
          : null,
    );
  }

  @override
  String toString() =>
      'StorageSection($scope, categories: ${categories.length}, '
      'total: $totalBytes, complete: $complete)';
}
