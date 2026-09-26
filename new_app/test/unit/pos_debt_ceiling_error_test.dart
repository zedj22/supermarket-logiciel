// PHASE 9 BUG FIX — DEBT_CEILING_EXCEEDED localization contract.
//
// Contract under test: a 422 checkout failure with envelope code
// DEBT_CEILING_EXCEEDED is mapped by its envelope CODE first (never the
// generic `validation_error` status headline), the four amounts from
// `error.details` are folded into the localized message — the checkout
// error surface is the single `cart.lastError` string (payment dialog
// `payment-error` line + toast), so dropping them would leave the cashier
// unable to judge how far over the ceiling the sale is — and the raw
// English backend text only travels as the secondary `detail`.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/pos/pos_error_message.dart';
import 'package:supermarket_pos/network/api_client.dart';

const _locales = ['ar', 'fr', 'en'];

const _details = <String, String>{
  'customer_id': '11111111-1111-1111-1111-111111111111',
  'current_balance': '0.000',
  'new_debt': '600.000',
  'projected_balance': '600.000',
  'debt_ceiling': '500.000',
};

DioException _ceiling({Map<String, dynamic>? details, int status = 422}) {
  final path = '/api/v1/sales';
  return DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: {
        'error': {
          'code': 'DEBT_CEILING_EXCEEDED',
          'message_key': 'errors.businessRule',
          'message': 'Customer debt ceiling exceeded',
          'details': details ?? _details,
          'request_id': 'req-1',
        },
      },
    ),
  );
}

DioException _plain422() {
  final path = '/api/v1/sales';
  return DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 422,
      data: {
        'error': {
          'code': 'VALIDATION_ERROR',
          'message': 'Validation failed',
          'details': <String, dynamic>{},
          'request_id': 'req-2',
        },
      },
    ),
  );
}

void main() {
  group('DEBT_CEILING_EXCEEDED → localized headline + amounts', () {
    for (final loc in _locales) {
      test('$loc maps by envelope code, not by HTTP 422 status', () {
        final failure = posApiError(_ceiling(), loc);

        final headline = AppStrings.t('debt_ceiling_exceeded', loc);
        expect(failure.message, startsWith(headline));
        // The key itself must have resolved to a translation.
        expect(headline, isNot('debt_ceiling_exceeded'));
        // Must NOT collapse into the generic 422 headline.
        expect(
          failure.message,
          isNot(startsWith(AppStrings.t('validation_error', loc))),
        );
        expect(
          failure.message.toLowerCase(),
          isNot(contains('validation failed')),
        );
      });

      test('$loc folds all four amounts into the message', () {
        final failure = posApiError(_ceiling(), loc);
        final expectedNumbers = AppStrings.t('debt_ceiling_detail', loc)
            .replaceAll('{current}', '0.000')
            .replaceAll('{new_debt}', '600.000')
            .replaceAll('{ceiling}', '500.000')
            .replaceAll('{projected}', '600.000');

        expect(
          failure.message,
          '${AppStrings.t('debt_ceiling_exceeded', loc)}\n$expectedNumbers',
        );
        // No unresolved placeholders leak to the cashier.
        expect(failure.message, isNot(contains('{')));
        // Raw backend text stays in the secondary slot only.
        expect(failure.detail, 'Customer debt ceiling exceeded');
      });

      test('$loc missing details degrade to "?" placeholders', () {
        final failure = posApiError(
          _ceiling(details: <String, dynamic>{}),
          loc,
        );
        expect(
          failure.message,
          startsWith(AppStrings.t('debt_ceiling_exceeded', loc)),
        );
        expect(failure.message, contains('?'));
      });
    }

    test('posApiMessage returns headline + amounts (single string surface)',
        () {
      final message = posApiMessage(_ceiling(), 'ar');
      expect(message, startsWith(AppStrings.t('debt_ceiling_exceeded', 'ar')));
      expect(message, contains('600.000'));
      expect(message, contains('500.000'));
      // The multi-line message survives as ONE string (toast + dialog line).
      expect(message.split('\n'), hasLength(5)); // headline + 4 amount lines
    });

    test('ar / fr headlines are not the English text', () {
      final english = AppStrings.t('debt_ceiling_exceeded', 'en');
      for (final loc in ['ar', 'fr']) {
        expect(
          posApiError(_ceiling(), loc).message,
          isNot(startsWith(english)),
          reason: '$loc fell back to English',
        );
      }
    });

    test('a plain 422 (no ceiling code) still maps to validation_error', () {
      // Regression: the code-first branch must not hijack other 422s.
      for (final loc in _locales) {
        final failure = posApiError(_plain422(), loc);
        expect(failure.message, AppStrings.t('validation_error', loc));
        expect(failure.detail, 'Validation failed');
      }
    });

    test('a ceiling code on a non-422 status is still mapped by code', () {
      final failure = posApiError(_ceiling(status: 409), 'en');
      expect(
        failure.message,
        startsWith(AppStrings.t('debt_ceiling_exceeded', 'en')),
      );
      expect(failure.message, isNot(AppStrings.t('stock_conflict', 'en')));
    });

    test('backendErrorCode reads the envelope code', () {
      expect(backendErrorCode(_ceiling()), 'DEBT_CEILING_EXCEEDED');
      expect(backendErrorCode(_plain422()), 'VALIDATION_ERROR');
      expect(
        backendErrorCode(DioException.connectionError(
          requestOptions: RequestOptions(path: '/api/v1/sales'),
          reason: 'connection refused',
        )),
        isNull,
      );
    });

    test('every key used above exists and is translated in ar/fr/en', () {
      const keys = ['debt_ceiling_exceeded', 'debt_ceiling_detail'];
      for (final key in keys) {
        for (final loc in _locales) {
          final value = AppStrings.t(key, loc);
          expect(value, isNotEmpty, reason: 'missing: $key@$loc');
          expect(value, isNot(key), reason: 'untranslated: $key@$loc');
        }
      }
      // The detail template keeps its four substitution anchors.
      for (final loc in _locales) {
        final template = AppStrings.t('debt_ceiling_detail', loc);
        expect(template, contains('{current}'));
        expect(template, contains('{new_debt}'));
        expect(template, contains('{ceiling}'));
        expect(template, contains('{projected}'));
      }
    });
  });
}
