// Localized API-failure messages for the POS (UX FIX #12 — FIX #5).
//
// Audit rule: every POS toast must show a message the cashier can read in
// their own language. Backend text (`error.message`, validation `details`)
// is English and is therefore never the primary line — it is passed as the
// toast's `detail` (secondary line) so it still reaches support/dev.
//
//   message : always localized (`AppStrings.t`) for the active locale
//   detail  : raw backend text, optional, secondary only
import 'package:dio/dio.dart';

import '../../core/strings.dart';
import '../../network/api_client.dart';

/// Localized primary message + optional raw backend detail.
class PosApiError {
  const PosApiError(this.message, [this.detail]);

  /// Always localized for the requested locale.
  final String message;

  /// Raw backend text (English) — secondary line only, never the headline.
  final String? detail;
}

/// Maps any failure thrown by the POS API to a localized message.
///
/// [fallbackKey] is the localized generic key used for unmapped statuses
/// (`api_error_retry` by default).
PosApiError posApiError(
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

  // Business rules are mapped by their envelope code FIRST so they keep
  // their identity regardless of HTTP status.
  final errorCode = backendErrorCode(error);
  if (errorCode == 'DEBT_CEILING_EXCEEDED') {
    return PosApiError(_debtCeilingMessage(error, loc), detail);
  }

  final code = error.response?.statusCode;
  final String key;
  if (code == 401) {
    key = 'session_expired_login';
  } else if (code == 403) {
    key = _permissionKey(error);
  } else if (code == 409) {
    key = 'stock_conflict';
  } else if (code == 422) {
    key = 'validation_error';
  } else {
    // 404 / 5xx / unknown — one clear, localized retry message.
    key = fallbackKey;
  }
  return PosApiError(AppStrings.t(key, loc), detail);
}

/// DEBT_CEILING_EXCEEDED → localized headline + localized amounts block.
///
/// The checkout error surface is ONE string (`cart.lastError`: the payment
/// dialog's `payment-error` line and the toast), so the four amounts from
/// the envelope `details` are folded into the message as a second line —
/// dropping them would leave the cashier unable to judge how far over the
/// ceiling the sale is. Backend totals are already localized-formatted
/// decimal strings ("600.000"), so only the labels need translation.
String _debtCeilingMessage(DioException error, String loc) {
  final headline = AppStrings.t('debt_ceiling_exceeded', loc);
  final details = _envelopeDetails(error);
  final numbers = AppStrings.t('debt_ceiling_detail', loc)
      .replaceAll('{current}', '${details['current_balance'] ?? '?'}')
      .replaceAll('{new_debt}', '${details['new_debt'] ?? '?'}')
      .replaceAll('{ceiling}', '${details['debt_ceiling'] ?? '?'}')
      .replaceAll('{projected}', '${details['projected_balance'] ?? '?'}');
  return '$headline\n$numbers';
}

/// `error.details` map from the standard error envelope (empty if absent).
Map<String, dynamic> _envelopeDetails(DioException error) {
  final data = error.response?.data;
  if (data is Map) {
    final err = data['error'];
    if (err is Map) {
      final details = err['details'];
      if (details is Map) return details.cast<String, dynamic>();
    }
  }
  return const <String, dynamic>{};
}

/// Localized-only view of [posApiError] (toast headline, dialog error line).
String posApiMessage(
  Object error,
  String loc, {
  String fallbackKey = 'api_error_retry',
}) {
  return posApiError(error, loc, fallbackKey: fallbackKey).message;
}

/// 403 → the specific permission the cashier lacks (discount / credit)
/// when the backend says so, otherwise the generic denial.
String _permissionKey(DioException error) {
  final data = error.response?.data;
  final err = data is Map ? data['error'] : null;
  final details = err is Map ? '${err['details'] ?? ''}' : '';
  final code = err is Map ? '${err['code'] ?? ''}' : '';
  if (details.contains('discount') || code.contains('DISCOUNT')) {
    return 'permission_discount';
  }
  if (details.contains('credit') || code.contains('CREDIT')) {
    return 'permission_credit';
  }
  return 'permission_denied';
}
