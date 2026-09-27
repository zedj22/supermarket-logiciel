// Phase 10 — pack localization: every new key exists in ar / fr / en and
// never falls back to the raw key (constants_test already enforces that
// the three maps carry identical key sets).
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _packKeys = <String>[
  'packs',
  'packs_subtitle',
  'add_pack',
  'edit_pack',
  'no_packs',
  'no_packs_found',
  'pack_name',
  'pack_detail_title',
  'components',
  'add_component',
  'select_pack_product',
  'sum_of_parts',
  'pack_requires_components',
  'pack_component_duplicate',
  'pack_created',
  'pack_updated',
  'pack_archived',
  'archive_pack_confirm',
  'max_packs',
  'pack_inactive',
  'pack_stock_insufficient',
  'pack_picker_title',
  'pack_picker_hint',
  'pack_not_saleable',
  'pack_badge',
  'enter_pack_quantity',
  'pack_shortage_detail',
  // Phase 10 fix round — informational profitability preview.
  'estimated_cost',
  'estimated_profit',
  'estimated_margin',
  'estimate_pmp_note',
];

void main() {
  group('Phase 10 pack strings', () {
    for (final locale in ['ar', 'fr', 'en']) {
      test('every pack key resolves to a real translation in $locale', () {
        for (final key in _packKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'empty translation for $key/$locale');
          expect(
            value,
            isNot(key),
            reason: 'missing translation for $key/$locale',
          );
        }
      });
    }

    test('ar pack strings are actually Arabic script', () {
      final arabic = RegExp(r'[؀-ۿ]');
      for (final key in _packKeys) {
        // Pack badges may legitimately stay a brand word in every locale.
        if (key == 'pack_badge') continue;
        expect(
          arabic.hasMatch(AppStrings.t(key, 'ar')),
          isTrue,
          reason: '$key must be translated in ar',
        );
      }
    });

    test('the shortage pattern keeps its three placeholders in all locales',
        () {
      for (final locale in ['ar', 'fr', 'en']) {
        final value = AppStrings.t('pack_shortage_detail', locale);
        expect(value, contains('{product}'));
        expect(value, contains('{required}'));
        expect(value, contains('{available}'));
      }
    });
  });
}
