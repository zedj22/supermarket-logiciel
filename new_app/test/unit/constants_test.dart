import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/constants.dart';
import 'package:supermarket_pos/core/strings.dart';

void main() {
  group('AppConstants', () {
    test('app name is set', () {
      expect(AppConstants.appName, isNotEmpty);
    });

    test('app version is set', () {
      expect(AppConstants.appVersion, isNotEmpty);
    });

    test('maxPinLength is positive', () {
      expect(AppConstants.maxPinLength, greaterThan(0));
    });

    test('minPinLength matches backend rule of 4 digits', () {
      expect(AppConstants.minPinLength, 4);
      expect(AppConstants.minPinLength, lessThan(AppConstants.maxPinLength));
    });

    test('defaultPageSize is positive', () {
      expect(AppConstants.defaultPageSize, greaterThan(0));
    });

    test('apiTimeout is positive', () {
      expect(AppConstants.apiTimeout.inSeconds, greaterThan(0));
    });
  });

  group('AppStrings', () {
    test('translations exist for all 3 locales', () {
      expect(AppStrings.translations, contains('ar'));
      expect(AppStrings.translations, contains('fr'));
      expect(AppStrings.translations, contains('en'));
    });

    test('translate returns value for known key', () {
      final result = AppStrings.translate('app_name', 'ar');
      expect(result, isNotEmpty);
      expect(result, isNot('app_name')); // should not return the key itself
    });

    test('translate returns key for unknown key', () {
      final result = AppStrings.translate('nonexistent_key_xyz', 'ar');
      expect(result, 'nonexistent_key_xyz');
    });

    test('all locales have same keys', () {
      final arKeys = AppStrings.translations['ar']!.keys.toSet();
      final frKeys = AppStrings.translations['fr']!.keys.toSet();
      final enKeys = AppStrings.translations['en']!.keys.toSet();
      expect(arKeys, frKeys);
      expect(arKeys, enKeys);
    });
  });
}
