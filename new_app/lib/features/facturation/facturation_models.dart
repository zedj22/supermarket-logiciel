/// Facturation document + invoice-client models (Phase 8).
///
/// Money and quantity fields are decimal STRINGS (never doubles).
/// Exact 3-decimal helpers are re-exported from the Phase 9 client
/// models — same semantics.
///
/// Fiscal totals (HT / TVA / TTC / timbre / net à payer) are SERVER-
/// authoritative: Flutter only does display arithmetic via integer
/// milli math, never float, and the preview endpoint is the source of
/// truth before create.
library;

import '../clients/customer_models.dart' show milliToMoney, moneyToMilli;

export '../clients/customer_models.dart'
    show formatMoney, moneyToMilli, milliToMoney;

/// Backend `doc_type` values (Phase 1 domain membership).
abstract final class DocTypeValue {
  static const String fac = 'FAC';
  static const String dev = 'DEV';
  static const String pro = 'PRO';
  static const String bc = 'BC';
  static const String bl = 'BL';
  static const List<String> all = [fac, dev, pro, bc, bl];
}

/// Backend `payment_method` values (Phase 1 domain membership).
abstract final class PaymentMethodValue {
  static const String cash = 'cash';
  static const String transfer = 'transfer';
  static const String cheque = 'cheque';
  static const List<String> all = [cash, transfer, cheque];
}

/// Allowed TVA rates (Phase 1 domain membership {0, 9, 19}).
const List<int> kTvaRates = [0, 9, 19];

/// Invoice (fiscal) client — separate domain from POS Customer.
class InvoiceClientModel {
  final String id;
  final String name;
  final String? address;
  final String? wilaya;
  final String? phone;
  final String? nif;
  final String? rc;
  final String? ai;
  final String? nis;
  final bool isArchived;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const InvoiceClientModel({
    required this.id,
    required this.name,
    this.address,
    this.wilaya,
    this.phone,
    this.nif,
    this.rc,
    this.ai,
    this.nis,
    this.isArchived = false,
    this.createdAt,
    this.updatedAt,
  });

  factory InvoiceClientModel.fromJson(Map<String, dynamic> json) {
    return InvoiceClientModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      address: json['address'] as String?,
      wilaya: json['wilaya'] as String?,
      phone: json['phone'] as String?,
      nif: json['nif'] as String?,
      rc: json['rc'] as String?,
      ai: json['ai'] as String?,
      nis: json['nis'] as String?,
      isArchived: json['is_archived'] as bool? ?? false,
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }
}

/// One persisted invoice line (snapshot + Phase 1 line totals).
class InvoiceLineModel {
  final String id;
  final String? productId;

  /// Stage 3A option identity — nullable traceability links (the
  /// backend stores them SET NULL; description + price snapshots stay
  /// the printable truth).
  final String? variantId;
  final String? sellingUnitId;
  final String? packId;

  final String description;
  final String quantity;
  final String unitPriceHt;
  final String tvaRate;
  final String discountPct;
  final int position;
  final String totalHt;
  final String totalTva;

  const InvoiceLineModel({
    required this.id,
    this.productId,
    this.variantId,
    this.sellingUnitId,
    this.packId,
    required this.description,
    required this.quantity,
    required this.unitPriceHt,
    required this.tvaRate,
    required this.discountPct,
    required this.position,
    required this.totalHt,
    required this.totalTva,
  });

  factory InvoiceLineModel.fromJson(Map<String, dynamic> json) {
    return InvoiceLineModel(
      id: json['id'] as String,
      productId: json['product_id'] as String?,
      variantId: json['variant_id'] as String?,
      sellingUnitId: json['selling_unit_id'] as String?,
      packId: json['pack_id'] as String?,
      description: json['description'] as String? ?? '',
      quantity: '${json['quantity'] ?? 0}',
      unitPriceHt: '${json['unit_price_ht'] ?? 0}',
      tvaRate: '${json['tva_rate'] ?? 0}',
      discountPct: '${json['discount_pct'] ?? 0}',
      position: json['position'] as int? ?? 0,
      totalHt: '${json['total_ht'] ?? 0}',
      totalTva: '${json['total_tva'] ?? 0}',
    );
  }
}

/// Phase 1 document totals (centime precision, decimal strings).
class InvoiceDocumentTotalsModel {
  final String totalHt;
  final String totalTva;
  final String totalTtc;
  final String timbre;
  final String netAPayer;

  const InvoiceDocumentTotalsModel({
    required this.totalHt,
    required this.totalTva,
    required this.totalTtc,
    required this.timbre,
    required this.netAPayer,
  });

  factory InvoiceDocumentTotalsModel.fromJson(Map<String, dynamic> json) {
    return InvoiceDocumentTotalsModel(
      totalHt: '${json['total_ht'] ?? 0}',
      totalTva: '${json['total_tva'] ?? 0}',
      totalTtc: '${json['total_ttc'] ?? 0}',
      timbre: '${json['timbre'] ?? 0}',
      netAPayer: '${json['net_a_payer'] ?? 0}',
    );
  }
}

/// List row: identity + client reference, no lines / totals.
class InvoiceDocumentSummaryModel {
  final String id;
  final String docType;
  final int year;
  final String number;
  final String documentDate;
  final String clientId;
  final InvoiceClientModel? client;
  final String paymentMethod;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const InvoiceDocumentSummaryModel({
    required this.id,
    required this.docType,
    required this.year,
    required this.number,
    required this.documentDate,
    required this.clientId,
    this.client,
    required this.paymentMethod,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  factory InvoiceDocumentSummaryModel.fromJson(Map<String, dynamic> json) {
    return InvoiceDocumentSummaryModel(
      id: json['id'] as String,
      docType: json['doc_type'] as String? ?? DocTypeValue.fac,
      year: json['year'] as int? ?? 0,
      number: json['number'] as String? ?? '',
      documentDate: json['document_date'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      client: json['client'] == null
          ? null
          : InvoiceClientModel.fromJson(
              json['client'] as Map<String, dynamic>,
            ),
      paymentMethod: json['payment_method'] as String? ?? PaymentMethodValue.cash,
      notes: json['notes'] as String?,
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }
}

/// Full document: identity + editable fields + lines + totals.
class InvoiceDocumentModel {
  final String id;
  final String docType;
  final int year;
  final String number;
  final String documentDate;
  final String clientId;
  final InvoiceClientModel? client;
  final String paymentMethod;
  final String? notes;
  final bool showDiscount;
  final bool showTva;
  final bool showTimbre;
  final bool showPaymentMethod;
  final bool showAmountWords;
  final List<InvoiceLineModel> lines;
  final InvoiceDocumentTotalsModel totals;
  final String amountInWords;

  /// Sale-posting link (null = not posted as a POS sale yet).
  final String? saleId;
  final DateTime? postedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const InvoiceDocumentModel({
    required this.id,
    required this.docType,
    required this.year,
    required this.number,
    required this.documentDate,
    required this.clientId,
    this.client,
    required this.paymentMethod,
    this.notes,
    this.showDiscount = true,
    this.showTva = true,
    this.showTimbre = true,
    this.showPaymentMethod = true,
    this.showAmountWords = true,
    this.lines = const [],
    required this.totals,
    this.amountInWords = '',
    this.saleId,
    this.postedAt,
    this.createdAt,
    this.updatedAt,
  });

  /// True when this document has already been posted as a POS sale.
  bool get isPosted => saleId != null;

  factory InvoiceDocumentModel.fromJson(Map<String, dynamic> json) {
    return InvoiceDocumentModel(
      id: json['id'] as String,
      docType: json['doc_type'] as String? ?? DocTypeValue.fac,
      year: json['year'] as int? ?? 0,
      number: json['number'] as String? ?? '',
      documentDate: json['document_date'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      client: json['client'] == null
          ? null
          : InvoiceClientModel.fromJson(
              json['client'] as Map<String, dynamic>,
            ),
      paymentMethod: json['payment_method'] as String? ?? PaymentMethodValue.cash,
      notes: json['notes'] as String?,
      showDiscount: json['show_discount'] as bool? ?? true,
      showTva: json['show_tva'] as bool? ?? true,
      showTimbre: json['show_timbre'] as bool? ?? true,
      showPaymentMethod: json['show_payment_method'] as bool? ?? true,
      showAmountWords: json['show_amount_words'] as bool? ?? true,
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => InvoiceLineModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      totals: InvoiceDocumentTotalsModel.fromJson(
        json['totals'] as Map<String, dynamic>? ?? const {},
      ),
      amountInWords: json['amount_in_words'] as String? ?? '',
      saleId: json['sale_id'] as String?,
      postedAt: DateTime.tryParse('${json['posted_at'] ?? ''}'),
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }
}

/// POST /factures/preview resolved-but-unpersisted line (no id).
class InvoiceLinePreviewModel {
  final String? productId;

  /// Stage 3A option identity (nullable, same as the persisted line).
  final String? variantId;
  final String? sellingUnitId;
  final String? packId;

  final String description;
  final String quantity;
  final String unitPriceHt;
  final String tvaRate;
  final String discountPct;
  final int position;
  final String totalHt;
  final String totalTva;

  const InvoiceLinePreviewModel({
    this.productId,
    this.variantId,
    this.sellingUnitId,
    this.packId,
    required this.description,
    required this.quantity,
    required this.unitPriceHt,
    required this.tvaRate,
    required this.discountPct,
    required this.position,
    required this.totalHt,
    required this.totalTva,
  });

  factory InvoiceLinePreviewModel.fromJson(Map<String, dynamic> json) {
    return InvoiceLinePreviewModel(
      productId: json['product_id'] as String?,
      variantId: json['variant_id'] as String?,
      sellingUnitId: json['selling_unit_id'] as String?,
      packId: json['pack_id'] as String?,
      description: json['description'] as String? ?? '',
      quantity: '${json['quantity'] ?? 0}',
      unitPriceHt: '${json['unit_price_ht'] ?? 0}',
      tvaRate: '${json['tva_rate'] ?? 0}',
      discountPct: '${json['discount_pct'] ?? 0}',
      position: json['position'] as int? ?? 0,
      totalHt: '${json['total_ht'] ?? 0}',
      totalTva: '${json['total_tva'] ?? 0}',
    );
  }
}

/// POST /factures/preview dry-run result (nothing persisted).
class InvoiceDocumentPreviewModel {
  final String documentDate;
  final int year;
  final String number;
  final String clientId;
  final InvoiceClientModel? client;
  final List<InvoiceLinePreviewModel> lines;
  final InvoiceDocumentTotalsModel totals;
  final String amountInWords;

  const InvoiceDocumentPreviewModel({
    required this.documentDate,
    required this.year,
    required this.number,
    required this.clientId,
    this.client,
    this.lines = const [],
    required this.totals,
    this.amountInWords = '',
  });

  factory InvoiceDocumentPreviewModel.fromJson(Map<String, dynamic> json) {
    return InvoiceDocumentPreviewModel(
      documentDate: json['document_date'] as String? ?? '',
      year: json['year'] as int? ?? 0,
      number: json['number'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      client: json['client'] == null
          ? null
          : InvoiceClientModel.fromJson(
              json['client'] as Map<String, dynamic>,
            ),
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map(
            (e) => InvoiceLinePreviewModel.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
      totals: InvoiceDocumentTotalsModel.fromJson(
        json['totals'] as Map<String, dynamic>? ?? const {},
      ),
      amountInWords: json['amount_in_words'] as String? ?? '',
    );
  }
}

/// Local draft line staged inside the invoice editor dialog.
///
/// Quantity / price / discount stay as raw text until submit; money
/// math uses the exact milli helpers only (display totals, never
/// fiscal authority — the preview endpoint is).
///
/// Stage 3A option identity: at most one of (variant, selling unit)
/// under a product, or a pack alone — mirrors the backend contract.
/// The three ids are transmitted as-is; display names are dialog UX
/// only (the server snapshots description + price as fiscal truth).
class DraftInvoiceLine {
  final String? productId;
  final String? productName;

  /// Stage 3A option identity + display names (nullable).
  final String? variantId;
  final String? variantName;
  final String? sellingUnitId;
  final String? sellingUnitName;
  final String? packId;
  final String? packName;

  final String description;
  final String quantity;
  final String unitPriceHt;

  /// `null` until a rate is chosen; stored as an int for the dropdown.
  final int? tvaRate;
  final String discountPct;

  const DraftInvoiceLine({
    this.productId,
    this.productName,
    this.variantId,
    this.variantName,
    this.sellingUnitId,
    this.sellingUnitName,
    this.packId,
    this.packName,
    required this.description,
    required this.quantity,
    required this.unitPriceHt,
    this.tvaRate,
    this.discountPct = '0',
  });

  /// A line with NO product and NO pack requires full free-text fields.
  /// Pack lines are not free-text — the server prefills name/price/tva.
  bool get isFreeText => productId == null && packId == null;

  bool get isPackLine => packId != null;

  DraftInvoiceLine copyWith({
    String? productId,
    String? productName,
    String? variantId,
    String? variantName,
    String? sellingUnitId,
    String? sellingUnitName,
    String? packId,
    String? packName,
    String? description,
    String? quantity,
    String? unitPriceHt,
    int? tvaRate,
    String? discountPct,
    bool clearProduct = false,
    bool clearOption = false,
    bool clearTvaRate = false,
  }) {
    return DraftInvoiceLine(
      productId: clearProduct ? null : (productId ?? this.productId),
      productName: clearProduct ? null : (productName ?? this.productName),
      // Option ids are owned by the product — clearing the product
      // clears its variant / unit too (and vice versa via clearOption).
      variantId:
          (clearProduct || clearOption) ? null : (variantId ?? this.variantId),
      variantName:
          (clearProduct || clearOption) ? null : (variantName ?? this.variantName),
      sellingUnitId: (clearProduct || clearOption)
          ? null
          : (sellingUnitId ?? this.sellingUnitId),
      sellingUnitName: (clearProduct || clearOption)
          ? null
          : (sellingUnitName ?? this.sellingUnitName),
      packId: clearProduct ? null : (packId ?? this.packId),
      packName: clearProduct ? null : (packName ?? this.packName),
      description: description ?? this.description,
      quantity: quantity ?? this.quantity,
      unitPriceHt: unitPriceHt ?? this.unitPriceHt,
      tvaRate: clearTvaRate ? null : (tvaRate ?? this.tvaRate),
      discountPct: discountPct ?? this.discountPct,
    );
  }

  /// Display-only line HT total: (qty×1000 × price×1000) / 1000 with
  /// discount applied — integer math, rounded half-up, no floats.
  ///
  /// Discount is a percentage in thousandths (10.5% → 10500); the
  /// factor is `(100000 − pct) / 100000`.
  int get lineHtMilli {
    final q = qtyToMilli(quantity);
    final p = moneyToMilli(unitPriceHt);
    if (q == null || p == null) return 0;
    var raw = q * p; // 10^-6 units
    final discount = pctToMilli(discountPct);
    if (discount != null && discount > 0) {
      raw = (raw * (100000 - discount) + 50000) ~/ 100000;
    }
    return (raw + 500) ~/ 1000;
  }

  /// Display-only TVA amount on the discounted HT total.
  int get lineTvaMilli {
    final ht = lineHtMilli;
    final rate = tvaRate;
    if (rate == null || rate == 0) return 0;
    return (ht * rate + 50) ~/ 100;
  }

  String get lineHt => milliToMoney(lineHtMilli);
  String get lineTva => milliToMoney(lineTvaMilli);

  Map<String, dynamic> toPayload() {
    final hasProduct = productId != null;
    final hasPack = packId != null;
    return {
      if (hasProduct) 'product_id': productId,
      if (hasProduct && variantId != null) 'variant_id': variantId,
      if (hasProduct && sellingUnitId != null) 'selling_unit_id': sellingUnitId,
      if (hasPack) 'pack_id': packId,
      // Free-text lines carry their own identity fields; product / pack
      // lines send description and price only when the user edited them
      // (empty prefill → the server's authoritative prefill wins).
      if (!hasProduct && !hasPack) 'description': description.trim(),
      'quantity': quantity.trim(),
      if (!hasProduct && !hasPack) 'unit_price_ht': unitPriceHt.trim(),
      if (!hasProduct && !hasPack && tvaRate != null) 'tva_rate': '$tvaRate',
      if (hasProduct && unitPriceHt.trim().isNotEmpty)
        'unit_price_ht': unitPriceHt.trim(),
      if (hasProduct && tvaRate != null) 'tva_rate': '$tvaRate',
      if (hasPack && unitPriceHt.trim().isNotEmpty)
        'unit_price_ht': unitPriceHt.trim(),
      if (hasPack && tvaRate != null) 'tva_rate': '$tvaRate',
      'discount_pct': discountPct.trim().isEmpty ? '0' : discountPct.trim(),
    };
  }
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

final RegExp _pctPattern = RegExp(r'^(\d{1,3})(?:\.(\d{1,3}))?$');

/// Discount percentage in millionths (0..100 → 0..100_000_000).
int? pctToMilli(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final match = _pctPattern.firstMatch(value);
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null || whole > 100) return null;
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  final frac = int.tryParse(fraction);
  if (frac == null) return null;
  return whole * 1000 + frac;
}
