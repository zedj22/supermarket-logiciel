// Phase 17 (§17.2) — backup payload parsing and display formatting.
//
// The list is the operator's only view of what exists on the server, so a
// malformed entry must degrade to something honest (id 0 / empty name /
// epoch date) rather than throw and blank the whole section.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/settings/backup_models.dart';

const _json = <String, Object>{
  'id': 7,
  'filename': 'backup_20261003_153000.sql',
  'size': 2048,
  'created_at': '2026-10-03T15:30:52+00:00',
  'sha256': 'abc123',
  'schema_revision': 'e7d4a9c1f3b6',
  'pg_dump_version': 'pg_dump (PostgreSQL) 18.6',
  'app_version': '0.1.0',
};

void main() {
  group('BackupInfo.fromJson', () {
    test('reads every field the backend sends', () {
      final info = BackupInfo.fromJson(_json);

      expect(info.id, 7);
      expect(info.filename, 'backup_20261003_153000.sql');
      expect(info.size, 2048);
      expect(info.sha256, 'abc123');
      expect(info.schemaRevision, 'e7d4a9c1f3b6');
      expect(info.pgDumpVersion, 'pg_dump (PostgreSQL) 18.6');
      expect(info.appVersion, '0.1.0');
      expect(info.createdAt.toUtc().year, 2026);
    });

    test('tolerates an adopted manifest with only the contract fields', () {
      final info = BackupInfo.fromJson(<String, Object>{
        'id': 1,
        'filename': 'copied_by_hand.sql',
        'size': 9,
        'created_at': '2026-01-01T00:00:00+00:00',
      });

      expect(info.sha256, isNull);
      expect(info.schemaRevision, isNull);
      expect(info.pgDumpVersion, isNull);
    });

    test('never throws on a partial or malformed payload', () {
      final empty = BackupInfo.fromJson(const <String, Object>{});
      expect(empty.id, 0);
      expect(empty.filename, '');
      expect(empty.size, 0);
      // epoch ⇒ formatBackupDate renders the placeholder instead of 1970
      expect(formatBackupDate(empty.createdAt), '—');
    });
  });

  group('parseBackupList', () {
    test('parses the items array', () {
      final items = parseBackupList(<String, Object>{
        'items': <Object>[_json],
        'count': 1,
      });
      expect(items, hasLength(1));
      expect(items.single.id, 7);
    });

    test('returns an empty list for anything that is not a listing', () {
      expect(parseBackupList(null), isEmpty);
      expect(parseBackupList(<Object>[]), isEmpty);
      expect(parseBackupList(<String, Object>{'items': 'nope'}), isEmpty);
      expect(
        parseBackupList(<String, Object>{
          'items': <Object>['not a map'],
        }),
        isEmpty,
      );
    });
  });

  group('formatBytes', () {
    test('uses the unit an operator expects', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(40 * 1024 * 1024), '40.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });
  });

  group('formatBackupDate', () {
    test('renders local time as YYYY-MM-DD HH:mm', () {
      final value = DateTime.utc(2026, 10, 3, 15, 30).toLocal();
      expect(formatBackupDate(value), matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    });

    test('the epoch placeholder is a dash, not 1970', () {
      expect(
        formatBackupDate(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
        '—',
      );
    });
  });
}
