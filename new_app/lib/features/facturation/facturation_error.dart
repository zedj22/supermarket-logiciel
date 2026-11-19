// Localized API-failure mapping for the Facturation feature (Phase 8).
//
// Same contract as the clients mapper: the primary message is ALWAYS
// localized for the active locale; the raw backend text
// (`error.message`) travels as the secondary `detail` line only.
// Structured envelope `error.code` first, HTTP status as fallback.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../clients/clients_error.dart';

/// Localized primary message + optional raw backend detail.
export '../clients/clients_error.dart' show PosApiError;

/// Maps a failure from a facturation request to a localized message.
PosApiError facturationApiError(
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
  final licenseKey = licenseErrorKey(code);
  if (licenseKey != null) {
    return PosApiError(AppStrings.t(licenseKey, loc), detail);
  }
  final String key;
  switch (code) {
    case 'INVOICE_CLIENT_ARCHIVED':
      key = 'invoice_client_archived_error';
      break;
    case 'NOT_FOUND':
      key = 'document_not_found';
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
    case 'COMPANY_MISSING':
      key = 'company_missing';
      break;
    case 'PRINT_RENDER_FAILED':
      key = 'export_failed';
      break;
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [facturationApiError] (inline error lines).
String facturationApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return facturationApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'document_not_found';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
