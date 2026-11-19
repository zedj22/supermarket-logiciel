// Localized API-failure mapping for the Promotions feature (Phase 18).
//
// Same contract as the expenses mapper (`expenses_error.dart`): the
// primary message is ALWAYS localized for the active locale, the raw
// backend text (`error.message`) travels as the secondary `detail` line
// only, and the envelope `error.code` is checked FIRST because Phase 18
// defines the business codes the manager must read in their language.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from a promotions request to a localized message.
PosApiError promotionsApiError(
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
    case 'PROMOTION_NOT_FOUND':
      key = 'error_promotion_not_found';
      break;
    case 'PROMOTION_PRODUCT_CONFLICT':
      key = 'promotion_product_conflict';
      break;
    case 'INVALID_PROMOTION_VALUE':
      key = 'promotion_invalid_value';
      break;
    case 'MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED':
      key = 'promotion_multi_fixed';
      break;
    case 'UNKNOWN_PRODUCT':
      key = 'promotion_unknown_product';
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
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [promotionsApiError] (inline dialog error line).
String promotionsApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return promotionsApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'error_promotion_not_found';
    case 409:
      return 'promotion_save_failed';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
