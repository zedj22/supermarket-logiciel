// Phase 16 (§23.2 / §33 step 11) — first-run router wiring.
//
// The router refuses every route except `/setup-network` until the wizard
// has produced a run mode, but only for installs that actually went through
// `main()`. Two things are pinned here: the forced first-run redirect, and
// the fact that the gate is inert for hosts that embed the app without
// bootstrapping an install (so the pre-existing login flows still work).
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/devices/setup_wizard_screen.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late ProviderContainer container;

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool bootstrapped,
    required bool configured,
  }) async {
    final dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: path == '/api/v1/auth/login-users'
            ? {'items': <dynamic>[], 'total': 0}
            : {'setup_needed': false},
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
          installBootstrappedProvider.overrideWithValue(bootstrapped),
          networkConfiguredProvider.overrideWith((ref) async => configured),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    // Bounded pumps: the login screen keeps a progress indicator alive, so
    // `pumpAndSettle` would never return. 40 × 50ms = 2000ms — long enough
    // for the startup splash's fixed minimum sequence (1600ms, see
    // kSplashSequenceDuration) to release the router on top of that.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
  }

  String location() => container.read(routerProvider).state.uri.path;

  group('first-run wizard gate (§23.2)', () {
    testWidgets('a bootstrapped install with no run mode lands on the wizard',
        (tester) async {
      await pumpApp(tester, bootstrapped: true, configured: false);

      expect(location(), '/setup-network');
      expect(find.byType(SetupWizardScreen), findsOneWidget);
      expect(find.text('Admin'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the wizard is the only reachable route until it finishes',
        (tester) async {
      await pumpApp(tester, bootstrapped: true, configured: false);
      expect(location(), '/setup-network');

      container.read(routerProvider).go('/pos');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(location(), '/setup-network');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an install with a run mode goes straight to login',
        (tester) async {
      await pumpApp(tester, bootstrapped: true, configured: true);

      expect(location(), '/login');
      expect(find.byType(SetupWizardScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hosts that never bootstrap the install are not forced in',
        (tester) async {
      await pumpApp(tester, bootstrapped: false, configured: false);

      expect(location(), '/login');
      expect(find.byType(SetupWizardScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
