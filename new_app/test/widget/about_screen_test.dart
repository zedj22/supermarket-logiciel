// About page (Phase 2) — identity, versions, capability cards, motion.
//
// Pins: the Klick POS developer credit, the app version from
// AppConstants, the server name/version from a mocked
// GET /api/v1/system/info, the safe offline placeholder, the always-
// visible /about nav item (Settings pattern), the disabled Documentation
// button with its "coming soon" caption, RTL + three-theme rendering,
// reduced-motion rendering, and localization completeness.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/constants.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/about/about_screen.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/shell/nav_items.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

class MockDio extends Mock implements Dio {}

Response<dynamic> _ok(String path, Object? data) => Response(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void _mockSystemInfo(
  MockDio dio, {
  bool fail = false,
  Map<String, dynamic>? body,
}) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any())).thenAnswer((invocation) async {
    if (fail) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/api/v1/system/info'),
        reason: 'connection refused',
      );
    }
    return _ok(
      '/api/v1/system/info',
      body ??
          {
            'name': 'Supermarket Pro',
            'version': '0.1.0',
            'environment': 'dev',
            'database_status': 'connected',
            'timestamp': '2026-01-01T00:00:00Z',
            'protocol': 1,
            'server_id': 'srv-1',
          },
    );
  });
}

Future<void> _pumpAbout(
  WidgetTester tester, {
  required MockDio dio,
  AppLocale locale = AppLocale.en,
  AppThemeMode mode = AppThemeMode.light,
  bool reduceMotion = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        localeProvider.overrideWith(
          (ref) => LocaleNotifier()..setLocale(locale),
        ),
        themeProvider.overrideWith(
          (ref) => ThemeNotifier()..setTheme(mode),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.forMode(mode),
        locale: const Locale('en'),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        builder: reduceMotion
            ? (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true),
                  child: child!,
                )
            : null,
        home: const Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: AboutScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AboutScreen content', () {
    testWidgets('shows Klick POS, the app version and the hero', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio);

      expect(find.byKey(const Key('about-screen')), findsOneWidget);
      expect(find.text('Klick POS'), findsNWidgets(2)); // hero + info card
      expect(find.text(AppConstants.appVersion), findsOneWidget);
      // Localized app name: hero title + info-card Application row.
      expect(find.text(AppStrings.t('app_name', 'en')), findsNWidgets(2));
      expect(find.byKey(const Key('about-copyright')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders server store name and version from system info',
        (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio);

      expect(find.byKey(const Key('about-server-store')), findsOneWidget);
      expect(find.text('Supermarket Pro'), findsOneWidget);
      expect(find.byKey(const Key('about-server-version')), findsOneWidget);
      expect(find.text('0.1.0'), findsOneWidget);
      expect(find.byKey(const Key('about-server-unavailable')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a safe placeholder when the server is unreachable',
        (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio, fail: true);
      await _pumpAbout(tester, dio: dio);

      expect(find.byKey(const Key('about-server-unavailable')), findsOneWidget);
      expect(
        find.text(AppStrings.t('about_server_unavailable', 'en')),
        findsOneWidget,
      );
      // The rest of the page still renders.
      expect(find.text('Klick POS'), findsNWidgets(2));
      expect(find.byKey(const Key('about-app-version')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows all six verified capability cards', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio);

      for (final id in ['pos', 'catalog', 'inventory', 'invoicing', 'reports', 'lan']) {
        expect(find.byKey(Key('about-feature-$id')), findsOneWidget);
      }
      expect(find.text(AppStrings.t('about_feature_pos', 'en')), findsOneWidget);
      expect(
        find.text(AppStrings.t('about_feature_lan', 'en')),
        findsOneWidget,
      );
    });

    testWidgets('documentation button is enabled and localized', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio);

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('about-documentation-button')),
      );
      expect(button.onPressed, isNotNull);
      expect(
        find.text(AppStrings.t('about_documentation', 'en')),
        findsOneWidget,
      );
    });
  });

  group('AboutScreen localization and themes', () {
    testWidgets('renders in Arabic (RTL) without errors', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio, locale: AppLocale.ar);

      expect(find.text('Klick POS'), findsNWidgets(2));
      expect(find.text(AppStrings.t('app_name', 'ar')), findsNWidgets(2));
      expect(find.text(AppStrings.t('about_feature_pos', 'ar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in French without errors', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio, locale: AppLocale.fr);

      expect(find.text(AppStrings.t('app_name', 'fr')), findsNWidgets(2));
      expect(
        find.text(AppStrings.t('about_feature_invoicing', 'fr')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    for (final mode in [AppThemeMode.dark, AppThemeMode.light, AppThemeMode.grey]) {
      testWidgets('renders in the ${mode.name} theme', (tester) async {
        final dio = MockDio();
        _mockSystemInfo(dio);
        await _pumpAbout(tester, dio: dio, mode: mode);

        expect(find.byKey(const Key('about-screen')), findsOneWidget);
        expect(find.byKey(const Key('about-info-card')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('renders under reduced motion without errors', (tester) async {
      final dio = MockDio();
      _mockSystemInfo(dio);
      await _pumpAbout(tester, dio: dio, reduceMotion: true);

      expect(find.byKey(const Key('about-screen')), findsOneWidget);
      expect(find.byKey(const Key('about-feature-pos')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('every About key is present and translated in all three locales', () {
      const keys = <String>[
        'about',
        'about_description',
        'about_information',
        'about_application',
        'about_application_version',
        'about_server',
        'about_server_store',
        'about_server_version',
        'about_server_unavailable',
        'about_developer',
        'about_documentation',
        'about_coming_soon',
        'about_feature_pos',
        'about_feature_pos_desc',
        'about_feature_catalog',
        'about_feature_catalog_desc',
        'about_feature_inventory',
        'about_feature_inventory_desc',
        'about_feature_invoicing',
        'about_feature_invoicing_desc',
        'about_feature_reports',
        'about_feature_reports_desc',
        'about_feature_lan',
        'about_feature_lan_desc',
      ];
      for (final key in keys) {
        for (final locale in ['ar', 'fr', 'en']) {
          // AppStrings.t falls back to the raw key when a translation is
          // missing, so a value equal to the key means "not translated".
          final value = AppStrings.t(key, locale);
          expect(value, isNot(key), reason: '$key missing in $locale');
          expect(value, isNotEmpty, reason: '$key empty in $locale');
        }
      }
    });
  });

  group('About navigation integration', () {
    test('the /about rail item is always visible, after Settings', () {
      // can() = false for every scope: only no-scope items survive.
      final groups = buildNavGroups(can: (_) => false);
      final admin = groups
          .firstWhere((g) => g.titleKey == 'nav_group_administration');
      final paths = admin.items.map((i) => i.path).toList();

      expect(paths, contains('/about'));
      expect(paths, contains('/settings'));
      expect(paths.indexOf('/about'), greaterThan(paths.indexOf('/settings')));
      final about = admin.items.firstWhere((i) => i.path == '/about');
      expect(about.scope, isNull);
      expect(about.labelKey, 'about');
    });

    test('an About item exists for every permission profile', () {
      for (final scopes in [
        <String>{},
        {'pos_sale'},
        {'user_manage', 'report_financial', 'device_manage'},
      ]) {
        final groups = buildNavGroups(can: scopes.contains);
        final paths = groups.expand((g) => g.items).map((i) => i.path);
        expect(paths, contains('/about'));
      }
    });
  });
}
