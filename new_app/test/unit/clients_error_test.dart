// Phase 9 — customer/debt error mapping.
//
// Contract (mirrors the POS mapper, Phase 8 FIX #5): the primary
// message is ALWAYS localized for the active locale; the raw backend
// text travels ONLY as the secondary `detail`. Unlike the POS mapper,
// customer operations map the structured envelope `error.code` first —
// a 409 from archiving a customer must NEVER surface as "stock
// conflict".
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/clients/clients_error.dart';

const _locales = ['ar', 'fr', 'en'];

DioException _envelope(int status, String code, {String? message}) {
  const path = '/api/v1/customers';
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

DioException _network() => DioException.connectionError(
      requestOptions: RequestOptions(path: '/api/v1/customers'),
      reason: 'connection refused',
    );

void main() {
  group('envelope code → localized headline (ar / fr / en)', () {
    const codeKeys = <String, String>{
      'PAYMENT_EXCEEDS_BALANCE': 'debt_payment_exceeds',
      'PAYMENT_AMOUNT_INVALID': 'invalid_amount',
      'CUSTOMER_ARCHIVED': 'customer_is_archived',
      'OUTSTANDING_DEBT': 'customer_outstanding_debt',
      'NOT_FOUND': 'customer_not_found',
      'VALIDATION_ERROR': 'validation_error',
      'FORBIDDEN': 'permission_denied',
      'AUTHORIZATION_ERROR': 'permission_denied',
      'UNAUTHORIZED': 'session_expired_login',
      'AUTHENTICATION_ERROR': 'session_expired_login',
    };

    for (final loc in _locales) {
      for (final entry in codeKeys.entries) {
        test('$loc ${entry.key} → ${entry.value}', () {
          final error = clientsApiError(
            _envelope(422, entry.key),
            loc,
          );
          expect(error.message, AppStrings.t(entry.value, loc));
          expect(error.message, isNot(entry.value));
          // Raw English backend text is never the headline.
          expect(error.message, isNot('backend text for ${entry.key}'));
          expect(error.detail, 'backend text for ${entry.key}');
        });
      }

      test('$loc connection failure → network_error_retry, no detail', () {
        final error = clientsApiError(_network(), loc);
        expect(error.message, AppStrings.t('network_error_retry', loc));
        expect(error.message, isNot('network_error_retry'));
        expect(error.detail, isNull);
      });

      test('$loc unexpected non-Dio error → fallback, no detail', () {
        final error = clientsApiError(
          StateError('boom'),
          loc,
          fallbackKey: 'api_error_retry',
        );
        expect(error.message, AppStrings.t('api_error_retry', loc));
        expect(error.detail, isNull);
      });

      test('$loc 409 without a known code never says "stock conflict"', () {
        final error = clientsApiError(_envelope(409, 'SOME_OTHER'), loc);
        expect(error.message, isNot(AppStrings.t('stock_conflict', loc)));
        expect(error.message.toLowerCase(), isNot(contains('stock')));
      });
    }
  });

  group('HTTP status fallback (no / unknown envelope code)', () {
    test('401 → session_expired_login', () {
      final error = clientsApiError(_envelope(401, ''), 'en');
      expect(error.message, AppStrings.t('session_expired_login', 'en'));
    });

    test('403 → permission_denied', () {
      final error = clientsApiError(_envelope(403, ''), 'en');
      expect(error.message, AppStrings.t('permission_denied', 'en'));
    });

    test('404 → customer_not_found', () {
      final error = clientsApiError(_envelope(404, ''), 'en');
      expect(error.message, AppStrings.t('customer_not_found', 'en'));
    });

    test('422 → validation_error', () {
      final error = clientsApiError(_envelope(422, ''), 'en');
      expect(error.message, AppStrings.t('validation_error', 'en'));
    });

    test('500 → custom fallback key', () {
      final error = clientsApiError(
        _envelope(500, ''),
        'en',
        fallbackKey: 'no_data',
      );
      expect(error.message, AppStrings.t('no_data', 'en'));
      expect(error.message, isNot('no_data'));
    });
  });

  group('clientsApiMessage', () {
    test('returns the localized headline only', () {
      final message = clientsApiMessage(
        _envelope(422, 'PAYMENT_EXCEEDS_BALANCE'),
        'fr',
      );
      expect(message, AppStrings.t('debt_payment_exceeds', 'fr'));
      expect(message, isNot(contains('backend text')));
    });
  });

  group('PosApiError re-export', () {
    test('clients_error exposes the same PosApiError type as POS', () {
      final error = clientsApiError(_network(), 'en');
      expect(error.message, isNotEmpty);
      expect(error.detail, isNull);
    });
  });
}
