import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

/// Phase 5 (Products & Categories) localization coverage across ar/fr/en.
void main() {
  const phase5Keys = [
    'categories',
    'create_category',
    'edit_category',
    'archive_category_confirm',
    'category_created',
    'category_updated',
    'category_archived',
    'manage_categories',
    'add_product',
    'edit_product',
    'archive_product_confirm',
    'product_created',
    'product_updated',
    'product_archived',
    'cost',
    'unit',
    'description',
    'expiry_date',
    'image_path',
    'low_stock_threshold',
    'sku',
    'all',
    'archived',
    'no_category',
    'prev',
    'next',
    'products_subtitle',
    'status',
    'sort',
    'refresh',
    'actions',
    'page_size',
    'no_products',
    'no_products_hint',
    'in_stock',
    'sort_name',
    'sort_price',
    'sort_quantity',
    'sort_newest',
  ];

  group('Phase 5 strings', () {
    for (final locale in ['ar', 'fr', 'en']) {
      test('every Phase 5 key exists and is non-empty in "$locale"', () {
        for (final key in phase5Keys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });
    }

    test('Arabic and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in phase5Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(phase5Keys.length ~/ 2));
    });

    test('French and English translations differ (actually localized)', () {
      var translated = 0;
      for (final key in phase5Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(phase5Keys.length ~/ 2));
    });

    test('unknown locale falls back to the key itself', () {
      expect(AppStrings.t('add_product', 'de'), 'add_product');
    });
  });

  group('Phase 6 unit labels (unitLabel)', () {
    const unitCodes = [
      'kg',
      'gram',
      'liter',
      'milliliter',
      'meter',
      'pack',
      'piece',
      'box',
    ];

    for (final locale in ['ar', 'fr', 'en']) {
      test('unitLabel returns non-empty label for every code in "$locale"', () {
        for (final code in unitCodes) {
          final label = AppStrings.unitLabel(code, locale);
          expect(label, isNotEmpty, reason: 'empty unitLabel: $code@$locale');
        }
      });
    }

    test('unitLabel is translated (differs from raw code) for ar', () {
      // fr/en intentionally map some codes to themselves (kg → kg).
      for (final code in unitCodes) {
        final label = AppStrings.unitLabel(code, 'ar');
        expect(
          label,
          isNot(code),
          reason: 'unitLabel fell back to raw code for $code@ar',
        );
      }
    });

    test('unitLabel translates non-identity codes for fr', () {
      const frIdentityOk = {'kg'};
      for (final code in unitCodes) {
        if (frIdentityOk.contains(code)) continue;
        final label = AppStrings.unitLabel(code, 'fr');
        expect(
          label,
          isNot(code),
          reason: 'unitLabel fell back to raw code for $code@fr',
        );
      }
    });

    test('unitLabel falls back to code when code is null or unknown', () {
      expect(AppStrings.unitLabel(null, 'en'), '');
      expect(AppStrings.unitLabel(null, 'ar'), '');
      expect(AppStrings.unitLabel('weird', 'en'), 'weird');
      expect(AppStrings.unitLabel('weird', 'fr'), 'weird');
      expect(AppStrings.unitLabel('weird', 'ar'), 'weird');
    });

    test('Arabic and English unit labels differ', () {
      var differs = 0;
      for (final code in unitCodes) {
        if (AppStrings.unitLabel(code, 'ar') !=
            AppStrings.unitLabel(code, 'en')) {
          differs++;
        }
      }
      expect(differs, greaterThan(unitCodes.length ~/ 2));
    });
  });

  group('Phase 6 archive snackbar strings', () {
    const archiveKeys = [
      'variant_archived',
      'selling_unit_archived',
      'purchase_unit_archived',
      'archived_purchase_unit',
      'unit_type',
    ];

    for (final locale in ['ar', 'fr', 'en']) {
      test('every archive/unit key exists in "$locale"', () {
        for (final key in archiveKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing: $key@$locale');
          expect(value, isNot(key), reason: 'untranslated: $key@$locale');
        }
      });
    }
  });
}
