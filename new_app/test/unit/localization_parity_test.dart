// Phase 17 (§17.3) — localization parity across ar/fr/en.
//
// `AppStrings.t` falls back to the **key** when a locale is missing a
// translation, so an untranslated string does not fail loudly: it prints
// `settings_load_failed` on the operator's screen in the middle of Arabic
// or French prose.  These tests turn that silent degradation into a hard
// failure and make the exact gap visible.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys whose value is *allowed* to equal the key: SI / unit symbols that
/// are genuinely written the same way in every locale (`kg` is `kg` in
/// English and French, `كغ` in Arabic).  Everything else matching would be
/// `AppStrings.t`'s raw-key fallback leaking onto the screen.
const _symbolKeys = {'kg'};

Map<String, String> _map(String locale) =>
    AppStrings.translations[locale] ?? const <String, String>{};

Set<String> _missing(String from, String to) =>
    _map(from).keys.toSet().difference(_map(to).keys.toSet());

void main() {
  group('localization parity (Phase 17 §17.3)', () {
    test('all three locale maps are present', () {
      for (final locale in _locales) {
        expect(_map(locale), isNotEmpty, reason: 'missing locale: $locale');
      }
    });

    test('every locale carries exactly the same key set', () {
      final gaps = <String>[];
      for (final from in _locales) {
        for (final to in _locales) {
          if (from == to) continue;
          final missing = _missing(from, to).toList()..sort();
          if (missing.isNotEmpty) {
            gaps.add('$from → $to (${missing.length}): $missing');
          }
        }
      }
      expect(
        gaps,
        isEmpty,
        reason: 'key sets differ between locales:\n${gaps.join('\n')}',
      );
    });

    test('no value is empty in any locale', () {
      final empty = <String>[];
      for (final locale in _locales) {
        _map(locale).forEach((key, value) {
          if (value.trim().isEmpty) empty.add('$key@$locale');
        });
      }
      expect(empty, isEmpty, reason: 'empty translations: $empty');
    });

    test('no value is a raw key (the t() fallback made visible)', () {
      final raw = <String>[];
      for (final locale in _locales) {
        _map(locale).forEach((key, value) {
          if (value == key && !_symbolKeys.contains(key)) {
            raw.add('$key@$locale');
          }
        });
      }
      expect(raw, isEmpty, reason: 'untranslated (value == key): $raw');
    });

    test('the three locales are actually translated, not copies', () {
      // A handful of keys are legitimately identical across locales
      // (`80mm`, `A4`, `OK`, brand/product codes…), so the bar is "most
      // differ", not "all differ".
      final identicalArEn = <String>[];
      final identicalFrEn = <String>[];
      final en = _map('en');
      en.forEach((key, value) {
        if (_map('ar')[key] == value) identicalArEn.add(key);
        if (_map('fr')[key] == value) identicalFrEn.add(key);
      });
      expect(
        identicalArEn.length,
        lessThan(en.length ~/ 4),
        reason: 'Arabic looks copied from English: $identicalArEn',
      );
      expect(
        identicalFrEn.length,
        lessThan(en.length ~/ 4),
        reason: 'French looks copied from English: $identicalFrEn',
      );
    });

    test('key count matches the Phase 17 baseline', () {
      // Measured at §17.3 (859); §17.6 added `ask_before_print_question`
      // (860); the product-quantity save added `product_and_stock_updated`,
      // `quantity_readonly` and `product_stock_reason` (863).  Update this
      // deliberately when a subphase adds strings — an unexplained drop
      // means keys were deleted from one map only.
      expect(_map('en').keys.length, 863);
      expect(_map('ar').keys.length, _map('en').keys.length);
      expect(_map('fr').keys.length, _map('en').keys.length);
    });
  });
}
