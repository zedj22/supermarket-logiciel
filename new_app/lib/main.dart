import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/constants.dart';
import 'features/auth/auth_provider.dart';
import 'features/auth/credential_storage.dart';
import 'features/devices/connection_provider.dart';
import 'features/devices/device_identity.dart';
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
  final apiClient = ApiClient(baseUrl: await initialBaseUrl());
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
        apiClientProvider.overrideWithValue(apiClient),
        credentialStorageProvider.overrideWithValue(credentials),
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

    final themeState = ref.watch(themeProvider);
    final localeState = ref.watch(localeProvider);
    final authState = ref.watch(authProvider);

    if (authState.status == AuthStatus.checking) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        // The boot splash used to render on the *default* light scaffold
        // with a dark-theme icon hardcoded below, flashing the wrong
        // palette for one frame on every cold start.
        theme: AppTheme.forMode(themeState.mode),
        locale: localeState.flutterLocale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.store,
                  size: 64,
                  color: AppTheme.forMode(
                    themeState.mode,
                  ).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
            ),
          ),
        ),
      );
    }

    final router = ref.watch(routerProvider);

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
