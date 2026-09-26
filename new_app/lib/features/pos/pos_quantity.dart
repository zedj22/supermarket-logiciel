// Shared POS quantity mutation logic (UX FIX #12 — FIX #6).
//
// Every cart quantity mutation path parses, validates and applies through
// this module so the rules can never diverge:
//   - `+` shortcut            → applyLineQuantity (raw "+1")
//   - cart +/- buttons        → applyLineQuantity
//   - direct qty typing       → applyLineQuantity (raw text / expression)
//   - quantity expression     → applyLineQuantity ("10*24" → 240)
//   - `*` quantity input      → applyLineQuantity (entered value replaces)
//   - add-to-cart quantity    → applyAddingLine (merge aware)
//
// Two independent guarantees:
//   1. exact decimal arithmetic (no binary floating point) for expression
//      parsing and stock math — quantities are scaled ×1000 integers,
//      matching the backend Numeric(18,3) domain;
//   2. an EARLY client-side stock guard that never allows an impossible
//      cart quantity, including the sum across every line that draws from
//      the same stock bucket (product + variant). The backend checkout
//      remains authoritative — this guard only rejects the obvious.
import '../../core/quantity_expression.dart';
import '../../core/strings.dart';
import 'pos_models.dart';
import 'pos_providers.dart';

// The exact parser (scaled integers, `10*24` → 240, one rejection rule)
// lives in core so the add-flow quantity dialog shares it verbatim.
export '../../core/quantity_expression.dart';

// ---------------------------------------------------------------------------
// Stock math (exact, cross-line)
// ---------------------------------------------------------------------------

/// Base units required by [quantity] of [line], scaled ×1000.
int? posRequestedBaseScaled({
  required String quantity,
  required String? unitMultiplier,
}) {
  final qty = posScaled(quantity);
  if (qty == null) return null;
  final multiplier = posScaled(unitMultiplier) ?? kPosQtyScale;
  if (multiplier <= 0) return kPosQtyScale;
  // qty × multiplier — both ×1000 → result ×1e6 → back to ×1000.
  final product = qty * multiplier;
  return (product + (kPosQtyScale ~/ 2)) ~/ kPosQtyScale;
}

/// Base units required by [quantity] of [line] (selling-unit aware) —
/// plain double view of [posRequestedBaseScaled] for previews only.
double posRequestedBaseQuantity(CartLine line, double quantity) {
  final scaled = posRequestedBaseScaled(
    quantity: posScaledText((quantity * kPosQtyScale).round()),
    unitMultiplier: line.unitMultiplier,
  );
  return (scaled ?? 0) / kPosQtyScale;
}

/// True when both lines draw from the same stock bucket: same product and
/// same variant (selling-unit lines of one product share the bucket).
bool posSameStockBucket(CartLine a, CartLine b) =>
    a.productId == b.productId && (a.variantId ?? '') == (b.variantId ?? '');

/// Core stock guard: can [cart] hold [quantity] for the line described by
/// [prototype] when the line identified by [existingKey] is changed?
///
/// - compares the TOTAL base quantity requested across every line of the
///   same stock bucket against [CartLine.availableStock];
/// - unknown stock (null / unparseable) never blocks;
/// - reducing a quantity that is already over stock stays possible so the
///   cashier can always repair the cart.
///
/// Returns the localized error message or null when the change is allowed.
String? canApplyQuantityChange({
  required PosCartState cart,
  required CartLine prototype,
  required String? existingKey,
  required String quantity,
  required String loc,
}) {
  final requested = posScaled(quantity);
  if (requested == null) {
    return AppStrings.t('invalid_quantity_expression', loc);
  }
  if (requested <= 0) {
    return AppStrings.t('invalid_quantity_expression', loc);
  }
  if (requested > kPosQuantityMax * kPosQtyScale) {
    return AppStrings.t('quantity_too_large', loc);
  }

  final stock = posScaled(prototype.availableStock);
  if (stock == null) return null; // unknown stock → never blocks

  final requestedBase = posRequestedBaseScaled(
    quantity: quantity,
    unitMultiplier: prototype.unitMultiplier,
  );
  if (requestedBase == null) {
    return AppStrings.t('invalid_quantity_expression', loc);
  }

  var currentBase = 0;
  var othersBase = 0;
  for (final line in cart.lines) {
    final lineBase = posRequestedBaseScaled(
      quantity: line.quantity,
      unitMultiplier: line.unitMultiplier,
    );
    if (lineBase == null) continue;
    if (existingKey != null && line.key == existingKey) {
      currentBase = lineBase;
      continue;
    }
    if (posSameStockBucket(line, prototype)) {
      othersBase += lineBase;
    }
  }

  if (othersBase + requestedBase <= stock) return null;
  // Never trap the cashier: shrinking a line that is already over stock is
  // always allowed (it moves the cart back toward a valid state).
  if (requestedBase <= currentBase) return null;
  return AppStrings.t('out_of_stock', loc);
}

/// Single-line stock rule used by dialogs that only know one line
/// (`quantity × unit multiplier ≤ available stock`, exact scaled math).
/// The cart-wide rule is [canApplyQuantityChange] — always applied again
/// at the moment the mutation is written to the cart.
String? posQtyStockError({
  required String quantity,
  required String? availableStock,
  required String? unitMultiplier,
  required String loc,
}) {
  final stock = posScaled(availableStock);
  if (stock == null) return null; // unknown stock → never blocks
  final base = posRequestedBaseScaled(
    quantity: quantity,
    unitMultiplier: unitMultiplier,
  );
  if (base == null) return null;
  if (base <= stock) return null;
  return AppStrings.t('out_of_stock', loc);
}

// ---------------------------------------------------------------------------
// Apply (single funnel for every mutation path)
// ---------------------------------------------------------------------------

/// Rejected mutation: localized [message] plus whether it came from the
/// stock guard (toast key selection stays with the caller).
typedef PosQuantityErrorHandler = void Function(
  String message,
  bool isStockError,
);

/// `quantity + delta` in exact scaled math (never binary floating point),
/// clamped to `[0, kPosQuantityMax]`. [delta] is in quantity units.
String posQuantityAdd(String quantity, double delta) {
  final scaled = posScaled(quantity) ?? 0;
  final add = (delta * kPosQtyScale).round();
  final next = (scaled + add).clamp(0, (kPosQuantityMax * kPosQtyScale).toInt());
  return posScaledText(next);
}

/// Applies [rawInput] as the new quantity of an existing cart line.
///
/// Parses an optional expression, runs the shared stock guard (including
/// the other lines of the same bucket) and writes to the cart only when
/// both pass. Returns true when the cart changed.
bool applyLineQuantity({
  required PosCartNotifier notifier,
  required PosCartState cart,
  required CartLine line,
  required String rawInput,
  required String loc,
  PosQuantityErrorHandler? onError,
}) {
  final expression = parseQuantityExpression(rawInput);
  final parseError = expression.errorMessage(loc);
  if (parseError != null) {
    onError?.call(parseError, false);
    return false;
  }
  final stockError = canApplyQuantityChange(
    cart: cart,
    prototype: line,
    existingKey: line.key,
    quantity: expression.text,
    loc: loc,
  );
  if (stockError != null) {
    onError?.call(stockError, true);
    return false;
  }
  notifier.updateLine(line.key, quantity: expression.text);
  return true;
}

/// Applies [rawInput] as the quantity of a line being added to the cart.
///
/// Merge aware: when the cart already holds the same key (same product /
/// variant / selling unit) the requested quantity is added to it — with
/// exact scaled arithmetic — and the stock guard sees the merged result.
bool applyAddingLine({
  required PosCartNotifier notifier,
  required PosCartState cart,
  required CartLine newLine,
  required String rawInput,
  required String loc,
  PosQuantityErrorHandler? onError,
}) {
  final expression = parseQuantityExpression(rawInput);
  final parseError = expression.errorMessage(loc);
  if (parseError != null) {
    onError?.call(parseError, false);
    return false;
  }
  CartLine? existing;
  for (final line in cart.lines) {
    if (line.key == newLine.key) {
      existing = line;
      break;
    }
  }
  final int requestedScaled;
  final String requestedText;
  if (existing == null) {
    requestedScaled = expression.scaled;
    requestedText = expression.text;
  } else {
    requestedScaled =
        (posScaled(existing.quantity) ?? 0) + expression.scaled;
    requestedText = posScaledText(requestedScaled);
    if (requestedScaled > kPosQuantityMax * kPosQtyScale) {
      onError?.call(AppStrings.t('quantity_too_large', loc), false);
      return false;
    }
  }
  final stockError = canApplyQuantityChange(
    cart: cart,
    prototype: newLine,
    existingKey: existing?.key,
    quantity: requestedText,
    loc: loc,
  );
  if (stockError != null) {
    onError?.call(stockError, true);
    return false;
  }
  if (existing == null) {
    notifier.addLine(newLine.copyWith(quantity: requestedText));
  } else {
    // The merged total was already computed exactly above (scaled integer
    // math). The notifier has to SET it — merging it a second time would
    // count the existing quantity twice (1 + 1 became 3.0).
    notifier.updateLine(existing.key, quantity: requestedText);
  }
  return true;
}
