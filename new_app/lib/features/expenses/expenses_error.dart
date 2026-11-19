// Localized API-failure mapping for the Expenses feature (Phase 13).
//
// Same contract as the returns mapper (`return_error_message.dart`): the
// primary message is ALWAYS localized for the active locale, the raw
// backend text (`error.message`) travels as the secondary `detail` line
// only, and the envelope `error.code` is checked FIRST because Phase 13
// defines the business codes the cashier must read in their language.
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from an expenses request to a localized message.
PosApiError expensesApiError(
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
    case 'EXPENSE_NOT_FOUND':
      key = 'error_expense_not_found';
      break;
    case 'EXPENSE_ALREADY_CANCELLED':
      key = 'expense_already_cancelled';
      break;
    case 'IDEMPOTENCY_CONFLICT':
      key = 'error_idempotency_conflict';
      break;
    case 'CONFLICT':
      key = 'expense_save_failed';
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

/// Localized-only view of [expensesApiError] (inline dialog error line).
String expensesApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return expensesApiError(error, loc, fallbackKey: fallbackKey).message;
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
      return 'error_expense_not_found';
    case 409:
      return 'expense_save_failed';
    case 422:
      return 'validation_error';
    default:
      return null;
  }
}
