// Cart → independent-return lines for the POS return mode.
//
// The POS cart cannot identify the original sale of a line (it holds no
// sale reference), so the only supported backend workflow for returning
// what is sitting in the cart is the INDEPENDENT return: one line per
// (product, variant), quantity expressed in BASE units, no sale link.
// The server prices every line from the current catalog — exactly the
// rule `POST /api/v1/returns` applies to the Returns screen's product
// dialog (return_products_dialog.dart). Pack lines are the exception: a
// pack can only be restored by a LINKED return that knows the pack's own
// sale line (the backend rejects `pack_id` on independent lines), so a
// pack anywhere in the cart blocks the whole POS return with a clear
// message — never a silent skip, never a fabricated sale reference.
//
// Exact scaled-integer math throughout (core/quantity_expression.dart,
// the same ×1000 domain the cart and the backend use) — selling-unit
// quantities are converted with `posRequestedBaseScaled`, the shared
// conversion the stock guard already applies (re-exported through
// pos_quantity.dart, which also hosts it).
import 'pos_models.dart';
import 'pos_quantity.dart';

/// One line of `POST /api/v1/returns` produced by the POS return mode.
class PosReturnLine {
  const PosReturnLine({
    required this.productId,
    this.variantId,
    required this.quantity,
  });

  /// Target product (required by the backend's independent-line schema).
  final String productId;

  /// Variant target when the cart line was variant-specific.
  final String? variantId;

  /// Quantity in BASE units as a decimal string (backend 3-decimal
  /// domain; `posScaledText` emits the canonical form).
  final String quantity;

  /// Request shape of an independent return line (`ReturnLineRequest`).
  Map<String, dynamic> toJson() => {
        'product_id': productId,
        if (variantId != null) 'variant_id': variantId,
        'quantity': quantity,
      };
}

/// Result of [buildPosReturnLines]: either `lines` (when `errorKey` is
/// null) or the localization key explaining why the cart cannot become a
/// return document. Never throws, never partially succeeds.
class PosReturnLinesResult {
  const PosReturnLinesResult.ok(this.lines) : errorKey = null;

  const PosReturnLinesResult.failed(this.errorKey) : lines = const [];

  final List<PosReturnLine> lines;
  final String? errorKey;

  bool get isOk => errorKey == null;
}

/// Converts [cartLines] into independent-return lines.
///
/// Rules (all client-side pre-checks; the backend stays authoritative):
///  * an empty cart is not a return (`cart_empty`);
///  * any pack line blocks the return (`pos_return_pack_not_supported`) —
///    packs are returnable only through a linked sale return;
///  * every line must carry a product id and a positive parseable
///    quantity (`error_return_line_invalid` / `invalid_qty`);
///  * selling-unit lines are converted to BASE units with the shared
///    exact conversion (`quantity × unitMultiplier`, half-up ×1000 math);
///  * lines that resolve to the same (product, variant) are MERGED in
///    exact scaled arithmetic — the independent line knows nothing about
///    selling units, so `3 Piece + 1 Box(×10)` of one product is one
///    return line of 13 base units.
///
/// Output order is the cart's first-seen (product, variant) order.
PosReturnLinesResult buildPosReturnLines(List<CartLine> cartLines) {
  if (cartLines.isEmpty) {
    return const PosReturnLinesResult.failed('cart_empty');
  }
  for (final line in cartLines) {
    if (line.isPack) {
      return const PosReturnLinesResult.failed(
        'pos_return_pack_not_supported',
      );
    }
    // A price-only custom line has no product to restock in this flow.
    if (line.customLine) {
      return const PosReturnLinesResult.failed(
        'pos_return_custom_not_supported',
      );
    }
  }

  final totalByBucket = <String, int>{};
  final lineByBucket = <String, CartLine>{};
  for (final line in cartLines) {
    final productId = line.productId;
    if (productId == null || productId.isEmpty) {
      return const PosReturnLinesResult.failed('error_return_line_invalid');
    }
    final qtyScaled = posScaled(line.quantity);
    if (qtyScaled == null || qtyScaled <= 0) {
      return const PosReturnLinesResult.failed('invalid_qty');
    }
    final baseScaled = posRequestedBaseScaled(
      quantity: line.quantity,
      unitMultiplier: line.unitMultiplier,
    );
    if (baseScaled == null || baseScaled <= 0) {
      return const PosReturnLinesResult.failed('invalid_qty');
    }
    final bucket = '$productId|${line.variantId ?? ''}';
    totalByBucket[bucket] = (totalByBucket[bucket] ?? 0) + baseScaled;
    lineByBucket[bucket] = line;
  }

  final lines = <PosReturnLine>[];
  for (final entry in totalByBucket.entries) {
    final source = lineByBucket[entry.key]!;
    final variantId = source.variantId;
    lines.add(
      PosReturnLine(
        productId: source.productId!,
        variantId:
            (variantId == null || variantId.isEmpty) ? null : variantId,
        quantity: posScaledText(entry.value),
      ),
    );
  }
  return PosReturnLinesResult.ok(lines);
}
