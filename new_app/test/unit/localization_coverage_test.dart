// Phase 17 (§17.3) — "All strings translated".
//
// Two failure modes this file turns into a hard failure instead of a
// silent English (or raw-key) string on an Arabic screen:
//
//  1. a user-visible literal written straight into a widget —
//     `Text('Sales')` renders in English for every locale;
//  2. `AppStrings.t('no_such_key', loc)` — `t()` falls back to the key
//     itself, so a typo prints `settings_load_faield` on screen.
//
// The scan is line-oriented over `lib/` and deliberately excludes
// `core/strings.dart` (the dictionary itself) and anything containing `$`
// (an interpolated value, which cannot be a static translation).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

final _literalPatterns = <RegExp>[
  RegExp(r"Text\(\s*'([^'$]+)'"),
  RegExp(
    r"(?:labelText|hintText|tooltip|semanticLabel|helperText|addSemanticsLabel)"
    r"\s*:\s*'([^'$]+)'",
  ),
];

/// A translation lookup with a literal key: `AppStrings.t('save', loc)`.
final _lookupPattern = RegExp(r"AppStrings\.(?:t|translate)\(\s*'([^']+)'");

/// Three or more consecutive Latin letters — what makes a literal read as
/// a word rather than a code (`80mm`, `A4`, `v2` are all fine).
final _wordPattern = RegExp(r'[A-Za-z]{3}');

/// Dynamic keys are built at runtime (`AppStrings.t('lan_status_$s', loc)`),
/// so no static scan can check them.  These are the families the app
/// builds and the values each backend enum can actually produce — a new
/// enum value with no key would print `lan_status_approvedd` on screen.
const _dynamicKeyFamilies = <String, Set<String>>{
  'purchase_status_': {'draft', 'received', 'cancelled'},
  'lan_status_': {'pending', 'approved', 'rejected', 'revoked'},
  'entry_type_': {'sale', 'payment', 'adjustment', 'sale_void', 'sale_refund'},
  'supplier_entry_type_': {'purchase', 'payment', 'purchase_cancel'},
  'loyalty_event_': {
    'sale_earn',
    'debt_settlement_earn',
    'redeem',
    'return_clawback',
    'void_clawback',
    'adjustment',
    'expiry',
  },
};

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !f.path.replaceAll('\\', '/').endsWith('core/strings.dart'));

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

void main() {
  group('localization coverage of lib/ (Phase 17 §17.3)', () {
    test('no hardcoded user-visible string in a widget', () {
      final keys = AppStrings.translations['en']?.keys.toSet() ?? <String>{};
      final violations = <String>[];

      for (final file in _dartFiles()) {
        final source = file.readAsStringSync();
        for (final pattern in _literalPatterns) {
          for (final match in pattern.allMatches(source)) {
            final literal = match.group(1)!;
            if (!_wordPattern.hasMatch(literal)) continue;
            if (keys.contains(literal)) continue;
            violations.add(
              '${file.path.replaceAll('\\', '/')}:'
              '${_lineOf(source, match.start)}: Text($literal)',
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'these bypass AppStrings.t and render in one language only:\n'
            '${violations.join('\n')}',
      );
    });

    test('every AppStrings.t lookup names a key that exists', () {
      final keys = AppStrings.translations['en']?.keys.toSet() ?? <String>{};
      final unknown = <String>[];

      for (final file in _dartFiles()) {
        final source = file.readAsStringSync();
        for (final match in _lookupPattern.allMatches(source)) {
          final key = match.group(1)!;
          if (keys.contains(key)) continue;

          // Dynamic keys (`purchase_status_$status`) cannot be checked
          // literally, but the *family* can: if no key starts with the
          // static prefix, every one of them falls back to raw text.
          if (key.contains(r'$')) {
            final prefix = key.split(r'$').first;
            if (prefix.isNotEmpty && keys.any((k) => k.startsWith(prefix))) {
              continue;
            }
          }

          unknown.add(
            '${file.path.replaceAll('\\', '/')}:'
            '${_lineOf(source, match.start)}: $key',
          );
        }
      }

      expect(
        unknown,
        isEmpty,
        reason:
            'AppStrings.t falls back to the raw key on screen:\n'
            '${unknown.join('\n')}',
      );
    });

    test('every dynamic key family resolves for all of its enum values', () {
      final missing = <String>[];
      for (final family in _dynamicKeyFamilies.entries) {
        for (final value in family.value) {
          final key = '${family.key}$value';
          for (final locale in AppStrings.translations.keys) {
            final resolved = AppStrings.t(key, locale);
            if (resolved == key) missing.add('$key@$locale');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason: 'dynamic keys with no translation: $missing',
      );
    });
  });
}
