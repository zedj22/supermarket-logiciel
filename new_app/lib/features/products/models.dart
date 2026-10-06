// Catalog data models (Phase 5 + Phase 6): products, categories,
// variants, selling units, barcode lookup.

class CategoryModel {
  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;
  final int productCount;
  final bool isArchived;

  const CategoryModel({
    required this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    this.productCount = 0,
    this.isArchived = false,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
      productCount: json['product_count'] as int? ?? 0,
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

class ProductModel {
  final String id;
  final String name;
  final String? barcode;
  final String? sku;
  final String? description;
  final String unit;
  final String price;
  final String cost;
  final String avgCost;
  final String quantity;
  final String lowStockThreshold;
  final bool allowNegativeStock;
  // Phase 17 pricing. NULL wholesale = feature off for this product
  // (pre-phase rows keep their retail behaviour). vat_rate is the strict
  // {0, 9, 19} catalog metadata — display only, never in a sale total.
  final String? wholesalePrice;
  final String? wholesaleMinQty;
  final int vatRate;
  final String? expiryDate;
  final String? imagePath;
  final String? categoryId;
  final String? categoryName;
  final bool isArchived;

  const ProductModel({
    required this.id,
    required this.name,
    this.barcode,
    this.sku,
    this.description,
    this.unit = 'piece',
    this.price = '0',
    this.cost = '0',
    this.avgCost = '0',
    this.quantity = '0',
    this.lowStockThreshold = '5',
    this.allowNegativeStock = false,
    this.wholesalePrice,
    this.wholesaleMinQty,
    this.vatRate = 0,
    this.expiryDate,
    this.imagePath,
    this.categoryId,
    this.categoryName,
    this.isArchived = false,
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) {
    return ProductModel(
      id: json['id'] as String,
      name: json['name'] as String,
      barcode: json['barcode'] as String?,
      sku: json['sku'] as String?,
      description: json['description'] as String?,
      unit: json['unit'] as String? ?? 'piece',
      price: '${json['price'] ?? 0}',
      cost: '${json['cost'] ?? 0}',
      avgCost: '${json['avg_cost'] ?? 0}',
      quantity: '${json['quantity'] ?? 0}',
      lowStockThreshold: '${json['low_stock_threshold'] ?? 5}',
      allowNegativeStock: json['allow_negative_stock'] as bool? ?? false,
      wholesalePrice: json['wholesale_price']?.toString(),
      wholesaleMinQty: json['wholesale_min_qty']?.toString(),
      vatRate: json['vat_rate'] as int? ?? 0,
      expiryDate: json['expiry_date'] as String?,
      imagePath: json['image_path'] as String?,
      categoryId: json['category_id'] as String?,
      categoryName: json['category_name'] as String?,
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

/// Product variant (Phase 6). price/cost null → inherit product values.
class VariantModel {
  final String id;
  final String productId;
  final String name;
  final String? barcode;
  final String? sku;
  final String? price;
  final String? cost;
  final String quantity;
  final bool isArchived;

  const VariantModel({
    required this.id,
    required this.productId,
    required this.name,
    this.barcode,
    this.sku,
    this.price,
    this.cost,
    this.quantity = '0',
    this.isArchived = false,
  });

  factory VariantModel.fromJson(Map<String, dynamic> json) {
    return VariantModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      name: json['name'] as String,
      barcode: json['barcode'] as String?,
      sku: json['sku'] as String?,
      price: json['price'] == null ? null : '${json['price']}',
      cost: json['cost'] == null ? null : '${json['cost']}',
      quantity: '${json['quantity'] ?? 0}',
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}

/// Commercial selling unit (Phase 6): piece ×1, box ×24, …
/// Prices are independent — never derived from multiplier × base price.
class SellingUnitModel {
  final String id;
  final String productId;
  final String name;
  final String unitType;
  final String multiplier;
  final String? barcode;
  final String? sellingPrice;
  final bool isBaseUnit;
  final bool isArchived;
  final String? availableBaseQty;
  final String? availableSellingQty;
  final String? effectivePrice;

  const SellingUnitModel({
    required this.id,
    required this.productId,
    required this.name,
    this.unitType = 'piece',
    this.multiplier = '1',
    this.barcode,
    this.sellingPrice,
    this.isBaseUnit = false,
    this.isArchived = false,
    this.availableBaseQty,
    this.availableSellingQty,
    this.effectivePrice,
  });

  factory SellingUnitModel.fromJson(Map<String, dynamic> json) {
    return SellingUnitModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      name: json['name'] as String,
      unitType: json['unit_type'] as String? ?? 'piece',
      multiplier: '${json['multiplier'] ?? 1}',
      barcode: json['barcode'] as String?,
      sellingPrice:
          json['selling_price'] == null ? null : '${json['selling_price']}',
      isBaseUnit: json['is_base_unit'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      availableBaseQty: json['available_base_qty']?.toString(),
      availableSellingQty: json['available_selling_qty']?.toString(),
      effectivePrice: json['effective_price']?.toString(),
    );
  }
}

/// Purchase packaging unit (Phase 6 correction): Box ×24, Carton ×48, …
/// Separate from selling units. No selling price — cost lives on documents.
class PurchaseUnitModel {
  final String id;
  final String productId;
  final String name;
  final String unitType;
  final String multiplier;
  final String? barcode;
  final bool isDefault;
  final bool isArchived;
  final String? fullPackages;
  final String? baseEquivalentAvailable;

  const PurchaseUnitModel({
    required this.id,
    required this.productId,
    required this.name,
    this.unitType = 'piece',
    this.multiplier = '1',
    this.barcode,
    this.isDefault = false,
    this.isArchived = false,
    this.fullPackages,
    this.baseEquivalentAvailable,
  });

  factory PurchaseUnitModel.fromJson(Map<String, dynamic> json) {
    return PurchaseUnitModel(
      id: json['id'] as String,
      productId: json['product_id'] as String,
      name: json['name'] as String,
      unitType: json['unit_type'] as String? ?? 'piece',
      multiplier: '${json['multiplier'] ?? 1}',
      barcode: json['barcode'] as String?,
      isDefault: json['is_default'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      fullPackages: json['full_packages']?.toString(),
      baseEquivalentAvailable: json['base_equivalent_available']?.toString(),
    );
  }
}

/// Unified barcode scan result (Phase 8 ready).
class BarcodeLookupModel {
  final bool found;
  final String? kind; // product | variant | selling_unit
  final String? productId;
  final String? productName;
  final String? productPrice;
  final String? productQuantity;
  final String? productUnit;
  final String? variantId;
  final String? variantName;
  final String? variantPrice;
  final String? sellingUnitId;
  final String? sellingUnitName;
  final String? sellingUnitMultiplier;
  final String? sellingUnitPrice;
  final bool isArchived;

  const BarcodeLookupModel({
    required this.found,
    this.kind,
    this.productId,
    this.productName,
    this.productPrice,
    this.productQuantity,
    this.productUnit,
    this.variantId,
    this.variantName,
    this.variantPrice,
    this.sellingUnitId,
    this.sellingUnitName,
    this.sellingUnitMultiplier,
    this.sellingUnitPrice,
    this.isArchived = false,
  });

  factory BarcodeLookupModel.fromJson(Map<String, dynamic> json) {
    return BarcodeLookupModel(
      found: json['found'] as bool? ?? false,
      kind: json['kind'] as String?,
      productId: json['product_id'] as String?,
      productName: json['product_name'] as String?,
      productPrice: json['product_price']?.toString(),
      productQuantity: json['product_quantity']?.toString(),
      productUnit: json['product_unit'] as String?,
      variantId: json['variant_id'] as String?,
      variantName: json['variant_name'] as String?,
      variantPrice: json['variant_price']?.toString(),
      sellingUnitId: json['selling_unit_id'] as String?,
      sellingUnitName: json['selling_unit_name'] as String?,
      sellingUnitMultiplier: json['selling_unit_multiplier']?.toString(),
      sellingUnitPrice: json['selling_unit_price']?.toString(),
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}
