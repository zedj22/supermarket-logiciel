// Localized API-failure mapping for the Zakat feature.
//
// Same contract as the reports mapper (`reports_error.dart`): the primary
// message is ALWAYS localized, the raw backend text travels as the
// secondary detail line only, and the envelope `error.code` is checked
// FIRST so the zakat business codes (`IDEMPOTENCY_CONFLICT`,
// `ZAKAT_CALCULATION_NOT_FOUND`) never degrade into the generic retry.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from a zakat request to a localized message.
PosApiError zakatApiError(
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
    case 'IDEMPOTENCY_CONFLICT':
      key = 'zakat_idempotency_conflict';
      break;
    case 'ZAKAT_CALCULATION_NOT_FOUND':
      key = 'zakat_calculation_not_found';
      break;
    case 'FORBIDDEN':
    case 'AUTHORIZATION_ERROR':
      key = 'permission_denied';
      break;
    case 'UNAUTHORIZED':
    case 'AUTHENTICATION_ERROR':
      key = 'session_expired_login';
      break;
    case 'VALIDATION_ERROR':
      key = 'validation_error';
      break;
    case 'MISSING_FONT':
      key = 'missing_font';
      break;
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [zakatApiError] (inline error lines/toasts).
String zakatApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return zakatApiError(error, loc, fallbackKey: fallbackKey).message;
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
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
