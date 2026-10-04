// POS cart / checkout / holds / favorites models (Phase 8 Step 3).
//
// Server remains authoritative for prices, stock, and totals. Client
// models only hold display state and the request payload shape.
import '../../core/strings.dart';

/// Payment methods accepted by POST /api/v1/sales.
enum PaymentMethod {
  cash('cash'),
  card('card'),
  partial('partial'),
  credit('credit');

  final String apiValue;
  const PaymentMethod(this.apiValue);

  bool get requiresCustomer => this == PaymentMethod.partial || this == PaymentMethod.credit;
}

/// One cart line (client-side). ids are UUID strings from the API.
///
/// Phase 10: a line is EITHER a product line (`productId` set, `packId`
/// null) OR a pack line (`packId` set, `productId` null) — the same
/// mutual exclusion the sale API enforces on `items[]`.
class CartLine {
  final String? productId;
  final String? variantId;
  final String? sellingUnitId;
  final String? packId;
  final String name;
  final String? variantName;
  final String? unitName;
  final String quantity;
  final String unitPrice;
  final String lineDiscount;
  final String? barcode;
  final String? availableStock;
  final String productUnit;

  /// Snapshot of the pack's component list at add-to-cart time —
  /// display only (what the cashier is bundling), never sent to checkout.
  final String? componentsSummary;

  /// Snapshot of the base-unit catalog price at add-to-cart time
  /// (product or variant configured price). Informational only —
  /// never used for totals.
  final String? baseUnitPrice;

  /// Snapshot of the selected selling unit's multiplier (base units per
  /// selling unit), e.g. '10' for Box = 10 Piece. Null when no selling
  /// unit was chosen (direct base add).
  final String? unitMultiplier;

  /// Line identity (const-cached at construction): the cart's O(n)
  /// `indexWhere` in `PosCartNotifier.addLine` reads it once per existing
  /// line, so rebuilding the 3-part string on every access made building a
  /// 10 000 line cart quadratic (measured 14.9 s). Value semantics are
  /// unchanged — same string the getter used to produce.
  final String key;

  const CartLine({
    this.productId,
    this.variantId,
    this.sellingUnitId,
    this.packId,
    required this.name,
    this.variantName,
    this.unitName,
    this.quantity = '1',
    this.unitPrice = '0',
    this.lineDiscount = '0',
    this.barcode,
    this.availableStock,
    this.productUnit = 'piece',
    this.componentsSummary,
    this.baseUnitPrice,
    this.unitMultiplier,
  }) : key = packId != null
            ? 'pack:$packId'
            : '${productId ?? ''}|${variantId ?? ''}|${sellingUnitId ?? ''}';

  /// Pack lines never share a key with product lines (Phase 10): a pack
  /// and its component product stay two independent cart lines.
  bool get isPack => packId != null;

  double get qty => double.tryParse(quantity) ?? 0;
  double get price => double.tryParse(unitPrice) ?? 0;
  double get discountAmount => double.tryParse(lineDiscount) ?? 0;

  /// Gross line amount before line discount (display only).
  double get lineTotal => (qty * price) - discountAmount;

  CartLine copyWith({
    String? quantity,
    String? unitPrice,
    String? lineDiscount,
    String? availableStock,
    String? name,
  }) {
    return CartLine(
      productId: productId,
      variantId: variantId,
      sellingUnitId: sellingUnitId,
      packId: packId,
      name: name ?? this.name,
      variantName: variantName,
      unitName: unitName,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      lineDiscount: lineDiscount ?? this.lineDiscount,
      barcode: barcode,
      availableStock: availableStock ?? this.availableStock,
      productUnit: productUnit,
      componentsSummary: componentsSummary,
      baseUnitPrice: baseUnitPrice,
      unitMultiplier: unitMultiplier,
    );
  }

  /// Full UI snapshot for holds — `POST /api/v1/pos/holds` items and
  /// `pos_holds.cart_snapshot` (FIX #10B). Reconstructs the visual cart
  /// with NO catalog lookup: product/unit/variant names, base-unit price
  /// and multiplier are stored inline (null when a field does not apply).
  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'variant_id': variantId,
        'selling_unit_id': sellingUnitId,
        'pack_id': packId,
        'product_name': name,
        'variant_name': variantName,
        'unit_name': unitName,
        'product_unit': productUnit,
        'quantity': quantity,
        'unit_price': unitPrice,
        'line_discount': lineDiscount,
        'components_summary': componentsSummary,
        'base_unit_price': baseUnitPrice,
        'unit_multiplier': unitMultiplier,
        'available_stock': availableStock,
        'barcode': barcode,
      };

  /// Checkout payload for `POST /api/v1/sales` — fixed API contract.
  /// Display fields (product_name, unit_name, base_unit_price,
  /// unit_multiplier, components_summary, …) are intentionally NOT part of
  /// the sale payload; they only live in the hold snapshot [toJson].
  Map<String, dynamic> toSaleJson() => {
        if (productId != null) 'product_id': productId,
        if (packId != null) 'pack_id': packId,
        if (variantId != null) 'variant_id': variantId,
        if (sellingUnitId != null) 'selling_unit_id': sellingUnitId,
        'quantity': quantity,
        'unit_price': unitPrice,
        'line_discount': lineDiscount,
        if (barcode != null) 'barcode': barcode,
      };

  factory CartLine.fromJson(Map<String, dynamic> json) {
    return CartLine(
      productId: json['product_id'] as String?,
      variantId: json['variant_id'] as String?,
      sellingUnitId: json['selling_unit_id'] as String?,
      packId: json['pack_id'] as String?,
      name: (json['product_name'] as String?) ??
          (json['name'] as String?) ??
          '',
      variantName: json['variant_name'] as String?,
      unitName: json['unit_name'] as String?,
      quantity: '${json['quantity'] ?? 1}',
      unitPrice: '${json['unit_price'] ?? 0}',
      lineDiscount: '${json['line_discount'] ?? 0}',
      barcode: json['barcode'] as String?,
      availableStock: json['available_stock']?.toString(),
      productUnit: json['product_unit'] as String? ?? 'piece',
      componentsSummary: json['components_summary'] as String?,
      baseUnitPrice: json['base_unit_price']?.toString(),
      unitMultiplier: json['unit_multiplier']?.toString(),
    );
  }
}

/// Customer summary for the POS picker (minimal Phase 3 endpoint).
class PosCustomer {
  final String id;
  final String name;
  final String? phone;
  final double balance;
  final bool isArchived;

  const PosCustomer({
    required this.id,
    required this.name,
    this.phone,
    this.balance = 0,
    this.isArchived = false,
  });

  factory PosCustomer.fromJson(Map<String, dynamic> json) {
    return PosCustomer(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String?,
      balance: double.tryParse('${json['balance'] ?? 0}') ?? 0,
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

/// Server hold snapshot (POST/GET /api/v1/pos/holds).
class HoldModel {
  final String id;
  final String? deviceId;
  final String? customerId;
  final String? note;
  final String invoiceDiscount;
  final DateTime createdAt;
  final List<CartLine> items;

  const HoldModel({
    required this.id,
    this.deviceId,
    this.customerId,
    this.note,
    this.invoiceDiscount = '0',
    required this.createdAt,
    this.items = const [],
  });

  factory HoldModel.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List<dynamic>? ?? const [])
        .map((e) => CartLine.fromJson(e as Map<String, dynamic>))
        .toList();
    return HoldModel(
      id: json['id'] as String,
      deviceId: json['device_id'] as String?,
      customerId: json['customer_id'] as String?,
      note: json['note'] as String?,
      invoiceDiscount: '${json['invoice_discount'] ?? 0}',
      createdAt: DateTime.tryParse('${json['created_at']}') ?? DateTime.now(),
      items: items,
    );
  }
}

/// Favorite product pin for quick-add.
class FavoriteModel {
  final String id;
  final String productId;
  final String? productName;
  final String? barcode;
  final String? price;
  final String? quantity;

  const FavoriteModel({
    required this.id,
    required this.productId,
    this.productName,
    this.barcode,
    this.price,
    this.quantity,
  });

  factory FavoriteModel.fromJson(Map<String, dynamic> json) {
    return FavoriteModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      productName: json['product_name'] as String?,
      barcode: json['barcode'] as String?,
      price: json['price']?.toString(),
      quantity: json['quantity']?.toString(),
    );
  }
}

/// Server-side unit price correction reported after checkout.
///
/// Exactly one of `product_id` / `pack_id` is set (Phase 10 GATE 6), and
/// `lineIndex` addresses the request `items[]` position. [identity] keys
/// the override rows regardless of which kind of line was corrected;
/// `productName` is filled client-side from the cart line before clear
/// (backend sends ids only).
class PriceOverrideModel {
  final int lineIndex;
  final String? productId;
  final String? packId;
  final String requestedUnitPrice;
  final String appliedUnitPrice;
  final String? productName;

  const PriceOverrideModel({
    required this.lineIndex,
    this.productId,
    this.packId,
    required this.requestedUnitPrice,
    required this.appliedUnitPrice,
    this.productName,
  });

  /// Stable identity for widget keys and cart-name lookup.
  String get identity => packId != null ? 'pack:$packId' : productId ?? '';

  factory PriceOverrideModel.fromJson(Map<String, dynamic> json) {
    return PriceOverrideModel(
      lineIndex: json['line_index'] as int? ?? 0,
      productId: json['product_id'] as String?,
      packId: json['pack_id'] as String?,
      requestedUnitPrice: '${json['requested_unit_price'] ?? 0}',
      appliedUnitPrice: '${json['applied_unit_price'] ?? 0}',
      productName: json['product_name'] as String?,
    );
  }

  PriceOverrideModel withProductName(String name) => PriceOverrideModel(
        lineIndex: lineIndex,
        productId: productId,
        packId: packId,
        requestedUnitPrice: requestedUnitPrice,
        appliedUnitPrice: appliedUnitPrice,
        productName: name,
      );
}

/// Checkout success payload (SaleCreateResponse subset used by UI).
class CheckoutResult {
  final String id;
  final String invoiceNumber;
  final String status;
  final String subtotal;
  final String discount;
  final String total;
  final String paid;
  final String change;
  final String debt;
  final String paymentMethod;
  final bool idempotentReplay;
  final List<PriceOverrideModel> priceOverrides;

  const CheckoutResult({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    required this.change,
    required this.debt,
    required this.paymentMethod,
    this.idempotentReplay = false,
    this.priceOverrides = const [],
  });

  CheckoutResult withPriceOverrides(List<PriceOverrideModel> overrides) {
    return CheckoutResult(
      id: id,
      invoiceNumber: invoiceNumber,
      status: status,
      subtotal: subtotal,
      discount: discount,
      total: total,
      paid: paid,
      change: change,
      debt: debt,
      paymentMethod: paymentMethod,
      idempotentReplay: idempotentReplay,
      priceOverrides: overrides,
    );
  }

  factory CheckoutResult.fromJson(Map<String, dynamic> json) {
    return CheckoutResult(
      id: '${json['id']}',
      invoiceNumber: '${json['invoice_number'] ?? ''}',
      status: '${json['status'] ?? 'completed'}',
      subtotal: '${json['subtotal'] ?? 0}',
      discount: '${json['discount'] ?? 0}',
      total: '${json['total'] ?? 0}',
      paid: '${json['paid'] ?? 0}',
      change: '${json['change'] ?? 0}',
      debt: '${json['debt'] ?? 0}',
      paymentMethod: '${json['payment_method'] ?? 'cash'}',
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
      priceOverrides: (json['price_overrides'] as List<dynamic>? ?? const [])
          .map((e) => PriceOverrideModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Minimal sale history row for POS reprint.
///
/// UX FIX #12 — FIX #1: the row also carries a compact sold-units summary
/// (`2 Box · 48 Piece`) so the cashier sees what was sold without opening
/// Sale Detail. It is computed from [lines] (localized unit labels) with
/// the API's `unit_summary` as a fallback for payloads without lines.
class SaleHistoryItem {
  final String id;
  final String invoiceNumber;
  final String total;
  final String paid;
  final String paymentMethod;
  final String status;
  final DateTime saleDate;
  final String? customerId;
  final List<SaleHistoryLine> lines;
  final String? unitSummary;

  const SaleHistoryItem({
    required this.id,
    required this.invoiceNumber,
    required this.total,
    required this.paid,
    required this.paymentMethod,
    required this.status,
    required this.saleDate,
    this.customerId,
    this.lines = const [],
    this.unitSummary,
  });

  factory SaleHistoryItem.fromJson(Map<String, dynamic> json) {
    return SaleHistoryItem(
      id: '${json['id']}',
      invoiceNumber: '${json['invoice_number'] ?? ''}',
      total: '${json['total'] ?? 0}',
      paid: '${json['paid'] ?? 0}',
      paymentMethod: '${json['payment_method'] ?? 'cash'}',
      status: '${json['status'] ?? ''}',
      saleDate: DateTime.tryParse('${json['sale_date']}') ?? DateTime.now(),
      customerId: json['customer_id'] as String?,
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => SaleHistoryLine.fromJson(e as Map<String, dynamic>))
          .toList(),
      unitSummary: json['unit_summary'] as String?,
    );
  }

  /// `2 Box · 48 Piece` for the history row, grouped by sold unit in
  /// first-seen order (capped at three groups, then `+N`); null when the
  /// sale carries no unit information at all.
  String? unitSummaryText(String loc) {
    if (lines.isEmpty) return unitSummary;
    final order = <String>[];
    final totals = <String, double>{};
    for (final line in lines) {
      final label =
          AppStrings.unitLabel(line.sellingUnitName ?? line.productUnit, loc);
      if (label.isEmpty) continue;
      if (!totals.containsKey(label)) {
        order.add(label);
        totals[label] = 0;
      }
      totals[label] =
          (totals[label] ?? 0) + (double.tryParse(line.quantity) ?? 0);
    }
    if (order.isEmpty) return unitSummary;
    final groups = <String>[
      for (final label in order.take(3)) '${_qtyText(totals[label]!)} $label',
    ];
    var summary = groups.join(' · ');
    if (order.length > 3) summary = '$summary +${order.length - 3}';
    return summary;
  }

  static String _qtyText(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    var text = value.toStringAsFixed(6);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      if (text.endsWith('.')) text = text.substring(0, text.length - 1);
    }
    return text;
  }
}

/// Unit facts of one sale line — only what a history row needs
/// (quantity + which unit was sold). No prices: totals stay untouched.
class SaleHistoryLine {
  final String quantity;
  final String productUnit;
  final String? sellingUnitName;

  const SaleHistoryLine({
    required this.quantity,
    required this.productUnit,
    this.sellingUnitName,
  });

  factory SaleHistoryLine.fromJson(Map<String, dynamic> json) {
    return SaleHistoryLine(
      quantity: '${json['quantity'] ?? 0}',
      productUnit: '${json['product_unit'] ?? 'piece'}',
      sellingUnitName: json['selling_unit_name'] as String?,
    );
  }
}

/// One sale line (GET /api/v1/sales/{id} → SaleLineResponse).
///
/// Every field is historical (UX FIX #11): captured at checkout, never
/// re-read from the catalog. The three nullable display snapshots are
/// null for base-unit sales and for rows created before Phase 8.
class SaleDetailLine {
  final String id;
  final String productId;

  /// Phase 10 line shapes: product line (null), charged pack summary
  /// (pack id, product id empty), pack component (both set). Returns may
  /// only target the first two — a pack is returned whole (GATE 11).
  final String? packId;
  final String? variantId;
  final String productName;
  final String? productSku;
  final String? productBarcode;
  final String productUnit;
  final String? variantName;
  final String? sellingUnitName;
  final String? sellingUnitMultiplier;
  final String unitPrice;
  final String unitCost;
  final String quantity;
  final String lineDiscount;
  final String lineTotal;

  const SaleDetailLine({
    required this.id,
    required this.productId,
    this.packId,
    this.variantId,
    required this.productName,
    this.productSku,
    this.productBarcode,
    required this.productUnit,
    this.variantName,
    this.sellingUnitName,
    this.sellingUnitMultiplier,
    required this.unitPrice,
    required this.unitCost,
    required this.quantity,
    required this.lineDiscount,
    required this.lineTotal,
  });

  factory SaleDetailLine.fromJson(Map<String, dynamic> json) {
    return SaleDetailLine(
      id: '${json['id'] ?? ''}',
      productId: '${json['product_id'] ?? ''}',
      packId: json['pack_id'] as String?,
      variantId: json['variant_id'] as String?,
      productName: '${json['product_name'] ?? ''}',
      productSku: json['product_sku'] as String?,
      productBarcode: json['product_barcode'] as String?,
      productUnit: '${json['product_unit'] ?? 'piece'}',
      variantName: json['variant_name'] as String?,
      sellingUnitName: json['selling_unit_name'] as String?,
      sellingUnitMultiplier:
          json['selling_unit_multiplier']?.toString(),
      unitPrice: '${json['unit_price'] ?? 0}',
      unitCost: '${json['unit_cost'] ?? 0}',
      quantity: '${json['quantity'] ?? 0}',
      lineDiscount: '${json['line_discount'] ?? 0}',
      lineTotal: '${json['line_total'] ?? 0}',
    );
  }

  /// Base-unit quantity implied by a selling-unit line
  /// (quantity × stored multiplier) — null for base-unit sales.
  double? get baseQuantity {
    final multiplier = double.tryParse(sellingUnitMultiplier ?? '');
    final qty = double.tryParse(quantity);
    if (multiplier == null || qty == null) return null;
    return qty * multiplier;
  }
}

/// One payment row (GET /api/v1/sales/{id} → SalePaymentResponse).
class SalePayment {
  final String id;
  final String method;
  final String amount;

  const SalePayment({
    required this.id,
    required this.method,
    required this.amount,
  });

  factory SalePayment.fromJson(Map<String, dynamic> json) {
    return SalePayment(
      id: '${json['id'] ?? ''}',
      method: '${json['method'] ?? 'cash'}',
      amount: '${json['amount'] ?? 0}',
    );
  }
}

/// Full sale detail (GET /api/v1/sales/{id} → SaleResponse).
class SaleDetail {
  final String id;
  final String invoiceNumber;
  final String? customerId;
  final String status;
  final String subtotal;
  final String discount;
  final String total;
  final String paid;
  final String change;
  final String debt;
  final String paymentMethod;
  final String? deviceId;
  final String? note;
  final DateTime saleDate;

  /// Phase 12 void attribution (GATE 9): the totals above are NEVER
  /// rewritten — these three fields are the only trace of a void.
  final DateTime? voidedAt;
  final String? voidedBy;
  final String? voidReason;
  final List<SaleDetailLine> lines;
  final List<SalePayment> payments;

  const SaleDetail({
    required this.id,
    required this.invoiceNumber,
    this.customerId,
    required this.status,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    required this.change,
    required this.debt,
    required this.paymentMethod,
    this.deviceId,
    this.note,
    required this.saleDate,
    this.voidedAt,
    this.voidedBy,
    this.voidReason,
    this.lines = const [],
    this.payments = const [],
  });

  /// Terminal void state (GATE 1): a voided sale can never be voided or
  /// sold again, and it may no longer receive linked returns.
  bool get isVoided => voidedAt != null || status == 'void';

  factory SaleDetail.fromJson(Map<String, dynamic> json) {
    return SaleDetail(
      id: '${json['id'] ?? ''}',
      invoiceNumber: '${json['invoice_number'] ?? ''}',
      customerId: json['customer_id'] as String?,
      status: '${json['status'] ?? ''}',
      subtotal: '${json['subtotal'] ?? 0}',
      discount: '${json['discount'] ?? 0}',
      total: '${json['total'] ?? 0}',
      paid: '${json['paid'] ?? 0}',
      change: '${json['change'] ?? 0}',
      debt: '${json['debt'] ?? 0}',
      paymentMethod: '${json['payment_method'] ?? 'cash'}',
      deviceId: json['device_id'] as String?,
      note: json['note'] as String?,
      saleDate: DateTime.tryParse('${json['sale_date']}') ?? DateTime.now(),
      voidedAt: DateTime.tryParse('${json['voided_at']}'),
      voidedBy: json['voided_by'] as String?,
      voidReason: json['void_reason'] as String?,
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => SaleDetailLine.fromJson(e as Map<String, dynamic>))
          .toList(),
      payments: (json['payments'] as List<dynamic>? ?? const [])
          .map((e) => SalePayment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Client-side cart totals for display (server recomputes on checkout).
class CartTotals {
  final double subtotal;
  final double invoiceDiscount;
  final double total;
  final int lineCount;

  const CartTotals({
    this.subtotal = 0,
    this.invoiceDiscount = 0,
    this.total = 0,
    this.lineCount = 0,
  });

  String get subtotalDisplay => subtotal.toStringAsFixed(2);
  String get totalDisplay => total.toStringAsFixed(2);
  String get invoiceDiscountDisplay => invoiceDiscount.toStringAsFixed(2);
}

/// Payment math helpers (pure — unit tested).
class PaymentMath {
  const PaymentMath._();

  static double parse(String raw) => double.tryParse(raw.trim()) ?? 0;

  static String money(double value) => value.toStringAsFixed(2);

  static double changeOf({required double paid, required double total}) {
    final delta = paid - total;
    return delta > 0 ? delta : 0;
  }

  static double debtOf({required double paid, required double total}) {
    final delta = total - paid;
    return delta > 0 ? delta : 0;
  }

  /// Returns null when valid, else a machine key for the error message.
  static String? validate({
    required PaymentMethod method,
    required double total,
    required double paid,
    required bool hasCustomer,
    required bool canDiscount,
    required bool canCredit,
  }) {
    if (total <= 0) return 'empty_cart_title';
    if (!canDiscount) {
      // Discounts are only rejected when actually present on the cart;
      // callers pass canDiscount=false together with hasAnyDiscount state.
    }
    switch (method) {
      case PaymentMethod.cash:
        if (paid + 1e-9 < total) return 'paid_too_low';
        return null;
      case PaymentMethod.card:
        if ((paid - total).abs() > 0.01) return 'invalid_amount';
        return null;
      case PaymentMethod.partial:
        if (!hasCustomer) return 'customer_required';
        if (!canCredit) return 'permission_credit';
        if (paid <= 0 || paid + 1e-9 >= total) return 'invalid_amount';
        return null;
      case PaymentMethod.credit:
        if (!hasCustomer) return 'customer_required';
        if (!canCredit) return 'permission_credit';
        if (paid.abs() > 0.01) return 'invalid_amount';
        return null;
    }
  }
}
