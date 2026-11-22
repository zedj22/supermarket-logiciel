// Receipt printing mode — persistence regression suite.
//
// Reproduces the reported bug flow against a **stateful** fake backend
// (PUT merges into the stored state, GET returns it) instead of an adapter
// that merely echoes the request:
//
//  1. open Settings → choose a mode (+ threshold) → Save
//  2. leave Settings → reopen it                (same provider scope)
//  3. recreate the provider container            (application restart)
//
// All three modes must come back exactly as saved, and an installation
// that never saved a mode must still read as Disabled.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/settings/settings_provider.dart';
import 'package:supermarket_pos/features/settings/settings_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

import '../helpers/settings_fake_adapter.dart';

const Key _modeDropdownKey = Key('settings-receipt-print-mode');
const Key _minAmountKey = Key('settings-receipt-min-amount');
const Key _saveKey = Key('settings-save-button');

/// A fake backend that actually stores what the PUT body contains, exactly
/// like `app_settings` (singleton row) does.
class _SettingsServer {
  _SettingsServer([Map<String, Object?>? initial])
      : state = <String, Object?>{
          ...kDefaultSettingsJson,
          ...?initial,
        };

  Map<String, Object?> state;
  final List<RequestOptions> requests = <RequestOptions>[];

  late final FakeJsonAdapter adapter = FakeJsonAdapter((options) async {
    requests.add(options);
    if (options.method == 'PUT') {
      final body = Map<String, dynamic>.from(options.data as Map);
      // Persist exactly the keys the backend knows (the real service applies
      // a partial update; here the client always sends the full form).
      state = <String, Object?>{...state, ...body};
    }
    return (statusCode: 200, body: state);
  });

  Iterable<RequestOptions> get puts =>
      requests.where((r) => r.method == 'PUT');
}

/// Mounts the settings screen inside a navigation shell so the screen can be
/// left and reopened without recreating the providers.
class _NavHarness extends StatelessWidget {
  const _NavHarness({required this.showSettings});

  final ValueNotifier<bool> showSettings;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: showSettings,
      builder: (context, visible, _) => Scaffold(
        body: visible
            ? const SettingsScreen()
            : const Center(child: Text('dashboard')),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> pumpApp(
    WidgetTester tester,
    _SettingsServer server, {
    ValueNotifier<bool>? showSettings,
    ProviderContainer? container,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final scope = ProviderScope(
      overrides: [
        localeProvider.overrideWith(
          (ref) => LocaleNotifier(prefs)..setLocale(AppLocale.en),
        ),
        themeProvider.overrideWith(
          (ref) => ThemeNotifier(prefs)..setTheme(AppThemeMode.dark),
        ),
        currentUserProvider.overrideWithValue(_admin),
        apiClientProvider.overrideWithValue(
          ApiClient(dio: fakeDio(server.adapter)),
        ),
      ],
      child: _SettingsApp(showSettings: showSettings),
    );
    await tester.pumpWidget(scope);
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  group('Receipt printing mode persistence', () {
    // `disabled` starts from a saved gated mode, because selecting the value
    // that is already selected is (correctly) not a change to save.
    const scenarios = <String, Map<String, Object?>>{
      'ask_above_threshold': <String, Object?>{
        'receipt_print_mode': 'disabled',
        'receipt_min_amount': 0,
      },
      'ask': <String, Object?>{
        'receipt_print_mode': 'disabled',
        'receipt_min_amount': 0,
      },
      'auto_print': <String, Object?>{
        'receipt_print_mode': 'disabled',
        'receipt_min_amount': 0,
      },
      'disabled': <String, Object?>{
        'receipt_print_mode': 'ask_above_threshold',
        'receipt_min_amount': 500,
      },
    };

    for (final scenario in scenarios.entries) {
      final mode = scenario.key;
      testWidgets('$mode survives Save → leave → reopen Settings',
          (tester) async {
        final server = _SettingsServer(scenario.value);
        final visible = ValueNotifier<bool>(true);
        await pumpApp(tester, server, showSettings: visible);

        await _selectMode(tester, AppStrings.t('receipt_print_mode_$mode', 'en'));
        if (mode == 'ask_above_threshold') {
          await _enterText(tester, find.byKey(_minAmountKey), '500');
        }
        await _tap(tester, find.byKey(_saveKey));

        expect(server.puts, hasLength(1));
        expect((server.puts.single.data as Map)['receipt_print_mode'], mode);

        // Leave Settings…
        visible.value = false;
        await tester.pumpAndSettle();
        expect(find.byKey(_modeDropdownKey), findsNothing);

        // …and come back.
        visible.value = true;
        await tester.pumpAndSettle();

        expect(
          find.text(AppStrings.t('receipt_print_mode_$mode', 'en')),
          findsOneWidget,
          reason: 'the reopened dropdown must show the saved mode',
        );
        expect(server.state['receipt_print_mode'], mode);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the saved threshold is still displayed when Settings is '
        'reopened', (tester) async {
      final server = _SettingsServer();
      final visible = ValueNotifier<bool>(true);
      await pumpApp(tester, server, showSettings: visible);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      await _enterText(tester, find.byKey(_minAmountKey), '750.5');
      await _tap(tester, find.byKey(_saveKey));

      expect(server.state['receipt_min_amount'], 750.5);

      visible.value = false;
      await tester.pumpAndSettle();
      visible.value = true;
      await tester.pumpAndSettle();

      expect(find.byKey(_minAmountKey), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byKey(_minAmountKey)).controller?.text,
        '750.5',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('mode + threshold survive a full provider recreation '
        '(application restart)', (tester) async {
      final server = _SettingsServer();
      await pumpApp(tester, server);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      await _enterText(tester, find.byKey(_minAmountKey), '500');
      await _tap(tester, find.byKey(_saveKey));
      expect(server.state['receipt_print_mode'], 'ask_above_threshold');
      expect(server.state['receipt_min_amount'], 500);

      // Restart: tear the widget tree down completely and mount a brand-new
      // ProviderScope against the same (persisted) backend.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester, server);

      expect(
        find.text(
          AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(_minAmountKey), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byKey(_minAmountKey)).controller?.text,
        '500',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an installation with no saved mode still reads as Disabled '
        'after a restart', (tester) async {
      final server = _SettingsServer(<String, Object?>{
        'receipt_print_mode': null,
        'receipt_min_amount': null,
      });
      await pumpApp(tester, server);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester, server);

      expect(
        find.text(AppStrings.t('receipt_print_mode_disabled', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(_minAmountKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ONE dropdown replaces the two legacy switches', (tester) async {
      final server = _SettingsServer();
      await pumpApp(tester, server);

      // The separate ask/auto switches are gone…
      expect(find.byKey(const Key('settings-ask-before-print')), findsNothing);
      expect(find.byKey(const Key('settings-auto-print')), findsNothing);

      // …and the single dropdown offers all four modes.
      await tester.ensureVisible(find.byKey(_modeDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_modeDropdownKey));
      await tester.pumpAndSettle();
      for (final mode in <String>[
        'disabled',
        'ask',
        'auto_print',
        'ask_above_threshold',
      ]) {
        expect(
          find.text(AppStrings.t('receipt_print_mode_$mode', 'en')).last,
          findsOneWidget,
          reason: 'missing option $mode',
        );
      }
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the threshold field only appears in the threshold mode',
        (tester) async {
      final server = _SettingsServer();
      await pumpApp(tester, server);

      expect(find.byKey(_minAmountKey), findsNothing);

      await _selectMode(tester, AppStrings.t('receipt_print_mode_ask', 'en'));
      expect(find.byKey(_minAmountKey), findsNothing);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_auto_print', 'en'),
      );
      expect(find.byKey(_minAmountKey), findsNothing);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      expect(find.byKey(_minAmountKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('changing only the mode keeps the previously saved threshold',
        (tester) async {
      final server = _SettingsServer(<String, Object?>{
        'receipt_print_mode': 'ask_above_threshold',
        'receipt_min_amount': 500,
      });
      final visible = ValueNotifier<bool>(true);
      await pumpApp(tester, server, showSettings: visible);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_auto_print', 'en'),
      );
      await _tap(tester, find.byKey(_saveKey));
      expect(server.state['receipt_print_mode'], 'auto_print');
      expect(server.state['receipt_min_amount'], 500);

      await _selectMode(
        tester,
        AppStrings.t('receipt_print_mode_ask_above_threshold', 'en'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(find.byKey(_minAmountKey)).controller?.text,
        '500',
        reason: 'switching back must not lose the stored amount',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

const AuthUser _admin = AuthUser(
  id: 'u-1',
  fullName: 'Admin',
  isActive: true,
  roles: ['admin'],
  permissions: [settingsManageScope],
);

class _SettingsApp extends ConsumerWidget {
  const _SettingsApp({required this.showSettings});

  final ValueNotifier<bool>? showSettings;

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
      home: showSettings == null
          ? const Scaffold(body: SettingsScreen())
          : _NavHarness(showSettings: showSettings!),
    );
  }
}

Future<void> _selectMode(WidgetTester tester, String label) async {
  final dropdown = find.byKey(_modeDropdownKey);
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _enterText(WidgetTester tester, Finder finder, String text) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
