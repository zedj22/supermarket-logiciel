// Phase L1-C — licensing error codes → localized messages.
//
// Contract: the eight guard codes (Phase L1-B / License Manager) always
// surface as their own localized sentence, in every locale, ahead of the
// HTTP status fallbacks. A licensing rejection is NOT a connection
// failure (`isConnectionError` is false — the response arrived) and NOT
// a permission/stock problem, so `permission_denied`, `network_error_retry`
// and `api_error_retry` must never win.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/clients/clients_error.dart';
import 'package:supermarket_pos/features/purchases/purchases_error.dart';
import 'package:supermarket_pos/features/pos/pos_error_message.dart';
import 'package:supermarket_pos/features/returns/return_error_message.dart';
import 'package:supermarket_pos/network/api_client.dart';

const _locales = ['ar', 'fr', 'en'];

/// The eight licensing codes and their localization keys (L1-B contract).
const _licenseCodes = <String, String>{
  'license_required': 'license_error_required',
  'trial_expired': 'license_error_expired',
  'trial_upload_forbidden': 'license_error_upload_forbidden',
  'trial_restore_forbidden': 'license_error_restore_forbidden',
  'license_invalid': 'license_error_invalid',
  'license_invalid_key': 'license_error_invalid_key',
  'license_bound_elsewhere': 'license_error_bound_elsewhere',
  'license_status_unavailable': 'license_error_status_unavailable',
};

DioException _envelope(int status, String code, {String? message}) {
  const path = '/api/v1/products';
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
      requestOptions: RequestOptions(path: '/api/v1/products'),
      reason: 'connection refused',
    );

void main() {
  group('code → localization key', () {
    test('exactly the eight L1-B codes are recognized', () {
      expect(licenseErrorLocalizationKeys, _licenseCodes);
      for (final code in _licenseCodes.keys) {
        expect(isLicenseErrorCode(code), isTrue, reason: code);
      }
      expect(isLicenseErrorCode(null), isFalse);
      expect(isLicenseErrorCode(''), isFalse);
      expect(isLicenseErrorCode('FORBIDDEN'), isFalse);
      expect(isLicenseErrorCode('device_revoked'), isFalse);
      expect(isLicenseErrorCode('backup_tools_missing'), isFalse);
    });

    test('licenseErrorKey returns the right key or null', () {
      for (final entry in _licenseCodes.entries) {
        expect(licenseErrorKey(entry.key), entry.value);
      }
      expect(licenseErrorKey('VALIDATION_ERROR'), isNull);
      expect(licenseErrorKey(null), isNull);
    });

    test('licenseErrorKeyFrom reads the envelope code of a DioException', () {
      for (final entry in _licenseCodes.entries) {
        expect(
          licenseErrorKeyFrom(_envelope(403, entry.key)),
          entry.value,
        );
      }
      expect(licenseErrorKeyFrom(_envelope(403, 'FORBIDDEN')), isNull);
      expect(licenseErrorKeyFrom(_network()), isNull);
    });
  });

  group('localized headline in ar / fr / en', () {
    for (final loc in _locales) {
      for (final entry in _licenseCodes.entries) {
        test('$loc ${entry.key} → ${entry.value}', () {
          final error = clientsApiError(_envelope(403, entry.key), loc);
          expect(error.message, AppStrings.t(entry.value, loc));
          expect(error.message, isNot(entry.value),
              reason: 'the raw key must never be shown');
          expect(error.message, isNot('backend text for ${entry.key}'),
              reason: 'raw English backend text is never the headline');
          expect(error.detail, 'backend text for ${entry.key}');
          expect(error.message, isNotEmpty);
        });
      }
    }
  });

  group('licensing rejections are not connection failures', () {
    test('a license error is never isConnectionError', () {
      for (final code in _licenseCodes.keys) {
        expect(
          isConnectionError(_envelope(403, code)),
          isFalse,
          reason: 'the HTTP response arrived: $code',
        );
        expect(
          isConnectionError(_envelope(503, code)),
          isFalse,
          reason: 'HTTP error status is still not a connection failure: $code',
        );
      }
      expect(isConnectionError(_network()), isTrue);
    });

    test('a license envelope never maps to network_error_retry', () {
      for (final loc in _locales) {
        for (final code in _licenseCodes.keys) {
          final error = clientsApiError(_envelope(403, code), loc);
          expect(
            error.message,
            isNot(AppStrings.t('network_error_retry', loc)),
            reason: '$code must not read as a connectivity problem',
          );
        }
      }
    });
  });

  group('status-code fallbacks never override a license code', () {
    test('a 403 license code is not permission_denied', () {
      for (final loc in _locales) {
        final error = clientsApiError(_envelope(403, 'trial_expired'), loc);
        expect(error.message, AppStrings.t('license_error_expired', loc));
        expect(error.message, isNot(AppStrings.t('permission_denied', loc)));
      }
    });

    test('a 503 license_status_unavailable is not the generic 5xx retry', () {
      for (final loc in _locales) {
        final error = posApiError(
          _envelope(503, 'license_status_unavailable'),
          loc,
        );
        expect(
          error.message,
          AppStrings.t('license_error_status_unavailable', loc),
        );
        expect(error.message, isNot(AppStrings.t('api_error_retry', loc)));
        expect(error.message, isNot(AppStrings.t('stock_conflict', loc)));
      }
    });

    test('posApiError maps trial_expired at its canonical 403', () {
      final failure = posApiError(_envelope(403, 'trial_expired'), 'en');
      expect(failure.message, AppStrings.t('license_error_expired', 'en'));
      expect(failure.detail, 'backend text for trial_expired');
    });

    test('posApiMessage returns the localized license headline only', () {
      final message = posApiMessage(
        _envelope(403, 'license_required'),
        'ar',
      );
      expect(message, AppStrings.t('license_error_required', 'ar'));
      expect(message, isNot(contains('backend text')));
    });
  });

  group('representative feature mappers honor license codes', () {
    test('clientsApiError', () {
      final error = clientsApiError(
        _envelope(403, 'license_bound_elsewhere'),
        'fr',
      );
      expect(error.message, AppStrings.t('license_error_bound_elsewhere', 'fr'));
      expect(error.message, isNot(AppStrings.t('permission_denied', 'fr')));
    });

    test('purchasesApiError', () {
      final error = purchasesApiError(
        _envelope(403, 'trial_upload_forbidden'),
        'en',
      );
      expect(
        error.message,
        AppStrings.t('license_error_upload_forbidden', 'en'),
      );
      expect(error.message, isNot(AppStrings.t('permission_denied', 'en')));
    });

    test('returnsApiError', () {
      final error = returnsApiError(
        _envelope(403, 'trial_restore_forbidden'),
        'ar',
      );
      expect(
        error.message,
        AppStrings.t('license_error_restore_forbidden', 'ar'),
      );
      expect(error.message, isNot(AppStrings.t('permission_denied', 'ar')));
    });
  });

  group('ordinary errors are untouched by the license mapping', () {
    test('a plain 403 FORBIDDEN still reads as permission_denied', () {
      final error = clientsApiError(_envelope(403, 'FORBIDDEN'), 'en');
      expect(error.message, AppStrings.t('permission_denied', 'en'));
    });

    test('a connection failure still reads as network_error_retry', () {
      final error = clientsApiError(_network(), 'en');
      expect(error.message, AppStrings.t('network_error_retry', 'en'));
    });

    test('a non-license 500 keeps the feature fallback', () {
      final error = posApiError(_envelope(500, 'INTERNAL_ERROR'), 'en');
      expect(error.message, isNot(AppStrings.t('license_error_required', 'en')));
      expect(error.message, isNotEmpty);
    });
  });
}
