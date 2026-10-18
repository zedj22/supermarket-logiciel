// Klick POS — startup splash and brand identity contract.
//
// Cold start must:
//   1. mount the brand splash (drawn logo, wordmark, localized tagline)
//      as the FIRST surface and hold every route there while auth is
//      checking AND until the fixed minimum sequence has played;
//   2. reveal the real destination exactly when auth is done — login for
//      a fresh install, the shell for a restored session, never a stuck
//      splash on an auth failure;
//   3. release its one-shot gate only once: logout, navigation and auth
//      changes must never replay the splash;
//   4. honour reduced motion by opening the gate without animating;
//   5. fit every supported window size without overflow, RTL and LTR.
//
// The gated PNG/ICO generation lives in test/tools/.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/splash/splash_screen.dart';
import 'package:supermarket_pos/l10n/locale_provider.dart';
import 'package:supermarket_pos/main.dart';
import 'package:supermarket_pos/network/api_client.dart';
import 'package:supermarket_pos/router/app_router.dart';

class MockDio extends Mock implements Dio {}

class _NoSessionCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => false;

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => const [];

  @override
  Future<List<String>> readUserPermissions() async => const [];

  @override
  Future<void> clearAll() async {}
}

class _SessionCredentialStorage extends SecureCredentialStorage {
  @override
  Future<bool> hasToken() async => true;

  @override
  Future<String?> readToken() async => 'tok-admin';

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> saveUserId(String userId) async {}

  @override
  Future<void> saveUserName(String name) async {}

  @override
  Future<void> saveUserRoles(List<String> roles) async {}

  @override
  Future<void> saveUserPermissions(List<String> permissions) async {}

  @override
  Future<List<String>> readUserRoles() async => const [];

  @override
  Future<List<String>> readUserPermissions() async => const [];

  @override
  Future<void> clearAll() async {}
}

const _setupPath = '/api/v1/auth/setup/check';
const _loginUsersPath = '/api/v1/auth/login-users';
const _loginPath = '/api/v1/auth/login';
const _logoutPath = '/api/v1/auth/logout-token';
const _usersPath = '/api/v1/users';
const _verifyTokenPath = '/api/v1/auth/verify-token';
const _mePath = '/api/v1/auth/me';

Response<dynamic> _response(String path, Map<String, dynamic> data) =>
    Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  void stubBootRequests(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(_setupPath)).thenAnswer(
      (_) async => _response(_setupPath, {'setup_needed': false}),
    );
    when(() => dio.get(_loginUsersPath)).thenAnswer(
      (_) async => _response(_loginUsersPath, {
        'items': [
          {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
          },
        ],
        'total': 1,
      }),
    );
  }

  void stubLoginAndLogout(MockDio dio) {
    when(() => dio.post(_loginPath, data: any(named: 'data'))).thenAnswer(
      (_) async => _response(_loginPath, {
        'access_token': 'tok-admin',
        'expires_in': 3600,
        'user': {
          'id': 'u1',
          'full_name': 'Admin',
          'is_active': true,
          'roles': [
            {'name': 'admin'},
          ],
          'permissions': ['user_manage', 'pos_sale'],
        },
      }),
    );
    when(() => dio.post(_logoutPath, data: any(named: 'data'))).thenAnswer(
      (_) async => _response(_logoutPath, {'message': 'logged out'}),
    );
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    required MockDio dio,
    SecureCredentialStorage? credentials,
    AppLocale? locale,
    Size? viewport,
  }) async {
    if (viewport != null) {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider.overrideWithValue(
            credentials ?? _NoSessionCredentialStorage(),
          ),
          if (locale != null)
            localeProvider.overrideWith((ref) {
              final notifier = LocaleNotifier();
              notifier.setLocale(locale);
              return notifier;
            }),
        ],
        child: const SupermarketPosApp(),
      ),
    );
  }

  /// Login-screen PIN flow (mirrors the shared auth harnesses).
  Future<void> loginAsAdmin(WidgetTester tester) async {
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
  }

  group('startup splash sequence', () {
    testWidgets(
      'cold start mounts the brand splash first, then reveals login',
      (tester) async {
        final dio = MockDio();
        stubBootRequests(dio);

        await pumpApp(tester, dio: dio);

        expect(find.byType(MaterialApp), findsOneWidget,
            reason: 'one MaterialApp for the whole app life');
        expect(find.byType(SplashScreen), findsOneWidget);
        expect(find.byKey(const Key('splash-screen')), findsOneWidget);
        expect(find.byKey(const Key('splash-logo')), findsOneWidget);
        expect(find.byKey(const Key('splash-wordmark')), findsOneWidget);
        expect(find.text('Klick POS'), findsOneWidget);
        expect(find.byKey(const Key('splash-tagline')), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing,
            reason: 'no real screen may mount before the sequence ends');
        expect(tester.takeException(), isNull);

        await tester.pumpAndSettle();

        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing,
            reason: 'the splash is a cold-start surface only');
        expect(ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp)),
        ).read(splashGateProvider), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the spinner shows only while auth is checking, and the gate '
      'opens exactly when the sequence has completed',
      (tester) async {
        final dio = MockDio();
        stubBootRequests(dio);
        // Hold auth in `checking` until the test releases it.
        final setupCheck = Completer<void>();
        when(() => dio.get(_setupPath)).thenAnswer(
          (_) => setupCheck.future.then(
            (_) => _response(_setupPath, {'setup_needed': false}),
          ),
        );

        await pumpApp(tester, dio: dio);

        expect(find.byKey(const Key('splash-screen')), findsOneWidget,
            reason: 'auth checking keeps every route on the splash');
        expect(find.byKey(const Key('splash-progress')), findsOneWidget);

        setupCheck.complete();
        await tester.pump();

        expect(find.byKey(const Key('splash-screen')), findsOneWidget,
            reason: 'auth done but the minimum sequence still holds');
        expect(find.byKey(const Key('splash-progress')), findsNothing,
            reason: 'the spinner reports loading only, never decoration');

        await tester.pumpAndSettle();

        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a restored session reveals the shell directly — no login flash, '
      'no splash left behind',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final dio = MockDio();
        stubBootRequests(dio);
        when(() => dio.get(_usersPath)).thenAnswer(
          (_) async => _response(_usersPath, {
            'items': [
              {
                'id': 'u1',
                'full_name': 'Admin',
                'is_active': true,
                'roles': [
                  {'name': 'admin'},
                ],
              },
            ],
            'total': 1,
          }),
        );
        when(() => dio.get(_mePath)).thenAnswer(
          (_) async => _response(_mePath, {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
            'permissions': ['user_manage'],
          }),
        );
        when(() => dio.post(_verifyTokenPath, data: any(named: 'data')))
            .thenAnswer(
          (_) async => _response(_verifyTokenPath, {
            'valid': true,
            'user': {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
              'permissions': ['user_manage'],
            },
          }),
        );

        await pumpApp(
          tester,
          dio: dio,
          credentials: _SessionCredentialStorage(),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ScaffoldWithNav), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing,
            reason: 'a valid session never touches the login screen');
        expect(find.byType(SplashScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an auth init failure settles on login — the splash never strands',
      (tester) async {
        final dio = MockDio();
        when(() => dio.interceptors).thenReturn(Interceptors());
        when(() => dio.options).thenReturn(BaseOptions());
        when(() => dio.get(any())).thenThrow(
          DioException.connectionError(
            requestOptions: RequestOptions(path: '/'),
            reason: 'server down',
          ),
        );

        await pumpApp(tester, dio: dio);

        // Bounded pumps (60 × 50ms = 3000ms): the splash controller is the
        // clock, then its 350ms fade-out to the login route plays.
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.byType(LoginScreen), findsOneWidget,
            reason: 'auth failure resolves to login, not a dead splash');
        expect(find.byType(SplashScreen), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('one-shot gate', () {
    testWidgets(
      'logout and re-login never replay the splash',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final dio = MockDio();
        stubBootRequests(dio);
        stubLoginAndLogout(dio);

        await pumpApp(tester, dio: dio);
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);

        await loginAsAdmin(tester);
        expect(find.byType(ScaffoldWithNav), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing);

        await tester.tap(find.byKey(const Key('logout-button')));
        await tester.pumpAndSettle();

        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(SplashScreen), findsNothing,
            reason: 'the gate opened once and stays open for the run');
        expect(ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp)),
        ).read(splashGateProvider), isTrue,
            reason: 'the gate is one-shot, never reset');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('reduced motion', () {
    testWidgets(
      'skips the sequence: gate opens on the first frame, no animation',
      (tester) async {
        final dio = MockDio();
        stubBootRequests(dio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
              credentialStorageProvider
                  .overrideWithValue(_NoSessionCredentialStorage()),
            ],
            child: MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: const SplashScreen(),
              ),
            ),
          ),
        );
        await tester.pump();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(SplashScreen)),
        );
        expect(container.read(splashGateProvider), isTrue,
            reason: 'no motion means no held sequence');
        expect(find.byKey(const Key('splash-logo')), findsOneWidget);
        expect(find.byKey(const Key('splash-wordmark')), findsOneWidget);
        expect(find.byKey(const Key('splash-tagline')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('localization and layout', () {
    testWidgets('the tagline is the localized about_description', (
      tester,
    ) async {
      final dio = MockDio();
      stubBootRequests(dio);

      await pumpApp(tester, dio: dio, locale: AppLocale.ar);
      expect(
        find.text(AppStrings.t('about_description', 'ar')),
        findsOneWidget,
      );
      expect(find.text('Klick POS'), findsOneWidget,
          reason: 'the wordmark is the brand name, never translated');

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    for (final locale in <AppLocale>[AppLocale.ar, AppLocale.en]) {
      for (final viewport in const <Size>[
        Size(600, 600),
        Size(1024, 768),
        Size(1366, 768),
        Size(1920, 1080),
      ]) {
        testWidgets(
          'no overflow at ${viewport.width.toInt()}×${viewport.height.toInt()} '
          '(${locale.name})',
          (tester) async {
            final dio = MockDio();
            stubBootRequests(dio);

            await pumpApp(
              tester,
              dio: dio,
              locale: locale,
              viewport: viewport,
            );

            expect(find.byKey(const Key('splash-screen')), findsOneWidget);
            expect(find.byKey(const Key('splash-wordmark')), findsOneWidget);
            expect(tester.takeException(), isNull);

            await tester.pumpAndSettle();

            expect(find.byType(LoginScreen), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });
}
