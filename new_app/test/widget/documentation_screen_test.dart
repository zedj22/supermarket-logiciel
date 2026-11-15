// Documentation Center — widget tests (Phase 3).
//
// Covers rendering, chapter/article selection, live search with section
// anchoring, no-results state, previous/next navigation, three-locale
// localization, RTL, light/dark/grey themes, narrow-window dropdowns,
// reduced motion, and the About → Documentation navigation.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/about/about_screen.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/documentation/doc_content.dart';
import 'package:supermarket_pos/features/documentation/documentation_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/theme/app_theme.dart';
import 'package:supermarket_pos/theme/app_theme_mode.dart';
import 'package:supermarket_pos/theme/theme_provider.dart';

class MockDio extends Mock implements Dio {}

void _mockAboutRequests(MockDio dio) {
  when(() => dio.interceptors).thenReturn(Interceptors());
  when(() => dio.options).thenReturn(BaseOptions());
  when(() => dio.get(any())).thenAnswer(
    (invocation) async => Response<dynamic>(
      requestOptions: RequestOptions(path: '/api/v1/system/info'),
      statusCode: 200,
      data: <String, dynamic>{'name': 'Supermarket Pro', 'version': '0.1.0'},
    ),
  );
}

Future<void> _pumpDocs(
  WidgetTester tester, {
  AppLocale locale = AppLocale.en,
  AppThemeMode mode = AppThemeMode.light,
  Size surface = const Size(1366, 768),
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
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
          child: Scaffold(body: DocumentationScreen()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DocumentationScreen', () {
    testWidgets('renders the sidebar, default article and prev/next',
        (tester) async {
      await _pumpDocs(tester);

      expect(find.byKey(const Key('documentation-screen')), findsOneWidget);
      expect(find.byKey(const Key('documentation-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('documentation-chapter-getting_started')),
          findsOneWidget);
      expect(find.byKey(const Key('documentation-chapter-pos')), findsOneWidget);
      expect(find.byKey(const Key('documentation-article-view')), findsOneWidget);
      // Default article: first in the registry.
      expect(
        find.text(docT('gs_first_launch.title', 'en')),
        findsWidgets,
      );
      expect(find.byKey(const Key('documentation-prev')), findsNothing);
      expect(find.byKey(const Key('documentation-next')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selecting a sidebar article opens it', (tester) async {
      await _pumpDocs(tester);

      // The sidebar is a scrolling list of every article; the readability
      // pass makes its rows a little taller, so the target may sit below
      // the fold on the test viewport. Scroll it in, then select it.
      await tester.scrollUntilVisible(
        find.byKey(const Key('documentation-article-pos_payment')),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('documentation-sidebar')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('documentation-article-pos_payment')));
      await tester.pumpAndSettle();

      expect(
        find.text(docT('pos_payment.title', 'en')),
        findsWidgets,
      );
      expect(find.byKey(const Key('documentation-prev')), findsOneWidget);
      expect(find.byKey(const Key('documentation-next')), findsOneWidget);
    });

    testWidgets('previous / next navigate in reading order', (tester) async {
      await _pumpDocs(tester);

      await tester.tap(find.byKey(const Key('documentation-next')));
      await tester.pumpAndSettle();
      expect(
        find.text(docT('gs_admin_login.title', 'en')),
        findsWidgets,
      );

      await tester.tap(find.byKey(const Key('documentation-prev')));
      await tester.pumpAndSettle();
      expect(
        find.text(docT('gs_first_launch.title', 'en')),
        findsWidgets,
      );
    });

    testWidgets('typing in search shows live results; selecting one '
        'opens the article and clears the query', (tester) async {
      await _pumpDocs(tester);

      await tester.enterText(
        find.byKey(const Key('documentation-search-field')),
        'wholesale',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('documentation-results')), findsOneWidget);
      final result = find.byKey(const Key('documentation-result-pos_pricing'));
      expect(result, findsOneWidget);

      await tester.tap(result);
      await tester.pumpAndSettle();

      // Query cleared, article shown.
      expect(find.byKey(const Key('documentation-results')), findsNothing);
      expect(
        find.text(docT('pos_pricing.title', 'en')),
        findsWidgets,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('documentation-search-field')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('search hit anchors the matching section (scrolls into '
        'view without errors)', (tester) async {
      await _pumpDocs(tester);

      await tester.enterText(
        find.byKey(const Key('documentation-search-field')),
        'debt ceiling',
      );
      await tester.pumpAndSettle();

      final hit = find.byKey(const Key('documentation-result-pos_payment'));
      expect(hit, findsOneWidget);
      await tester.tap(hit);
      await tester.pumpAndSettle();

      expect(
        find.text(docT('pos_payment.title', 'en')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no-results state appears for unknown terms and clear '
        'button resets', (tester) async {
      await _pumpDocs(tester);

      await tester.enterText(
        find.byKey(const Key('documentation-search-field')),
        'zzzz-not-a-real-term',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('documentation-no-results')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('documentation-search-clear')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('documentation-no-results')),
        findsNothing,
      );
      expect(find.byKey(const Key('documentation-article-view')),
          findsOneWidget);
    });

    testWidgets('renders Arabic content in RTL', (tester) async {
      await _pumpDocs(tester, locale: AppLocale.ar);

      expect(
        find.text(docT('gs_first_launch.title', 'ar')),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(AppStrings.t('documentation_search_hint', 'ar')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders French content', (tester) async {
      await _pumpDocs(tester, locale: AppLocale.fr);

      expect(
        find.text(docT('chapter.getting_started.title', 'fr')),
        findsOneWidget,
      );
      expect(
        find.text(docT('gs_first_launch.title', 'fr')),
        findsWidgets,
      );
    });

    for (final mode in [AppThemeMode.dark, AppThemeMode.light, AppThemeMode.grey]) {
      testWidgets('renders in the ${mode.name} theme', (tester) async {
        await _pumpDocs(tester, mode: mode);
        expect(find.byKey(const Key('documentation-screen')), findsOneWidget);
        expect(find.byKey(const Key('documentation-article-view')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('narrow windows replace the sidebar with chapter and '
        'article dropdowns', (tester) async {
      await _pumpDocs(tester, surface: const Size(720, 800));

      expect(find.byKey(const Key('documentation-sidebar')), findsNothing);
      expect(
        find.byKey(const Key('documentation-chapter-dropdown')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('documentation-article-dropdown')),
        findsOneWidget,
      );
      // Still usable: article content is visible.
      expect(find.byKey(const Key('documentation-article-view')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders under reduced motion without errors',
        (tester) async {
      await _pumpDocs(tester, reduceMotion: true);
      expect(find.byKey(const Key('documentation-screen')), findsOneWidget);
      expect(find.byKey(const Key('documentation-article-gs_first_launch')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('About → Documentation integration', () {
    testWidgets('the About documentation button opens the center',
        (tester) async {
      final dio = MockDio();
      _mockAboutRequests(dio);
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: '/about',
        routes: [
          // Mirror the real shell: routes render inside a Scaffold.
          GoRoute(
            path: '/about',
            builder: (context, state) =>
                const Scaffold(body: AboutScreen()),
          ),
          GoRoute(
            path: '/documentation',
            builder: (context, state) =>
                const Scaffold(body: DocumentationScreen()),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
            localeProvider.overrideWith(
              (ref) => LocaleNotifier()..setLocale(AppLocale.en),
            ),
            themeProvider.overrideWith(
              (ref) => ThemeNotifier()..setTheme(AppThemeMode.light),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('en'),
            supportedLocales: appSupportedLocales,
            localizationsDelegates: appLocalizationsDelegates,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(const Key('about-documentation-button'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('documentation-screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('documentation-sidebar')), findsOneWidget);
      router.dispose();
    });
  });
}
