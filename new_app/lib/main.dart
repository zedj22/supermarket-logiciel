import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants.dart';
import 'features/auth/auth_provider.dart';
import 'theme/app_theme.dart';
import 'theme/app_theme_mode.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: SupermarketPosApp()));
}

class SupermarketPosApp extends ConsumerWidget {
  const SupermarketPosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final localeState = ref.watch(localeProvider);
    final authState = ref.watch(authProvider);

    if (authState.status == AuthStatus.checking) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
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
                  color: AppTheme.dark().colorScheme.primary,
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
      theme: _getTheme(themeState.mode),
      routerConfig: router,
      locale: localeState.flutterLocale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: appLocalizationsDelegates,
    );
  }

  ThemeData _getTheme(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.dark:
        return AppTheme.dark();
      case AppThemeMode.light:
        return AppTheme.light();
      case AppThemeMode.grey:
        return AppTheme.grey();
    }
  }
}
