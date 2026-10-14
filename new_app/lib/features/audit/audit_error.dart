// Localized API-failure mapping for the Audit Log feature (Slice B).
//
// Same contract as the expenses mapper (`expenses_error.dart`): the
// primary message is ALWAYS localized for the active locale, the raw
// backend text travels as the secondary `detail` line only, and the
// envelope `error.code` is checked FIRST. The audit surface is read-only,
// so the vocabulary is small: auth (401), permission (403), not-found
// (404) and the generic retryable failure.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from an audit request to a localized message.
PosApiError auditApiError(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  if (error is! DioException) {
    return PosApiError(AppStrings.t(fallbackKey, loc));
  }
  if (isConnectionError(error)) {
    return PosApiError(AppStrings.t('network_error_retry', loc));
  }
  final detail = backendErrorMessage(error);
  final code = _envelopeCode(error);
  final String key;
  switch (code) {
    case 'NOT_FOUND':
      key = 'audit_not_found';
      break;
    case 'VALIDATION_ERROR':
      key = 'validation_error';
      break;
    case 'FORBIDDEN':
    case 'AUTHORIZATION_ERROR':
      key = 'permission_denied';
      break;
    case 'UNAUTHORIZED':
    case 'AUTHENTICATION_ERROR':
      key = 'session_expired_login';
      break;
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [auditApiError] (inline error line).
String auditApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return auditApiError(error, loc, fallbackKey: fallbackKey).message;
}

String? _envelopeCode(DioException error) {
  final data = error.response?.data;
  if (data is Map) {
    final err = data['error'];
    if (err is Map) {
      final code = err['code'];
      if (code is String && code.isNotEmpty) return code;
    }
  }
  return null;
}

String? _statusKey(int? status) {
  switch (status) {
    case 401:
      return 'session_expired_login';
    case 403:
      return 'permission_denied';
    case 404:
      return 'audit_not_found';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
