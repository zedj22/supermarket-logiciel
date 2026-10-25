// Pack / bundle data models (Phase 10).
//
// Mirrors the `app/schemas/pack.py` contract exactly: money and quantity
// values travel as decimal STRINGS (NUMERIC(18,3) on the wire) so no
// binary float ever touches a persisted business value.
import '../../core/markup_percent.dart';

class PackComponentModel {
  /// BASE units one pack consumes (GATE 2 — the column semantics are
  /// unchanged, and this is what stock / availability / checkout use).
  final String quantity;

  /// Selected selling unit (Phase 10 fix round). `null` = product base
  /// unit, which is also how every component created before the fix round
  /// hydrates.
  final String? sellingUnitId;
  final String? sellingUnitName;

  /// Snapshot taken when the pack was defined — never the live catalog
  /// value, so a later multiplier change cannot rewrite this row.
  final String? sellingUnitMultiplier;

  /// `quantity` expressed in the selected unit (equal to `quantity` for
  /// base-unit components).
  final String unitQuantity;

  /// Explicit alias of `quantity` for the edit form / hydration.
  final String baseQuantity;

  final String productId;
  final String productName;
  final String productUnit;
  final String productPrice;

  /// Current product PMP (Phase 7) — informational estimate only.
  final String avgCost;

  const PackComponentModel({
    required this.productId,
    required this.productName,
    this.productUnit = 'piece',
    this.productPrice = '0',
    this.quantity = '0',
    this.sellingUnitId,
    this.sellingUnitName,
    this.sellingUnitMultiplier,
    this.unitQuantity = '0',
    this.baseQuantity = '0',
    this.avgCost = '0',
  });

  /// Legacy rows carry no unit identity: base unit ×1, entered = base.
  bool get hasSellingUnit => sellingUnitId != null;

  double get multiplier =>
      double.tryParse(sellingUnitMultiplier ?? '1') ?? 1;

  factory PackComponentModel.fromJson(Map<String, dynamic> json) {
    final quantity = '${json['quantity'] ?? 0}';
    return PackComponentModel(
      productId: '${json['product_id'] ?? ''}',
      productName: '${json['product_name'] ?? ''}',
      productUnit: '${json['product_unit'] ?? 'piece'}',
      productPrice: '${json['product_price'] ?? 0}',
      quantity: quantity,
      sellingUnitId: json['selling_unit_id'] as String?,
      sellingUnitName: json['selling_unit_name'] as String?,
      sellingUnitMultiplier: json['selling_unit_multiplier']?.toString(),
      unitQuantity: '${json['unit_quantity'] ?? quantity}',
      baseQuantity: '${json['base_quantity'] ?? quantity}',
      avgCost: '${json['avg_cost'] ?? 0}',
    );
  }
}

/// Pack list/detail row (`PackResponse` / `PackDetailResponse`).
///
/// `sumOfParts` is informational only (GATE 3) — never used for pricing,
/// totals or stock.
class PackModel {
  final String id;
  final String name;
  final String? barcode;
  final String price;
  final bool isActive;
  final bool isArchived;
  final String? archivedAt;
  final String? imagePath;
  final int componentsCount;
  final String? sumOfParts;

  /// Informational estimate from the live PMP (Phase 10 fix round).
  /// `null` whenever the backend omits it (list rows, price == 0 margin).
  final String? estimatedCost;
  final String? estimatedProfit;

  /// Backend field `estimated_margin_percent` — profit / selling price ×
  /// 100. Kept verbatim for API compatibility but NEVER displayed: the
  /// app-wide profit percentage is [estimatedMarkupPercent].
  final String? estimatedMarginPercent;
  final String createdAt;
  final String updatedAt;
  final List<PackComponentModel> components;

  const PackModel({
    required this.id,
    required this.name,
    this.barcode,
    this.price = '0',
    this.isActive = true,
    this.isArchived = false,
    this.archivedAt,
    this.imagePath,
    this.componentsCount = 0,
    this.sumOfParts,
    this.estimatedCost,
    this.estimatedProfit,
    this.estimatedMarginPercent,
    this.createdAt = '',
    this.updatedAt = '',
    this.components = const [],
  });

  bool get isSaleable => isActive && !isArchived;

  /// The app-wide profit percentage for a pack: profit as a percentage of
  /// the pack's ESTIMATED COST (markup on cost), from the shared helper
  /// `core/markup_percent.dart`.
  ///
  /// Computed here rather than taken from the backend's
  /// `estimated_margin_percent`, which is profit / price × 100 — a
  /// different metric. `null` when the cost is missing, unparsable or not
  /// strictly positive (never divide by zero); the absolute
  /// [estimatedCost] / [estimatedProfit] strings are untouched.
  String? get estimatedMarkupPercent => markupPercentRaw(
        profitRaw: estimatedProfit,
        costRaw: estimatedCost,
      );

  factory PackModel.fromJson(Map<String, dynamic> json) {
    return PackModel(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      barcode: json['barcode'] as String?,
      price: '${json['price'] ?? 0}',
      isActive: json['is_active'] as bool? ?? true,
      isArchived: json['is_archived'] as bool? ?? false,
      archivedAt: json['archived_at']?.toString(),
      imagePath: json['image_path'] as String?,
      componentsCount: json['components_count'] as int? ?? 0,
      sumOfParts: json['sum_of_parts']?.toString(),
      estimatedCost: json['estimated_cost']?.toString(),
      estimatedProfit: json['estimated_profit']?.toString(),
      estimatedMarginPercent: json['estimated_margin_percent']?.toString(),
      createdAt: '${json['created_at'] ?? ''}',
      updatedAt: '${json['updated_at'] ?? ''}',
      components: (json['components'] as List<dynamic>? ?? const [])
          .map((e) => PackComponentModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// One component row of `GET /packs/{id}/availability`.
///
/// `required_*` / `available_quantity` are BASE units (what the sale will
/// actually deduct); the `unit_*` fields spell the conversion out for the
/// UI — e.g. "2 Box = 48 Piece".
class PackComponentAvailabilityModel {
  final String productId;
  final String productName;
  final String productUnit;
  final String requiredPerPack;
  final String requiredQuantity;
  final String availableQuantity;
  final bool ok;
  final String? sellingUnitId;
  final String? sellingUnitName;
  final String? sellingUnitMultiplier;
  final String unitQuantity;
  final String requiredUnitQuantity;

  const PackComponentAvailabilityModel({
    required this.productId,
    required this.productName,
    this.productUnit = 'piece',
    this.requiredPerPack = '0',
    this.requiredQuantity = '0',
    this.availableQuantity = '0',
    this.ok = true,
    this.sellingUnitId,
    this.sellingUnitName,
    this.sellingUnitMultiplier,
    this.unitQuantity = '0',
    this.requiredUnitQuantity = '0',
  });

  /// Selected selling unit (null = product base unit / legacy component).
  bool get hasSellingUnit => sellingUnitId != null;

  factory PackComponentAvailabilityModel.fromJson(Map<String, dynamic> json) {
    final requiredPerPack = '${json['required_per_pack'] ?? 0}';
    final requiredQuantity = '${json['required_quantity'] ?? 0}';
    return PackComponentAvailabilityModel(
      productId: '${json['product_id'] ?? ''}',
      productName: '${json['product_name'] ?? ''}',
      productUnit: '${json['product_unit'] ?? 'piece'}',
      requiredPerPack: requiredPerPack,
      requiredQuantity: requiredQuantity,
      availableQuantity: '${json['available_quantity'] ?? 0}',
      ok: json['ok'] as bool? ?? true,
      sellingUnitId: json['selling_unit_id'] as String?,
      sellingUnitName: json['selling_unit_name'] as String?,
      sellingUnitMultiplier: json['selling_unit_multiplier']?.toString(),
      unitQuantity: '${json['unit_quantity'] ?? requiredPerPack}',
      requiredUnitQuantity:
          '${json['required_unit_quantity'] ?? requiredQuantity}',
    );
  }
}

/// `GET /api/v1/packs/{id}/availability?quantity=N` — read-only, never
/// reserves stock.
class PackAvailabilityModel {
  final String packId;
  final String packName;
  final String price;
  final bool isActive;
  final bool isArchived;
  final String quantity;
  final bool saleable;
  final String maxPackQuantity;
  final String? sumOfParts;
  final List<PackComponentAvailabilityModel> components;
  final List<String> errors;

  const PackAvailabilityModel({
    required this.packId,
    required this.packName,
    this.price = '0',
    this.isActive = true,
    this.isArchived = false,
    this.quantity = '1',
    this.saleable = false,
    this.maxPackQuantity = '0',
    this.sumOfParts,
    this.components = const [],
    this.errors = const [],
  });

  factory PackAvailabilityModel.fromJson(Map<String, dynamic> json) {
    return PackAvailabilityModel(
      packId: '${json['pack_id'] ?? ''}',
      packName: '${json['pack_name'] ?? ''}',
      price: '${json['price'] ?? 0}',
      isActive: json['is_active'] as bool? ?? true,
      isArchived: json['is_archived'] as bool? ?? false,
      quantity: '${json['quantity'] ?? 1}',
      saleable: json['saleable'] as bool? ?? false,
      maxPackQuantity: '${json['max_pack_quantity'] ?? 0}',
      sumOfParts: json['sum_of_parts']?.toString(),
      components: (json['components'] as List<dynamic>? ?? const []).map(
        (e) => PackComponentAvailabilityModel.fromJson(e as Map<String, dynamic>),
      ).toList(),
      errors: (json['errors'] as List<dynamic>? ?? const [])
          .map((e) => '${e ?? ''}')
          .toList(),
    );
  }
}

/// Everything the POS needs to place one pack line in the cart.
class PackPickResult {
  final String packId;
  final String name;
  final String? barcode;
  final String price;
  final String quantity;
  final String maxPackQuantity;
  final String componentsSummary;

  const PackPickResult({
    required this.packId,
    required this.name,
    this.barcode,
    required this.price,
    this.quantity = '1',
    this.maxPackQuantity = '0',
    this.componentsSummary = '',
  });
}
