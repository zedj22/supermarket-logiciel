// Phase L1-D — the licence restrictions the backup surfaces *display*.
//
// The server owns the decision; these tests pin the presentation half of
// §4.4: which buttons the Trial-active / Trial-expired gates disable,
// which notice they show, that the snapshot is fed by the existing
// system-info flow (not by a guess), and that a server-side licensing
// rejection is reported as such rather than as "permission denied".
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/backup_restore/backup_restore_screen.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/features/settings/backup_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
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

const _settingsJson = <String, Object>{
  'store_name': 'Supermarket Pro',
  'default_paper': '80mm',
  'ask_before_print': false,
  'auto_print_invoice': false,
  'allow_debt': true,
  'low_stock_threshold': 5,
};

Map<String, Object> _listing(List<Map<String, Object>> items) =>
    <String, Object>{'items': items, 'count': items.length};

/// `license` block of a trial that is still running.
Map<String, Object> _trialLicense() => <String, Object>{
      'mode': 'trial',
      'status': 'active',
      'trial_active': true,
      'trial_expired': false,
      'remaining_seconds': 60 * 60 * 24 * 2,
      'trial_days': 14,
      'expires_at':
          DateTime.now().add(const Duration(days: 2)).toIso8601String(),
    };

/// `license` block of a trial the server already reports as elapsed.
Map<String, Object> _expiredLicense() => <String, Object>{
      'mode': 'trial_expired',
      'status': 'expired',
      'trial_active': false,
      'trial_expired': true,
      'remaining_seconds': 0,
      'trial_days': 14,
      'expires_at':
          DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
    };

LicenseInfo _licenseFrom(Map<String, Object> block) =>
    LicenseInfo.tryParse(block)!;

/// Backend stand-in for the whole backup surface + `GET /system/info`.
FakeJsonAdapter _adapter({
  List<Map<String, Object>> items = const <Map<String, Object>>[_backupJson],
  Map<String, Object>? license,
  int uploadStatus = 201,
  String? uploadCode,
}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (path.endsWith('/system/info')) {
      final body = <String, Object>{
        'name': 'Supermarket Pro',
        'version': '1.0.0',
      };
      if (license != null) body['license'] = license;
      return (statusCode: 200, body: body);
    }
    if (options.method == 'GET' && path.endsWith('/inspect')) {
      return (
        statusCode: 200,
        body: <String, Object>{
          'backup': _backupJson,
          'file_present': true,
          'sha256_ok': true,
          'current_schema_revision': '0042_seed',
          'schema_compatible': true,
          'warnings': <Object>[],
        },
      );
    }
    if (options.method == 'GET' && path.endsWith('/download')) {
      return (statusCode: 200, body: 'PK-zip-bytes');
    }
    if (options.method == 'POST' && path.endsWith('/upload')) {
      if (uploadCode != null) {
        return (
          statusCode: uploadStatus,
          body: <String, Object>{
            'error': <String, Object>{
              'code': uploadCode,
              'message': 'The server refused this backup operation.',
            },
          },
        );
      }
      return (statusCode: 201, body: _backupJson);
    }
    if (options.method == 'POST' && path.endsWith('/restore')) {
      return (
        statusCode: 200,
        body: <String, Object>{'restored': true, 'backup': _backupJson},
      );
    }
    if (options.method == 'GET' && path == '/api/v1/backups') {
      return (statusCode: 200, body: _listing(items));
    }
    if (options.method == 'POST' && path == '/api/v1/backups') {
      return (statusCode: 201, body: _backupJson);
    }
    return (statusCode: 200, body: _settingsJson);
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: <String>['admin'],
  permissions: <String>[backupRestoreScope, settingsManageScope],
);

class _FakeFilePicker extends FilePicker {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 50,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    return FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'portability.zip',
        size: 12,
        bytes: Uint8List.fromList(const <int>[0x50, 0x4B, 0x05, 0x06]),
      ),
    ]);
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
    bool readSequential = false,
  }) async {
    return 'C:/tmp/archive.zip';
  }
}

/// Mounts the Phase L1-C ingestor so `/system/info` responses really do
/// feed `licenseStatusProvider`, exactly like the running app.
class _WithIngestor extends ConsumerWidget {
  const _WithIngestor(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(licenseIngestorProvider);
    return child;
  }
}

class _BackupHarness extends StatelessWidget {
  const _BackupHarness({this.ingestor = false});

  final bool ingestor;

  @override
  Widget build(BuildContext context) {
    final screen = const Scaffold(body: BackupRestoreScreen());
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ingestor ? _WithIngestor(screen) : screen,
    );
  }
}

class _SettingsHarness extends StatelessWidget {
  const _SettingsHarness({this.ingestor = false});

  final bool ingestor;

  @override
  Widget build(BuildContext context) {
    final screen = Scaffold(body: SettingsScreen());
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ingestor ? _WithIngestor(screen) : screen,
    );
  }
}

List<Override> _overrides(
  FakeJsonAdapter adapter, {
  LicenseInfo? license,
  bool ingestor = false,
}) {
  return <Override>[
    localeProvider.overrideWith((ref) => LocaleNotifier()..setLocale(AppLocale.en)),
    currentUserProvider.overrideWithValue(_admin),
    apiClientProvider.overrideWithValue(ApiClient(dio: fakeDio(adapter))),
    if (license != null && !ingestor)
      licenseStatusProvider.overrideWith((ref) => license),
  ];
}

Future<void> _pumpBackup(
  WidgetTester tester, {
  required FakeJsonAdapter adapter,
  LicenseInfo? license,
  bool ingestor = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(adapter, license: license, ingestor: ingestor),
      child: _BackupHarness(ingestor: ingestor),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required FakeJsonAdapter adapter,
  LicenseInfo? license,
  bool ingestor = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(adapter, license: license, ingestor: ingestor),
      child: _SettingsHarness(ingestor: ingestor),
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

bool _enabled(WidgetTester tester, Finder finder) {
  final Object widget = tester.widget(finder);
  return switch (widget) {
    final FilledButton b => b.onPressed != null,
    final OutlinedButton b => b.onPressed != null,
    final IconButton b => b.onPressed != null,
    _ => throw StateError('unexpected button widget: $widget'),
  };
}

/// Installs a picker that hands back a tiny ZIP without any dialog.
void _installPicker() {
  FilePicker.platform = _FakeFilePicker();
  addTearDown(() => FilePicker.platform = FilePickerIO());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Trial active — export only', () {
    testWidgets('shows the notice and disables upload and restore only',
        (tester) async {
      await _pumpBackup(
        tester,
        adapter: _adapter(),
        license: _licenseFrom(_trialLicense()),
      );

      expect(
        find.byKey(const Key('backup-restore-license-notice')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('backup_license_trial_notice', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('backup_license_expired_notice', 'en')),
        findsNothing,
      );

      expect(_enabled(tester, find.byKey(const Key('backup-restore-create'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('backup-restore-upload'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('inspect-3'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('restore-3'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('download-3'))), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a disabled restore button never reaches the server',
        (tester) async {
      final adapter = _adapter(
        license: _trialLicense(),
        uploadCode: 'trial_upload_forbidden',
        uploadStatus: 403,
      );
      await _pumpBackup(
        tester,
        adapter: adapter,
        license: _licenseFrom(_trialLicense()),
      );

      await tester.tap(find.byKey(const Key('restore-3')));
      await tester.pumpAndSettle();

      expect(
        adapter.requests.where((r) => r.path.endsWith('/restore')),
        isEmpty,
      );
      expect(
        adapter.requests.where((r) => r.path.endsWith('/inspect')),
        isEmpty,
        reason: 'restore starts with inspect — neither may be sent',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Trial expired — read-only rescue', () {
    testWidgets('keeps listing and download, disables every write action',
        (tester) async {
      await _pumpBackup(
        tester,
        adapter: _adapter(),
        license: _licenseFrom(_expiredLicense()),
      );

      expect(
        find.text(AppStrings.t('backup_license_expired_notice', 'en')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('backup-restore-license-notice')),
        findsOneWidget,
      );

      expect(_enabled(tester, find.byKey(const Key('backup-restore-create'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('backup-restore-upload'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('inspect-3'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('restore-3'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('download-3'))), isTrue);
      // The catalogue itself is still read.
      expect(find.text('backup_20261003_153000.sql'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Unknown licence state', () {
    testWidgets('disables nothing and shows no restriction notice',
        (tester) async {
      await _pumpBackup(tester, adapter: _adapter());

      expect(
        find.byKey(const Key('backup-restore-license-notice')),
        findsNothing,
      );
      expect(_enabled(tester, find.byKey(const Key('backup-restore-create'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('backup-restore-upload'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('inspect-3'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('restore-3'))), isTrue);
      expect(_enabled(tester, find.byKey(const Key('download-3'))), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('the system-info flow drives the restrictions', () {
    testWidgets('a licence block in GET /system/info turns the gate on',
        (tester) async {
      await _pumpBackup(
        tester,
        adapter: _adapter(license: _trialLicense()),
        ingestor: true,
      );

      expect(
        find.byKey(const Key('backup-restore-license-notice')),
        findsOneWidget,
        reason: 'the notice must come from the ingested system-info block',
      );
      expect(
        find.text(AppStrings.t('backup_license_trial_notice', 'en')),
        findsOneWidget,
      );
      expect(_enabled(tester, find.byKey(const Key('backup-restore-upload'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('restore-3'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('backup-restore-create'))),
          isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an expired block read through the same flow locks the '
        'write actions', (tester) async {
      await _pumpBackup(
        tester,
        adapter: _adapter(license: _expiredLicense()),
        ingestor: true,
      );

      expect(
        find.text(AppStrings.t('backup_license_expired_notice', 'en')),
        findsOneWidget,
      );
      expect(_enabled(tester, find.byKey(const Key('backup-restore-create'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('restore-3'))), isFalse);
      expect(_enabled(tester, find.byKey(const Key('download-3'))), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('server-side refusals keep their identity', () {
    testWidgets('a licensing rejection is not reported as permission denied',
        (tester) async {
      final adapter = _adapter(
        uploadCode: 'trial_upload_forbidden',
        uploadStatus: 403,
      );
      await _pumpBackup(tester, adapter: adapter);
      _installPicker();

      await _tap(tester, find.byKey(const Key('backup-restore-upload')));

      expect(
        find.text(
          AppStrings.t('license_error_upload_forbidden', 'en'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('permission_denied', 'en')),
        findsNothing,
      );
      await _drainToasts(tester);
    });

    testWidgets('a 503 licence check is not reported as a generic retry',
        (tester) async {
      final adapter = _adapter(
        uploadCode: 'license_status_unavailable',
        uploadStatus: 503,
      );
      await _pumpBackup(tester, adapter: adapter);
      _installPicker();

      await _tap(tester, find.byKey(const Key('backup-restore-upload')));

      expect(
        find.text(AppStrings.t('license_error_status_unavailable', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('api_error_retry', 'en')),
        findsNothing,
      );
      await _drainToasts(tester);
    });
  });

  group('Settings → Backups card', () {
    testWidgets('an active trial keeps create and disables restore',
        (tester) async {
      await _pumpSettings(
        tester,
        adapter: _adapter(),
        license: _licenseFrom(_trialLicense()),
      );

      expect(
        find.byKey(const Key('settings-backup-license-notice')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('backup_license_trial_notice', 'en')),
        findsOneWidget,
      );
      expect(_enabled(tester, find.byKey(const Key('settings-backup-create'))), isTrue);
      expect(
        _enabled(tester, find.byKey(const Key('settings-backup-restore-3'))),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an expired trial disables create and restore alike',
        (tester) async {
      await _pumpSettings(
        tester,
        adapter: _adapter(),
        license: _licenseFrom(_expiredLicense()),
      );

      expect(
        find.text(AppStrings.t('backup_license_expired_notice', 'en')),
        findsOneWidget,
      );
      expect(_enabled(tester, find.byKey(const Key('settings-backup-create'))), isFalse);
      expect(
        _enabled(tester, find.byKey(const Key('settings-backup-restore-3'))),
        isFalse,
      );
      expect(find.text('backup_20261003_153000.sql'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no licence block means no notice and no disabled action',
        (tester) async {
      await _pumpSettings(tester, adapter: _adapter());

      expect(
        find.byKey(const Key('settings-backup-license-notice')),
        findsNothing,
      );
      expect(_enabled(tester, find.byKey(const Key('settings-backup-create'))), isTrue);
      expect(
        _enabled(tester, find.byKey(const Key('settings-backup-restore-3'))),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
