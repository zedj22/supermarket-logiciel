// Localized API-failure mapping for the Returns / Voids feature
// (Phase 12).
//
// Same contract as the POS mapper (pos_error_message.dart): the primary
// message is ALWAYS localized for the active locale; the raw backend text
// (`error.message`) travels as the secondary `detail` line only. The
// envelope `error.code` is checked FIRST because Phase 12 defines the
// business codes the cashier must read in their own language.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from a returns/voids request to a localized message.
PosApiError returnsApiError(
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
    case 'SALE_ALREADY_VOID':
      key = 'error_sale_already_void';
      break;
    case 'SALE_NOT_VOIDABLE':
      key = 'error_sale_not_voidable';
      break;
    case 'SALE_HAS_RETURNS':
      key = 'error_sale_has_returns';
      break;
    case 'RETURN_EXCEEDS_SOLD':
    case 'RETURN_EXCEEDS_REMAINING_CREDIT':
      key = 'error_return_exceeds_sold';
      break;
    case 'RETURN_PACK_NOT_WHOLE':
      key = 'error_return_pack_not_whole';
      break;
    case 'RETURN_LINE_INVALID':
      key = 'error_return_line_invalid';
      break;
    case 'IDEMPOTENCY_CONFLICT':
      key = 'error_idempotency_conflict';
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
    case 'CONFLICT':
      key = 'return_conflict';
      break;
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [returnsApiError] (inline dialog error line).
String returnsApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return returnsApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'return_not_found';
    case 409:
      return 'return_conflict';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
