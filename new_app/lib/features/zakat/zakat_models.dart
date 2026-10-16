// Zakat al-Tijarah models — wire contract for `/api/v1/zakat`.
//
// Money is carried as the backend's decimal strings (`'120.500'`) and
// dates as ISO `yyyy-MM-dd` strings: the client never multiplies or
// rounds money, the server is the only place the formula runs (§
// backend app/domain/zakat.py). Normalization of operator input goes
// through `moneyToMilli`/`milliToMoney` at the form boundary only.
import 'package:flutter/foundation.dart';

@immutable
class ZakatLineInput {
  const ZakatLineInput({
    required this.label,
    required this.amount,
    this.due,
  });

  final String label;
  final String amount;
  final bool? due;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'amount': amount,
        if (due != null) 'due': due,
      };

  factory ZakatLineInput.fromJson(Map<String, dynamic> json) =>
      ZakatLineInput(
        label: json['label'] as String? ?? '',
        amount: json['amount'] as String? ?? '0',
        due: json['due'] as bool?,
      );
}

/// The full calculation payload — also what a saved snapshot stores
/// verbatim (`inputs`), so a snapshot is fully reproducible.
@immutable
class ZakatCalculationInput {
  const ZakatCalculationInput({
    required this.zakatDate,
    this.hawlStartDate,
    this.goldPricePerGram,
    this.nisabOverride,
    this.inventoryBasis = 'market',
    this.inventoryOverrideValue,
    this.inventoryOverrideReason,
    this.useImportedInventory = true,
    this.excludedProductIds = const <String>[],
    this.cashProvided = false,
    this.cashItems = const <ZakatLineInput>[],
    this.collectibleReceivables,
    this.doubtfulReceivables,
    this.otherReceivableItems = const <ZakatLineInput>[],
    this.debtTreatment = 'deduct_all',
    this.liabilityItems = const <ZakatLineInput>[],
    this.notes,
  });

  final String zakatDate;
  final String? hawlStartDate;
  final String? goldPricePerGram;
  final String? nisabOverride;
  final String inventoryBasis;
  final String? inventoryOverrideValue;
  final String? inventoryOverrideReason;
  final bool useImportedInventory;
  final List<String> excludedProductIds;
  final bool cashProvided;
  final List<ZakatLineInput> cashItems;
  final String? collectibleReceivables;
  final String? doubtfulReceivables;
  final List<ZakatLineInput> otherReceivableItems;
  final String debtTreatment;
  final List<ZakatLineInput> liabilityItems;
  final String? notes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'zakat_date': zakatDate,
        if (hawlStartDate != null && hawlStartDate!.isNotEmpty)
          'hawl_start_date': hawlStartDate,
        if (goldPricePerGram != null && goldPricePerGram!.isNotEmpty)
          'gold_price_per_gram': goldPricePerGram,
        if (nisabOverride != null && nisabOverride!.isNotEmpty)
          'nisab_override': nisabOverride,
        'inventory_basis': inventoryBasis,
        if (inventoryBasis == 'override') ...<String, dynamic>{
          if (inventoryOverrideValue != null &&
              inventoryOverrideValue!.isNotEmpty)
            'inventory_override_value': inventoryOverrideValue,
          if (inventoryOverrideReason != null &&
              inventoryOverrideReason!.trim().isNotEmpty)
            'inventory_override_reason': inventoryOverrideReason!.trim(),
        },
        'use_imported_inventory': useImportedInventory,
        if (excludedProductIds.isNotEmpty)
          'excluded_product_ids': excludedProductIds,
        'cash_provided': cashProvided,
        if (cashItems.isNotEmpty)
          'cash_items': cashItems.map((l) => l.toJson()).toList(),
        if (collectibleReceivables != null &&
            collectibleReceivables!.isNotEmpty)
          'collectible_receivables': collectibleReceivables,
        if (doubtfulReceivables != null && doubtfulReceivables!.isNotEmpty)
          'doubtful_receivables': doubtfulReceivables,
        if (otherReceivableItems.isNotEmpty)
          'other_receivable_items':
              otherReceivableItems.map((l) => l.toJson()).toList(),
        'debt_treatment': debtTreatment,
        if (liabilityItems.isNotEmpty)
          'liability_items': liabilityItems.map((l) => l.toJson()).toList(),
        if (notes != null && notes!.trim().isNotEmpty)
          'notes': notes!.trim(),
      };

  factory ZakatCalculationInput.fromJson(Map<String, dynamic> json) {
    List<ZakatLineInput> lines(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatLineInput.fromJson)
            .toList();
    return ZakatCalculationInput(
      zakatDate: json['zakat_date'] as String? ?? '',
      hawlStartDate: json['hawl_start_date'] as String?,
      goldPricePerGram: json['gold_price_per_gram'] as String?,
      nisabOverride: json['nisab_override'] as String?,
      inventoryBasis: json['inventory_basis'] as String? ?? 'market',
      inventoryOverrideValue: json['inventory_override_value'] as String?,
      inventoryOverrideReason: json['inventory_override_reason'] as String?,
      useImportedInventory: json['use_imported_inventory'] as bool? ?? true,
      excludedProductIds: (json['excluded_product_ids'] as List<dynamic>? ??
              const [])
          .map((e) => e.toString())
          .toList(),
      cashProvided: json['cash_provided'] as bool? ?? false,
      cashItems: lines('cash_items'),
      collectibleReceivables: json['collectible_receivables'] as String?,
      doubtfulReceivables: json['doubtful_receivables'] as String?,
      otherReceivableItems: lines('other_receivable_items'),
      debtTreatment: json['debt_treatment'] as String? ?? 'deduct_all',
      liabilityItems: lines('liability_items'),
      notes: json['notes'] as String?,
    );
  }
}

@immutable
class ZakatWarning {
  const ZakatWarning({required this.code, this.detail = const {}});

  final String code;
  final Map<String, String> detail;

  /// Localization key mirroring backend `printing/labels.py`.
  String get labelKey => 'zakat_warn_${code.toLowerCase()}';

  factory ZakatWarning.fromJson(Map<String, dynamic> json) => ZakatWarning(
        code: json['code'] as String? ?? '',
        detail: (json['detail'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, v?.toString() ?? '')),
      );
}

/// Mirror of backend `ZakatResultResponse` — every money field stays a
/// decimal string (or null when the server could not compute it).
@immutable
class ZakatResult {
  const ZakatResult({
    required this.zakatDate,
    required this.status,
    required this.missingFields,
    required this.warnings,
    required this.hawlStartDate,
    required this.hawlDaysElapsed,
    required this.hawlCompleted,
    required this.goldPricePerGram,
    required this.nisabAmount,
    required this.nisabSource,
    required this.inventoryBasis,
    required this.inventoryValue,
    required this.inventorySource,
    required this.inventoryImportedValue,
    required this.inventoryExcludedValue,
    required this.inventoryProductCount,
    required this.inventoryIncludedCount,
    required this.cashProvided,
    required this.cashTotal,
    required this.cashItemCount,
    required this.collectibleReceivables,
    required this.doubtfulReceivables,
    required this.otherReceivablesTotal,
    required this.receivablesIncludedTotal,
    required this.receivableItemCount,
    required this.debtTreatment,
    required this.liabilitiesTotalEntered,
    required this.deductionsApplied,
    required this.liabilitiesSkippedAmount,
    required this.liabilitiesSkippedCount,
    required this.liabilityItemCount,
    required this.netZakatable,
    required this.zakatRate,
    required this.zakatDue,
    required this.provisionalZakatDue,
    required this.reachesNisab,
    required this.eligibilityReasons,
  });

  final String zakatDate;
  final String status;
  final List<String> missingFields;
  final List<ZakatWarning> warnings;
  final String? hawlStartDate;
  final int? hawlDaysElapsed;
  final bool? hawlCompleted;
  final String? goldPricePerGram;
  final String? nisabAmount;
  final String? nisabSource;
  final String inventoryBasis;
  final String? inventoryValue;
  final String inventorySource;
  final String? inventoryImportedValue;
  final String inventoryExcludedValue;
  final int inventoryProductCount;
  final int inventoryIncludedCount;
  final bool cashProvided;
  final String? cashTotal;
  final int cashItemCount;
  final String? collectibleReceivables;
  final String? doubtfulReceivables;
  final String otherReceivablesTotal;
  final String? receivablesIncludedTotal;
  final int receivableItemCount;
  final String debtTreatment;
  final String liabilitiesTotalEntered;
  final String deductionsApplied;
  final String liabilitiesSkippedAmount;
  final int liabilitiesSkippedCount;
  final int liabilityItemCount;
  final String netZakatable;
  final String zakatRate;
  final String? zakatDue;
  final String? provisionalZakatDue;
  final bool? reachesNisab;
  final List<String> eligibilityReasons;

  bool get isProvisional => status == 'provisional';

  factory ZakatResult.fromJson(Map<String, dynamic> json) => ZakatResult(
        zakatDate: json['zakat_date'] as String? ?? '',
        status: json['status'] as String? ?? 'provisional',
        missingFields: (json['missing_fields'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        warnings: (json['warnings'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatWarning.fromJson)
            .toList(),
        hawlStartDate: json['hawl_start_date'] as String?,
        hawlDaysElapsed: (json['hawl_days_elapsed'] as num?)?.toInt(),
        hawlCompleted: json['hawl_completed'] as bool?,
        goldPricePerGram: json['gold_price_per_gram'] as String?,
        nisabAmount: json['nisab_amount'] as String?,
        nisabSource: json['nisab_source'] as String?,
        inventoryBasis: json['inventory_basis'] as String? ?? 'market',
        inventoryValue: json['inventory_value'] as String?,
        inventorySource: json['inventory_source'] as String? ?? 'imported',
        inventoryImportedValue: json['inventory_imported_value'] as String?,
        inventoryExcludedValue:
            json['inventory_excluded_value'] as String? ?? '0',
        inventoryProductCount:
            (json['inventory_product_count'] as num?)?.toInt() ?? 0,
        inventoryIncludedCount:
            (json['inventory_included_count'] as num?)?.toInt() ?? 0,
        cashProvided: json['cash_provided'] as bool? ?? false,
        cashTotal: json['cash_total'] as String?,
        cashItemCount: (json['cash_item_count'] as num?)?.toInt() ?? 0,
        collectibleReceivables: json['collectible_receivables'] as String?,
        doubtfulReceivables: json['doubtful_receivables'] as String?,
        otherReceivablesTotal:
            json['other_receivables_total'] as String? ?? '0',
        receivablesIncludedTotal: json['receivables_included_total'] as String?,
        receivableItemCount:
            (json['receivable_item_count'] as num?)?.toInt() ?? 0,
        debtTreatment: json['debt_treatment'] as String? ?? 'deduct_all',
        liabilitiesTotalEntered:
            json['liabilities_total_entered'] as String? ?? '0',
        deductionsApplied: json['deductions_applied'] as String? ?? '0',
        liabilitiesSkippedAmount:
            json['liabilities_skipped_amount'] as String? ?? '0',
        liabilitiesSkippedCount:
            (json['liabilities_skipped_count'] as num?)?.toInt() ?? 0,
        liabilityItemCount:
            (json['liability_item_count'] as num?)?.toInt() ?? 0,
        netZakatable: json['net_zakatable'] as String? ?? '0',
        zakatRate: json['zakat_rate'] as String? ?? '0.025',
        zakatDue: json['zakat_due'] as String?,
        provisionalZakatDue: json['provisional_zakat_due'] as String?,
        reachesNisab: json['reaches_nisab'] as bool?,
        eligibilityReasons:
            (json['eligibility_reasons'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(),
      );
}

@immutable
class ZakatCalculateResponse {
  const ZakatCalculateResponse({
    required this.storeName,
    required this.generatedAt,
    required this.result,
  });

  final String storeName;
  final String generatedAt;
  final ZakatResult result;

  factory ZakatCalculateResponse.fromJson(Map<String, dynamic> json) =>
      ZakatCalculateResponse(
        storeName: json['store_name'] as String? ?? '',
        generatedAt: json['generated_at'] as String? ?? '',
        result: ZakatResult.fromJson(
          (json['result'] as Map<String, dynamic>? ?? const {}),
        ),
      );
}

@immutable
class ZakatOfficialNisabReference {
  const ZakatOfficialNisabReference({
    required this.hijriYear,
    required this.amount,
    required this.goldPricePerGram,
    required this.purity,
    required this.source,
    required this.note,
  });

  final int hijriYear;
  final String amount;
  final String goldPricePerGram;
  final String purity;
  final String source;
  final String note;

  factory ZakatOfficialNisabReference.fromJson(Map<String, dynamic> json) =>
      ZakatOfficialNisabReference(
        hijriYear: (json['hijri_year'] as num?)?.toInt() ?? 0,
        amount: json['amount'] as String? ?? '0',
        goldPricePerGram: json['gold_price_per_gram'] as String? ?? '0',
        purity: json['purity'] as String? ?? '',
        source: json['source'] as String? ?? '',
        note: json['note'] as String? ?? '',
      );
}

@immutable
class ZakatDefaults {
  const ZakatDefaults({
    required this.zakatRate,
    required this.hawlDays,
    required this.nisabGoldGrams,
    required this.inventoryBasis,
    required this.debtTreatment,
  });

  final String zakatRate;
  final int hawlDays;
  final String nisabGoldGrams;
  final String inventoryBasis;
  final String debtTreatment;

  factory ZakatDefaults.fromJson(Map<String, dynamic> json) => ZakatDefaults(
        zakatRate: json['zakat_rate'] as String? ?? '0.025',
        hawlDays: (json['hawl_days'] as num?)?.toInt() ?? 354,
        nisabGoldGrams: json['nisab_gold_grams'] as String? ?? '85',
        inventoryBasis: json['inventory_basis'] as String? ?? 'market',
        debtTreatment: json['debt_treatment'] as String? ?? 'deduct_all',
      );
}

@immutable
class ZakatInventoryLine {
  const ZakatInventoryLine({
    required this.productId,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.marketUnitPrice,
    required this.costUnitPrice,
    required this.marketValue,
    required this.costValue,
  });

  final String productId;
  final String name;
  final String unit;
  final String quantity;
  final String marketUnitPrice;
  final String costUnitPrice;
  final String marketValue;
  final String costValue;

  factory ZakatInventoryLine.fromJson(Map<String, dynamic> json) =>
      ZakatInventoryLine(
        productId: json['product_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        unit: json['unit'] as String? ?? '',
        quantity: json['quantity'] as String? ?? '0',
        marketUnitPrice: json['market_unit_price'] as String? ?? '0',
        costUnitPrice: json['cost_unit_price'] as String? ?? '0',
        marketValue: json['market_value'] as String? ?? '0',
        costValue: json['cost_value'] as String? ?? '0',
      );
}

@immutable
class ZakatContextInventory {
  const ZakatContextInventory({
    required this.productCount,
    required this.totalMarketValue,
    required this.totalCostValue,
    required this.truncated,
    required this.lines,
  });

  final int productCount;
  final String totalMarketValue;
  final String totalCostValue;
  final bool truncated;
  final List<ZakatInventoryLine> lines;

  factory ZakatContextInventory.fromJson(Map<String, dynamic> json) =>
      ZakatContextInventory(
        productCount: (json['product_count'] as num?)?.toInt() ?? 0,
        totalMarketValue: json['total_market_value'] as String? ?? '0',
        totalCostValue: json['total_cost_value'] as String? ?? '0',
        truncated: json['truncated'] as bool? ?? false,
        lines: (json['lines'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatInventoryLine.fromJson)
            .toList(),
      );
}

@immutable
class ZakatDebtor {
  const ZakatDebtor({
    required this.customerId,
    required this.name,
    required this.balance,
    this.phone,
  });

  final String customerId;
  final String name;
  final String? phone;
  final String balance;

  factory ZakatDebtor.fromJson(Map<String, dynamic> json) => ZakatDebtor(
        customerId: json['customer_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String?,
        balance: json['balance'] as String? ?? '0',
      );
}

@immutable
class ZakatContextReceivables {
  const ZakatContextReceivables({
    required this.ledgerTotal,
    required this.debtorCount,
    required this.debtors,
  });

  final String ledgerTotal;
  final int debtorCount;
  final List<ZakatDebtor> debtors;

  factory ZakatContextReceivables.fromJson(Map<String, dynamic> json) =>
      ZakatContextReceivables(
        ledgerTotal: json['ledger_total'] as String? ?? '0',
        debtorCount: (json['debtor_count'] as num?)?.toInt() ?? 0,
        debtors: (json['debtors'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatDebtor.fromJson)
            .toList(),
      );
}

@immutable
class ZakatPayable {
  const ZakatPayable({
    required this.supplierId,
    required this.name,
    required this.balance,
    this.phone,
  });

  final String supplierId;
  final String name;
  final String? phone;
  final String balance;

  factory ZakatPayable.fromJson(Map<String, dynamic> json) => ZakatPayable(
        supplierId: json['supplier_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String?,
        balance: json['balance'] as String? ?? '0',
      );
}

@immutable
class ZakatContextLiabilities {
  const ZakatContextLiabilities({
    required this.supplierBalanceTotal,
    required this.supplierCount,
    required this.suppliers,
  });

  final String supplierBalanceTotal;
  final int supplierCount;
  final List<ZakatPayable> suppliers;

  factory ZakatContextLiabilities.fromJson(Map<String, dynamic> json) =>
      ZakatContextLiabilities(
        supplierBalanceTotal:
            json['supplier_balance_total'] as String? ?? '0',
        supplierCount: (json['supplier_count'] as num?)?.toInt() ?? 0,
        suppliers: (json['suppliers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatPayable.fromJson)
            .toList(),
      );
}

/// One `GET /zakat/context` call that seeds the whole screen.
@immutable
class ZakatContext {
  const ZakatContext({
    required this.storeName,
    required this.storePhone,
    required this.storeAddress,
    required this.today,
    required this.officialNisabReference,
    required this.defaults,
    required this.inventory,
    required this.receivablesReference,
    required this.liabilitiesReference,
  });

  final String storeName;
  final String storePhone;
  final String storeAddress;
  final String today;
  final ZakatOfficialNisabReference officialNisabReference;
  final ZakatDefaults defaults;
  final ZakatContextInventory inventory;
  final ZakatContextReceivables receivablesReference;
  final ZakatContextLiabilities liabilitiesReference;

  factory ZakatContext.fromJson(Map<String, dynamic> json) => ZakatContext(
        storeName: json['store_name'] as String? ?? '',
        storePhone: json['store_phone'] as String? ?? '',
        storeAddress: json['store_address'] as String? ?? '',
        today: json['today'] as String? ?? '',
        officialNisabReference: ZakatOfficialNisabReference.fromJson(
          (json['official_nisab_reference'] as Map<String, dynamic>? ??
              const {}),
        ),
        defaults: ZakatDefaults.fromJson(
          (json['defaults'] as Map<String, dynamic>? ?? const {}),
        ),
        inventory: ZakatContextInventory.fromJson(
          (json['inventory'] as Map<String, dynamic>? ?? const {}),
        ),
        receivablesReference: ZakatContextReceivables.fromJson(
          (json['receivables_reference'] as Map<String, dynamic>? ?? const {}),
        ),
        liabilitiesReference: ZakatContextLiabilities.fromJson(
          (json['liabilities_reference'] as Map<String, dynamic>? ?? const {}),
        ),
      );
}

@immutable
class ZakatCalculationSummary {
  const ZakatCalculationSummary({
    required this.id,
    required this.zakatDate,
    required this.status,
    required this.netZakatable,
    required this.zakatDue,
    required this.provisionalZakatDue,
    required this.nisabAmount,
    required this.reachesNisab,
    required this.hawlCompleted,
    required this.paymentsTotal,
    required this.createdAt,
    this.notes,
    this.createdBy,
  });

  final String id;
  final String zakatDate;
  final String status;
  final String netZakatable;
  final String? zakatDue;
  final String? provisionalZakatDue;
  final String? nisabAmount;
  final bool? reachesNisab;
  final bool? hawlCompleted;
  final String paymentsTotal;
  final String? notes;
  final String? createdBy;
  final String createdAt;

  factory ZakatCalculationSummary.fromJson(Map<String, dynamic> json) =>
      ZakatCalculationSummary(
        id: json['id'] as String? ?? '',
        zakatDate: json['zakat_date'] as String? ?? '',
        status: json['status'] as String? ?? 'provisional',
        netZakatable: json['net_zakatable'] as String? ?? '0',
        zakatDue: json['zakat_due'] as String?,
        provisionalZakatDue: json['provisional_zakat_due'] as String?,
        nisabAmount: json['nisab_amount'] as String?,
        reachesNisab: json['reaches_nisab'] as bool?,
        hawlCompleted: json['hawl_completed'] as bool?,
        paymentsTotal: json['payments_total'] as String? ?? '0',
        notes: json['notes'] as String?,
        createdBy: json['created_by'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );
}

@immutable
class ZakatPaymentResponse {
  const ZakatPaymentResponse({
    required this.id,
    required this.calculationId,
    required this.amount,
    required this.method,
    required this.paidAt,
    required this.createdAt,
    this.note,
    this.createdBy,
  });

  final String id;
  final String calculationId;
  final String amount;
  final String method;
  final String paidAt;
  final String? note;
  final String? createdBy;
  final String createdAt;

  factory ZakatPaymentResponse.fromJson(Map<String, dynamic> json) =>
      ZakatPaymentResponse(
        id: json['id'] as String? ?? '',
        calculationId: json['calculation_id'] as String? ?? '',
        amount: json['amount'] as String? ?? '0',
        method: json['method'] as String? ?? 'cash',
        paidAt: json['paid_at'] as String? ?? '',
        note: json['note'] as String?,
        createdBy: json['created_by'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// Full snapshot: summary + stored result + the exact stored inputs.
@immutable
class ZakatCalculationDetail extends ZakatCalculationSummary {
  const ZakatCalculationDetail({
    required super.id,
    required super.zakatDate,
    required super.status,
    required super.netZakatable,
    required super.zakatDue,
    required super.provisionalZakatDue,
    required super.nisabAmount,
    required super.reachesNisab,
    required super.hawlCompleted,
    required super.paymentsTotal,
    required super.createdAt,
    super.notes,
    super.createdBy,
    required this.result,
    required this.inputs,
    this.payments = const <ZakatPaymentResponse>[],
  });

  final ZakatResult result;
  final ZakatCalculationInput inputs;
  final List<ZakatPaymentResponse> payments;

  factory ZakatCalculationDetail.fromJson(Map<String, dynamic> json) {
    final summary = ZakatCalculationSummary.fromJson(json);
    return ZakatCalculationDetail(
      id: summary.id,
      zakatDate: summary.zakatDate,
      status: summary.status,
      netZakatable: summary.netZakatable,
      zakatDue: summary.zakatDue,
      provisionalZakatDue: summary.provisionalZakatDue,
      nisabAmount: summary.nisabAmount,
      reachesNisab: summary.reachesNisab,
      hawlCompleted: summary.hawlCompleted,
      paymentsTotal: summary.paymentsTotal,
      notes: summary.notes,
      createdBy: summary.createdBy,
      createdAt: summary.createdAt,
      result: ZakatResult.fromJson(
        (json['result'] as Map<String, dynamic>? ?? const {}),
      ),
      inputs: ZakatCalculationInput.fromJson(
        (json['inputs'] as Map<String, dynamic>? ?? const {}),
      ),
      payments: (json['payments'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ZakatPaymentResponse.fromJson)
          .toList(),
    );
  }
}

/// One page of the saved-calculation history.
@immutable
class ZakatCalculationPage {
  const ZakatCalculationPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
  });

  final List<ZakatCalculationSummary> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  factory ZakatCalculationPage.fromJson(Map<String, dynamic> json) =>
      ZakatCalculationPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ZakatCalculationSummary.fromJson)
            .toList(),
        total: (json['total'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        pageSize: (json['page_size'] as num?)?.toInt() ?? 40,
        pages: (json['pages'] as num?)?.toInt() ?? 1,
      );
}

/// Localization key helpers mirroring backend enum values.
String zakatStatusKey(String status) => 'zakat_status_$status';

String zakatNisabSourceKey(String? source) =>
    'zakat_nisab_source_${source ?? 'none'}';

String zakatBasisKey(String basis) => 'zakat_basis_$basis';

String zakatMethodKey(String method) => 'zakat_method_$method';

String zakatPaymentMethodKey(String method) => 'zakat_pay_$method';

String zakatMissingFieldKey(String field) => 'zakat_missing_$field';

String zakatEligibilityKey(String reason) =>
    'zakat_eligibility_${reason.toLowerCase()}';
