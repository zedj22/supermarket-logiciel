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
}
