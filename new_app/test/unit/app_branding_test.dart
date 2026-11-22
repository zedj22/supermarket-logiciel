// Product name — one generic brand for every kind of shop.
//
// The software is sold to groceries, pharmacies, hardware stores and
// corner shops, so the wordmark may not name a supermarket. These tests
// pin the three translations and prove the old supermarket wording is
// gone from the name in every locale (the localized wordmark is
// `app_name`; the `MaterialApp` title uses `AppConstants.appName`).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/constants.dart';
import 'package:supermarket_pos/core/strings.dart';

const _expected = <String, String>{
  'ar': 'نظام تسيير المحلات',
  'fr': 'Système de gestion des commerces',
  'en': 'Store Management System',
};

/// Words that name a supermarket — none of them may survive in the brand.
const _supermarketWording = <String>[
  'سوبرماركت',
  'سوبر ماركت',
  'Supermarché',
  'supermarché',
  'Supermarket',
  'supermarket',
];

void main() {
  group('app_name', () {
    test('is the generic store-management name in all three locales', () {
      for (final entry in _expected.entries) {
        expect(
          AppStrings.t('app_name', entry.key),
          entry.value,
          reason: 'wrong wordmark for ${entry.key}',
        );
      }
    });

    test('never names a supermarket in any locale', () {
      for (final locale in _expected.keys) {
        final name = AppStrings.t('app_name', locale);
        for (final word in _supermarketWording) {
          expect(
            name.contains(word),
            isFalse,
            reason: '$locale wordmark still says "$word": $name',
          );
        }
      }
    });

    test('the three locales are genuinely different translations', () {
      expect(_expected.values.toSet(), hasLength(3));
      expect(AppStrings.t('app_name', 'ar'), isNot(_expected['en']));
    });

    test('Arabic is Arabic script and the Latin locales are Latin', () {
      final ar = AppStrings.t('app_name', 'ar');
      final arabicScript = RegExp(r'[\u0600-\u06FF]');
      expect(arabicScript.hasMatch(ar), isTrue);
      // Arabic contains no Latin letters, so a fallback can never look right.
      expect(RegExp(r'[A-Za-z]').hasMatch(ar), isFalse);

      for (final locale in ['fr', 'en']) {
        final name = AppStrings.t('app_name', locale);
        expect(RegExp(r'[A-Za-z]').hasMatch(name), isTrue, reason: locale);
        expect(arabicScript.hasMatch(name), isFalse, reason: locale);
      }
    });
  });

  group('the Flutter-level app title', () {
    test('matches the English wordmark', () {
      expect(AppConstants.appName, _expected['en']);
      expect(AppConstants.appName, AppStrings.t('app_name', 'en'));
    });

    test('carries no supermarket wording', () {
      for (final word in _supermarketWording) {
        expect(AppConstants.appName.contains(word), isFalse);
      }
    });
  });

  group('the key is still resolvable everywhere', () {
    test('never falls back to the raw key', () {
      for (final locale in _expected.keys) {
        expect(AppStrings.t('app_name', locale), isNot('app_name'));
      }
    });

  });
}
