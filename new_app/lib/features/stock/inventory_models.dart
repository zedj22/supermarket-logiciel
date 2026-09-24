// Inventory data models (Phase 7): stock list, movements, product detail.
//
// Money/quantity arrive as strings from JSON (Decimal serialization) —
// keep them as strings and parse only for display/math.

class InventoryItemModel {
  final String productId;
  final String name;
  final String? barcode;
  final String unit;
  final String quantity;
  final String lowStockThreshold;
  final bool allowNegativeStock;
  final String cost;
  final String avgCost;
  final String stockValue;
  final String price;
  final bool isArchived;
  final String? categoryId;
  final String? categoryName;
  final String updatedAt;

  const InventoryItemModel({
    required this.productId,
    required this.name,
    this.barcode,
    this.unit = 'piece',
    this.quantity = '0',
    this.lowStockThreshold = '5',
    this.allowNegativeStock = false,
    this.cost = '0',
    this.avgCost = '0',
    this.stockValue = '0',
    this.price = '0',
    this.isArchived = false,
    this.categoryId,
    this.categoryName,
    this.updatedAt = '',
  });

  factory InventoryItemModel.fromJson(Map<String, dynamic> json) {
    return InventoryItemModel(
      productId: json['product_id'] as String,
      name: json['name'] as String,
      barcode: json['barcode'] as String?,
      unit: json['unit'] as String? ?? 'piece',
      quantity: '${json['quantity'] ?? 0}',
      lowStockThreshold: '${json['low_stock_threshold'] ?? 5}',
      allowNegativeStock: json['allow_negative_stock'] as bool? ?? false,
      cost: '${json['cost'] ?? 0}',
      avgCost: '${json['avg_cost'] ?? 0}',
      stockValue: '${json['stock_value'] ?? 0}',
      price: '${json['price'] ?? 0}',
      isArchived: json['is_archived'] as bool? ?? false,
      categoryId: json['category_id'] as String?,
      categoryName: json['category_name'] as String?,
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }

  double get quantityAsDouble => double.tryParse(quantity) ?? 0;
  double get thresholdAsDouble => double.tryParse(lowStockThreshold) ?? 5;
  bool get isLowStock =>
      !isArchived && quantityAsDouble > 0 && quantityAsDouble <= thresholdAsDouble;
  bool get isOutStock => !isArchived && quantityAsDouble <= 0;
}

class InventoryMovementModel {
  final String id;
  final String productId;
  final String? productName;
  final String? variantId;
  final String? variantName;
  final String movementType;
  final String quantityChange;
  final String quantityBefore;
  final String quantityAfter;
  final String? documentQuantity;
  final String? documentUnit;
  final String? purchaseUnitId;
  final String? packagesChange;
  final String? unitCost;
  final String? avgCostAfter;
  final String? reason;
  final String? sourceDocumentType;
  final String? sourceDocumentId;
  final String? userId;
  final String? userName;
  final String? deviceId;
  final String movementDate;
  final String createdAt;

  const InventoryMovementModel({
    required this.id,
    required this.productId,
    this.productName,
    this.variantId,
    this.variantName,
    required this.movementType,
    required this.quantityChange,
    required this.quantityBefore,
    required this.quantityAfter,
    this.documentQuantity,
    this.documentUnit,
    this.purchaseUnitId,
    this.packagesChange,
    this.unitCost,
    this.avgCostAfter,
    this.reason,
    this.sourceDocumentType,
    this.sourceDocumentId,
    this.userId,
    this.userName,
    this.deviceId,
    this.movementDate = '',
    this.createdAt = '',
  });

  factory InventoryMovementModel.fromJson(Map<String, dynamic> json) {
    return InventoryMovementModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      productName: json['product_name'] as String?,
      variantId: json['variant_id'] as String?,
      variantName: json['variant_name'] as String?,
      movementType: json['movement_type'] as String? ?? '',
      quantityChange: '${json['quantity_change'] ?? 0}',
      quantityBefore: '${json['quantity_before'] ?? 0}',
      quantityAfter: '${json['quantity_after'] ?? 0}',
      documentQuantity: json['document_quantity']?.toString(),
      documentUnit: json['document_unit'] as String?,
      purchaseUnitId: json['purchase_unit_id'] as String?,
      packagesChange: json['packages_change']?.toString(),
      unitCost: json['unit_cost']?.toString(),
      avgCostAfter: json['avg_cost_after']?.toString(),
      reason: json['reason'] as String?,
      sourceDocumentType: json['source_document_type'] as String?,
      sourceDocumentId: json['source_document_id'] as String?,
      userId: json['user_id'] as String?,
      userName: json['user_name'] as String?,
      deviceId: json['device_id'] as String?,
      movementDate: json['movement_date'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
    );
  }
}

class InventoryProductDetailModel {
  final String productId;
  final String name;
  final String? barcode;
  final String unit;
  final String quantity;
  final String cost;
  final String avgCost;
  final String stockValue;
  final String price;
  final String lowStockThreshold;
  final bool allowNegativeStock;
  final bool isArchived;
  final Map<String, dynamic> packaging;
  final List<Map<String, dynamic>> variants;
  final List<Map<String, dynamic>> purchaseUnits;
  final List<InventoryMovementModel> recentMovements;

  const InventoryProductDetailModel({
    required this.productId,
    required this.name,
    this.barcode,
    this.unit = 'piece',
    this.quantity = '0',
    this.cost = '0',
    this.avgCost = '0',
    this.stockValue = '0',
    this.price = '0',
    this.lowStockThreshold = '5',
    this.allowNegativeStock = false,
    this.isArchived = false,
    this.packaging = const {},
    this.variants = const [],
    this.purchaseUnits = const [],
    this.recentMovements = const [],
  });

  factory InventoryProductDetailModel.fromJson(Map<String, dynamic> json) {
    return InventoryProductDetailModel(
      productId: json['product_id'] as String,
      name: json['name'] as String,
      barcode: json['barcode'] as String?,
      unit: json['unit'] as String? ?? 'piece',
      quantity: '${json['quantity'] ?? 0}',
      cost: '${json['cost'] ?? 0}',
      avgCost: '${json['avg_cost'] ?? 0}',
      stockValue: '${json['stock_value'] ?? 0}',
      price: '${json['price'] ?? 0}',
      lowStockThreshold: '${json['low_stock_threshold'] ?? 5}',
      allowNegativeStock: json['allow_negative_stock'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      packaging:
          Map<String, dynamic>.from(json['packaging'] as Map? ?? const {}),
      variants: (json['variants'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      purchaseUnits: (json['purchase_units'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      recentMovements: (json['recent_movements'] as List<dynamic>? ?? const [])
          .map((e) =>
              InventoryMovementModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
