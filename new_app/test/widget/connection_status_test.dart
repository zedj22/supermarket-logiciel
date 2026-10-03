// Phase 16 — AppBar connection chip (§13.1 / §14 steady-state UI).
//
// Two things are pinned here: the pure phase→(colour, label) mapping for
// every state of the state machine, and the fact that the chip renders that
// label at the AppBar's trailing edge in each locale.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_models.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/widgets/status_chip.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpChip(
    WidgetTester tester, {
    LanConnectionState state = const LanConnectionState(),
    AppLocale locale = AppLocale.en,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          lanConnectionProvider.overrideWith((ref) {
            final notifier = LanConnectionNotifier(ApiClient());
            notifier.debugSetState(state);
            return notifier;
          }),
        ],
        child: MaterialApp(
          locale: Locale(locale.name),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(
            appBar: AppBar(actions: const [ConnectionStatusChip()]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('ConnectionStatusChip.presentation', () {
    test('green when connected with a healthy database', () {
      final (color, key) =
          ConnectionStatusChip.presentation(LanPhase.connected, false);
      expect(key, 'lan_connected');
      expect(color, Colors.green);
    });

    test('amber when connected but the server database is degraded (§13.1)', () {
      final (color, key) =
          ConnectionStatusChip.presentation(LanPhase.connected, true);
      expect(key, 'lan_degraded_db');
      expect(color, Colors.amber);
    });

    test('red for reconnecting, disconnected and rejected', () {
      for (final phase in [
        LanPhase.reconnecting,
        LanPhase.disconnected,
        LanPhase.rejected,
      ]) {
        final (color, key) = ConnectionStatusChip.presentation(phase, false);
        expect(key, 'lan_disconnected', reason: phase.name);
        expect(color, Colors.red, reason: phase.name);
      }
    });

    test('amber while the wizard is still establishing a link', () {
      for (final phase in [
        LanPhase.serverFound,
        LanPhase.pairingRequested,
        LanPhase.awaitingApproval,
        LanPhase.connecting,
      ]) {
        final (color, key) = ConnectionStatusChip.presentation(phase, false);
        expect(key, 'lan_reconnecting', reason: phase.name);
        expect(color, Colors.amber, reason: phase.name);
      }
    });

    test('grey before anything has been configured', () {
      for (final phase in [LanPhase.unconfigured, LanPhase.discovering]) {
        final (color, key) = ConnectionStatusChip.presentation(phase, false);
        expect(key, 'lan_disconnected', reason: phase.name);
        expect(color, Colors.grey, reason: phase.name);
      }
    });

    test('every phase has a presentation (no fall-through)', () {
      for (final phase in LanPhase.values) {
        final (color, key) = ConnectionStatusChip.presentation(phase, false);
        expect(color, isNotNull, reason: phase.name);
        expect(AppStrings.t(key, 'en'), isNot(key), reason: phase.name);
        expect(AppStrings.t(key, 'ar'), isNot(key), reason: phase.name);
        expect(AppStrings.t(key, 'fr'), isNot(key), reason: phase.name);
      }
    });
  });

  group('ConnectionStatusChip rendering', () {
    testWidgets('renders the connected label and green dot in English',
        (tester) async {
      await pumpChip(
        tester,
        state: const LanConnectionState(phase: LanPhase.connected),
      );

      expect(find.byKey(const Key('connection-status-label')),
          findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_connected', 'en')),
        findsOneWidget,
      );
      final dot = tester.widget<Container>(
        find.byKey(const Key('connection-status-dot')),
      );
      expect((dot.decoration as BoxDecoration).color, Colors.green);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the degraded label in French', (tester) async {
      await pumpChip(
        tester,
        locale: AppLocale.fr,
        state: const LanConnectionState(
          phase: LanPhase.connected,
          degraded: true,
        ),
      );

      expect(
        find.text(AppStrings.t('lan_degraded_db', 'fr')),
        findsOneWidget,
      );
      final dot = tester.widget<Container>(
        find.byKey(const Key('connection-status-dot')),
      );
      expect((dot.decoration as BoxDecoration).color, Colors.amber);
    });

    testWidgets('renders the disconnected label in Arabic (RTL)',
        (tester) async {
      await pumpChip(
        tester,
        locale: AppLocale.ar,
        state: const LanConnectionState(phase: LanPhase.disconnected),
      );

      expect(
        find.text(AppStrings.t('lan_disconnected', 'ar')),
        findsOneWidget,
      );
      expect(
        Directionality.of(tester.element(find.byType(ConnectionStatusChip))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tooltip carries the connected detail, not the raw key',
        (tester) async {
      await pumpChip(
        tester,
        state: const LanConnectionState(phase: LanPhase.connected),
      );
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, AppStrings.t('lan_connected_tooltip', 'en'));
      expect(tooltip.message, isNot('lan_connected_tooltip'));
    });
  });

  // ---------------------------------------------------------------------------
  // §14 / §23.1 — the reconnect modal is a BOOT-TIME prompt, at most once,
  // and a mid-session flap is reported by the chip alone.
  // ---------------------------------------------------------------------------

  group('boot-time reconnect modal', () {
    late ProviderContainer container;
    late LanConnectionNotifier notifier;

    Future<void> pumpShell(
      WidgetTester tester, {
      required LanConnectionState initial,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final user = AuthUser(
        id: 'u1',
        fullName: 'Admin',
        isActive: true,
        roles: const ['admin'],
        permissions: const ['pos_sale'],
      );
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => ScaffoldWithNav(
              location: state.matchedLocation,
              child: const Text('shell-body'),
            ),
          ),
          GoRoute(
            path: '/setup-network',
            builder: (context, state) => const Text('wizard-route'),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localeProvider.overrideWith(
              (ref) => LocaleNotifier(prefs)..setLocale(AppLocale.en),
            ),
            currentUserProvider.overrideWithValue(user),
            lanConnectionProvider.overrideWith((ref) {
              notifier = LanConnectionNotifier(ApiClient());
              notifier.debugSetState(initial);
              return notifier;
            }),
          ],
          child: MaterialApp.router(
            locale: const Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      container = ProviderScope.containerOf(
        tester.element(find.byType(ScaffoldWithNav)),
      );
    }

    testWidgets('opens on a failed first heartbeat after bootstrap',
        (tester) async {
      await pumpShell(
        tester,
        initial: const LanConnectionState(
          phase: LanPhase.connecting,
          baseUrl: 'http://192.168.1.10:8000',
          serverId: 'server-1',
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);

      notifier.debugSetState(const LanConnectionState(
        phase: LanPhase.reconnecting,
        baseUrl: 'http://192.168.1.10:8000',
        serverId: 'server-1',
        errorMessage: 'unreachable',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const Key('reconnect-now')), findsOneWidget);
      expect(find.byKey(const Key('reconnect-manual-entry')), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_reconnect_title', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_server_unreachable', 'en')),
        findsOneWidget,
      );
      expect(
        container.read(reconnectPromptShownProvider),
        isTrue,
        reason: 'the modal is once-per-run (§14)',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('"manual entry" drops the cashier on the wizard (§14)',
        (tester) async {
      await pumpShell(
        tester,
        initial: const LanConnectionState(
          phase: LanPhase.connecting,
          baseUrl: 'http://192.168.1.10:8000',
          serverId: 'server-1',
        ),
      );
      notifier.debugSetState(const LanConnectionState(
        phase: LanPhase.disconnected,
        baseUrl: 'http://192.168.1.10:8000',
        serverId: 'server-1',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('reconnect-manual-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('wizard-route'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mid-session flap shows the chip only, never a modal',
        (tester) async {
      await pumpShell(
        tester,
        initial: const LanConnectionState(
          phase: LanPhase.connected,
          baseUrl: 'http://192.168.1.10:8000',
          serverId: 'server-1',
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);

      notifier.debugSetState(const LanConnectionState(
        phase: LanPhase.reconnecting,
        baseUrl: 'http://192.168.1.10:8000',
        serverId: 'server-1',
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AlertDialog), findsNothing,
          reason: '§14: chip only, never interrupt a cashier mid-sale');
      expect(
        find.byKey(const Key('connection-status-label')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_disconnected', 'en')),
        findsOneWidget,
      );
      expect(container.read(reconnectPromptShownProvider), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
