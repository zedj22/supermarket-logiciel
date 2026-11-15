// Choosing WHICH selling unit prices a line automatically (Method 2).
//
// A product can carry several selling units (Box ×4, Carton ×12, …). The
// automatic mode must pick exactly one per line and it must be a real
// discount, so the rule is deliberately data-driven and deterministic:
//
//  * the unit must be active, NOT the base unit, and hold more than one
//    base unit (`multiplier > 1`);
//  * it must carry its own configured price (`selling_price`) that is
//    strictly cheaper than `multiplier × regular unit price` — a "bundle"
//    that costs the same or more is not a discount and is ignored;
//  * among the eligible units the one that SAVES the most per bundle wins
//    (ties go to the larger bundle, then to the unit's name/id order, so
//    two identical configurations can never flip between scans).
//
// No eligible unit → null, and the caller keeps plain regular pricing (or,
// in manual mode, the existing picker). Nothing is guessed from names or
// from the display language.
import '../../core/quantity_expression.dart';
import '../../core/sell_unit_pricing.dart';
import '../products/models.dart';

/// The automatic bundle plan for [units] priced against [unitPrice], or
/// null when the product has no usable discounted selling unit.
AutoSellUnitPricing? resolveAutoSellUnit(
  List<SellingUnitModel> units, {
  required String unitPrice,
}) {
  final base = posScaled(unitPrice);
  if (base == null || base <= 0) return null;

  AutoSellUnitPricing? best;
  var bestSaving = 0;
  var bestBundle = 0;

  for (final unit in units) {
    if (unit.isArchived || unit.isBaseUnit) continue;
    final price = unit.sellingPrice;
    if (price == null) continue;
    final plan = AutoSellUnitPricing(
      bundleQuantity: unit.multiplier,
      bundlePrice: price,
      unitPrice: unitPrice,
    );
    if (!autoSellUnitIsDiscounted(plan)) continue;
    final bundleQty = posScaled(unit.multiplier);
    final bundlePrice = posScaled(price);
    if (bundleQty == null || bundlePrice == null) continue;
    // Saving in ×1e6 money units (scaled price × scaled quantity); only
    // its ORDER matters here, so the scale is irrelevant.
    final saving = (bundleQty * base) - (bundlePrice * kPosQtyScale);
    if (saving > bestSaving ||
        (saving == bestSaving && bundleQty > bestBundle)) {
      best = plan;
      bestSaving = saving;
      bestBundle = bundleQty;
    }
  }
  return best;
}
