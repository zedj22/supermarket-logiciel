// Localized API-failure mapping for the Purchases feature (Phase 11).
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

/// Maps a failure from a purchases request to a localized message.
PosApiError purchasesApiError(
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
    case 'PURCHASE_ALREADY_RECEIVED':
      key = 'purchase_already_received';
      break;
    case 'PURCHASE_ALREADY_CANCELLED':
      key = 'purchase_already_cancelled';
      break;
    case 'INVALID_PURCHASE_STATE':
      key = 'invalid_purchase_state';
      break;
    case 'PURCHASE_LINE_INVALID':
      key = 'purchase_line_invalid';
      break;
    case 'DATABASE_CONSTRAINT':
      // A database integrity failure (NOT NULL / FK / CHECK ...) is a
      // server-side data problem — never a stock/quantity conflict, so
      // it must not render the stock-conflict copy. The raw backend
      // text travels in the detail line for support.
      key = 'database_constraint';
      break;
    case 'CONFLICT':
      // Cancel reversal conflicts (stock / sealed packages) surface
      // with the existing stock-conflict copy; detail carries the
      // backend explanation.
      key = 'stock_conflict';
      break;
    case 'NOT_FOUND':
      key = 'purchase_not_found';
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

/// Localized-only view of [purchasesApiError] (inline error lines).
String purchasesApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return purchasesApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'purchase_not_found';
    case 422:
      return 'validation_error';
    case 409:
      return 'invalid_purchase_state';
    default:
      return null;
  }
}
