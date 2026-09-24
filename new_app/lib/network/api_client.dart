import 'package:dio/dio.dart';
import '../core/constants.dart';

typedef OnUnauthorized = void Function();

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

/// Decides whether a 401 should be treated as session expiry.
///
/// Returns true only when ALL of these hold:
/// - the response status is 401
/// - the client currently holds a token (app is authenticated)
/// - the failing request is NOT a public authentication endpoint
///
/// This prevents session-expiry redirects on the login/setup flow, where
/// no token exists yet and public endpoints are still loading.
bool shouldHandleSessionExpiry(
  DioException err, {
  required bool hasToken,
}) {
  if (err.response?.statusCode != 401) return false;
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

class ApiClient {
  late final Dio _dio;
  OnUnauthorized? _onUnauthorized;

  ApiClient({String? baseUrl, Dio? dio}) {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: baseUrl ?? 'http://localhost:8000',
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

  /// True when an Authorization Bearer token is currently attached.
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

  void _handleUnauthorized() {
    clearToken();
    _onUnauthorized?.call();
  }
}

class _AuthInterceptor extends Interceptor {
  final ApiClient _client;

  _AuthInterceptor(this._client);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
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