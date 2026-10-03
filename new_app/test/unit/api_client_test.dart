import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/constants.dart';
import 'package:supermarket_pos/network/api_client.dart';

void main() {
  group('ApiClient', () {
    test('can be instantiated with default baseUrl', () {
      final client = ApiClient();
      expect(client.dio, isNotNull);
      expect(client.dio.options.baseUrl, contains('localhost'));
    });

    test('can be instantiated with custom baseUrl', () {
      final client = ApiClient(baseUrl: 'http://example.com');
      expect(client.dio.options.baseUrl, 'http://example.com');
    });

    test('setToken adds Authorization header', () {
      final client = ApiClient();
      expect(client.hasToken, false);
      client.setToken('test-token');
      expect(client.dio.options.headers['Authorization'], 'Bearer test-token');
      expect(client.hasToken, true);
    });

    test('clearToken removes Authorization header', () {
      final client = ApiClient();
      client.setToken('test-token');
      client.clearToken();
      expect(client.dio.options.headers.containsKey('Authorization'), false);
      expect(client.hasToken, false);
    });
  });

  group('shouldHandleSessionExpiry', () {
    DioException errorWithStatus(int statusCode, String path) {
      return DioException(
        requestOptions: RequestOptions(path: path),
        response: Response(
          requestOptions: RequestOptions(path: path),
          statusCode: statusCode,
        ),
      );
    }

    test('returns false for non-401 responses', () {
      final err = errorWithStatus(500, '/api/v1/users');
      expect(shouldHandleSessionExpiry(err, hasToken: true), false);
    });

    test('returns false when the app is unauthenticated (no token)', () {
      final err = errorWithStatus(401, '/api/v1/users');
      expect(shouldHandleSessionExpiry(err, hasToken: false), false);
    });

    test('returns false for public auth endpoints even with a token', () {
      for (final path in publicAuthPaths) {
        final err = errorWithStatus(401, path);
        expect(
          shouldHandleSessionExpiry(err, hasToken: true),
          false,
          reason: 'public path should not expire: $path',
        );
      }
    });

    test('returns true for protected endpoint when authenticated', () {
      final err = errorWithStatus(401, '/api/v1/users');
      expect(shouldHandleSessionExpiry(err, hasToken: true), true);
    });
  });

  group('isConnectionError', () {
    test('true when no HTTP response was received', () {
      final err = DioException(requestOptions: RequestOptions(path: '/x'));
      expect(isConnectionError(err), true);
    });

    test('false when an HTTP response exists even for error status', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 401,
        ),
      );
      expect(isConnectionError(err), false);
    });
  });

  group('backendErrorMessage', () {
    test('returns null when there is no response', () {
      final err = DioException(requestOptions: RequestOptions(path: '/x'));
      expect(backendErrorMessage(err), isNull);
    });

    test('extracts message from {"error": {"message": ...}} envelope', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/api/v1/auth/login'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/login'),
          statusCode: 401,
          data: {
            'error': {
              'code': 'AUTHENTICATION_ERROR',
              'message': 'Invalid credentials',
            }
          },
        ),
      );
      expect(backendErrorMessage(err), 'Invalid credentials');
    });

    test('falls back to top-level message field', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 422,
          data: {'message': 'Validation failed'},
        ),
      );
      expect(backendErrorMessage(err), 'Validation failed');
    });

    test('returns null when message fields are empty', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
          data: {'error': {'code': 'INTERNAL_ERROR', 'message': ''}},
        ),
      );
      expect(backendErrorMessage(err), isNull);
    });

    test('joins FastAPI detail list into a readable message', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/api/v1/inventory/adjust'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/inventory/adjust'),
          statusCode: 422,
          data: {
            'detail': [
              {
                'loc': ['body', 'reason'],
                'msg': 'reason is required for decrease and set',
                'type': 'value_error',
              },
            ],
          },
        ),
      );
      expect(
        backendErrorMessage(err),
        'reason: reason is required for decrease and set',
      );
    });

    test('joins multiple detail-list field errors with semicolons', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 422,
          data: {
            'detail': [
              {
                'loc': ['body', 'quantity'],
                'msg': 'greater than 0',
                'type': 'value_error',
              },
              {
                'loc': ['body', 'reason'],
                'msg': 'required',
                'type': 'value_error',
              },
            ],
          },
        ),
      );
      expect(
        backendErrorMessage(err),
        'quantity: greater than 0; reason: required',
      );
    });

    test('prefers structured error envelope over detail list', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 422,
          data: {
            'error': {
              'code': 'VALIDATION_ERROR',
              'message': 'reason is required',
            },
            'detail': [
              {'loc': ['body'], 'msg': 'fallback'},
            ],
          },
        ),
      );
      expect(backendErrorMessage(err), 'reason is required');
    });
  });

  group('AuthInterceptor 401 behavior', () {
    test('401 on protected endpoint expires session when authenticated', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((request) {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"error":{"code":"UNAUTHORIZED","message":"Missing authentication token"}}',
        );
        request.response.close();
      });

      final client = ApiClient(baseUrl: 'http://127.0.0.1:$port');
      var unauthorizedCount = 0;
      client.setOnUnauthorized(() => unauthorizedCount++);
      client.setToken('existing-session-token');

      await expectLater(
        client.dio.get('/api/v1/users'),
        throwsA(isA<DioException>()),
      );

      expect(unauthorizedCount, 1);
      expect(client.hasToken, false);
      await server.close(force: true);
    });

    test('401 on public auth endpoint does NOT expire session (no token)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((request) {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"error":{"code":"AUTHENTICATION_ERROR","message":"Invalid credentials"}}',
        );
        request.response.close();
      });

      final client = ApiClient(baseUrl: 'http://127.0.0.1:$port');
      var unauthorizedCount = 0;
      client.setOnUnauthorized(() => unauthorizedCount++);

      await expectLater(
        client.dio.get('/api/v1/auth/login-users'),
        throwsA(isA<DioException>()),
      );

      expect(unauthorizedCount, 0);
      await server.close(force: true);
    });

    test('401 on public auth endpoint does NOT expire session even with stale token',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((request) {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"error":{"code":"AUTHENTICATION_ERROR","message":"Invalid PIN"}}',
        );
        request.response.close();
      });

      final client = ApiClient(baseUrl: 'http://127.0.0.1:$port');
      var unauthorizedCount = 0;
      client.setOnUnauthorized(() => unauthorizedCount++);
      client.setToken('stale-token');

      await expectLater(
        client.dio.get('/api/v1/auth/login'),
        throwsA(isA<DioException>()),
      );

      expect(unauthorizedCount, 0);
      expect(client.hasToken, true);
      await server.close(force: true);
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 16 (§12.5 / §23.2) — dynamic base URL + machine identity headers
  // ---------------------------------------------------------------------------

  group('Phase 16 device identity', () {
    test('defaults to the single-PC base URL', () {
      expect(ApiClient().dio.options.baseUrl, AppConstants.defaultServerBaseUrl);
      expect(AppConstants.defaultServerBaseUrl, contains('localhost'));
    });

    test('setBaseUrl switches the target and ignores blank input', () {
      final client = ApiClient();
      client.setBaseUrl('  http://192.168.1.10:8000  ');
      expect(client.baseUrl, 'http://192.168.1.10:8000');
      expect(client.dio.options.baseUrl, 'http://192.168.1.10:8000');

      client.setBaseUrl('');
      expect(client.baseUrl, 'http://192.168.1.10:8000',
          reason: 'a failed lookup must never wipe a working URL');
      client.setBaseUrl('   ');
      expect(client.baseUrl, 'http://192.168.1.10:8000');
    });

    test('setDeviceIdentity attaches both guard headers together', () {
      final client = ApiClient();
      expect(client.hasDeviceIdentity, isFalse);

      client.setDeviceIdentity(
        deviceId: 'pos-1-2',
        deviceToken: 'tok',
      );
      expect(client.dio.options.headers[deviceIdHeader], 'pos-1-2');
      expect(client.dio.options.headers[deviceTokenHeader], 'tok');
      expect(client.hasDeviceIdentity, isTrue);
    });

    test('a null/empty value removes that header', () {
      final client = ApiClient();
      client.setDeviceIdentity(deviceId: 'pos-1-2', deviceToken: 'tok');
      client.setDeviceIdentity(deviceId: null, deviceToken: 'tok');
      expect(client.dio.options.headers.containsKey(deviceIdHeader), isFalse);
      expect(client.hasDeviceIdentity, isFalse);

      client.setDeviceIdentity(deviceId: 'pos-1-2', deviceToken: '');
      expect(client.dio.options.headers.containsKey(deviceTokenHeader),
          isFalse);
      expect(client.hasDeviceIdentity, isFalse);
    });
  });

  group('shouldHandleSessionExpiry device-code exclusion', () {
    DioException errWithCode(int status, String code) {
      final path = '/api/v1/products';
      return DioException(
        requestOptions: RequestOptions(path: path),
        response: Response(
          requestOptions: RequestOptions(path: path),
          statusCode: status,
          data: {
            'error': {'code': code, 'message': 'x'}
          },
        ),
      );
    }

    test('isDeviceGuardErrorCode recognises exactly the three guard codes', () {
      expect(deviceGuardErrorCodes, {'device_required',
        'device_not_paired', 'device_revoked'});
      expect(isDeviceGuardErrorCode('device_required'), isTrue);
      expect(isDeviceGuardErrorCode('device_not_paired'), isTrue);
      expect(isDeviceGuardErrorCode('device_revoked'), isTrue);
      expect(isDeviceGuardErrorCode('PAIRING_CODE_INVALID'), isFalse);
      expect(isDeviceGuardErrorCode(null), isFalse);
      expect(isDeviceGuardErrorCode(''), isFalse);
    });

    test('a device rejection is NOT a session expiry at its canonical status',
        () {
      // Step A §12 contract: device_required → 401; device_not_paired and
      // device_revoked → 403. Whatever the status, the device link must be
      // kept separate from the user session.
      const canonical = <String, int>{
        'device_required': 401,
        'device_not_paired': 403,
        'device_revoked': 403,
      };
      canonical.forEach((code, status) {
        expect(
          shouldHandleSessionExpiry(errWithCode(status, code), hasToken: true),
          isFalse,
          reason: 'device code must not expire the session: $code@$status',
        );
        expect(
          shouldHandleSessionExpiry(errWithCode(401, code), hasToken: true),
          isFalse,
          reason: 'device code must not expire the session at any status: '
              '$code',
        );
      });
    });

    test('an ordinary 401 still expires the session', () {
      expect(
        shouldHandleSessionExpiry(
            errWithCode(401, 'AUTHENTICATION_ERROR'),
            hasToken: true),
        isTrue,
      );
    });

    test(
        'the interceptor routes a device rejection (403 device_revoked) away '
        'from the session handler', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((request) {
        // Step A §12: a revoked device is 403 FORBIDDEN, not 401.
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"error":{"code":"device_revoked","message":"revoked"}}',
        );
        request.response.close();
      });

      final client = ApiClient(baseUrl: 'http://127.0.0.1:$port');
      var unauthorizedCount = 0;
      final deviceErrors = <String>[];
      client.setOnUnauthorized(() => unauthorizedCount++);
      client.setOnDeviceError(deviceErrors.add);
      client.setToken('valid-user-session');
      client.setDeviceIdentity(deviceId: 'pos-1-2', deviceToken: 'stale');

      await expectLater(
        client.dio.get('/api/v1/products'),
        throwsA(isA<DioException>()),
      );

      expect(deviceErrors, ['device_revoked']);
      expect(unauthorizedCount, 0,
          reason: 'the user session must survive a device rejection');
      expect(client.hasToken, isTrue,
          reason: 'the JWT is a separate layer from the device link');
      await server.close(force: true);
    });
  });
}