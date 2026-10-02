// Localized API-failure mapping for the Reports feature (Phase 14).
//
// Same contract as the expenses mapper (`expenses_error.dart`): the
// primary message is ALWAYS localized for the active locale, the raw
// backend text (`error.message`) travels as the secondary `detail` line
// only, and the envelope `error.code` is checked FIRST because Phase 14
// defines the business codes the report screens must read in their
// language (`REPORT_INVALID_RANGE` / `REPORT_RANGE_TOO_WIDE` /
// `REPORT_SORT_INVALID`, §11).
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';
import '../pos/pos_error_message.dart';

/// Localized primary message + optional raw backend detail.
export '../pos/pos_error_message.dart' show PosApiError;

/// Maps a failure from a report request to a localized message.
PosApiError reportsApiError(
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
    case 'REPORT_INVALID_RANGE':
      key = 'report_invalid_range';
      break;
    case 'REPORT_RANGE_TOO_WIDE':
      key = 'report_range_too_wide';
      break;
    case 'REPORT_SORT_INVALID':
      key = 'report_sort_invalid';
      break;
    // Phase 15 export/print envelope codes (§16.1) — mapped by code so a
    // 500 `EXPORT_RENDER_FAILED` never degrades into the generic retry.
    case 'EXPORT_FORMAT_UNSUPPORTED':
      key = 'export_format_unsupported';
      break;
    case 'EXPORT_ROW_LIMIT':
      key = 'export_row_limit';
      break;
    case 'EXPORT_TOO_LARGE':
      key = 'export_too_large';
      break;
    case 'EXPORT_RENDER_FAILED':
      key = 'export_render_failed';
      break;
    case 'PRINT_RENDER_FAILED':
      key = 'print_render_failed';
      break;
    case 'MISSING_FONT':
      key = 'missing_font';
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
    default:
      key = _statusKey(error.response?.statusCode) ?? fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// Localized-only view of [reportsApiError] (inline tab error line).
String reportsApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return reportsApiError(error, loc, fallbackKey: fallbackKey).message;
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
