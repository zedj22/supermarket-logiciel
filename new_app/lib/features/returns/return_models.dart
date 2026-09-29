// Phase 12 return / void models.
//
// Money and quantity always arrive as decimal STRINGS (Phase 0 money
// rule) and stay strings end to end: the server prices every return line
// from the persisted sale economics, so the client only renders what the
// API returned — it never recomputes a refund.
import '../pos/pos_models.dart';

/// Reason codes accepted by `POST /api/v1/returns` (backend literal list).
const List<String> kReturnReasons = <String>[
  'defective',
  'wrong_item',
  'customer_change',
  'expired',
  'other',
];

/// Localization key for a reason code (`return_reason_<code>`).
String returnReasonKey(String reason) => 'return_reason_$reason';

/// One persisted return line with its historical snapshots.
class ReturnLine {
  final String id;
  final String? saleLineId;
  final String? productId;
  final String? packId;
  final String? variantId;
  final String productName;
  final String productUnit;
  final String? variantName;
  final String? sellingUnitName;
  final String? sellingUnitMultiplier;
  final String unitPrice;
  final String quantity;
  final String? quantityBase;
  final String lineDiscount;
  final String lineTotal;

  const ReturnLine({
    required this.id,
    this.saleLineId,
    this.productId,
    this.packId,
    this.variantId,
    required this.productName,
    required this.productUnit,
    this.variantName,
    this.sellingUnitName,
    this.sellingUnitMultiplier,
    required this.unitPrice,
    required this.quantity,
    this.quantityBase,
    required this.lineDiscount,
    required this.lineTotal,
  });

  factory ReturnLine.fromJson(Map<String, dynamic> json) {
    return ReturnLine(
      id: '${json['id'] ?? ''}',
      saleLineId: json['sale_line_id'] as String?,
      productId: json['product_id'] as String?,
      packId: json['pack_id'] as String?,
      variantId: json['variant_id'] as String?,
      productName: '${json['product_name'] ?? ''}',
      productUnit: '${json['product_unit'] ?? 'piece'}',
      variantName: json['variant_name'] as String?,
      sellingUnitName: json['selling_unit_name'] as String?,
      sellingUnitMultiplier: json['selling_unit_multiplier']?.toString(),
      unitPrice: '${json['unit_price'] ?? 0}',
      quantity: '${json['quantity'] ?? 0}',
      quantityBase: json['quantity_base']?.toString(),
      lineDiscount: '${json['line_discount'] ?? 0}',
      lineTotal: '${json['line_total'] ?? 0}',
    );
  }

  /// A return line restores a whole pack when it carries a pack target.
  bool get isPack => packId != null && packId!.isNotEmpty;

  /// Base-unit quantity actually restored (falls back to `quantity`).
  double? get baseQuantity {
    final raw = quantityBase ?? quantity;
    return double.tryParse(raw);
  }
}

/// A posted return document (header + lines).
class ReturnDoc {
  final String id;
  final String returnNumber;
  final String? saleId;
  final String? invoiceNumber;
  final String? customerId;
  final String? userId;
  final String reason;
  final String subtotal;
  final String discount;
  final String total;
  final String? note;
  final String? deviceId;
  final String? clientRequestId;
  final DateTime returnDate;
  final List<ReturnLine> lines;

  const ReturnDoc({
    required this.id,
    required this.returnNumber,
    this.saleId,
    this.invoiceNumber,
    this.customerId,
    this.userId,
    required this.reason,
    required this.subtotal,
    required this.discount,
    required this.total,
    this.note,
    this.deviceId,
    this.clientRequestId,
    required this.returnDate,
    this.lines = const [],
  });

  factory ReturnDoc.fromJson(Map<String, dynamic> json) {
    return ReturnDoc(
      id: '${json['id'] ?? ''}',
      returnNumber: '${json['return_number'] ?? ''}',
      saleId: json['sale_id'] as String?,
      invoiceNumber: json['invoice_number'] as String?,
      customerId: json['customer_id'] as String?,
      userId: json['user_id'] as String?,
      reason: '${json['reason'] ?? ''}',
      subtotal: '${json['subtotal'] ?? 0}',
      discount: '${json['discount'] ?? 0}',
      total: '${json['total'] ?? 0}',
      note: json['note'] as String?,
      deviceId: json['device_id'] as String?,
      clientRequestId: json['client_request_id'] as String?,
      returnDate:
          DateTime.tryParse('${json['return_date']}') ?? DateTime.now(),
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => ReturnLine.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Linked return (refunds valued from the sale) vs independent return.
  bool get isLinked => saleId != null && saleId!.isNotEmpty;
}

/// Minimal product row for the independent-return search (current price
/// is what the server will refund — GATE 5 only freezes price for LINKED
/// returns, where the sale's own economics decide).
class ReturnProductCandidate {
  final String id;
  final String name;
  final String unit;
  final String price;
  final String quantity;
  final String barcode;

  const ReturnProductCandidate({
    required this.id,
    required this.name,
    required this.unit,
    required this.price,
    required this.quantity,
    this.barcode = '',
  });

  factory ReturnProductCandidate.fromJson(Map<String, dynamic> json) {
    return ReturnProductCandidate(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      unit: '${json['unit'] ?? 'piece'}',
      price: '${json['price'] ?? 0}',
      quantity: '${json['quantity'] ?? 0}',
      barcode: '${json['barcode'] ?? ''}',
    );
  }
}

/// Resolved `GET /api/v1/products/barcode-lookup` hit for the Return
/// Products scan flow. The backend resolves selling unit → variant →
/// product, so a variant barcode keeps its `variantId` and the return
/// restores the VARIANT only (Phase 8/12 variant-only stock rule).
class ReturnBarcodeHit {
  final bool found;
  final String kind; // 'product' | 'variant' | 'selling_unit'
  final String? productId;
  final String productName;
  final String? variantId;
  final String? variantName;
  final String unit;
  final bool isArchived;

  const ReturnBarcodeHit({
    required this.found,
    required this.kind,
    this.productId,
    this.productName = '',
    this.variantId,
    this.variantName,
    this.unit = 'piece',
    this.isArchived = false,
  });

  /// Variant barcodes return the variant; everything else targets the
  /// product itself.
  String? get returnVariantId => kind == 'variant' ? variantId : null;

  String get displayName =>
      (variantName != null && variantName!.isNotEmpty)
          ? '$productName ($variantName)'
          : productName;

  factory ReturnBarcodeHit.fromJson(Map<String, dynamic> json) {
    return ReturnBarcodeHit(
      found: json['found'] as bool? ?? false,
      kind: '${json['kind'] ?? ''}',
      productId: json['product_id'] as String?,
      productName: '${json['product_name'] ?? ''}',
      variantId: json['variant_id'] as String?,
      variantName: json['variant_name'] as String?,
      unit: '${json['product_unit'] ?? 'piece'}',
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

/// One page of `GET /api/v1/returns`.
class ReturnListPage {
  final List<ReturnDoc> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const ReturnListPage({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 20,
    this.pages = 1,
  });

  factory ReturnListPage.fromJson(Map<String, dynamic> json) {
    return ReturnListPage(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => ReturnDoc.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      pageSize: json['page_size'] as int? ?? 20,
      pages: json['pages'] as int? ?? 1,
    );
  }
}

/// `POST /api/v1/returns` → 201 body.
class ReturnCreateResult {
  final ReturnDoc doc;
  final bool idempotentReplay;
  final String refundTotal;
  final String creditReversed;
  final String cashPending;

  const ReturnCreateResult({
    required this.doc,
    required this.idempotentReplay,
    required this.refundTotal,
    required this.creditReversed,
    required this.cashPending,
  });

  factory ReturnCreateResult.fromJson(Map<String, dynamic> json) {
    return ReturnCreateResult(
      doc: ReturnDoc.fromJson(
        (json['return'] as Map<String, dynamic>? ?? const {}),
      ),
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
      refundTotal: '${json['refund_total'] ?? 0}',
      creditReversed: '${json['credit_reversed'] ?? 0}',
      cashPending: '${json['cash_pending'] ?? 0}',
    );
  }
}

/// `POST /api/v1/sales/{id}/void` → 200 body.
///
/// The sale snapshot is never rewritten (GATE 9): the returned [sale]
/// keeps its original totals, it only gains the void attribution.
class VoidResult {
  final SaleDetail sale;
  final String creditReversed;
  final String refundDue;
  final String cashPending;

  const VoidResult({
    required this.sale,
    required this.creditReversed,
    required this.refundDue,
    required this.cashPending,
  });

  factory VoidResult.fromJson(Map<String, dynamic> json) {
    return VoidResult(
      sale: SaleDetail.fromJson(
        json['sale'] as Map<String, dynamic>? ?? const {},
      ),
      creditReversed: '${json['credit_reversed'] ?? 0}',
      refundDue: '${json['refund_due'] ?? 0}',
      cashPending: '${json['cash_pending'] ?? 0}',
    );
  }
}
