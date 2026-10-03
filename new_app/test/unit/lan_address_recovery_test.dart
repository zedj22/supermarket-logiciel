// Phase 16 §23.3 — reconnect = cached address FIRST, then UDP rediscovery.
//
// Real 2-PC QA regression: PC1's address changed (192.168.1.7 → .20) and the
// paired client came back up holding the old address. These tests pin the
// contract that makes a DHCP/IP change survivable *without* a re-pair:
//
//   * the remembered `paired_server_url` is tried first (no sweep when it
//     still answers),
//   * when it is unusable the client sweeps for offers and validates them
//     with /health + /system/info,
//   * only an offer with the SAME `server_id` is ever adopted,
//   * `paired_server_url` is rewritten, the device token is not,
//   * the same recovery runs from the login Retry and from `retryNow`.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supermarket_pos/features/devices/connection_provider.dart';
import 'package:supermarket_pos/features/devices/device_identity.dart';
import 'package:supermarket_pos/features/devices/discovery_service.dart';
import 'package:supermarket_pos/network/api_client.dart';

class MockDio extends Mock implements Dio {}

/// Discovery fake that answers immediately and counts the sweeps, so a test
/// can prove whether UDP rediscovery ran at all.
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

ServerOffer _offer({
  required String address,
  required String serverId,
  int port = 8000,
}) {
  return ServerOffer(
    address: address,
    serverId: serverId,
    name: 'Store',
    httpPort: port,
    tls: false,
    nonce: 'a1b2c3d4e5f60718',
  );
}

ServerProbe _probeResult(String url, {required String serverId}) {
  return ServerProbe(
    baseUrl: url,
    serverId: serverId,
    storeName: 'Store',
    protocol: 1,
    version: '1.0.0',
    database: 'connected',
    databaseConnected: true,
  );
}

/// The dead address the client still remembers after PC1 moved.
const String staleUrl = 'http://192.168.1.7:8000';
const String movedUrl = 'http://192.168.1.20:8000';
const String pairedId = 'server-1';

DioException _connectionError(String url) {
  return DioException.connectionError(
    requestOptions: RequestOptions(path: url),
    reason: 'no route to host',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> probedUrls;

  /// Default probe: the remembered address is dead, the moved one answers
  /// as the SAME server.
  Future<ServerProbe> probeFn(String url) async {
    probedUrls.add(url);
    if (url == staleUrl) throw _connectionError(url);
    return _probeResult(url, serverId: pairedId);
  }

  /// Happy-path app API: /health and /system/info both answer.
  void stubApi(MockDio dio, {required bool healthy}) {
    when(() => dio.interceptors).thenReturn(Interceptors());
    when(() => dio.options).thenReturn(BaseOptions());
    when(() => dio.get(any(), options: any(named: 'options')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      if (!healthy) throw _connectionError(path);
      return Response<dynamic>(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: path == '/api/v1/system/info'
            ? <String, dynamic>{
                'server_id': pairedId,
                'protocol': 1,
                'name': 'Store',
                'version': '1.0.0',
                'database_status': 'connected',
              }
            : <String, dynamic>{
                'status': 'healthy',
                'database': 'connected',
              },
      );
    });
  }

  Future<LanConnectionNotifier> buildNotifier({
    required MockDio dio,
    required _CountingDiscovery discovery,
    ApiClient? api,
    Future<ServerProbe> Function(String url)? probe,
  }) async {
    final notifier = LanConnectionNotifier(
      api ?? ApiClient(dio: dio),
      discoveryFactory: (_) => discovery,
      probe: probe ?? probeFn,
      // Keep the periodic heartbeat far outside the test's lifetime; each
      // test drives the tick it needs explicitly.
      heartbeatInterval: const Duration(hours: 1),
    );
    addTearDown(notifier.dispose);
    await Future<void>.delayed(Duration.zero);
    return notifier;
  }

  setUp(() {
    probedUrls = <String>[];
    SharedPreferences.setMockInitialValues(<String, Object>{
      pairedServerUrlStorageKey: staleUrl,
      pairedServerIdStorageKey: pairedId,
      appRunModeStorageKey: appRunModeClient,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'device_token': 'tok-device',
    });
  });

  group('bootstrap — cached address first, then UDP rediscovery (§23.3)', () {
    test('a remembered address that still answers is used, with no sweep',
        () async {
      final dio = MockDio();
      stubApi(dio, healthy: true);
      final discovery = _CountingDiscovery(
        [_offer(address: '192.168.1.20', serverId: pairedId)],
      );
      final notifier = await buildNotifier(
        dio: dio,
        discovery: discovery,
        // The remembered address is alive and still OUR server.
        probe: (url) async {
          probedUrls.add(url);
          return _probeResult(url, serverId: pairedId);
        },
      );

      final phase = await notifier.bootstrap();

      expect(phase, LanPhase.connected);
      expect(notifier.state.baseUrl, staleUrl);
      expect(discovery.sweepCount, 0,
          reason: 'a healthy cached address must not trigger a sweep');
      expect(probedUrls, [staleUrl]);
    });

    test('a dead remembered address is replaced by the rediscovered one',
        () async {
      final dio = MockDio();
      stubApi(dio, healthy: true);
      final api = ApiClient(dio: dio);
      final discovery = _CountingDiscovery(
        [_offer(address: '192.168.1.20', serverId: pairedId)],
      );
      final notifier =
          await buildNotifier(dio: dio, discovery: discovery, api: api);

      final phase = await notifier.bootstrap();

      expect(phase, LanPhase.connected);
      expect(discovery.sweepCount, 1);
      expect(discovery.disposed, isTrue, reason: 'the sweep socket is closed');
      expect(notifier.state.baseUrl, movedUrl);
      expect(notifier.state.serverId, pairedId);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(pairedServerUrlStorageKey), movedUrl,
          reason: 'the new address must survive the next boot');
      expect(prefs.getString(pairedServerIdStorageKey), pairedId);

      // Same server, same pairing: the token is neither cleared nor
      // re-issued, so no re-pair is ever asked for.
      expect(await const FlutterSecureStorage().read(key: 'device_token'),
          'tok-device');
      expect(api.hasDeviceIdentity, isTrue);
      expect(api.baseUrl, movedUrl);
      expect(notifier.state.deviceErrorCode, isNull);
      expect(notifier.state.errorMessage, isNull);
    });

    test('an offer from a DIFFERENT server is never adopted', () async {
      final dio = MockDio();
      stubApi(dio, healthy: false);
      final discovery = _CountingDiscovery(
        [_offer(address: '192.168.1.99', serverId: 'server-2')],
      );
      final notifier = await buildNotifier(
        dio: dio,
        discovery: discovery,
        // Something else lives at the remembered address now, and the sweep
        // only sees that other store.
        probe: (url) async {
          probedUrls.add(url);
          return _probeResult(url, serverId: 'server-2');
        },
      );

      await notifier.bootstrap();

      expect(discovery.sweepCount, 1, reason: 'the sweep did run');
      expect(probedUrls, [staleUrl],
          reason: 'an offer with another server_id is filtered before probing');
      expect(notifier.state.baseUrl, staleUrl,
          reason: 'identity is server_id: a foreign server is never adopted');
      expect(notifier.state.errorMessage, 'unreachable');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(pairedServerUrlStorageKey), staleUrl);
      expect(prefs.getString(pairedServerIdStorageKey), pairedId);
      expect(await const FlutterSecureStorage().read(key: 'device_token'),
          'tok-device',
          reason: 'no re-pair and no link wipe for a foreign offer');
    });
  });

  group('retryNow / login Retry (§23.3)', () {
    test('retryNow rediscovers instead of re-hitting the dead address',
        () async {
      final dio = MockDio();
      stubApi(dio, healthy: true);
      final discovery = _CountingDiscovery(
        [_offer(address: '192.168.1.20', serverId: pairedId)],
      );
      final notifier = await buildNotifier(dio: dio, discovery: discovery);
      notifier.debugSetState(const LanConnectionState(
        phase: LanPhase.disconnected,
        baseUrl: staleUrl,
        serverId: pairedId,
        errorMessage: 'unreachable',
      ));

      await notifier.retryNow();

      expect(discovery.sweepCount, 1);
      expect(notifier.state.baseUrl, movedUrl);
      expect(notifier.state.phase, LanPhase.connected);
      expect(notifier.state.errorMessage, isNull);
    });

    test('reacquireServer is a no-op for an install that was never paired',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        appRunModeStorageKey: appRunModeClient,
      });
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      final dio = MockDio();
      stubApi(dio, healthy: true);
      final discovery = _CountingDiscovery(const <ServerOffer>[]);
      final notifier = await buildNotifier(dio: dio, discovery: discovery);

      final recovered = await notifier.reacquireServer();

      expect(recovered, isFalse);
      expect(discovery.sweepCount, 0);
      expect(probedUrls, isEmpty);
    });

    test('reacquireServer repairs the link the login Retry is holding',
        () async {
      final dio = MockDio();
      stubApi(dio, healthy: true);
      final discovery = _CountingDiscovery(
        [_offer(address: '192.168.1.20', serverId: pairedId)],
      );
      final notifier = await buildNotifier(dio: dio, discovery: discovery);

      final recovered = await notifier.reacquireServer();

      expect(recovered, isTrue);
      expect(discovery.sweepCount, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(pairedServerUrlStorageKey), movedUrl);
    });
  });
}
