// Phase L1-C - licensing route wiring and gating (Phase L2-C un-park).
//
// Pins: /licensing is reachable before login, an expired trial parks
// every other destination on it (login, authenticated shell, direct
// navigation) while the first-run wizard keeps precedence, an active or
// absent license snapshot changes nothing (Main PC / LAN startup flows
// untouched), the licensing state never disturbs the LAN connection
// phase, the login screen's "View license" entry works, and a verified
// Lifetime snapshot un-parks the install (back to login / dashboard)
// without a restart.
//
// License snapshots are set directly on the provider: the router listens
// to it and re-runs its redirect, exactly as it does when an interceptor
// response lands.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/dashboard/dashboard_screen.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/devices/setup_wizard_screen.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/features/licensing/license_snapshot.dart';
import 'package:supermarket_pos/features/licensing/licensing_screen.dart';
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

const _loginPath = '/api/v1/auth/login';
const _logoutPath = '/api/v1/auth/logout-token';

LicenseInfo _expiredLicense() => LicenseInfo(
      mode: LicenseMode.trialExpired,
      status: LicenseStatus.expired,
      trialActive: false,
      trialExpired: true,
      remainingSeconds: 0,
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      trialDays: 14,
    );

LicenseInfo _activeLicense() => LicenseInfo(
      mode: LicenseMode.trial,
      status: LicenseStatus.active,
      trialActive: true,
      trialExpired: false,
      remainingSeconds: 86400,
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      trialDays: 14,
    );

Map<String, dynamic> _lifetimeStatusPayload() => <String, dynamic>{
      'mode': 'lifetime',
      'status': 'active',
      'license_type': 'lifetime',
      'license_id': 'LIC-42',
      'activated_at': '2026-11-03T09:30:00Z',
      'trial': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late ProviderContainer container;

  Response<dynamic> adminLoginResponse() => Response<dynamic>(
        requestOptions: RequestOptions(path: _loginPath),
        data: {
          'access_token': 'tok-admin',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'full_name': 'Admin',
            'is_active': true,
            'roles': [
              {'name': 'admin'},
            ],
            'permissions': ['user_manage'],
          },
        },
        statusCode: 200,
      );

  Future<void> pumpApp(
    WidgetTester tester, {
    bool bootstrapped = false,
    bool? configured,
    Map<String, dynamic>? licenseStatus,
  }) async {
    // Desktop viewport: the login column (user list - PIN - submit) is
    // taller than the 800x600 test default, and an off-screen submit
    // button cannot be tapped.
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    Response<dynamic> listResponse(String path) => Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: {'items': <dynamic>[], 'total': 0},
        );

    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      switch (path) {
        case '/api/v1/auth/login-users':
          return Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {
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
            },
          );
        case '/api/v1/auth/setup/check':
          return Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {'setup_needed': false},
          );
        case '/api/v1/auth/me':
          return Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': [
                {'name': 'admin'},
              ],
              'permissions': ['user_manage'],
            },
          );
        case '/api/v1/license/status':
          // Phase L2-E: only the boot-fetch test supplies a payload; every
          // other test keeps the previous default (a non-map body the
          // snapshot parser declines, leaving the provider untouched).
          if (licenseStatus != null) {
            return Response<dynamic>(
              requestOptions: RequestOptions(path: path),
              statusCode: 200,
              data: licenseStatus,
            );
          }
          return listResponse(path);
        default:
          return listResponse(path);
      }
    });

    when(() => dio.post(_loginPath, data: any(named: 'data')))
        .thenAnswer((_) async => adminLoginResponse());
    when(() => dio.post(_logoutPath, data: any(named: 'data'))).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: _logoutPath),
        statusCode: 200,
        data: {'message': 'logged out'},
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
          if (bootstrapped)
            installBootstrappedProvider.overrideWithValue(true),
          if (configured != null)
            networkConfiguredProvider.overrideWith((ref) async => configured),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    // Bounded pumps: the startup splash holds a fixed minimum sequence,
    // so pumpAndSettle is not reliable this early (see first_run test).
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  String location() => container.read(routerProvider).state.uri.path;

  Future<void> setLicense(WidgetTester tester, LicenseInfo license) async {
    container.read(licenseStatusProvider.notifier).state = license;
    // The router re-runs its redirect on this change; settle so the route
    // transition finishes and the previous route leaves the tree.
    await tester.pumpAndSettle();
  }

  Future<void> loginAsAdmin(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();
  }

  group('unauthenticated gating', () {
    testWidgets('baseline: no license snapshot - login, no banner',
        (tester) async {
      await pumpApp(tester);

      expect(location(), '/login');
      expect(find.byKey(const Key('license-banner')), findsNothing);
      expect(container.read(licenseStatusProvider), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired snapshot parks the login screen on /licensing',
        (tester) async {
      await pumpApp(tester);
      expect(location(), '/login');

      await setLicense(tester, _expiredLicense());

      expect(location(), '/licensing');
      expect(find.byType(LicensingScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byKey(const Key('license-screen-title')), findsOneWidget);
      // Unauthenticated + expired: no back and no logout action.
      expect(find.byKey(const Key('license-back-button')), findsNothing);
      expect(find.byKey(const Key('license-logout-button')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an active snapshot does not gate the login screen',
        (tester) async {
      await pumpApp(tester);
      expect(location(), '/login');

      await setLicense(tester, _activeLicense());

      expect(location(), '/login');
      expect(find.byKey(const Key('license-banner')), findsNothing,
          reason: 'the banner lives in the authenticated shell only');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the login screen exposes the pre-login licensing entry',
        (tester) async {
      await pumpApp(tester);
      expect(location(), '/login');
      expect(find.byKey(const Key('license-view-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('license-view-button')));
      await tester.pumpAndSettle();

      expect(location(), '/licensing');
      expect(find.byType(LicensingScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the licensing screen can navigate back to login',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('license-view-button')));
      await tester.pumpAndSettle();
      expect(location(), '/licensing');
      // No snapshot yet - unknown card, not expired - back action shows.
      expect(find.byKey(const Key('license-back-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('license-back-button')));
      await tester.pumpAndSettle();

      expect(location(), '/login');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a verified Lifetime snapshot releases the parked licensing '
        'screen so the back action returns to login', (tester) async {
      await pumpApp(tester);
      await setLicense(tester, _expiredLicense());
      expect(location(), '/licensing');
      expect(find.byKey(const Key('license-back-button')), findsNothing,
          reason: 'while expired there is nowhere to go back to');

      container.read(licenseSnapshotProvider.notifier).state =
          LicenseSnapshot.tryParse(_lifetimeStatusPayload())!;
      await tester.pumpAndSettle();

      // Soft un-park: the gate stops holding the install here (the
      // pre-login visit to /licensing keeps working), and the screen now
      // offers the way out.
      expect(location(), '/licensing');
      expect(find.byKey(const Key('license-back-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('license-back-button')));
      await tester.pumpAndSettle();

      expect(location(), '/login');
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(LicensingScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('authenticated shell', () {
    testWidgets('an expired snapshot parks the shell on /licensing with a '
        'logout action', (tester) async {
      await pumpApp(tester);
      await loginAsAdmin(tester);
      expect(location(), '/');
      expect(find.byType(DashboardScreen), findsOneWidget);

      await setLicense(tester, _expiredLicense());

      expect(location(), '/licensing');
      expect(find.byType(LicensingScreen), findsOneWidget);
      expect(find.byType(DashboardScreen), findsNothing);
      expect(find.byKey(const Key('license-logout-button')), findsOneWidget);
      expect(find.byKey(const Key('license-back-button')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an active snapshot keeps the dashboard and shows the banner',
        (tester) async {
      await pumpApp(tester);
      await loginAsAdmin(tester);
      expect(location(), '/');

      await setLicense(tester, _activeLicense());
      await tester.pumpAndSettle();

      expect(location(), '/');
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byKey(const Key('license-banner')), findsOneWidget);
      // Unmount to cancel the banner's one-minute refresh timer.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the startup fetch recognizes a Lifetime install with no '
        'user action (restart scenario)', (tester) async {
      // Phase L2-E: a licensed install restarts; the best-effort boot
      // fetch (main.dart -> licenseIngestorProvider) must load Lifetime
      // from the first screen onward, without the licensing page ever
      // being opened.
      await pumpApp(tester, licenseStatus: _lifetimeStatusPayload());

      final snap = container.read(licenseSnapshotProvider);
      expect(snap, isNotNull,
          reason: 'the boot fetch ran during startup with no user action');
      expect(snap!.isLifetime, isTrue);
      expect(snap.licenseId, 'LIC-42');

      await loginAsAdmin(tester);
      expect(location(), '/');
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byKey(const Key('license-banner-lifetime')), findsOneWidget,
          reason: 'the shell presents the boot-fetched Lifetime state');
      // Unmount to cancel the banner's one-minute refresh timer.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('direct navigation away from /licensing is redirected back',
        (tester) async {
      await pumpApp(tester);
      await loginAsAdmin(tester);

      await setLicense(tester, _expiredLicense());
      expect(location(), '/licensing');

      container.read(routerProvider).go('/products');
      await tester.pumpAndSettle();

      expect(location(), '/licensing');
      expect(find.byType(LicensingScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a verified Lifetime snapshot releases the parked shell so '
        'the back action returns to the dashboard', (tester) async {
      await pumpApp(tester);
      await loginAsAdmin(tester);
      expect(location(), '/');

      await setLicense(tester, _expiredLicense());
      expect(location(), '/licensing');
      expect(find.byKey(const Key('license-logout-button')), findsOneWidget);
      expect(find.byKey(const Key('license-back-button')), findsNothing);

      container.read(licenseSnapshotProvider.notifier).state =
          LicenseSnapshot.tryParse(_lifetimeStatusPayload())!;
      await tester.pumpAndSettle();

      expect(location(), '/licensing',
          reason: 'the banner link keeps working - un-park means "no '
              'longer held here", not "kicked off the screen"');
      expect(find.byKey(const Key('license-logout-button')), findsNothing);
      expect(find.byKey(const Key('license-back-button')), findsOneWidget,
          reason: 'a licensed install always has the way out');

      await tester.tap(find.byKey(const Key('license-back-button')));
      await tester.pumpAndSettle();

      expect(location(), '/');
      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(find.byType(LicensingScreen), findsNothing);
      expect(find.byKey(const Key('license-banner-lifetime')), findsOneWidget,
          reason: 'the shell presents the Lifetime state, not a trial strip');
      // Unmount to cancel every license-card refresh timer.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('precedence and separation of concerns', () {
    testWidgets('the first-run wizard keeps precedence over an expired '
        'license', (tester) async {
      await pumpApp(tester, bootstrapped: true, configured: false);
      expect(location(), '/setup-network');
      expect(find.byType(SetupWizardScreen), findsOneWidget);

      await setLicense(tester, _expiredLicense());

      expect(location(), '/setup-network');
      expect(find.byType(SetupWizardScreen), findsOneWidget);
      expect(find.byType(LicensingScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a license snapshot never changes the LAN connection phase',
        (tester) async {
      await pumpApp(tester);
      await loginAsAdmin(tester);

      // Let the boot-time connection bootstrap settle first.
      await tester.pumpAndSettle();
      final phaseBefore = container.read(lanConnectionProvider).phase;

      await setLicense(tester, _expiredLicense());
      await tester.pump(const Duration(milliseconds: 200));

      expect(location(), '/licensing');
      expect(
        container.read(lanConnectionProvider).phase,
        phaseBefore,
        reason: 'license state must not drive connectivity',
      );
      expect(container.read(licenseStatusProvider), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
