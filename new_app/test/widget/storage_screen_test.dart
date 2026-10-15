// Storage & Data Usage — widget tests for the admin storage page.
//
// Coverage map:
//  * refresh lifecycle: loading → measured, refresh disabled while busy;
//  * honesty rules: partial chip when anything measurable is unavailable,
//    NO chip when only `not_stored` categories are open, payload
//    `total_bytes`/`complete` are re-derived client-side;
//  * failure mapping: HTTP 500 → retryable server error, HTTP 403 →
//    permission message, total failure → error card with a working
//    retry, each keeping the other scope's data where it exists;
//  * security: without `settings_manage` the screen renders the denied
//    view and neither the probe nor the API is ever touched;
//  * RTL: Arabic direction with LTR-pinned size values;
//  * request contract: exactly `GET /api/v1/storage`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
import 'package:supermarket_pos/features/storage/storage_models.dart';
import 'package:supermarket_pos/features/storage/storage_provider.dart';
import 'package:supermarket_pos/features/storage/storage_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -- fixtures -----------------------------------------------------------

  /// Local scope with one measurable category unavailable (cache folder
  /// missing) → the page must report a *partial* total.
  final StorageSection localPartial = StorageSection(
    scope: storageScopeLocal,
    measuredAt: DateTime(2026, 10, 15, 10, 5),
    categories: const [
      StorageCategory(key: 'application', available: true, bytes: 4096),
      StorageCategory(key: 'exports', available: true, bytes: 2048),
      StorageCategory(
        key: 'cache_temp',
        available: false,
        reason: storageReasonMissing,
      ),
    ],
    disk: const StorageDisk(
      available: true,
      totalBytes: 999,
      freeBytes: 111,
    ),
  );

  /// Local scope fully measured — completeness then hinges on `logs`
  /// being `not_stored` (server side), which must NOT break the report.
  final StorageSection localComplete = StorageSection(
    scope: storageScopeLocal,
    measuredAt: DateTime(2026, 10, 15, 10, 5),
    categories: const [
      StorageCategory(key: 'application', available: true, bytes: 100),
      StorageCategory(key: 'exports', available: true, bytes: 20),
      StorageCategory(key: 'cache_temp', available: true, bytes: 0),
    ],
    disk: const StorageDisk(
      available: true,
      totalBytes: 999,
      freeBytes: 111,
    ),
  );

  /// A realistic `GET /api/v1/storage` payload — the `total_bytes` and
  /// `complete` claims are deliberately *wrong* so the tests fail if the
  /// client ever trusts them instead of re-deriving from `categories`.
  const Map<String, Object> serverJson = <String, Object>{
    'scope': 'server',
    'measured_at': '2026-10-15T10:00:00',
    'total_bytes': 999999,
    'complete': false,
    'categories': <Object>[
      <String, Object>{'key': 'database', 'available': true, 'bytes': 1000},
      <String, Object>{
        'key': 'application',
        'available': true,
        'bytes': 500,
      },
      <String, Object>{'key': 'backups', 'available': true, 'bytes': 250},
      <String, Object>{'key': 'data', 'available': true, 'bytes': 100},
      <String, Object>{'key': 'cache_temp', 'available': true, 'bytes': 50},
      <String, Object>{
        'key': 'logs',
        'available': false,
        'reason': 'not_stored',
      },
    ],
    'disk': <String, Object>{
      'available': true,
      'total_bytes': 100000,
      'free_bytes': 40000,
    },
  };

  const AuthUser admin = AuthUser(
    id: 'u-1',
    fullName: 'Admin',
    isActive: true,
    roles: ['admin'],
    permissions: [settingsManageScope],
  );

  AuthUser userWith(List<String> permissions) => AuthUser(
        id: 'u-2',
        fullName: 'Operator',
        isActive: true,
        roles: const ['cashier'],
        permissions: permissions,
      );

  Map<String, Object> errorBody() => <String, Object>{
        'error': <String, Object>{
          'code': 'INTERNAL',
          'message': 'boom',
        },
      };

  FakeJsonAdapter okAdapter() =>
      FakeJsonAdapter((options) async => (statusCode: 200, body: serverJson));

  // -- harness ------------------------------------------------------------

  Future<void> pumpStorage(
    WidgetTester tester, {
    AppLocale locale = AppLocale.ar,
    AuthUser user = admin,
    required FakeJsonAdapter adapter,
    LocalStorageProbe? probe,
    String? runMode,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(null)..setLocale(locale),
          ),
          themeProvider.overrideWith(
            (ref) => ThemeNotifier(null)..setTheme(AppThemeMode.dark),
          ),
          currentUserProvider.overrideWithValue(user),
          apiClientProvider.overrideWithValue(
            ApiClient(dio: fakeDio(adapter)),
          ),
          // A real probe would walk the Flutter SDK folder — every test
          // injects its own deterministic section (or gate).
          localStorageProbeProvider.overrideWithValue(
            probe ?? (() async => localPartial),
          ),
          storageRunModeProvider.overrideWith((ref) async => runMode),
        ],
        child: const _StorageHarness(),
      ),
    );
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  FilledButton refreshButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('storage-refresh')));

  // -- tests --------------------------------------------------------------

  group('Storage & Data Usage page', () {
    testWidgets(
      'measures both scopes, disables refresh while busy, marks partial',
      (tester) async {
        final adapter = okAdapter();
        final gate = Completer<StorageSection>();
        await pumpStorage(
          tester,
          adapter: adapter,
          probe: () => gate.future,
        );

        // initState microtask started the measurement.
        await tester.pump();
        expect(
          find.byKey(const Key('storage-loading-card')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('storage-summary-card')), findsNothing);
        expect(refreshButton(tester).enabled, isFalse);
        expect(
          find.byKey(const Key('storage-refresh-spinner')),
          findsOneWidget,
        );

        gate.complete(localPartial);
        await tester.pumpAndSettle();

        // Exactly one request, to exactly the documented endpoint.
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.method, 'GET');
        expect(adapter.requests.single.uri.path, '/api/v1/storage');
        expect(refreshButton(tester).enabled, isTrue);

        // Local 4096+2048 + server 1000+500+250+100+50 = 8044 → 7.9 KB.
        expect(find.byKey(const Key('storage-summary-card')), findsOneWidget);
        expect(find.text('7.9 KB'), findsOneWidget);
        expect(
          find.byKey(const Key('storage-partial-chip')),
          findsOneWidget,
          reason: 'the local cache category is unavailable',
        );

        expect(
          find.byKey(const Key('storage-local-value-application')),
          findsOneWidget,
        );
        expect(find.text('4.0 KB'), findsOneWidget);
        expect(find.text('2.0 KB'), findsOneWidget);
        expect(find.text('1000 B'), findsOneWidget);
        expect(find.text('500 B'), findsOneWidget);
        expect(find.text('250 B'), findsOneWidget);
        expect(find.text('100 B'), findsOneWidget);
        expect(find.text('50 B'), findsOneWidget);
        expect(find.text('999 B'), findsOneWidget);
        expect(find.text('97.7 KB'), findsOneWidget);

        // Unavailable categories show their reason, not a number.
        expect(
          find.byKey(const Key('storage-local-reason-cache_temp')),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('storage_reason_missing', 'ar')),
          findsWidgets,
        );
        expect(
          find.byKey(const Key('storage-server-reason-logs')),
          findsOneWidget,
        );
        expect(
          find.text(AppStrings.t('storage_reason_not_stored', 'ar')),
          findsOneWidget,
        );

        // Both timestamps are displayed.
        expect(find.text('2026-10-15 10:05'), findsOneWidget);
        expect(find.text('2026-10-15 10:00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a fully measured report (logs not_stored) shows no partial chip',
      (tester) async {
        final adapter = okAdapter();
        await pumpStorage(
          tester,
          adapter: adapter,
          probe: () async => localComplete,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('storage-summary-card')), findsOneWidget);
        expect(find.byKey(const Key('storage-partial-chip')), findsNothing);
        // Local 100+20+0 + server 1900 = 2020 → 2.0 KB.
        expect(find.text('2.0 KB'), findsOneWidget);
        expect(
          find.byKey(const Key('storage-server-note')),
          findsNothing,
          reason: 'this install is not the server host',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('HTTP 500 keeps local data and offers a working retry',
        (tester) async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 500, body: errorBody()),
      );
      await pumpStorage(
        tester,
        adapter: adapter,
        probe: () async => localComplete,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('storage-server-error')), findsOneWidget);
      expect(
        find.text(AppStrings.t('api_error_retry', 'ar')),
        findsOneWidget,
      );
      // The local scope survived the server failure.
      expect(
        find.byKey(const Key('storage-local-value-application')),
        findsOneWidget,
      );
      expect(find.text('100 B'), findsOneWidget); // local application row

      await tapKey(tester, const Key('storage-server-retry'));
      expect(adapter.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('HTTP 403 maps to the permission message', (tester) async {
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 403, body: errorBody()),
      );
      await pumpStorage(
        tester,
        adapter: adapter,
        probe: () async => localComplete,
      );
      await tester.pumpAndSettle();

      expect(
        find.text(AppStrings.t('storage_no_permission', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('total failure shows the error card and retry re-measures',
        (tester) async {
      var probeCalls = 0;
      final adapter = FakeJsonAdapter(
        (options) async => (statusCode: 500, body: errorBody()),
      );
      await pumpStorage(
        tester,
        adapter: adapter,
        probe: () async {
          probeCalls += 1;
          throw StateError('probe unavailable');
        },
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('storage-error-card')), findsOneWidget);
      expect(probeCalls, 1);
      expect(adapter.requests, hasLength(1));

      await tapKey(tester, const Key('storage-retry'));
      expect(probeCalls, 2);
      expect(adapter.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh is disabled while a measurement is running',
        (tester) async {
      final gates = <Completer<StorageSection>>[];
      Future<StorageSection> gated() {
        final gate = Completer<StorageSection>();
        gates.add(gate);
        return gate.future;
      }

      final adapter = okAdapter();
      await pumpStorage(tester, adapter: adapter, probe: gated);

      await tester.pump();
      gates[0].complete(localComplete);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('storage-summary-card')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('storage-refresh')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('storage-refresh')));
      // A single pump, NOT pumpAndSettle: the gate keeps the state busy
      // (and the timeout timer unexpired), which is exactly what "busy"
      // must look like to the operator.
      await tester.pump();
      expect(refreshButton(tester).enabled, isFalse);
      expect(
        find.byKey(const Key('storage-refresh-spinner')),
        findsOneWidget,
      );
      // Existing data stays on screen during the refresh.
      expect(find.byKey(const Key('storage-summary-card')), findsOneWidget);

      gates[1].complete(localComplete);
      await tester.pumpAndSettle();
      expect(refreshButton(tester).enabled, isTrue);
      expect(adapter.requests, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'without settings_manage: denied view, no probe, no API request',
      (tester) async {
        var probeCalled = false;
        final adapter = FakeJsonAdapter((options) async {
          fail('an unauthorized screen must not call GET /api/v1/storage');
        });
        await pumpStorage(
          tester,
          user: userWith(const ['pos_sale']),
          adapter: adapter,
          probe: () async {
            probeCalled = true;
            return localComplete;
          },
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('storage-denied')), findsOneWidget);
        expect(find.byKey(const Key('storage-screen')), findsNothing);
        expect(probeCalled, isFalse);
        expect(adapter.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Arabic RTL with LTR-pinned size values', (tester) async {
      final adapter = okAdapter();
      await pumpStorage(
        tester,
        locale: AppLocale.ar,
        adapter: adapter,
        probe: () async => localComplete,
      );
      await tester.pumpAndSettle();

      expect(
        Directionality.of(tester.element(find.byKey(const Key('storage-screen')))),
        TextDirection.rtl,
      );
      expect(find.text(AppStrings.t('storage_usage', 'ar')), findsOneWidget);

      // Numbers and dates must not mirror, even on an RTL screen.
      expect(
        Directionality.of(
          tester.element(find.byKey(const Key('storage-total-value'))),
        ),
        TextDirection.ltr,
      );
      expect(
        Directionality.of(
          tester.element(
            find.byKey(const Key('storage-local-value-application')),
          ),
        ),
        TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('explains when this install hosts the server', (tester) async {
      final adapter = okAdapter();
      await pumpStorage(
        tester,
        adapter: adapter,
        probe: () async => localComplete,
        runMode: 'server',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('storage-server-note')), findsOneWidget);
      expect(
        find.text(AppStrings.t('storage_server_on_this_pc', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

class _StorageHarness extends ConsumerWidget {
  const _StorageHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final mode = ref.watch(themeProvider).mode;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forMode(mode),
      locale: locale.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
      home: const Scaffold(body: StorageUsageScreen()),
    );
  }
}
