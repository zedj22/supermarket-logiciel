// UX FIX #12 (FIX #5) — POS toast localization audit.
//
// Two layers:
//   1. every key a POS toast can show exists in ar/fr/en;
//   2. a static scan proves NO `showPosToast` call passes a raw English
//      string literal as its headline (the class of bug human QA found).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';

/// Every localized key reachable from a POS toast headline.
const posToastKeys = [
  'sale_completed',
  'sale_failed',
  'hold_saved',
  'hold_restored',
  'cart_empty',
  'out_of_stock',
  'cannot_add_out_of_stock',
  'archive_product_pos',
  'permission_discount',
  'permission_credit',
  'permission_denied',
  'invoice_copied',
  'api_error_retry',
  'network_error_retry',
  'session_expired_login',
  'stock_conflict',
  'validation_error',
  'invalid_quantity_expression',
  'quantity_too_large',
  'print_failed',
];

/// Expressions that are already localized upstream (verified by reading
/// the producer: provider `_message()` → `posApiMessage`, `PosApiError`
/// message, notice keys → `AppStrings.t`).
const localizedExpressions = {
  'message',
  'err',
  'error',
  'failure.message',
  'error.message',
  'stockError',
};

String _argsOf(String source, int open) {
  var depth = 0;
  var i = open;
  var quote = '';
  while (i < source.length) {
    final ch = source[i];
    if (quote.isNotEmpty) {
      if (ch == r'\') {
        i += 2;
        continue;
      }
      if (ch == quote) quote = '';
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      i++;
      continue;
    }
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return source.substring(open + 1, i);
    }
    i++;
  }
  return source.substring(open + 1);
}

/// Expression assigned to `message:` inside one call's argument list.
String? _messageExpression(String args) {
  final start = args.indexOf('message:');
  if (start < 0) return null;
  var i = start + 'message:'.length;
  var depth = 0;
  var quote = '';
  final buffer = StringBuffer();
  while (i < args.length) {
    final ch = args[i];
    if (quote.isNotEmpty) {
      buffer.write(ch);
      if (ch == quote) quote = '';
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      buffer.write(ch);
      i++;
      continue;
    }
    if (ch == '(' || ch == '[' || ch == '{') depth++;
    if (ch == ')' || ch == ']' || ch == '}') depth--;
    if (ch == ',' && depth == 0) break;
    buffer.write(ch);
    i++;
  }
  return buffer.toString().trim();
}

class ToastCall {
  ToastCall(this.file, this.line, this.expression);
  final String file;
  final int line;
  final String expression;
}

List<ToastCall> _scan() {
  final calls = <ToastCall>[];
  final files = Directory('lib/features/pos')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final source = file.readAsStringSync();
    final needle = 'showPosToast(';
    var from = 0;
    while (true) {
      final at = source.indexOf(needle, from);
      if (at < 0) break;
      from = at + needle.length;
      // Skip the declaration itself (`void showPosToast(`).
      final before = source.substring(0, at).trimRight();
      if (before.endsWith('void')) continue;
      final args = _argsOf(source, at + needle.length - 1);
      final line = '\n'.allMatches(source.substring(0, at)).length + 1;
      final expression = _messageExpression(args);
      if (expression != null) {
        calls.add(ToastCall(file.path, line, expression));
      }
    }
  }
  return calls;
}

void main() {
  group('G. toast keys are localized (ar/fr/en)', () {
    for (final locale in ['ar', 'fr', 'en']) {
      test('every toast key exists and is non-empty in "$locale"', () {
        for (final key in posToastKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(value, isNot(key), reason: 'untranslated: $key@$locale');
        }
      });
    }

    test('Arabic and French actually differ from English', () {
      for (final key in posToastKeys) {
        expect(AppStrings.t(key, 'ar'), isNot(AppStrings.t(key, 'en')),
            reason: '$key not translated to Arabic');
        expect(AppStrings.t(key, 'fr'), isNot(AppStrings.t(key, 'en')),
            reason: '$key not translated to French');
      }
    });
  });

  group('H. no raw toast message reaches the cashier', () {
    test('the POS feature really contains toast calls (scan is live)', () {
      final calls = _scan();
      expect(calls, isNotEmpty, reason: 'scanner found no showPosToast calls');
      // Guard against the scanner silently matching nothing later.
      expect(calls.length, greaterThanOrEqualTo(15),
          reason: 'only ${calls.length} toast calls scanned');
    });

    test('no showPosToast headline is a string literal', () {
      final raw = _scan()
          .where((c) =>
              c.expression.startsWith("'") || c.expression.startsWith('"'))
          .toList();
      expect(
        raw,
        isEmpty,
        reason: 'raw English toast text: '
            '${raw.map((c) => '${c.file}:${c.line} → ${c.expression}').join(', ')}',
      );
    });

    test('every toast headline is AppStrings.t(...) or a verified producer',
        () {
      final suspicious = _scan()
          .where((c) =>
              !c.expression.contains('AppStrings.t(') &&
              !localizedExpressions.contains(c.expression))
          .toList();
      expect(
        suspicious,
        isEmpty,
        reason: 'unverified toast message: '
            '${suspicious.map((c) => '${c.file}:${c.line} → ${c.expression}').join(', ')}',
      );
    });

    test('every key passed to AppStrings.t in a toast exists in ar/fr/en',
        () {
      final keys = <String>{};
      for (final call in _scan()) {
        final matches =
            RegExp(r"AppStrings\.t\('([^']+)'").allMatches(call.expression);
        for (final m in matches) {
          keys.add(m.group(1)!);
        }
      }
      expect(keys, isNotEmpty);
      for (final key in keys) {
        for (final locale in ['ar', 'fr', 'en']) {
          expect(AppStrings.t(key, locale), isNotEmpty,
              reason: 'toast key missing: $key@$locale');
        }
      }
    });
  });
}
