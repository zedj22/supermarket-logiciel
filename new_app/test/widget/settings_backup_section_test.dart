// Phase 17 (§17.2) — the Backups card in Settings.
//
// What matters here is what the screen is allowed to *claim*:
//  * the section only exists for `backup_restore` (admin), like its API;
//  * "Backup created" / "Backup restored" appear only after a 2xx;
//  * a refused restore says so instead of staying silent;
//  * the confirmation dialog can be cancelled without touching the server.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
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
};

Map<String, Object> _listing(List<Map<String, Object>> items) =>
    <String, Object>{'items': items, 'count': items.length};

const _settingsJson = <String, Object>{
  'store_name': 'Supermarket Pro',
  'store_phone': '',
  'store_address': '',
  'invoice_footer': '',
  'default_paper': '80mm',
  'ask_before_print': false,
  'auto_print_invoice': false,
  'allow_debt': true,
  'low_stock_threshold': 5,
};

/// A backend stand-in: `GET /backups` answers with [items], `POST /backups`
/// and `POST /backups/{id}/restore` obey the failure flags.
FakeJsonAdapter _adapter({
  List<Map<String, Object>> items = const <Map<String, Object>>[_backupJson],
  bool failCreate = false,
  bool failRestore = false,
  bool emptyAfterCreate = false,
}) {
  return FakeJsonAdapter((options) async {
    final path = options.path;
    if (options.method == 'POST' && path == '/api/v1/backups') {
      if (failCreate) {
        return (
          statusCode: 500,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'internal_error',
              'message': 'no space left on device',
            },
          },
        );
      }
      return (
        statusCode: 201,
        body: emptyAfterCreate ? <String, Object>{} : _backupJson,
      );
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
      return (statusCode: 200, body: _listing(items));
    }
    // /settings (any other path)
    return (statusCode: 200, body: _settingsJson);
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: [backupRestoreScope, settingsManageScope],
);

const AuthUser _cashier = AuthUser(
  id: 'u-2',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: ['cashier'],
  permissions: <String>[],
);

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
      child: const _BackupHarness(),
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

class _BackupHarness extends StatelessWidget {
  const _BackupHarness();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: SettingsScreen()),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Backups card', () {
    testWidgets('is rendered for backup_restore and hidden otherwise',
        (tester) async {
      await _pump(
        tester,
        user: _admin,
        adapter: _adapter(),
      );

      expect(find.byKey(const Key('settings-backup-section')), findsOneWidget);
      expect(find.text(AppStrings.t('backups', 'en')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cashier never sees it and never calls the API',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _cashier, adapter: adapter);

      expect(
        find.byKey(const Key('settings-backup-section')),
        findsNothing,
      );
      expect(
        adapter.requests.where((r) => r.path == '/api/v1/backups'),
        isEmpty,
        reason: 'a non-admin must not issue a backup request at all',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists the catalogue with size and date', (tester) async {
      await _pump(tester, user: _admin, adapter: _adapter());

      expect(
        find.byKey(const Key('settings-backup-list')),
        findsOneWidget,
      );
      expect(find.text('backup_20261003_153000.sql'), findsOneWidget);
      expect(find.textContaining('40.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty catalogue says so instead of showing a blank card',
        (tester) async {
      await _pump(
        tester,
        user: _admin,
        adapter: _adapter(items: const <Map<String, Object>>[]),
      );

      expect(find.byKey(const Key('settings-backup-empty')), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_empty', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('creating a backup announces it only after the 201',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('settings-backup-create')));

      final posts =
          adapter.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.path, '/api/v1/backups');

      expect(find.text(AppStrings.t('backup_created', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_create_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed create says failed and never says created',
        (tester) async {
      final adapter = _adapter(failCreate: true);
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(tester, find.byKey(const Key('settings-backup-create')));

      expect(
        find.text(AppStrings.t('backup_create_failed', 'en')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('backup_created', 'en')), findsNothing);
      expect(find.textContaining('no space left on device'), findsOneWidget,
          reason: 'the operator needs the real reason');
      expect(
        find.text(AppStrings.t('backup_load_failed', 'en')),
        findsNothing,
          reason: 'a failed create must not be reported as a failed load',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('restoring asks for confirmation first', (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(
        tester,
        find.byKey(const Key('settings-backup-restore-3')),
      );

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_restore_confirm', 'en')),
        findsOneWidget,
      );
      expect(
        adapter.requests.where((r) => r.method == 'POST'),
        isEmpty,
        reason: 'nothing must be replayed before the operator confirms',
      );

      await _tap(tester, find.byKey(const Key('settings-backup-cancel')));

      expect(find.byType(AlertDialog), findsNothing);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a confirmed restore posts and announces success',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(
        tester,
        find.byKey(const Key('settings-backup-restore-3')),
      );
      await _tap(tester, find.byKey(const Key('settings-backup-confirm')));

      final posts =
          adapter.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.path, '/api/v1/backups/3/restore');

      expect(find.text(AppStrings.t('backup_restored', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('backup_restore_failed', 'en')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refused restore is reported as a failure',
        (tester) async {
      final adapter = _adapter(failRestore: true);
      await _pump(tester, user: _admin, adapter: adapter);

      await _tap(
        tester,
        find.byKey(const Key('settings-backup-restore-3')),
      );
      await _tap(tester, find.byKey(const Key('settings-backup-confirm')));

      expect(
        find.text(AppStrings.t('backup_restore_failed', 'en')),
        findsOneWidget,
      );
      expect(find.text(AppStrings.t('backup_restored', 'en')), findsNothing);
      expect(find.textContaining('modified since it was created'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
