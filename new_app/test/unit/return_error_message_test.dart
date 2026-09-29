// Phase 12 — returns/voids error mapping.
//
// Contract (mirrors the POS and customers mappers): the primary message
// is ALWAYS localized for the active locale; the raw backend text
// (`error.message`) travels ONLY as the secondary `detail`. The
// structured envelope `error.code` is checked first, so a Phase 12
// business code is never swallowed by a generic HTTP status.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/returns/return_error_message.dart';

const _locales = ['ar', 'fr', 'en'];

DioException _envelope(int status, String code, {String? message}) {
  const path = '/api/v1/returns';
  return DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: {
        'error': {
          'code': code,
          'message': message ?? 'backend text for $code',
          'details': <String, dynamic>{},
        },
      },
    ),
  );
}

DioException _status(int status) => DioException(
      requestOptions: RequestOptions(path: '/api/v1/returns'),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/v1/returns'),
        statusCode: status,
        data: {
          'error': {
            'code': 'HTTP_$status',
            'message': 'backend status text',
            'details': <String, dynamic>{},
          },
        },
      ),
    );

DioException _network() => DioException.connectionError(
      requestOptions: RequestOptions(path: '/api/v1/returns'),
      reason: 'connection refused',
    );

void main() {
  group('envelope code → localized headline (ar / fr / en)', () {
    const codeKeys = <String, String>{
      'SALE_ALREADY_VOID': 'error_sale_already_void',
      'SALE_NOT_VOIDABLE': 'error_sale_not_voidable',
      'SALE_HAS_RETURNS': 'error_sale_has_returns',
      'RETURN_EXCEEDS_SOLD': 'error_return_exceeds_sold',
      'RETURN_EXCEEDS_REMAINING_CREDIT': 'error_return_exceeds_sold',
      'RETURN_PACK_NOT_WHOLE': 'error_return_pack_not_whole',
      'RETURN_LINE_INVALID': 'error_return_line_invalid',
      'IDEMPOTENCY_CONFLICT': 'error_idempotency_conflict',
      'CONFLICT': 'return_conflict',
      'VALIDATION_ERROR': 'validation_error',
      'FORBIDDEN': 'permission_denied',
      'AUTHORIZATION_ERROR': 'permission_denied',
      'UNAUTHORIZED': 'session_expired_login',
      'AUTHENTICATION_ERROR': 'session_expired_login',
    };

    for (final loc in _locales) {
      for (final entry in codeKeys.entries) {
        test('$loc ${entry.key} → ${entry.value}', () {
          final error = returnsApiError(_envelope(409, entry.key), loc);
          expect(error.message, AppStrings.t(entry.value, loc));
          expect(error.message, isNot(entry.value));
          // Raw English backend text is never the headline.
          expect(error.message, isNot('backend text for ${entry.key}'));
          expect(error.detail, 'backend text for ${entry.key}');
        });
      }

      test('$loc connection failure → network_error_retry, no detail', () {
        final error = returnsApiError(_network(), loc);
        expect(error.message, AppStrings.t('network_error_retry', loc));
        expect(error.message, isNot('network_error_retry'));
        expect(error.detail, isNull);
      });

      test('$loc unexpected non-Dio error → fallback, no detail', () {
        final error = returnsApiError(
          StateError('boom'),
          loc,
          fallbackKey: 'api_error_retry',
        );
        expect(error.message, AppStrings.t('api_error_retry', loc));
        expect(error.detail, isNull);
      });

      test('$loc 409 with an unknown code never says "stock conflict"', () {
        final error = returnsApiError(_envelope(409, 'SOME_OTHER'), loc);
        expect(error.message, isNot(AppStrings.t('stock_conflict', loc)));
        expect(error.message.toLowerCase(), isNot(contains('stock')));
      });

      test('$loc 404 without a known code → return_not_found', () {
        final error = returnsApiError(_status(404), loc);
        expect(error.message, AppStrings.t('return_not_found', loc));
        expect(error.message, isNot('return_not_found'));
      });

      test('$loc 403 without a known code → permission_denied', () {
        final error = returnsApiError(_status(403), loc);
        expect(error.message, AppStrings.t('permission_denied', loc));
      });

      test('$loc 500 → generic api_error_retry with backend detail', () {
        final error = returnsApiError(_status(500), loc);
        expect(error.message, AppStrings.t('api_error_retry', loc));
        expect(error.detail, 'backend status text');
      });
    }
  });

  group('localization sanity', () {
    test('Phase 12 error headlines differ across locales', () {
      const code = 'SALE_ALREADY_VOID';
      final ar = returnsApiError(_envelope(409, code), 'ar').message;
      final en = returnsApiError(_envelope(409, code), 'en').message;
      expect(ar, isNot(en));
    });

    test('returnsApiMessage matches returnsApiError().message', () {
      final error = returnsApiError(_envelope(409, 'SALE_HAS_RETURNS'), 'en');
      expect(
        returnsApiMessage(_envelope(409, 'SALE_HAS_RETURNS'), 'en'),
        error.message,
      );
    });
  });
}
