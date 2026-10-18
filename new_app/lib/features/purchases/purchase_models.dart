/// Purchase document models (Phase 11).
///
/// Money and quantity fields are decimal STRINGS (never doubles).
/// Exact 3-decimal helpers are re-exported from the Phase 9 client
/// models — same semantics.
///
/// Document semantics (decision record GATE 4/5):
/// - line.quantity = document units (packages when purchase_unit_id is
///   set, otherwise base units)
/// - line.unit_cost = cost per document unit
/// - line_total = quantity × unit_cost
/// - subtotal = Σ line_total, total = subtotal − discount, paid settled
///   at receipt. Flutter NEVER computes PMP — totals here are display
///   arithmetic only; all valuation comes from the server.
library;

import '../clients/customer_models.dart' show milliToMoney, moneyToMilli;

export '../clients/customer_models.dart'
    show formatMoney, formatMoneyPlain, moneyToMilli, milliToMoney;

/// Backend `purchase_status` values (Phase 11 lifecycle).
abstract final class PurchaseStatusValue {
  static const String draft = 'draft';
  static const String received = 'received';
  static const String cancelled = 'cancelled';
}

/// One purchase line with historical snapshots (GATE 15).
class PurchaseLineModel {
  final String id;
  final String productId;
  final String? variantId;
  final String productName;
  final String? productSku;
  final String? productBarcode;
  final String productUnit;
  final String? purchaseUnitId;
  final String? purchaseUnitName;

  /// Document-unit multiplier (`null` for loose/base lines).
  final String? unitMultiplier;
  final String quantity;
  final String unitCost;
  final String? baseQtyEquivalent;
  final String lineTotal;

  const PurchaseLineModel({
    required this.id,
    required this.productId,
    this.variantId,
    required this.productName,
    this.productSku,
    this.productBarcode,
    required this.productUnit,
    this.purchaseUnitId,
    this.purchaseUnitName,
    this.unitMultiplier,
    required this.quantity,
    required this.unitCost,
    this.baseQtyEquivalent,
    required this.lineTotal,
  });

  factory PurchaseLineModel.fromJson(Map<String, dynamic> json) {
    return PurchaseLineModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      variantId: json['variant_id'] as String?,
      productName: json['product_name'] as String? ?? '',
      productSku: json['product_sku'] as String?,
      productBarcode: json['product_barcode'] as String?,
      productUnit: json['product_unit'] as String? ?? 'piece',
      purchaseUnitId: json['purchase_unit_id'] as String?,
      purchaseUnitName: json['purchase_unit_name'] as String?,
      unitMultiplier: json['unit_multiplier']?.toString(),
      quantity: '${json['quantity'] ?? 0}',
      unitCost: '${json['unit_cost'] ?? 0}',
      baseQtyEquivalent: json['base_qty_equivalent']?.toString(),
      lineTotal: '${json['line_total'] ?? 0}',
    );
  }
}

/// Purchase header as returned by the API.
class PurchaseModel {
  final String id;
  final String invoiceNumber;

  /// `draft` | `received` | `cancelled`.
  final String status;

  /// Supplier link — null/empty means "no supplier" (optional supplier).
  final String? supplierId;
  final String? supplierName;
  final String? userId;
  final String subtotal;
  final String discount;
  final String total;
  final String paid;
  final String? note;
  final String? deviceId;
  final String? clientRequestId;
  final DateTime? purchaseDate;
  final DateTime? receivedAt;
  final DateTime? cancelledAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<PurchaseLineModel> lines;
  final bool idempotentReplay;

  const PurchaseModel({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    this.supplierId,
    this.supplierName,
    this.userId,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    this.note,
    this.deviceId,
    this.clientRequestId,
    this.purchaseDate,
    this.receivedAt,
    this.cancelledAt,
    this.createdAt,
    this.updatedAt,
    this.lines = const [],
    this.idempotentReplay = false,
  });

  factory PurchaseModel.fromJson(Map<String, dynamic> json) {
    // Normalize: legacy payloads used '' for "no supplier" (the field
    // used to be non-nullable) — both null and '' mean "no supplier".
    final rawSupplierId = json['supplier_id'] as String?;
    final supplierId =
        rawSupplierId == null || rawSupplierId.isEmpty ? null : rawSupplierId;
    return PurchaseModel(
      id: json['id'] as String,
      invoiceNumber: json['invoice_number'] as String? ?? '',
      status: json['status'] as String? ?? PurchaseStatusValue.draft,
      supplierId: supplierId,
      supplierName: json['supplier_name'] as String?,
      userId: json['user_id'] as String?,
      subtotal: '${json['subtotal'] ?? 0}',
      discount: '${json['discount'] ?? 0}',
      total: '${json['total'] ?? 0}',
      paid: '${json['paid'] ?? 0}',
      note: json['note'] as String?,
      deviceId: json['device_id'] as String?,
      clientRequestId: json['client_request_id'] as String?,
      purchaseDate: DateTime.tryParse('${json['purchase_date'] ?? ''}'),
      receivedAt: DateTime.tryParse('${json['received_at'] ?? ''}'),
      cancelledAt: DateTime.tryParse('${json['cancelled_at'] ?? ''}'),
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => PurchaseLineModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
    );
  }

  bool get isDraft => status == PurchaseStatusValue.draft;
  bool get isReceived => status == PurchaseStatusValue.received;
  bool get isCancelled => status == PurchaseStatusValue.cancelled;

  /// Display-only outstanding amount (`total - paid`, clamped at 0).
  /// Document arithmetic — the server is authoritative on receive.
  int get unpaidMilli {
    final t = moneyToMilli(total) ?? 0;
    final p = moneyToMilli(paid) ?? 0;
    return t > p ? t - p : 0;
  }

  String get unpaid => milliToMoney(unpaidMilli);
}

/// Local draft line staged inside the purchase editor dialog.
///
/// Quantity/cost stay as raw text until submit; money math uses the
/// exact milli helpers only (display totals, never PMP).
class DraftLine {
  final String productId;
  final String productName;
  final String? variantId;
  final String? variantName;
  final String? purchaseUnitId;
  final String? purchaseUnitName;

  /// Multiplier of the selected purchase unit (`null` = base units).
  final String? multiplier;
  final String quantity;
  final String unitCost;

  const DraftLine({
    required this.productId,
    required this.productName,
    this.variantId,
    this.variantName,
    this.purchaseUnitId,
    this.purchaseUnitName,
    this.multiplier,
    required this.quantity,
    required this.unitCost,
  });

  DraftLine copyWith({
    String? productId,
    String? productName,
    String? variantId,
    String? variantName,
    String? purchaseUnitId,
    String? purchaseUnitName,
    String? multiplier,
    String? quantity,
    String? unitCost,
    bool clearVariant = false,
    bool clearPurchaseUnit = false,
  }) {
    return DraftLine(
      productId: productId ?? this.productId,
      productName: productName ?? this.productName,
      variantId: clearVariant ? null : (variantId ?? this.variantId),
      variantName: clearVariant ? null : (variantName ?? this.variantName),
      purchaseUnitId:
          clearPurchaseUnit ? null : (purchaseUnitId ?? this.purchaseUnitId),
      purchaseUnitName:
          clearPurchaseUnit ? null : (purchaseUnitName ?? this.purchaseUnitName),
      multiplier: clearPurchaseUnit ? null : (multiplier ?? this.multiplier),
      quantity: quantity ?? this.quantity,
      unitCost: unitCost ?? this.unitCost,
    );
  }

  /// Display-only line total: (qty×1000 × cost×1000) / 1000 in
  /// thousandths — integer math, rounded half-up, no floats.
  int get lineTotalMilli {
    final q = qtyToMilli(quantity);
    final c = moneyToMilli(unitCost);
    if (q == null || c == null) return 0;
    final raw = q * c; // 10^-6 units
    return (raw + 500) ~/ 1000; // back to 10^-3, half-up
  }

  String get lineTotal => milliToMoney(lineTotalMilli);

  String? get labelForDisplay {
    final parts = <String>[productName];
    if (variantName != null && variantName!.isNotEmpty) {
      parts.add(variantName!);
    }
    if (purchaseUnitName != null && purchaseUnitName!.isNotEmpty) {
      parts.add(purchaseUnitName!);
    }
    return parts.join(' · ');
  }

  Map<String, dynamic> toPayload() {
    return {
      'product_id': productId,
      if (variantId != null) 'variant_id': variantId,
      if (purchaseUnitId != null) 'purchase_unit_id': purchaseUnitId,
      'quantity': quantity.trim(),
      'unit_cost': unitCost.trim(),
    };
  }
}

/// Effective cost per DOCUMENT unit in thousandths.
///
/// Total-cost mode off: the entered cost IS the per-document-unit cost
/// (existing behavior, returned unchanged). On: the entered cost is the
/// TOTAL for the entered [quantity], so the per-unit cost is derived —
/// total ÷ qty, integer half-up to thousandths. Returns null when the
/// cost is unparsable, or when the derivation would divide by a
/// missing/non-positive quantity (division by zero never happens).
int? effectiveUnitCostMilli({
  required String quantity,
  required String cost,
  required bool totalCostMode,
}) {
  final c = moneyToMilli(cost);
  if (c == null) return null;
  if (!totalCostMode) return c;
  final q = qtyToMilli(quantity);
  if (q == null || q <= 0) return null;
  return (c * 1000 + q ~/ 2) ~/ q;
}

/// Document quantity expressed in BASE units: qty × multiplier,
/// integer half-up to thousandths. A null/empty multiplier means the
/// line already is in base units, so the quantity passes through
/// unchanged. Null when the quantity (or a provided multiplier) is
/// unparsable or non-positive.
int? baseQtyEquivalentMilli(String quantity, String? multiplier) {
  final q = qtyToMilli(quantity);
  if (q == null) return null;
  if (multiplier == null || multiplier.trim().isEmpty) return q;
  final m = moneyToMilli(multiplier);
  if (m == null || m <= 0) return null;
  return (q * m + 500) ~/ 1000;
}

/// BASE-unit cost from a per-DOCUMENT-unit cost: cost ÷ multiplier,
/// integer half-up to thousandths — the same convention the server
/// uses in `base_unit_cost_from_package`. A null/empty multiplier means
/// the line already is in base units, so the cost passes through.
int? baseUnitCostMilli(int? unitCostMilli, String? multiplier) {
  if (unitCostMilli == null) return null;
  if (multiplier == null || multiplier.trim().isEmpty) return unitCostMilli;
  final m = moneyToMilli(multiplier);
  if (m == null || m <= 0) return null;
  return (unitCostMilli * 1000 + m ~/ 2) ~/ m;
}

final RegExp _qtyPattern = RegExp(r'^(\d+)(?:\.(\d{1,3}))?$');

/// Quantity in thousandths (same shape as moneyToMilli, separate regex
/// so callers stay explicit about units). Null for empty, negative, or
/// more-than-3-decimal input — the backend is authoritative.
int? qtyToMilli(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final match = _qtyPattern.firstMatch(value);
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null) return null;
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  final frac = int.tryParse(fraction);
  if (frac == null) return null;
  return whole * 1000 + frac;
}

/// True when [raw] is a whole number (no fractional part) — required
/// for purchase-unit (package) lines.
bool isWholeQty(String raw) {
  final milli = qtyToMilli(raw.trim());
  return milli != null && milli % 1000 == 0;
}
