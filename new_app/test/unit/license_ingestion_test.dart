// Phase L1-C — system-info ingestion through the shared ApiClient.
//
// One interceptor hook on the existing `GET /api/v1/system/info` path
// feeds `licenseStatusProvider`: no extra request, no polling. Pins the
// happy path, an old server without the `license` field (never active),
// a connection failure (state must stay null — connectivity is a
// separate concern), and the fact that other endpoints never touch the
// license state.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/auth/auth_provider.dart';
import 'package:supermarket_pos/features/licensing/license_info.dart';
import 'package:supermarket_pos/features/licensing/license_providers.dart';
import 'package:supermarket_pos/network/api_client.dart';

Map<String, dynamic> _licenseBody({
  required String mode,
  required String status,
  int remaining = 0,
  String? expiresAt,
}) =>
    <String, dynamic>{
      'name': 'Supermarket Pro',
      'version': '0.1.0',
      'environment': 'dev',
      'protocol': 1,
      'license': <String, dynamic>{
        'mode': mode,
        'status': status,
        'trial_active': status == 'active',
        'trial_expired': status == 'expired',
        'first_launch_at': '2026-01-01T00:00:00Z',
        'expires_at': expiresAt,
        'observed_at': '2026-01-05T00:00:00Z',
        'remaining_seconds': remaining,
        'trial_days': 14,
      },
    };

void main() {
  late HttpServer server;
  late String baseUrl;
  Map<String, dynamic>? nextBody;
  var systemInfoHits = 0;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    nextBody = null;
    systemInfoHits = 0;
    server.listen((request) async {
      if (request.uri.path.endsWith('/system/info')) {
        systemInfoHits++;
      }
      final body = request.uri.path.endsWith('/system/info')
          ? nextBody
          : <String, dynamic>{'items': <dynamic>[], 'total': 0};
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body ?? <String, dynamic>{}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  ProviderContainer buildContainer() {
    final client = ApiClient(baseUrl: baseUrl);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    // The same one-shot registration SupermarketPosApp performs.
    container.read(licenseIngestorProvider);
    return container;
  }

  LicenseInfo? licenseOf(ProviderContainer container) =>
      container.read(licenseStatusProvider);

  test('an active trial snapshot is ingested from /system/info', () async {
    nextBody = _licenseBody(
      mode: 'trial',
      status: 'active',
      remaining: 864000,
      expiresAt: '2026-01-15T00:00:00Z',
    );
    final container = buildContainer();
    expect(licenseOf(container), isNull,
        reason: 'nothing is known before the first response');

    final client = container.read(apiClientProvider);
    await client.dio.get('/api/v1/system/info');

    final license = licenseOf(container);
    expect(license, isNotNull);
    expect(license!.status, LicenseStatus.active);
    expect(license.mode, LicenseMode.trial);
    expect(license.trialDays, 14);
    expect(license.remainingSeconds, 864000);
    expect(systemInfoHits, 1);
  });

  test('a later expired snapshot replaces the previous one', () async {
    nextBody = _licenseBody(mode: 'trial', status: 'active', remaining: 100);
    final container = buildContainer();
    final client = container.read(apiClientProvider);

    await client.dio.get('/api/v1/system/info');
    expect(licenseOf(container)!.status, LicenseStatus.active);

    nextBody = _licenseBody(mode: 'trial_expired', status: 'expired');
    await client.dio.get('/api/v1/system/info');

    final license = licenseOf(container)!;
    expect(license.status, LicenseStatus.expired);
    expect(license.mode, LicenseMode.trialExpired);
    expect(license.trialExpired, isTrue);
    expect(systemInfoHits, 2);
  });

  test('an old server without a license field yields unknown, not active',
      () async {
    nextBody = <String, dynamic>{
      'name': 'Old Server',
      'version': '0.0.9',
      'protocol': 1,
    };
    final container = buildContainer();
    await container.read(apiClientProvider).dio.get('/api/v1/system/info');

    final license = licenseOf(container);
    expect(license, isNotNull,
        reason: 'the response arrived — this is "unknown", not "no data"');
    expect(license!.status, LicenseStatus.unavailable);
    expect(license.mode, LicenseMode.unknown);
    expect(license.status, isNot(LicenseStatus.active));
  });

  test('a connection failure never touches the license state', () async {
    final container = buildContainer();
    // A port that was bound and immediately released: nothing listens.
    final throwaway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadUrl = 'http://127.0.0.1:${throwaway.port}';
    await throwaway.close(force: true);

    final client = container.read(apiClientProvider);
    client.setBaseUrl(deadUrl);
    await expectLater(
      client.dio.get('/api/v1/system/info'),
      throwsA(isA<DioException>()),
    );

    expect(licenseOf(container), isNull,
        reason: 'no response means no license snapshot');
  });

  test('non-system-info endpoints never feed the license state', () async {
    final container = buildContainer();
    await container
        .read(apiClientProvider)
        .dio
        .get('/api/v1/anything', data: <String, dynamic>{});

    expect(licenseOf(container), isNull);
    expect(systemInfoHits, 0);
  });

  test('the ingestor detaches its callback when disposed', () async {
    nextBody = _licenseBody(mode: 'trial', status: 'active', remaining: 10);
    final client = ApiClient(baseUrl: baseUrl);
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(client)],
    );
    container.read(licenseIngestorProvider);
    await client.dio.get('/api/v1/system/info');
    expect(container.read(licenseStatusProvider), isNotNull);

    container.dispose();
    // A second response after disposal must not throw (callback cleared).
    await client.dio.get('/api/v1/system/info');
  });
}
