/// Exact money-string helpers (thousandths of the currency unit).
///
/// Phase 8 convention: money travels as a decimal STRING (`'120.500'`)
/// and is only ever parsed into integer thousandths for arithmetic —
/// never through `double`.
///
/// These two functions used to live in `features/clients/customer_models.dart`;
/// they moved to `core/` so the shared markup-on-cost helper
/// (`core/markup_percent.dart`) can parse money without depending on a
/// feature. `customer_models.dart` re-exports them, so every existing
/// import keeps resolving unchanged.
library;

final RegExp _moneyPattern = RegExp(r'^(\d+)(?:\.(\d{1,3}))?$');

/// Parses a money string to integer thousandths without floating point.
///
/// `'120.500'` → `120500`, `'7'` → `7000`. Returns null for empty,
/// negative, or more-than-3-decimal input (reject instead of rounding
/// client-side — the backend is authoritative).
int? moneyToMilli(String raw) {
  // Accept space-grouped display values defensively (`'1 500'` → `'1500'`):
  // grouping is presentation-only and must never change the parsed value.
  final value = raw.replaceAll(' ', '').trim();
  if (value.isEmpty) return null;
  final match = _moneyPattern.firstMatch(value);
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null) return null;
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  final frac = int.tryParse(fraction);
  if (frac == null) return null;
  return whole * 1000 + frac;
}

/// Renders thousandths back to a money string: `120500` → `'120.500'`.
String milliToMoney(int milli) {
  final negative = milli < 0;
  final abs = milli.abs();
  final whole = abs ~/ 1000;
  final fraction = (abs % 1000).toString().padLeft(3, '0');
  return '${negative ? '-' : ''}$whole.$fraction';
}
