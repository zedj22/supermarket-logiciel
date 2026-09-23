// Catalog data models (Phase 5): products and categories.

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
  final String quantity;
  final String lowStockThreshold;
  final bool allowNegativeStock;
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
    this.quantity = '0',
    this.lowStockThreshold = '5',
    this.allowNegativeStock = false,
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
      quantity: '${json['quantity'] ?? 0}',
      lowStockThreshold: '${json['low_stock_threshold'] ?? 5}',
      allowNegativeStock: json['allow_negative_stock'] as bool? ?? false,
      expiryDate: json['expiry_date'] as String?,
      imagePath: json['image_path'] as String?,
      categoryId: json['category_id'] as String?,
      categoryName: json['category_name'] as String?,
      isArchived: json['is_archived'] as bool? ?? false,
    );
  }
}
