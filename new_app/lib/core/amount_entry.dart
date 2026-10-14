// POS weight/length AMOUNT-entry math (exact scaled arithmetic).
//
// When a cashier sells by weight (kg, gram) or length (meter) they may
// enter HOW MUCH MONEY the customer wants to pay instead of the weight /
// length itself. This module owns the two exact conversions — never
// binary floating point — so the dialog and its tests share one rule:
//
//   quantity = amount ÷ unit price   (HALF-UP to the 3-decimal domain)
//   actual   = quantity × unit price (HALF-UP to the money domain)
//
// Both inputs and outputs are scaled ×1000 integers, matching the
// backend Numeric(18,3) quantity domain (`kPosQtyScale`). The actual
// total is ALWAYS recomputed from the rounded quantity — never the raw
// requested amount — so the cashier confirms what will really be
// charged (requirement: never silently charge a different amount).
import 'quantity_expression.dart';

/// Unit-type codes that offer the amount-entry mode: weight (kg, gram)
/// and length (meter) only — the existing ProductUnit vocabulary, never
/// translated labels. Volume (liter/milliliter) and count-based units
/// (piece, pack, box, …) are deliberately excluded.
const Set<String> kAmountEntryUnitTypes = {'kg', 'gram', 'meter'};

/// True when [unitType] is a weight or length unit that may offer
/// amount entry. Case-insensitive; unknown / empty → false.
bool isAmountEntryUnit(String? unitType) =>
    kAmountEntryUnitTypes.contains((unitType ?? '').trim().toLowerCase());

/// `amount ÷ price` in exact scaled (×1000) math, HALF-UP — `100 ÷ 250`
/// → `0.400`, `100 ÷ 300` → `0.333`. Null when either operand is
/// unusable (amount ≤ 0 → nothing to sell; price ≤ 0 → division is
/// meaningless and amount mode must stay disabled).
int? amountToQuantityScaled({
  required int amountScaled,
  required int priceScaled,
}) {
  if (amountScaled <= 0 || priceScaled <= 0) return null;
  final numerator = amountScaled * kPosQtyScale;
  // Half-up on integer division: (2n + d) ~/ (2d).
  return (2 * numerator + priceScaled) ~/ (2 * priceScaled);
}

/// `quantity × price` in exact scaled (×1000) math, HALF-UP — the ACTUAL
/// money amount the rounded quantity costs (`0.333 × 300` → `99.900`,
/// never the requested `100`). Null when either operand is unusable.
int? quantityToAmountScaled({
  required int quantityScaled,
  required int priceScaled,
}) {
  if (quantityScaled <= 0 || priceScaled <= 0) return null;
  final product = quantityScaled * priceScaled; // ×10^6
  return (2 * product + kPosQtyScale) ~/ (2 * kPosQtyScale);
}
