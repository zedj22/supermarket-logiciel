// Objective 1 — the Data Transfer screen.
//
// What matters here is what the screen is allowed to *claim*:
//  * the page only exists for `product_view`, export needs
//    `export_data`, import needs `product_create` — and a cashier
//    never issues a request at all;
//  * a successful export/import is announced only after a 2xx, and a
//    refused one always shows the reason;
//  * the preview (dry run) never claims that anything was applied;
//  * the multipart body really carries the picked file, `dry_run` and
//    `on_conflict` as the backend expects them.
import 'dart:convert';
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
import 'package:supermarket_pos/features/data_transfer/data_transfer_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/network/api_client.dart';

import '../helpers/settings_fake_adapter.dart';

const _importReport = <String, Object>{
  'dry_run': true,
  'applied': false,
  'filename': 'catalog.csv',
  'format': 'csv',
  'total_rows': 4,
  'created': 1,
  'updated': 1,
  'skipped': 1,
  'failed': 1,
  'mapping': <String, Object>{'name': 0, 'barcode': 1},
  'unmapped_columns': <Object>['legacy_col'],
  'rows': <Object>[
    <String, Object>{
      'row': 2,
      'action': 'create',
      'name': 'Widget',
      'messages': <Object>[],
    },
    <String, Object>{
      'row': 9,
      'action': 'failed',
      'name': 'Bad',
      'messages': <Object>['price must be a number'],
    },
  ],
  'warnings': <Object>[],
};

/// A backend stand-in for the two endpoints: export answers with bytes,
/// import echoes the `dry_run` flag it received so the report card can
/// be asserted for preview *and* apply.
FakeJsonAdapter _adapter({bool failExport = false, bool failImport = false}) {
  return FakeJsonAdapter((options) async {
    if (options.path == '/api/v1/products/export') {
      if (failExport) {
        return (
          statusCode: 403,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'permission_denied',
              'message': 'missing export_data permission',
            },
          },
        );
      }
      return (statusCode: 200, body: 'name,barcode\nWidget,123\n');
    }
    if (options.path == '/api/v1/products/import') {
      if (failImport) {
        return (
          statusCode: 413,
          body: <String, Object>{
            'error': <String, Object>{
              'code': 'IMPORT_FILE_TOO_LARGE',
              'message': 'The import file exceeds the 20 MB limit.',
            },
          },
        );
      }
      var dryRun = true;
      final data = options.data;
      if (data is FormData) {
        for (final field in data.fields) {
          if (field.key == 'dry_run') dryRun = field.value == 'true';
        }
      }
      return (
        statusCode: 200,
        body: <String, Object>{
          ..._importReport,
          'dry_run': dryRun,
          'applied': !dryRun,
        },
      );
    }
    return (statusCode: 200, body: <String, Object>{});
  });
}

const AuthUser _manager = AuthUser(
  id: 'u-1',
  fullName: 'Manager',
  isActive: true,
  roles: <String>['admin'],
  permissions: <String>[
    'product_view',
    'export_data',
    'product_create',
    'product_update',
  ],
);

const AuthUser _creator = AuthUser(
  id: 'u-2',
  fullName: 'Creator',
  isActive: true,
  roles: <String>['manager'],
  permissions: <String>['product_view', 'export_data', 'product_create'],
);

const AuthUser _viewer = AuthUser(
  id: 'u-3',
  fullName: 'Viewer',
  isActive: true,
  roles: <String>['manager'],
  permissions: <String>['product_view'],
);

const AuthUser _cashier = AuthUser(
  id: 'u-4',
  fullName: 'Cashier Ali',
  isActive: true,
  roles: <String>['cashier'],
  permissions: <String>[],
);

/// In-memory `FilePicker`: [pickResult] answers `pickFiles`, [savedPath]
/// decides whether `saveFile` reports a write or a cancel, and every
/// call is recorded so tests can prove the dialog never opened on a
/// failed request.
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

FilePickerResult _csvPick() => FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: 'catalog.csv',
        size: 21,
        bytes: Uint8List.fromList(utf8.encode('name,barcode\nWidget,1\n')),
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
      child: const _DataTransferHarness(),
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

class _DataTransferHarness extends StatelessWidget {
  const _DataTransferHarness();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: DataTransferScreen()),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Data transfer gate', () {
    testWidgets('a cashier sees permission denied and never calls the API',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _cashier, adapter: adapter);

      expect(find.byKey(const Key('data-transfer-denied')), findsOneWidget);
      expect(find.byKey(const Key('data-transfer-title')), findsNothing);
      expect(adapter.requests, isEmpty,
          reason: 'a non-product user must not issue a transfer request');
      expect(tester.takeException(), isNull);
    });

    testWidgets('product_view alone shows the page but no export/import',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _viewer, adapter: adapter);

      expect(find.byKey(const Key('data-transfer-title')), findsOneWidget);
      expect(find.byKey(const Key('data-transfer-export')), findsNothing);
      expect(find.byKey(const Key('data-transfer-import')), findsNothing);
      expect(find.byKey(const Key('data-transfer-denied')), findsOneWidget);
      expect(adapter.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('Export', () {
    testWidgets('a 200 is announced and the file reaches the save dialog',
        (tester) async {
      final adapter = _adapter();
      final picker = _FakeFilePicker(savedPath: 'C:/tmp/products.csv');
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-export-go')));

      final posts =
          adapter.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(1));
      expect(posts.single.path, '/api/v1/products/export');
      final body = posts.single.data;
      expect(body, isA<Map<String, dynamic>>());
      expect((body as Map)['format'], 'csv');
      expect(body['scope'], 'all');
      expect(body['status'], 'active');
      expect(body.containsKey('search'), isFalse);

      expect(picker.saveCount, 1);
      expect(picker.lastFileName, 'products.csv');
      expect(picker.lastBytes, isNotNull);

      expect(find.text(AppStrings.t('dt_export_success', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('dt_export_failed', 'en')), findsNothing);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a refused export says failed with the real reason and '
        'never opens the save dialog', (tester) async {
      final adapter = _adapter(failExport: true);
      final picker = _FakeFilePicker(savedPath: 'C:/tmp/products.csv');
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-export-go')));

      expect(picker.saveCount, 0,
          reason: 'no bytes may be offered for a failed export');
      expect(find.text(AppStrings.t('dt_export_failed', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('dt_export_success', 'en')),
        findsNothing,
        reason: 'a 403 must never be reported as success',
      );
      expect(find.textContaining('missing export_data permission'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('the filtered scope sends the search term', (tester) async {
      final adapter = _adapter();
      final picker = _FakeFilePicker(savedPath: 'C:/tmp/products.csv');
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const ValueKey<String>('dt-scope-all')));
      await tester.tap(find.byKey(const Key('dt-scope-item-filtered')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('data-transfer-search')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('data-transfer-search')),
        'jphone',
      );
      await tester.pumpAndSettle();

      await _tap(tester, find.byKey(const Key('data-transfer-export-go')));

      final body =
          adapter.requests.where((r) => r.method == 'POST').single.data
              as Map<String, dynamic>;
      expect(body['scope'], 'filtered');
      expect(body['search'], 'jphone');
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });
  });

  group('Import', () {
    testWidgets('pressing preview without a file says so and posts nothing',
        (tester) async {
      final adapter = _adapter();
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-preview')));

      expect(find.text(AppStrings.t('dt_no_file', 'en')), findsOneWidget);
      expect(
        adapter.requests.where((r) => r.path == '/api/v1/products/import'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a dry-run posts the picked file and renders the report '
        'without ever claiming an apply', (tester) async {
      final adapter = _adapter();
      final picker = _FakeFilePicker(pickResult: _csvPick());
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-pick')));
      expect(find.text('catalog.csv'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('data-transfer-preview')));

      final imports = adapter.requests
          .where((r) => r.path == '/api/v1/products/import')
          .toList();
      expect(imports, hasLength(1));
      final data = imports.single.data;
      expect(data, isA<FormData>());
      final form = data as FormData;
      expect(
        form.fields.any((f) => f.key == 'dry_run' && f.value == 'true'),
        isTrue,
      );
      expect(
        form.fields.any((f) => f.key == 'on_conflict' && f.value == 'skip'),
        isTrue,
      );
      expect(form.files.single.value.filename, 'catalog.csv');
      expect(
        imports.single.headers['content-type'],
        startsWith('multipart/form-data'),
      );

      expect(find.byKey(const Key('import-report')), findsOneWidget);
      expect(
        find.text(AppStrings.t('dt_report_title', 'en')),
        findsOneWidget,
      );
      expect(find.text('${AppStrings.t('label_total', 'en')}: 4'), findsOneWidget);
      expect(
        find.text('${AppStrings.t('dt_rows_valid', 'en')}: 3'),
        findsOneWidget,
      );
      expect(
        find.text('${AppStrings.t('dt_rows_invalid', 'en')}: 1'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('import-row-2')), findsOneWidget);
      expect(find.byKey(const Key('import-row-9')), findsOneWidget);
      expect(
        find.byKey(const Key('import-report-preview')),
        findsOneWidget,
        reason: 'a dry run must be visibly marked as a preview',
      );
      expect(find.text(AppStrings.t('dt_apply_success', 'en')), findsNothing,
          reason: 'a preview must never claim that rows were written');
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a failed apply says failed with the reason and never says '
        'applied', (tester) async {
      final adapter = _adapter(failImport: true);
      final picker = _FakeFilePicker(pickResult: _csvPick());
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-pick')));
      await _tap(tester, find.byKey(const Key('data-transfer-apply')));

      final imports = adapter.requests
          .where((r) => r.path == '/api/v1/products/import')
          .toList();
      expect(imports, hasLength(1));
      final form = imports.single.data as FormData;
      expect(
        form.fields.any((f) => f.key == 'dry_run' && f.value == 'false'),
        isTrue,
        reason: 'apply must be sent as a real (non-dry) run',
      );

      expect(find.text(AppStrings.t('dt_apply_failed', 'en')), findsOneWidget);
      expect(find.text(AppStrings.t('dt_apply_success', 'en')), findsNothing);
      expect(find.textContaining('exceeds the 20 MB limit'), findsOneWidget);
      expect(find.byKey(const Key('import-report')), findsNothing);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('a refused preview says preview failed', (tester) async {
      final adapter = _adapter(failImport: true);
      final picker = _FakeFilePicker(pickResult: _csvPick());
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = FilePickerIO());
      await _pump(tester, user: _manager, adapter: adapter);

      await _tap(tester, find.byKey(const Key('data-transfer-pick')));
      await _tap(tester, find.byKey(const Key('data-transfer-preview')));

      expect(find.text(AppStrings.t('dt_preview_failed', 'en')), findsOneWidget);
      expect(find.textContaining('exceeds the 20 MB limit'), findsOneWidget);
      expect(find.byKey(const Key('import-report')), findsNothing);
      expect(tester.takeException(), isNull);
      await _drainToasts(tester);
    });

    testWidgets('the update policy is offered only with product_update',
        (tester) async {
      final adapter = _adapter();
      FilePicker.platform = _FakeFilePicker(pickResult: _csvPick());
      addTearDown(() => FilePicker.platform = FilePickerIO());

      await _pump(tester, user: _creator, adapter: adapter);
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('dt-policy-skip')),
      );
      expect(
        find.byKey(const Key('dt-policy-item-update')),
        findsNothing,
        reason: 'the server would reject on_conflict=update without the '
            'permission, so it must not be offered',
      );
      // Dismiss the menu again.
      await tester.tapAt(const Offset(790, 30));
      await tester.pumpAndSettle();

      await _pump(tester, user: _manager, adapter: adapter);
      await _tap(
        tester,
        find.byKey(const ValueKey<String>('dt-policy-skip')),
      );
      expect(
        find.byKey(const Key('dt-policy-item-update')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(790, 30));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
