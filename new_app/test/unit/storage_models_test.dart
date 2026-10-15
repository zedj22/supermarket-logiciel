// Storage & Data Usage — shared model tests.
//
// Two invariants drive this file:
//  1. `formatBytes` must cover a full disk volume (TB) without changing
//     the GB/MB/KB/B output operators already know from backups;
//  2. a StorageSection total is always *derived from its categories* —
//     it sums available bytes only, and a measurable-but-unavailable
//     category marks the report incomplete so the UI can show
//     "partial" instead of pretending the number is exact.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/storage/storage_models.dart';

void main() {
  group('formatBytes (storage page boundaries)', () {
    test('keeps the byte/KB/MB/GB output operators already know', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(40 * 1024 * 1024), '40.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('a full disk volume reads in TB', () {
      const gib = 1024 * 1024 * 1024;
      expect(formatBytes(1024 * gib), '1.00 TB');
      expect(formatBytes(5 * 1024 * gib), '5.00 TB');
      expect(formatBytes(1024 * 1024 * gib), '1024.00 TB');
    });
  });

  group('StorageSection aggregation', () {
    const section = StorageSection(
      scope: storageScopeServer,
      measuredAt: null,
      categories: [
        StorageCategory(key: 'database', available: true, bytes: 100),
        StorageCategory(key: 'backups', available: true, bytes: 40),
        StorageCategory(
          key: 'logs',
          available: false,
          reason: storageReasonNotStored,
        ),
      ],
    );

    test('not_stored contributes no bytes yet keeps the report complete', () {
      expect(section.totalBytes, 140);
      expect(section.complete, isTrue);
      expect(section.hasUnavailable, isFalse);
      expect(section.category('logs')!.isNotApplicable, isTrue);
    });

    test('a measurable-but-unavailable category makes the total partial', () {
      const partial = StorageSection(
        scope: storageScopeServer,
        measuredAt: null,
        categories: [
          StorageCategory(key: 'database', available: true, bytes: 100),
          StorageCategory(
            key: 'backups',
            available: false,
            reason: storageReasonTimeout,
          ),
        ],
      );
      expect(partial.totalBytes, 100);
      expect(partial.complete, isFalse);
      expect(partial.hasUnavailable, isTrue);
      expect(partial.category('backups')!.isMeasurableAndUnavailable, isTrue);
    });

    test('category lookup answers by key', () {
      expect(section.category('backups')?.bytes, 40);
      expect(section.category('no_such_key'), isNull);
    });
  });

  group('server payload parsing', () {
    test('re-derives totals from categories, ignoring payload claims', () {
      final parsed = StorageSection.fromJson(storageScopeServer, <String, Object>{
        'scope': 'server',
        'measured_at': '2026-10-15T10:00:00',
        // Deliberately wrong on purpose: the client must never trust them.
        'total_bytes': 999999,
        'complete': false,
        'categories': <Object>[
          <String, Object>{'key': 'database', 'available': true, 'bytes': 1000},
          <String, Object>{
            'key': 'application',
            'available': true,
            'bytes': 500,
          },
          <String, Object>{
            'key': 'backups',
            'available': false,
            'reason': 'timeout',
          },
          <String, Object>{
            'key': 'logs',
            'available': false,
            'reason': 'not_stored',
          },
        ],
        'disk': <String, Object>{
          'available': true,
          'total_bytes': 10,
          'free_bytes': 4,
        },
      });

      expect(parsed.scope, storageScopeServer);
      expect(parsed.totalBytes, 1500);
      expect(parsed.complete, isFalse); // backups timed out
      expect(parsed.measuredAt, DateTime.tryParse('2026-10-15T10:00:00'));
      expect(parsed.category('backups')?.reason, storageReasonTimeout);
      expect(parsed.disk?.available, isTrue);
      expect(parsed.disk?.totalBytes, 10);
      expect(parsed.disk?.freeBytes, 4);
    });

    test('a malformed payload degrades to empty instead of throwing', () {
      final parsed = StorageSection.fromJson(
        storageScopeServer,
        <String, Object>{
          'measured_at': 'not-a-date',
          'categories': 'not a list',
          'disk': 'not a map',
        },
      );
      expect(parsed.categories, isEmpty);
      expect(parsed.totalBytes, 0);
      expect(parsed.disk, isNull);
      expect(parsed.measuredAt, isNull);
    });

    test('an unknown disk reason still renders as unavailable', () {
      final disk = StorageDisk.fromJson(
        <String, Object>{'available': false, 'reason': 'timeout'},
      );
      expect(disk.available, isFalse);
      expect(disk.reason, storageReasonTimeout);
      expect(
        AppStrings.t(storageReasonLabelKey(disk.reason), 'en'),
        isNot('storage_unavailable'),
      );
    });
  });

  group('labels resolve for every key the measurement can produce', () {
    test('every category key has a translated label', () {
      final keys = <String>{
        ...kServerStorageCategoryKeys,
        ...kLocalStorageCategoryKeys,
      };
      expect(keys, hasLength(7));
      for (final key in keys) {
        final labelKey = storageCategoryLabelKey(key);
        expect(labelKey, isNot('storage_unavailable'), reason: key);
        for (final locale in ['ar', 'fr', 'en']) {
          final label = AppStrings.t(labelKey, locale);
          expect(label, isNot(labelKey), reason: '$labelKey@$locale');
        }
      }
    });

    test('every reason code has a translated label', () {
      final reasons = <String>{
        storageReasonMissing,
        storageReasonInMemory,
        storageReasonPermission,
        storageReasonTimeout,
        storageReasonError,
        storageReasonNotStored,
      };
      expect(kStorageReasonLabelKeys.keys.toSet(), reasons);
      for (final reason in reasons) {
        final labelKey = storageReasonLabelKey(reason);
        for (final locale in ['ar', 'fr', 'en']) {
          expect(AppStrings.t(labelKey, locale), isNot(labelKey));
        }
      }
    });

    test('unknown keys and reasons fall back to the unavailable label', () {
      expect(storageCategoryLabelKey('no_such_key'), 'storage_unavailable');
      expect(storageReasonLabelKey('no_such_reason'), 'storage_unavailable');
      expect(storageReasonLabelKey(null), 'storage_unavailable');
      expect(AppStrings.t('storage_unavailable', 'en'), 'Unavailable');
    });

    test('the local scope never claims server-owned categories', () {
      const serverOwned = {'database', 'backups', 'data', 'logs'};
      expect(
        kLocalStorageCategoryKeys.toSet().intersection(serverOwned),
        isEmpty,
        reason: 'database/backups/data/logs are measured by the backend',
      );
      expect(kLocalStorageCategoryKeys, hasLength(3));
      expect(kServerStorageCategoryKeys, hasLength(6));
    });
  });
}
