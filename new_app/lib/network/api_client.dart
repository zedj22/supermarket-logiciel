import 'package:dio/dio.dart';
import '../core/constants.dart';

typedef OnUnauthorized = void Function();

/// Reports a device-guard rejection (`device_required`,
/// `device_not_paired`, `device_revoked`) to the connection layer.
/// The JWT is deliberately left untouched — the two identities are
/// independent layers (§9.3).
typedef OnDeviceError = void Function(String code);

/// Public authentication endpoints that never require a JWT.
///
/// A 401 on any of these paths is an ordinary API error (e.g. bad PIN) and
/// must NEVER trigger "session expired" handling.
const Set<String> publicAuthPaths = <String>{
  '/api/v1/auth/setup/check',
  '/api/v1/auth/setup',
  '/api/v1/auth/login',
  '/api/v1/auth/login-users',
  '/api/v1/auth/verify-token',
  '/api/v1/auth/logout',
  '/api/v1/auth/logout-token',
};

/// The Phase 16 machine-identity headers (§12.5).
///
/// Both are attached globally once the device has been paired; the server's
/// router-level guard reads them before the JWT is even considered.
const String deviceIdHeader = 'X-Device-ID';
const String deviceTokenHeader = 'X-Device-Token';

/// Codes the server's device guard raises when the machine identity is
/// missing (`device_required`, HTTP **401**), unknown / not approved /
/// bad credential (`device_not_paired`, HTTP **403**) or revoked
/// (`device_revoked`, HTTP **403**).
///
/// A guard rejection is NOT a session expiry — at any status: the user
/// session is perfectly valid, the *device link* is broken and must be
/// surfaced by the connection UI (`device_revoked` / `device_not_paired`
/// branch, §23.2).
const Set<String> deviceGuardErrorCodes = <String>{
  'device_required',
  'device_not_paired',
  'device_revoked',
};

/// True for [code] when it is one of the device-guard codes.
bool isDeviceGuardErrorCode(String? code) =>
    code != null && deviceGuardErrorCodes.contains(code);

/// Decides whether a 401 should be treated as session expiry.
///
/// Returns true only when ALL of these hold:
/// - the response status is 401
/// - the error is not a device-guard error (device link ≠ user session)
/// - the client currently holds a token (app is authenticated)
/// - the failing request is NOT a public authentication endpoint
///
/// This prevents session-expiry redirects on the login/setup flow, where
/// no token exists yet and public endpoints are still loading, and on the
/// LAN pairing/revocation flow, where logging the user out would hide the
/// real problem behind a login screen.
bool shouldHandleSessionExpiry(
  DioException err, {
  required bool hasToken,
}) {
  if (err.response?.statusCode != 401) return false;
  if (isDeviceGuardErrorCode(backendErrorCode(err))) return false;
  if (!hasToken) return false;
  if (publicAuthPaths.contains(err.requestOptions.path)) return false;
  return true;
}

/// True when the exception represents a connection failure (no HTTP response
/// received) rather than an HTTP error response from the server.
bool isConnectionError(DioException e) => e.response == null;

/// Extracts the backend-provided message from an error response body.
///
/// Supports:
/// - Standard envelope: `{"error": {"message": "..."}}`
/// - Top-level `message`
/// - String `detail` (legacy)
/// - FastAPI default `detail: [{loc, msg, type}, ...]` list (Pydantic 422)
///
/// Returns null when there is no response or no usable message field.
String? backendErrorMessage(DioException e) {
  if (e.response == null) return null;
  final data = e.response?.data;
  if (data is Map) {
    final error = data['error'];
    if (error is Map) {
      final msg = error['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
    final msg = data['message'];
    if (msg is String && msg.isNotEmpty) return msg;
    final detail = data['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List && detail.isNotEmpty) {
      final parts = <String>[];
      for (final item in detail) {
        if (item is Map) {
          final m = item['msg'];
          if (m is String && m.isNotEmpty) {
            final loc = item['loc'];
            if (loc is List && loc.length > 1) {
              final field = loc.skip(1).join('.');
              parts.add(field.isNotEmpty ? '$field: $m' : m);
            } else {
              parts.add(m);
            }
          }
        } else if (item is String && item.isNotEmpty) {
          parts.add(item);
        }
      }
      if (parts.isNotEmpty) return parts.join('; ');
    }
  }
  return null;
}

/// Extracts the structured envelope `error.code` from an error response.
///
/// Supports the standard envelope `{"error": {"code": "..."}}`. The code
/// is mapped FIRST (before the HTTP status) so business rules keep their
/// identity across the UI — e.g. `DEBT_CEILING_EXCEEDED` (422) must not
/// collapse into the generic `validation_error` headline.
///
/// Returns null when there is no response or no usable code field.
String? backendErrorCode(DioException e) {
  final data = e.response?.data;
  if (data is Map) {
    final error = data['error'];
    if (error is Map) {
      final code = error['code'];
      if (code is String && code.isNotEmpty) return code;
    }
  }
  return null;
}

class ApiClient {
  late final Dio _dio;
  OnUnauthorized? _onUnauthorized;
  OnDeviceError? _onDeviceError;

  ApiClient({String? baseUrl, Dio? dio}) {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: baseUrl ?? AppConstants.defaultServerBaseUrl,
            connectTimeout: AppConstants.apiTimeout,
            receiveTimeout: AppConstants.apiTimeout,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
          ),
        );

    _dio.interceptors.add(_AuthInterceptor(this));
    _dio.interceptors.add(LogInterceptor(
      requestBody: true,
      responseBody: true,
      error: true,
      logPrint: (obj) {},
    ));
  }

  Dio get dio => _dio;

  /// The server this client currently talks to.
  String get baseUrl => _dio.options.baseUrl;

  /// Point the client at a different server (post-pair switch, or a
  /// reconnect that found the store's LAN address has changed).
  ///
  /// Blank/whitespace input is ignored so a failed lookup can never wipe a
  /// working URL.
  void setBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    _dio.options.baseUrl = trimmed;
  }

  /// Attach or detach the Phase 16 machine-identity headers (§12.5).
  ///
  /// Both headers must be present together — passing a null/empty value
  /// removes that header. The token itself is never logged or persisted in
  /// plain SharedPreferences; it lives in `flutter_secure_storage`.
  void setDeviceIdentity({
    required String? deviceId,
    required String? deviceToken,
  }) {
    _setHeader(deviceIdHeader, deviceId);
    _setHeader(deviceTokenHeader, deviceToken);
  }

  /// True when both device-guard headers are currently attached.
  bool get hasDeviceIdentity =>
      _dio.options.headers.containsKey(deviceIdHeader) &&
      _dio.options.headers.containsKey(deviceTokenHeader);

  /// True when an `Authorization` Bearer token is currently attached.
  bool get hasToken => _dio.options.headers.containsKey('Authorization');

  void setToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearToken() {
    _dio.options.headers.remove('Authorization');
  }

  void setOnUnauthorized(OnUnauthorized callback) {
    _onUnauthorized = callback;
  }

  /// Registers the device-link failure callback (device ≠ session).
  void setOnDeviceError(OnDeviceError callback) {
    _onDeviceError = callback;
  }

  void _setHeader(String name, String? value) {
    if (value == null || value.isEmpty) {
      _dio.options.headers.remove(name);
    } else {
      _dio.options.headers[name] = value;
    }
  }

  void _handleUnauthorized() {
    clearToken();
    _onUnauthorized?.call();
  }

  void _handleDeviceError(String code) {
    _onDeviceError?.call(code);
  }
}

class _AuthInterceptor extends Interceptor {
  final ApiClient _client;

  _AuthInterceptor(this._client);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final code = backendErrorCode(err);
    if (isDeviceGuardErrorCode(code)) {
      // The device link is broken, not the user session. Keep the JWT, hand
      // the code to the connection layer, and let the caller render the
      // dedicated revoked / not-paired UI.
      _client._handleDeviceError(code!);
      handler.next(err);
      return;
    }
    if (shouldHandleSessionExpiry(err, hasToken: _client.hasToken)) {
      _client._handleUnauthorized();
      handler.reject(DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        type: DioExceptionType.badResponse,
        error: 'Unauthorized',
      ));
      return;
    }
    handler.next(err);
  }
}