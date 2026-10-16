// Shared presentation-only number formatting for Klick POS.
//
// Groups integer digits in sets of three (counting from the right) using a
// regular space, e.g. `1000` → `1 000`, `218095577.85` → `218 095 577.85`,
// `-1234567.89` → `-1 234 567.89`.
//
// These helpers are pure string transforms on already-formatted values:
// - they never parse to `double` (no floating point drift),
// - they preserve the input's decimal separator (`.`) and precision verbatim,
// - they pass through anything that is not a plain decimal number
//   (identifiers, barcodes, dates, invoice numbers, already-grouped text…).
//
// Never use these helpers to build API payloads or values for calculations —
// strip grouping first with [stripGrouping] if a formatted value must be
// parsed back.

/// Matches a plain decimal number: optional `-`, digits, optional `.` + digits.
final RegExp _plainNumberPattern = RegExp(r'^-?\d+(?:\.\d+)?$');

/// True when [raw] is a plain (ungrouped) decimal number.
bool isPlainNumber(String raw) => _plainNumberPattern.hasMatch(raw.trim());

/// Inserts a regular space between every group of three integer digits,
/// counting from the right: `218095577.85` → `218 095 577.85`.
///
/// Presentation only:
/// - the sign, decimal separator and decimal digits are preserved verbatim
///   (no digits are added or removed),
/// - values that are not plain decimal numbers (empty, identifiers,
///   already-grouped text, scientific notation…) are returned trimmed and
///   unchanged,
/// - `0`, small numbers and numbers with no integer thousands are returned
///   unchanged.
String formatGrouped(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return value;
  if (!_plainNumberPattern.hasMatch(value)) return value;

  final negative = value.startsWith('-');
  final unsigned = negative ? value.substring(1) : value;
  final dot = unsigned.indexOf('.');
  final integerPart = dot == -1 ? unsigned : unsigned.substring(0, dot);
  final fractionPart = dot == -1 ? '' : unsigned.substring(dot);

  final grouped = integerPart.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ' ',
  );
  return '${negative ? '-' : ''}$grouped$fractionPart';
}

/// Formats a [double] with a fixed number of [decimals] digits and space
/// thousands grouping: `formatGroupedFixed(4000000.0, 2)` → `'4 000 000.00'`.
///
/// This is the display companion of `value.toStringAsFixed(decimals)` —
/// it does not round differently, it only groups the integer part.
String formatGroupedFixed(double value, int decimals) =>
    formatGrouped(value.toStringAsFixed(decimals));

/// Removes regular-space thousands grouping so a displayed value can be
/// parsed back exactly: `'218 095 577.85'` → `'218095577.85'`.
///
/// Only regular spaces are stripped, so the result is the original plain
/// decimal string. Use this before feeding displayed numbers into parsers
/// (`double.tryParse`, money validators, API payloads…).
String stripGrouping(String raw) => raw.replaceAll(' ', '');
