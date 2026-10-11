// Phase 16 (§23.1 / §13.1) — first-run network setup wizard.
//
// Scope: the role step, the discovery step (fake service, no sockets) and
// the mandatory `PopScope` that stops a first-run client from escaping the
// wizard before it can present a device identity. Steps that would talk to
// a real server (probe / pair / poll) are covered by the connection tests,
// not by pumping UI against the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';
import 'package:supermarket_pos/features/devices/setup_wizard_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';

ServerOffer _offer({String id = 'server-1', String name = 'Store A'}) =>
    ServerOffer(
      address: '192.168.1.10',
      serverId: id,
      name: name,
      httpPort: 8000,
      tls: false,
      nonce: 'a1b2c3d4e5f60718',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<ServerOffer> emitted;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    emitted = <ServerOffer>[];
  });

  Future<ProviderContainer> pumpWizard(
    WidgetTester tester, {
    bool mandatory = true,
    AppLocale locale = AppLocale.en,
    List<ServerOffer> offers = const [],
  }) async {
    emitted = offers;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(locale),
          ),
          lanConnectionProvider.overrideWith((ref) {
            // ApiClient() does no I/O at construction; these tests stop
            // before any HTTP round-trip.
            return LanConnectionNotifier(
              ApiClient(),
              discoveryFactory: (port) =>
                  FakeDiscoveryService(offers: emitted),
            );
          }),
        ],
        child: MaterialApp(
          locale: Locale(locale.name),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: appLocalizationsDelegates,
          home: SetupWizardScreen(mandatory: mandatory),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(SetupWizardScreen)),
    );
  }

  group('SetupWizardScreen — role step', () {
    testWidgets('shows the title, first-run hint and both roles',
        (tester) async {
      await pumpWizard(tester);

      expect(find.byKey(const Key('wizard-title')), findsOneWidget);
      // AppBar title + wizard body repeat the same string.
      expect(
        find.text(AppStrings.t('lan_wizard_title', 'en')),
        findsWidgets,
      );
      expect(
        find.text(AppStrings.t('lan_first_run_hint', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('role-server')), findsOneWidget);
      expect(find.byKey(const Key('role-client')), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_server_role', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_client_role', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('is unclosable on first run and closable later',
        (tester) async {
      await pumpWizard(tester, mandatory: true);
      expect(find.byType(BackButton), findsNothing);
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
        isFalse,
        reason: 'a first-run client must not escape the wizard',
      );

      await pumpWizard(tester, mandatory: false);
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in Arabic (RTL) with translated role copy',
        (tester) async {
      await pumpWizard(tester, locale: AppLocale.ar);

      expect(
        Directionality.of(tester.element(find.byType(SetupWizardScreen))),
        TextDirection.rtl,
      );
      expect(
        find.text(AppStrings.t('lan_server_role', 'ar')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_client_role', 'ar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SetupWizardScreen — discovery step', () {
    testWidgets('choosing the client role enters the searching step',
        (tester) async {
      await pumpWizard(tester);

      await tester.tap(find.byKey(const Key('role-client')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('wizard-searching')), findsOneWidget);
      expect(
        find.byKey(const Key('wizard-searching-label')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_searching_server', 'en')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('manual-host')), findsOneWidget);
      expect(find.byKey(const Key('manual-connect')), findsOneWidget);
      expect(await readAppRunMode(), appRunModeClient);
      expect(find.byKey(const Key('wizard-timeout')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists discovered servers without probing them yet',
        (tester) async {
      await pumpWizard(
        tester,
        offers: [_offer(id: 'server-1', name: 'Store A')],
      );

      await tester.tap(find.byKey(const Key('role-client')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('offer-server-1')), findsOneWidget);
      expect(find.text('Store A'), findsOneWidget);
      // Display-only short form (host); the full ip:port stays internal.
      expect(find.text('192.168.1.10'), findsOneWidget);
      expect(find.text('192.168.1.10:8000'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces the search timeout after the 4 s budget',
        (tester) async {
      await pumpWizard(tester);

      await tester.tap(find.byKey(const Key('role-client')));
      await tester.pump();
      expect(find.byKey(const Key('wizard-timeout')), findsNothing);

      await tester.pump(const Duration(seconds: 4) + const Duration(milliseconds: 1));

      expect(find.byKey(const Key('wizard-timeout')), findsOneWidget);
      expect(
        find.text(AppStrings.t('lan_search_timeout', 'en')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the empty search still offers manual IP entry', (tester) async {
      await pumpWizard(tester);
      await tester.tap(find.byKey(const Key('role-client')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text(AppStrings.t('lan_manual_entry', 'en')),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings.t('lan_ip_label', 'en')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('manual-host')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SetupWizardScreen — wizard chrome', () {
    testWidgets('mandatory wizard has no AppBar back affordance at all',
        (tester) async {
      await pumpWizard(tester, mandatory: true);
      expect(find.byType(BackButton), findsNothing);

      final appbar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appbar.automaticallyImplyLeading, isFalse);
    });

    testWidgets('non-mandatory wizard restores the AppBar back affordance',
        (tester) async {
      await pumpWizard(tester, mandatory: false);
      final appbar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appbar.automaticallyImplyLeading, isTrue);
    });
  });
}
