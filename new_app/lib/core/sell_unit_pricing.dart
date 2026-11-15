// Automatic sell-unit (bundle) pricing — "Method 2".
//
// A product may sell at a discounted price when bought by the selling unit:
//
//   regular unit price   500 DA
//   sell unit ("bundle")   4 units for 1 900 DA
//
// Method 2 charges that bundle price automatically, for every COMPLETE
// sell unit in the line, and the regular unit price for the rest:
//
//   bundleCount      = floor(quantity / sellUnitQuantity)
//   remainingQuantity = quantity % sellUnitQuantity
//   lineTotal = bundleCount * sellUnitPrice
//             + remainingQuantity * regularUnitPrice
//
//   1 → 500   2 → 1000   3 → 1500   4 → 1900
//   5 → 2400  6 → 2900   7 → 3400   8 → 3800  …
//
// The cart already has exactly the right shape for this: a line is
// `quantity × unit_price − line_discount`. Method 2 therefore keeps the
// REGULAR unit price on the line (so the cashier still sees 500 DA per
// unit, stock math and VAT are untouched) and expresses the bundle saving
// as the line's discount:
//
//   line_discount = quantity * regularUnitPrice − bundleTotal(quantity)
//
// That discount is the SAME field the backend already validates and
// persists (`app/services/sale.py::_apply_line_discount`), the invoice and
// the sales history read the persisted line total, and nothing has to be
// added to the schema. The bundle price is never stacked with another
// discount: this module only produces the ONE derived amount.
//
// All arithmetic is exact fixed point at the app's 1/1000 quantity scale
// (see core/quantity_expression.dart) — no binary floating point, so
// 4 × 499.99 and 1900.005 style inputs cannot drift a cent between the
// cart, the invoice and the saved sale.
import 'quantity_expression.dart';

/// One product's automatic bundle configuration, resolved from its active
/// selling units. A null instance means "no usable bundle": the product
/// prices at its regular unit price exactly as before.
class AutoSellUnitPricing {
  /// Units per sell unit (`product_selling_units.multiplier`), > 1.
  final String bundleQuantity;

  /// The sell unit's own configured price (`selling_price`).
  final String bundlePrice;

  /// The regular unit price this plan was resolved against — the price the
  /// remaining units are charged at. Kept here so a recomputation can never
  /// silently use a different base than the add did.
  final String unitPrice;

  const AutoSellUnitPricing({
    required this.bundleQuantity,
    required this.bundlePrice,
    required this.unitPrice,
  });
}

/// True when [plan] describes a real discount: a bundle must hold more than
/// one unit and cost strictly less than that many regular units. Anything
/// else (a sell unit priced at or above its components, a multiplier of 1,
/// unparsable values) is NOT a discount and must never be applied — the
/// caller falls back to plain regular pricing.
bool autoSellUnitIsDiscounted(AutoSellUnitPricing plan) {
  final bundleQty = posScaled(plan.bundleQuantity);
  final bundlePrice = posScaled(plan.bundlePrice);
  final unitPrice = posScaled(plan.unitPrice);
  if (bundleQty == null || bundlePrice == null || unitPrice == null) {
    return false;
  }
  if (bundleQty <= kPosQtyScale) return false;
  if (bundlePrice <= 0 || unitPrice <= 0) return false;
  final regularForBundle = _scaleMul(bundleQty, unitPrice);
  return bundlePrice < regularForBundle;
}

/// `floor(quantity / bundleQuantity)` — the number of complete bundles.
int sellUnitBundleCount({
  required String quantity,
  required String bundleQuantity,
}) {
  final q = posScaled(quantity);
  final bundle = posScaled(bundleQuantity);
  if (q == null || bundle == null || bundle <= 0) return 0;
  final count = q ~/ bundle;
  return count < 0 ? 0 : count;
}

/// `quantity % bundleQuantity` — the units charged at the regular price.
int sellUnitRemainder({
  required String quantity,
  required String bundleQuantity,
}) {
  final q = posScaled(quantity);
  final bundle = posScaled(bundleQuantity);
  if (q == null || bundle == null || bundle <= 0) return 0;
  final remaining = q % bundle;
  return remaining < 0 ? 0 : remaining;
}

/// The Method 2 line total for [quantity], formatted like every other cart
/// amount (scaled-integer text, no trailing zeros).
///
/// Returns null when the plan is unusable, so the caller can fall back to
/// `quantity × unitPrice` instead of silently charging a wrong amount.
String? autoSellUnitTotal(AutoSellUnitPricing plan, String quantity) {
  if (!autoSellUnitIsDiscounted(plan)) return null;
  final q = posScaled(quantity);
  final bundleQty = posScaled(plan.bundleQuantity)!;
  final bundlePrice = posScaled(plan.bundlePrice)!;
  final unitPrice = posScaled(plan.unitPrice)!;
  if (q == null || q < 0) return null;

  final bundles = q ~/ bundleQty;
  final remaining = q % bundleQty;
  final total =
      (bundles * bundlePrice) + _scaleMul(remaining, unitPrice);
  return posScaledText(total);
}

/// The automatic line discount: regular value of [quantity] minus the
/// bundle total. `'0'` when Method 2 does not apply (or saves nothing).
///
/// The discount is never negative: if a configuration would charge MORE
/// than the regular price at this quantity (possible only for a plan that
/// [autoSellUnitIsDiscounted] already rejects) the value clamps to zero.
String autoSellUnitDiscount(AutoSellUnitPricing plan, String quantity) {
  final total = autoSellUnitTotal(plan, quantity);
  if (total == null) return '0';
  final q = posScaled(quantity);
  final unitPrice = posScaled(plan.unitPrice);
  final totalScaled = posScaled(total);
  if (q == null || unitPrice == null || totalScaled == null) return '0';
  final regular = _scaleMul(q, unitPrice);
  final discount = regular - totalScaled;
  return discount > 0 ? posScaledText(discount) : '0';
}

/// `a × b` for two ×1000-scaled values, back at ×1000 with half-up
/// rounding — the same convention the quantity multiplier math uses.
int _scaleMul(int a, int b) => ((a * b) + (kPosQtyScale ~/ 2)) ~/ kPosQtyScale;
