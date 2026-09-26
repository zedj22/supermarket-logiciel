// Quantity expression parsing (shared, exact scaled arithmetic).
//
// Extracted from the POS quantity funnel (UX FIX #12 — FIX #3/#6) so the
// SAME rules apply everywhere a quantity is typed:
//   - POS cart typing / `+` / `*` quantity input dialog
//   - product selling-unit quantity dialog (add flow)
//
// Two guarantees:
//   1. exact decimal arithmetic — quantities are scaled ×1000 integers,
//      matching the backend Numeric(18,3) domain, never binary floats;
//   2. one rejection rule for plain numbers and `a*b` expressions alike.
import 'strings.dart';

/// Largest quantity a single entry may hold (matches the cart clamp).
const double kPosQuantityMax = 999999;

/// Backend quantity precision: 3 decimal places.
const int kPosQtyScale = 1000;

enum PosQuantityStatus {
  /// Parsed successfully (plain number or `a*b` expression).
  valid,

  /// Nothing entered.
  empty,

  /// Malformed (`*`, `10*`, `*24`, `10**24`, `abc`, …).
  invalid,

  /// Zero or negative (`0`, `10*0`, `-2`, `10*-4`).
  nonPositive,

  /// Above [kPosQuantityMax].
  tooLarge,
}

/// Result of [parseQuantityExpression].
class PosQuantityExpression {
  const PosQuantityExpression._(this.status, this.value, this.text)
      : scaled = 0;

  const PosQuantityExpression.valid(this.scaled, this.value, this.text)
      : status = PosQuantityStatus.valid;

  final PosQuantityStatus status;

  /// Numeric value (0 when [status] is not [PosQuantityStatus.valid]).
  final double value;

  /// Exact quantity as a scaled (×1000) integer — used for further math so
  /// no binary floating point ever enters a quantity.
  final int scaled;

  /// Text stored on the line: the raw input for a plain number (unchanged
  /// behavior), the computed product for an expression.
  final String text;

  const PosQuantityExpression.failure(PosQuantityStatus status)
      : this._(status, 0, '');

  bool get isValid => status == PosQuantityStatus.valid;

  /// Localized message for a failed parse; null when valid.
  String? errorMessage(String loc) {
    switch (status) {
      case PosQuantityStatus.valid:
        return null;
      case PosQuantityStatus.empty:
      case PosQuantityStatus.invalid:
      case PosQuantityStatus.nonPositive:
        return AppStrings.t('invalid_quantity_expression', loc);
      case PosQuantityStatus.tooLarge:
        return AppStrings.t('quantity_too_large', loc);
    }
  }
}

/// Scaled (×1000) integer view of a plain decimal string — `null` when the
/// text is not a plain positive decimal (sign, exponent, letters, …).
int? posScaled(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d{1,3}))?$').firstMatch(text);
  if (match == null) return null;
  final whole = match.group(1)!;
  if (whole.length > 7) return null; // > 9999999 — outside the POS range
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  final scaled = int.parse(whole) * kPosQtyScale + int.parse(fraction);
  return scaled;
}

/// Formats a scaled (×1000) integer as decimal text (`240000` → `240`).
String posScaledText(int scaled) {
  final negative = scaled < 0;
  final abs = scaled.abs();
  final whole = abs ~/ kPosQtyScale;
  final fraction = abs % kPosQtyScale;
  if (fraction == 0) return '${negative ? '-' : ''}$whole';
  final digits = '$fraction'.padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole.$digits';
}

/// Parses `10`, `2.5`, `0.500` **and** quantity expressions `10*24` → 240.
///
/// Whitespace around the operands is accepted (`10 * 24` = 240). Anything
/// else (`*`, `10*`, `*24`, `10**24`, `10*0`, `-2`, `abc`) is rejected with
/// the matching [PosQuantityStatus]. The product is computed on scaled
/// integers — never with binary floating point.
PosQuantityExpression parseQuantityExpression(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const PosQuantityExpression.failure(PosQuantityStatus.empty);
  }
  if (text.startsWith('-')) {
    return const PosQuantityExpression.failure(PosQuantityStatus.nonPositive);
  }

  final parts = text.split('*').map((p) => p.trim()).toList();
  if (parts.length > 2) {
    return const PosQuantityExpression.failure(PosQuantityStatus.invalid);
  }

  final operands = <int>[];
  for (final part in parts) {
    final scaled = posScaled(part);
    if (scaled == null) {
      return const PosQuantityExpression.failure(PosQuantityStatus.invalid);
    }
    operands.add(scaled);
  }

  int resultScaled;
  if (operands.length == 1) {
    resultScaled = operands.first;
  } else {
    // Both operands are ×1000 → the product is ×1e6; round back to ×1000
    // (half up) so the result matches the backend 3-decimal domain.
    final product = operands[0] * operands[1];
    resultScaled = (product + (kPosQtyScale ~/ 2)) ~/ kPosQtyScale;
  }

  if (resultScaled <= 0) {
    return const PosQuantityExpression.failure(PosQuantityStatus.nonPositive);
  }
  if (resultScaled > kPosQuantityMax * kPosQtyScale) {
    return const PosQuantityExpression.failure(PosQuantityStatus.tooLarge);
  }

  final canonical = posScaledText(resultScaled);
  // Plain numbers keep the caller's own text; expressions store the
  // computed product.
  final stored = operands.length == 1 ? text : canonical;
  return PosQuantityExpression.valid(
    resultScaled,
    double.parse(canonical),
    stored,
  );
}

/// Validates raw quantity input — the shared "is this input acceptable"
/// rule for every quantity field. Returns the localized error message or
/// null when the input may be used.
String? validateRequestedQuantity(String raw, String loc) {
  return parseQuantityExpression(raw).errorMessage(loc);
}
