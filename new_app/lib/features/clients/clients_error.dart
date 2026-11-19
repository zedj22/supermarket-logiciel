// Localized API-failure mapping for the Customers / Debts feature.
//
// Same contract as the POS mapper (pos_error_message.dart): the primary
// message is ALWAYS localized for the active locale; the raw backend
// text (`error.message`) travels as the secondary `detail` line only.
// The POS-specific 409 → "stock conflict" mapping must not leak into
// customer operations, so this feature maps the structured envelope
// `error.code` first and falls back to HTTP status afterwards.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from a customers/debts request to a localized message.
PosApiError clientsApiError(
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
    case 'PAYMENT_EXCEEDS_BALANCE':
      key = 'debt_payment_exceeds';
      break;
    case 'PAYMENT_AMOUNT_INVALID':
      key = 'invalid_amount';
      break;
    case 'CUSTOMER_ARCHIVED':
      key = 'customer_is_archived';
      break;
    case 'OUTSTANDING_DEBT':
      key = 'customer_outstanding_debt';
      break;
    case 'NOT_FOUND':
      key = 'customer_not_found';
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

/// Localized-only view of [clientsApiError] (inline dialog error line).
String clientsApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return clientsApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'customer_not_found';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
