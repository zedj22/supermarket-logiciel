// Phase 18 promotion models.
//
// Money (`value`) always arrives as a decimal STRING (Phase 0 money rule):
// the backend owns NUMERIC(18,3) and Flutter only renders what the API
// returned — it never recomputes a promotional price. The effective promo
// price for a product rides on the PRODUCT response
// (`ProductModel.promotion.price`), never on this model.
//
// A promotion is a CONTAINER: name + type + value + the set of products it
// targets. `products.price` is never rewritten (deactivation restores
// retail on the next price resolution).
import '../clients/customer_models.dart' show formatMoney;

/// Localization key for a promotion type (`percentage` / `fixed_price`).
String promotionTypeKey(String type) => 'promotion_type_$type';

/// What a row prints for the promotion's value: `20%` for a percentage,
/// the money amount for a fixed price.
String promotionValueLabel(PromotionItem promotion) {
  if (promotion.promotionType == 'percentage') {
    return '${formatMoney(promotion.value)}%';
  }
  return formatMoney(promotion.value);
}

/// One product reference inside a promotion (`{id, name}`).
class PromotionProductRef {
  final String id;
  final String name;

  const PromotionProductRef({required this.id, required this.name});

  factory PromotionProductRef.fromJson(Map<String, dynamic> json) {
    return PromotionProductRef(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
    );
  }
}

/// One promotion as `GET/POST/PUT /api/v1/promotions` returns it.
class PromotionItem {
  final String id;
  final String name;

  /// `'percentage'` | `'fixed_price'`.
  final String promotionType;

  /// Decimal string, e.g. `'20.000'` (percent) or `'150.000'` (price).
  final String value;
  final bool isActive;

  /// Lightweight `{id, name}` refs (membership set).
  final List<PromotionProductRef> products;

  /// Membership ids — the same set as [products], id order preserved.
  final List<String> productIds;
  final int productCount;
  final String? clientRequestId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool idempotentReplay;

  const PromotionItem({
    required this.id,
    required this.name,
    required this.promotionType,
    required this.value,
    required this.isActive,
    this.products = const [],
    this.productIds = const [],
    this.productCount = 0,
    this.clientRequestId,
    this.createdAt,
    this.updatedAt,
    this.idempotentReplay = false,
  });

  factory PromotionItem.fromJson(Map<String, dynamic> json) {
    final products = (json['products'] as List<dynamic>? ?? const [])
        .map((e) => PromotionProductRef.fromJson(e as Map<String, dynamic>))
        .toList();
    return PromotionItem(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      promotionType: '${json['promotion_type'] ?? 'percentage'}',
      value: '${json['value'] ?? 0}',
      isActive: json['is_active'] as bool? ?? true,
      products: products,
      productIds: (json['product_ids'] as List<dynamic>? ?? const [])
          .map((e) => '$e')
          .toList(),
      productCount: json['product_count'] as int? ?? products.length,
      clientRequestId: json['client_request_id'] as String?,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse('${json['created_at']}'),
      updatedAt: json['updated_at'] == null
          ? null
          : DateTime.tryParse('${json['updated_at']}'),
      idempotentReplay: json['idempotent_replay'] as bool? ?? false,
    );
  }

  bool get isPercentage => promotionType == 'percentage';
}

/// One page of `GET /api/v1/promotions`.
class PromotionListPage {
  final List<PromotionItem> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const PromotionListPage({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 40,
    this.pages = 1,
  });

  factory PromotionListPage.fromJson(Map<String, dynamic> json) {
    return PromotionListPage(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => PromotionItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      pageSize: json['page_size'] as int? ?? 40,
      pages: json['pages'] as int? ?? 1,
    );
  }
}
