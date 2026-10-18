// Phase 16 §23.3 — boot-time reconnect wiring (2-PC QA regression).
//
// The connection machine used to be created ONLY by the authenticated shell
// (the status chip and the boot-time modal). A paired client whose
// `paired_server_url` had gone stale could therefore not authenticate, never
// mounted the shell, and never ran `bootstrap()` — so nothing ever repaired
// the address and nothing ever rediscovered. These tests pin:
//
//   1. the machine exists on the FIRST frame, while only login is mounted;
//   2. the login screen's Retry re-acquires the address (cached first, then
//      UDP rediscovery) before it re-asks for the user list — the reported
//      "Retry produces no request at all" symptom.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/auth/credential_storage.dart';
import 'package:supermarket_pos/features/auth/login_screen.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';
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

class _CountingDiscovery implements DiscoveryService {
  final List<ServerOffer> offers;
  int sweepCount = 0;
  bool disposed = false;

  _CountingDiscovery(this.offers);

  @override
  Stream<ServerOffer> discover(
      {Duration budget = const Duration(seconds: 2)}) {
    sweepCount++;
    return Stream.fromIterable(offers);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

const String staleUrl = 'http://192.168.1.7:8000';
const String movedUrl = 'http://192.168.1.20:8000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  void stubPublicGet(MockDio dio) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: path == '/api/v1/auth/login-users'
            ? <String, dynamic>{
                'items': <dynamic>[
                  <String, dynamic>{
                    'id': 'u1',
                    'full_name': 'Admin',
                    'is_active': true,
                    'roles': <dynamic>[
                      <String, dynamic>{'name': 'admin'},
                    ],
                  },
                ],
                'total': 1,
              }
            : <String, dynamic>{'setup_needed': false},
      );
    });
  }

  testWidgets(
      'the reconnect machine is created on the first frame, before any login',
      (tester) async {
    // A client install that never completed pairing: `bootstrap()` can only
    // reach `disconnected` from `app_run_mode == client`, so seeing that
    // phase proves the machine ran while the shell is nowhere in sight.
    SharedPreferences.setMockInitialValues(<String, Object>{
      appRunModeStorageKey: appRunModeClient,
    });

    final dio = MockDio();
    stubPublicGet(dio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    // Bounded pumps (40 × 50ms = 2000ms): the startup splash holds every
    // route for its fixed minimum sequence (kSplashSequenceDuration,
    // 1600ms) before the login screen mounts, then auth resolves.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(ScaffoldWithNav), findsNothing,
        reason: 'no shell means no status chip and no boot modal');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    expect(container.exists(lanConnectionProvider), isTrue,
        reason: 'the provider must be instantiated before authentication');
    expect(container.read(lanConnectionProvider).phase, LanPhase.disconnected,
        reason: 'only bootstrap() can leave a client install here');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the login Retry re-acquires the moved server address, then reloads',
      (tester) async {
    // The reported failure: PC2 paired against 192.168.1.7, PC1 moved to
    // .20, PC2 restarted and the login screen's Retry did nothing at all.
    SharedPreferences.setMockInitialValues(<String, Object>{
      pairedServerUrlStorageKey: staleUrl,
      pairedServerIdStorageKey: 'server-1',
      appRunModeStorageKey: appRunModeClient,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'device_token': 'tok-device',
    });

    final dio = MockDio();
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());

    final requestedUrls = <String>[];
    when(() => dio.get(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (path == '/api/v1/auth/setup/check') {
        return Response<dynamic>(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: <String, dynamic>{'setup_needed': false},
        );
      }
      requestedUrls.add(dio.options.baseUrl);
      if (requestedUrls.length == 1) {
        // First attempt: the remembered address is gone.
        throw DioException.connectionError(
          requestOptions: RequestOptions(path: path),
          reason: 'no route to host',
        );
      }
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'id': 'u1',
              'full_name': 'Admin',
              'is_active': true,
              'roles': <dynamic>[
                <String, dynamic>{'name': 'admin'},
              ],
            },
          ],
          'total': 1,
        },
      );
    });

    final discovery = _CountingDiscovery([
      const ServerOffer(
        address: '192.168.1.20',
        serverId: 'server-1',
        name: 'Store',
        httpPort: 8000,
        tls: false,
        nonce: 'a1b2c3d4e5f60718',
      ),
    ]);

    // Mirrors `main()`: the client boots against the remembered address.
    final api = ApiClient(dio: dio)..setBaseUrl(staleUrl);

    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localeProvider.overrideWith(
            (ref) => LocaleNotifier(prefs)..setLocale(AppLocale.en),
          ),
          apiClientProvider.overrideWithValue(api),
          credentialStorageProvider
              .overrideWithValue(_NoSessionCredentialStorage()),
          networkConfiguredProvider.overrideWith((ref) async => true),
          lanConnectionProvider.overrideWith((ref) {
            final notifier = LanConnectionNotifier(
              api,
              discoveryFactory: (_) => discovery,
              probe: (url) async {
                if (url == staleUrl) {
                  throw DioException.connectionError(
                    requestOptions: RequestOptions(path: url),
                    reason: 'no route to host',
                  );
                }
                return ServerProbe(
                  baseUrl: url,
                  serverId: 'server-1',
                  storeName: 'Store',
                  protocol: 1,
                  version: '1.0.0',
                  database: 'connected',
                  databaseConnected: true,
                );
              },
              heartbeatInterval: const Duration(hours: 1),
            );
            // Riverpod disposes the notifier with the provider — no
            // addTearDown here, a second dispose is a StateNotifier error.
            return notifier;
          }),
        ],
        child: const SupermarketPosApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Network error, please try again'), findsOneWidget,
        reason: 'the reported symptom: the client cannot even load users');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(discovery.sweepCount, 1,
        reason: 'Retry must run UDP rediscovery, not just repaint');
    expect(requestedUrls, [staleUrl, movedUrl],
        reason: 'first attempt at the remembered address, then at the new one');
    expect(api.baseUrl, movedUrl);
    expect(api.hasDeviceIdentity, isTrue,
        reason: 'the device headers survive the address move (no re-pair)');

    expect(prefs.getString(pairedServerUrlStorageKey), movedUrl,
        reason: 'the moved address is persisted for the next boot');
    expect(prefs.getString(pairedServerIdStorageKey), 'server-1');

    expect(find.text('Admin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
