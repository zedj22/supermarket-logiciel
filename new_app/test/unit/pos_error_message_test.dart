// Phase 8 FIX #5 — POS error-toast localization (mapping layer).
//
// Contract under test: `posApiError` turns ANY failure into a headline the
// cashier can read in their own language (ar / fr / en), while the raw
// backend text is carried ONLY as the secondary `detail`. The toast widget
// (`showPosToast`) is untouched by this test — it renders `message` first
// and `detail` second.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_error_message.dart';

const _locales = ['ar', 'fr', 'en'];

/// Status → AppStrings key used by every POS error toast.
const _statusKeys = <int, String>{
  401: 'session_expired_login',
  403: 'permission_denied',
  409: 'stock_conflict',
  422: 'validation_error',
  500: 'api_error_retry',
};

DioException _http(int status, {Object? data}) {
  final path = '/api/v1/pos/probe';
  return DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data ??
          {
            'error': {'code': 'E$status', 'message': 'backend said $status'},
          },
    ),
  );
}

DioException _network() => DioException.connectionError(
      requestOptions: RequestOptions(path: '/api/v1/pos/probe'),
      reason: 'connection refused',
    );

void main() {
  group('status → localized headline (ar / fr / en)', () {
    for (final loc in _locales) {
      for (final entry in _statusKeys.entries) {
        test('$loc HTTP ${entry.key} → ${entry.value}', () {
          final failure = posApiError(_http(entry.key), loc);

          final headline = AppStrings.t(entry.value, loc);
          expect(failure.message, headline);
          // The key itself must have resolved to a translation.
          expect(failure.message, isNot(entry.value));
          // The raw English backend text is never the headline …
          expect(failure.message, isNot('backend said ${entry.key}'));
          expect(failure.message.toLowerCase(),
              isNot(contains('backend said')));
          // … it only travels as the secondary detail.
          expect(failure.detail, 'backend said ${entry.key}');
        });
      }

      test('$loc connection failure → network_error_retry, no detail', () {
        final failure = posApiError(_network(), loc);
        expect(failure.message, AppStrings.t('network_error_retry', loc));
        expect(failure.message, isNot('network_error_retry'));
        expect(failure.detail, isNull);
      });

      test('$loc unexpected non-Dio error → api_error_retry, no detail', () {
        final failure = posApiError(StateError('boom'), loc);
        expect(failure.message, AppStrings.t('api_error_retry', loc));
        expect(failure.message, isNot('api_error_retry'));
        expect(failure.detail, isNull);
      });
    }

    test('ar / fr headlines are not the English text', () {
      for (final loc in ['ar', 'fr']) {
        for (final status in _statusKeys.keys) {
          final failure = posApiError(_http(status), loc);
          expect(
            failure.message,
            isNot(AppStrings.t(_statusKeys[status]!, 'en')),
            reason: '$loc/$status fell back to English',
          );
        }
        expect(posApiError(_network(), loc).message,
            isNot(AppStrings.t('network_error_retry', 'en')));
      }
    });
  });

  group('403 refinements', () {
    test('discount scope → permission_discount', () {
      final failure = posApiError(
        _http(403, data: {
          'error': {
            'code': 'PERMISSION_DENIED',
            'details': 'missing discount scope',
            'message': 'Discount permission required',
          },
        }),
        'en',
      );
      expect(failure.message, AppStrings.t('permission_discount', 'en'));
      expect(failure.detail, 'Discount permission required');
    });

    test('credit scope → permission_credit', () {
      final failure = posApiError(
        _http(403, data: {
          'error': {
            'code': 'CREDIT_NOT_ALLOWED',
            'message': 'Credit sales are disabled',
          },
        }),
        'ar',
      );
      expect(failure.message, AppStrings.t('permission_credit', 'ar'));
      expect(failure.detail, 'Credit sales are disabled');
    });

    test('otherwise → permission_denied', () {
      final failure = posApiError(_http(403), 'fr');
      expect(failure.message, AppStrings.t('permission_denied', 'fr'));
    });
  });

  group('DATABASE_CONSTRAINT envelope code (a 409 that is NOT stock)', () {
    // Regression: a database integrity failure arrives as HTTP 409 and
    // must never render the stock-conflict copy — the envelope code
    // decides before the status fallback.
    for (final loc in _locales) {
      test('$loc 409 + DATABASE_CONSTRAINT → database_constraint', () {
        final failure = posApiError(
          _http(409, data: {
            'error': {
              'code': 'DATABASE_CONSTRAINT',
              'message': 'A database constraint was violated',
            },
          }),
          loc,
        );
        expect(failure.message, AppStrings.t('database_constraint', loc));
        expect(failure.message, isNot('database_constraint'));
        expect(failure.message, isNot(AppStrings.t('stock_conflict', loc)));
        expect(failure.detail, 'A database constraint was violated');
      });
    }

    test('409 with code CONFLICT still renders the stock copy', () {
      final failure = posApiError(
        _http(409, data: {
          'error': {
            'code': 'CONFLICT',
            'message': 'Purchase cancellation would make stock negative',
          },
        }),
        'en',
      );
      expect(failure.message, AppStrings.t('stock_conflict', 'en'));
    });
  });

  group('headline vs detail contract', () {
    test('posApiMessage returns the localized headline only', () {
      expect(
        posApiMessage(_http(409), 'ar'),
        AppStrings.t('stock_conflict', 'ar'),
      );
      expect(posApiMessage(_http(409), 'ar'), isNot(contains('backend')));
    });

    test('a 422 FastAPI detail list stays in the detail slot', () {
      final failure = posApiError(
        _http(422, data: {
          'detail': [
            {
              'loc': ['body', 'quantity'],
              'msg': 'greater than 0',
            },
          ],
        }),
        'fr',
      );
      expect(failure.message, AppStrings.t('validation_error', 'fr'));
      expect(failure.detail, 'quantity: greater than 0');
    });

    test('fallbackKey lets callers pick another localized headline', () {
      final failure = posApiError(
        _http(500),
        'en',
        fallbackKey: 'sale_failed',
      );
      expect(failure.message, AppStrings.t('sale_failed', 'en'));
      expect(failure.detail, 'backend said 500');
    });

    test('every key used above exists and is translated in ar/fr/en', () {
      const keys = [
        'session_expired_login',
        'permission_denied',
        'permission_discount',
        'permission_credit',
        'stock_conflict',
        'database_constraint',
        'validation_error',
        'api_error_retry',
        'network_error_retry',
        'sale_failed',
      ];
      for (final key in keys) {
        for (final loc in _locales) {
          final value = AppStrings.t(key, loc);
          expect(value, isNotEmpty, reason: 'missing: $key@$loc');
          expect(value, isNot(key), reason: 'untranslated: $key@$loc');
        }
      }
    });
  });
}
