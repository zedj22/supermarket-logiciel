// Purchase-save error mapping regression (stock conflict mislabel).
//
// Production failure: saving a purchase invoice (sport, qty 10 @ 1500)
// hit a database NOT NULL constraint on the server; the backend's
// generic integrity mapping returned 409, and the purchases mapper
// rendered it with the stock-conflict copy ("Stock conflict — review
// quantities") — a message about stock on a screen about a database
// defect. Contract pinned here:
//
//   DATABASE_CONSTRAINT (any status) → `database_constraint`, detail
//       carries the raw backend text, NEVER the stock copy;
//   CONFLICT (cancel reversal / sealed packages / over-return) still
//       → `stock_conflict` — genuine stock/quantity conflicts keep
//       their message;
//   409 with no envelope code keeps the pre-existing status fallback.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/purchases/purchases_error.dart';

const _locales = ['ar', 'fr', 'en'];

DioException _envelope(int status, String code, {String? message}) {
  const path = '/api/v1/purchases';
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

void main() {
  group('database constraint failure is not a stock conflict', () {
    for (final loc in _locales) {
      test('$loc DATABASE_CONSTRAINT → database_constraint + raw detail',
          () {
        final error = purchasesApiError(
          _envelope(
            409,
            'DATABASE_CONSTRAINT',
            message: 'A database constraint was violated',
          ),
          loc,
        );
        expect(error.message, AppStrings.t('database_constraint', loc));
        expect(error.message, isNot('database_constraint'));
        // The production mislabel must never come back.
        expect(error.message, isNot(AppStrings.t('stock_conflict', loc)));
        // Raw backend text stays on the secondary line for support.
        expect(error.detail, 'A database constraint was violated');
      });
    }

    test('DATABASE_CONSTRAINT is localized, not identical across locales',
        () {
      final ar = purchasesApiError(_envelope(409, 'DATABASE_CONSTRAINT'), 'ar');
      final en = purchasesApiError(_envelope(409, 'DATABASE_CONSTRAINT'), 'en');
      final fr = purchasesApiError(_envelope(409, 'DATABASE_CONSTRAINT'), 'fr');
      expect(ar.message, isNot(en.message));
      expect(fr.message, isNot(en.message));
    });
  });

  group('genuine stock / quantity conflicts keep the stock copy', () {
    for (final loc in _locales) {
      test('$loc CONFLICT → stock_conflict (cancel reversal conflicts)',
          () {
        final error = purchasesApiError(
          _envelope(
            409,
            'CONFLICT',
            message: 'Purchase cancellation would make stock negative',
          ),
          loc,
        );
        expect(error.message, AppStrings.t('stock_conflict', loc));
        expect(
          error.detail,
          'Purchase cancellation would make stock negative',
        );
      });
    }
  });

  group('status fallback (no envelope code)', () {
    test('409 without a code → invalid_purchase_state, not stock copy', () {
      final error = purchasesApiError(_envelope(409, ''), 'en');
      expect(error.message, AppStrings.t('invalid_purchase_state', 'en'));
      expect(error.message, isNot(AppStrings.t('stock_conflict', 'en')));
    });

    test('422 → validation_error', () {
      final error = purchasesApiError(_envelope(422, ''), 'en');
      expect(error.message, AppStrings.t('validation_error', 'en'));
    });

    test('500 → fallback api_error_retry', () {
      final error = purchasesApiError(_envelope(500, ''), 'en');
      expect(error.message, AppStrings.t('api_error_retry', 'en'));
    });
  });

  group('purchasesApiMessage', () {
    test('returns the localized headline only', () {
      final message = purchasesApiMessage(
        _envelope(409, 'DATABASE_CONSTRAINT'),
        'fr',
      );
      expect(message, AppStrings.t('database_constraint', 'fr'));
      expect(message, isNot(contains('backend text')));
    });
  });
}
