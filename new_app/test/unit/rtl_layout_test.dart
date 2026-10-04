// Phase 17 (§17.4) — RTL layout works.
//
// `Directionality` already follows the locale (Phase 6, asserted in
// localization_init_test.dart), so what is left to guard is everything
// that *ignores* it:
//
//  1. physical left/right layout properties — they point the wrong way
//     on an Arabic screen.  The directional equivalents
//     (`EdgeInsetsDirectional.only(start/end:)`, `AlignmentDirectional`,
//     `TextAlign.start/end`) flip for free.
//  2. directional icons.  Flutter mirrors an icon only when its
//     `IconData.matchTextDirection` is true; `Icons.chevron_left` is,
//     which is why the pagination rows need no per-call-site logic — but
//     a non-mirroring directional icon would silently point backwards.
//
// `TextDirection.ltr` pins are NOT violations: they are the deliberate
// rule that numbers, dates, quantities and signed changes never mirror
// (a "-4" must read "-4" in Arabic too).  The last test keeps them.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Idioms that pin layout to a physical side.  Each one has a directional
/// replacement, so there is no excuse for them to survive.
final _physicalPatterns = <String, RegExp>{
  'EdgeInsets.only(left/right)':
      RegExp(r'EdgeInsets\.only\([^)\n]*\b(?:left|right)\s*:'),
  'EdgeInsets.symmetric(left/right)':
      RegExp(r'EdgeInsets\.symmetric\([^)\n]*\b(?:left|right)\s*:'),
  'Alignment.centerLeft/centerRight/topLeft/...':
      RegExp(r'\bAlignment\.(?:centerLeft|centerRight|topLeft|topRight|'
          r'bottomLeft|bottomRight)\b'),
  'TextAlign.left/right': RegExp(r'\bTextAlign\.(?:left|right)\b'),
  'Positioned(left:/right:)': RegExp(r'\bPositioned\(\s*(?:left|right)\s*:'),
  'BorderRadius.only(...)': RegExp(r'\bBorderRadius\.only\('),
  'Border.only(...)': RegExp(r'\bBorder\.only\('),
};

/// `left:`/`right:` written straight onto a directional-capable widget.
final _physicalProperty = RegExp(
  r'\b(?:left|right)\s*:\s*(?:const\s+)?'
  r'(?:EdgeInsets|Alignment|Border|BorderRadius|Matrix4|BoxDecoration)',
);

/// Any `Icons.x` reference in the app.
final _iconPattern = RegExp(r'\bIcons\.([A-Za-z0-9_]+)');

/// Icon names that point horizontally, and therefore must be mirrored.
final _horizontalIconName = RegExp(
  r'(?:left|right|chevron|arrow_back|arrow_forward|'
  r'navigate_before|navigate_next|first_page|last_page)',
  caseSensitive: false,
);

/// The horizontal icons the app actually uses, checked against the SDK
/// (`IconData.matchTextDirection`), so a new one cannot be dropped in
/// without being verified.
const _mirroredIcons = <String, IconData>{
  'chevron_left': Icons.chevron_left,
  'chevron_right': Icons.chevron_right,
};

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// Whether [Icon] wrapped its child in a horizontal flip.
bool _isMirrored(WidgetTester tester) {
  final iconFinder = find.byType(Icon);
  final transforms = tester.widgetList<Transform>(
    find.descendant(of: iconFinder, matching: find.byType(Transform)),
  );
  return transforms.any((t) => t.transform.storage[0] < 0);
}

Future<Icon> _pumpIcon(WidgetTester tester, TextDirection direction) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: direction,
      child: const Icon(Icons.chevron_left, size: 24),
    ),
  );
  return tester.widget<Icon>(find.byType(Icon));
}

void main() {
  group('RTL layout (Phase 17 §17.4)', () {
    test('no physical left/right layout idiom survives in lib/', () {
      final violations = <String>[];

      for (final file in _dartFiles()) {
        final source = file.readAsStringSync();
        void report(RegExp pattern, String label) {
          for (final match in pattern.allMatches(source)) {
            violations.add(
              '$label @ '
              '${file.path.replaceAll('\\', '/')}:'
              '${_lineOf(source, match.start)}',
            );
          }
        }

        _physicalPatterns.forEach((label, pattern) => report(pattern, label));
        report(_physicalProperty, 'physical left:/right: property');
      }

      expect(
        violations,
        isEmpty,
        reason:
            'these point the wrong way on an Arabic screen — use the '
            'directional (start/end) form instead:\n${violations.join('\n')}',
      );
    });

    test('every directional icon the app uses auto-mirrors under RTL', () {
      final used = <String>{};
      for (final file in _dartFiles()) {
        for (final match in _iconPattern.allMatches(file.readAsStringSync())) {
          final name = match.group(1)!;
          if (_horizontalIconName.hasMatch(name)) used.add(name);
        }
      }

      final unverified =
          used.difference(_mirroredIcons.keys.toSet()).toList()..sort();
      expect(
        unverified,
        isEmpty,
        reason:
            'directional Icons.* used in lib/ but not in _mirroredIcons — '
            'add them there (and assert matchTextDirection) so the RTL '
            'flip is verified: $unverified',
      );

      final notMirroring = _mirroredIcons.entries
          .where((e) => !e.value.matchTextDirection)
          .map((e) => e.key)
          .toList();
      expect(
        notMirroring,
        isEmpty,
        reason:
            'these would point the wrong way under RTL: $notMirroring',
      );
    });

    testWidgets('a chevron is flipped under RTL and left alone under LTR',
        (tester) async {
      final icon = await _pumpIcon(tester, TextDirection.rtl);
      expect(icon.icon, Icons.chevron_left);
      expect(
        _isMirrored(tester),
        isTrue,
        reason: 'Icons.chevron_left must be mirrored for RTL pagination',
      );

      await tester.pumpWidget(const SizedBox());
      final ltrIcon = await _pumpIcon(tester, TextDirection.ltr);
      expect(ltrIcon.icon, Icons.chevron_left);
      expect(
        _isMirrored(tester),
        isFalse,
        reason: 'an LTR screen must not flip the chevron',
      );
    });

    test('numbers stay LTR: TextDirection.ltr pins are still in use', () {
      // Deliberate exception to the directional rule.  Removing these
      // makes "-4" render as "4-" (and dates as "04-10-2026") on Arabic
      // screens, so the pins are asserted to exist rather than scanned for.
      var pins = 0;
      for (final file in _dartFiles()) {
        // `[^;]` crosses newlines: the pin is often a ternary
        // (`textDirection: columns[c].numeric ? TextDirection.ltr : null`).
        pins += RegExp(r'textDirection:[^;]{0,80}TextDirection\.ltr')
            .allMatches(file.readAsStringSync())
            .length;
      }
      expect(
        pins,
        greaterThanOrEqualTo(10),
        reason:
            'numeric/date text lost its LTR pin — quantities, signed '
            'changes and ISO dates must not mirror under RTL (found $pins)',
      );
    });
  });
}
