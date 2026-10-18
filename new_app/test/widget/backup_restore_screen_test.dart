// Objective 2 — the Backup & Restore screen.
//
// What matters here is what the screen is allowed to *claim*:
//  * the page (and its catalogue request) only exists for
//    `backup_restore` — a cashier never issues a request at all;
//  * a restore confirmation shows the server's inspect summary first
//    and is REFUSED (button disabled, no POST) when the dump file is
//    missing or its recorded hash no longer matches;
//  * an inspect failure aborts the restore instead of offering a blind
//    confirm;
//  * download / upload / create announce success only after a 2xx and
//    surface the real reason otherwise.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/backup_restore/backup_restore_screen.dart';
import 'package:supermarket_pos/features/settings/backup_models.dart';
import 'package:supermarket_pos/features/settings/backup_provider.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/settings_fake_adapter.dart';

const _backupJson = <String, Object>{
  'id': 3,
  'filename': 'backup_20261003_153000.sql',
  'size': 40 * 1024 * 1024,
  'created_at': '2026-10-03T15:30:52+00:00',
  'sha256': 'e3b0c44298fc1c149afbf4c8996fb924',
  'schema_revision': '0042_seed',
};

Map<String, Object> _listing(List<Map<String, Object>> items) =>
    <String, Object>{'items': items, 'count': items.length};

const _inspectOk = <String, Object>{
  'backup': _backupJson,
  'file_present': true,
  'sha256_ok': true,
  'current_schema_revision': '0042_seed',
  'schema_compatible': true,
  'warnings': <Object>[],
};

/// A backend stand-in for the whole surface: list, inspect, download,
/// upload and restore — each with its own failure flag.
FakeJsonAdapter _adapter({
  List<Map<String, Object>> items = const <Map<String, Object>>[_backupJson],
  bool failList = false,
  bool failInspect = false,
  Map<String, Object?>? inspect,
  bool failDownload = false,
  bool failUpload = false,
  bool failRestore = false,
}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (options.method == 'GET' && path.endsWith('/inspect')) {
      if (failInspect) {
        return (
          statusCode: 404,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'not_found',
              'message': 'backup 3 was not found',
            },
          },
        );
      }
      return (statusCode: 200, body: inspect ?? _inspectOk);
    }
    if (options.method == 'GET' && path.endsWith('/download')) {
      if (failDownload) {
        return (
          statusCode: 500,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'internal_error',
              'message': 'dump volume unreadable',
            },
          },
        );
      }
      return (statusCode: 200, body: 'PK-zip-bytes');
    }
    if (options.method == 'POST' && path.endsWith('/upload')) {
      if (failUpload) {
        return (
          statusCode: 413,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'BACKUP_TOO_LARGE',
              'message': 'The archive exceeds the 200 MB limit.',
            },
          },
        );
      }
      return (statusCode: 201, body: _backupJson);
    }
    if (options.method == 'POST' && path.endsWith('/restore')) {
      if (failRestore) {
        return (
          statusCode: 422,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'BUSINESS_RULE_ERROR',
              'message': 'This backup has been modified since it was '
                  'created and will not be restored.',
            },
          },
        );
      }
      return (
        statusCode: 200,
        body: <String, Object>{'restored': true, 'backup': _backupJson},
      );
    }
    if (path == '/api/v1/backups') {
      if (failList) {
        return (
          statusCode: 500,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'internal_error',
              'message': 'pg_dump unavailable',
            },
          },
        );
      }
      return (statusCode: 200, body: _listing(items));
    }
    return (statusCode: 200, body: <String, Object>{});
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: <String>['admin'],
  permissions: <String>[backupRestoreScope],
);

const AuthUser _cashier = AuthUser(
  id: 'u-2',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: <String>['cashier'],
  permissions: <String>[],
);

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker({this.pickResult, this.savedPath});

  final FilePickerResult? pickResult;
  final String? savedPath;

  int pickCount = 0;
  int saveCount = 0;
  String? lastTitle;
  String? lastFileName;
  Uint8List? lastBytes;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCount++;
    return pickResult;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saveCount++;
    lastTitle = dialogTitle;
    lastFileName = fileName;
    lastBytes = bytes;
    return savedPath;
  }
}

FilePickerResult _zipPick() => FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'portability.zip',
        size: 12,
        bytes: Uint8List.fromList(const <int>[0x50, 0x4B, 0x05, 0x06]),
      ),
    ]);

Future<void> _pump(
  WidgetTester tester, {
  required AuthUser user,
  required FakeJsonAdapter adapter,
  AppLocale locale = AppLocale.en,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localeProvider.overrideWith(
          (ref) => LocaleNotifier()..setLocale(locale),
        ),
        currentUserProvider.overrideWithValue(user),
        apiClientProvider.overrideWithValue(ApiClient(dio: fakeDio(adapter))),
      ],
      child: const _BackupRestoreHarness(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Lets every toast dismiss timer fire so no timer leaks past the test.
Future<void> _drainToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

class _BackupRestoreHarness extends StatelessWidget {
  const _BackupRestoreHarness();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: BackupRestoreScreen()),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Backup & restore gate', () {
    testWidgets('a cashier sees permission denied and never calls the API',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _cashier, adapter: adapter);

      expect(
        find.byKey(const Key('backup-restore-denied')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('backup-restore-title')), findsNothing);
      expect(adapter.requests, isEmpty,
          reason: 'a non-admin must not trigger a catalogue request');
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists the catalogue with date and size', (tester) async {
      await _pump(tester, user: _admin, adapter: _adapter());

      expect(find.text('backup_20261003_153000.sql'), findsOneWidget);
      expect(find.textContaining('40.0 MB'), findsOneWidget);
      // The date renders in the machine's local time, so the expected
      // string is computed exactly like the screen computes it.
      expect(
        find.textContaining(
          formatBackupDate(DateTime.parse('2026-10-03T15:30:52+00:00')),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('backup-restore-safety')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Inspect', () {
    testWidgets('shows the integrity summary without any restore call',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('inspect-3')));

      final inspects = adapter.requests
          .where((r) => r.path.endsWith('/inspect'))
          .toList();
      expect(inspects, hasLength(1));
      expect(
        adapter.requests.where((r) => r.method == 'POST'),
        isEmpty,
        reason: 'inspecting must never post a restore',
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(AppStrings.t('br_integrity_ok', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('inspect-close')), findsOneWidget);
      expect(find.byKey(const Key('restore-confirm')), findsNothing);

      await _tap(tester, find.byKey(const Key('inspect-close')));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Restore', () {
    testWidgets('a confirmed restore posts confirm:true and announces it',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('restore-3')));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_restore_confirm', 'en')),
        findsOneWidget,
      );

      await _tap(tester, find.byKey(const Key('restore-confirm')));

      final posts =
          adapter.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.path, '/api/v1/backups/3/restore');
      final body = posts.single.data;
      expect(body, isA<Map<String, dynamic>>());
      expect((body as Map)['confirm'], true);

      expect(
        find.text(AppStrings.t('backup_restored', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('backup_restore_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a hash mismatch disables the confirm button and never '
        'posts', (tester) async {
      final adapter = _adapter(
        inspect: const <String, Object>{
          'backup': _backupJson,
          'file_present': true,
          'sha256_ok': false,
          'schema_compatible': true,
          'warnings': <Object>['hash does not match the manifest'],
        },
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('restore-3')));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(AppStrings.t('br_integrity_bad', 'en')),
        findsOneWidget,
      );
      expect(
        find.text('hash does not match the manifest'),
        findsOneWidget,
      );
      final confirm =
          tester.widget<FilledButton>(find.byKey(const Key('restore-confirm')));
      expect(confirm.onPressed, isNull,
          reason: 'the operator must not be able to confirm a tampered file');
      expect(
        adapter.requests.where((r) => r.method == 'POST'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a missing dump file disables the confirm button',
        (tester) async {
      final adapter = _adapter(
        inspect: const <String, Object?>{
          'backup': _backupJson,
          'file_present': false,
          'sha256_ok': null,
          'schema_compatible': null,
          'warnings': <Object>[],
        },
      );
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('restore-3')));

      expect(
        find.byKey(const Key('inspect-file-missing')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('br_integrity_unknown', 'en')),
        findsOneWidget,
      );
      final confirm =
          tester.widget<FilledButton>(find.byKey(const Key('restore-confirm')));
      expect(confirm.onPressed, isNull);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed inspect aborts the restore with a message and '
        'never offers the dialog', (tester) async {
      final adapter = _adapter(failInspect: true);
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('restore-3')));

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(AppStrings.t('backup_restore_failed', 'en')),
        findsOneWidget,
      );
      expect(find.textContaining('backup 3 was not found'), findsOneWidget);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a refused restore is reported as a failure', (tester) async {
      final adapter = _adapter(failRestore: true);
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('restore-3')));
      await _tap(tester, find.byKey(const Key('restore-confirm')));

      expect(
        find.text(AppStrings.t('backup_restore_failed', 'en')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('backup_restored', 'en')), findsNothing);
      expect(
        find.textContaining('modified since it was created'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });

  group('Download', () {
    testWidgets('a 200 hands the archive to the save dialog', (tester) async {
      final adapter = _adapter();
      final picker = _FakeFilePicker(savedPath: 'C:/tmp/archive.zip');
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('download-3')));

      final gets = adapter.requests
          .where((r) => r.path.endsWith('/download'))
          .toList();
      expect(gets, hasLength(1));
      expect(picker.saveCount, 1);
      expect(picker.lastFileName, 'backup_20261003_153000.zip',
          reason: 'the .sql dump travels as a .zip archive');
      expect(picker.lastBytes, isNotNull);
      expect(
        find.text(AppStrings.t('br_download_ready', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('br_download_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a failed download says failed with the reason and never '
        'opens the save dialog', (tester) async {
      final adapter = _adapter(failDownload: true);
      final picker = _FakeFilePicker(savedPath: 'C:/tmp/archive.zip');
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('download-3')));

      expect(picker.saveCount, 0);
      expect(
        find.text(AppStrings.t('br_download_failed', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('br_download_ready', 'en')),
        findsNothing,
      );
      expect(find.textContaining('dump volume unreadable'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });

  group('Upload', () {
    testWidgets('posts the picked archive as multipart and reloads',
        (tester) async {
      final adapter = _adapter();
      final picker = _FakeFilePicker(pickResult: _zipPick());
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('backup-restore-upload')));

      final uploads = adapter.requests
          .where((r) => r.path.endsWith('/upload'))
          .toList();
      expect(uploads, hasLength(1));
      final data = uploads.single.data;
      expect(data, isA<FormData>());
      final form = data as FormData;
      expect(form.files.single.value.filename, 'portability.zip');
      expect(
        uploads.single.headers['content-type'],
        startsWith('multipart/form-data'),
      );
      // The catalogue was re-read after the upload.
      expect(
        adapter.requests.where((r) => r.path == '/api/v1/backups').length,
        greaterThanOrEqualTo(2),
      );

      expect(
        find.text(AppStrings.t('br_upload_success', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('br_upload_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a refused upload says failed with the reason and never '
        'says success', (tester) async {
      final adapter = _adapter(failUpload: true);
      final picker = _FakeFilePicker(pickResult: _zipPick());
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('backup-restore-upload')));

      expect(
        find.text(AppStrings.t('br_upload_failed', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('br_upload_success', 'en')),
        findsNothing,
      );
      expect(find.textContaining('exceeds the 200 MB limit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });

  group('Create', () {
    testWidgets('announces a created backup only after the 201',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('backup-restore-create')));

      final posts = adapter.requests
          .where((r) => r.method == 'POST' && r.path == '/api/v1/backups')
          .toList();
      expect(posts, hasLength(1));
      expect(
        find.text(AppStrings.t('backup_created', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });

  group('List failures', () {
    testWidgets('a failed load is reported instead of a silent empty list',
        (tester) async {
      final adapter = _adapter(failList: true);
      await _pump(tester, user: _admin, adapter: adapter);

      expect(find.byKey(const Key('backup-restore-error')), findsOneWidget);
      expect(find.textContaining('pg_dump unavailable'), findsOneWidget);
      expect(
        find.byKey(const Key('backup-restore-empty')),
        findsNothing,
        reason: 'a failed load must not claim that there are no backups',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty catalogue says so', (tester) async {
      final adapter = _adapter(items: const <Map<String, Object>>[]);
      await _pump(tester, user: _admin, adapter: adapter);

      expect(find.byKey(const Key('backup-restore-empty')), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_empty', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
