import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/constants.dart';
import 'features/auth/auth_provider.dart';
import 'features/auth/credential_storage.dart';
import 'features/devices/connection_provider.dart';
import 'features/devices/device_identity.dart';
import 'features/settings/pos_settings_provider.dart';
import 'features/settings/scan_settings_provider.dart';
import 'features/licensing/license_providers.dart';
import 'network/api_client.dart';
import 'theme/app_theme.dart';
import 'theme/theme_provider.dart';
import 'l10n/locale_provider.dart';
import 'router/app_router.dart';

const List<Locale> appSupportedLocales = <Locale>[
  Locale('ar'),
  Locale('fr'),
  Locale('en'),
];

const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Phase 16 (§8.3 / §23.2): the client boots against the remembered
  // server when one exists, otherwise the single-PC default, and carries
  // the persisted machine identity from the very first request. Pairing is
  // deliberately independent of the user session, so this survives logout.
  final credentials = SecureCredentialStorage();
  final baseUrl = await initialBaseUrl();
  final apiClient = ApiClient(baseUrl: baseUrl);

  // P8: discovery follows the port the backend actually published, so a
  // non-default port does not silently break LAN pairing.
  final parsedBaseUrl = Uri.tryParse(baseUrl);
  final discoveryPort =
      (parsedBaseUrl != null && parsedBaseUrl.hasPort) ? parsedBaseUrl.port : 8000;

  // First-run UX (single PC): the backend launcher publishes
  // `supermarket_endpoint.json` when it starts, so a desktop whose exe sits
  // next to that descriptor (or whose ProgramData has one) IS the server.
  // Preselect the role instead of forcing the operator through a network
  // wizard on a machine that needs no network configuration at all.
  if (await readAppRunMode() == null &&
      await readLocalBackendBaseUrl() != null) {
    await writeAppRunMode(appRunModeServer);
  }

  final link = await readServerLink();
  if (link.isPaired) {
    apiClient.setDeviceIdentity(
      deviceId: await ensurePosDeviceId(),
      deviceToken: link.deviceToken,
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        localeProvider.overrideWith((ref) => LocaleNotifier(prefs)),
        themeProvider.overrideWith((ref) => ThemeNotifier(prefs)),
        scanSettingsProvider.overrideWith((ref) => ScanSettingsNotifier(prefs)),
        posSettingsProvider.overrideWith((ref) => PosSettingsNotifier(prefs)),
        apiClientProvider.overrideWithValue(apiClient),
        credentialStorageProvider.overrideWithValue(credentials),
        lanDiscoveryPortProvider.overrideWithValue(discoveryPort),
        installBootstrappedProvider.overrideWithValue(true),
      ],
      child: const SupermarketPosApp(),
    ),
  );
}

class SupermarketPosApp extends ConsumerWidget {
  const SupermarketPosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Phase 16 §23.3 — 2-PC QA bug: the reconnect / rediscovery machine must
    // start on the FIRST frame. It used to be created only by the
    // authenticated shell (the status chip and the boot-time modal), so a
    // paired client that could not authenticate — exactly what a stale
    // `paired_server_url` after a server IP change produces — never ran
    // `bootstrap()`, never repaired the address and never rediscovered.
    // `read` (not `watch`) starts it without rebuilding the whole app on
    // every connection tick.
    ref.read(lanConnectionProvider);

    // Phase L1-C: feed the licensing state from every existing
    // /system/info response through the shared client's interceptor —
    // no extra request, no polling.
    ref.read(licenseIngestorProvider);

    final themeState = ref.watch(themeProvider);
    final localeState = ref.watch(localeProvider);
    final router = ref.watch(routerProvider);

    // ONE MaterialApp for the whole app life. The cold-start splash is a
    // route (/splash) inside this router — while auth is still checking
    // the redirect holds every destination there — so there is never a
    // second Material app, a second navigator, or a palette flip on the
    // first frame.
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forMode(themeState.mode),
      routerConfig: router,
      locale: localeState.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
    );
  }
}
