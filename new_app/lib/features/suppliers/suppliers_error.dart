// Localized API-failure mapping for the Suppliers feature (Phase 11).
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

/// Maps a failure from a suppliers request to a localized message.
PosApiError suppliersApiError(
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
    case 'SUPPLIER_ARCHIVED':
      key = 'supplier_is_archived';
      break;
    case 'OUTSTANDING_SUPPLIER_BALANCE':
      key = 'outstanding_supplier_balance';
      break;
    case 'SUPPLIER_PAYMENT_EXCEEDS_BALANCE':
      key = 'supplier_payment_exceeds';
      break;
    case 'SUPPLIER_PAYMENT_AMOUNT_INVALID':
      key = 'invalid_amount';
      break;
    case 'NOT_FOUND':
      key = 'supplier_not_found';
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

/// Localized-only view of [suppliersApiError] (inline error lines).
String suppliersApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return suppliersApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'supplier_not_found';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
